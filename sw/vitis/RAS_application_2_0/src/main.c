/******************************************************************************
 * main.c — RAAS LeNet-5 PS app (Ultra96-v2 bare-metal A53)
 *
 * Workflow:
 *   1. Hold PicoRV32 in reset.
 *   2. Load firmware bytes (firmware_lenet) vào BRAM @ PS view 0xA0000000.
 *   3. Prefill DDR @ PS view 0x10000000 với weights/bias/image từ lenet_data.h
 *      theo layout của lenet_map.h.
 *   4. Init mailbox = MBX_BOOT.
 *   5. Cache flush DDR (PicoRV32 đọc qua HP0 non-coherent).
 *   6. Release PicoRV32 reset.
 *   7. Poll mailbox; print predicted_digit and compare with lenet_test_label.
 ******************************************************************************/
#include <stdio.h>
#include <stdint.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "raas_map.h"
#include "lenet_map.h"          /* DDR layout offsets */
#include "firmware_image.h"     /* pico_firmware[], pico_firmware_len */
#include "lenet_data.h"         /* lenet_conv1_weight, lenet_image, ... */

/* Poll limits — tốc độ A53 ~1 GHz, mỗi iteration vài cycle */
#define MAILBOX_POLL_LIMIT     100000000u
#define DDR_PS_BASE            RAAS_PS_DDR_BASE   /* = 0x10000000 */
#define BRAM_PS_BASE           RAAS_PS_BRAM_BASE  /* = 0xA0000000 */

/* ── Helper: load PicoRV32 firmware (uint8_t array) vào BRAM (32-bit AXI) ─ */
static void load_firmware_to_bram(void)
{
    uint32_t word_count = (pico_firmware_len + 3u) / 4u;
    for (uint32_t w = 0; w < word_count; w++) {
        uint32_t value = 0u;
        for (uint32_t b = 0; b < 4; b++) {
            uint32_t idx = w * 4u + b;
            if (idx < pico_firmware_len) {
                value |= ((uint32_t)pico_firmware[idx]) << (b * 8u);
            }
        }
        Xil_Out32(BRAM_PS_BASE + w * 4u, value);
    }
    /* BRAM via axi_bram_ctrl_2 ở vùng PL peripheral (Device memory non-cacheable
     * trong default MMU). Flush vẫn an toàn idempotent. */
    Xil_DCacheFlushRange(BRAM_PS_BASE, pico_firmware_len);
}

/* ── Helper: copy 32-bit aligned data → DDR ─────────────────────────────── */
static void write_words_to_ddr(uint32_t ddr_offset, const uint32_t *src,
                               uint32_t word_count)
{
    for (uint32_t i = 0; i < word_count; i++) {
        Xil_Out32(DDR_PS_BASE + ddr_offset + i * 4u, src[i]);
    }
}

/* ── Helper: prefill DDR + flush ─────────────────────────────────────────── */
static void prefill_ddr(void)
{
    /* Clear out the mailbox and predicted digit area */
    Xil_Out32(DDR_PS_BASE + LENET_DDR_MAILBOX_OFF, RAAS_MBX_BOOT);
    Xil_Out32(DDR_PS_BASE + LENET_DDR_PREDICTED_OFF, 0xFFFFFFFFu);
    Xil_Out32(DDR_PS_BASE + LENET_DDR_LAYER_DBG_OFF, 0x0);

    /* Load input image */
    write_words_to_ddr(LENET_DDR_IMAGE_OFF, lenet_image, sizeof(lenet_image) / 4);

    /* Load Conv1 */
    write_words_to_ddr(LENET_DDR_CONV1_BIAS_OFF, lenet_conv1_bias, sizeof(lenet_conv1_bias) / 4);
    write_words_to_ddr(LENET_DDR_CONV1_W_OFF, lenet_conv1_weight, sizeof(lenet_conv1_weight) / 4);

    /* Load Conv2 */
    write_words_to_ddr(LENET_DDR_CONV2_BIAS_OFF, lenet_conv2_bias, sizeof(lenet_conv2_bias) / 4);
    write_words_to_ddr(LENET_DDR_CONV2_W_OFF, lenet_conv2_weight, sizeof(lenet_conv2_weight) / 4);

    /* Load FC1 */
    write_words_to_ddr(LENET_DDR_FC1_BIAS_OFF, lenet_fc1_bias, sizeof(lenet_fc1_bias) / 4);
    write_words_to_ddr(LENET_DDR_FC1_W_OFF, lenet_fc1_weight, sizeof(lenet_fc1_weight) / 4);

    /* Load FC2 */
    write_words_to_ddr(LENET_DDR_FC2_BIAS_OFF, lenet_fc2_bias, sizeof(lenet_fc2_bias) / 4);
    write_words_to_ddr(LENET_DDR_FC2_W_OFF, lenet_fc2_weight, sizeof(lenet_fc2_weight) / 4);

    /* Load FC3 */
    write_words_to_ddr(LENET_DDR_FC3_BIAS_OFF, lenet_fc3_bias, sizeof(lenet_fc3_bias) / 4);
    write_words_to_ddr(LENET_DDR_FC3_W_OFF, lenet_fc3_weight, sizeof(lenet_fc3_weight) / 4);

    /* QUAN TRỌNG: flush A53 cache để PicoRV32 (HP0 non-coherent) thấy data
     * Khác với smoke test, LeNet dùng vùng data rộng tới 0x50000 (320KB). */
    Xil_DCacheFlushRange(DDR_PS_BASE, 0x50000);
}

/* ── Helper: poll mailbox với cache invalidate ───────────────────────────── */
static uint32_t wait_mailbox_change(void)
{
    for (uint32_t i = 0; i < MAILBOX_POLL_LIMIT; i++) {
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_MAILBOX_OFF, 4);
        uint32_t value = Xil_In32(DDR_PS_BASE + LENET_DDR_MAILBOX_OFF);
        
        /* Đọc debug layer nếu thay đổi thì in ra */
        static uint32_t last_layer = 0;
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_LAYER_DBG_OFF, 4);
        uint32_t layer = Xil_In32(DDR_PS_BASE + LENET_DDR_LAYER_DBG_OFF);
        if (layer != last_layer && layer != 0) {
            xil_printf("  -> Firmware reached layer %u\r\n", (unsigned int)layer);
            last_layer = layer;
        }

        if (value != RAAS_MBX_BOOT && value != RAAS_MBX_STARTED) {
            return value;
        }
    }
    return 0xFFFFFFFFu;  /* timeout */
}

int main(void)
{
    xil_printf("\r\n=== RAAS LeNet-5 Inference ===\r\n");
    xil_printf("Firmware size: %u bytes\r\n", (unsigned int)pico_firmware_len);

    /* 1. Hold PicoRV32 in reset */
    Xil_Out32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET, RAAS_SW_RESET_HOLD);
    xil_printf("PicoRV32 held in reset\r\n");

    /* 2. Load firmware vào BRAM */
    load_firmware_to_bram();
    xil_printf("Loaded firmware to BRAM @ 0x%08x\r\n", (unsigned int)BRAM_PS_BASE);

    /* 3-4. Prefill DDR + init mailbox + cache flush */
    prefill_ddr();
    xil_printf("Prefilled DDR with LeNet weights & test image (Label: %u)\r\n", 
               (unsigned int)LENET_TEST_LABEL);

    /* 5. Release PicoRV32 reset */
    Xil_Out32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET, RAAS_SW_RESET_RUN);
    xil_printf("PicoRV32 released — polling mailbox...\r\n");

    /* 6. Poll mailbox */
    uint32_t result = wait_mailbox_change();

    switch (result) {
    case RAAS_MBX_PASS:
        xil_printf("\r\n>>> INFERENCE COMPLETE <<<\r\n");
        /* Read predicted digit and cycles */
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_PREDICTED_OFF, 4);
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_HW_CYCLES_OFF, 4);
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_SW_CYCLES_OFF, 4);

        uint32_t predicted = Xil_In32(DDR_PS_BASE + LENET_DDR_PREDICTED_OFF);
        uint32_t hw_cycles = Xil_In32(DDR_PS_BASE + LENET_DDR_HW_CYCLES_OFF);
        uint32_t sw_cycles = Xil_In32(DDR_PS_BASE + LENET_DDR_SW_CYCLES_OFF);

        xil_printf("Predicted Digit : %u\r\n", (unsigned int)predicted);
        xil_printf("Ground Truth    : %u\r\n", (unsigned int)LENET_TEST_LABEL);
        
        if (predicted == LENET_TEST_LABEL) {
            xil_printf("Result          : CORRECT ✅\r\n");
        } else {
            xil_printf("Result          : WRONG ❌\r\n");
        }

        xil_printf("\r\n--- Performance Benchmark ---\r\n");
        xil_printf("Hardware Accel Cycles : %u\r\n", (unsigned int)hw_cycles);
        xil_printf("Pure Software Cycles  : %u\r\n", (unsigned int)sw_cycles);
        
        if (hw_cycles > 0) {
            float speedup = (float)sw_cycles / (float)hw_cycles;
            /* Note: xil_printf doesn't support %f well, so we print integer and fractional part */
            int speedup_int = (int)speedup;
            int speedup_frac = (int)((speedup - speedup_int) * 100);
            xil_printf("Speedup Ratio         : %d.%02dx\r\n", speedup_int, speedup_frac);
        }
        break;
        
    case RAAS_MBX_FAIL:
        xil_printf("\r\n>>> RESULT: FAIL <<<\r\n");
        break;
    case RAAS_MBX_DMA_TIMEOUT:
        xil_printf("\r\n>>> RESULT: DMA TIMEOUT <<<\r\n");
        break;
    case RAAS_MBX_DMA_ERROR:
        xil_printf("\r\n>>> RESULT: DMA ERROR (DMASR err bit) <<<\r\n");
        break;
    case RAAS_MBX_ACCEL_TIMEOUT:
        xil_printf("\r\n>>> RESULT: ACCELERATOR TIMEOUT <<<\r\n");
        break;
    case 0xFFFFFFFFu:
        xil_printf("\r\n>>> RESULT: PS POLL TIMEOUT (firmware not running?) <<<\r\n");
        break;
    default:
        xil_printf("\r\n>>> RESULT: UNKNOWN 0x%08x <<<\r\n", (unsigned int)result);
        break;
    }

    xil_printf("Done.\r\n");
    while (1) {}
    return 0;  /* unreachable */
}

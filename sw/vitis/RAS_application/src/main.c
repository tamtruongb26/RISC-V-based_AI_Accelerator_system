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
#include "sleep.h"
#include "raas_map.h"
#include "lenet_map.h"          /* DDR layout offsets */
#include "firmware_image.h"     /* pico_firmware[], pico_firmware_len */
#include "lenet_data.h"         /* lenet_conv1_weight, lenet_image, ... */

#define RUN_1000_IMAGES_BENCHMARK  1
#define BENCHMARK_IMAGE_COUNT      1

#if RUN_1000_IMAGES_BENCHMARK
#include "lenet_images_1000.h"
#endif

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

    /* Verify BRAM content */
    uint32_t errors = 0;
    for (uint32_t w = 0; w < word_count; w++) {
        uint32_t expected = 0u;
        for (uint32_t b = 0; b < 4; b++) {
            uint32_t idx = w * 4u + b;
            if (idx < pico_firmware_len) {
                expected |= ((uint32_t)pico_firmware[idx]) << (b * 8u);
            }
        }
        uint32_t actual = Xil_In32(BRAM_PS_BASE + w * 4u);
        if (actual != expected) {
            errors++;
            if (errors <= 5) {
                xil_printf("  [BRAM ERROR] Mismatch at word %u: expected 0x%08x, got 0x%08x\r\n",
                           (unsigned int)w, (unsigned int)expected, (unsigned int)actual);
            }
        }
    }
    if (errors > 0) {
        xil_printf("  [BRAM ERROR] Total mismatches: %u / %u words\r\n",
                   (unsigned int)errors, (unsigned int)word_count);
    }
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

#if !RUN_1000_IMAGES_BENCHMARK
    /* Load input image */
    write_words_to_ddr(LENET_DDR_IMAGE_OFF, lenet_image, sizeof(lenet_image) / 4);
#endif

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

static void print_val(int16_t val)
{
    float fval = (float)val / 2048.0f;
    int val_int = (int)fval;
    float frac = fval - (float)val_int;
    if (frac < 0.0f) frac = -frac;
    int val_frac = (int)(frac * 1000.0f);
    
    if (fval < 0.0f && val_int == 0) {
        xil_printf(" -0.%03d", val_frac);
    } else {
        xil_printf(" %d.%03d", val_int, val_frac);
    }
}

static void print_fmap_compare(const char *name, uint32_t hw_offset, uint32_t sw_offset, uint32_t total_elements, uint32_t print_count)
{
    Xil_DCacheInvalidateRange(DDR_PS_BASE + hw_offset, total_elements * 2);
    Xil_DCacheInvalidateRange(DDR_PS_BASE + sw_offset, total_elements * 2);

    uint32_t mismatches = 0;
    int first_mismatch_idx = -1;

    for (uint32_t i = 0; i < total_elements; i++) {
        uint32_t hw_word = Xil_In32((DDR_PS_BASE + hw_offset + i * 2) & ~3u);
        int16_t hw_val = ((hw_offset + i * 2) & 2u) ? (int16_t)(hw_word >> 16) : (int16_t)(hw_word & 0xFFFF);

        uint32_t sw_word = Xil_In32((DDR_PS_BASE + sw_offset + i * 2) & ~3u);
        int16_t sw_val = ((sw_offset + i * 2) & 2u) ? (int16_t)(sw_word >> 16) : (int16_t)(sw_word & 0xFFFF);

        if (hw_val != sw_val) {
            if (mismatches == 0) {
                first_mismatch_idx = i;
            }
            mismatches++;
        }
    }

    if (mismatches == 0) {
        xil_printf("  %s: MATCH ✅ (all %u elements)\r\n", name, (unsigned int)total_elements);
    } else {
        xil_printf("  %s: MISMATCH ❌ (%u / %u mismatches, first at idx %d)\r\n", 
                   name, (unsigned int)mismatches, (unsigned int)total_elements, first_mismatch_idx);
    }

    xil_printf("    HW (first %u):", (unsigned int)print_count);
    for (uint32_t i = 0; i < print_count; i++) {
        uint32_t word = Xil_In32((DDR_PS_BASE + hw_offset + i * 2) & ~3u);
        int16_t val = ((hw_offset + i * 2) & 2u) ? (int16_t)(word >> 16) : (int16_t)(word & 0xFFFF);
        print_val(val);
    }
    xil_printf("\r\n");

    xil_printf("    SW (first %u):", (unsigned int)print_count);
    for (uint32_t i = 0; i < print_count; i++) {
        uint32_t word = Xil_In32((DDR_PS_BASE + sw_offset + i * 2) & ~3u);
        int16_t val = ((sw_offset + i * 2) & 2u) ? (int16_t)(word >> 16) : (int16_t)(word & 0xFFFF);
        print_val(val);
    }
    xil_printf("\r\n");

    if (mismatches > 0 && first_mismatch_idx >= 0) {
        uint32_t hw_word = Xil_In32((DDR_PS_BASE + hw_offset + first_mismatch_idx * 2) & ~3u);
        int16_t hw_val = ((hw_offset + first_mismatch_idx * 2) & 2u) ? (int16_t)(hw_word >> 16) : (int16_t)(hw_word & 0xFFFF);

        uint32_t sw_word = Xil_In32((DDR_PS_BASE + sw_offset + first_mismatch_idx * 2) & ~3u);
        int16_t sw_val = ((sw_offset + first_mismatch_idx * 2) & 2u) ? (int16_t)(sw_word >> 16) : (int16_t)(sw_word & 0xFFFF);
        
        xil_printf("    First mismatch value at idx %d: HW=", first_mismatch_idx);
        print_val(hw_val);
        xil_printf(" (raw: 0x%04X), SW=", (unsigned int)(uint16_t)hw_val);
        print_val(sw_val);
        xil_printf(" (raw: 0x%04X)\r\n", (unsigned int)(uint16_t)sw_val);
    }
}

/* ── Helper: print firmware error debug dump from DDR ─────────────────────── */
static void print_error_debug(void)
{
    Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_LAYER_DBG_OFF, 4);
    Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_ERR_CODE_OFF, 32);
    Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_MAILBOX_OFF, 4);

    uint32_t layer      = Xil_In32(DDR_PS_BASE + LENET_DDR_LAYER_DBG_OFF);
    uint32_t err_code   = Xil_In32(DDR_PS_BASE + LENET_DDR_ERR_CODE_OFF);
    uint32_t dma_mm2s   = Xil_In32(DDR_PS_BASE + LENET_DDR_ERR_DMA_MM2S_OFF);
    uint32_t dma_s2mm   = Xil_In32(DDR_PS_BASE + LENET_DDR_ERR_DMA_S2MM_OFF);
    uint32_t accel_stat = Xil_In32(DDR_PS_BASE + LENET_DDR_ERR_ACCEL_OFF);
    uint32_t tile_n0    = Xil_In32(DDR_PS_BASE + LENET_DDR_ERR_TILE_N0_OFF);
    uint32_t tile_k0    = Xil_In32(DDR_PS_BASE + LENET_DDR_ERR_TILE_K0_OFF);
    uint32_t cfg_val    = Xil_In32(DDR_PS_BASE + LENET_DDR_ERR_CFG_OFF);

    uint32_t rt_mailbox = Xil_In32(DDR_PS_BASE + LENET_DDR_MAILBOX_OFF);

    xil_printf("--- Error Debug Dump ---\r\n");
    xil_printf("  Failed at layer  : %u\r\n", (unsigned int)layer);
    xil_printf("  Error code (raw) : 0x%08x (%d)\r\n",
               (unsigned int)err_code, (int)err_code);
    xil_printf("  Tile n0=%u k0=%u\r\n",
               (unsigned int)tile_n0, (unsigned int)tile_k0);
    xil_printf("  CFG written      : 0x%08x\r\n", (unsigned int)cfg_val);
    xil_printf("    M=%u K=%u N=%u ACT=%u\r\n",
               (unsigned int)(cfg_val & 0xF),
               (unsigned int)((cfg_val >> 4) & 0xF),
               (unsigned int)((cfg_val >> 8) & 0xF),
               (unsigned int)((cfg_val >> 12) & 0x3));
    xil_printf("    START=%u ACC=%u SKIP_PP=%u SKIP_W=%u SLOT=%u OS=%u POOL=%u\r\n",
               (unsigned int)((cfg_val >> 14) & 1),
               (unsigned int)((cfg_val >> 15) & 1),
               (unsigned int)((cfg_val >> 16) & 1),
               (unsigned int)((cfg_val >> 17) & 1),
               (unsigned int)((cfg_val >> 18) & 3),
               (unsigned int)((cfg_val >> 22) & 1),
               (unsigned int)((cfg_val >> 23) & 1));
    xil_printf("  DMA MM2S DMASR   : 0x%08x (Snapshot)\r\n", (unsigned int)dma_mm2s);
    xil_printf("  DMA S2MM DMASR   : 0x%08x (Snapshot)\r\n", (unsigned int)dma_s2mm);
    xil_printf("  Accel STATUS     : 0x%08x (Snapshot)\r\n", (unsigned int)accel_stat);
    xil_printf("  Mailbox (DDR)    : 0x%08x\r\n", (unsigned int)rt_mailbox);

    /* Decode snapshot DMASR bits */
    if (dma_mm2s & 0x10u) xil_printf("  !! MM2S DMAIntErr (internal)\r\n");
    if (dma_mm2s & 0x20u) xil_printf("  !! MM2S DMASlvErr (slave)\r\n");
    if (dma_mm2s & 0x40u) xil_printf("  !! MM2S DMADecErr (decode)\r\n");
    if (dma_s2mm & 0x10u) xil_printf("  !! S2MM DMAIntErr (internal)\r\n");
    if (dma_s2mm & 0x20u) xil_printf("  !! S2MM DMASlvErr (slave)\r\n");
    if (dma_s2mm & 0x40u) xil_printf("  !! S2MM DMADecErr (decode)\r\n");

    /* Decode snapshot accel STATUS */
    if (accel_stat & 0x1u) xil_printf("  !! Accel BUSY\r\n");
    if (accel_stat & 0x2u) xil_printf("  !! Accel DONE\r\n");
    if (!(accel_stat & 0x3u)) xil_printf("  !! Accel IDLE (FSM stuck?)\r\n");
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

#if RUN_1000_IMAGES_BENCHMARK
    xil_printf("Running %d MNIST test images benchmark...\r\n", BENCHMARK_IMAGE_COUNT);
    int correct_hw = 0;
    int correct_sw = 0;
    uint32_t total_hw_cycles = 0;
    uint32_t total_sw_cycles = 0;

    for (int i = 0; i < BENCHMARK_IMAGE_COUNT; i++) {
        /* Hold PicoRV32 in reset */
        Xil_Out32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET, RAAS_SW_RESET_HOLD);
        (void)Xil_In32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET); /* Force AXI write completion */
        usleep(10); /* Wait for reset propagation */

        /* Reload firmware to BRAM on every iteration to restore the .data section */
        load_firmware_to_bram();

        /* Write current image */
        write_words_to_ddr(LENET_DDR_IMAGE_OFF, lenet_test_images[i], 392);

        /* Reset mailbox & result area */
        Xil_Out32(DDR_PS_BASE + LENET_DDR_MAILBOX_OFF, RAAS_MBX_BOOT);
        Xil_Out32(DDR_PS_BASE + LENET_DDR_PREDICTED_OFF, 0xFFFFFFFFu);
        Xil_Out32(DDR_PS_BASE + LENET_DDR_LAYER_DBG_OFF, 0x0);

        /* Flush cache for image and mailbox so PicoRV32 sees it */
        Xil_DCacheFlushRange(DDR_PS_BASE + LENET_DDR_IMAGE_OFF, 392 * 4);
        Xil_DCacheFlushRange(DDR_PS_BASE + LENET_DDR_MAILBOX_OFF, 64);

        /* Wait 10 us to ensure reset takes effect */
        usleep(10);

        /* Release PicoRV32 reset */
        Xil_Out32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET, RAAS_SW_RESET_RUN);

        /* Poll mailbox */
        uint32_t result = wait_mailbox_change();

        if (result == RAAS_MBX_PASS) {
            Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_PREDICTED_OFF, 4);
            Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_PREDICTED_SW_OFF, 4);
            Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_HW_CYCLES_OFF, 4);
            Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_SW_CYCLES_OFF, 4);

            uint32_t predicted = Xil_In32(DDR_PS_BASE + LENET_DDR_PREDICTED_OFF);
            uint32_t predicted_sw = Xil_In32(DDR_PS_BASE + LENET_DDR_PREDICTED_SW_OFF);
            uint32_t hw_cycles = Xil_In32(DDR_PS_BASE + LENET_DDR_HW_CYCLES_OFF);
            uint32_t sw_cycles = Xil_In32(DDR_PS_BASE + LENET_DDR_SW_CYCLES_OFF);

            if (predicted == lenet_test_labels[i]) correct_hw++;
            if (predicted_sw == lenet_test_labels[i]) correct_sw++;

            total_hw_cycles += hw_cycles;
            total_sw_cycles += sw_cycles;

            if ((i + 1) % 10 == 0) {
                int hw_acc_int = (correct_hw * 100) / (i + 1);
                int hw_acc_frac = ((correct_hw * 10000) / (i + 1)) % 100;
                int sw_acc_int = (correct_sw * 100) / (i + 1);
                int sw_acc_frac = ((correct_sw * 10000) / (i + 1)) % 100;

                xil_printf("Progress: %d / %d | HW Acc: %d.%02d%% | SW Acc: %d.%02d%%\r\n", 
                           i + 1, BENCHMARK_IMAGE_COUNT, hw_acc_int, hw_acc_frac, sw_acc_int, sw_acc_frac);
            }
        } else {
            xil_printf("Image %d failed! Mailbox = 0x%08x\r\n", i, (unsigned int)result);
            print_error_debug();
            break;
        }
    }

    xil_printf("\r\n=== %d IMAGES BENCHMARK COMPLETED ===\r\n", BENCHMARK_IMAGE_COUNT);
    int final_hw_int = (correct_hw * 100) / BENCHMARK_IMAGE_COUNT;
    int final_hw_frac = ((correct_hw * 10000) / BENCHMARK_IMAGE_COUNT) % 100;
    int final_sw_int = (correct_sw * 100) / BENCHMARK_IMAGE_COUNT;
    int final_sw_frac = ((correct_sw * 10000) / BENCHMARK_IMAGE_COUNT) % 100;
    xil_printf("Final HW Accuracy: %d.%02d%%\r\n", final_hw_int, final_hw_frac);
    xil_printf("Final SW Accuracy: %d.%02d%%\r\n", final_sw_int, final_sw_frac);
    
    uint32_t avg_hw = total_hw_cycles / BENCHMARK_IMAGE_COUNT;
    uint32_t avg_sw = total_sw_cycles / BENCHMARK_IMAGE_COUNT;
    xil_printf("Avg HW Cycles: %u\r\n", (unsigned int)avg_hw);
    xil_printf("Avg SW Cycles: %u\r\n", (unsigned int)avg_sw);
    if (avg_hw > 0) {
        float speedup = (float)avg_sw / (float)avg_hw;
        int speedup_int = (int)speedup;
        int speedup_frac = (int)((speedup - speedup_int) * 100);
        xil_printf("Speedup Ratio: %d.%02dx\r\n", speedup_int, speedup_frac);
    }
    
    xil_printf("Done.\r\n");
    while (1) {}
#else
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
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_PREDICTED_SW_OFF, 4);
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_HW_CYCLES_OFF, 4);
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_SW_CYCLES_OFF, 4);

        uint32_t predicted = Xil_In32(DDR_PS_BASE + LENET_DDR_PREDICTED_OFF);
        uint32_t predicted_sw = Xil_In32(DDR_PS_BASE + LENET_DDR_PREDICTED_SW_OFF);
        uint32_t hw_cycles = Xil_In32(DDR_PS_BASE + LENET_DDR_HW_CYCLES_OFF);
        uint32_t sw_cycles = Xil_In32(DDR_PS_BASE + LENET_DDR_SW_CYCLES_OFF);

        xil_printf("Predicted Digit (HW) : %u\r\n", (unsigned int)predicted);
        xil_printf("Predicted Digit (SW) : %u\r\n", (unsigned int)predicted_sw);
        xil_printf("Ground Truth         : %u\r\n", (unsigned int)LENET_TEST_LABEL);
        
        if (predicted == LENET_TEST_LABEL) {
            xil_printf("Result (HW)          : CORRECT ✅\r\n");
        } else {
            xil_printf("Result (HW)          : WRONG ❌\r\n");
        }

        if (predicted_sw == LENET_TEST_LABEL) {
            xil_printf("Result (SW)          : CORRECT ✅\r\n");
        } else {
            xil_printf("Result (SW)          : WRONG ❌\r\n");
        }

        xil_printf("\r\n--- Intermediate Outputs (HW vs SW Comparison) ---\r\n");
        print_fmap_compare("Input Image", LENET_DDR_IMAGE_OFF, LENET_DDR_IMAGE_OFF, 784, 8);
        print_fmap_compare("Conv1 Out  ", LENET_DDR_HW_CONV1_OFF, LENET_DDR_SW_CONV1_OFF, 3456, 8);
        print_fmap_compare("Pool1 Out  ", LENET_DDR_HW_POOL1_OFF, LENET_DDR_SW_POOL1_OFF, 864, 8);
        print_fmap_compare("Conv2 Out  ", LENET_DDR_HW_CONV2_OFF, LENET_DDR_SW_CONV2_OFF, 1024, 8);
        print_fmap_compare("Pool2 Out  ", LENET_DDR_HW_POOL2_OFF, LENET_DDR_SW_POOL2_OFF, 256, 8);
        print_fmap_compare("FC1 Out    ", LENET_DDR_HW_FC1_OFF, LENET_DDR_SW_FC1_OFF, 120, 8);
        print_fmap_compare("FC2 Out    ", LENET_DDR_HW_FC2_OFF, LENET_DDR_SW_FC2_OFF, 84, 8);
        print_fmap_compare("FC3 Out    ", LENET_DDR_HW_FC3_OFF, LENET_DDR_SW_FC3_OFF, 10, 10);

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

        /* ── Phase 0/3b: per-layer + per-state cycle breakdown (prove bottleneck) ── */
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_LAYER_CYC_OFF, 9 * 4);
        Xil_DCacheInvalidateRange(DDR_PS_BASE + LENET_DDR_ACCEL_CNT_OFF, 11 * 4);
        {
            uint32_t lc[9];
            int i;
            static const char *lname[8] = {
                "Conv1", "Pool1", "Conv2", "Pool2", "FC1  ", "FC2  ", "FC3  ", "Argmx"
            };
            for (i = 0; i < 9; i++)
                lc[i] = Xil_In32(DDR_PS_BASE + LENET_DDR_LAYER_CYC_OFF + i * 4);

            xil_printf("\r\n--- Per-Layer Cycles (HW run) ---\r\n");
            for (i = 0; i < 8; i++) {
                uint32_t d   = lc[i + 1] - lc[i];
                uint32_t pct = hw_cycles ? (uint32_t)(((uint64_t)d * 100u) / hw_cycles) : 0u;
                xil_printf("  %s : %u (%u%%)\r\n", lname[i], (unsigned)d, (unsigned)pct);
            }

            uint32_t ac[11];
            for (i = 0; i < 11; i++)
                ac[i] = Xil_In32(DDR_PS_BASE + LENET_DDR_ACCEL_CNT_OFF + i * 4);
            /* ac: 0 idle,1 load_w,2 load_b,3 load_in,4 compute,5 post,6 send,7 done,8 total,9 pe_active,10 sparsity_skip */
            uint32_t tot = ac[8] ? ac[8] : 1u;
            xil_printf("\r\n--- Accelerator State Breakdown (total=%u) ---\r\n", (unsigned)ac[8]);
            xil_printf("  IDLE(orchestrate): %u (%u%%)\r\n", (unsigned)ac[0], (unsigned)((uint64_t)ac[0]*100/tot));
            xil_printf("  LOAD_W           : %u (%u%%)\r\n", (unsigned)ac[1], (unsigned)((uint64_t)ac[1]*100/tot));
            xil_printf("  LOAD_IN          : %u (%u%%)\r\n", (unsigned)ac[3], (unsigned)((uint64_t)ac[3]*100/tot));
            xil_printf("  COMPUTE(MAC)     : %u (%u%%)\r\n", (unsigned)ac[4], (unsigned)((uint64_t)ac[4]*100/tot));
            xil_printf("  POST_PROC        : %u (%u%%)\r\n", (unsigned)ac[5], (unsigned)((uint64_t)ac[5]*100/tot));
            xil_printf("  SEND_OUT         : %u (%u%%)\r\n", (unsigned)ac[6], (unsigned)((uint64_t)ac[6]*100/tot));
            xil_printf("  NOTE: IDLE%% = PicoRV32 orchestration (DMA setup/copy/poll)\r\n");

            /* Phase 4: sparsity skip rate = skip / (SA_N=8 × compute cycles) */
            uint32_t denom = 8u * ac[4];
            uint32_t sp_pct = denom ? (uint32_t)(((uint64_t)ac[10] * 100u) / denom) : 0u;
            xil_printf("\r\n--- Sparsity (operand isolation, Phase 4) ---\r\n");
            xil_printf("  Zero row-feeds skipped: %u\r\n", (unsigned)ac[10]);
            xil_printf("  Skip rate (~ReLU sparsity): %u%% of MAC row-feeds\r\n", (unsigned)sp_pct);
        }
        break;

    case RAAS_MBX_FAIL:
        xil_printf("\r\n>>> RESULT: FAIL <<<\r\n");
        break;
    case RAAS_MBX_DMA_TIMEOUT:
        xil_printf("\r\n>>> RESULT: DMA TIMEOUT <<<\r\n");
        print_error_debug();
        break;
    case RAAS_MBX_DMA_ERROR:
        xil_printf("\r\n>>> RESULT: DMA ERROR (DMASR err bit) <<<\r\n");
        print_error_debug();
        break;
    case RAAS_MBX_ACCEL_TIMEOUT:
        xil_printf("\r\n>>> RESULT: ACCELERATOR TIMEOUT <<<\r\n");
        print_error_debug();
        break;
    case 0xFFFFFFFFu:
        xil_printf("\r\n>>> RESULT: PS POLL TIMEOUT (firmware not running?) <<<\r\n");
        break;
    default:
        xil_printf("\r\n>>> RESULT: UNKNOWN 0x%08x <<<\r\n", (unsigned int)result);
        print_error_debug();
        break;
    }

    xil_printf("Done.\r\n");
    while (1) {}
    return 0;  /* unreachable */
#endif
}

/******************************************************************************
 * main.c — RAAS smoke test PS app (Ultra96-v2 bare-metal A53)
 *
 * Workflow:
 *   1. Hold PicoRV32 in reset.
 *   2. Load firmware bytes vào BRAM @ PS view 0xA0000000.
 *   3. Prefill DDR @ PS view 0x10000000 với weights/bias/input/golden.
 *   4. Init mailbox = MBX_BOOT.
 *   5. Cache flush DDR (PicoRV32 đọc qua HP0 non-coherent).
 *   6. Release PicoRV32 reset.
 *   7. Poll mailbox; print result.
 ******************************************************************************/
#include <stdio.h>
#include <stdint.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "raas_map.h"
#include "firmware_image.h"     /* pico_firmware[], pico_firmware_len */
#include "smoketest_data.h"     /* smoketest_weights/bias/input/golden */

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

static void write_uint16_to_ddr(uint32_t ddr_offset, const uint16_t *src,
                                uint32_t cell_count)
{
    /* DDR ghi qua 32-bit. Pack 2×u16 thành 1×u32 cẩn thận với endian. */
    for (uint32_t i = 0; i < cell_count; i += 2) {
        uint32_t lo = (uint32_t)src[i];
        uint32_t hi = (i + 1 < cell_count) ? (uint32_t)src[i + 1] : 0u;
        uint32_t word = (hi << 16) | lo;
        Xil_Out32(DDR_PS_BASE + ddr_offset + (i / 2) * 4u, word);
    }
}

/* ── Helper: prefill DDR + flush ─────────────────────────────────────────── */
static void prefill_ddr(void)
{
    write_words_to_ddr(RAAS_DDR_WEIGHTS_OFFSET,
                       smoketest_weights, RAAS_WEIGHTS_WORDS);
    write_words_to_ddr(RAAS_DDR_BIAS_OFFSET,
                       smoketest_bias, RAAS_BIAS_WORDS);
    write_words_to_ddr(RAAS_DDR_INPUT_OFFSET,
                       smoketest_input, RAAS_INPUT_WORDS);
    write_uint16_to_ddr(RAAS_DDR_GOLDEN_OFFSET,
                        smoketest_golden, RAAS_OUTPUT_CELLS);

    /* Init mailbox = BOOT */
    Xil_Out32(DDR_PS_BASE + RAAS_DDR_MAILBOX_OFFSET, RAAS_MBX_BOOT);

    /* QUAN TRỌNG: flush A53 cache để PicoRV32 (HP0 non-coherent) thấy data */
    Xil_DCacheFlushRange(DDR_PS_BASE, RAAS_DDR_USED_SIZE);
}

/* ── Helper: poll mailbox với cache invalidate ───────────────────────────── */
static uint32_t wait_mailbox_change(void)
{
    for (uint32_t i = 0; i < MAILBOX_POLL_LIMIT; i++) {
        Xil_DCacheInvalidateRange(DDR_PS_BASE + RAAS_DDR_MAILBOX_OFFSET, 4);
        uint32_t value = Xil_In32(DDR_PS_BASE + RAAS_DDR_MAILBOX_OFFSET);
        if (value != RAAS_MBX_BOOT && value != RAAS_MBX_STARTED) {
            return value;
        }
    }
    return 0xFFFFFFFFu;  /* timeout */
}

/* ── Helper: print captured output cells (debug) ─────────────────────────── */
static void print_output_buffer(void)
{
    Xil_DCacheInvalidateRange(DDR_PS_BASE + RAAS_DDR_OUTPUT_OFFSET,
                              RAAS_OUTPUT_CELLS * 2);
    volatile const uint16_t *out =
        (volatile const uint16_t *)(DDR_PS_BASE + RAAS_DDR_OUTPUT_OFFSET);
    volatile const uint16_t *gold =
        (volatile const uint16_t *)(DDR_PS_BASE + RAAS_DDR_GOLDEN_OFFSET);

    xil_printf("Output buffer (first 8 cells, hex Q1.4.11):\r\n");
    for (uint32_t i = 0; i < 8; i++) {
        xil_printf("  [%2d] got=0x%04x exp=0x%04x %s\r\n",
                   i, (uint32_t)out[i], (uint32_t)gold[i],
                   (out[i] == gold[i]) ? "OK" : "DIFF");
    }
}

int main(void)
{
    xil_printf("\r\n=== RAAS smoke test boot ===\r\n");
    xil_printf("Firmware size: %u bytes\r\n", (unsigned int)pico_firmware_len);

    /* 1. Hold PicoRV32 in reset */
    Xil_Out32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET, RAAS_SW_RESET_HOLD);
    xil_printf("PicoRV32 held in reset\r\n");

    /* 2. Load firmware vào BRAM */
    load_firmware_to_bram();
    xil_printf("Loaded firmware to BRAM @ 0x%08x\r\n", (unsigned int)BRAM_PS_BASE);

    /* 3-4. Prefill DDR + init mailbox + cache flush */
    prefill_ddr();
    xil_printf("Prefilled DDR @ 0x%08x\r\n", (unsigned int)DDR_PS_BASE);

    /* 5. Release PicoRV32 reset */
    Xil_Out32(RAAS_PS_SW_RESET_BASE + RAAS_SW_RESET_OFFSET, RAAS_SW_RESET_RUN);
    xil_printf("PicoRV32 released — polling mailbox...\r\n");

    /* 6. Poll mailbox */
    uint32_t result = wait_mailbox_change();

    switch (result) {
    case RAAS_MBX_PASS:
        xil_printf("\r\n>>> RESULT: PASS <<<\r\n");
        break;
    case RAAS_MBX_FAIL:
        xil_printf("\r\n>>> RESULT: FAIL <<<\r\n");
        print_output_buffer();
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

    while (1) {}
    return 0;  /* unreachable */
}
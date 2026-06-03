/******************************************************************************
 * main.c — RAAS smoke test firmware (Stage A: 1 tile 8×8×8 bypass)
 *
 * Test flow:
 *   1. mailbox = STARTED                           (signal PS)
 *   2. dma_reset()
 *   3. arm S2MM trước (chờ accelerator gửi output)
 *   4. accel_configure + accel_start                (FSM: IDLE → LOAD_W)
 *   5. Stream 3 MM2S transfers tới accelerator:
 *        weights (128B) → bias (16B) → input (128B)
 *   6. Wait accelerator DONE bit                    (FSM về IDLE, sticky DONE)
 *   7. Wait S2MM transfer xong                      (output đã có ở DDR)
 *   8. Compare 64 cell output vs golden
 *   9. mailbox = PASS / FAIL / *_TIMEOUT / *_ERROR
 *  10. Halt (while(1) — PS đọc mailbox qua JTAG mrd hoặc polling).
 *
 * Plan ref: §8.3 (Step 14.3.4), §8 Q1=A.
 ******************************************************************************/

#include <stdint.h>
#include "raas_map.h"
#include "accel.h"
#include "dma.h"
#include "mailbox.h"

/* Timeout values (cycle count poll). Conservative — Q4 trong plan đã chốt. */
#define DMA_TIMEOUT     100000u   /* DMA transfer 32 word @ 100MHz < 1us  */
#define ACCEL_TIMEOUT   1000000u  /* tile 8x8x8 ~ 200 cycle = 2us         */

/* Convert word count → byte count (mỗi AXIS word = 32-bit = 4 byte) */
#define WEIGHTS_BYTES   (RAAS_WEIGHTS_WORDS * 4u)
#define BIAS_BYTES      (RAAS_BIAS_WORDS    * 4u)
#define INPUT_BYTES     (RAAS_INPUT_WORDS   * 4u)
#define OUTPUT_BYTES    (RAAS_OUTPUT_WORDS  * 4u)

/* ── Debug checkpoint mailbox values (0xDB_xx = debug step xx) ─────────
 * Dùng để pinpoint AXI stall: PS đọc mailbox sau timeout, giá trị 0xDB_xx
 * cho biết firmware đã reach step xx nhưng bị stuck ở step xx+1.
 * Sau khi debug xong, xoá các dòng mailbox_set(0xDB...) này.
 * ──────────────────────────────────────────────────────────────────────── */
#define DBG(n)  mailbox_set(0xDB000000u | (n))

int main(void)
{
    int rc;

    /* ── Step 1: signal PS rằng firmware đã boot ─────────────────────── */
    mailbox_set(RAAS_MBX_STARTED);          /* 0xCAFEBABE — boot OK       */

    /* ── Step 2: reset DMA (ensure clean state) ──────────────────────── */
    DBG(0x02);                               /* before dma_reset()          */
    dma_reset();
    DBG(0x03);                               /* dma_reset() returned        */

    /* ── Step 3: arm S2MM TRƯỚC khi start accelerator ─────────────────
     * Lý do: arm sớm để DMA TREADY=1 sẵn. Khi accelerator vào SEND_OUT
     * sẽ truyền liền không stall. Hợp lệ vì DMA chỉ chờ TVALID. */
    dma_s2mm_recv(RAAS_PICO_DDR_ADDR(RAAS_DDR_OUTPUT_OFFSET), OUTPUT_BYTES);
    DBG(0x04);                               /* dma_s2mm_recv() returned    */

    /* ── Step 4: configure + start accelerator ───────────────────────── */
    accel_configure(RAAS_TILE_M, RAAS_TILE_K, RAAS_TILE_N,
                    RAAS_CFG_ACT_BYPASS);
    DBG(0x05);                               /* accel_configure() returned  */
    accel_start();
    DBG(0x06);                               /* accel_start() returned      */

    /* ── Step 5: stream 3 MM2S transfers (weights, bias, input) ──────── */
    DBG(0x07);                               /* before weights MM2S         */
    rc = dma_mm2s_send_and_wait(
            RAAS_PICO_DDR_ADDR(RAAS_DDR_WEIGHTS_OFFSET),
            WEIGHTS_BYTES, DMA_TIMEOUT);
    if (rc < 0) goto dma_err;

    DBG(0x08);                               /* before bias MM2S            */
    rc = dma_mm2s_send_and_wait(
            RAAS_PICO_DDR_ADDR(RAAS_DDR_BIAS_OFFSET),
            BIAS_BYTES, DMA_TIMEOUT);
    if (rc < 0) goto dma_err;

    DBG(0x09);                               /* before input MM2S           */
    rc = dma_mm2s_send_and_wait(
            RAAS_PICO_DDR_ADDR(RAAS_DDR_INPUT_OFFSET),
            INPUT_BYTES, DMA_TIMEOUT);
    if (rc < 0) goto dma_err;

    /* ── Step 6: wait accelerator DONE ───────────────────────────────── */
    DBG(0x0A);                               /* before accel_wait_done()    */
    if (accel_wait_done(ACCEL_TIMEOUT) < 0) {
        mailbox_set(RAAS_MBX_ACCEL_TIMEOUT);
        goto halt;
    }

    /* ── Step 7: wait S2MM xong (output đã ở DDR) ────────────────────── */
    DBG(0x0B);                               /* before dma_s2mm_wait()      */
    rc = dma_s2mm_wait(DMA_TIMEOUT);
    if (rc < 0) goto dma_err;

    /* ── Step 8: compare 64 output cells với golden ──────────────────── */
    DBG(0x0C);                               /* before compare              */
    {
        volatile const uint16_t *out =
            (volatile const uint16_t *)
            RAAS_PICO_DDR_ADDR(RAAS_DDR_OUTPUT_OFFSET);
        volatile const uint16_t *gold =
            (volatile const uint16_t *)
            RAAS_PICO_DDR_ADDR(RAAS_DDR_GOLDEN_OFFSET);

        uint32_t errs = 0;
        for (uint32_t i = 0; i < RAAS_OUTPUT_CELLS; i++) {
            if (out[i] != gold[i]) {
                errs++;
            }
        }

        mailbox_set(errs == 0 ? RAAS_MBX_PASS : RAAS_MBX_FAIL);
    }
    goto halt;

dma_err:
    mailbox_set(rc == -2 ? RAAS_MBX_DMA_ERROR : RAAS_MBX_DMA_TIMEOUT);

halt:
    /* PS đọc mailbox + output qua JTAG mrd. Firmware halt vĩnh viễn. */
    while (1) {
        __asm__ volatile ("nop");
    }
    return 0;  /* unreachable, satisfies compiler */
}

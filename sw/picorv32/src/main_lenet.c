/******************************************************************************
 * main_lenet.c — LeNet-5 inference entry point for PicoRV32
 *
 * Flow:
 *   1. Signal PS that firmware has booted (mailbox = STARTED)
 *   2. Reset DMA to clean state
 *   3. Run full LeNet-5 inference (7 layers)
 *   4. Write predicted digit to DDR
 *   5. Signal PS that inference is done (mailbox = PASS)
 *   6. Halt (infinite loop)
 *
 * PS reads mailbox + predicted digit via JTAG/polling.
 ******************************************************************************/

#include <stdint.h>
#include "raas_map.h"
#include "lenet_map.h"
#include "lenet.h"
#include "dma.h"
#include "mailbox.h"
#include "io.h"
#include "accel.h"

/* get_cycles → io.h::pico_rdcycle() (Phase 0 refactor) */
#define get_cycles pico_rdcycle

/* Phase 5: chạy demo 4-config reliability sau benchmark (=0 để tắt cho đo speed). */
#define RUN_RELIABILITY_DEMO 1
#define REL_FAULT_BIT   3u        /* bit lật (tune để thấy hiệu ứng) */
#define REL_FAULT_TRIG  100000u   /* cycle tiêm (rơi vào Conv1, tune trên board) */

int main(void)
{
    /* Step 1: signal PS that firmware has booted */
    mmio_write32(LENET_ADDR(LENET_DDR_MAILBOX_OFF), RAAS_MBX_STARTED);

    /* Step 2: reset DMA (ensure clean state) */
    dma_reset();

    /* Step 3: run LeNet-5 inference (HW) */
    uint32_t hw_start = get_cycles();
    int digit_hw = lenet5_infer(1);  /* use_hw = 1 */
    uint32_t hw_cycles = get_cycles() - hw_start;

    /* Write HW cycles */
    mmio_write32(LENET_ADDR(LENET_DDR_HW_CYCLES_OFF), hw_cycles);

    if (digit_hw < 0) {
        /* ── Error debug dump: snapshot HW state vào DDR ──────────── */
        mmio_write32(LENET_ADDR(LENET_DDR_ERR_CODE_OFF), (uint32_t)digit_hw);
        mmio_write32(LENET_ADDR(LENET_DDR_ERR_DMA_MM2S_OFF), dma_mm2s_get_status());
        mmio_write32(LENET_ADDR(LENET_DDR_ERR_DMA_S2MM_OFF), dma_s2mm_get_status());
        mmio_write32(LENET_ADDR(LENET_DDR_ERR_ACCEL_OFF), accel_get_status());
        mmio_write32(LENET_ADDR(LENET_DDR_ERR_CFG_OFF), accel_get_cfg());

        /* Map error code → proper mailbox magic value */
        uint32_t err_mbx;
        switch (digit_hw) {
        case -1: err_mbx = RAAS_MBX_DMA_TIMEOUT;   break;
        case -2: err_mbx = RAAS_MBX_DMA_ERROR;      break;
        case -3: err_mbx = RAAS_MBX_ACCEL_TIMEOUT;  break;
        default: err_mbx = RAAS_MBX_FAIL;           break;
        }
        mmio_write32(LENET_ADDR(LENET_DDR_MAILBOX_OFF), err_mbx);
    } else {
        /* Step 4: run LeNet-5 inference (SW) */
        uint32_t sw_start = get_cycles();
        int digit_sw = lenet5_infer(0);  /* use_hw = 0 */
        (void)digit_sw; /* suppress unused warning */
        uint32_t sw_cycles = get_cycles() - sw_start;

        /* Write SW cycles */
        mmio_write32(LENET_ADDR(LENET_DDR_SW_CYCLES_OFF), sw_cycles);

        /* Write predicted digit to DDR (use HW result) */
        mmio_write32(LENET_ADDR(LENET_DDR_PREDICTED_OFF), (uint32_t)digit_hw);

        /* Write SW predicted digit to DDR */
        mmio_write32(LENET_ADDR(LENET_DDR_PREDICTED_SW_OFF), (uint32_t)digit_sw);

#if RUN_RELIABILITY_DEMO
        /* Phase 5: demo 4-config reliability (ghi REL fields trước khi báo PASS) */
        reliability_demo(REL_FAULT_BIT, REL_FAULT_TRIG);
#endif

        /* Step 5: signal PS that inference is done */
        mmio_write32(LENET_ADDR(LENET_DDR_MAILBOX_OFF), RAAS_MBX_PASS);
    }

    /* Step 6: halt */
    while (1) {
        __asm__ volatile ("nop");
    }
    return 0;  /* unreachable */
}

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

/* get_cycles → io.h::pico_rdcycle() (Phase 0 refactor) */
#define get_cycles pico_rdcycle

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
        /* Error occurred in HW (e.g. timeout), write error code to mailbox */
        mmio_write32(LENET_ADDR(LENET_DDR_MAILBOX_OFF), (uint32_t)(-digit_hw));
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

        /* Step 5: signal PS that inference is done */
        mmio_write32(LENET_ADDR(LENET_DDR_MAILBOX_OFF), RAAS_MBX_PASS);
    }

    /* Step 6: halt */
    while (1) {
        __asm__ volatile ("nop");
    }
    return 0;  /* unreachable */
}

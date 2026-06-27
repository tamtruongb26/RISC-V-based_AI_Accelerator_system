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

/* Phase 5: chạy demo 4-config reliability sau benchmark (=0 để tắt cho đo speed).
 * LƯU Ý: phải =0 khi đo accuracy nhiều ảnh — FI cố tình tiêm lỗi/bit-flip nên
 * vừa làm sai kết quả vừa để lại HW ở trạng thái bẩn giữa các ảnh. Bật lại =1
 * chỉ khi chạy demo Phase 5 (1 ảnh). */
#define RUN_RELIABILITY_DEMO 0
#define REL_FAULT_BIT   3u        /* bit lật (tune để thấy hiệu ứng) */
#define REL_FAULT_TRIG  100000u   /* cycle tiêm (rơi vào Conv1, tune trên board) */

int main(void)
{
    /* Signal PS that firmware has booted (1 lần duy nhất) */
    mmio_write32(LENET_ADDR(LENET_DDR_MAILBOX_OFF), RAAS_MBX_STARTED);

    /* ── No-reboot loop ──────────────────────────────────────────────────
     * PicoRV32 boot 1 lần, xử lý từng ảnh qua handshake GO/PASS với PS.
     * Tránh reset-race khi reboot mỗi ảnh (image 2+ không boot lại được).
     * Mỗi ảnh: PS stage ảnh + ghi GO → FW infer → ghi predicted + PASS. */
    for (;;) {
        /* Chờ PS stage ảnh xong + ra lệnh GO */
        while (mmio_read32(LENET_ADDR(LENET_DDR_MAILBOX_OFF)) != RAAS_MBX_GO) {
            /* spin */
        }

        /* Reset DMA mỗi ảnh (PicoRV32 không reboot → tự dọn state) */
        dma_reset();

        /* Run LeNet-5 inference (HW) */
        uint32_t hw_start = get_cycles();
        int digit_hw = lenet5_infer(1);  /* use_hw = 1 */
        uint32_t hw_cycles = get_cycles() - hw_start;
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
            /* Run LeNet-5 inference (SW) */
            uint32_t sw_start = get_cycles();
            int digit_sw = lenet5_infer(0);  /* use_hw = 0 */
            uint32_t sw_cycles = get_cycles() - sw_start;
            mmio_write32(LENET_ADDR(LENET_DDR_SW_CYCLES_OFF), sw_cycles);

            /* Write predicted digit (HW + SW) */
            mmio_write32(LENET_ADDR(LENET_DDR_PREDICTED_OFF), (uint32_t)digit_hw);
            mmio_write32(LENET_ADDR(LENET_DDR_PREDICTED_SW_OFF), (uint32_t)digit_sw);

#if RUN_RELIABILITY_DEMO
            /* Phase 5: demo 4-config reliability (ghi REL fields trước khi PASS) */
            reliability_demo(REL_FAULT_BIT, REL_FAULT_TRIG);
#endif

            /* Báo PS ảnh xong (predicted đã ghi xong trước PASS) */
            mmio_write32(LENET_ADDR(LENET_DDR_MAILBOX_OFF), RAAS_MBX_PASS);
        }
        /* loop back, chờ GO cho ảnh kế */
    }
    return 0;  /* unreachable */
}

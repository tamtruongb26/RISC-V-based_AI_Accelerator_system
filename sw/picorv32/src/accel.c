/******************************************************************************
 * accel.c — Accelerator AXI-Lite control implementation
 *
 * Plan ref: §8.3 (Step 14.3).
 ******************************************************************************/

#include "accel.h"
#include "io.h"
#include "raas_map.h"

/* Helper: write reg ở offset relative tới ACCEL_BASE */
static inline void accel_write(uint32_t offset, uint32_t value)
{
    mmio_write32(RAAS_PICO_ACCEL_BASE + offset, value);
}

static inline uint32_t accel_read(uint32_t offset)
{
    return mmio_read32(RAAS_PICO_ACCEL_BASE + offset);
}

void accel_configure(uint32_t M, uint32_t K, uint32_t N, uint32_t act_mode)
{
    accel_write(RAAS_ACCEL_TILE_M, M);
    accel_write(RAAS_ACCEL_TILE_K, K);
    accel_write(RAAS_ACCEL_TILE_N, N);

    /* Pre-write CTRL với act_mode nhưng KHÔNG set START.
     * START sẽ được pulse riêng ở accel_start() để đảm bảo data path đã setup. */
    accel_write(RAAS_ACCEL_CTRL, act_mode & RAAS_CTRL_ACT_MASK);

    fence_iorw();   /* đảm bảo config writes hoàn thành trước khi start */
}

void accel_start(void)
{
    /* Đọc CTRL hiện tại để giữ act_mode bits, rồi pulse START.
     * Hardware tự clear START bit sau 1 cycle (auto-clear logic trong AXI shim). */
    uint32_t ctrl = accel_read(RAAS_ACCEL_CTRL);
    accel_write(RAAS_ACCEL_CTRL, ctrl | RAAS_CTRL_START);
    fence_iorw();
}

int accel_wait_done(uint32_t timeout_cycles)
{
    for (uint32_t i = 0; i < timeout_cycles; i++) {
        uint32_t status = accel_read(RAAS_ACCEL_STATUS);
        if (status & RAAS_STATUS_DONE) {
            return 0;
        }
    }
    return -1;
}

uint32_t accel_get_status(void)
{
    return accel_read(RAAS_ACCEL_STATUS);
}

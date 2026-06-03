/******************************************************************************
 * accel.c — Accelerator AXI-Lite control implementation (Phase 0 layout)
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

/* ── Config + start ────────────────────────────────────────────────────── */

void accel_configure(uint32_t M, uint32_t K, uint32_t N, uint32_t act_mode)
{
    /* Ghi CFG nhưng KHÔNG set START bit. */
    accel_write(RAAS_ACCEL_CFG, RAAS_CFG_PACK(M, K, N, act_mode));
    fence_iorw();
}

void accel_start(void)
{
    /* Read CFG hiện tại, OR với START_BIT, write back.
     * Hardware tự clear START sau 1 cycle. */
    uint32_t cfg = accel_read(RAAS_ACCEL_CFG);
    accel_write(RAAS_ACCEL_CFG, cfg | RAAS_CFG_START_BIT);
    fence_iorw();
}

void accel_configure_and_start(uint32_t M, uint32_t K, uint32_t N, uint32_t act_mode)
{
    /* Pack toàn bộ + START vào 1 word, 1 AXI-Lite write. */
    accel_write(RAAS_ACCEL_CFG,
                RAAS_CFG_PACK(M, K, N, act_mode) | RAAS_CFG_START_BIT);
    fence_iorw();
}

/* ── Status polling ────────────────────────────────────────────────────── */

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

/* ── Counter readback ──────────────────────────────────────────────────── */

void accel_counters_clear(void)
{
    accel_write(RAAS_ACCEL_CNT_CLEAR, RAAS_CNT_CLEAR_PULSE);
    fence_iorw();
}

uint32_t accel_counter_read(uint32_t idx)
{
    if (idx >= RAAS_CNT_COUNT) return 0;
    accel_write(RAAS_ACCEL_CNT_SEL, idx);
    fence_iorw();
    return accel_read(RAAS_ACCEL_CNT_VAL);
}

void accel_counters_snapshot(accel_counters_t *out)
{
    out->idle      = accel_counter_read(RAAS_CNT_IDX_IDLE);
    out->load_w    = accel_counter_read(RAAS_CNT_IDX_LOAD_W);
    out->load_b    = accel_counter_read(RAAS_CNT_IDX_LOAD_B);
    out->load_in   = accel_counter_read(RAAS_CNT_IDX_LOAD_IN);
    out->compute   = accel_counter_read(RAAS_CNT_IDX_COMPUTE);
    out->post_proc = accel_counter_read(RAAS_CNT_IDX_POST_PROC);
    out->send      = accel_counter_read(RAAS_CNT_IDX_SEND);
    out->done      = accel_counter_read(RAAS_CNT_IDX_DONE);
    out->total     = accel_counter_read(RAAS_CNT_IDX_TOTAL);
    out->pe_active = accel_counter_read(RAAS_CNT_IDX_PE_ACTIVE);
}

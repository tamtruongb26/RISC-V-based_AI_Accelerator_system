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

void accel_configure_and_start_flags(uint32_t M, uint32_t K, uint32_t N,
                                     uint32_t act_mode, uint32_t flags)
{
    accel_write(RAAS_ACCEL_CFG,
                RAAS_CFG_PACK(M, K, N, act_mode) | RAAS_CFG_START_BIT | flags);
    fence_iorw();
}

/* ── Phase 2a: HW im2col mode ──────────────────────────────────────────── */

void accel_im2col_config(uint32_t cfg0, uint32_t cfg1)
{
    accel_write(RAAS_ACCEL_IM2COL_CFG0, cfg0);
    accel_write(RAAS_ACCEL_IM2COL_CFG1, cfg1);
    fence_iorw();
}

void accel_start_im2col(void)
{
    accel_write(RAAS_ACCEL_CFG, RAAS_CFG_IM2COL_MODE | RAAS_CFG_START_BIT);
    fence_iorw();
}

/* Phase 2c autonomy: ghi descriptor + AUTO_GO. accelerator tự duyệt tile,
 * tự lập trình DMA. act_mode = RAAS_CFG_ACT_* (đã shift). KHÔNG set START
 * (auto_seq tự drive start cho control_unit). */
void accel_gemm_auto_start(uint32_t tiles, uint32_t in_base,
                           uint32_t out_base, uint32_t act_mode)
{
    accel_write(RAAS_ACCEL_IM2COL_CFG0,   tiles);      /* {n,m,k} */
    accel_write(RAAS_ACCEL_IM2COL_CFG1,   in_base);
    accel_write(RAAS_ACCEL_DESC_OUT_BASE, out_base);
    fence_iorw();
    accel_write(RAAS_ACCEL_CFG, act_mode | RAAS_CFG_AUTO_GO);
    fence_iorw();
}

/* Phase 2b: HW maxpool — cfg0 = (C<<16)|(W<<8)|H (tái dùng IM2COL_CFG0). */
void accel_start_pool(uint32_t cfg0)
{
    accel_write(RAAS_ACCEL_IM2COL_CFG0, cfg0);
    fence_iorw();
    accel_write(RAAS_ACCEL_CFG, RAAS_CFG_POOL_MODE | RAAS_CFG_START_BIT);
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
    return -3;  /* -3 = accel timeout (distinct from DMA: -1=timeout, -2=error) */
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
    out->sparsity_skip = accel_counter_read(RAAS_CNT_IDX_SPARSITY);
}

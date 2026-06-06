/******************************************************************************
 * accel.h — Accelerator AXI-Lite control API (Phase 0 register-packed layout)
 *
 * Phase 0 thay đổi: 5 register cũ (TILE_M/K/N/CTRL/STATUS) được pack lại còn
 * 1 CONFIG_PACKED register. Workflow:
 *
 *   // Cách cũ: 4 MMIO writes
 *   //   accel_configure(M, K, N, ACT) → 3 writes (M, K, N) + 1 write (CTRL)
 *   //   accel_start()                 → 1 read + 1 write (set START bit)
 *   // Tổng: 6 MMIO accesses / tile
 *
 *   // Cách mới: 1 MMIO write
 *   accel_configure_and_start(M, K, N, RAAS_CFG_ACT_BYPASS);
 *   // ... drive AXIS data via DMA ...
 *   if (accel_wait_done(timeout) < 0) handle_timeout();
 *
 * Phase 0 cũng thêm counter readback indirect (CNT_SEL/CNT_VAL) — xem
 * accel_counter_read(). Counters tự increment khi accelerator chạy.
 ******************************************************************************/
#ifndef RAAS_ACCEL_H
#define RAAS_ACCEL_H

#include <stdint.h>
#include "raas_map.h"

/* ── Configuration + start ─────────────────────────────────────────────── */

/* Cấu hình tile size + activation mode (chưa start).
 *   M, K, N: 1..8 (4-bit fields trong CONFIG_PACKED)
 *   act_mode: RAAS_CFG_ACT_BYPASS / _ACT_RELU / _ACT_SIGMOID */
void accel_configure(uint32_t M, uint32_t K, uint32_t N, uint32_t act_mode);

/* Pulse START bit (one-shot, hardware tự clear sau 1 cycle).
 *   FSM transition: IDLE → LOAD_W_RECV.
 *   Gọi sau khi đã accel_configure(). */
void accel_start(void);

/* Fused: cấu hình + start trong 1 AXI-Lite write. Đây là path nhanh nhất, giảm
 * MMIO overhead ~6× so với cách cũ. Khuyến nghị dùng cái này trong hot loop. */
void accel_configure_and_start(uint32_t M, uint32_t K, uint32_t N, uint32_t act_mode);

/* Như trên nhưng OR thêm flags (RAAS_CFG_ACC_ACCUM / RAAS_CFG_POST_SKIP) cho
 * HW K-accumulation. K-tile 0: flags=0; K-tile>0: ACC_ACCUM; K-tile không-cuối
 * thêm POST_SKIP. */
void accel_configure_and_start_flags(uint32_t M, uint32_t K, uint32_t N,
                                     uint32_t act_mode, uint32_t flags);

/* ── Phase 2a: HW im2col mode ──────────────────────────────────────────── */

/* Ghi 2 register cấu hình im2col (IM2COL_CFG0/CFG1 đã pack sẵn). */
void accel_im2col_config(uint32_t cfg0, uint32_t cfg1);

/* Start chế độ im2col (CFG = IM2COL_MODE | START, 1 write). */
void accel_start_im2col(void);

/* ── Status polling ────────────────────────────────────────────────────── */

/* Poll STATUS.DONE bit cho đến khi set, hoặc timeout.
 *   Return: 0 = DONE, -1 = timeout.
 *   DONE bit là sticky → vẫn = 1 sau khi accelerator về IDLE. Sticky tự clear
 *   khi START write tiếp theo. */
int accel_wait_done(uint32_t timeout_cycles);

/* Đọc STATUS register raw (debug). */
uint32_t accel_get_status(void);

/* ── Phase 0 instrumentation: per-state cycle counters ─────────────────── */

/* Pulse CNT_CLEAR — reset toàn bộ counter (idle, load_w, ..., pe_active, total).
 * Gọi trước khi bắt đầu inference để đo từ 0. */
void accel_counters_clear(void);

/* Đọc 1 counter theo index (xem RAAS_CNT_IDX_* trong raas_map.h).
 * Mỗi call = 2 MMIO accesses (write CNT_SEL, read CNT_VAL).
 * Trả về 0 nếu idx out-of-range. */
uint32_t accel_counter_read(uint32_t idx);

/* Snapshot toàn bộ counter vào struct.
 * Khuyến nghị: clear → run inference → snapshot → ghi mailbox. */
typedef struct {
    uint32_t idle;
    uint32_t load_w;
    uint32_t load_b;
    uint32_t load_in;
    uint32_t compute;
    uint32_t post_proc;
    uint32_t send;
    uint32_t done;
    uint32_t total;
    uint32_t pe_active;
} accel_counters_t;

void accel_counters_snapshot(accel_counters_t *out);

#endif /* RAAS_ACCEL_H */

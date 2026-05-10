/******************************************************************************
 * accel.h — Accelerator AXI-Lite control API
 *
 * Wrapper quanh 5 register của accelerator_2.0 IP (AXI-Lite slave).
 * Address ở RAAS_PICO_ACCEL_BASE = 0x40000000.
 *
 * Workflow điển hình (Stage A: 1 tile bypass):
 *   accel_configure(8, 8, 8, RAAS_CTRL_ACT_BYPASS);
 *   accel_start();
 *   ... drive AXIS data via DMA ...
 *   if (accel_wait_done(timeout) < 0) handle_timeout();
 *
 * Plan ref: §8.3 (Step 14.3).
 ******************************************************************************/
#ifndef RAAS_ACCEL_H
#define RAAS_ACCEL_H

#include <stdint.h>

/* Cấu hình tile size + activation mode (chưa start).
 *   M, K, N: 1..8
 *   act_mode: RAAS_CTRL_ACT_BYPASS / _ACT_RELU / _ACT_SIGMOID */
void accel_configure(uint32_t M, uint32_t K, uint32_t N, uint32_t act_mode);

/* Pulse START bit (one-shot, hardware tự clear sau 1 cycle).
 *   FSM transition: IDLE → LOAD_W_RECV.
 *   Gọi sau khi đã accel_configure(). */
void accel_start(void);

/* Poll STATUS.DONE bit cho đến khi set, hoặc timeout.
 *   Return: 0 = DONE, -1 = timeout.
 *   DONE bit là sticky → vẫn = 1 sau khi accelerator về IDLE. Sticky tự clear
 *   khi START write tiếp theo. */
int accel_wait_done(uint32_t timeout_cycles);

/* Đọc STATUS register raw (debug). */
uint32_t accel_get_status(void);

#endif /* RAAS_ACCEL_H */

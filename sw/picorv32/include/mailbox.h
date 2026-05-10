/******************************************************************************
 * mailbox.h — Mailbox status writer
 *
 * PicoRV32 ghi status code vào DDR offset RAAS_DDR_MAILBOX_OFFSET (0x800).
 * PS app polls cùng địa chỉ (qua PS view DDR) sau khi Xil_DCacheInvalidateRange.
 *
 * Note: PicoRV32 access DDR qua HP0 là non-cached → write trực tiếp xuất hiện
 * ở DDR ngay (không cần fence trước poll, nhưng có fence để tránh compiler
 * reorder).
 *
 * Plan ref: §8.3 (Step 14.3).
 ******************************************************************************/
#ifndef RAAS_MAILBOX_H
#define RAAS_MAILBOX_H

#include <stdint.h>

/* Ghi giá trị magic vào mailbox @ DDR.
 *   value: RAAS_MBX_STARTED / _PASS / _FAIL / _DMA_TIMEOUT / _ACCEL_TIMEOUT */
void mailbox_set(uint32_t value);

#endif /* RAAS_MAILBOX_H */

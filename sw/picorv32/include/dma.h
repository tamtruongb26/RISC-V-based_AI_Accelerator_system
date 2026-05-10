/******************************************************************************
 * dma.h — AXI DMA control API (Simple Mode, no scatter-gather)
 *
 * Wraps Xilinx AXI DMA register interface (PG021).
 * Address ở RAAS_PICO_DMA_BASE = 0x40010000.
 *
 * 2 channel độc lập:
 *   MM2S: Memory-Mapped → Stream (DDR → AXIS master → accelerator S00_AXIS)
 *   S2MM: Stream → Memory-Mapped (accelerator M00_AXIS → AXIS slave → DDR)
 *
 * Workflow điển hình:
 *   dma_reset();
 *   dma_s2mm_recv(output_addr, length);   // arm receive trước
 *   dma_mm2s_send(weights_addr, length);  // kick off send
 *   dma_mm2s_wait(timeout);
 *   ... thêm mm2s send cho bias, input ...
 *   dma_s2mm_wait(timeout);                // đợi output về DDR
 *
 * Plan ref: §8.3 (Step 14.3).
 ******************************************************************************/
#ifndef RAAS_DMA_H
#define RAAS_DMA_H

#include <stdint.h>

/* Reset cả 2 channel. Block đến khi RESET bit auto-clear.
 *   Sau reset: DMACR.RUN=0, DMASR.HALTED=1, DMASR.IDLE=1. */
void dma_reset(void);

/* Kick off MM2S transfer (non-blocking).
 *   src_addr: DDR address (PicoRV32/DMA view, 0x10000000+offset)
 *   length_bytes: số byte truyền (multiple of 4 cho 32-bit AXIS) */
void dma_mm2s_send(uint32_t src_addr, uint32_t length_bytes);

/* Đợi MM2S transfer xong (poll DMASR.IDLE).
 *   Return: 0 = OK, -1 = timeout, -2 = DMASR error bit set */
int dma_mm2s_wait(uint32_t timeout_cycles);

/* Arm S2MM để nhận stream (non-blocking).
 *   dst_addr: DDR address
 *   length_bytes: max bytes có thể nhận */
void dma_s2mm_recv(uint32_t dst_addr, uint32_t length_bytes);

/* Đợi S2MM transfer xong. */
int dma_s2mm_wait(uint32_t timeout_cycles);

/* Combined send-and-wait helper (90% use case).
 *   Return: 0 = OK, -1/-2 = error */
int dma_mm2s_send_and_wait(uint32_t src_addr, uint32_t length_bytes,
                           uint32_t timeout_cycles);

/* Debug: read raw DMASR */
uint32_t dma_mm2s_get_status(void);
uint32_t dma_s2mm_get_status(void);

#endif /* RAAS_DMA_H */

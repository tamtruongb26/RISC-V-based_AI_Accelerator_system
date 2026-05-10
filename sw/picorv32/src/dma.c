/******************************************************************************
 * dma.c — AXI DMA control implementation (Simple Mode)
 *
 * AXI DMA programming sequence (PG021, Simple Mode):
 *
 *   Reset:
 *     1. Write DMACR.RESET = 1
 *     2. Poll DMACR.RESET (auto-clear)
 *
 *   MM2S transfer:
 *     1. DMACR.RUN = 1                (channel ready)
 *     2. Write SA_LO (+ SA_HI=0)      (source address)
 *     3. Write LENGTH                 (KICK off transfer)
 *     4. Poll DMASR.IDLE = 1          (done)
 *
 *   S2MM transfer: same pattern với DA_LO + LENGTH = max receive size.
 *
 * Plan ref: §8.3 (Step 14.3).
 ******************************************************************************/

#include "dma.h"
#include "io.h"
#include "raas_map.h"

/* ── Helpers: read/write reg với base = DMA_BASE + offset ──────────────── */
static inline void dma_write(uint32_t offset, uint32_t value)
{
    mmio_write32(RAAS_PICO_DMA_BASE + offset, value);
}

static inline uint32_t dma_read(uint32_t offset)
{
    return mmio_read32(RAAS_PICO_DMA_BASE + offset);
}

/* ────────────────────────────────────────────────────────────────────────
 * dma_reset — reset cả MM2S + S2MM
 * ──────────────────────────────────────────────────────────────────────── */
void dma_reset(void)
{
    /* RESET bit là self-clearing W1C. Set 1 → hardware reset → tự về 0. */
    dma_write(RAAS_DMA_MM2S_DMACR, RAAS_DMACR_RESET);
    dma_write(RAAS_DMA_S2MM_DMACR, RAAS_DMACR_RESET);

    /* Poll cho đến khi cả 2 channel reset xong (DMACR.RESET = 0). */
    uint32_t guard = 1000000u;
    while (guard--) {
        uint32_t mm2s_cr = dma_read(RAAS_DMA_MM2S_DMACR);
        uint32_t s2mm_cr = dma_read(RAAS_DMA_S2MM_DMACR);
        if (!(mm2s_cr & RAAS_DMACR_RESET) && !(s2mm_cr & RAAS_DMACR_RESET)) {
            break;
        }
    }
    fence_iorw();
}

/* ────────────────────────────────────────────────────────────────────────
 * Helper: poll DMASR.IDLE với timeout + error check
 *   Return: 0 = OK, -1 = timeout, -2 = error bit set
 * ──────────────────────────────────────────────────────────────────────── */
static int dma_wait_idle(uint32_t status_reg_offset, uint32_t timeout_cycles)
{
    const uint32_t error_mask =
        RAAS_DMASR_DMAINTERR | RAAS_DMASR_DMASLVERR | RAAS_DMASR_DMADECERR;

    for (uint32_t i = 0; i < timeout_cycles; i++) {
        uint32_t status = mmio_read32(RAAS_PICO_DMA_BASE + status_reg_offset);
        if (status & error_mask) {
            return -2;   /* error bit set */
        }
        if (status & RAAS_DMASR_IDLE) {
            return 0;    /* transfer done */
        }
    }
    return -1;           /* timeout */
}

/* ────────────────────────────────────────────────────────────────────────
 * MM2S: read DDR → stream out qua AXIS master tới accelerator
 * ──────────────────────────────────────────────────────────────────────── */
void dma_mm2s_send(uint32_t src_addr, uint32_t length_bytes)
{
    /* 1. Set RUN bit (start channel, vẫn idle vì chưa có length) */
    dma_write(RAAS_DMA_MM2S_DMACR, RAAS_DMACR_RUN);

    /* 2. Source address (low 32-bit; high reg = 0 cho safety) */
    dma_write(RAAS_DMA_MM2S_SA_LO, src_addr);
    dma_write(RAAS_DMA_MM2S_SA_HI, 0u);

    /* 3. LENGTH write triggers transfer kickoff */
    dma_write(RAAS_DMA_MM2S_LENGTH, length_bytes);

    fence_iorw();
}

int dma_mm2s_wait(uint32_t timeout_cycles)
{
    return dma_wait_idle(RAAS_DMA_MM2S_DMASR, timeout_cycles);
}

int dma_mm2s_send_and_wait(uint32_t src_addr, uint32_t length_bytes,
                           uint32_t timeout_cycles)
{
    dma_mm2s_send(src_addr, length_bytes);
    return dma_mm2s_wait(timeout_cycles);
}

/* ────────────────────────────────────────────────────────────────────────
 * S2MM: nhận stream từ accelerator → write DDR
 * ──────────────────────────────────────────────────────────────────────── */
void dma_s2mm_recv(uint32_t dst_addr, uint32_t length_bytes)
{
    dma_write(RAAS_DMA_S2MM_DMACR, RAAS_DMACR_RUN);
    dma_write(RAAS_DMA_S2MM_DA_LO, dst_addr);
    dma_write(RAAS_DMA_S2MM_DA_HI, 0u);
    dma_write(RAAS_DMA_S2MM_LENGTH, length_bytes);
    fence_iorw();
}

int dma_s2mm_wait(uint32_t timeout_cycles)
{
    return dma_wait_idle(RAAS_DMA_S2MM_DMASR, timeout_cycles);
}

/* Debug helpers */
uint32_t dma_mm2s_get_status(void) { return dma_read(RAAS_DMA_MM2S_DMASR); }
uint32_t dma_s2mm_get_status(void) { return dma_read(RAAS_DMA_S2MM_DMASR); }

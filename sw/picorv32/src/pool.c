/******************************************************************************
 * pool.c — Max-pool 2×2 stride 2 (software implementation)
 *
 * Pooling layers reduce spatial dimensions by selecting the maximum value
 * from each 2×2 block. This is a simple operation that runs entirely in
 * software on PicoRV32 — no accelerator or DMA needed.
 *
 * LeNet-5 uses this after Conv1 (24×24→12×12) and Conv2 (8×8→4×4).
 *
 * Input/Output stored in DDR as CHW (channel-first), Q1.4.11.
 ******************************************************************************/

#include "pool.h"
#include "io.h"
#include "accel.h"
#include "dma.h"

#define POOL_DMA_TIMEOUT    2000000u
#define POOL_ACCEL_TIMEOUT  2000000u

/* ── Helper: read/write Q1.4.11 from DDR ───────────────────────────── */
static inline int16_t rd16(uint32_t addr)
{
    uint32_t word = mmio_read32(addr & ~3u);
    return (addr & 2u) ? (int16_t)(word >> 16) : (int16_t)(word & 0xFFFF);
}

static inline void wr16(uint32_t addr, int16_t val)
{
    uint32_t aligned = addr & ~3u;
    uint32_t word = mmio_read32(aligned);
    if (addr & 2u)
        word = (word & 0x0000FFFF) | ((uint32_t)(uint16_t)val << 16);
    else
        word = (word & 0xFFFF0000) | (uint32_t)(uint16_t)val;
    mmio_write32(aligned, word);
}

static inline int16_t max16(int16_t a, int16_t b) { return a > b ? a : b; }

void maxpool2x2(uint32_t in_addr, uint32_t out_addr,
                uint32_t C, uint32_t H, uint32_t W)
{
    uint32_t H_out = H / 2u;
    uint32_t W_out = W / 2u;

    /*
     * For each channel, scan 2×2 non-overlapping blocks.
     *
     * Input layout:  in[c][h][w]  at offset (c*H*W + h*W + w) * 2
     * Output layout: out[c][h'][w'] at offset (c*H_out*W_out + h'*W_out + w') * 2
     */
    for (uint32_t c = 0; c < C; c++) {
        for (uint32_t h = 0; h < H_out; h++) {
            for (uint32_t w = 0; w < W_out; w++) {
                uint32_t base = (c * H * W) * 2u;
                uint32_t h2 = h * 2u;
                uint32_t w2 = w * 2u;

                /* Read 4 elements in the 2×2 block */
                int16_t v00 = rd16(in_addr + base + (h2 * W + w2) * 2u);
                int16_t v01 = rd16(in_addr + base + (h2 * W + w2 + 1) * 2u);
                int16_t v10 = rd16(in_addr + base + ((h2 + 1) * W + w2) * 2u);
                int16_t v11 = rd16(in_addr + base + ((h2 + 1) * W + w2 + 1) * 2u);

                /* Max of 4 */
                int16_t m = max16(max16(v00, v01), max16(v10, v11));

                /* Write output */
                uint32_t out_off = (c * H_out * W_out + h * W_out + w) * 2u;
                wr16(out_addr + out_off, m);
            }
        }
    }
}

/* Phase 2b: HW maxpool 2×2 (POOL mode). Stream FM [C×H×W] qua accelerator →
 * nhận [C×H/2×W/2]. Cùng signature maxpool2x2 (SW). */
int pool_hw(uint32_t in_addr, uint32_t out_addr, uint32_t C, uint32_t H, uint32_t W)
{
    /* BUG FIX: scratchpad u_sp_fm chỉ chứa SP_FM_DEPTH=1024 phần tử, nhưng
     * Pool1 FM = 6×24×24 = 3456 > 1024 → tràn → maxpool đọc rác.
     * Pool 2×2 ĐỘC LẬP theo kênh → xử lý TỪNG KÊNH (H×W ≤ 1024 luôn vừa:
     * Pool1 576, Pool2 64). Layout CHW giữ nguyên (kênh c → offset riêng). */
    uint32_t in_ch_bytes  = H * W * 2u;
    uint32_t out_ch_bytes = (H / 2u) * (W / 2u) * 2u;
    uint32_t cfg0 = (1u << 16) | (W << 8) | H;       /* C=1 mỗi lần */
    int rc;

    for (uint32_t c = 0; c < C; c++) {
        dma_reset();
        accel_start_pool(cfg0);                       /* → LOAD_FM, chờ AXIS */
        dma_s2mm_recv(out_addr + c * out_ch_bytes, out_ch_bytes);

        rc = dma_mm2s_send_and_wait(in_addr + c * in_ch_bytes, in_ch_bytes,
                                    POOL_DMA_TIMEOUT);
        if (rc < 0) return rc;
        rc = accel_wait_done(POOL_ACCEL_TIMEOUT);
        if (rc < 0) return rc;
        rc = dma_s2mm_wait(POOL_DMA_TIMEOUT);
        if (rc < 0) return rc;
    }
    return 0;
}

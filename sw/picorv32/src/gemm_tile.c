/******************************************************************************
 * gemm_tile.c — Tiled GEMM implementation for 8×8 systolic array
 *
 * Core algorithm:
 *   for each output tile (n_tile, m_tile):
 *     clear accumulator
 *     for each k_tile:
 *       1. Copy sub-matrices from DDR → tile staging buffers (pad to 8×8)
 *       2. Send to accelerator via DMA (weights → bias_zeros → input)
 *       3. Receive tile output via DMA
 *       4. Accumulate into C_acc (software add, Q1.4.11)
 *     Apply bias + activation on accumulated result
 *     Write back to DDR output
 *
 * Why software accumulation?
 *   The accelerator's post-proc pipeline applies bias+activation per tile.
 *   But when K > 8, we need to sum partial products across multiple K-tiles
 *   BEFORE applying bias/activation. So we send bias=0 to the accelerator
 *   and handle bias+activation in software after all K-tiles are done.
 ******************************************************************************/

#include "gemm_tile.h"
#include "lenet_map.h"
#include "raas_map.h"
#include "accel.h"
#include "dma.h"
#include "io.h"

/* Tile size = systolic array dimension */
#define SA 8u

/* DMA/accel timeout */
#define TILE_DMA_TIMEOUT    200000u
#define TILE_ACCEL_TIMEOUT  500000u

/* ── Helper: read/write Q1.4.11 element from DDR ────────────────────────
 * DDR stores packed 2×u16 per u32 word. We need byte-level access.
 * PicoRV32 memory is byte-addressable via AXI, so we can read 16-bit.
 * ──────────────────────────────────────────────────────────────────────── */
static inline int16_t ddr_read16(uint32_t addr)
{
    /* Read 32-bit word, extract correct half */
    uint32_t word = mmio_read32(addr & ~3u);
    if (addr & 2u)
        return (int16_t)(word >> 16);
    else
        return (int16_t)(word & 0xFFFF);
}

static inline void ddr_write16(uint32_t addr, int16_t val)
{
    uint32_t aligned = addr & ~3u;
    uint32_t word = mmio_read32(aligned);
    if (addr & 2u)
        word = (word & 0x0000FFFF) | ((uint32_t)(uint16_t)val << 16);
    else
        word = (word & 0xFFFF0000) | (uint32_t)(uint16_t)val;
    mmio_write32(aligned, word);
}

/* ── Helper: min ─────────────────────────────────────────────────────── */
static inline uint32_t umin(uint32_t a, uint32_t b) { return a < b ? a : b; }

/* ── Helper: clear tile buffer (fill with zeros) ─────────────────────── */
static void tile_clear(uint32_t addr, uint32_t words)
{
    for (uint32_t i = 0; i < words; i++)
        mmio_write32(addr + i * 4u, 0u);
}

/* ── Helper: copy sub-matrix from large DDR matrix → tile staging buf ──
 *
 * Copies a sub-block of size (rows × cols) from a row-major matrix
 * of width `stride` starting at `src_addr`, into an 8×8 tile buffer
 * at `dst_addr`. Elements outside (rows, cols) are zero-padded.
 *
 * Each element is Q1.4.11 = 16-bit. Tile buffer stores packed 2×u16.
 * ──────────────────────────────────────────────────────────────────────── */
static void copy_sub_to_tile(uint32_t src_addr, uint32_t src_stride,
                             uint32_t dst_addr,
                             uint32_t rows, uint32_t cols)
{
    /* Clear entire 8×8 tile first (8 rows × 4 words/row = 32 words) */
    tile_clear(dst_addr, 32u);

    for (uint32_t r = 0; r < rows; r++) {
        for (uint32_t c = 0; c < cols; c++) {
            /* Read from source matrix: element at (r, c) */
            uint32_t src_off = (r * src_stride + c) * 2u;  /* 2 bytes per element */
            int16_t val = ddr_read16(src_addr + src_off);

            /* Write to tile buffer: element at (r, c) in 8-wide row */
            uint32_t dst_off = (r * SA + c) * 2u;
            ddr_write16(dst_addr + dst_off, val);
        }
    }
}

/* ── Main tiled GEMM ─────────────────────────────────────────────────── */
int gemm_tiled(uint32_t a_addr, uint32_t w_addr, uint32_t b_addr,
               uint32_t c_addr,
               uint32_t M, uint32_t K, uint32_t N,
               uint32_t act_mode)
{
    /* Tile staging buffer addresses (from lenet_map.h) */
    uint32_t tile_w   = LENET_ADDR(LENET_DDR_TILE_W_OFF);
    uint32_t tile_b   = LENET_ADDR(LENET_DDR_TILE_B_OFF);
    uint32_t tile_in  = LENET_ADDR(LENET_DDR_TILE_IN_OFF);
    uint32_t tile_out = LENET_ADDR(LENET_DDR_TILE_OUT_OFF);

    int rc;

    /* Iterate over output tiles */
    for (uint32_t n0 = 0; n0 < N; n0 += SA) {
        uint32_t n_size = umin(SA, N - n0);

        for (uint32_t m0 = 0; m0 < M; m0 += SA) {
            uint32_t m_size = umin(SA, M - m0);

            /* ── Zero the accumulator for this (m,n) output tile ──── */
            /* We accumulate in the output area of DDR directly.
             * Clear the sub-block C[m0..m0+m_size, n0..n0+n_size]. */
            for (uint32_t r = 0; r < m_size; r++) {
                for (uint32_t c = 0; c < n_size; c++) {
                    uint32_t out_off = ((m0 + r) * N + (n0 + c)) * 2u;
                    ddr_write16(c_addr + out_off, 0);
                }
            }

            /* ── K-tile loop: accumulate partial GEMMs ──────────── */
            for (uint32_t k0 = 0; k0 < K; k0 += SA) {
                uint32_t k_size = umin(SA, K - k0);

                /* 1. Copy sub-weight W[k0:+k_size, n0:+n_size] → tile_w
                 *    W is [K × N] row-major. */
                copy_sub_to_tile(w_addr + (k0 * N + n0) * 2u, N,
                                 tile_w, k_size, n_size);

                /* 2. Copy sub-input A[m0:+m_size, k0:+k_size] → tile_in
                 *    A is [M × K] row-major. */
                copy_sub_to_tile(a_addr + (m0 * K + k0) * 2u, K,
                                 tile_in, m_size, k_size);

                /* 3. Bias = zeros (we add bias in software after all K) */
                tile_clear(tile_b, 4u);

                /* 4. Reset DMA for this tile */
                dma_reset();

                /* 5. Configure accelerator */
                accel_configure(SA, SA, SA, RAAS_CTRL_ACT_BYPASS);
                accel_start();

                /* 6. Arm S2MM to receive output */
                dma_s2mm_recv(tile_out, SA * SA * 2u / 2u * 2u);
                /* = 8×8 elements × 2 bytes / 2 per word × 4 bytes = 128 bytes */

                /* 7. Stream weights → bias → input via MM2S */
                /* Weights: 8 rows × ceil(8/2) words × 4 bytes = 128 bytes */
                rc = dma_mm2s_send_and_wait(tile_w, SA * (SA / 2u) * 4u,
                                            TILE_DMA_TIMEOUT);
                if (rc < 0) return rc;

                /* Bias: ceil(8/2) words × 4 bytes = 16 bytes */
                rc = dma_mm2s_send_and_wait(tile_b, (SA / 2u) * 4u,
                                            TILE_DMA_TIMEOUT);
                if (rc < 0) return rc;

                /* Input: 8 rows × ceil(8/2) words × 4 bytes = 128 bytes */
                rc = dma_mm2s_send_and_wait(tile_in, SA * (SA / 2u) * 4u,
                                            TILE_DMA_TIMEOUT);
                if (rc < 0) return rc;

                /* 8. Wait accelerator DONE */
                rc = accel_wait_done(TILE_ACCEL_TIMEOUT);
                if (rc < 0) return rc;

                /* 9. Wait S2MM done */
                rc = dma_s2mm_wait(TILE_DMA_TIMEOUT);
                if (rc < 0) return rc;

                /* 10. Accumulate tile output into C[m0..., n0...]
                 *     Read from tile_out, add to C. */
                for (uint32_t r = 0; r < m_size; r++) {
                    for (uint32_t c = 0; c < n_size; c++) {
                        uint32_t to = (r * SA + c) * 2u;
                        int16_t partial = ddr_read16(tile_out + to);

                        uint32_t co = ((m0 + r) * N + (n0 + c)) * 2u;
                        int16_t acc = ddr_read16(c_addr + co);

                        /* Q1.4.11 saturating add */
                        int32_t sum = (int32_t)acc + (int32_t)partial;
                        if (sum > 32767) sum = 32767;
                        if (sum < -32768) sum = -32768;

                        ddr_write16(c_addr + co, (int16_t)sum);
                    }
                }
            } /* end k_tile loop */

            /* ── Post K-accumulation: add bias + activation ────── */
            for (uint32_t r = 0; r < m_size; r++) {
                for (uint32_t c = 0; c < n_size; c++) {
                    uint32_t co = ((m0 + r) * N + (n0 + c)) * 2u;
                    int32_t val = (int32_t)ddr_read16(c_addr + co);

                    /* Add bias (once, after all K-tiles) */
                    if (b_addr != 0u) {
                        int16_t bias_val = ddr_read16(b_addr + (n0 + c) * 2u);
                        val += (int32_t)bias_val;
                    }

                    /* Saturate */
                    if (val > 32767) val = 32767;
                    if (val < -32768) val = -32768;

                    /* Activation */
                    if (act_mode == RAAS_CTRL_ACT_RELU && val < 0)
                        val = 0;

                    ddr_write16(c_addr + co, (int16_t)val);
                }
            }

        } /* end m_tile loop */
    } /* end n_tile loop */

    return 0;
}

/* ── Pure Software GEMM (for benchmarking) ───────────────────────────── */
int gemm_sw(uint32_t a_addr, uint32_t w_addr, uint32_t b_addr,
            uint32_t c_addr,
            uint32_t M, uint32_t K, uint32_t N,
            uint32_t act_mode)
{
    for (uint32_t m = 0; m < M; m++) {
        for (uint32_t n = 0; n < N; n++) {
            int32_t acc = 0;
            for (uint32_t k = 0; k < K; k++) {
                int16_t a_val = ddr_read16(a_addr + (m * K + k) * 2u);
                int16_t w_val = ddr_read16(w_addr + (k * N + n) * 2u);
                acc += (int32_t)a_val * (int32_t)w_val;
            }
            acc >>= 11; /* Q2.8.22 -> Q1.8.7 -> Q1.4.11 */
            
            if (b_addr != 0u) {
                int16_t b_val = ddr_read16(b_addr + n * 2u);
                acc += (int32_t)b_val;
            }
            
            if (acc > 32767) acc = 32767;
            if (acc < -32768) acc = -32768;
            
            if (act_mode == RAAS_CTRL_ACT_RELU && acc < 0) {
                acc = 0;
            }
            
            ddr_write16(c_addr + (m * N + n) * 2u, (int16_t)acc);
        }
    }
    return 0;
}

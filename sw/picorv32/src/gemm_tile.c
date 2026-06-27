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

/* Phase 1a-ii-C: số M-tile trong 1 block (blocking). PHẢI khớp param HW
 * control_unit NUM_SLOTS. Weight nạp 1 lần/k0, reuse qua nslots slot. */
#define NUM_SLOTS 4u

/* DMA/accel timeout */
#define TILE_DMA_TIMEOUT    200000u
#define TILE_ACCEL_TIMEOUT  500000u
/* OS mode streams up to 32 k-tiles × 144B = 4608B per N-tile;
 * give DMA 10× more budget than normal tile. */
#define OS_DMA_TIMEOUT      2000000u
#define OS_ACCEL_TIMEOUT    5000000u

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

    /* Iterate: n-tile → block của M-tile → K-tile → slot trong block.
     *
     * Phase 1a-ii-C blocking (weight-stationary):
     *   - Mỗi k0 nạp weight W[k0,n0] 1 lần (slot 0); các slot sau reuse
     *     (SKIP_W_LOAD, KHÔNG push weight) → cắt DDR weight ~nslots× (Conv).
     *   - psum cộng dồn ở 40-bit trong accelerator, vào slot riêng (ACC_SLOT).
     *   - K-tile cuối: post_proc (+bias +act) + send cho từng slot → C.
     *   - K-accumulation (1a-i): k0==0 ghi đè, k0>0 cộng dồn. */
    for (uint32_t n0 = 0; n0 < N; n0 += SA) {
        uint32_t n_size = umin(SA, N - n0);

        for (uint32_t m_blk = 0; m_blk < M; m_blk += SA * NUM_SLOTS) {
            uint32_t blk_rows = umin(SA * NUM_SLOTS, M - m_blk);
            uint32_t nslots   = (blk_rows + SA - 1u) / SA;   /* M-tile trong block */

            for (uint32_t k0 = 0; k0 < K; k0 += SA) {
                uint32_t k_size = umin(SA, K - k0);
                uint32_t last_k = (k0 + SA >= K);

                /* Weight tile W[k0,n0] — chung cho mọi slot trong block,
                 * nạp staging 1 lần (push chỉ ở slot 0). */
                copy_sub_to_tile(w_addr + (k0 * N + n0) * 2u, N,
                                 tile_w, k_size, n_size);

                /* Bias tile (chỉ dùng ở K-tile cuối) */
                tile_clear(tile_b, 4u);
                if (last_k && b_addr != 0u) {
                    for (uint32_t c = 0; c < n_size; c++) {
                        int16_t bv = ddr_read16(b_addr + (n0 + c) * 2u);
                        ddr_write16(tile_b + c * 2u, bv);
                    }
                }

                for (uint32_t s = 0; s < nslots; s++) {
                    uint32_t m0      = m_blk + s * SA;
                    uint32_t m_size  = umin(SA, M - m0);
                    uint32_t reuse_w = (s != 0u);   /* slot 0 nạp W, sau reuse */

                    uint32_t flags = (k0 == 0u ? 0u : RAAS_CFG_ACC_ACCUM)
                                   | (last_k    ? 0u : RAAS_CFG_POST_SKIP)
                                   | (reuse_w   ? RAAS_CFG_SKIP_W_LOAD : 0u)
                                   | RAAS_CFG_ACC_SLOT(s);
                    uint32_t this_act = last_k ? act_mode : RAAS_CFG_ACT_BYPASS;

                    /* Input tile A[m0:+m_size, k0:+k_size] (riêng mỗi slot) */
                    copy_sub_to_tile(a_addr + (m0 * K + k0) * 2u, K,
                                     tile_in, m_size, k_size);

                    dma_reset();
                    accel_configure_and_start_flags(SA, SA, SA, this_act, flags);

                    if (last_k)
                        dma_s2mm_recv(tile_out, SA * SA * 2u / 2u * 2u);

                    /* Weight chỉ push khi KHÔNG reuse (slot 0). reuse →
                     * accelerator skip LOAD_W nên tuyệt đối không push weight. */
                    if (!reuse_w) {
                        rc = dma_mm2s_send_and_wait(tile_w, SA * (SA / 2u) * 4u,
                                                    TILE_DMA_TIMEOUT);
                        if (rc < 0) return rc;
                    }
                    rc = dma_mm2s_send_and_wait(tile_b, (SA / 2u) * 4u,
                                                TILE_DMA_TIMEOUT);
                    if (rc < 0) return rc;
                    rc = dma_mm2s_send_and_wait(tile_in, SA * (SA / 2u) * 4u,
                                                TILE_DMA_TIMEOUT);
                    if (rc < 0) return rc;

                    rc = accel_wait_done(TILE_ACCEL_TIMEOUT);
                    if (rc < 0) return rc;

                    /* K-tile cuối: nhận output (đã +bias +act) → C[m0,n0] */
                    if (last_k) {
                        rc = dma_s2mm_wait(TILE_DMA_TIMEOUT);
                        if (rc < 0) return rc;
                        for (uint32_t r = 0; r < m_size; r++) {
                            for (uint32_t c = 0; c < n_size; c++) {
                                uint32_t to = (r * SA + c) * 2u;
                                uint32_t co = ((m0 + r) * N + (n0 + c)) * 2u;
                                ddr_write16(c_addr + co, ddr_read16(tile_out + to));
                            }
                        }
                    }
                } /* end slot loop */
            } /* end k_tile loop */
        } /* end m_block loop */
    } /* end n_tile loop */

    return 0;
}

/* ── Phase 3a/3b: Output-Stationary GEMM cho FC (M=1) — util 12.5%→100% ───
 * Map K→hàng, N→cột; mỗi cycle 64 MAC song song. C[1×N] = A[1×K] × W[K×N].
 *
 * Phase 3b CISC: gom TẤT CẢ K-tile vào 1 invocation/N-tile. HW tự lặp K-tile
 * nội bộ (số K-tile qua IM2COL_CFG0), cộng dồn psum. Stream 1 lần liền mạch
 * [W(32w) a(4w)]×k_tiles. → FC1 480 invocation → 15 (cắt overhead orchestration).
 * KHÔNG bias (OS clear bias=0; bias cộng SW nếu cần). */
int gemm_os(uint32_t a_addr, uint32_t w_addr, uint32_t c_addr,
            uint32_t K, uint32_t N, uint32_t act_mode)
{
    uint32_t stream   = LENET_ADDR(LENET_DDR_OS_STAGE_OFF);
    uint32_t tile_out = LENET_ADDR(LENET_DDR_TILE_OUT_OFF);
    uint32_t k_tiles  = (K + SA - 1u) / SA;
    /* byte/K-tile = (64 W + 8 a) elem × 2B = 144B (= 36 word) */
    uint32_t stream_bytes = k_tiles * (SA * SA + SA) * 2u;
    int rc;

    for (uint32_t n0 = 0; n0 < N; n0 += SA) {
        uint32_t n_size = umin(SA, N - n0);

        /* ── Dựng stream interleaved [W tile | a-vector]×k_tiles ── */
        uint32_t soff = stream;
        for (uint32_t k0 = 0; k0 < K; k0 += SA) {
            uint32_t k_size = umin(SA, K - k0);
            /* W tile W[k0,n0] → 8×8 (64 elem), copy_sub_to_tile tự zero-pad */
            copy_sub_to_tile(w_addr + (k0 * N + n0) * 2u, N, soff, k_size, n_size);
            soff += SA * SA * 2u;                       /* +64 elem */
            /* a-vector A[0, k0:+k_size] → 8 elem (zero-pad phần thừa) */
            for (uint32_t i = 0; i < SA; i++)
                ddr_write16(soff + i * 2u,
                            i < k_size ? ddr_read16(a_addr + (k0 + i) * 2u) : 0);
            soff += SA * 2u;                            /* +8 elem */
        }

        /* Debug: ghi tile info để dump lỗi biết N-tile nào fail */
        mmio_write32(LENET_ADDR(LENET_DDR_ERR_TILE_N0_OFF), n0);
        mmio_write32(LENET_ADDR(LENET_DDR_ERR_TILE_K0_OFF), k_tiles);

        /* BUG FIX: dma_reset() TRƯỚC accel_im2col_config() để đảm bảo
         * IM2COL_CFG0 (os_ktiles) không bị overwrite bởi pool_hw stale state.
         * Thứ tự đúng: reset → config os_ktiles → start accel → arm DMA. */
        dma_reset();
        accel_im2col_config(k_tiles, 0u);   /* IM2COL_CFG0 = số K-tile (OS reuse) */
        /* DIAG (tạm): đọc lại IM2COL_CFG0 → ghi vào field dump "n0".
         * Khi lỗi, PS in "Tile n0=X": X=k_tiles(32)→register OK (HW logic stale,
         * cần re-synth IP); X=0→write không tới reg5 (vấn đề khác). */
        mmio_write32(LENET_ADDR(LENET_DDR_ERR_TILE_N0_OFF),
                     mmio_read32(RAAS_PICO_ACCEL_BASE + RAAS_ACCEL_IM2COL_CFG0));
        accel_configure_and_start_flags(1u, SA, SA, act_mode, RAAS_CFG_OS_MODE);
        dma_s2mm_recv(tile_out, SA * 2u);    /* M=1×N=8 → 4 word */

        /* OS mode gửi k_tiles × 144B (tối đa 4608B cho FC1) → dùng OS_DMA_TIMEOUT */
        rc = dma_mm2s_send_and_wait(stream, stream_bytes, OS_DMA_TIMEOUT);
        if (rc < 0) return rc;
        rc = accel_wait_done(OS_ACCEL_TIMEOUT);
        if (rc < 0) return rc;
        rc = dma_s2mm_wait(OS_DMA_TIMEOUT);
        if (rc < 0) return rc;

        for (uint32_t c = 0; c < n_size; c++)
            ddr_write16(c_addr + (n0 + c) * 2u, ddr_read16(tile_out + c * 2u));
    }
    return 0;
}

/* ── Phase 2c: GEMM tự hành (autonomy) — accelerator tự duyệt tile + DMA ──
 * Pico stage TẤT CẢ tile thành block liền mạch [W64|bias8|A64] (272B) theo
 * thứ tự (n,m,k), ghi descriptor + AUTO_GO, rồi CHỜ 1 lần. accelerator tự
 * lặp m/k/n + tự lập trình DMA → bỏ ~mt·kt·nt lần Pico orchestrate.
 * Bias chỉ dùng ở K-tile cuối (HW post_proc); stage mọi tile cho đồng đều.
 * Output tile 8×8 row-major (128B/tile) → de-tile về C[M×N]. */
#define AUTO_ACCEL_TIMEOUT  200000000u   /* cả GEMM trong 1 invocation */
int gemm_auto(uint32_t a_addr, uint32_t w_addr, uint32_t b_addr, uint32_t c_addr,
              uint32_t M, uint32_t K, uint32_t N, uint32_t act_mode)
{
    uint32_t mt = (M + SA - 1u) / SA;
    uint32_t kt = (K + SA - 1u) / SA;
    uint32_t nt = (N + SA - 1u) / SA;
    uint32_t in_stage  = LENET_ADDR(LENET_DDR_AUTO_IN_OFF);
    uint32_t out_stage = LENET_ADDR(LENET_DDR_AUTO_OUT_OFF);
    int rc;

    /* ── Stage block input theo thứ tự (n,m,k) khớp auto_seq ── */
    uint32_t blk = in_stage;
    for (uint32_t n0 = 0; n0 < N; n0 += SA) {
        uint32_t ns = umin(SA, N - n0);
        for (uint32_t m0 = 0; m0 < M; m0 += SA) {
            uint32_t ms = umin(SA, M - m0);
            for (uint32_t k0 = 0; k0 < K; k0 += SA) {
                uint32_t ks = umin(SA, K - k0);
                /* W tile [ks×ns] → 8×8 (zero-pad) = 64 elem */
                copy_sub_to_tile(w_addr + (k0 * N + n0) * 2u, N, blk, ks, ns);
                blk += SA * SA * 2u;
                /* bias [ns] → 8 elem (zero-pad; HW chỉ cộng ở K cuối) */
                for (uint32_t i = 0; i < SA; i++)
                    ddr_write16(blk + i * 2u,
                                (i < ns && b_addr) ? ddr_read16(b_addr + (n0 + i) * 2u) : 0);
                blk += SA * 2u;
                /* A tile [ms×ks] → 8×8 = 64 elem */
                copy_sub_to_tile(a_addr + (m0 * K + k0) * 2u, K, blk, ms, ks);
                blk += SA * SA * 2u;
            }
        }
    }

    /* ── Descriptor + AUTO_GO → chờ DONE (cả GEMM) ── */
    accel_gemm_auto_start(RAAS_DESC_TILES(nt, mt, kt), in_stage, out_stage, act_mode);
    rc = accel_wait_done(AUTO_ACCEL_TIMEOUT);
    if (rc < 0) return rc;

    /* ── De-tile output (8×8 row-major/tile, thứ tự n,m) về C[M×N] ── */
    uint32_t oblk = out_stage;
    for (uint32_t n0 = 0; n0 < N; n0 += SA) {
        uint32_t ns = umin(SA, N - n0);
        for (uint32_t m0 = 0; m0 < M; m0 += SA) {
            uint32_t ms = umin(SA, M - m0);
            for (uint32_t mm = 0; mm < ms; mm++)
                for (uint32_t nn = 0; nn < ns; nn++)
                    ddr_write16(c_addr + ((m0 + mm) * N + n0 + nn) * 2u,
                                ddr_read16(oblk + (mm * SA + nn) * 2u));
            oblk += SA * SA * 2u;
        }
    }
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
            
            if (act_mode == RAAS_CFG_ACT_RELU && acc < 0) {
                acc = 0;
            }
            
            ddr_write16(c_addr + (m * N + n) * 2u, (int16_t)acc);
        }
    }
    return 0;
}

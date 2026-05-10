/******************************************************************************
 * lenet.c — LeNet-5 layer orchestration
 *
 * Chains all 7 layers using ping-pong buffers:
 *
 *   IMAGE → Conv1 → FMAP_B
 *           Pool1 → FMAP_A
 *           Conv2 → FMAP_B
 *           Pool2 → FMAP_A
 *           FC1   → FMAP_B
 *           FC2   → FMAP_A
 *           FC3   → FMAP_B → argmax → predicted digit
 *
 * Conv layers use im2col → GEMM. Pool layers run in software.
 * FC layers are direct GEMM (input already flat from Pool2 onward).
 *
 * Note on GEMM output layout for Conv layers:
 *   GEMM produces output in [M × N] = [H_out*W_out × C_out] layout.
 *   But Pool expects CHW = [C_out × H_out × W_out].
 *   So after each Conv GEMM, we need to transpose from "spatial-major"
 *   to "channel-major" (HWC → CHW).
 ******************************************************************************/

#include "lenet.h"
#include "lenet_map.h"
#include "raas_map.h"
#include "gemm_tile.h"
#include "im2col.h"
#include "pool.h"
#include "io.h"
#include "mailbox.h"

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

/* ── Helper: HWC → CHW transpose ─────────────────────────────────────
 *
 * GEMM output is [H_out*W_out × C_out] (row = spatial, col = channel).
 * Pool expects [C_out × H_out × W_out] (channel-first).
 *
 * src[hw * C + c] → dst[c * H*W + hw]
 * ──────────────────────────────────────────────────────────────────── */
static void hwc_to_chw(uint32_t src_addr, uint32_t dst_addr,
                        uint32_t H_out, uint32_t W_out, uint32_t C_out)
{
    uint32_t HW = H_out * W_out;
    for (uint32_t hw = 0; hw < HW; hw++) {
        for (uint32_t c = 0; c < C_out; c++) {
            int16_t val = rd16(src_addr + (hw * C_out + c) * 2u);
            wr16(dst_addr + (c * HW + hw) * 2u, val);
        }
    }
}

/* Debug mailbox checkpoint */
#define LDBG(layer)  mmio_write32(LENET_ADDR(LENET_DDR_LAYER_DBG_OFF), (layer))

int lenet5_infer(int use_hw)
{
    /* Shorthand addresses */
    uint32_t image   = LENET_ADDR(LENET_DDR_IMAGE_OFF);
    uint32_t im2col_buf = LENET_ADDR(LENET_DDR_IM2COL_OFF);
    uint32_t fmap_a  = LENET_ADDR(LENET_DDR_FMAP_A_OFF);
    uint32_t fmap_b  = LENET_ADDR(LENET_DDR_FMAP_B_OFF);

    int rc;

    /* ── Layer 1: Conv1 ──────────────────────────────────────────────
     * im2col(image 1×28×28, k=5) → IM2COL_BUF [576×25]
     * GEMM(576×25 × 25×6) + bias + ReLU → FMAP_A (temporary HWC)
     * HWC→CHW transpose → FMAP_B [6×24×24]
     * ──────────────────────────────────────────────────────────────── */
    LDBG(1);
    im2col(image, im2col_buf,
           LENET_CONV1_C_IN, LENET_CONV1_H_IN, LENET_CONV1_W_IN,
           LENET_CONV1_KH, LENET_CONV1_KW, 1u);

    rc = (use_hw ? gemm_tiled : gemm_sw)(im2col_buf,
               LENET_ADDR(LENET_DDR_CONV1_W_OFF),
               LENET_ADDR(LENET_DDR_CONV1_BIAS_OFF),
               fmap_a,  /* temp: HWC layout */
               LENET_CONV1_GEMM_M, LENET_CONV1_GEMM_K, LENET_CONV1_GEMM_N,
               RAAS_CTRL_ACT_RELU);
    if (rc < 0) return rc;

    /* Transpose HWC → CHW for pooling */
    hwc_to_chw(fmap_a, fmap_b,
               LENET_CONV1_H_OUT, LENET_CONV1_W_OUT, LENET_CONV1_C_OUT);

    /* ── Layer 2: Pool1 ──────────────────────────────────────────────
     * maxpool2x2(FMAP_B [6×24×24]) → FMAP_A [6×12×12]
     * ──────────────────────────────────────────────────────────────── */
    LDBG(2);
    maxpool2x2(fmap_b, fmap_a,
               LENET_POOL1_C, LENET_POOL1_H_IN, LENET_POOL1_W_IN);

    /* ── Layer 3: Conv2 ──────────────────────────────────────────────
     * im2col(FMAP_A [6×12×12], k=5) → IM2COL_BUF [64×150]
     * GEMM(64×150 × 150×16) + bias + ReLU → FMAP_B (temporary HWC)
     * HWC→CHW transpose → FMAP_A [16×8×8]
     * ──────────────────────────────────────────────────────────────── */
    LDBG(3);
    im2col(fmap_a, im2col_buf,
           LENET_CONV2_C_IN, LENET_CONV2_H_IN, LENET_CONV2_W_IN,
           LENET_CONV2_KH, LENET_CONV2_KW, 1u);

    rc = (use_hw ? gemm_tiled : gemm_sw)(im2col_buf,
               LENET_ADDR(LENET_DDR_CONV2_W_OFF),
               LENET_ADDR(LENET_DDR_CONV2_BIAS_OFF),
               fmap_b,  /* temp: HWC layout */
               LENET_CONV2_GEMM_M, LENET_CONV2_GEMM_K, LENET_CONV2_GEMM_N,
               RAAS_CTRL_ACT_RELU);
    if (rc < 0) return rc;

    hwc_to_chw(fmap_b, fmap_a,
               LENET_CONV2_H_OUT, LENET_CONV2_W_OUT, LENET_CONV2_C_OUT);

    /* ── Layer 4: Pool2 ──────────────────────────────────────────────
     * maxpool2x2(FMAP_A [16×8×8]) → FMAP_B [16×4×4] = 256 elements
     * After this, data is already "flat" for FC layers (CHW → vector).
     * ──────────────────────────────────────────────────────────────── */
    LDBG(4);
    maxpool2x2(fmap_a, fmap_b,
               LENET_POOL2_C, LENET_POOL2_H_IN, LENET_POOL2_W_IN);

    /* ── Layer 5: FC1 ────────────────────────────────────────────────
     * GEMM(1×256 × 256×120) + bias + ReLU
     * FMAP_B [256] → FMAP_A [120]
     * ──────────────────────────────────────────────────────────────── */
    LDBG(5);
    rc = (use_hw ? gemm_tiled : gemm_sw)(fmap_b,
               LENET_ADDR(LENET_DDR_FC1_W_OFF),
               LENET_ADDR(LENET_DDR_FC1_BIAS_OFF),
               fmap_a,
               1u, LENET_FC1_IN, LENET_FC1_OUT,
               RAAS_CTRL_ACT_RELU);
    if (rc < 0) return rc;

    /* ── Layer 6: FC2 ────────────────────────────────────────────────
     * GEMM(1×120 × 120×84) + bias + ReLU
     * FMAP_A [120] → FMAP_B [84]
     * ──────────────────────────────────────────────────────────────── */
    LDBG(6);
    rc = (use_hw ? gemm_tiled : gemm_sw)(fmap_a,
               LENET_ADDR(LENET_DDR_FC2_W_OFF),
               LENET_ADDR(LENET_DDR_FC2_BIAS_OFF),
               fmap_b,
               1u, LENET_FC2_IN, LENET_FC2_OUT,
               RAAS_CTRL_ACT_RELU);
    if (rc < 0) return rc;

    /* ── Layer 7: FC3 ────────────────────────────────────────────────
     * GEMM(1×84 × 84×10) + bias + ReLU
     * FMAP_B [84] → FMAP_A [10]
     * ──────────────────────────────────────────────────────────────── */
    LDBG(7);
    rc = gemm_tiled(fmap_b,
               LENET_ADDR(LENET_DDR_FC3_W_OFF),
               LENET_ADDR(LENET_DDR_FC3_BIAS_OFF),
               fmap_a,
               1u, LENET_FC3_IN, LENET_FC3_OUT,
               RAAS_CTRL_ACT_RELU);
    if (rc < 0) return rc;

    /* ── Argmax ──────────────────────────────────────────────────────
     * Find index of maximum value in FMAP_A[10]
     * ──────────────────────────────────────────────────────────────── */
    LDBG(8);
    int16_t max_val = rd16(fmap_a);
    int predicted = 0;
    for (uint32_t i = 1; i < LENET_FC3_OUT; i++) {
        int16_t v = rd16(fmap_a + i * 2u);
        if (v > max_val) {
            max_val = v;
            predicted = (int)i;
        }
    }

    return predicted;
}

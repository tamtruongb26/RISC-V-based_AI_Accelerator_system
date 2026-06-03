/******************************************************************************
 * lenet_map.h — DDR memory layout for LeNet-5 inference
 *
 * Defines all DDR offsets where PS prefills weights/bias/image and where
 * PicoRV32 firmware reads/writes feature maps during inference.
 *
 * Layout matches system_description.md §5.1.
 * Base address: RAAS_PICO_DDR_BASE = 0x10000000 (from raas_map.h).
 ******************************************************************************/
#ifndef LENET_MAP_H
#define LENET_MAP_H

#include <stdint.h>

/* ============================================================================
 * Layer dimensions (from model.py: 28×28 input, FC1=Linear(256,120))
 * ============================================================================ */

/* Conv1: 1→6, 5×5, stride=1.  Input 28×28×1 → Output 24×24×6 */
#define LENET_CONV1_C_IN    1u
#define LENET_CONV1_C_OUT   6u
#define LENET_CONV1_KH      5u
#define LENET_CONV1_KW      5u
#define LENET_CONV1_H_IN    28u
#define LENET_CONV1_W_IN    28u
#define LENET_CONV1_H_OUT   24u   /* = 28 - 5 + 1 */
#define LENET_CONV1_W_OUT   24u
/* GEMM dims: M=576, K=25, N=6 */
#define LENET_CONV1_GEMM_M  (LENET_CONV1_H_OUT * LENET_CONV1_W_OUT)  /* 576 */
#define LENET_CONV1_GEMM_K  (LENET_CONV1_C_IN * LENET_CONV1_KH * LENET_CONV1_KW) /* 25 */
#define LENET_CONV1_GEMM_N  LENET_CONV1_C_OUT  /* 6 */

/* Pool1: 2×2 max pool.  24×24×6 → 12×12×6 */
#define LENET_POOL1_C       6u
#define LENET_POOL1_H_IN    24u
#define LENET_POOL1_W_IN    24u
#define LENET_POOL1_H_OUT   12u
#define LENET_POOL1_W_OUT   12u

/* Conv2: 6→16, 5×5, stride=1.  12×12×6 → 8×8×16 */
#define LENET_CONV2_C_IN    6u
#define LENET_CONV2_C_OUT   16u
#define LENET_CONV2_KH      5u
#define LENET_CONV2_KW      5u
#define LENET_CONV2_H_IN    12u
#define LENET_CONV2_W_IN    12u
#define LENET_CONV2_H_OUT   8u    /* = 12 - 5 + 1 */
#define LENET_CONV2_W_OUT   8u
/* GEMM dims: M=64, K=150, N=16 */
#define LENET_CONV2_GEMM_M  (LENET_CONV2_H_OUT * LENET_CONV2_W_OUT)  /* 64 */
#define LENET_CONV2_GEMM_K  (LENET_CONV2_C_IN * LENET_CONV2_KH * LENET_CONV2_KW) /* 150 */
#define LENET_CONV2_GEMM_N  LENET_CONV2_C_OUT  /* 16 */

/* Pool2: 2×2 max pool.  8×8×16 → 4×4×16 = 256 */
#define LENET_POOL2_C       16u
#define LENET_POOL2_H_IN    8u
#define LENET_POOL2_W_IN    8u
#define LENET_POOL2_H_OUT   4u
#define LENET_POOL2_W_OUT   4u
#define LENET_FLATTEN_SIZE  (LENET_POOL2_C * LENET_POOL2_H_OUT * LENET_POOL2_W_OUT)  /* 256 */

/* FC layers */
#define LENET_FC1_IN   256u
#define LENET_FC1_OUT  120u
#define LENET_FC2_IN   120u
#define LENET_FC2_OUT  84u
#define LENET_FC3_IN   84u
#define LENET_FC3_OUT  10u

/* ============================================================================
 * DDR Layout — offsets from RAAS_PICO_DDR_BASE (0x10000000)
 *
 * PS prefills weights/bias/image before releasing PicoRV32.
 * PicoRV32 reads them and writes feature maps / scratch during inference.
 * ============================================================================ */

/* --- Weights & Bias (PS prefill, Pico read-only) --- */
#define LENET_DDR_IMAGE_OFF       0x00000000u  /* 28×28×1 = 784 × 2B = 1568B */
#define LENET_DDR_CONV1_BIAS_OFF  0x00000800u  /* 6 × 2B = 12B */
#define LENET_DDR_CONV1_W_OFF     0x00000900u  /* 150 × 2B = 300B (transposed [25×6]) */
#define LENET_DDR_CONV2_BIAS_OFF  0x00000C00u  /* 16 × 2B = 32B */
#define LENET_DDR_CONV2_W_OFF     0x00000D00u  /* 2400 × 2B = 4800B (transposed [150×16]) */
#define LENET_DDR_FC1_BIAS_OFF    0x00002000u  /* 120 × 2B = 240B */
#define LENET_DDR_FC1_W_OFF       0x00002100u  /* 30720 × 2B = 61440B (transposed [256×120]) */
#define LENET_DDR_FC2_BIAS_OFF    0x00012000u  /* 84 × 2B = 168B */
#define LENET_DDR_FC2_W_OFF       0x00012100u  /* 10080 × 2B = 20160B (transposed [120×84]) */
#define LENET_DDR_FC3_BIAS_OFF    0x00017000u  /* 10 × 2B = 20B */
#define LENET_DDR_FC3_W_OFF       0x00017100u  /* 840 × 2B = 1680B (transposed [84×10]) */

/* --- Scratch / Feature Maps (Pico R/W) --- */
#define LENET_DDR_IM2COL_OFF      0x00020000u  /* max = Conv1: 576×25×2B = 28800B */
#define LENET_DDR_FMAP_A_OFF      0x00028000u  /* ping buffer: max 24×24×6×2B = 6912B */
#define LENET_DDR_FMAP_B_OFF      0x00030000u  /* pong buffer: max 6912B */
#define LENET_DDR_TILE_OUT_OFF    0x00038000u  /* 8×8 tile output = 128B */
#define LENET_DDR_TILE_W_OFF      0x00038100u  /* 8×8 tile weight = 128B */
#define LENET_DDR_TILE_B_OFF      0x00038200u  /* 8 bias = 16B */
#define LENET_DDR_TILE_IN_OFF     0x00038300u  /* 8×8 tile input = 128B */

/* --- Communication --- */
#define LENET_DDR_MAILBOX_OFF     0x00040000u  /* 4B status word */
#define LENET_DDR_PREDICTED_OFF   0x00040004u  /* 4B argmax result */
#define LENET_DDR_LAYER_DBG_OFF   0x00040008u  /* 4B current layer (debug) */
#define LENET_DDR_HW_CYCLES_OFF   0x0004000Cu  /* 4B hardware cycles */
#define LENET_DDR_SW_CYCLES_OFF   0x00040010u  /* 4B software cycles */

/* --- Phase 0 instrumentation: per-layer + accelerator counter snapshots ---
 *
 * LAYER_CYC[i] = Pico rdcycle taken right after layer i completes.
 *   i=0  → start of inference (immediately after accel_counters_clear)
 *   i=1  → after Conv1     i=2 → after Pool1
 *   i=3  → after Conv2     i=4 → after Pool2
 *   i=5  → after FC1       i=6 → after FC2
 *   i=7  → after FC3       i=8 → after argmax
 * Tổng 9 × 4B = 36B. Delta giữa các slot = cycle count của layer đó.
 *
 * ACCEL_CNT = accel_counters_t snapshot tại cuối inference (40B).
 * Layout = (idle, load_w, load_b, load_in, compute, post_proc, send, done,
 *          total, pe_active) — 10 × 4B. Tổng accelerator behavior breakdown.
 */
#define LENET_DDR_LAYER_CYC_OFF   0x00040020u  /* 9 × 4B = 36B */
#define LENET_DDR_ACCEL_CNT_OFF   0x00040050u  /* 10 × 4B = 40B */
#define LENET_DDR_INSTR_END_OFF   0x00040080u  /* end of instrumentation block */

/* Convenience: absolute Pico-view addresses */
#define LENET_ADDR(off)  (RAAS_PICO_DDR_BASE + (off))

/* Same for PS view (happens to be identical for DDR on this platform) */
#define LENET_PS_ADDR(off)  (RAAS_PS_DDR_BASE + (off))

#endif /* LENET_MAP_H */

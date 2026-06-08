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
#define LENET_DDR_OS_STAGE_OFF    0x00038400u  /* OS mode staging buffer (approx 4608B) */

/* --- Communication --- */
#define LENET_DDR_MAILBOX_OFF     0x00040000u  /* 4B status word */
#define LENET_DDR_PREDICTED_OFF   0x00040004u  /* 4B argmax result */
#define LENET_DDR_PREDICTED_SW_OFF 0x00040014u /* 4B software argmax result */
#define LENET_DDR_LAYER_DBG_OFF   0x00040008u  /* 4B current layer (debug) */
#define LENET_DDR_HW_CYCLES_OFF   0x0004000Cu  /* 4B hardware cycles */
#define LENET_DDR_SW_CYCLES_OFF   0x00040010u  /* 4B software cycles */

/* --- Phase 0 instrumentation (firmware writes during HW run) --- */
#define LENET_DDR_LAYER_CYC_OFF   0x00040020u  /* 9 × 4B: cumul rdcycle/layer */
#define LENET_DDR_ACCEL_CNT_OFF   0x00040050u  /* 10 × 4B: accel per-state cnt */

/* --- Error debug (firmware writes on failure, PS reads via DDR) --- */
#define LENET_DDR_ERR_CODE_OFF    0x00040080u  /* 4B signed error code */
#define LENET_DDR_ERR_DMA_MM2S_OFF 0x00040084u /* 4B DMA MM2S DMASR snapshot */
#define LENET_DDR_ERR_DMA_S2MM_OFF 0x00040088u /* 4B DMA S2MM DMASR snapshot */
#define LENET_DDR_ERR_ACCEL_OFF   0x0004008Cu  /* 4B accel STATUS snapshot */
#define LENET_DDR_ERR_TILE_N0_OFF 0x00040090u  /* 4B: n0 index when error */
#define LENET_DDR_ERR_TILE_K0_OFF 0x00040094u  /* 4B: k0 index when error */
#define LENET_DDR_ERR_CFG_OFF     0x00040098u  /* 4B: CFG value written to accel */

/* --- HW Debug Dump Offsets (Pico writes during HW run, PS reads to compare) --- */
#define LENET_DDR_HW_DEBUG_BASE    0x00100000u
#define LENET_DDR_HW_CONV1_OFF     (LENET_DDR_HW_DEBUG_BASE + 0x0000u)
#define LENET_DDR_HW_POOL1_OFF     (LENET_DDR_HW_DEBUG_BASE + 0x4000u) /* 6*24*24*2 = 13824B -> fits in 0x4000 */
#define LENET_DDR_HW_CONV2_OFF     (LENET_DDR_HW_DEBUG_BASE + 0x5000u) /* 6*12*12*2 = 3456B -> fits in 0x1000 */
#define LENET_DDR_HW_POOL2_OFF     (LENET_DDR_HW_DEBUG_BASE + 0x6000u) /* 16*8*8*2 = 4096B -> fits in 0x1000 */
#define LENET_DDR_HW_FC1_OFF       (LENET_DDR_HW_DEBUG_BASE + 0x6400u) /* 16*4*4*2 = 512B -> fits in 0x400 */
#define LENET_DDR_HW_FC2_OFF       (LENET_DDR_HW_DEBUG_BASE + 0x6600u) /* 120*2 = 240B */
#define LENET_DDR_HW_FC3_OFF       (LENET_DDR_HW_DEBUG_BASE + 0x6800u) /* 84*2 = 168B */

/* --- SW Debug Dump Offsets (Pico writes during SW run, PS reads to compare) --- */
#define LENET_DDR_SW_DEBUG_BASE    0x00110000u
#define LENET_DDR_SW_CONV1_OFF     (LENET_DDR_SW_DEBUG_BASE + 0x0000u)
#define LENET_DDR_SW_POOL1_OFF     (LENET_DDR_SW_DEBUG_BASE + 0x4000u)
#define LENET_DDR_SW_CONV2_OFF     (LENET_DDR_SW_DEBUG_BASE + 0x5000u)
#define LENET_DDR_SW_POOL2_OFF     (LENET_DDR_SW_DEBUG_BASE + 0x6000u)
#define LENET_DDR_SW_FC1_OFF       (LENET_DDR_SW_DEBUG_BASE + 0x6400u)
#define LENET_DDR_SW_FC2_OFF       (LENET_DDR_SW_DEBUG_BASE + 0x6600u)
#define LENET_DDR_SW_FC3_OFF       (LENET_DDR_SW_DEBUG_BASE + 0x6800u)

/* Convenience: absolute Pico-view addresses */
#define LENET_ADDR(off)  (RAAS_PICO_DDR_BASE + (off))

/* Same for PS view (happens to be identical for DDR on this platform) */
#define LENET_PS_ADDR(off)  (RAAS_PS_DDR_BASE + (off))

#endif /* LENET_MAP_H */

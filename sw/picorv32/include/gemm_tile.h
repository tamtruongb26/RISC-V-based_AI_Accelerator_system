/******************************************************************************
 * gemm_tile.h — Tiled GEMM API for PicoRV32 firmware
 ******************************************************************************/
#ifndef GEMM_TILE_H
#define GEMM_TILE_H

#include <stdint.h>

/*
 * gemm_tiled — General matrix multiply with tiling on 8×8 systolic array.
 *
 * Computes: C[M×N] = A[M×K] × W[K×N] + bias[N], with optional ReLU.
 *
 * All matrices stored in DDR as row-major Q1.4.11 (16-bit elements,
 * packed 2 per 32-bit word when accessed via DMA).
 *
 * When K > 8, firmware performs software K-accumulation:
 *   - Each K-tile runs with accelerator in BYPASS mode (no activation)
 *   - Firmware accumulates partial results
 *   - Bias and activation applied only after the last K-tile
 *
 * Parameters:
 *   a_addr     DDR address of input  A[M × K], row-major Q1.4.11
 *   w_addr     DDR address of weight W[K × N], row-major Q1.4.11 (TRANSPOSED)
 *   b_addr     DDR address of bias   B[N], Q1.4.11 (0 = no bias)
 *   c_addr     DDR address of output C[M × N], row-major Q1.4.11
 *   M, K, N    Matrix dimensions (can be any positive value, not limited to 8)
 *   act_mode   RAAS_CFG_ACT_BYPASS, RAAS_CFG_ACT_RELU, etc.
 *
 * Returns: 0 on success, negative on DMA/accelerator error.
 */
int gemm_tiled(uint32_t a_addr, uint32_t w_addr, uint32_t b_addr,
               uint32_t c_addr,
               uint32_t M, uint32_t K, uint32_t N,
               uint32_t act_mode);

/*
 * gemm_sw — Pure software matrix multiply on PicoRV32.
 * Same signature as gemm_tiled, used for benchmarking.
 */
int gemm_sw(uint32_t a_addr, uint32_t w_addr, uint32_t b_addr,
            uint32_t c_addr,
            uint32_t M, uint32_t K, uint32_t N,
            uint32_t act_mode);

#endif /* GEMM_TILE_H */

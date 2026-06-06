/******************************************************************************
 * im2col.h — im2col transform API for PicoRV32 firmware
 ******************************************************************************/
#ifndef IM2COL_H
#define IM2COL_H

#include <stdint.h>

/*
 * im2col — Convert feature map to column matrix for GEMM-based convolution.
 *
 * Transforms input[C_in × H × W] (CHW, row-major, Q1.4.11 in DDR)
 * into output[H_out*W_out × C_in*kH*kW] (row-major, Q1.4.11 in DDR).
 *
 * After im2col, convolution becomes: output = im2col_matrix × W_transposed + bias
 * which is a standard GEMM that the systolic array can compute.
 *
 * Parameters:
 *   in_addr    DDR address of input feature map, CHW layout
 *   out_addr   DDR address of output im2col matrix
 *   C          Number of input channels
 *   H, W       Spatial dimensions of input
 *   kH, kW     Kernel size
 *   stride     Convolution stride (typically 1)
 */
void im2col(uint32_t in_addr, uint32_t out_addr,
            uint32_t C, uint32_t H, uint32_t W,
            uint32_t kH, uint32_t kW, uint32_t stride);

/* HW im2col (Phase 2a) — đẩy xuống accelerator. Drop-in cho im2col() SW.
 * Return 0 OK, <0 timeout (DMA/accel). pad=0. */
int im2col_hw(uint32_t in_addr, uint32_t out_addr,
              uint32_t C, uint32_t H, uint32_t W,
              uint32_t kH, uint32_t kW, uint32_t stride);

#endif /* IM2COL_H */

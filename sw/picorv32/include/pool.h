/******************************************************************************
 * pool.h — Max-pool 2×2 API for PicoRV32 firmware
 ******************************************************************************/
#ifndef POOL_H
#define POOL_H

#include <stdint.h>

/*
 * maxpool2x2 — 2×2 max-pooling with stride 2 (software, no accelerator).
 *
 * Input/Output layout: CHW (channel-first, row-major, Q1.4.11 in DDR).
 * H and W must be even.
 *
 * For each channel, for each 2×2 block, output = max of 4 elements.
 * Output dimensions: C × (H/2) × (W/2).
 *
 * Parameters:
 *   in_addr   DDR address of input[C × H × W]
 *   out_addr  DDR address of output[C × H/2 × W/2]
 *   C         Number of channels
 *   H, W      Spatial dimensions (must be even)
 */
void maxpool2x2(uint32_t in_addr, uint32_t out_addr,
                uint32_t C, uint32_t H, uint32_t W);

/* Phase 2b: HW maxpool 2×2 qua accelerator (POOL mode). Returns 0/negative. */
int pool_hw(uint32_t in_addr, uint32_t out_addr,
            uint32_t C, uint32_t H, uint32_t W);

#endif /* POOL_H */

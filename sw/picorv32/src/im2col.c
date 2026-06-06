/******************************************************************************
 * im2col.c — im2col transform for Conv→GEMM mapping
 *
 * Convolution can be expressed as matrix multiplication:
 *
 *   Conv2d(input, kernel) = im2col(input) × kernel_matrix + bias
 *
 * im2col "unrolls" each receptive field (the kH×kW patch that a filter
 * slides over) into a single row. The result is a 2D matrix where:
 *   - Each row = one output pixel's receptive field (flattened)
 *   - Rows = H_out × W_out (all output spatial positions)
 *   - Cols = C_in × kH × kW (all elements in one receptive field)
 *
 * Example for Conv1 (1×28×28, k=5):
 *   H_out = 28-5+1 = 24, W_out = 24
 *   im2col matrix: [576 × 25]  (576 patches, each 25 elements)
 *
 * This matrix × weight[25×6] = output[576×6] = conv1 result.
 *
 * All data in DDR as Q1.4.11 (16-bit per element).
 ******************************************************************************/

#include "im2col.h"
#include "io.h"
#include "accel.h"
#include "dma.h"

#define IM2COL_DMA_TIMEOUT    2000000u
#define IM2COL_ACCEL_TIMEOUT  2000000u

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

void im2col(uint32_t in_addr, uint32_t out_addr,
            uint32_t C, uint32_t H, uint32_t W,
            uint32_t kH, uint32_t kW, uint32_t stride)
{
    uint32_t H_out = (H - kH) / stride + 1;
    uint32_t W_out = (W - kW) / stride + 1;
    uint32_t K = C * kH * kW;  /* columns in output matrix */

    /*
     * For each output position (h_out, w_out), write one row of the
     * im2col matrix. Each row has K = C_in * kH * kW elements.
     *
     * The row contains the flattened receptive field in CHW order:
     *   for c in 0..C_in:
     *     for kh in 0..kH:
     *       for kw in 0..kW:
     *         element = input[c, h_out*stride + kh, w_out*stride + kw]
     */
    uint32_t row = 0;
    for (uint32_t h_out = 0; h_out < H_out; h_out++) {
        for (uint32_t w_out = 0; w_out < W_out; w_out++) {
            uint32_t col = 0;
            for (uint32_t c = 0; c < C; c++) {
                for (uint32_t kh = 0; kh < kH; kh++) {
                    for (uint32_t kw = 0; kw < kW; kw++) {
                        uint32_t h_in = h_out * stride + kh;
                        uint32_t w_in = w_out * stride + kw;

                        /* Input address: CHW layout → offset = (c*H*W + h*W + w) * 2 */
                        uint32_t in_off = (c * H * W + h_in * W + w_in) * 2u;
                        int16_t val = rd16(in_addr + in_off);

                        /* Output address: row-major [M × K] → offset = (row*K + col) * 2 */
                        uint32_t out_off = (row * K + col) * 2u;
                        wr16(out_addr + out_off, val);

                        col++;
                    }
                }
            }
            row++;
        }
    }
}

/* ── HW im2col (Phase 2a) ───────────────────────────────────────────────
 * Đẩy việc im2col xuống accelerator (Vấn đề 3b). Drop-in cho im2col() SW.
 * Accelerator tự block theo output-row → fire-once: config + start, DMA FM vào,
 * DMA ma trận A ra DDR. pad=0 (LeNet conv valid).
 * Return 0 OK, <0 timeout. */
int im2col_hw(uint32_t in_addr, uint32_t out_addr,
              uint32_t C, uint32_t H, uint32_t W,
              uint32_t kH, uint32_t kW, uint32_t stride)
{
    const uint32_t pad = 0u;
    uint32_t Hout = (H + 2u*pad - kH) / stride + 1u;
    uint32_t Wout = (W + 2u*pad - kW) / stride + 1u;
    uint32_t fm_bytes = C * H * W * 2u;
    uint32_t a_bytes  = Hout * Wout * C * kH * kW * 2u;
    int rc;

    uint32_t cfg0 = (kW << 28) | (kH << 24) | (C << 16) | (W << 8) | H;
    uint32_t cfg1 = (pad << 20) | (stride << 16) | (Wout << 8) | Hout;

    accel_im2col_config(cfg0, cfg1);
    dma_reset();
    accel_start_im2col();                 /* → LOAD_FM, chờ AXIS */
    dma_s2mm_recv(out_addr, a_bytes);     /* arm nhận ma trận A */

    rc = dma_mm2s_send_and_wait(in_addr, fm_bytes, IM2COL_DMA_TIMEOUT);
    if (rc < 0) return rc;
    rc = accel_wait_done(IM2COL_ACCEL_TIMEOUT);
    if (rc < 0) return rc;
    rc = dma_s2mm_wait(IM2COL_DMA_TIMEOUT);
    return rc;
}

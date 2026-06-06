#ifndef RAAS_MAP_H
#define RAAS_MAP_H

#include <stdint.h>

/* ============================================================================
 * Address bases
 * ============================================================================ */

/* PicoRV32 view (firmware sees these) */
#define RAAS_PICO_ACCEL_BASE     0x40000000u   /* accelerator AXI-Lite     */
#define RAAS_PICO_DMA_BASE       0x40010000u   /* AXI DMA control          */
#define RAAS_PICO_DDR_BASE       0x10000000u   /* DDR via HP0 (uncached)   */

/* PS A53 view (Vitis app sees these) */
#define RAAS_PS_BRAM_BASE        0xA0000000u   /* PicoRV32 BRAM (load FW)  */
#define RAAS_PS_BRAM_SIZE        0x10000u      /* 64 KB                    */
#define RAAS_PS_ACCEL_BASE       0xA0010000u   /* accelerator (debug only) */
#define RAAS_PS_SW_RESET_BASE    0xA0030000u   /* sw_reset_0               */
#define RAAS_PS_DDR_BASE         0x10000000u   /* same DDR vùng (cacheable)*/

/* sw_reset_0 register */
#define RAAS_SW_RESET_OFFSET     0x00u
/* SLV_REG0 bit[0]: 1 = RUN (deassert), 0 = RESET (assert). Default 0. */
#define RAAS_SW_RESET_RUN        0x1u
#define RAAS_SW_RESET_HOLD       0x0u

/* ============================================================================
 * Accelerator register offsets (Phase 0 layout)
 *
 * Old 5-register layout (TILE_M/K/N/CTRL/STATUS) đã được pack lại để giảm
 * MMIO overhead: 1 write thay 4. Thêm 2 register cho counter readback indirect.
 * ============================================================================ */

#define RAAS_ACCEL_CFG           0x00u   /* R/W  CONFIG_PACKED              */
#define RAAS_ACCEL_CNT_CLEAR     0x04u   /* R/W  [0]=PULSE (auto-clear)     */
#define RAAS_ACCEL_CNT_SEL       0x08u   /* R/W  [3:0]=counter index        */
#define RAAS_ACCEL_STATUS        0x0Cu   /* R    [0]=BUSY, [1]=DONE         */
#define RAAS_ACCEL_CNT_VAL       0x10u   /* R    32-bit counter[CNT_SEL]    */
#define RAAS_ACCEL_IM2COL_CFG0   0x14u   /* R/W  {KW,KH,C,W,H} packed       */
#define RAAS_ACCEL_IM2COL_CFG1   0x18u   /* R/W  {pad,stride,Wout,Hout}     */

/* CONFIG_PACKED bit fields:
 *   [3:0]   = M_size  (1..8)
 *   [7:4]   = K_size
 *   [11:8]  = N_size
 *   [13:12] = ACT_MODE (0=bypass, 1=ReLU, 2=sigmoid)
 *   [14]    = START (one-shot pulse, auto-clear)
 */
#define RAAS_CFG_M_SHIFT         0u
#define RAAS_CFG_K_SHIFT         4u
#define RAAS_CFG_N_SHIFT         8u
#define RAAS_CFG_ACT_SHIFT       12u
#define RAAS_CFG_START_BIT       (1u << 14)

/* Phase 1a-i: HW K-accumulation control (CFG spare bit).
 *   [15] ACC_ACCUM : 1 = cộng dồn psum_buf (K-tile > 0), 0 = ghi đè (K-tile 0)
 *   [16] POST_SKIP : 1 = bỏ POST_PROC+SEND (K-tile giữa), 0 = làm (K-tile cuối)
 * Mặc định (bit=0) = behavior cũ (ghi đè + post_proc). */
#define RAAS_CFG_ACC_ACCUM       (1u << 15)
#define RAAS_CFG_POST_SKIP       (1u << 16)

/* Phase 2a: HW im2col mode (CFG bit 21). Params ở IM2COL_CFG0/CFG1.
 *   CFG0 = (kW<<28)|(kH<<24)|(C<<16)|(W<<8)|H
 *   CFG1 = (pad<<20)|(stride<<16)|(Wout<<8)|Hout */
#define RAAS_CFG_IM2COL_MODE     (1u << 21)

/* Phase 3a: OS dataflow mode (CFG bit 22) — FC layer, util 12.5%→100%.
 *   Stream: weight tile (32 word) + a-vector (4 word), KHÔNG bias (SW bias).
 *   Cộng dồn K-tile qua ACC_ACCUM/POST_SKIP. */
#define RAAS_CFG_OS_MODE         (1u << 22)

/* Phase 1a-ii: data reuse (CFG spare bit).
 *   [17]    SKIP_W_LOAD : 1 = giữ weight cũ trong array (bỏ LOAD_W), 0 = nạp weight
 *   [19:18] ACC_SLOT    : output-tile slot trong accumulator (blocking, 0..3) */
#define RAAS_CFG_SKIP_W_LOAD     (1u << 17)
#define RAAS_CFG_ACC_SLOT_SHIFT  18u
#define RAAS_CFG_ACC_SLOT(s)     (((uint32_t)(s) & 0x3u) << RAAS_CFG_ACC_SLOT_SHIFT)
/*   [20] SKIP_IN_LOAD : 1 = giữ input cũ trong input_buf (bỏ LOAD_IN, reuse FC) */
#define RAAS_CFG_SKIP_IN_LOAD    (1u << 20)

#define RAAS_CFG_ACT_BYPASS      (0u << RAAS_CFG_ACT_SHIFT)
#define RAAS_CFG_ACT_RELU        (1u << RAAS_CFG_ACT_SHIFT)
#define RAAS_CFG_ACT_SIGMOID     (2u << RAAS_CFG_ACT_SHIFT)
#define RAAS_CFG_ACT_MASK        (3u << RAAS_CFG_ACT_SHIFT)

/* Helper macro: pack (M, K, N, act) thành 1 CONFIG word KHÔNG có START.
 * Firmware ghi CFG | RAAS_CFG_START_BIT để vừa setup vừa start trong 1 write. */
#define RAAS_CFG_PACK(M, K, N, act) \
    ((((uint32_t)(M) & 0xFu) << RAAS_CFG_M_SHIFT) | \
     (((uint32_t)(K) & 0xFu) << RAAS_CFG_K_SHIFT) | \
     (((uint32_t)(N) & 0xFu) << RAAS_CFG_N_SHIFT) | \
     ((uint32_t)(act)))

/* STATUS bit fields (DONE is sticky, cleared on next START write) */
#define RAAS_STATUS_BUSY         (1u << 0)
#define RAAS_STATUS_DONE         (1u << 1)

/* CNT_CLEAR bit field */
#define RAAS_CNT_CLEAR_PULSE     (1u << 0)

/* Counter index (write vào CNT_SEL trước khi đọc CNT_VAL) */
#define RAAS_CNT_IDX_IDLE        0u
#define RAAS_CNT_IDX_LOAD_W      1u
#define RAAS_CNT_IDX_LOAD_B      2u
#define RAAS_CNT_IDX_LOAD_IN     3u
#define RAAS_CNT_IDX_COMPUTE     4u
#define RAAS_CNT_IDX_POST_PROC   5u
#define RAAS_CNT_IDX_SEND        6u
#define RAAS_CNT_IDX_DONE        7u
#define RAAS_CNT_IDX_TOTAL       8u
#define RAAS_CNT_IDX_PE_ACTIVE   9u
#define RAAS_CNT_COUNT           10u

/* ============================================================================
 * AXI DMA register offsets (Xilinx PG021 standard, Simple Mode)
 * ============================================================================ */

/* MM2S channel: read DDR → AXIS master → accelerator S00_AXIS */
#define RAAS_DMA_MM2S_DMACR      0x00u   /* control          */
#define RAAS_DMA_MM2S_DMASR      0x04u   /* status           */
#define RAAS_DMA_MM2S_SA_LO      0x18u   /* source addr lo   */
#define RAAS_DMA_MM2S_SA_HI      0x1Cu   /* source addr hi   */
#define RAAS_DMA_MM2S_LENGTH     0x28u   /* length (bytes)   */

/* S2MM channel: AXIS slave ← accelerator M00_AXIS, write DDR */
#define RAAS_DMA_S2MM_DMACR      0x30u
#define RAAS_DMA_S2MM_DMASR      0x34u
#define RAAS_DMA_S2MM_DA_LO      0x48u   /* dest addr lo     */
#define RAAS_DMA_S2MM_DA_HI      0x4Cu   /* dest addr hi     */
#define RAAS_DMA_S2MM_LENGTH     0x58u

/* DMACR bits */
#define RAAS_DMACR_RUN           (1u << 0)   /* 1=run, 0=halt */
#define RAAS_DMACR_RESET         (1u << 2)   /* W1C self-clear */

/* DMASR bits */
#define RAAS_DMASR_HALTED        (1u << 0)
#define RAAS_DMASR_IDLE          (1u << 1)   /* set khi transfer xong   */
#define RAAS_DMASR_DMAINTERR     (1u << 4)   /* internal error           */
#define RAAS_DMASR_DMASLVERR     (1u << 5)   /* slave error              */
#define RAAS_DMASR_DMADECERR     (1u << 6)   /* decode error             */

/* ============================================================================
 * DDR layout (PS prefill các vùng, PicoRV32 đọc/ghi qua HP0)
 * Total < 4 KB, all offsets từ DDR base.
 * ============================================================================ */

#define RAAS_DDR_WEIGHTS_OFFSET  0x000u   /* 64×2B = 128B (8x8 padded)    */
#define RAAS_DDR_BIAS_OFFSET     0x100u   /* 8×2B = 16B (then padding)    */
#define RAAS_DDR_INPUT_OFFSET    0x200u   /* 64×2B = 128B (8x8 padded)    */
#define RAAS_DDR_OUTPUT_OFFSET   0x400u   /* 64×2B = 128B (DMA S2MM ghi)  */
#define RAAS_DDR_GOLDEN_OFFSET   0x500u   /* 64×2B = 128B (PS prefill)    */
#define RAAS_DDR_MAILBOX_OFFSET  0x800u   /* 4B status word               */
#define RAAS_DDR_USED_SIZE       0x1000u  /* 4 KB total                   */

/* Convenience macros — addr cho cả PicoRV32 và PS view */
#define RAAS_PICO_DDR_ADDR(off)  (RAAS_PICO_DDR_BASE + (off))
#define RAAS_PS_DDR_ADDR(off)    (RAAS_PS_DDR_BASE   + (off))

/* ============================================================================
 * Mailbox magic values (firmware ghi, PS đọc)
 * ============================================================================ */

#define RAAS_MBX_BOOT             0x00000000u  /* PS init                 */
#define RAAS_MBX_STARTED          0xCAFEBABEu  /* FW vào main()           */
#define RAAS_MBX_PASS             0xC0DEC0DEu  /* test pass               */
#define RAAS_MBX_FAIL             0xDEADBEEFu  /* output mismatch         */
#define RAAS_MBX_DMA_TIMEOUT      0xDEAD0001u  /* DMA hang                */
#define RAAS_MBX_ACCEL_TIMEOUT    0xDEAD0002u  /* accelerator hang        */
#define RAAS_MBX_DMA_ERROR        0xDEAD0003u  /* DMASR error bit set     */

/* ============================================================================
 * Tile config (Stage A: hardcoded 8×8×8 bypass)
 * ============================================================================ */

#define RAAS_TILE_M              8u
#define RAAS_TILE_K              8u
#define RAAS_TILE_N              8u

/* AXIS word counts (mỗi word = 32-bit = 2 elements Q1.4.11 packed) */
#define RAAS_WEIGHTS_WORDS       32u  /* 8 row × 4 word/row = 32 word     */
#define RAAS_BIAS_WORDS          4u   /* 8 elements / 2 = 4 word          */
#define RAAS_INPUT_WORDS         32u  /* M=8 × ⌈K/2⌉=4 = 32 word          */
#define RAAS_OUTPUT_WORDS        32u  /* M=8 × ⌈N/2⌉=4 = 32 word          */
#define RAAS_OUTPUT_CELLS        64u  /* M×N = 64 elements                */

#endif /* RAAS_MAP_H */

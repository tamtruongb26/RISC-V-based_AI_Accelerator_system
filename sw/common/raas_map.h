/******************************************************************************
 * raas_map.h — RAAS shared memory map + register definitions
 *
 * Shared between PicoRV32 firmware (sw/picorv32/) và PS app (sw/vitis/).
 *
 * Hardware ref: hw/accelerator_2_0/hdl/, fpga/RAS.bd address map.
 * Plan ref:     §8.1 (Step 14.1) trong plan file.
 ******************************************************************************/
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
 * Accelerator register offsets (relative to ACCEL_BASE)
 * ============================================================================ */

#define RAAS_ACCEL_TILE_M        0x00u   /* R/W [9:0] M dimension (1..8) */
#define RAAS_ACCEL_TILE_K        0x04u   /* R/W [9:0]                    */
#define RAAS_ACCEL_TILE_N        0x08u   /* R/W [9:0]                    */
#define RAAS_ACCEL_CTRL          0x0Cu   /* R/W [0]=START, [2:1]=ACT     */
#define RAAS_ACCEL_STATUS        0x10u   /* R   [0]=BUSY, [1]=DONE       */

/* CTRL bit fields */
#define RAAS_CTRL_START          (1u << 0)
#define RAAS_CTRL_ACT_BYPASS     (0u << 1)
#define RAAS_CTRL_ACT_RELU       (1u << 1)
#define RAAS_CTRL_ACT_SIGMOID    (2u << 1)
#define RAAS_CTRL_ACT_MASK       (3u << 1)

/* STATUS bit fields (DONE is sticky, cleared on next START write) */
#define RAAS_STATUS_BUSY         (1u << 0)
#define RAAS_STATUS_DONE         (1u << 1)

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

/******************************************************************************
 * io.h — MMIO helpers cho PicoRV32 firmware
 *
 * PicoRV32 truy cập AXI peripheral qua physical address (no MMU). Dùng volatile
 * pointer để compiler không reorder/cache.
 *
 * Plan ref: §8.3 (Step 14.3).
 ******************************************************************************/
#ifndef RAAS_IO_H
#define RAAS_IO_H

#include <stdint.h>

static inline void mmio_write32(uint32_t addr, uint32_t value)
{
    *(volatile uint32_t *)addr = value;
}

static inline uint32_t mmio_read32(uint32_t addr)
{
    return *(volatile uint32_t *)addr;
}

/* Memory fence — RV32 fence instruction.
 * Đảm bảo ordering giữa MMIO writes (vd: write data trước, write START sau). */
static inline void fence_iorw(void)
{
    __asm__ volatile ("nop" ::: "memory");
}

/* PicoRV32 cycle counter (CSR rdcycle, lower 32 bits).
 * Wraps every ~43 seconds at 100 MHz — đủ cho 1 LeNet inference. */
static inline uint32_t pico_rdcycle(void)
{
    uint32_t cycles;
    __asm__ volatile ("rdcycle %0" : "=r"(cycles));
    return cycles;
}

#endif /* RAAS_IO_H */

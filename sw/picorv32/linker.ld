/******************************************************************************
 * linker.ld — PicoRV32 firmware linker script
 *
 * Target: 64 KB BRAM @ 0x00000000 (PicoRV32 view, axi_bram_ctrl_0).
 * BRAM dual-port: PS app loads firmware via 0xA0000000 trước, sau đó deassert
 * sw_reset_0 → PicoRV32 fetch instruction từ 0x00000000.
 *
 * PROGADDR_RESET (PicoRV32 IP param) = 0x00000000 → entry point phải ở đây.
 * Stack grows downward từ top of BRAM (0x10000) xuống.
 *
 * Plan ref: §8.2 (Step 14.2).
 ******************************************************************************/

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    BRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    /* Reset vector + startup code phải ở 0x0 */
    .text 0x00000000 :
    {
        KEEP(*(.text.init))   /* startup.S _start */
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
        . = ALIGN(4);
    } > BRAM

    /* Initialized data — link sau .text */
    .data : ALIGN(4)
    {
        __data_start = .;
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > BRAM

    /* Zero-initialized — startup.S clear vùng này */
    .bss : ALIGN(4)
    {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > BRAM

    /* Stack grows downward từ top of BRAM. startup.S set sp = __stack_top. */
    __stack_top = ORIGIN(BRAM) + LENGTH(BRAM);

    /* Discard sections không cần thiết cho freestanding */
    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}

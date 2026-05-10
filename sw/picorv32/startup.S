/******************************************************************************
 * startup.S — PicoRV32 firmware entry point
 *
 * Sequence:
 *   1. PicoRV32 reset deasserted → PC = PROGADDR_RESET = 0x00000000.
 *   2. Set stack pointer = __stack_top (top of BRAM = 0x10000).
 *   3. Clear .bss (PicoRV32 không tự zero memory at reset).
 *   4. Jump to main(). Don't return (test halts via while(1) in main).
 *   5. Fallback: nếu main() return → infinite loop để CPU không fetch garbage.
 *
 * IRQ note: PicoRV32 IP có ENABLE_IRQ=1 nhưng default mask = 0xFFFFFFFF (all
 * masked). Firmware này KHÔNG dùng IRQ → không cần install handler.
 *
 * Plan ref: §8.2 (Step 14.2).
 ******************************************************************************/

    .section .text.init, "ax"
    .global  _start
    .type    _start, @function

_start:
    /* ── 1. Set stack pointer ─────────────────────────────────── */
    la      sp, __stack_top

    /* ── 2. Clear .bss section ────────────────────────────────── */
    la      t0, __bss_start
    la      t1, __bss_end
1:
    bgeu    t0, t1, 2f          /* if t0 >= t1, done */
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* ── 3. Jump to main() ────────────────────────────────────── */
    call    main

    /* ── 4. Fallback halt nếu main() return ────────────────────── */
halt:
    j       halt

    .size _start, . - _start

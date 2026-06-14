/* Linker script for riscv-torture tests on Frost -- DDR memory config.
 *
 * A minimal boot stub (crt0_torture_ddr.S, .boot) runs from the low BRAM ROM
 * and far-jumps to the DDR-resident _start; the test itself -- code, data and
 * the signature area -- lives in the cached DDR region, fetched through the
 * L1I and loaded/stored through the L1D.  DDR sections load in place
 * (LMA == VMA): the simulator preloads the behavioral DDR from sw_ddr.mem, so
 * frost_header's data-copy loop is a no-op (load address == store address) and
 * its jump to _torture_test_begin stays within DDR.
 */

ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 96K
    RAM (rwx) : ORIGIN = 0x00018000, LENGTH = 160K

    DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 64M

    MMIO (rw) : ORIGIN = 0x40000000, LENGTH = 40
}

_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);

SECTIONS
{
    /* ROM boot stub only: far-jump to the DDR-resident _start. */
    .boot : {
        KEEP(*(.boot))
    } > ROM

    .text : {
        KEEP(*(.text.init))
        *(.text*)
        *(.text.*)
    } > DDR

    .rodata : {
        *(.rodata*)
        *(.rodata.*)
        *(.srodata*)
        . = ALIGN(4);
    } > DDR

    /* Loaded in place from sw_ddr.mem (LMA == VMA), so frost_header's copy
     * loop becomes a no-op. */
    .data : {
        __data_load_start = .;
        __data_start      = .;
        *(.data*)
        . = ALIGN(4);
    } > DDR

    .sdata : {
        *(.sdata*)
        . = ALIGN(4);
        __data_end = .;
    } > DDR

    .sbss : {
        __sbss_start = .;
        *(.sbss*)
        *(.scommon*)
        . = ALIGN(4);
        __sbss_end = .;
    } > DDR

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DDR

    /* tohost section (used by Spike for program termination, harmless on Frost) */
    .tohost : {
        *(.tohost)
    } > DDR

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);
    PROVIDE(UART_ADDR           = 0x40000000);
}

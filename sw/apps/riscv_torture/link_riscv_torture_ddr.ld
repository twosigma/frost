/* crt0_torture_ddr.S boots from low BRAM and jumps to _start in cached DDR.
 * Code, data and the signature load in place from sw_ddr.mem (LMA == VMA).
 * The jump from frost_header to _torture_test_begin stays within JAL range. */

ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 95K
    DEBUG (rx): ORIGIN = 0x00017C00, LENGTH = 1K  /* debug-module slice: reserved, never allocated */
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

    /* LMA == VMA: startup copies each data word onto itself. */
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

    /* tohost section (used by Spike for program termination, harmless on FROST) */
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

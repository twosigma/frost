/* Linker script for riscv-torture tests on Frost
 *
 * ROM holds: code (header + test + footer) + data load image
 * RAM holds: data runtime copy (including signature area) + BSS + stack
 *
 * NOTE: 2MB simulation memory. Not suitable for synthesis.
 */

ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 1M
    RAM (rwx) : ORIGIN = 0x00100000, LENGTH = 1M

    MMIO (rw) : ORIGIN = 0x40000000, LENGTH = 40
}

_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text*)
        *(.text.*)
    } > ROM

    .rodata : {
        *(.rodata*)
        *(.rodata.*)
        *(.srodata*)
        . = ALIGN(4);
    } > ROM

    .data : AT(ADDR(.rodata) + SIZEOF(.rodata)) {
        __data_load_start = LOADADDR(.data);
        __data_start      = .;
        *(.data*)
        . = ALIGN(4);
    } > RAM

    .sdata : AT(LOADADDR(.data) + SIZEOF(.data)) {
        *(.sdata*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM

    .sbss : {
        __sbss_start = .;
        *(.sbss*)
        *(.scommon*)
        . = ALIGN(4);
        __sbss_end = .;
    } > RAM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /* tohost section (used by Spike for program termination, harmless on Frost) */
    .tohost : {
        *(.tohost)
    } > RAM

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);
    PROVIDE(UART_ADDR           = 0x40000000);
}

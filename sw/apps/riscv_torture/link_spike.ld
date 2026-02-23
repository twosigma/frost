/* Linker script for running torture tests on Spike (reference generation)
 *
 * Uses 0x80000000 base (Spike default) instead of Frost's 0x00000000.
 * Code and data both in RAM since Spike doesn't need ROM/RAM split.
 */

ENTRY(_start)

MEMORY
{
    RAM  (rwx) : ORIGIN = 0x80000000, LENGTH = 4M
    MMIO (rw)  : ORIGIN = 0x40000000, LENGTH = 4K
}

_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text*)
        *(.text.*)
    } > RAM

    .rodata : {
        *(.rodata*)
        *(.rodata.*)
        *(.srodata*)
        . = ALIGN(4);
    } > RAM

    /* For Spike, data is in the same memory space (no ROM→RAM copy needed) */
    .data : {
        __data_load_start = .;
        __data_start      = .;
        *(.data*)
        . = ALIGN(4);
    } > RAM

    .sdata : {
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

    /* Spike tohost/fromhost for program termination */
    .tohost : ALIGN(0x1000) {
        *(.tohost)
    } > RAM

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);
    PROVIDE(UART_ADDR           = 0x40000000);
}

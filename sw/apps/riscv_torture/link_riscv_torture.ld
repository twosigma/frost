/* BRAM layout shared with sw/common/link.ld: 95 KiB ROM, 1 KiB reserved for
 * debug, and 160 KiB RAM. ROM holds code and the data load image; RAM holds
 * runtime data, the signature, BSS and stack. */

ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 95K
    DEBUG (rx): ORIGIN = 0x00017C00, LENGTH = 1K  /* debug-module slice: reserved, never allocated */
    RAM (rwx) : ORIGIN = 0x00018000, LENGTH = 160K

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

    /* tohost section (used by Spike for program termination, harmless on FROST) */
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

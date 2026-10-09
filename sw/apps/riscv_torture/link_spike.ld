/* Spike reference layout: code and data share RAM at 0x80000000. */

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

    /* LMA == VMA: startup copies each data word onto itself. */
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

    /* Spike maps plain memory at the UART. The footer polls UART_TX_STATUS
     * before each byte, so preset its ready bit there. */
    .frost_uart_status 0x40000028 : {
        LONG(1)
    } > MMIO

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);
    PROVIDE(UART_ADDR           = 0x40000000);
}

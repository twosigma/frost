/* Linker script for riscv-arch-test on Frost, low-BRAM config.
 *
 * Code, data and the signature area all live in the 256 KiB low region
 * (ROM 96K + RAM 160K), so neither cached tier is involved: this is the pure
 * ISA-conformance tier. The ROM/RAM split gives the big compliance tests
 * (fmadd/fnmadd/... with up to ~14K test cases) a large contiguous RAM for
 * their signature areas; a test whose image exceeds the low BRAM is covered
 * by the ddr tier (link_arch_test.ld) instead. This suite runs only in
 * simulation.
 *
 * The .data load image sits in ROM directly after .rodata and crt0 copies it
 * into RAM. Near-capacity tests place that load image just below RAM with a
 * small overlap into the destination range, so crt0 copies backward
 * (memmove-safe for dest > src).
 */

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
        KEEP(*(.init))
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

    /* No heap needed for arch tests */

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);
    PROVIDE(UART_ADDR           = 0x40000000);
    PROVIDE(UART_RX_DATA_ADDR   = 0x40000004);
    PROVIDE(UART_RX_STATUS_ADDR = 0x40000024);
    PROVIDE(FIFO0_ADDR      = 0x40000008);
    PROVIDE(FIFO1_ADDR      = 0x4000000C);
    PROVIDE(MTIME_LO_ADDR    = 0x40000010);
    PROVIDE(MTIME_HI_ADDR    = 0x40000014);
    PROVIDE(MTIMECMP_LO_ADDR = 0x40000018);
    PROVIDE(MTIMECMP_HI_ADDR = 0x4000001C);
    PROVIDE(MSIP_ADDR        = 0x40000020);
}

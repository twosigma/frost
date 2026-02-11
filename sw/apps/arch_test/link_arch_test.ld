/* Linker script for riscv-arch-test on Frost
 *
 * Optimized for arch tests which have tiny code (~700 bytes) but
 * potentially large data sections (test vectors + signature area).
 * Split 50/50 to prevent LMA/VMA overlap during the crt0 forward copy.
 *
 * ROM holds: code (~700 bytes) + data load image (N bytes).
 * RAM holds: data runtime copy (N bytes) + BSS.
 * Constraint: code + 2*N <= 2MB, so max data ~1MB.
 *
 * NOTE: This linker script targets 2MB simulation memory (Verilator -GMEM_SIZE_BYTES).
 * It is NOT suitable for synthesis where hardware defaults to 128KB.
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

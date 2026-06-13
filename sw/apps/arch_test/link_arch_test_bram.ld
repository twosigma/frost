/* Linker script for riscv-arch-test on Frost
 *
 * SIM-ONLY 2 MiB map, deliberately larger than the 256 KiB hardware low
 * region: the big compliance tests (fmadd/fnmadd/... with up to ~14K test
 * cases) compile to several hundred KiB of generated code plus large
 * signature areas, and FROST executes only from the low instruction BRAM,
 * so they cannot be split into the cached DDR region. The compliance
 * harness (tests/test_arch_compliance.py) passes the matching
 * SIM_MEM_SIZE_BYTES=2097152 override; this suite never runs on hardware.
 *
 * The data load image lives in ROM and is copied forward into RAM by crt0
 * (ROM below RAM, so LMA < VMA and the ascending copy never overlaps).
 */

ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 96K
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

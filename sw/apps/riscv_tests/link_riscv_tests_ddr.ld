/* Linker script for riscv-tests on Frost -- DDR memory config.
 *
 * A minimal boot stub (crt0_riscv_tests_ddr.S, .boot) runs from the low BRAM
 * ROM and far-jumps to the DDR-resident _start; the test -- code, data and
 * (for ISA tests) the tohost area -- lives in the cached DDR region, fetched
 * through the L1I and loaded/stored through the L1D.  DDR sections load in
 * place (LMA == VMA): the simulator preloads the behavioral DDR from
 * sw_ddr.mem, so the startup's data-copy loop is a no-op (load address ==
 * store address).  The stack stays in low BRAM for fast access.
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
        KEEP(*(.init))
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

    /* Loaded in place from sw_ddr.mem (LMA == VMA), so the startup copy loop
     * is a no-op. */
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

    /* ISA tests emit a tohost section (harmless on Frost, which signals via
     * UART); keep it in DDR so it does not orphan into the low BRAM image. */
    .tohost : {
        *(.tohost)
    } > DDR

    .heap (NOLOAD) : {
        . = ALIGN(4);
        _heap_start = .;
        . = . + 64K;
        _heap_end = .;
    } > DDR

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

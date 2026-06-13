/* Linker script for riscv-arch-test on Frost
 *
 * HARDWARE memory map: the boot stub runs from the low BRAM ROM and the
 * test itself -- code, data and the signature area -- lives in the cached
 * DDR region, fetched through the L1I and loaded/stored through the L1D.
 * The big compliance tests (fadd/fmadd/... with thousands of generated
 * cases) compile to several hundred KiB, far beyond the 96 KiB low ROM;
 * execute-from-DDR removes that ceiling, so the suite runs the same image
 * shape as real software (sw.mem = low BRAM stub, sw_ddr.mem = DDR
 * sections) and no longer needs an oversized sim-only memory.
 *
 * DDR sections load in place (LMA == VMA): the simulator preloads the
 * behavioral DDR from sw_ddr.mem and the JTAG loader bursts the same image
 * on hardware, so the boot stub only zeroes .bss/.sbss and jumps.
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
    /* Boot stub only: zero .bss/.sbss, far-jump to the DDR-resident test. */
    .init : {
        KEEP(*(.init))
    } > ROM

    .text : {
        *(.text*)
        *(.text.*)
    } > DDR

    .rodata : {
        *(.rodata*)
        *(.rodata.*)
        *(.srodata*)
        . = ALIGN(4);
    } > DDR

    .data : {
        *(.data*)
        . = ALIGN(4);
    } > DDR

    .sdata : {
        *(.sdata*)
        . = ALIGN(4);
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

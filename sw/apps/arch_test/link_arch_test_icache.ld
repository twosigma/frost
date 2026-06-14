/* Linker script for riscv-arch-test on Frost -- I-cache ISOLATION config.
 *
 * Splits the two cached tiers so a failure is attributable to one path:
 *   - code (.text/.rodata) lives in the cached DDR region and is fetched
 *     through the L1I / fetch provider (this is the path under test),
 *   - data and the signature area (.data/.sdata/.bss) live in the low BRAM
 *     and are loaded/stored directly, NOT through the D-side cached tier.
 *
 * So a pass here proves instruction fetch from DDR is ISA-compliant
 * independent of the D-side cached-tier load/store path (which the `ddr`
 * config -- link_arch_test.ld -- exercises by putting data in DDR too).
 *
 * The low BRAM matches the 256 KiB hardware map. .data is initialized in
 * place (LMA == VMA in RAM): the simulator preloads the data BRAM directly
 * from sw.mem, so the boot stub (crt0_arch_test.S) only zeroes .bss/.sbss
 * and far-jumps to the DDR-resident framework entry point.
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

    /* Code under test: fetched from the cached DDR region through the L1I. */
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

    /* Data + signature: low BRAM, loaded/stored directly (not the D-cache). */
    .data : {
        __data_start = .;
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

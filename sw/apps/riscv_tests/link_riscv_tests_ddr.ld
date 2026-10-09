/* crt0_riscv_tests_ddr.S boots from low BRAM and jumps to _start in cached
 * DDR. Code, data, BSS and heap use DDR; the stack stays in low BRAM.
 * sw_ddr.mem loads DDR sections in place (LMA == VMA). */

ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 95K
    DEBUG (rx): ORIGIN = 0x00017C00, LENGTH = 1K  /* debug-module slice: reserved, never allocated */
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

    /* LMA == VMA: startup copies each data word onto itself. */
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

    /* Keep any upstream HTIF mailbox in DDR so it cannot become an orphan
     * section in low BRAM. FROST reports through UART and emits no mailbox. */
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

/* crt0_riscv_tests_ddr.S jumps to the constant 0x8000_0000, which is correct
 * only while _start sits at the DDR origin. */
ASSERT(_start == ORIGIN(DDR), "link_riscv_tests_ddr.ld: _start must sit at ORIGIN(DDR) (the boot stub jumps to the constant 0x80000000)")

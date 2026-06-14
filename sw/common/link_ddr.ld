/* Unified DDR-tier linker script for FROST RISC-V bare-metal programs.
 *
 * The ddr counterpart to link.ld (selected by common.mk / the per-app Makefiles
 * when MEM_CONFIG=ddr).  A minimal boot stub (crt0_ddr_boot.S, .boot) runs from
 * the low BRAM ROM and far-jumps to the DDR-resident _start; the WHOLE program
 * -- code, data, bss -- lives in the cached DDR region at 0x8000_0000, fetched
 * through the L1I and loaded/stored through the L1D.  The opt-in .ddr_* sections
 * stay in DDR after the relocated program, and the heap follows.  The stack
 * stays in low BRAM (fast).
 *
 * DDR sections load in place (LMA == VMA): the sim preloads the behavioral DDR
 * from sw_ddr.mem, so crt0's .data copy loop self-copies (a no-op).
 *
 * Image emission (MEM_CONFIG=ddr):
 *   sw.mem     = objcopy -R <whole program + .ddr_*>   (the ROM boot stub only)
 *   sw_ddr.mem = objcopy -j <whole program + .ddr_*> --change-addresses -0x80000000
 */

ENTRY(_start)

MEMORY
{
    ROM  (rx)  : ORIGIN = 0x00000000, LENGTH = 96K    /* boot stub only */
    RAM  (rwx) : ORIGIN = 0x00018000, LENGTH = 160K   /* stack (top at 0x40000) */
    DDR  (rwx) : ORIGIN = 0x80000000, LENGTH = 1024M  /* whole program + heap */
    MMIO (rw)  : ORIGIN = 0x40000000, LENGTH = 44     /* peripherals */
}

/* Stack stays in low BRAM (fast, uncached) for ALL programs. */
_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);
__freertos_irq_stack_top = _end_of_stack;

SECTIONS
{
    /* ================================================================
     * ROM: the boot stub only (far-jump to the DDR-resident _start)
     * ================================================================ */
    .boot : {
        KEEP(*(.boot))
    } > ROM

    /* ================================================================
     * DDR: the whole program (code + data + bss), loaded in place
     * ================================================================ */
    .text : {
        KEEP(*(.init))      /* crt0.S _start (apps with a C runtime) */
        *(.text*)
        *(.text.*)
    } > DDR

    .rodata : {
        *(EXCLUDE_FILE(*data3_big*) .rodata*)   /* radix2 FFT tables -> .ddr_rodata */
        *(.srodata*)
        . = ALIGN(4);
    } > DDR

    /* LMA == VMA: crt0's ROM->RAM copy loop self-copies (a no-op). */
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

    /* ================================================================
     * Opt-in cached-region sections, after the relocated program
     * ================================================================ */
    .ddr_text : {
        __ddr_text_start = .;
        *(.ddr_text*)
        . = ALIGN(4);
        __ddr_text_end = .;
    } > DDR

    .ddr_rodata : {
        __ddr_rodata_start = .;
        *data3_big*(.rodata*)   /* radix2-big-64k FFT reference data */
        *(.ddr_rodata*)
        . = ALIGN(4);
        __ddr_rodata_end = .;
    } > DDR

    .ddr_data : {
        __ddr_data_start = .;
        *(.ddr_data*)
        . = ALIGN(4);
        __ddr_data_end = .;
    } > DDR

    .ddr_bss (NOLOAD) : {
        __ddr_bss_start = .;
        *(.ddr_bss*)
        . = ALIGN(4);
        __ddr_bss_end = .;
    } > DDR

    /* Heap: the rest of the region (memory.c _sbrk allocates from here). */
    .ddr_heap (NOLOAD) : {
        . = ALIGN(16);
        _heap_start = .;
    } > DDR
    _heap_end = ORIGIN(DDR) + LENGTH(DDR);

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    /* ================================================================
     * GLOBAL SYMBOLS
     * ================================================================ */
    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);

    PROVIDE(UART_ADDR           = 0x40000000);
    PROVIDE(UART_RX_DATA_ADDR   = 0x40000004);
    PROVIDE(UART_RX_STATUS_ADDR = 0x40000024);
    PROVIDE(UART_TX_STATUS_ADDR = 0x40000028);
    PROVIDE(FIFO0_ADDR      = 0x40000008);
    PROVIDE(FIFO1_ADDR      = 0x4000000C);
    PROVIDE(MTIME_LO_ADDR    = 0x40000010);
    PROVIDE(MTIME_HI_ADDR    = 0x40000014);
    PROVIDE(MTIMECMP_LO_ADDR = 0x40000018);
    PROVIDE(MTIMECMP_HI_ADDR = 0x4000001C);
    PROVIDE(MSIP_ADDR        = 0x40000020);
}

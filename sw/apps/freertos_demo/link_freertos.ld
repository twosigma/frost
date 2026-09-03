/* Linker script for FreeRTOS on FROST (bram tier).
 * Derived from sw/common/link.ld with two differences: there is no .heap
 * section, because FreeRTOS heap_4.c carves task stacks and kernel objects
 * out of its own ucHeap array in .bss, and there are no cached-DDR sections,
 * so the whole program lives in the 256KiB low BRAM.
 * The memory sizes must match MEM_SIZE_BYTES in hw/rtl/frost.sv.
 */

ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 95K   /* Executable code + read-only data */
    DEBUG (rx): ORIGIN = 0x00017C00, LENGTH = 1K    /* debug-module slice: reserved, never allocated (hw/rtl/README.md) */

    /* RAM starts at 96K (0x18000), after ROM and the DEBUG slice */
    RAM (rwx) : ORIGIN = 0x00018000, LENGTH = 160K  /* Initialized data + BSS + stack + FreeRTOS heap */

    /* Memory-mapped peripherals, never data or code. These addresses must match
     * the MmioAddr constants in hw/rtl/cpu_and_mem/cpu_and_mem.sv and the
     * PROVIDE statements at the end of this file. */
    MMIO (rw) : ORIGIN = 0x40000000, LENGTH = 44    /* Peripherals: UART, FIFOs, Timer, MSIP */
}

/* The C stack grows down from the top of RAM; crt0.S initializes sp here. */
_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);

/* Kept for the upstream RISC-V port. port_frost_asm.S runs traps on the
 * interrupted task's stack and does not reference it. */
__freertos_irq_stack_top = _end_of_stack;

SECTIONS
{
    /* ================================================================
     * ROM SECTIONS (read-only)
     * ================================================================ */

    /* .text section - Executable code */
    .text : {
        KEEP(*(.init))      /* Startup code (crt0.S) - must be first */
        *(.text*)           /* All code sections */
        *(.text.*)
    } > ROM

    /* .rodata section - Read-only data (constants, strings) */
    .rodata : {
        *(.rodata*)         /* Large read-only data */
        *(.rodata.*)
        *(.srodata*)        /* Small read-only data (accessed via gp) */
        . = ALIGN(4);       /* Word-align for efficient access */
    } > ROM

    /* ================================================================
     * RAM SECTIONS (read-write, copied from ROM by crt0.S)
     * ================================================================ */

    /* .data section - Initialized global/static variables
     * Stored in ROM, copied to RAM by crt0.S before main() */
    .data : AT(ADDR(.rodata) + SIZEOF(.rodata)) {
        __data_load_start = LOADADDR(.data);   /* Source address in ROM */
        __data_start      = .;                 /* Destination address in RAM */

        *(.data*)           /* Initialized data */
        . = ALIGN(4);
    } > RAM

    /* .sdata section - Small initialized data, addressed gp-relative (within +/-2KB of gp) */
    .sdata : AT(LOADADDR(.data) + SIZEOF(.data)) {
        *(.sdata*)          /* Small initialized data */
        . = ALIGN(4);
        __data_end = .;     /* End of data to copy from ROM */
    } > RAM

    /* ================================================================
     * BSS SECTIONS (zeroed by crt0.S)
     * ================================================================ */

    /* .sbss section - Small uninitialized data (accessed via gp)
     * Zeroed by crt0.S before main() */
    .sbss : {
        __sbss_start = .;
        *(.sbss*)           /* Small uninitialized data */
        *(.scommon*)        /* Small common symbols */
        . = ALIGN(4);
        __sbss_end = .;
    } > RAM

    /* .bss section - Uninitialized global/static variables
     * Zeroed by crt0.S before main() */
    .bss : {
        __bss_start = .;
        *(.bss*)            /* Uninitialized data */
        *(COMMON)           /* Common symbols */
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /* No .heap section: FreeRTOS heap_4.c manages its own ucHeap array in .bss. */

    /* ================================================================
     * DISCARDED SECTIONS
     * ================================================================ */

    /* Drop C++ exception handling info (not used in bare-metal) */
    /DISCARD/ : {
        *(.eh_frame*)       /* Exception frame information */
        *(.eh_frame_hdr*)   /* Exception frame header */
    }

    /* ================================================================
     * GLOBAL SYMBOLS
     * ================================================================ */

    /* Global pointer: gp must be within +/-0x800 of every .sdata/.sbss object,
     * so it sits 0x800 past the start of small data. */
    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);

    /* Cached-region BSS bounds: nothing placed there by this script; empty
     * bounds keep crt0's .ddr_bss zeroing loop a no-op. */
    PROVIDE(__ddr_bss_start = 0);
    PROVIDE(__ddr_bss_end = 0);

    /* Memory-mapped peripheral addresses, referenced by C code through
     * sw/lib/include/mmio.h. They must match cpu_and_mem.sv. */
    PROVIDE(UART_ADDR          = 0x40000000);  /* UART transmit register */
    PROVIDE(UART_RX_DATA_ADDR  = 0x40000004);  /* UART receive data (read pops byte) */
    PROVIDE(FIFO0_ADDR          = 0x40000008);  /* MMIO FIFO 0 */
    PROVIDE(FIFO1_ADDR          = 0x4000000C);  /* MMIO FIFO 1 */
    /* CLINT-compatible timer registers (for RTOS support) */
    PROVIDE(MTIME_LO_ADDR       = 0x40000010);  /* mtime[31:0] - Machine timer low */
    PROVIDE(MTIME_HI_ADDR       = 0x40000014);  /* mtime[63:32] - Machine timer high */
    PROVIDE(MTIMECMP_LO_ADDR    = 0x40000018);  /* mtimecmp[31:0] - Timer compare low */
    PROVIDE(MTIMECMP_HI_ADDR    = 0x4000001C);  /* mtimecmp[63:32] - Timer compare high */
    PROVIDE(MSIP_ADDR           = 0x40000020);  /* Machine software interrupt pending */
    PROVIDE(UART_RX_STATUS_ADDR = 0x40000024); /* UART RX status (bit 0 = data available) */
    PROVIDE(UART_TX_STATUS_ADDR = 0x40000028); /* UART TX status (bit 0 = can accept byte) */
}

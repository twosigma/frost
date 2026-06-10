/* Linker script for the FROST URAM heap capacity test (uram_heap_test).
 *
 * Identical layout to the CoreMark-PRO app's coremark_pro.ld: code/.data/.bss/
 * stack live in the low BRAM, and the heap is placed in the high-address URAM
 * tier (URAM_BASE = 0x0100_0000, 2 MiB) so malloc can hand out multi-MB chunks
 * that the old ~1 MiB low-RAM heap could never satisfy. This is exactly the
 * layout the big CoreMark-PRO workloads use; the test allocates several MiB
 * from this heap and verifies it lands in (and reads back from) the URAM tier.
 *
 * Layout:
 *   ROM 512 KiB at 0x00000000  (code + read-only data)         -> low BRAM
 *   RAM 1536 KiB at 0x00080000 (data + bss + stack)            -> low BRAM
 *   URAM 2 MiB at 0x01000000   (heap, NOLOAD, 1.75 MiB usable)    -> UltraRAM tier
 *   MMIO at 0x40000000         (unchanged from link.ld)
 *
 * Every PROVIDE / symbol from link.ld is preserved so crt0.S and the FROST
 * libc keep resolving (__data_load_start/__data_start/__data_end, __sbss_*,
 * __bss_*, _heap_start/_heap_end, _stack_top, __global_pointer$, and the MMIO
 * peripheral addresses). MUST match frost.sv URAM_BASE / URAM_SIZE_BYTES.
 */

ENTRY(_start)

MEMORY
{
    /* Read-only memory region for code and constants. */
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 512K  /* Executable code + read-only data */

    /* Read-write memory region for variables and stack (the heap now lives in
     * the URAM tier below). Starts at 512K offset (0x80000) to follow ROM. */
    RAM (rwx) : ORIGIN = 0x00080000, LENGTH = 1536K /* Initialized data + BSS + stack */

    /* High-address UltraRAM memory tier (FROST "URAM tier"). Backs the
     * CoreMark-PRO heap so large working sets (loops ~6 MiB, zip ~3.3 MiB) fit
     * on-chip without growing the low BRAM. MUST match the RTL parameters in
     * frost.sv (URAM_BASE = 0x0100_0000, URAM_SIZE_BYTES = 2 MiB). The heap is
     * NOLOAD: URAM has no boot image, powering up zero in sim and on hardware. */
    URAM (rw) : ORIGIN = 0x01000000, LENGTH = 2M    /* CoreMark-PRO heap (UltraRAM) */

    /* Memory-mapped I/O peripheral region - DO NOT USE for regular data/code!
     * CRITICAL: If these addresses change, must also update:
     *   - hw/rtl/cpu_and_mem/cpu_and_mem.sv (MmioAddr constants)
     *   - This file's PROVIDE statements below
     */
    MMIO (rw) : ORIGIN = 0x40000000, LENGTH = 44    /* Peripherals: UART TX/RX, FIFOs, Timer, MSIP */
}

/* Stack configuration - C stack grows downward from top of RAM.
 * Stack pointer (sp) is initialized to this address in crt0.S. */
_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);

/* FreeRTOS ISR stack top - reuses main's stack after scheduler starts. */
__freertos_irq_stack_top = _end_of_stack;

SECTIONS
{
    /* ================================================================
     * ROM SECTIONS (Read-only, executed from flash/ROM)
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
     * RAM SECTIONS (Read-write, must be copied from ROM at startup)
     * ================================================================ */

    /* .data section - Initialized global/static variables
     * Stored in ROM, copied to RAM by crt0.S before main() */
    .data : AT(ADDR(.rodata) + SIZEOF(.rodata)) {
        __data_load_start = LOADADDR(.data);   /* Source address in ROM */
        __data_start      = .;                 /* Destination address in RAM */

        *(.data*)           /* Initialized data */
        . = ALIGN(4);
    } > RAM

    /* .sdata section - Small initialized data (accessed via global pointer)
     * Allows efficient access to frequently-used globals within ±2KB of gp */
    .sdata : AT(LOADADDR(.data) + SIZEOF(.data)) {
        *(.sdata*)          /* Small initialized data */
        . = ALIGN(4);
        __data_end = .;     /* End of data to copy from ROM */
    } > RAM

    /* ================================================================
     * BSS SECTIONS (Zero-initialized, created at runtime)
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

    /* .heap section - For dynamic heap allocations, placed in the URAM tier so
     * the malloc-heavy MITH workloads' large working sets (up to ~6 MiB for
     * loops) fit on-chip. NOLOAD: URAM powers up zero (no ROM image). _sbrk
     * (sw/lib/src/memory.c) grows from _heap_start toward _heap_end. */
    .heap (NOLOAD) : {
        . = ALIGN(8);
        _heap_start = .;
        . = . + 1792K;      /* 1.75 MiB heap (fits within the 2 MiB URAM tier) */
        _heap_end = .;
    } > URAM


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

    /* Global pointer (gp) for efficient small data access
     * Must be within ±2048 bytes (±0x800) of all .sdata/.sbss objects
     * Set to middle of small data region for optimal coverage */
    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);

    /* Memory-mapped I/O peripheral addresses
     * These symbols are referenced by C code (uart.c, fifo.h, timer.h, trap.h)
     * CRITICAL: Must match hardware addresses in cpu_and_mem.sv */
    PROVIDE(UART_ADDR           = 0x40000000);  /* UART transmit register (write-only) */
    PROVIDE(UART_RX_DATA_ADDR   = 0x40000004);  /* UART receive data (read consumes byte) */
    PROVIDE(UART_RX_STATUS_ADDR = 0x40000024);  /* UART RX status (bit 0 = data available) */
    PROVIDE(UART_TX_STATUS_ADDR = 0x40000028);  /* UART TX status (bit 0 = can accept byte) */
    PROVIDE(FIFO0_ADDR      = 0x40000008);  /* MMIO FIFO 0 */
    PROVIDE(FIFO1_ADDR      = 0x4000000C);  /* MMIO FIFO 1 */
    /* CLINT-compatible timer registers (for RTOS support) */
    PROVIDE(MTIME_LO_ADDR    = 0x40000010);  /* mtime[31:0] - Machine timer low */
    PROVIDE(MTIME_HI_ADDR    = 0x40000014);  /* mtime[63:32] - Machine timer high */
    PROVIDE(MTIMECMP_LO_ADDR = 0x40000018);  /* mtimecmp[31:0] - Timer compare low */
    PROVIDE(MTIMECMP_HI_ADDR = 0x4000001C);  /* mtimecmp[63:32] - Timer compare high */
    PROVIDE(MSIP_ADDR        = 0x40000020);  /* Machine software interrupt pending */
}

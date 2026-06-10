/* Linker script for FROST CoreMark-PRO bare-metal apps.
 *
 * Derived from sw/common/link.ld. The only substantive differences are the
 * ROM/RAM split and the heap placement: several official CoreMark-PRO
 * workloads need more than the shared link.ld's 32 KiB low RAM, and the MITH
 * harness allocates its large working buffers from malloc.
 *
 * The low-memory layout below must match the current X3 hardware programming
 * path and CPU BRAM address width: MEM_SIZE_BYTES is 128 KiB, and the JTAG
 * AXI-to-BRAM controller exposes a 128 KiB address range. Keep every low-memory
 * VMA inside [0, 128 KiB), or data accesses will alias in hardware.
 *
 * Layout:
 *   ROM  64 KiB at 0x00000000  (code + read-only data)
 *   RAM  64 KiB at 0x00010000  (data + bss)
 *   URAM  2 MiB at 0x01000000  (malloc heap + stack)
 *   MMIO       at 0x40000000   (unchanged from link.ld)
 *
 * Every PROVIDE / symbol from link.ld is preserved so crt0.S and the FROST
 * libc keep resolving (__data_load_start/__data_start/__data_end, __sbss_*,
 * __bss_*, _heap_start/_heap_end, _stack_top, __global_pointer$, and the MMIO
 * peripheral addresses).
 */

ENTRY(_start)

MEMORY
{
    /* Read-only memory region for code and constants. */
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K   /* Executable code + read-only data */

    /* Read-write memory region for variables (the heap and stack now live in
     * the URAM tier below). Starts at 64 KiB to follow ROM and stays inside the
     * 128 KiB low-BRAM hardware window. */
    RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 64K   /* Initialized data + BSS */

    /* High-address UltraRAM memory tier (FROST "URAM tier"). Backs the
     * CoreMark-PRO heap so large working sets (loops ~6 MiB, zip ~3.3 MiB) fit
     * on-chip without growing the low BRAM. MUST match the RTL parameters in
     * frost.sv (URAM_BASE = 0x0100_0000, URAM_SIZE_BYTES = 2 MiB). The heap is
     * NOLOAD: URAM has no boot image, powering up zero in sim and on hardware. */
    URAM (rw) : ORIGIN = 0x01000000, LENGTH = 2M    /* CoreMark-PRO heap + stack (UltraRAM) */

    /* Memory-mapped I/O peripheral region - DO NOT USE for regular data/code!
     * CRITICAL: If these addresses change, must also update:
     *   - hw/rtl/cpu_and_mem/cpu_and_mem.sv (MmioAddr constants)
     *   - This file's PROVIDE statements below
     */
    MMIO (rw) : ORIGIN = 0x40000000, LENGTH = 44    /* Peripherals: UART TX/RX, FIFOs, Timer, MSIP */
}

/* Stack configuration - C stack grows downward from the top of URAM.
 *
 * The parser workload's ezxml_free() cleanup recursively walks thousands of
 * ordered siblings; that can consume well over the low 64 KiB RAM window.
 * Measured stack high-water on X3 hardware (crt0 paint + exit() scan,
 * 2026-06-10, both -v1 and official -v0 configs): parser 77,152 B; cjpeg
 * 3,164 B; all others 1,696 B. The 112 KiB reserve keeps a 1.45x margin
 * over parser while freeing 144 KiB for the heap, which is what lets the
 * official cjpeg config reach the 10s score rule at -i41. */
_end_of_stack = ORIGIN(URAM) + LENGTH(URAM);
__stack_bottom = _end_of_stack - 112K;
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
        . = . + 1936K;      /* heap + 112 KiB stack reserve = 2 MiB URAM tier */
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

    __low_bram_end = ORIGIN(RAM) + LENGTH(RAM);
    __low_load_image_end = LOADADDR(.sdata) + SIZEOF(.sdata);
}

ASSERT(__low_load_image_end <= __low_bram_end, "CoreMark-PRO load image exceeds the 128 KiB low-BRAM hardware window")
ASSERT(__bss_end <= __low_bram_end, "CoreMark-PRO data/BSS exceeds the 64 KiB low-RAM hardware window")
ASSERT(_heap_end <= __stack_bottom, "CoreMark-PRO URAM heap overlaps the reserved 112 KiB stack")

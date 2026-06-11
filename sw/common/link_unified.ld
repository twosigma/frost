/* DRAFT — unified linker script for FROST RISC-V bare-metal programs (all boards, all sims)
 *
 * Status: Phase-0 draft, NOT yet wired into any build. Replaces link.ld,
 * coremark_pro.ld, and uram_heap_test.ld once the cache+DDR hierarchy lands.
 *
 * Memory model (identical on Genesys2 and X3 — cache hierarchy is opaque):
 *   [0x00000000, 0x00040000)  256KiB fast BRAM, uncached, 1-cycle, JTAG-loadable
 *       ROM  96KiB: .text + small .rodata (+ .data/.sdata load image)
 *       RAM 160KiB: .data/.sdata/.sbss/.bss + stack (top at 0x40000)
 *   [0x40000000, +44B)        MMIO (unchanged)
 *   [0x80000000, +1GiB)       cached region, DDR-backed, loadable
 *       .ddr_rodata/.ddr_data: large loaded sections (e.g. radix2 FFT tables)
 *       .ddr_bss:              large zero-init sections (zeroed by crt0)
 *       .ddr_heap:             everything else, to the end of the gigabyte
 *
 * Hardware coupling:
 *   - 256KiB low region must match MEM_SIZE_BYTES (hw/rtl/frost.sv) and the
 *     axi_bram_ctrl MEM_DEPTH in fpga/build/build_step.tcl (65536 words).
 *   - 0x80000000 must match the cached-region base in the data-mem router
 *     (replaces URAM_BASE 0x01000000 when the cache hierarchy lands).
 *   - MMIO addresses must match cpu_and_mem.sv MmioAddr constants.
 *
 * Image emission (two files; loader/sim write the regions separately):
 *   sw.mem      = objcopy -O verilog -R '.ddr_*' ...        (low BRAM image)
 *   sw_ddr.mem  = objcopy -O verilog -j .ddr_rodata -j .ddr_data
 *                   --change-addresses -0x80000000 ...      (DDR image, region-relative)
 *
 * Stack: lives in low BRAM for ALL programs (fast, uncached). The 112KiB
 * reserve below is the measured CoreMark-PRO high-water (parser) + margin;
 * the ASSERT keeps any program's data+bss from silently eating into it.
 *
 * .ddr_data caveat: loaded in place at its runtime address (LMA == VMA);
 * unlike low .data it is NOT re-initialized by crt0 on a reset without a
 * reload. The JTAG/sim flow always reloads, so this only matters if a future
 * flow restarts the CPU without rewriting memory.
 */

ENTRY(_start)

MEMORY
{
    ROM  (rx)  : ORIGIN = 0x00000000, LENGTH = 96K    /* code + read-only data */
    RAM  (rwx) : ORIGIN = 0x00018000, LENGTH = 160K   /* data + bss + stack */
    DDR  (rwx) : ORIGIN = 0x80000000, LENGTH = 1024M  /* cached region: big data + heap */
    MMIO (rw)  : ORIGIN = 0x40000000, LENGTH = 44     /* peripherals: UART, FIFOs, timer, MSIP */
}

/* Stack grows downward from the top of low RAM (0x00040000).
 * sp is initialized to this address in crt0.S */
_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);

/* Measured CoreMark-PRO stack high-water is 112KiB (parser); reserve it for
 * every program so the data+bss fit check below is a real guarantee. */
__stack_reserve = 112K;

/* FreeRTOS ISR stack top - reuses main's stack after scheduler starts */
__freertos_irq_stack_top = _end_of_stack;

SECTIONS
{
    /* ================================================================
     * ROM SECTIONS (read-only, executed in place)
     * ================================================================ */

    .text : {
        KEEP(*(.init))      /* Startup code (crt0.S) - must be first */
        *(.text*)
        *(.text.*)
    } > ROM

    /* Small/hot read-only data stays in fast BRAM. Large datasets destined
     * for the cached region are EXCLUDEd here and collected in .ddr_rodata
     * below — add one EXCLUDE_FILE glob per big-data object. Objects can
     * also opt in explicitly with __attribute__((section(".ddr_rodata"))). */
    .rodata : {
        *(EXCLUDE_FILE(*data3_big*) .rodata*)   /* radix2-big-64k FFT tables -> DDR */
        *(.srodata*)        /* Small read-only data (accessed via gp) */
        . = ALIGN(4);
    } > ROM

    /* ================================================================
     * RAM SECTIONS (read-write, copied from ROM by crt0.S)
     * ================================================================ */

    .data : AT(ADDR(.rodata) + SIZEOF(.rodata)) {
        __data_load_start = LOADADDR(.data);   /* Source address in ROM */
        __data_start      = .;                 /* Destination address in RAM */
        *(.data*)
        . = ALIGN(4);
    } > RAM

    .sdata : AT(LOADADDR(.data) + SIZEOF(.data)) {
        *(.sdata*)
        . = ALIGN(4);
        __data_end = .;     /* End of data to copy from ROM */
    } > RAM

    /* ================================================================
     * BSS SECTIONS (zero-initialized by crt0.S)
     * ================================================================ */

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

    /* ================================================================
     * DDR SECTIONS (cached region; loaded directly by JTAG/sim, not crt0)
     * ================================================================ */

    /* Large read-only datasets (LMA == VMA; written by the loader). */
    .ddr_rodata : {
        __ddr_rodata_start = .;
        *data3_big*(.rodata*)   /* radix2-big-64k 64K-point FFT reference data */
        *(.ddr_rodata*)         /* explicit opt-in via section attribute */
        . = ALIGN(4);
        __ddr_rodata_end = .;
    } > DDR

    /* Large initialized read-write data (LMA == VMA; see caveat in header). */
    .ddr_data : {
        __ddr_data_start = .;
        *(.ddr_data*)
        . = ALIGN(4);
        __ddr_data_end = .;
    } > DDR

    /* Large zero-initialized data; zeroed by crt0 (Phase-1 crt0 addition). */
    .ddr_bss (NOLOAD) : {
        __ddr_bss_start = .;
        *(.ddr_bss*)
        . = ALIGN(4);
        __ddr_bss_end = .;
    } > DDR

    /* Heap: the rest of the gigabyte. memory.c's _sbrk allocates
     * [_heap_start, _heap_end); no fixed size carved out here. */
    .ddr_heap (NOLOAD) : {
        . = ALIGN(16);
        _heap_start = .;
    } > DDR
    _heap_end = ORIGIN(DDR) + LENGTH(DDR);

    /* ================================================================
     * DISCARDED SECTIONS
     * ================================================================ */

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    /* ================================================================
     * GLOBAL SYMBOLS
     * ================================================================ */

    /* Global pointer (gp) for efficient small data access
     * Must be within ±2048 bytes (±0x800) of all .sdata/.sbss objects */
    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);

    /* Memory-mapped I/O peripheral addresses
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

/* ====================================================================
 * FIT CHECKS
 * ==================================================================== */

/* ROM load image (text + rodata + data/sdata copy source) must fit ROM.
 * .data/.sdata use AT(expr), which ld does not check against the region. */
ASSERT(LOADADDR(.sdata) + SIZEOF(.sdata) <= ORIGIN(ROM) + LENGTH(ROM),
       "ROM overflow: .text + .rodata + .data/.sdata load image exceeds 96K")

/* RAM data+bss must leave the full stack reserve free below _stack_top. */
ASSERT(__bss_end <= _end_of_stack - __stack_reserve,
       "RAM overflow: data+bss eats into the 112K stack reserve")

/* DDR-tier linker script for FreeRTOS on FROST RISC-V
 *
 * The ddr counterpart to link_freertos.ld (selected by the Makefile when
 * MEM_CONFIG=ddr). A minimal boot stub (../../common/crt0_ddr_boot.S, .boot)
 * runs from the low BRAM ROM and far-jumps to the DDR-resident _start; the
 * WHOLE program -- code, data, bss, AND the FreeRTOS heap (ucHeap in .bss) --
 * lives in the cached DDR region at 0x8000_0000, fetched through the L1I and
 * loaded/stored through the L1D. The stack stays in low BRAM (fast, uncached);
 * FreeRTOS task stacks come from its heap, which moves to DDR -- expected.
 *
 * DDR sections load in place (LMA == VMA): the sim preloads the behavioral DDR
 * from sw_ddr.mem, so crt0's .data copy loop self-copies (a no-op).
 *
 * Like link_freertos.ld this has NO heap section (FreeRTOS heap_4.c manages its
 * own ucHeap array in .bss) and no opt-in .ddr_* big-data sections.
 *
 * Image emission (MEM_CONFIG=ddr, via common.mk):
 *   sw.mem     = objcopy -R <whole program>   (the ROM boot stub only)
 *   sw_ddr.mem = objcopy -j <whole program> --change-addresses -0x80000000
 *
 * IMPORTANT: Memory sizes here must match MEM_SIZE_BYTES in hw/rtl/frost.sv.
 */

ENTRY(_start)

MEMORY
{
    ROM  (rx)  : ORIGIN = 0x00000000, LENGTH = 96K    /* boot stub only */
    RAM  (rwx) : ORIGIN = 0x00018000, LENGTH = 160K   /* stack (top at 0x40000) */
    DDR  (rwx) : ORIGIN = 0x80000000, LENGTH = 1024M  /* whole program + FreeRTOS heap (in .bss) */
    MMIO (rw)  : ORIGIN = 0x40000000, LENGTH = 44     /* Peripherals: UART, FIFOs, Timer, MSIP */
}

/* Stack stays in low BRAM (fast, uncached). sp is initialized to this in crt0.S */
_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);

/* FreeRTOS ISR stack top - reuses main's stack after scheduler starts */
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

    /* .text section - Executable code */
    .text : {
        KEEP(*(.init))      /* Startup code (crt0.S) - must be first */
        *(.text*)           /* All code sections */
        *(.text.*)
    } > DDR

    /* .rodata section - Read-only data (constants, strings) */
    .rodata : {
        *(.rodata*)         /* Large read-only data */
        *(.rodata.*)
        *(.srodata*)        /* Small read-only data (accessed via gp) */
        . = ALIGN(4);
    } > DDR

    /* .data section - Initialized global/static variables.
     * LMA == VMA: crt0's ROM->RAM copy loop self-copies (a no-op). */
    .data : {
        __data_load_start = .;                 /* Source address (== dest in DDR) */
        __data_start      = .;                 /* Destination address */
        *(.data*)           /* Initialized data */
        . = ALIGN(4);
    } > DDR

    /* .sdata section - Small initialized data (accessed via global pointer) */
    .sdata : {
        *(.sdata*)          /* Small initialized data */
        . = ALIGN(4);
        __data_end = .;     /* End of data to copy (no-op) */
    } > DDR

    /* ================================================================
     * BSS SECTIONS (Zero-initialized by crt0.S) -- includes FreeRTOS ucHeap
     * ================================================================ */

    /* .sbss section - Small uninitialized data (accessed via gp) */
    .sbss : {
        __sbss_start = .;
        *(.sbss*)           /* Small uninitialized data */
        *(.scommon*)        /* Small common symbols */
        . = ALIGN(4);
        __sbss_end = .;
    } > DDR

    /* .bss section - Uninitialized global/static variables (FreeRTOS ucHeap) */
    .bss : {
        __bss_start = .;
        *(.bss*)            /* Uninitialized data */
        *(COMMON)           /* Common symbols */
        . = ALIGN(4);
        __bss_end = .;
    } > DDR

    /* NOTE: No .heap section - FreeRTOS heap_4.c manages its own heap (ucHeap array in BSS) */

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
     * Must be within +/-2048 bytes (+/-0x800) of all .sdata/.sbss objects */
    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);

    /* Cached-region BSS bounds: nothing placed in the opt-in .ddr_bss section by
     * this script; empty bounds keep crt0's .ddr_bss zeroing loop a no-op (the
     * program's own .bss above is zeroed by the regular .bss loop). */
    PROVIDE(__ddr_bss_start = 0);
    PROVIDE(__ddr_bss_end = 0);

    /* Memory-mapped I/O peripheral addresses
     * These symbols are referenced by C code (uart.c, fifo.h, timer.h, trap.h)
     * CRITICAL: Must match hardware addresses in cpu_and_mem.sv */
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

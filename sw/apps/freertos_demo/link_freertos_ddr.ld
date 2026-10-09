/* DDR-tier linker script for FreeRTOS on FROST.
 *
 * MEM_CONFIG=ddr selects this script. The .boot stub in crt0_ddr_boot.S
 * runs from low BRAM and jumps to _start in cached DDR at 0x8000_0000.
 * Code uses L1I; data and the FreeRTOS heap use L1D. The startup stack
 * stays in uncached BRAM; task stacks come from the DDR heap.
 *
 * DDR sections load in place (LMA == VMA): the sim preloads the behavioral DDR
 * from sw_ddr.mem, so crt0's .data copy loop self-copies (a no-op).
 *
 * As in link_freertos.ld there is no .heap section (FreeRTOS heap_4.c manages
 * its own ucHeap array in .bss) and no opt-in .ddr_* big-data sections.
 *
 * Image emission (MEM_CONFIG=ddr, via common.mk):
 *   sw.mem     = objcopy -R <whole program>   (the ROM boot stub only)
 *   sw_ddr.mem = objcopy -j <whole program> --change-addresses -0x80000000
 *
 * The memory sizes must match MEM_SIZE_BYTES in hw/rtl/frost.sv.
 */

ENTRY(_start)

MEMORY
{
    ROM  (rx)  : ORIGIN = 0x00000000, LENGTH = 95K    /* boot stub only */
    DEBUG (rx) : ORIGIN = 0x00017C00, LENGTH = 1K    /* debug-module slice: reserved, never allocated (hw/rtl/README.md) */
    RAM  (rwx) : ORIGIN = 0x00018000, LENGTH = 160K   /* stack (top at 0x40000) */
    DDR  (rwx) : ORIGIN = 0x80000000, LENGTH = 1024M  /* whole program + FreeRTOS heap (in .bss) */
    MMIO (rw)  : ORIGIN = 0x40000000, LENGTH = 44     /* Peripherals: UART, FIFOs, Timer, MSIP */
}

/* crt0.S initializes the startup stack in uncached BRAM. */
_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);

/* Only the upstream RISC-V port uses this symbol. port_frost_asm.S runs traps
 * on the interrupted task's stack. */
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
        KEEP(*(.init))      /* Startup code (crt0.S): first; the boot stub jumps to 0x80000000 */
        *(.text*)           /* All code sections */
        *(.text.*)
    } > DDR

    .rodata : {
        *(.rodata*)         /* Large read-only data */
        *(.rodata.*)
        *(.srodata*)        /* Small read-only data */
        . = ALIGN(4);
    } > DDR

    .data : {
        __data_load_start = .;                 /* Source address (== dest in DDR) */
        __data_start      = .;                 /* Destination address */
        *(.data*)           /* Initialized data */
        . = ALIGN(4);
    } > DDR

    .sdata : {
        *(.sdata*)          /* Small initialized data */
        . = ALIGN(4);
        __data_end = .;     /* End of data to copy (no-op) */
    } > DDR

    /* ================================================================
     * BSS SECTIONS (zeroed by crt0.S; includes the FreeRTOS ucHeap)
     * ================================================================ */

    .sbss : {
        __sbss_start = .;
        *(.sbss*)           /* Small uninitialized data */
        *(.scommon*)        /* Small common symbols */
        . = ALIGN(4);
        __sbss_end = .;
    } > DDR

    .bss : {
        __bss_start = .;
        *(.bss*)            /* Uninitialized data */
        *(COMMON)           /* Common symbols */
        . = ALIGN(4);
        __bss_end = .;
    } > DDR

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

    /* gp-relative offsets span -2048 to 2047 bytes. This covers the first
     * 4 KiB of small data. */
    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);

    /* Empty .ddr_bss bounds skip crt0's optional DDR zeroing loop.
     * The regular .bss loop clears the program's BSS. */
    PROVIDE(__ddr_bss_start = 0);
    PROVIDE(__ddr_bss_end = 0);

    /* Memory-mapped peripheral addresses, referenced by C code through
     * sw/lib/include/mmio.h. They must match cpu_and_mem.sv. */
    PROVIDE(UART_ADDR          = 0x40000000);  /* UART transmit register */
    PROVIDE(UART_RX_DATA_ADDR  = 0x40000004);  /* UART receive data (read pops byte) */
    PROVIDE(FIFO0_ADDR          = 0x40000008);  /* MMIO FIFO 0 */
    PROVIDE(FIFO1_ADDR          = 0x4000000C);  /* MMIO FIFO 1 */
    /* Machine timer registers */
    PROVIDE(MTIME_LO_ADDR       = 0x40000010);  /* mtime[31:0] - Machine timer low */
    PROVIDE(MTIME_HI_ADDR       = 0x40000014);  /* mtime[63:32] - Machine timer high */
    PROVIDE(MTIMECMP_LO_ADDR    = 0x40000018);  /* mtimecmp[31:0] - Timer compare low */
    PROVIDE(MTIMECMP_HI_ADDR    = 0x4000001C);  /* mtimecmp[63:32] - Timer compare high */
    PROVIDE(MSIP_ADDR           = 0x40000020);  /* Machine software interrupt pending */
    PROVIDE(UART_RX_STATUS_ADDR = 0x40000024); /* UART RX status (bit 0 = data available) */
    PROVIDE(UART_TX_STATUS_ADDR = 0x40000028); /* UART TX status (bit 0 = TX ready) */
}

/* crt0_ddr_boot.S jumps to 0x8000_0000, so _start must be at the DDR origin. */
ASSERT(_start == ORIGIN(DDR), "link_freertos_ddr.ld: _start must sit at ORIGIN(DDR) (the rv64 boot stub jumps to the constant 0x80000000)")

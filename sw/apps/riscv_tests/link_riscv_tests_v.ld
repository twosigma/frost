/* Virtual riscv-tests environment in cached DDR. env_v/entry.S and vm.c
 * share an image with the user test at DRAM_BASE. The kernel uses a 2 MiB
 * superpage at the top of the address space; user pages are demand-paged
 * copies into frames above the image, with VAs equal to image offsets.
 * crt0_riscv_tests_ddr.S boots from ROM; entry.S zeroes .sbss and .bss.
 * Assertions keep _start at DRAM_BASE and the image plus 16 KiB kernel
 * stack below the user frames at DRAM_BASE + 64 pages. */

ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 95K
    DEBUG (rx): ORIGIN = 0x00017C00, LENGTH = 1K  /* debug-module slice: reserved, never allocated */
    RAM (rwx) : ORIGIN = 0x00018000, LENGTH = 160K

    DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 64M

    MMIO (rw) : ORIGIN = 0x40000000, LENGTH = 40
}

SECTIONS
{
    /* ROM boot stub only: far-jump to the DDR-resident _start. */
    .boot : {
        KEEP(*(.boot))
    } > ROM

    .text : {
        KEEP(*(.text.init))
        . = ALIGN(0x1000);
        *(.text*)
        *(.text.*)
    } > DDR

    .rodata : {
        *(.rodata*)
        *(.rodata.*)
        *(.srodata*)
        . = ALIGN(8);
    } > DDR

    .data : {
        . = ALIGN(0x1000);
        __data_load_start = .;
        __data_start      = .;
        *(.data*)
        . = ALIGN(8);
    } > DDR

    .sdata : {
        *(.sdata*)
        . = ALIGN(8);
        __data_end = .;
    } > DDR

    .sbss : {
        /* Kernel globals must not share a page with user test data. A kernel
         * write would change the backing image without changing the user's
         * copy, falsely failing evict()'s PTE_D check on a page the test has
         * only read. */
        . = ALIGN(0x1000);
        __sbss_start = .;
        *(.sbss*)
        *(.scommon*)
        . = ALIGN(8);
        __sbss_end = .;
    } > DDR

    .bss : {
        . = ALIGN(0x1000);
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > DDR

    .tohost : {
        *(.tohost)
    } > DDR

    _end = .;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);
}

ASSERT(_start == ORIGIN(DDR), "link_riscv_tests_v.ld: _start must sit at DRAM_BASE")
ASSERT(_end + 0x4000 <= ORIGIN(DDR) + 64 * 0x1000,
       "link_riscv_tests_v.ld: image + stack overlap the demand-paged user frames")

/* Linker script for riscv-tests on Frost -- VIRTUAL environment (-v).
 *
 * The upstream env/v layout in the cached DDR region: the kernel
 * (env_v/entry.S + vm.c) and the user test share one image at DRAM_BASE;
 * user pages are demand-paged copies of that image (user VA = image
 * offset) into frames above it, and the kernel runs translated through a
 * 2 MiB superpage at the top of the address space. A ROM boot stub
 * (crt0_riscv_tests_ddr.S) far-jumps to the DDR-resident _start; DDR
 * sections load in place from sw_ddr.mem; .bss (page tables, free lists)
 * is zeroed by the entry. The whole image must stay below the user frames
 * (DRAM_BASE + 64 pages), which the ASSERT below pins.
 */

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
        /* Page-aligned like .bss below: env_v's kernel globals (freelist
         * head/tail, the translated flag) must not share a 4 KiB page with
         * test data. User pages are demand-paged COPIES of this image, so a
         * kernel write through its own VA to a page the user also maps
         * silently diverges the copy from its backing -- and evict()'s
         * frame-vs-backing memcmp then trips its PTE_D assertion on a page
         * the test only ever read (rv64ui-v-ld / -lw: tdat at 0x3000 shared
         * a page with freelist_tail at 0x3020). Store tests masked it by
         * dirtying the page. */
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

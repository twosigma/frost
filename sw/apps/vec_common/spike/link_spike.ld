/* Linker script for the Spike reference run: 4 MiB of RAM at 0x80000000
 * (spike -m0x80000000:0x400000). The stack sits 64 KiB below the end so
 * the last page is free for the fault-only-first cases. */
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4M
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
    } > RAM

    .data : ALIGN(16) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    .tohost : ALIGN(0x1000) {
        *(.tohost)
    } > RAM

    .bss : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM

    __vt_ram_end = ORIGIN(RAM) + LENGTH(RAM);
    _stack_top   = __vt_ram_end - 0x10000;
    PROVIDE(__global_pointer$ = ADDR(.data) + 0x800);

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.riscv.attributes) }
}

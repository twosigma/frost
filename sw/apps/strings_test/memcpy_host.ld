/* Link script for the Spike-hosted memcpy harness: everything in Spike's DRAM. */
ENTRY(_start)
SECTIONS
{
    . = 0x80000000;
    .text : { *(.text.init) *(.text .text.*) }
    . = ALIGN(0x1000);
    .tohost : { *(.tohost) }
    .rodata : { *(.rodata .rodata.*) }
    .data : { *(.data .data.*) *(.sdata .sdata.*) }
    .bss : { *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON) }
}

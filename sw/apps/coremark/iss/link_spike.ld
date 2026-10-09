/* Flat image for Spike: everything at DRAM_BASE, including the .tohost section
 * that holds the HTIF tohost/fromhost words Spike watches for the exit write.
 * Independent of sw/common/link.ld, because this harness never runs on FROST. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text .text.*) }
  . = ALIGN(64);
  .tohost : { *(.tohost) }
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) }
  .data : { *(.data .data.*) }
  . = ALIGN(8);
  __global_pointer$ = . + 0x800;
  .sdata : { *(.sdata .sdata.*) }
  .sbss : { __bss_start = .; *(.sbss .sbss.*) }
  .bss : { *(.bss .bss.*) *(COMMON) . = ALIGN(4); __bss_end = .; }
  . = ALIGN(16);
  . = . + 0x40000;
  _stack_top = .;
}

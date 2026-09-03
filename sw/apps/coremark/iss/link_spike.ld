/* Flat image for Spike: everything at DRAM_BASE, HTIF tohost/fromhost exported
 * so the simulator can see the exit write.  Deliberately independent of
 * ../../common/link.ld -- this harness never runs on FROST hardware. */
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

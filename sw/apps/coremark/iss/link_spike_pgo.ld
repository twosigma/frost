/* Spike PGO-training image: link_spike.ld plus the .gcov_info table that
 * -fprofile-info-section emits, with the start/end symbols the freestanding
 * dumper in pgo_dump.c walks.  Measurement tooling only (README.md); no FROST
 * image is ever linked with this script. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text .text.*) }
  . = ALIGN(64);
  .tohost : { *(.tohost) }
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) }
  . = ALIGN(8);
  /* KEEP: nothing references these pointers, so --gc-sections would drop the
   * whole profile otherwise. */
  .gcov_info : {
    PROVIDE(__gcov_info_start = .);
    KEEP(*(.gcov_info))
    PROVIDE(__gcov_info_end = .);
  }
  .data : { *(.data .data.*) *(.got .got.*) }
  . = ALIGN(8);
  __global_pointer$ = . + 0x800;
  .sdata : { *(.sdata .sdata.*) }
  .sbss : { __bss_start = .; *(.sbss .sbss.*) }
  .bss : { *(.bss .bss.*) *(COMMON) . = ALIGN(4); __bss_end = .; }
  . = ALIGN(16);
  . = . + 0x40000;
  _stack_top = .;
}

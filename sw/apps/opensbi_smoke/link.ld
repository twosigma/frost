/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/* OpenSBI fw_jump enters the S-mode payload at DDR +2 MiB with a0 = hart ID
 * and a1 = DTB address. linux/buildroot-external/board/frost/frost_boot_image.py
 * places the DTB at +16 MiB or beyond the raw binary, whichever is later.
 * The packer cannot see NOLOAD sections, so LENGTH = 14M keeps the entire
 * program, including bss and stack, below +16 MiB. */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    DDR (rwx) : ORIGIN = 0x80200000, LENGTH = 14M
}

SECTIONS
{
    .text : {
        KEEP(*(.init))
        *(.text .text.*)
    } > DDR

    .rodata : {
        . = ALIGN(8);
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > DDR

    .data : {
        . = ALIGN(8);
        *(.data .data.*)
    } > DDR

    .sdata : {
        . = ALIGN(8);
        *(.sdata .sdata.*)
    } > DDR

    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);

    .sbss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start = .;
        *(.sbss .sbss.*)
    } > DDR

    .bss (NOLOAD) : {
        . = ALIGN(4096);
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > DDR

    .stack (NOLOAD) : {
        . = ALIGN(16);
        . += 64K;
        _stack_top = .;
    } > DDR
}

ASSERT(_start == ORIGIN(DDR), "link.ld: _start must sit at the payload slot (0x80200000)")

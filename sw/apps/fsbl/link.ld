/*
 *    Copyright 2026 John Goodacre
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

/* Linker script for FROST 2nd-Stage Bootloader (FSBL) in on-chip SRAM.
 * Loaded by Core Boot ROM from SPI NOR flash into [0x00004000, 0x00017C00).
 * Uses [0x00018000, 0x00040000) for data, BSS, and stack.
 */

ENTRY(_start)

MEMORY
{
    ROM   (rx)  : ORIGIN = 0x00004000, LENGTH = 79K
    DEBUG (rx)  : ORIGIN = 0x00017C00, LENGTH = 1K
    RAM   (rwx) : ORIGIN = 0x00018000, LENGTH = 160K
    DDR   (rwx) : ORIGIN = 0x80000000, LENGTH = 1024M
    MMIO  (rw)  : ORIGIN = 0x40000000, LENGTH = 44
}

_end_of_stack = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(_stack_top = _end_of_stack);
__stack_reserve = 64K;
__freertos_irq_stack_top = _end_of_stack;

SECTIONS
{
    .text : {
        KEEP(*(.init))
        *(.text*)
        *(.text.*)
    } > ROM

    .rodata : {
        *(.rodata*)
        *(.srodata*)
        . = ALIGN(4);
    } > ROM

    .data : AT(ADDR(.rodata) + SIZEOF(.rodata)) {
        __data_load_start = LOADADDR(.data);
        __data_start      = .;
        *(.data*)
        *(.got .got.*)
        . = ALIGN(4);
    } > RAM

    .sdata : AT(LOADADDR(.data) + SIZEOF(.data)) {
        *(.sdata*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM

    .sbss : {
        __sbss_start = .;
        *(.sbss*)
        *(.scommon*)
        . = ALIGN(4);
        __sbss_end = .;
    } > RAM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    .ddr_text : {
        __ddr_text_start = .;
        __ddr_text_end = .;
    } > DDR

    .ddr_rodata : {
        __ddr_rodata_start = .;
        __ddr_rodata_end = .;
    } > DDR

    .ddr_data : {
        __ddr_data_start = .;
        __ddr_data_end = .;
    } > DDR

    .ddr_bss (NOLOAD) : {
        __ddr_bss_start = .;
        __ddr_bss_end = .;
    } > DDR

    /DISCARD/ : {
        *(.eh_frame*)
        *(.eh_frame_hdr*)
    }

    PROVIDE(__global_pointer$ = ADDR(.sdata) + 0x800);

    PROVIDE(UART_ADDR           = 0x40000000);
    PROVIDE(UART_RX_DATA_ADDR   = 0x40000004);
    PROVIDE(UART_RX_STATUS_ADDR = 0x40000024);
    PROVIDE(UART_TX_STATUS_ADDR = 0x40000028);
    PROVIDE(FIFO0_ADDR          = 0x40000008);
    PROVIDE(FIFO1_ADDR          = 0x4000000C);
    PROVIDE(MTIME_LO_ADDR       = 0x40000010);
    PROVIDE(MTIME_HI_ADDR       = 0x40000014);
    PROVIDE(MTIMECMP_LO_ADDR    = 0x40000018);
    PROVIDE(MTIMECMP_HI_ADDR    = 0x4000001C);
    PROVIDE(MSIP_ADDR           = 0x40000020);
    PROVIDE(DMA_ENGINE_ADDR     = 0x40020000);
    PROVIDE(MEMORY_ERROR_ADDR   = 0x40021000);
    PROVIDE(NIC_ADDR            = 0x40030000);
}

ASSERT(LOADADDR(.sdata) + SIZEOF(.sdata) <= ORIGIN(ROM) + LENGTH(ROM),
       "FSBL ROM overflow: loaded image exceeds 79 KiB executable SRAM")
ASSERT(__bss_end <= _end_of_stack - __stack_reserve,
       "FSBL RAM overflow: data + bss exceeds SRAM allocation")


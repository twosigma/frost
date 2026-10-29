#    Copyright 2026 John Goodacre
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# FROST Core Boot ROM: executes at reset from 0x0000_0000 in on-chip BRAM,
# loads the 2nd-Stage Bootloader (FSBL) from SPI NOR flash (0x0300_0000) into
# on-chip SRAM (0x0000_4000), verifies its IEEE CRC-32 checksum, and jumps to it.
FPGA_CPU_CLK_FREQ ?= 200000000

OPT_LEVEL     := -Os
UNROLL_LOOPS  :=
LINKER_SCRIPT := link.ld
SRC_C         := ../../lib/src/uart.c bootrom.c
GENERATE_IMEM_INIT := 1
include ../../common/common.mk

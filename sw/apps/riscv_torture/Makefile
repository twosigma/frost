#    Copyright 2026 Two Sigma Open Source, LLC
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

# Makefile for riscv-torture test compilation on Frost
#
# Usage: make TEST_SRC=tests/test_001.S
#
# Each torture test .S file is expected to have been adapted by adapt_test.py
# to include frost_header.S at the top and frost_footer.S at the bottom.
# The adapted file is self-contained — just compile and link.

TEST_SRC ?=

# Architecture
ARCH = rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI  = ilp32

# Tools
RISCV_PREFIX ?= riscv-none-elf-
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

# Include paths (for encoding.h used by frost_header.S)
INCLUDES = -I. -I../riscv_tests/riscv-tests/env

# Memory configuration -- selects the linker script and, for ddr, the ROM boot
# stub plus the sections split out of the low BRAM image into the DDR image
# (sw_ddr.mem; tests/test_riscv_torture.py passes this via MEM_CONFIG):
#   bram (default): code + data + signature all in low BRAM -- pure ISA path,
#                   neither cached tier involved.
#   ddr:            a ROM boot stub far-jumps to the DDR-resident test; code +
#                   data + signature live in the cached DDR region (exercises
#                   both the L1I fetch path and the D-side cached load/store
#                   path).
MEM_CONFIG ?= bram

ifeq ($(MEM_CONFIG),bram)
LINKER_SCRIPT = link_riscv_torture.ld
BOOT_STUB     =
DDR_SECTIONS  =
else ifeq ($(MEM_CONFIG),ddr)
LINKER_SCRIPT = link_riscv_torture_ddr.ld
BOOT_STUB     = crt0_torture_ddr.S
DDR_SECTIONS  = .text.init .text .rodata .data .sdata .tohost
else
$(error MEM_CONFIG must be one of: bram, ddr (got '$(MEM_CONFIG)'))
endif

# Output files
EXECUTABLE_ELF_FILE  = sw.elf
VERILOG_HEX_FILE     = sw.mem
DDR_VERILOG_HEX_FILE = sw_ddr.mem
RAW_BINARY_FILE      = sw.bin
DISASSEMBLY_FILE     = sw.S

# Build targets
all: $(VERILOG_HEX_FILE) $(DDR_VERILOG_HEX_FILE) $(DISASSEMBLY_FILE)

# Compile the adapted torture test (header + test + footer as single .S file).
# The ddr config also assembles the ROM boot stub ($(BOOT_STUB)); the bram
# config leaves it empty (frost_header's _start already sits at 0x0).
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) frost_header.S frost_footer.S $(BOOT_STUB) $(LINKER_SCRIPT)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=tests/test_001.S)
endif
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
		$(INCLUDES) -T $(LINKER_SCRIPT) -o $@ $(BOOT_STUB) $(TEST_SRC)

# Low BRAM image: everything NOT split out to DDR (the bram config keeps the
# whole image; the ddr config keeps only the ROM boot stub).
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
		$(foreach s,$(DDR_SECTIONS),-R $(s)) $< $@

# DDR image, region-relative addresses (the behavioral DDR rebases at
# 0x8000_0000). With no DDR sections (bram config) emit an empty image so the
# harness symlink and the sim's $readmemh both stay happy.
$(DDR_VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
ifeq ($(strip $(DDR_SECTIONS)),)
	: > $@
else
	$(OBJCOPY) -O verilog --verilog-data-width 4 \
		$(foreach s,$(DDR_SECTIONS),-j $(s)) \
		--change-addresses -0x80000000 $< $@
endif

$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id $< $@

$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

clean:
	rm -f $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DDR_VERILOG_HEX_FILE) \
		$(RAW_BINARY_FILE) $(DISASSEMBLY_FILE)

.PHONY: all clean

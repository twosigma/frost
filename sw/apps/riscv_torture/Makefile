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

# Builds one riscv-torture test for FROST.
#
# Usage: make TEST_SRC=tests_rv64/test_001.S
#
# generate_tests.py and adapt_test.py wrap tests with frost_header.S and
# frost_footer.S so each .S file can be compiled and linked on its own.

TEST_SRC ?=

# Architecture (see arch.mk)
include ../../common/arch.mk
ARCH = $(FROST_XLEN_PREFIX)imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI  = $(FROST_INT_ABI)

# RV64 medlow sign-extends lui, so it cannot address the DDR image at
# 0x8xxx_xxxx. Use medany for PC-relative addressing.
CMODEL = -mcmodel=medany

# Tools
RISCV_PREFIX ?= riscv64-linux-
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

# Include paths (for encoding.h used by frost_header.S)
INCLUDES = -I. -I../riscv_tests/riscv-tests/env

# tests/test_riscv_torture.py selects MEM_CONFIG:
#   bram (default): code, data and signature in low BRAM, bypassing caches.
#   ddr: a ROM stub jumps to code, data and signature in cached DDR.
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

# tests/test_riscv_torture.py selects PAGED=1 for S-mode under an Sv39 identity
# map with 1 GiB leaves. The test and signature dump use the ITLB, DTLB and PTW.
# The root table lives in .data, so MEM_CONFIG=ddr is required: the PTW reads
# only cached DDR. Identity translation preserves the register state captured
# in the signature, so the Spike references apply unchanged.
PAGED ?= 0
ifeq ($(PAGED),1)
ifneq ($(MEM_CONFIG),ddr)
$(error PAGED=1 requires MEM_CONFIG=ddr (the root page table lives in .data, which must be in cached DDR))
endif
PAGED_FLAGS = -DFROST_PAGED
else
PAGED_FLAGS =
endif

# Output files
EXECUTABLE_ELF_FILE  = sw.elf
VERILOG_HEX_FILE     = sw.mem
DWORD_HEX_FILE       = sw64.mem
DDR_VERILOG_HEX_FILE = sw_ddr.mem
RAW_BINARY_FILE      = sw.bin
DISASSEMBLY_FILE     = sw.S

# Build targets
all: $(VERILOG_HEX_FILE) $(DWORD_HEX_FILE) $(DDR_VERILOG_HEX_FILE) $(DISASSEMBLY_FILE)

# Compile header, test and footer as one .S file. DDR builds also link a ROM
# stub; BRAM builds place frost_header's _start at 0x0.
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) frost_header.S frost_footer.S $(BOOT_STUB) $(LINKER_SCRIPT)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=tests_rv64/test_001.S)
endif
	$(CC) -march=$(ARCH) -mabi=$(ABI) $(CMODEL) -nostdlib -nostartfiles -static -fno-pie -no-pie -fno-stack-protector $(PAGED_FLAGS) \
		$(INCLUDES) -T $(LINKER_SCRIPT) -o $@ $(BOOT_STUB) $(TEST_SRC)

# Low BRAM image: everything not split out to DDR (the bram config keeps the
# whole image; the ddr config keeps only the ROM boot stub).
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
		$(foreach s,$(DDR_SECTIONS),-R $(s)) $< $@


# Dword-paired image for the 64-bit data BRAM ($readmemh rows are dwords;
# hw/rtl/README.md "Data-tier bus contract"). Every other image stays in 32-bit words.
$(DWORD_HEX_FILE): $(VERILOG_HEX_FILE) ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py '$<' '$@'

# DDR image, region-relative addresses (the behavioral DDR rebases at
# 0x8000_0000). With no DDR sections (bram config) emit an empty image so the
# harness symlink and the sim's $readmemh both still find a file.
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
	rm -f $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DWORD_HEX_FILE) $(DDR_VERILOG_HEX_FILE) \
		$(RAW_BINARY_FILE) $(DISASSEMBLY_FILE)

.PHONY: all clean

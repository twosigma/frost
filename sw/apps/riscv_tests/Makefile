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

# Makefile for riscv-tests ISA test compilation on Frost
#
# Usage: make TEST_SRC=riscv-tests/isa/rv32ui/add.S
#
# ISA tests define their own _start via RVTEST_CODE_BEGIN, so no crt0 is
# needed. Our riscv_test.h (in this directory) overrides the upstream env
# header via -I. taking precedence over -Iriscv-tests/env/p.

TEST_SRC ?=

# Architecture - matches common.mk RISCV_FLAGS -march value
ARCH = rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI  = ilp32

# Tools - use same prefix as common.mk
RISCV_PREFIX ?= riscv-none-elf-
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

# Include paths:
#   -I.                               picks up our riscv_test.h (overrides upstream)
#   -Iriscv-tests/isa/macros/scalar   picks up test_macros.h
#   -Iriscv-tests/env/p               picks up encoding.h (riscv_test.h #includes it)
#   -Iriscv-tests/env                 fallback for encoding.h
INCLUDES = -I. -Iriscv-tests/isa/macros/scalar -Iriscv-tests/env/p -Iriscv-tests/env

# Memory configuration -- selects the linker script and, for ddr, the ROM boot
# stub plus the sections split out of the low BRAM image into the DDR image
# (sw_ddr.mem; tests/test_riscv_tests.py passes this via MEM_CONFIG):
#   bram (default): code + data in low BRAM -- pure ISA path.
#   ddr:            a ROM boot stub far-jumps to the DDR-resident test; code +
#                   data live in the cached DDR region (exercises the L1I fetch
#                   path and the D-side cached load/store path).
MEM_CONFIG ?= bram

ifeq ($(MEM_CONFIG),bram)
LINKER_SCRIPT = link_riscv_tests.ld
BOOT_STUB     =
DDR_SECTIONS  =
else ifeq ($(MEM_CONFIG),ddr)
LINKER_SCRIPT = link_riscv_tests_ddr.ld
BOOT_STUB     = crt0_riscv_tests_ddr.S
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

# Compile and link .S test file via gcc (handles #include).
# ISA tests provide their own _start; the ddr config additionally links a ROM
# boot stub ($(BOOT_STUB)) that far-jumps to it.
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) riscv_test.h $(BOOT_STUB) $(LINKER_SCRIPT)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=riscv-tests/isa/rv32ui/add.S)
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

# Generate raw binary
$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id $< $@

# Generate disassembly
$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

clean:
	rm -f $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DDR_VERILOG_HEX_FILE) \
		$(RAW_BINARY_FILE) $(DISASSEMBLY_FILE)

.PHONY: all clean

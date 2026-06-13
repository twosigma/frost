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

# Makefile for riscv-arch-test individual test compilation
#
# Usage: make TEST_SRC=riscv-arch-test/riscv-test-suite/rv32i_m/I/src/add-01.S
#
# Uses gcc (not as) because .S test files use #include preprocessor directives.
# Uses ilp32 (soft-float ABI) since tests manage FP registers directly.

TEST_SRC ?=

# Architecture - matches common.mk RISCV_FLAGS -march value
ARCH = rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI  = ilp32

# Tools - use same prefix as common.mk
RISCV_PREFIX ?= riscv-none-elf-
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

# Include paths: model_test.h is in this directory, arch_test.h is in env/
INCLUDES = -I. -Iriscv-arch-test/riscv-test-suite/env

# Linker script: boot stub in low BRAM ROM, test code/data in cached DDR
LINKER_SCRIPT = link_arch_test.ld

# Output files - same naming as common.mk
EXECUTABLE_ELF_FILE  = sw.elf
VERILOG_HEX_FILE     = sw.mem
DDR_VERILOG_HEX_FILE = sw_ddr.mem
RAW_BINARY_FILE      = sw.bin
DISASSEMBLY_FILE     = sw.S

# Sections resident in the cached DDR region (split out of the low image)
DDR_SECTIONS = .text .rodata .data .sdata

# Build targets
all: $(VERILOG_HEX_FILE) $(DDR_VERILOG_HEX_FILE) $(DISASSEMBLY_FILE)

# Startup stub that provides _start in .init section (bss zero + far jump)
CRT0 = crt0_arch_test.S

# Compile defines the test declares in its RVTEST_CASE strings (riscof's
# `def NAME=True` clauses): TEST_CASE_1 gates the body; tests that need
# the framework trap handler add rvtest_mtrap_routine. Tests without the
# handler leave mtvec at 0 and Frost completes their misaligned accesses
# (FLEN=64 signature fsd's) in hardware. Lazily expanded so clean works
# without TEST_SRC.
TEST_DEFINES = $(shell grep -ohE 'def +[A-Za-z_0-9]+ *= *True' $(TEST_SRC) \
	| sed -E 's/def +([A-Za-z_0-9]+) *= *True/-D\1=True/' | sort -u)

# Compile and link .S test file + startup stub via gcc (handles #include)
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) $(CRT0) model_test.h $(LINKER_SCRIPT)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=riscv-arch-test/riscv-test-suite/rv32i_m/I/src/add-01.S)
endif
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
		-DXLEN=32 -DFLEN=64 $(TEST_DEFINES) \
		$(INCLUDES) -T $(LINKER_SCRIPT) -o $@ $(CRT0) $(TEST_SRC)

# Low BRAM image: the boot stub only (DDR sections split out)
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
		$(foreach s,$(DDR_SECTIONS),-R $(s)) $< $@

# DDR image, region-relative addresses (the behavioral DDR / JTAG loader
# rebase it at 0x8000_0000)
$(DDR_VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 \
		$(foreach s,$(DDR_SECTIONS),-j $(s)) \
		--change-addresses -0x80000000 $< $@

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

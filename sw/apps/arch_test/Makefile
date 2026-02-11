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

# Linker script optimized for arch tests (minimal ROM, maximum RAM)
LINKER_SCRIPT = link_arch_test.ld

# Output files - same naming as common.mk
EXECUTABLE_ELF_FILE = sw.elf
VERILOG_HEX_FILE    = sw.mem
RAW_BINARY_FILE     = sw.bin
DISASSEMBLY_FILE    = sw.S

# Build targets
all: $(VERILOG_HEX_FILE) $(DISASSEMBLY_FILE)

# Startup stub that provides _start in .init section (data copy, bss zero)
CRT0 = crt0_arch_test.S

# Compile and link .S test file + startup stub via gcc (handles #include)
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) $(CRT0) model_test.h $(LINKER_SCRIPT)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=riscv-arch-test/riscv-test-suite/rv32i_m/I/src/add-01.S)
endif
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
		-DXLEN=32 -DFLEN=64 \
		$(INCLUDES) -T $(LINKER_SCRIPT) -o $@ $(CRT0) $(TEST_SRC)

# Generate Verilog HEX file - same format as common.mk
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id $< $@

# Generate raw binary
$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id $< $@

# Generate disassembly
$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

clean:
	rm -f $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(DISASSEMBLY_FILE)

.PHONY: all clean

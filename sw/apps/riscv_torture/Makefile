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

# Linker script
LINKER_SCRIPT = link_riscv_torture.ld

# Output files
EXECUTABLE_ELF_FILE = sw.elf
VERILOG_HEX_FILE    = sw.mem
RAW_BINARY_FILE     = sw.bin
DISASSEMBLY_FILE    = sw.S

# Build targets
all: $(VERILOG_HEX_FILE) $(DISASSEMBLY_FILE)

# Compile the adapted torture test (header + test + footer as single .S file)
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) frost_header.S frost_footer.S $(LINKER_SCRIPT)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=tests/test_001.S)
endif
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
		$(INCLUDES) -T $(LINKER_SCRIPT) -o $@ $(TEST_SRC)

$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id $< $@

$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id $< $@

$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

clean:
	rm -f $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(DISASSEMBLY_FILE)

.PHONY: all clean

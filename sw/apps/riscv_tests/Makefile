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

# Linker script
LINKER_SCRIPT = link_riscv_tests.ld

# Output files
EXECUTABLE_ELF_FILE = sw.elf
VERILOG_HEX_FILE    = sw.mem
RAW_BINARY_FILE     = sw.bin
DISASSEMBLY_FILE    = sw.S

# Build targets
all: $(VERILOG_HEX_FILE) $(DISASSEMBLY_FILE)

# Compile and link .S test file via gcc (handles #include)
# No crt0 needed — ISA tests provide their own _start
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) riscv_test.h $(LINKER_SCRIPT)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=riscv-tests/isa/rv32ui/add.S)
endif
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
		$(INCLUDES) -T $(LINKER_SCRIPT) -o $@ $(TEST_SRC)

# Generate Verilog HEX file
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

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

# Builds one riscv-tests ISA test for Frost.
#
# Usage: make TEST_SRC=riscv-tests/isa/rv64ui/add.S
#
# ISA tests define their own _start via RVTEST_CODE_BEGIN, so no crt0 is
# needed. The riscv_test.h in this directory overrides the upstream env
# header: -I. takes precedence over -Iriscv-tests/env/p.

TEST_SRC ?=

# Architecture - matches common.mk RISCV_FLAGS -march value (see arch.mk)
include ../../common/arch.mk
ARCH = $(FROST_XLEN_PREFIX)imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI  = $(FROST_INT_ABI)
# lp64 needs PC-relative addressing for the DDR-resident test image: medlow's
# absolute lui cannot form 0x8xxx_xxxx addresses at 64, so the ddr links fail
# with relocation truncation (same fix as sw/apps/arch_test).
CMODEL = -mcmodel=medany

# Tools - use same prefix as common.mk
RISCV_PREFIX ?= riscv-none-elf-
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

# Test environment (tests/test_riscv_tests.py passes this via ENV):
#   p (default): physical environment. The test runs bare in M-mode, using
#                Frost's riscv_test.h override for UART pass/fail.
#   v:           virtual environment (the upstream -v variants). The test
#                runs as demand-paged Sv39 user code under the env_v/
#                supervisor kernel (Phase 3 M5). DDR-only: the kernel's
#                page tables and the user frames live in cached DDR.
ENV ?= p

# Include paths:
#   -Ienv_v (v only)                  picks up the virtual-env riscv_test.h
#   -I.                               picks up Frost's riscv_test.h (overrides upstream)
#   -Iriscv-tests/isa/macros/scalar   picks up test_macros.h
#   -Iriscv-tests/env/p               picks up encoding.h (riscv_test.h #includes it)
#   -Iriscv-tests/env                 fallback for encoding.h
ifeq ($(ENV),v)
INCLUDES = -Ienv_v -I. -Iriscv-tests/isa/macros/scalar -Iriscv-tests/env/p -Iriscv-tests/env
# The kernel: entry (reset, trap frame), the demand pager, freestanding
# string routines. ENTROPY seeds the pager's frame order per test.
ENV_SRC = env_v/entry.S env_v/vm.c env_v/string.c
ENV_CFLAGS = -std=gnu99 -O2 -DENTROPY=$(ENTROPY) -Wno-implicit-function-declaration
ENTROPY ?= 0x$(shell printf '%s' '$(TEST_SRC)' | cksum | cut -d' ' -f1 | xargs printf '%x')
else ifeq ($(ENV),p)
INCLUDES = -I. -Iriscv-tests/isa/macros/scalar -Iriscv-tests/env/p -Iriscv-tests/env
ENV_SRC =
ENV_CFLAGS =
else
$(error ENV must be one of: p, v (got '$(ENV)'))
endif

# Memory configuration. Selects the linker script and, for ddr, the ROM boot
# stub plus the sections split out of the low BRAM image into the DDR image
# (sw_ddr.mem). tests/test_riscv_tests.py passes this via MEM_CONFIG.
#   bram (default): code + data in low BRAM, a pure ISA path.
#   ddr:            a ROM boot stub far-jumps to the DDR-resident test. Code
#                   and data live in the cached DDR region, which exercises
#                   the L1I fetch path and the D-side cached load/store path.
MEM_CONFIG ?= bram

ifeq ($(ENV),v)
ifneq ($(MEM_CONFIG),ddr)
$(error ENV=v requires MEM_CONFIG=ddr (page tables and user frames live in cached DDR))
endif
LINKER_SCRIPT = link_riscv_tests_v.ld
BOOT_STUB     = crt0_riscv_tests_ddr.S
DDR_SECTIONS  = .text .rodata .data .sdata .tohost
else ifeq ($(MEM_CONFIG),bram)
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
DWORD_HEX_FILE       = sw64.mem
DDR_VERILOG_HEX_FILE = sw_ddr.mem
RAW_BINARY_FILE      = sw.bin
DISASSEMBLY_FILE     = sw.S

# Build targets
all: $(VERILOG_HEX_FILE) $(DWORD_HEX_FILE) $(DDR_VERILOG_HEX_FILE) $(DISASSEMBLY_FILE)

# Compile and link .S test file via gcc (handles #include).
# ISA tests provide their own _start; the ddr config additionally links a ROM
# boot stub ($(BOOT_STUB)) that far-jumps to it.
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) riscv_test.h $(BOOT_STUB) $(LINKER_SCRIPT) $(ENV_SRC)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=riscv-tests/isa/rv64ui/add.S)
endif
	$(CC) -march=$(ARCH) -mabi=$(ABI) $(CMODEL) -nostdlib -nostartfiles $(ENV_CFLAGS) \
		$(INCLUDES) -T $(LINKER_SCRIPT) -o $@ $(BOOT_STUB) $(ENV_SRC) $(TEST_SRC)

# Low BRAM image: everything not split out to DDR (the bram config keeps the
# whole image; the ddr config keeps only the ROM boot stub).
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
		$(foreach s,$(DDR_SECTIONS),-R $(s)) $< $@


# Dword-paired image for the 64-bit data BRAM ($readmemh rows are dwords;
# hw/rtl/README.md "Data-tier bus contract"). Every loader keeps the 32-bit-word formats.
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

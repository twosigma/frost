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

# Makefile for Branch Prediction Test
# Tests branch prediction behavior with various control flow patterns
# Note: Uses custom build flow (not common.mk) because branch_pred_test.S
# defines its own _start and doesn't use crt0.S

# Architecture - MUST match common.mk RISCV_FLAGS -march value
# If common.mk changes, update this value to match
ARCH = rv32imac_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI = ilp32

# Tools - use same prefix as common.mk
RISCV_PREFIX ?= riscv-none-elf-
AS      = $(RISCV_PREFIX)as
LD      = $(RISCV_PREFIX)ld
CC      = $(RISCV_PREFIX)gcc      # only used to assemble the ddr boot stub
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

# Boot stub for the ddr config (compiled with gcc so cpp strips its // comments;
# as(1) does not understand them). Far-jumps to the DDR-resident _start.
DDR_BOOT_STUB_SRC = ../../common/crt0_ddr_boot.S
DDR_BOOT_STUB_OBJ = crt0_ddr_boot.o

# Memory configuration -- selects the linker script and, for ddr, the ROM boot
# stub plus the sections split out of the low BRAM image into the DDR image
# (sw_ddr.mem; the cocotb runner symlinks this for every app):
#   bram (default): the whole program lives in low BRAM (EXACTLY today's
#                   behavior); only opt-in .ddr_* sections go to sw_ddr.mem.
#   ddr:            a ROM boot stub far-jumps to the DDR-resident _start; the
#                   whole program (code + data + this test's stack) lives in the
#                   cached DDR region (exercises the L1I fetch path and the
#                   D-side cached load/store path).
MEM_CONFIG ?= bram

ifeq ($(MEM_CONFIG),bram)
LINKER_SCRIPT = ../../common/link.ld
BOOT_STUB_OBJ =
# Only the opt-in cached-region sections go to the DDR image (current behavior).
DDR_SECTIONS  = .ddr_text .ddr_rodata .ddr_data
else ifeq ($(MEM_CONFIG),ddr)
LINKER_SCRIPT = ../../common/link_ddr.ld
BOOT_STUB_OBJ = $(DDR_BOOT_STUB_OBJ)
# Whole program is in DDR: split ALL loadable sections into the DDR image, so
# the low-BRAM sw.mem contains only the ROM boot stub.
DDR_SECTIONS  = .text .rodata .data .sdata .ddr_text .ddr_rodata .ddr_data
else
$(error MEM_CONFIG must be one of: bram, ddr (got '$(MEM_CONFIG)'))
endif

# Output files - same naming as common.mk
EXECUTABLE_ELF_FILE  = sw.elf
VERILOG_HEX_FILE     = sw.mem
DDR_VERILOG_HEX_FILE = sw_ddr.mem
RAW_BINARY_FILE      = sw.bin
VIVADO_BRAM_FILE     = sw.txt
DISASSEMBLY_FILE     = sw.S

# Build targets
all: $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DDR_VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DISASSEMBLY_FILE)

# Assemble and link. The ddr config additionally links a ROM boot stub
# ($(BOOT_STUB_OBJ)) that far-jumps to the DDR-resident _start; the bram config
# leaves it empty (_start already sits at 0x0).
$(DDR_BOOT_STUB_OBJ): $(DDR_BOOT_STUB_SRC)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -c -o $@ $<

$(EXECUTABLE_ELF_FILE): branch_pred_test.S $(BOOT_STUB_OBJ) $(LINKER_SCRIPT)
	$(AS) -march=$(ARCH) -mabi=$(ABI) -o branch_pred_test.o branch_pred_test.S
	$(LD) -m elf32lriscv -T $(LINKER_SCRIPT) -o $@ $(BOOT_STUB_OBJ) branch_pred_test.o
	@rm -f branch_pred_test.o

# Low BRAM image: everything NOT split out to DDR (bram keeps the whole image;
# ddr keeps only the ROM boot stub). Same format as common.mk.
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
		$(addprefix -R ,$(DDR_SECTIONS)) $< $@

# DDR image, region-relative addresses (the behavioral DDR rebases at
# 0x8000_0000). bram emits only the opt-in .ddr_* sections; if the program
# places nothing there the objcopy yields an empty file, so fall back to a
# single zero word (mirrors common.mk) -- the cocotb symlink and the sim's
# $readmemh both stay happy.
$(DDR_VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	-$(OBJCOPY) -O verilog --verilog-data-width 4 $(addprefix -j ,$(DDR_SECTIONS)) \
		--change-addresses -0x80000000 $< $@ 2>/dev/null
	@if [ ! -s $@ ]; then echo 00000000 > $@; fi

# Generate raw binary
$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id \
		$(addprefix -R ,$(DDR_SECTIONS)) $< $@

# Generate Vivado BRAM text file
$(VIVADO_BRAM_FILE): $(RAW_BINARY_FILE)
	xxd -e -g4 -c4 $< | awk '{printf "%08x\n", strtonum("0x" $$2)}' > $@

# Generate disassembly
$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

clean:
	rm -f $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DDR_VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DISASSEMBLY_FILE) branch_pred_test.o $(DDR_BOOT_STUB_OBJ)

.PHONY: all clean

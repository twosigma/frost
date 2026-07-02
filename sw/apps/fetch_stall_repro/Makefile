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

# Makefile for fetch_stall_repro
# Self-contained assembly directed test (defines its own _start, no crt0.S).

ARCH = rv32imac_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI = ilp32

RISCV_PREFIX ?= riscv-none-elf-
AS      = $(RISCV_PREFIX)as
LD      = $(RISCV_PREFIX)ld
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

DDR_BOOT_STUB_SRC = ../../common/crt0_ddr_boot.S
DDR_BOOT_STUB_OBJ = crt0_ddr_boot.o

MEM_CONFIG ?= bram

ifeq ($(MEM_CONFIG),bram)
LINKER_SCRIPT = ../../common/link.ld
BOOT_STUB_OBJ =
DDR_SECTIONS  = .ddr_text .ddr_rodata .ddr_data
else ifeq ($(MEM_CONFIG),ddr)
LINKER_SCRIPT = ../../common/link_ddr.ld
BOOT_STUB_OBJ = $(DDR_BOOT_STUB_OBJ)
DDR_SECTIONS  = .text .rodata .data .sdata .ddr_text .ddr_rodata .ddr_data
else
$(error MEM_CONFIG must be one of: bram, ddr (got '$(MEM_CONFIG)'))
endif

EXECUTABLE_ELF_FILE  = sw.elf
VERILOG_HEX_FILE     = sw.mem
DDR_VERILOG_HEX_FILE = sw_ddr.mem
RAW_BINARY_FILE      = sw.bin
VIVADO_BRAM_FILE     = sw.txt
DISASSEMBLY_FILE     = sw.S

all: $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DDR_VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DISASSEMBLY_FILE)

$(DDR_BOOT_STUB_OBJ): $(DDR_BOOT_STUB_SRC)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -c -o $@ $<

$(EXECUTABLE_ELF_FILE): fetch_stall_repro.S $(BOOT_STUB_OBJ) $(LINKER_SCRIPT)
	$(AS) -march=$(ARCH) -mabi=$(ABI) -o fetch_stall_repro.o fetch_stall_repro.S
	$(LD) -m elf32lriscv -T $(LINKER_SCRIPT) -o $@ $(BOOT_STUB_OBJ) fetch_stall_repro.o
	@rm -f fetch_stall_repro.o

$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
		$(addprefix -R ,$(DDR_SECTIONS)) $< $@

$(DDR_VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	-$(OBJCOPY) -O verilog --verilog-data-width 4 $(addprefix -j ,$(DDR_SECTIONS)) \
		--change-addresses -0x80000000 $< $@ 2>/dev/null
	@if [ ! -s $@ ]; then echo 00000000 > $@; fi

$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id \
		$(addprefix -R ,$(DDR_SECTIONS)) $< $@

$(VIVADO_BRAM_FILE): $(RAW_BINARY_FILE)
	xxd -e -g4 -c4 $< | awk '{printf "%08x\n", strtonum("0x" $$2)}' > $@

$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

clean:
	rm -f $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DDR_VERILOG_HEX_FILE) \
		$(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DISASSEMBLY_FILE) \
		fetch_stall_repro.o $(DDR_BOOT_STUB_OBJ)

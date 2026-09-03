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

# Shared build backend for self-starting assembly applications.
#
# The including Makefile must define ARCH, ABI, and ASM_SRC. These applications
# cannot use common.mk's C runtime because their assembly source defines _start,
# but they still need the same BRAM/DDR image semantics and incremental-build
# guarantees as ordinary software applications.

ifndef ARCH
$(error ARCH must be set before including standalone_asm.mk)
endif
ifndef ABI
$(error ABI must be set before including standalone_asm.mk)
endif
ifndef ASM_SRC
$(error ASM_SRC must be set before including standalone_asm.mk)
endif

# Architecture strings come from arch.mk. The including Makefile builds ARCH
# and ABI from its variables, and FROST_LD_EMULATION feeds LINK_FLAGS below.
include $(dir $(lastword $(MAKEFILE_LIST)))arch.mk

RISCV_PREFIX ?= riscv-none-elf-
AS      := $(RISCV_PREFIX)as
LD      := $(RISCV_PREFIX)ld
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

DDR_BOOT_STUB_SRC := ../../common/crt0_ddr_boot.S
DDR_BOOT_STUB_OBJ := crt0_ddr_boot.o

MEM_CONFIG ?= bram

ifeq ($(MEM_CONFIG),bram)
LINKER_SCRIPT := ../../common/link.ld
BOOT_STUB_OBJ :=
DDR_SECTIONS  := .ddr_text .ddr_rodata .ddr_data
else ifeq ($(MEM_CONFIG),ddr)
LINKER_SCRIPT := ../../common/link_ddr.ld
BOOT_STUB_OBJ := $(DDR_BOOT_STUB_OBJ)
DDR_SECTIONS  := .text .rodata .data .sdata .ddr_text .ddr_rodata .ddr_data
else
$(error MEM_CONFIG must be one of: bram, ddr (got '$(MEM_CONFIG)'))
endif

EXECUTABLE_ELF_FILE  := sw.elf
VERILOG_HEX_FILE     := sw.mem
DWORD_HEX_FILE       := sw64.mem
DDR_VERILOG_HEX_FILE := sw_ddr.mem
RAW_BINARY_FILE      := sw.bin
VIVADO_BRAM_FILE     := sw.txt
DISASSEMBLY_FILE     := sw.S
ASSEMBLY_OBJECT_FILE := $(patsubst %.S,%.o,$(notdir $(ASM_SRC)))
BUILD_CONFIG_FILE    := .frost-build-config.bin

# The assemble rule runs raw $(AS) with no C preprocessor, so .S sources here
# cannot use #if. Conditional code would have to use gas .if directives.
ASM_FLAGS       := -march=$(ARCH) -mabi=$(ABI)
# The boot stub compiles through $(CC) (which preprocesses).
BOOT_CFLAGS     := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles
LINK_FLAGS      := -m $(FROST_LD_EMULATION) -T $(LINKER_SCRIPT)
BUILD_MAKEFILES := $(MAKEFILE_LIST)

# Make cannot otherwise tell that the shared output names were produced with a
# different tier, ISA/ABI, tool override, linker, or section split. Keep one
# content-addressed stamp whose mtime changes exactly when the effective build
# configuration changes.
EFFECTIVE_BUILD_CONFIG = MEM_CONFIG=$(MEM_CONFIG)|ARCH=$(ARCH)|ABI=$(ABI)|AS=$(AS)|LD=$(LD)|CC=$(CC)|OBJCOPY=$(OBJCOPY)|OBJDUMP=$(OBJDUMP)|ASM_FLAGS=$(ASM_FLAGS)|BOOT_CFLAGS=$(BOOT_CFLAGS)|LINK_FLAGS=$(LINK_FLAGS)|LINKER_SCRIPT=$(LINKER_SCRIPT)|BOOT_STUB_OBJ=$(BOOT_STUB_OBJ)|DDR_SECTIONS=$(DDR_SECTIONS)|ASM_SRC=$(ASM_SRC)
shell_quote = '$(subst ','"'"',$(1))'

all: $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DWORD_HEX_FILE) \
     $(DDR_VERILOG_HEX_FILE) \
     $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DISASSEMBLY_FILE)

.PHONY: FORCE
FORCE:

$(BUILD_CONFIG_FILE): FORCE
	@tmp="$@.$$$$.tmp"; \
	printf '%s\n' $(call shell_quote,$(EFFECTIVE_BUILD_CONFIG)) > "$$tmp"; \
	if cmp -s "$$tmp" '$@'; then \
	    rm -f "$$tmp"; \
	else \
	    mv "$$tmp" '$@'; \
	fi

# The DDR boot stub is configuration-dependent too: changing ARCH/ABI or the
# selected tool must not silently reuse an object assembled by an older build.
$(DDR_BOOT_STUB_OBJ): $(DDR_BOOT_STUB_SRC) $(BUILD_CONFIG_FILE) $(BUILD_MAKEFILES)
	@set -e; \
	tmp='$@.tmp'; \
	trap 'rm -f "$$tmp"' 0 1 2 3 15; \
	$(CC) $(BOOT_CFLAGS) -c -o "$$tmp" '$<'; \
	mv "$$tmp" '$@'

# Assemble and link through temporary files so a failed tool invocation cannot
# replace a previously valid ELF. Switching tiers in either direction changes
# the configuration stamp and therefore always reaches this recipe.
$(EXECUTABLE_ELF_FILE): $(ASM_SRC) $(BOOT_STUB_OBJ) $(LINKER_SCRIPT) \
                        $(BUILD_CONFIG_FILE) $(BUILD_MAKEFILES)
	@set -e; \
	obj_tmp='$(ASSEMBLY_OBJECT_FILE)'; \
	elf_tmp='$@.tmp'; \
	trap 'rm -f "$$obj_tmp" "$$elf_tmp"' 0 1 2 3 15; \
	$(AS) $(ASM_FLAGS) -o "$$obj_tmp" '$(ASM_SRC)'; \
	$(LD) $(LINK_FLAGS) -o "$$elf_tmp" $(BOOT_STUB_OBJ) "$$obj_tmp"; \
	mv "$$elf_tmp" '$@'

# Low-BRAM image: the BRAM tier keeps the program here; the DDR tier keeps only
# the ROM boot stub and moves all program sections into sw_ddr.mem.
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
		$(addprefix -R ,$(DDR_SECTIONS)) '$<' '$@'

# Dword-paired image for the 64-bit data BRAM ($readmemh rows are dwords;
# hw/rtl/README.md "Data-tier bus contract"). Every loader keeps the 32-bit-word formats.
$(DWORD_HEX_FILE): $(VERILOG_HEX_FILE) ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py '$<' '$@'

# Generate the cached-region image atomically. An empty selected-section set is
# valid in the BRAM tier and becomes one zero word, so consumers can $readmemh
# the file unconditionally. Any objcopy error is fatal and leaves an old target
# untouched rather than blessing stale data.
$(DDR_VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	@set -e; \
	tmp="$@.$$$$.tmp"; \
	trap 'rm -f "$$tmp"' 0 1 2 3 15; \
	$(OBJCOPY) -O verilog --verilog-data-width 4 $(addprefix -j ,$(DDR_SECTIONS)) \
	      --change-addresses -0x80000000 '$<' "$$tmp"; \
	if [ ! -s "$$tmp" ]; then printf '00000000\n' > "$$tmp"; fi; \
	mv "$$tmp" '$@'

$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id \
		$(addprefix -R ,$(DDR_SECTIONS)) '$<' '$@'

$(VIVADO_BRAM_FILE): $(RAW_BINARY_FILE)
	xxd -e -g4 -c4 '$<' | awk '{printf "%08x\n", strtonum("0x" $$2)}' > '$@'

$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d '$<' > '$@'

clean:
	$(RM) $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DWORD_HEX_FILE) \
	      $(DDR_VERILOG_HEX_FILE) \
	      $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DISASSEMBLY_FILE) \
	      $(ASSEMBLY_OBJECT_FILE) $(DDR_BOOT_STUB_OBJ) $(BUILD_CONFIG_FILE)

.PHONY: all clean

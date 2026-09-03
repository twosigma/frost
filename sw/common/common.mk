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

# Shared FROST bare-metal toolchain and build rules.

# Overridable RISC-V toolchain prefix.
RISCV_PREFIX ?= riscv-none-elf-

# Toolchain executables
CC      := $(RISCV_PREFIX)gcc      # C compiler
OBJCOPY := $(RISCV_PREFIX)objcopy  # Binary format converter
OBJDUMP := $(RISCV_PREFIX)objdump  # Disassembler
SIZE    := $(RISCV_PREFIX)size     # Size analyzer

# CPU clock used by software timing calculations; board flows override it.
FPGA_CPU_CLK_FREQ ?= 300000000  # 300 MHz (default for X3)

# Apps may override optimization before including common.mk; isa_test uses -O2
# to avoid GP-relative relocation overflow.
OPT_LEVEL ?= -O3

# Apps may clear this; isa_test does.
UNROLL_LOOPS ?= -funroll-loops

# Architecture strings come from arch.mk
include $(dir $(lastword $(MAKEFILE_LIST)))arch.mk

# Apps may override the default LP64D ABI.
MABI ?= $(FROST_FP_ABI)

# Compilation flags

# RV64IMAFDC plus explicit Zba/Zbb/Zbs, Zicsr, Zicntr, Zifencei, Zicond, Zbkb,
# and Zihintpause. The explicit B subsets support older toolchain spelling.
# Bare-metal builds omit libc/start files and unwind metadata. Per-function/data
# sections allow --gc-sections; -fno-strict-aliasing protects MMIO pointer casts.
# LP64 needs medany because medlow cannot form sign-extended 0x8xxx_xxxx DDR
# addresses. riscv_tests, arch_test, and Spike references use the same model.
FROST_CMODEL = -mcmodel=medany

RISCV_FLAGS  = -march=$(FROST_XLEN_PREFIX)imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause -mabi=$(MABI) $(FROST_CMODEL) -Wall -Wextra \
               -nostdlib -nostartfiles -ffreestanding \
               -fno-unwind-tables -fno-asynchronous-unwind-tables \
               -ffunction-sections -fdata-sections \
               $(OPT_LEVEL) $(UNROLL_LOOPS) -fno-strict-aliasing

# Select the linker and image split:
#   bram (default): whole program in low BRAM; only opt-in .ddr_* sections in DDR.
#   ddr:            whole program relocated to the cached DDR region behind a ROM
#                   boot stub (exercises the L1I fetch path + D-side cached tier).
MEM_CONFIG ?= bram

ifneq ($(MEM_CONFIG),bram)
ifneq ($(MEM_CONFIG),ddr)
$(error MEM_CONFIG must be one of: bram, ddr (got '$(MEM_CONFIG)'))
endif
endif

ifeq ($(MEM_CONFIG),ddr)
# FreeRTOS and other apps may override the linker before this include.
LINKER_SCRIPT ?= ../../common/link_ddr.ld
DDR_BOOT_STUB := ../../common/crt0_ddr_boot.S
# Split all loadable sections into DDR; low BRAM contains only the boot stub.
DDR_SPLIT_SECTIONS := .text .rodata .data .sdata .ddr_text .ddr_rodata .ddr_data \
                      .cache_profile_text .cache_profile_rodata
else
# Apps may override the linker script before including this file.
LINKER_SCRIPT ?= ../../common/link.ld
DDR_BOOT_STUB :=
# Only opt-in cached sections go to the DDR image.
DDR_SPLIT_SECTIONS := .ddr_text .ddr_rodata .ddr_data
endif

# Linker flags: $(RISCV_FLAGS) plus the linker script and --gc-sections.
EXTRA_LDFLAGS ?=
LDFLAGS  += $(RISCV_FLAGS) -T $(LINKER_SCRIPT) -Wl,--gc-sections $(EXTRA_LDFLAGS)

# C flags and include paths.
CFLAGS = $(RISCV_FLAGS)
# addprefix emits no bare -I when INCLUDE_DIR is empty; a bare -I would consume
# the following -D.
CFLAGS += -I../../lib/include -I. $(addprefix -I,$(strip $(INCLUDE_DIR)))
CFLAGS += '-DCOMPILER_VERSION="$(COMPILER_VERSION)"' \
          '-DCOMPILER_FLAGS="$(RISCV_FLAGS)"' \
          '-DFPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ)' \
          $(EXTRA_CFLAGS)

# Assembly startup code (initializes stack, zeroes BSS, calls main)
ASSEMBLY_STARTUP_FILE := ../../common/crt0.S

# App Makefiles may add assembly sources here before including common.mk.
EXTRA_ASM_SRC ?=

# Output file names
EXECUTABLE_ELF_FILE     := sw.elf  # ELF executable with debug info
VERILOG_HEX_FILE        := sw.mem  # Verilog hex format for $readmemh
DWORD_HEX_FILE          := sw64.mem  # Dword-paired copy for the 64-bit data BRAM
RAW_BINARY_FILE         := sw.bin  # Raw binary (no ELF headers)
VIVADO_BRAM_FILE        := sw.txt  # BRAM initialization format for Vivado
DDR_HEX_FILE            := sw_ddr.mem  # Cached-region (DDR) image, region-relative
DDR_TXT_FILE            := sw_ddr.txt  # DDR image for the JTAG loader (dense words)
DISASSEMBLY_FILE        := sw.S    # Human-readable disassembly
IMEM_EVEN_COLD_INIT_FILE := sw_imem_even_cold.mem
IMEM_ODD_COLD_INIT_FILE  := sw_imem_odd_cold.mem
IMEM_EVEN_FRONTEND_HOT_INIT_FILE := sw_imem_even_frontend_hot.mem
IMEM_ODD_FRONTEND_HOT_INIT_FILE  := sw_imem_odd_frontend_hot.mem
IMEM_EVEN_SIDEBAND_FILE := sw_imem_even_sideband.mem
IMEM_ODD_SIDEBAND_FILE  := sw_imem_odd_sideband.mem
IMEM_EVEN_COMPRESSED_FILE := sw_imem_even_compressed.mem
IMEM_ODD_COMPRESSED_FILE  := sw_imem_odd_compressed.mem
# One scalar LUTRAM overlay image per sideband predicate and parity bank
# (generate_imem_predecode_init.py SCALAR_REPLICA_BITS).
IMEM_EVEN_IS_COMPRESSED_LO_FILE := sw_imem_even_is_compressed_lo.mem
IMEM_ODD_IS_COMPRESSED_LO_FILE := sw_imem_odd_is_compressed_lo.mem
IMEM_EVEN_IS_COMPRESSED_HI_FILE := sw_imem_even_is_compressed_hi.mem
IMEM_ODD_IS_COMPRESSED_HI_FILE := sw_imem_odd_is_compressed_hi.mem
IMEM_EVEN_EVEN_LOCAL_PAIR_VALID_FILE := sw_imem_even_even_local_pair_valid.mem
IMEM_ODD_EVEN_LOCAL_PAIR_VALID_FILE := sw_imem_odd_even_local_pair_valid.mem
IMEM_EVEN_PAIRABLE_NATIVE_LO_FILE := sw_imem_even_pairable_native_lo.mem
IMEM_ODD_PAIRABLE_NATIVE_LO_FILE := sw_imem_odd_pairable_native_lo.mem
IMEM_EVEN_PAIRABLE_COMPRESSED_HI_FILE := sw_imem_even_pairable_compressed_hi.mem
IMEM_ODD_PAIRABLE_COMPRESSED_HI_FILE := sw_imem_odd_pairable_compressed_hi.mem
IMEM_EVEN_PAIRABLE_NATIVE_HI_FILE := sw_imem_even_pairable_native_hi.mem
IMEM_ODD_PAIRABLE_NATIVE_HI_FILE := sw_imem_odd_pairable_native_hi.mem
IMEM_EVEN_SLOT2_START_VALID_LO_FILE := sw_imem_even_slot2_start_valid_lo.mem
IMEM_ODD_SLOT2_START_VALID_LO_FILE := sw_imem_odd_slot2_start_valid_lo.mem
IMEM_SCALAR_INIT_FILES := \
	$(IMEM_EVEN_IS_COMPRESSED_LO_FILE) $(IMEM_ODD_IS_COMPRESSED_LO_FILE) \
	$(IMEM_EVEN_IS_COMPRESSED_HI_FILE) $(IMEM_ODD_IS_COMPRESSED_HI_FILE) \
	$(IMEM_EVEN_EVEN_LOCAL_PAIR_VALID_FILE) $(IMEM_ODD_EVEN_LOCAL_PAIR_VALID_FILE) \
	$(IMEM_EVEN_PAIRABLE_NATIVE_LO_FILE) $(IMEM_ODD_PAIRABLE_NATIVE_LO_FILE) \
	$(IMEM_EVEN_PAIRABLE_COMPRESSED_HI_FILE) $(IMEM_ODD_PAIRABLE_COMPRESSED_HI_FILE) \
	$(IMEM_EVEN_PAIRABLE_NATIVE_HI_FILE) $(IMEM_ODD_PAIRABLE_NATIVE_HI_FILE) \
	$(IMEM_EVEN_SLOT2_START_VALID_LO_FILE) $(IMEM_ODD_SLOT2_START_VALID_LO_FILE)
IMEM_INIT_SCRIPT        := ../../common/generate_imem_predecode_init.py
# Globally ignored suffixes keep bookkeeping out of git status.
BUILD_CONFIG_FILE       := .frost-build-config.bin
DEPENDENCY_FILE         := .frost-deps.o
GENERATE_IMEM_INIT ?= 0
IMEM_INIT_TARGETS :=
ifeq ($(GENERATE_IMEM_INIT),1)
IMEM_INIT_TARGETS := $(IMEM_EVEN_COLD_INIT_FILE) $(IMEM_ODD_COLD_INIT_FILE) \
                     $(IMEM_EVEN_FRONTEND_HOT_INIT_FILE) \
                     $(IMEM_ODD_FRONTEND_HOT_INIT_FILE) \
                     $(IMEM_EVEN_SIDEBAND_FILE) $(IMEM_ODD_SIDEBAND_FILE) \
                     $(IMEM_EVEN_COMPRESSED_FILE) $(IMEM_ODD_COMPRESSED_FILE) \
                     $(IMEM_SCALAR_INIT_FILES)
endif

# A content-addressed stamp turns tools, flags, ABI, and tier into rebuild
# triggers. Identical invocations preserve its mtime, including a switch back.
EFFECTIVE_BUILD_CONFIG = MEM_CONFIG=$(MEM_CONFIG)|CC=$(CC)|OBJCOPY=$(OBJCOPY)|OBJDUMP=$(OBJDUMP)|CFLAGS=$(CFLAGS)|LDFLAGS=$(LDFLAGS)|LINKER_SCRIPT=$(LINKER_SCRIPT)|DDR_BOOT_STUB=$(DDR_BOOT_STUB)|ASSEMBLY_STARTUP_FILE=$(ASSEMBLY_STARTUP_FILE)|EXTRA_ASM_SRC=$(EXTRA_ASM_SRC)|SRC_C=$(SRC_C)|DDR_SPLIT_SECTIONS=$(DDR_SPLIT_SECTIONS)

# Quote a single-line make value; CFLAGS contains literal single quotes.
shell_quote = '$(subst ','"'"',$(1))'

# Direct-from-source linking has no per-object .d files. Generate an equivalent
# fragment that skips system headers. -MP tolerates headers that were removed.

# Build targets
all: $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DWORD_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DDR_HEX_FILE) \
     $(DDR_TXT_FILE) $(DISASSEMBLY_FILE) $(IMEM_INIT_TARGETS)

# Keep all as the default after the generated fragment appears.
-include $(DEPENDENCY_FILE)

.PHONY: FORCE
FORCE:

$(BUILD_CONFIG_FILE): FORCE
	@tmp='$@.$$$$.tmp'; \
	printf '%s\n' $(call shell_quote,$(EFFECTIVE_BUILD_CONFIG)) > "$$tmp"; \
	if cmp -s "$$tmp" '$@'; then \
	    rm -f "$$tmp"; \
	else \
	    mv "$$tmp" '$@'; \
	fi

# Link sources into the ELF; MAKEFILE_LIST makes build-logic changes relink it.
$(EXECUTABLE_ELF_FILE): $(SRC_C) $(DDR_BOOT_STUB) $(ASSEMBLY_STARTUP_FILE) $(EXTRA_ASM_SRC) $(LINKER_SCRIPT) \
                        $(MAKEFILE_LIST) $(BUILD_CONFIG_FILE)
	@tmp='$(DEPENDENCY_FILE).$$$$.tmp'; \
	if $(CC) $(CFLAGS) -MM -MP -MT '$@' \
	        $(DDR_BOOT_STUB) $(ASSEMBLY_STARTUP_FILE) $(EXTRA_ASM_SRC) $(SRC_C) > "$$tmp"; then \
	    mv "$$tmp" '$(DEPENDENCY_FILE)'; \
	else \
	    rm -f "$$tmp"; \
	    exit 1; \
	fi
	$(CC) $(CFLAGS) $(DDR_BOOT_STUB) $(ASSEMBLY_STARTUP_FILE) $(EXTRA_ASM_SRC) $(SRC_C) $(LDFLAGS) -o $@

$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

# Verilog hex image for $readmemh, used by simulation and synthesis: one 32-bit
# word per line in hexadecimal, little-endian. Cached-region (.ddr_*) sections
# are excluded because they live at 0x8000_0000 and would emit @-records far
# beyond the low BRAM. They ship separately in $(DDR_HEX_FILE).
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
	      $(addprefix -R ,$(DDR_SPLIT_SECTIONS)) $< $@

# Dword-paired image for the 64-bit data BRAM ($readmemh rows are dwords;
# hw/rtl/README.md "Data-tier bus contract"). Every loader keeps the 32-bit-word formats.
$(DWORD_HEX_FILE): $(VERILOG_HEX_FILE) ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py $< $@

# Raw binary, stripped of ELF headers and metadata. Cached-region sections are
# excluded so the binary spans only the low BRAM image.
$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id \
	      $(addprefix -R ,$(DDR_SPLIT_SECTIONS)) $< $@

# The cached-region (DDR) image holds the DDR_SPLIT_SECTIONS loaded sections:
# .ddr_* only in the bram tier, the whole program in the ddr tier. They are
# rebased so file offset 0 is the cached-region base, 0x8000_0000. Simulation
# loads this image into the behavioral DDR model, hardware through the JTAG
# loader.
# Programs with no selected loaded sections get a single zero word so consumers
# can always $readmemh the file. objcopy exits zero and writes an empty file in
# that case, so any nonzero objcopy status is a real build failure.
# The output goes to a temporary path first, so a failed conversion cannot
# bless or replace a previously generated image.
$(DDR_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	@set -e; \
	tmp='$@.$$$$.tmp'; \
	trap 'rm -f "$$tmp"' 0 1 2 3 15; \
	$(OBJCOPY) -O verilog --verilog-data-width 4 $(addprefix -j ,$(DDR_SPLIT_SECTIONS)) \
	      --change-addresses -0x80000000 '$<' "$$tmp"; \
	if [ ! -s "$$tmp" ]; then printf '00000000\n' > "$$tmp"; fi; \
	mv "$$tmp" '$@'

# DDR image for the JTAG loader: dense 32-bit words from the region base, since
# the selected sections start exactly at 0x8000_0000. The file is empty when the
# program places nothing in the cached region, and the loader skips empty files.
# As above, temporary outputs prevent a failed objcopy from reusing stale DDR
# contents.
$(DDR_TXT_FILE): $(EXECUTABLE_ELF_FILE)
	@set -e; \
	bin_tmp='sw_ddr.bin.$$$$.tmp'; \
	txt_tmp='$@.$$$$.tmp'; \
	trap 'rm -f "$$bin_tmp" "$$txt_tmp"' 0 1 2 3 15; \
	$(OBJCOPY) -O binary $(addprefix -j ,$(DDR_SPLIT_SECTIONS)) '$<' "$$bin_tmp"; \
	if [ -s "$$bin_tmp" ]; then \
	    xxd -e -g4 -c4 "$$bin_tmp" | awk '{printf "%08x\n", strtonum("0x" $$2)}' > "$$txt_tmp"; \
	else \
	    : > "$$txt_tmp"; \
	fi; \
	mv "$$bin_tmp" sw_ddr.bin; \
	mv "$$txt_tmp" '$@'

# Vivado BRAM initialization file: 8 hex digits per line, zero-padded.
$(VIVADO_BRAM_FILE): $(RAW_BINARY_FILE)
	xxd -e -g4 -c4 $< | awk '{printf "%08x\n", strtonum("0x" $$2)}' > $@

# Generate direct Vivado init files for the split instruction memory banks.
ifeq ($(GENERATE_IMEM_INIT),1)
$(IMEM_EVEN_COLD_INIT_FILE) $(IMEM_ODD_COLD_INIT_FILE) \
$(IMEM_EVEN_FRONTEND_HOT_INIT_FILE) $(IMEM_ODD_FRONTEND_HOT_INIT_FILE) \
$(IMEM_EVEN_SIDEBAND_FILE) $(IMEM_ODD_SIDEBAND_FILE) \
$(IMEM_EVEN_COMPRESSED_FILE) $(IMEM_ODD_COMPRESSED_FILE) \
$(IMEM_SCALAR_INIT_FILES): $(VERILOG_HEX_FILE) $(IMEM_INIT_SCRIPT)
	python3 $(IMEM_INIT_SCRIPT) $(VERILOG_HEX_FILE) \
		--depth-words 65536 \
		--even-cold $(IMEM_EVEN_COLD_INIT_FILE) \
		--odd-cold $(IMEM_ODD_COLD_INIT_FILE) \
		--even-frontend-hot $(IMEM_EVEN_FRONTEND_HOT_INIT_FILE) \
		--odd-frontend-hot $(IMEM_ODD_FRONTEND_HOT_INIT_FILE) \
		--even-sideband $(IMEM_EVEN_SIDEBAND_FILE) \
		--odd-sideband $(IMEM_ODD_SIDEBAND_FILE) \
		--even-compressed $(IMEM_EVEN_COMPRESSED_FILE) \
		--odd-compressed $(IMEM_ODD_COMPRESSED_FILE) \
		--even-is-compressed-lo $(IMEM_EVEN_IS_COMPRESSED_LO_FILE) \
		--odd-is-compressed-lo $(IMEM_ODD_IS_COMPRESSED_LO_FILE) \
		--even-is-compressed-hi $(IMEM_EVEN_IS_COMPRESSED_HI_FILE) \
		--odd-is-compressed-hi $(IMEM_ODD_IS_COMPRESSED_HI_FILE) \
		--even-even-local-pair-valid $(IMEM_EVEN_EVEN_LOCAL_PAIR_VALID_FILE) \
		--odd-even-local-pair-valid $(IMEM_ODD_EVEN_LOCAL_PAIR_VALID_FILE) \
		--even-pairable-native-lo $(IMEM_EVEN_PAIRABLE_NATIVE_LO_FILE) \
		--odd-pairable-native-lo $(IMEM_ODD_PAIRABLE_NATIVE_LO_FILE) \
		--even-pairable-compressed-hi $(IMEM_EVEN_PAIRABLE_COMPRESSED_HI_FILE) \
		--odd-pairable-compressed-hi $(IMEM_ODD_PAIRABLE_COMPRESSED_HI_FILE) \
		--even-pairable-native-hi $(IMEM_EVEN_PAIRABLE_NATIVE_HI_FILE) \
		--odd-pairable-native-hi $(IMEM_ODD_PAIRABLE_NATIVE_HI_FILE) \
		--even-slot2-start-valid-lo $(IMEM_EVEN_SLOT2_START_VALID_LO_FILE) \
		--odd-slot2-start-valid-lo $(IMEM_ODD_SLOT2_START_VALID_LO_FILE)
endif

size: $(EXECUTABLE_ELF_FILE)
	$(SIZE) $<

# Clean all build artifacts. Literal retired init names remain here so a reused
# app directory cannot retain stale provenance from older timing replicas.
clean:
	$(RM) $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(DWORD_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DDR_HEX_FILE) \
	      $(DDR_TXT_FILE) sw_ddr.bin $(DISASSEMBLY_FILE) $(BUILD_CONFIG_FILE) $(DEPENDENCY_FILE) \
	      $(IMEM_EVEN_COLD_INIT_FILE) $(IMEM_ODD_COLD_INIT_FILE) \
	      $(IMEM_EVEN_FRONTEND_HOT_INIT_FILE) $(IMEM_ODD_FRONTEND_HOT_INIT_FILE) \
	      $(IMEM_EVEN_SIDEBAND_FILE) $(IMEM_ODD_SIDEBAND_FILE) \
	      $(IMEM_EVEN_COMPRESSED_FILE) $(IMEM_ODD_COMPRESSED_FILE) \
	      $(IMEM_SCALAR_INIT_FILES) \
	      sw_imem_even_pc_compressed.mem sw_imem_odd_pc_compressed.mem \
	      sw_imem_even_compressed_hi.mem sw_imem_odd_compressed_hi.mem \
	      sw_imem_even_pc_metadata.mem sw_imem_odd_pc_metadata.mem \
	      sw_imem_even_pc_metadata_bit2.mem sw_imem_odd_pc_metadata_bit2.mem \
	      sw_imem_even_pc_metadata_bit3.mem sw_imem_odd_pc_metadata_bit3.mem

.PHONY: all size clean

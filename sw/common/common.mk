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

# Common Makefile definitions for RISC-V bare-metal software compilation
# NOTE: --depth-words 32768 below = the INSTRUCTION array depth (IMEM_SIZE_BYTES
# = 128KiB in hw/rtl/frost.sv). The data memory stays at MEM_SIZE_BYTES (256KiB).
# Configures toolchain and build rules for FROST RISC-V processor

# RISC-V cross-compiler toolchain prefix (can be overridden)
RISCV_PREFIX ?= riscv-none-elf-

# Toolchain executables
CC      := $(RISCV_PREFIX)gcc      # C compiler
OBJCOPY := $(RISCV_PREFIX)objcopy  # Binary format converter
OBJDUMP := $(RISCV_PREFIX)objdump  # Disassembler
SIZE    := $(RISCV_PREFIX)size     # Size analyzer

# FPGA CPU clock frequency in Hz (used for timing calculations)
# Can be overridden via environment variable for different boards
FPGA_CPU_CLK_FREQ ?= 300000000  # 300 MHz (default for X3)

# Optimization level (can be overridden by app-specific Makefiles before including common.mk)
# Default: -O3 for maximum performance
# Some apps (e.g., isa_test) may need -O2 to avoid GP-relative relocation overflow
OPT_LEVEL ?= -O3

# Loop unrolling (can be disabled by app-specific Makefiles before including common.mk)
# Default: enabled for performance
# Some apps (e.g., isa_test) may need to disable this
UNROLL_LOOPS ?= -funroll-loops

# ABI (can be overridden by app-specific Makefiles before including common.mk)
# Default: ilp32d for double-precision float ABI
# Some apps (e.g., coremark) may prefer ilp32f for better performance
MABI ?= ilp32d

# RISC-V compilation flags
#
# Architecture flags (-march, -mabi):
#   -march=rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
#     RV32IMAFDCB ISA (using explicit Zba_Zbb_Zbs for toolchain compatibility):
#       - I: Base integer instructions
#       - M: Multiply/divide
#       - A: Atomics (LR.W, SC.W, AMO instructions)
#       - B: Bit manipulation (B = Zba + Zbb + Zbs, spelled out in march string)
#       - C: Compressed instructions (16-bit instruction encoding)
#       - F: Single-precision floating-point
#       - D: Double-precision floating-point
#     Additional extensions:
#       - Zicsr: CSR instructions
#       - Zicntr: Base counters (cycle, time, instret)
#       - Zifencei: Instruction fetch fence
#       - Zicond: Conditional operations (czero.eqz, czero.nez)
#       - Zbkb: Bit manipulation for crypto (pack, packh, brev8, zip, unzip)
#       - Zihintpause: Pause hint for spin-wait loops
#   -mabi=$(MABI): ABI selection (default ilp32d, can be overridden to ilp32f)
#
# Bare-metal flags:
#   -nostdlib:      Don't link standard C library (we provide our own minimal lib/)
#   -nostartfiles:  Don't use standard startup files (we use crt0.S)
#   -ffreestanding: Freestanding environment (no OS assumptions, allows non-standard main)
#
# Code size and exception handling:
#   -fno-unwind-tables -fno-asynchronous-unwind-tables:
#     Disable generation of .eh_frame and .eh_frame_hdr sections. These are used
#     for C++ exceptions and stack unwinding, which we don't need in bare-metal C.
#     Saves significant code space (can be 10-20% of binary size).
#
# Optimization safety:
#   -fno-strict-aliasing:
#     Disable strict aliasing optimizations. Required for safe type-punning when
#     accessing hardware registers through pointer casts (e.g., casting addresses
#     to volatile uint32_t*). Without this, the compiler might reorder or eliminate
#     memory accesses that appear redundant but are actually necessary for MMIO.
#
#   -ffunction-sections -fdata-sections:
#     Place each function and data item in its own section. Combined with the
#     linker's --gc-sections flag, this allows unused functions to be removed
#     from the final binary. Essential for library code like uart.c where apps
#     may only use a subset of functions (e.g., Coremark uses uart_printf but
#     not uart_getchar).
RISCV_FLAGS  = -march=rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause -mabi=$(MABI) -Wall -Wextra \
               -nostdlib -nostartfiles -ffreestanding \
               -fno-unwind-tables -fno-asynchronous-unwind-tables \
               -ffunction-sections -fdata-sections \
               $(OPT_LEVEL) $(UNROLL_LOOPS) -fno-strict-aliasing

# Memory configuration -- selects the linker + image split (apps/CI pass this via
# MEM_CONFIG):
#   bram (default): whole program in low BRAM; only opt-in .ddr_* sections in DDR.
#   ddr:            whole program relocated to the cached DDR region behind a ROM
#                   boot stub (exercises the L1I fetch path + D-side cached tier).
# DEFAULT is bram, so every board/FPGA flow is unaffected.
MEM_CONFIG ?= bram

ifneq ($(MEM_CONFIG),bram)
ifneq ($(MEM_CONFIG),ddr)
$(error MEM_CONFIG must be one of: bram, ddr (got '$(MEM_CONFIG)'))
endif
endif

ifeq ($(MEM_CONFIG),ddr)
# App Makefiles may still override LINKER_SCRIPT (e.g. freertos sets its own ddr
# linker before including this file); ?= respects that.
LINKER_SCRIPT ?= ../../common/link_ddr.ld
DDR_BOOT_STUB := ../../common/crt0_ddr_boot.S
# Whole program is in DDR: split ALL loadable sections into the DDR image, so the
# low-BRAM sw.mem/sw.bin contain only the ROM boot stub (no huge sparse image).
DDR_SPLIT_SECTIONS := .text .rodata .data .sdata .ddr_text .ddr_rodata .ddr_data
else
# Linker script (can be overridden by app-specific Makefiles before including common.mk)
LINKER_SCRIPT ?= ../../common/link.ld
DDR_BOOT_STUB :=
# Only the opt-in cached-region sections go to the DDR image (current behavior).
DDR_SPLIT_SECTIONS := .ddr_text .ddr_rodata .ddr_data
endif

# Linker flags - includes RISC-V flags plus linker script and section garbage collection
EXTRA_LDFLAGS ?=
LDFLAGS  += $(RISCV_FLAGS) -T $(LINKER_SCRIPT) -Wl,--gc-sections $(EXTRA_LDFLAGS)

# C compilation flags - includes RISC-V flags plus include paths and defines
CFLAGS = $(RISCV_FLAGS)
# addprefix leaves the optional app-specific include list completely absent when
# INCLUDE_DIR is empty.  A bare `-I` would consume the following -D option as its
# argument and silently drop that preprocessor definition.
CFLAGS += -I../../lib/include -I. $(addprefix -I,$(strip $(INCLUDE_DIR)))
CFLAGS += '-DCOMPILER_VERSION="$(COMPILER_VERSION)"' \
          '-DCOMPILER_FLAGS="$(RISCV_FLAGS)"' \
          '-DFPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ)' \
          $(EXTRA_CFLAGS)

# Assembly startup code (initializes stack, zeroes BSS, calls main)
ASSEMBLY_STARTUP_FILE := ../../common/crt0.S

# Additional assembly source files (can be set by app-specific Makefiles before including common.mk)
EXTRA_ASM_SRC ?=

# Output file names
EXECUTABLE_ELF_FILE     := sw.elf  # ELF executable with debug info
VERILOG_HEX_FILE        := sw.mem  # Verilog hex format for $readmemh
RAW_BINARY_FILE         := sw.bin  # Raw binary (no ELF headers)
VIVADO_BRAM_FILE        := sw.txt  # BRAM initialization format for Vivado
DDR_HEX_FILE            := sw_ddr.mem  # Cached-region (DDR) image, region-relative
DDR_TXT_FILE            := sw_ddr.txt  # DDR image for the JTAG loader (dense words)
DISASSEMBLY_FILE        := sw.S    # Human-readable disassembly
IMEM_EVEN_INIT_FILE     := sw_imem_even.mem
IMEM_ODD_INIT_FILE      := sw_imem_odd.mem
IMEM_EVEN_SIDEBAND_FILE := sw_imem_even_sideband.mem
IMEM_ODD_SIDEBAND_FILE  := sw_imem_odd_sideband.mem
IMEM_INIT_SCRIPT        := ../../common/generate_imem_predecode_init.py
DMEM_BANK0_INIT_FILE    := sw_dmem_bank0.mem
DMEM_BANK1_INIT_FILE    := sw_dmem_bank1.mem
DMEM_BANK_INIT_SCRIPT   := ../../common/generate_dmem_bank_init.py
# These bookkeeping files deliberately use globally ignored build-artifact
# suffixes (*.bin / *.o), so ordinary app builds never pollute git status.
BUILD_CONFIG_FILE       := .frost-build-config.bin
DEPENDENCY_FILE         := .frost-deps.o
GENERATE_IMEM_INIT ?= 0
IMEM_INIT_TARGETS :=
ifeq ($(GENERATE_IMEM_INIT),1)
IMEM_INIT_TARGETS := $(IMEM_EVEN_INIT_FILE) $(IMEM_ODD_INIT_FILE) $(IMEM_EVEN_SIDEBAND_FILE) $(IMEM_ODD_SIDEBAND_FILE) $(DMEM_BANK0_INIT_FILE) $(DMEM_BANK1_INIT_FILE)
endif

# Make does not normally notice changes to command-line flags because the output
# names are shared by every configuration.  Keep one content-addressed stamp: a
# tier/ABI/flag/tool change updates its mtime, while an identical invocation
# leaves it untouched.  This also makes switching back to a previously used
# configuration safe (unlike one stamp per configuration).
EFFECTIVE_BUILD_CONFIG = MEM_CONFIG=$(MEM_CONFIG)|CC=$(CC)|OBJCOPY=$(OBJCOPY)|OBJDUMP=$(OBJDUMP)|CFLAGS=$(CFLAGS)|LDFLAGS=$(LDFLAGS)|LINKER_SCRIPT=$(LINKER_SCRIPT)|DDR_BOOT_STUB=$(DDR_BOOT_STUB)|ASSEMBLY_STARTUP_FILE=$(ASSEMBLY_STARTUP_FILE)|EXTRA_ASM_SRC=$(EXTRA_ASM_SRC)|SRC_C=$(SRC_C)|DDR_SPLIT_SECTIONS=$(DDR_SPLIT_SECTIONS)

# Quote one single-line make value for a POSIX shell.  In particular, CFLAGS
# contains literal single quotes around its string-valued preprocessor defines.
shell_quote = '$(subst ','"'"',$(1))'

# The ELF is linked directly from source, so there are no per-object .d files.
# Generate an equivalent dependency fragment before each relink.  It records all
# non-system headers actually included by every C/preprocessed-assembly source;
# -MP keeps a removed header from making the old dependency fragment unparseable.

# Build targets
all: $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DDR_HEX_FILE) \
     $(DDR_TXT_FILE) $(DISASSEMBLY_FILE) $(IMEM_INIT_TARGETS)

# Keep `all` as the default goal even after the generated fragment exists (its
# first dependency rule also names sw.elf).
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

# Link C sources and assembly startup into the ELF executable.  MAKEFILE_LIST
# covers the app Makefile plus this included common file, so changing build logic
# is itself a rebuild trigger in addition to the effective-config stamp.
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

# Generate disassembly listing for debugging
$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

# Generate Verilog HEX file for $readmemh (used by simulation and synthesis).
# Cached-region (.ddr_*) sections are excluded: they live at 0x8000_0000 and
# would otherwise emit @-records far beyond the low BRAM; they are delivered
# separately via $(DDR_HEX_FILE).
# Format: One 32-bit word per line in hexadecimal (little-endian)
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
	      $(addprefix -R ,$(DDR_SPLIT_SECTIONS)) $< $@

# Generate raw binary file (stripped of ELF headers and metadata; cached-region
# sections excluded so the binary spans only the low BRAM image)
$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id \
	      $(addprefix -R ,$(DDR_SPLIT_SECTIONS)) $< $@

# Generate the cached-region (DDR) image: only the .ddr_* loaded sections,
# rebased so file offset 0 = the cached-region base (0x8000_0000). Loaded by
# the behavioral DDR model in simulation and the JTAG loader on hardware.
# Programs with no selected loaded sections get a single zero word so consumers
# can always $readmemh the file.  Objcopy successfully emits an empty file for
# that legitimate case; any nonzero objcopy status is a real build failure.
# Generate into a temporary path so a failed conversion cannot bless or replace
# a previously generated image.
$(DDR_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	@set -e; \
	tmp='$@.$$$$.tmp'; \
	trap 'rm -f "$$tmp"' 0 1 2 3 15; \
	$(OBJCOPY) -O verilog --verilog-data-width 4 $(addprefix -j ,$(DDR_SPLIT_SECTIONS)) \
	      --change-addresses -0x80000000 '$<' "$$tmp"; \
	if [ ! -s "$$tmp" ]; then printf '00000000\n' > "$$tmp"; fi; \
	mv "$$tmp" '$@'

# DDR image for the JTAG loader: dense 32-bit words from the region base
# (the .ddr_* sections start exactly at 0x8000_0000). Empty when the program
# places nothing in the cached region; the loader skips empty files.  As above,
# temporary outputs prevent a failed objcopy from reusing stale DDR contents.
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

# Generate Vivado BRAM initialization file (8 hex digits per line, zero-padded)
$(VIVADO_BRAM_FILE): $(RAW_BINARY_FILE)
	xxd -e -g4 -c4 $< | awk '{printf "%08x\n", strtonum("0x" $$2)}' > $@

# Generate direct Vivado init files for the split instruction memory banks.
ifeq ($(GENERATE_IMEM_INIT),1)
$(IMEM_EVEN_INIT_FILE) $(IMEM_ODD_INIT_FILE) $(IMEM_EVEN_SIDEBAND_FILE) $(IMEM_ODD_SIDEBAND_FILE): $(VERILOG_HEX_FILE) $(IMEM_INIT_SCRIPT)
	python3 $(IMEM_INIT_SCRIPT) $(VERILOG_HEX_FILE) \
		--depth-words 32768 \
		--even-data $(IMEM_EVEN_INIT_FILE) \
		--odd-data $(IMEM_ODD_INIT_FILE) \
		--even-sideband $(IMEM_EVEN_SIDEBAND_FILE) \
		--odd-sideband $(IMEM_ODD_SIDEBAND_FILE)

# Per-bank init files for the banked data memory (Vivado TDP inference
# cannot consume a staging-array copy loop; see tdp_bram_dc_byte_en.sv).
$(DMEM_BANK0_INIT_FILE) $(DMEM_BANK1_INIT_FILE): $(VERILOG_HEX_FILE) $(DMEM_BANK_INIT_SCRIPT)
	python3 $(DMEM_BANK_INIT_SCRIPT) $(VERILOG_HEX_FILE) \
		--depth-words 65536 \
		--bank-output $(DMEM_BANK0_INIT_FILE) \
		--bank-output $(DMEM_BANK1_INIT_FILE)
endif

# Display memory usage statistics
size: $(EXECUTABLE_ELF_FILE)
	$(SIZE) $<

# Clean all build artifacts
clean:
	$(RM) $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DDR_HEX_FILE) \
	      $(DDR_TXT_FILE) sw_ddr.bin $(DISASSEMBLY_FILE) $(BUILD_CONFIG_FILE) $(DEPENDENCY_FILE) \
	      $(IMEM_EVEN_INIT_FILE) $(IMEM_ODD_INIT_FILE) $(IMEM_EVEN_SIDEBAND_FILE) $(IMEM_ODD_SIDEBAND_FILE)

.PHONY: all size clean

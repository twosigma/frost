# Common Makefile definitions for RISC-V bare-metal software compilation
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
#     linker's --gc-sections flag, this allows unused functoins to be removed
#     from the final binary. Essential for library code like uart.c where apps
#     may only use a subset of functions (e.g., Coremark uses uart_printf but
#     not uart_getchar).
RISCV_FLAGS  = -march=rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause -mabi=$(MABI) -Wall -Wextra \
               -nostdlib -nostartfiles -ffreestanding \
               -fno-unwind-tables -fno-asynchronous-unwind-tables \
               -ffunction-sections -fdata-sections \
               $(OPT_LEVEL) $(UNROLL_LOOPS) -fno-strict-aliasing

# Linker script (can be overridden by app-specific Makefiles before including common.mk)
LINKER_SCRIPT ?= ../../common/link.ld

# Linker flags - includes RISC-V flags plus linker script and section garbage collection
EXTRA_LDFLAGS ?=
LDFLAGS  += $(RISCV_FLAGS) -T $(LINKER_SCRIPT) -Wl,--gc-sections $(EXTRA_LDFLAGS)

# C compilation flags - includes RISC-V flags plus include paths and defines
CFLAGS = $(RISCV_FLAGS)
CFLAGS += -I../../lib/include -I. -I$(INCLUDE_DIR)  # Include directories
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
DISASSEMBLY_FILE        := sw.S    # Human-readable disassembly

# Build targets
all: $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DISASSEMBLY_FILE)

# Link C sources and assembly startup into ELF executable
$(EXECUTABLE_ELF_FILE): $(SRC_C) $(ASSEMBLY_STARTUP_FILE) $(EXTRA_ASM_SRC) $(LINKER_SCRIPT)
	$(CC) $(CFLAGS) $(ASSEMBLY_STARTUP_FILE) $(EXTRA_ASM_SRC) $(SRC_C) $(LDFLAGS) -o $@

# Generate disassembly listing for debugging
$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

# Generate Verilog HEX file for $readmemh (used by simulation and synthesis)
# Format: One 32-bit word per line in hexadecimal (little-endian)
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id $< $@

# Generate raw binary file (stripped of ELF headers and metadata)
$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id $< $@

# Generate Vivado BRAM initialization file (8 hex digits per line, zero-padded)
$(VIVADO_BRAM_FILE): $(RAW_BINARY_FILE)
	xxd -e -g4 -c4 $< | awk '{printf "%08x\n", strtonum("0x" $$2)}' > $@

# Display memory usage statistics
size: $(EXECUTABLE_ELF_FILE)
	$(SIZE) $<

# Clean all build artifacts
clean:
	$(RM) $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) $(DISASSEMBLY_FILE)

.PHONY: all size clean

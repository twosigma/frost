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

# Builds one riscv-arch-test test case and emits its memory images.
#
# Usage: make TEST_SRC=riscv-arch-test/riscv-test-suite/rv64i_m/I/src/addw-01.S
#
# Uses gcc (not as) because .S test files use #include preprocessor directives.
# Uses the integer (soft-float) ABI since tests manage FP registers directly.

TEST_SRC ?=

# ARCH matches the -march value in common.mk RISCV_FLAGS (see arch.mk).
include ../../common/arch.mk
# Compressed code is carried except for the tests in NO_COMPRESS_TESTS
# below. XLEN_DEFINE feeds the framework's arch_test.h/model_test.h
# register-width macros and must track the march.
ARCH        = $(FROST_XLEN_PREFIX)imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
XLEN_DEFINE = -DXLEN=64
# lp64 needs PC-relative addressing for the DDR-resident test body: medlow's
# absolute lui cannot form 0x8xxx_xxxx addresses at XLEN=64 (sign-extension), so
# the ddr/icache links fail with relocation truncation. Matches the Spike
# reference build in generate_references.py.
CMODEL      = -mcmodel=medany
ABI  = $(FROST_INT_ABI)

# Misaligned load/store trap tests whose test op must not compress. The
# vendored arch_test.h trap handler resumes at (mepc & ~3) + 8, so it needs
# at least 8 bytes from the trapping op's start to the next case: a 4B op
# plus two 2B c.nops. A compressed c.sd/c.ld/c.sw/c.lw shrinks that to 6B,
# the resume lands mid-instruction, and the garbage-decode path that follows
# traps on absolute addresses. The signature then depends on the link map,
# which differs between the Spike reference link and ours. This list mirrors
# NO_COMPRESS_TESTS in generate_references.py so the DUT binary and the Spike
# reference stay flag-identical per test.
NO_COMPRESS_TESTS = misalign-ld-01 misalign-lw-01 misalign-sw-01 misalign-sd-01
TEST_NAME = $(basename $(notdir $(TEST_SRC)))
ifneq ($(filter $(TEST_NAME),$(NO_COMPRESS_TESTS)),)
ARCH := $(subst imafdc,imafd,$(ARCH))
endif

# Same toolchain prefix as common.mk.
RISCV_PREFIX ?= riscv-none-elf-
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

# Include paths: model_test.h is in this directory, arch_test.h is in env/
INCLUDES = -I. -Iriscv-arch-test/riscv-test-suite/env

# Which memory tiers a test exercises, so a failure is attributable to one
# path. tests/test_arch_compliance.py passes this via --mem-config.
#   ddr    (default): code + data + signature in the cached DDR region, so
#                     both the L1I fetch path and the D-side cached-tier
#                     load/store path are exercised.
#   icache:           code in DDR (L1I fetch path under test), data +
#                     signature in low BRAM, loaded and stored directly
#                     rather than through the D-side cached tier. Isolates
#                     instruction fetch.
#   bram:             code + data + signature all in low BRAM. Pure ISA
#                     conformance, neither cached tier involved.
MEM_CONFIG ?= ddr

# Each config picks a linker script, a boot stub, and the set of sections
# split out of the low BRAM image into the DDR image (sw_ddr.mem). The bram
# config keeps everything in BRAM, so its DDR section list is empty.
ifeq ($(MEM_CONFIG),bram)
LINKER_SCRIPT = link_arch_test_bram.ld
CRT0          = crt0_arch_test_bram.S
DDR_SECTIONS  =
else ifeq ($(MEM_CONFIG),icache)
LINKER_SCRIPT = link_arch_test_icache.ld
CRT0          = crt0_arch_test.S
DDR_SECTIONS  = .text .rodata
else ifeq ($(MEM_CONFIG),ddr)
LINKER_SCRIPT = link_arch_test.ld
CRT0          = crt0_arch_test.S
DDR_SECTIONS  = .text .rodata .data .sdata
else
$(error MEM_CONFIG must be one of: bram, icache, ddr (got '$(MEM_CONFIG)'))
endif

# Output file names match common.mk.
EXECUTABLE_ELF_FILE  = sw.elf
VERILOG_HEX_FILE     = sw.mem
DWORD_HEX_FILE       = sw64.mem
DDR_VERILOG_HEX_FILE = sw_ddr.mem
RAW_BINARY_FILE      = sw.bin
DISASSEMBLY_FILE     = sw.S

all: $(VERILOG_HEX_FILE) $(DWORD_HEX_FILE) $(DDR_VERILOG_HEX_FILE) $(DISASSEMBLY_FILE)

# Compile defines the test declares in its RVTEST_CASE strings (riscof's
# `def NAME=True` clauses): TEST_CASE_1 gates the body; tests that need
# the framework trap handler add rvtest_mtrap_routine. Tests without the
# handler leave mtvec at 0 and Frost completes their misaligned accesses
# (FLEN=64 signature fsd's) in hardware. Lazily expanded so clean works
# without TEST_SRC.
TEST_DEFINES = $(shell grep -ohE 'def +[A-Za-z_0-9]+ *= *True' $(TEST_SRC) \
	| sed -E 's/def +([A-Za-z_0-9]+) *= *True/-D\1=True/' | sort -u)

# Compile and link .S test file + startup stub via gcc (handles #include)
$(EXECUTABLE_ELF_FILE): $(TEST_SRC) $(CRT0) model_test.h $(LINKER_SCRIPT)
ifndef TEST_SRC
	$(error TEST_SRC is not set. Usage: make TEST_SRC=riscv-arch-test/riscv-test-suite/rv64i_m/I/src/addw-01.S)
endif
	$(CC) -march=$(ARCH) -mabi=$(ABI) $(CMODEL) -nostdlib -nostartfiles \
		$(XLEN_DEFINE) -DFLEN=64 $(TEST_DEFINES) \
		$(INCLUDES) -T $(LINKER_SCRIPT) -o $@ $(CRT0) $(TEST_SRC)

# Low BRAM image: everything that is not split out to DDR. With an empty
# DDR_SECTIONS (bram config) this keeps the full image in BRAM.
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
		$(foreach s,$(DDR_SECTIONS),-R $(s)) $< $@


# Dword-paired image for the 64-bit data BRAM ($readmemh rows are dwords;
# hw/rtl/README.md "Data-tier bus contract"). Every loader keeps the 32-bit-word formats.
$(DWORD_HEX_FILE): $(VERILOG_HEX_FILE) ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py '$<' '$@'

# DDR image, region-relative addresses (the behavioral DDR / JTAG loader
# rebase it at 0x8000_0000). With no DDR sections (bram config) emit an empty
# image so the harness symlink and the probed $readmemh both still work.
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

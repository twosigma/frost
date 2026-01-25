# Makefile for ISA Compliance Test Suite
# Comprehensive tests for all RISC-V extensions supported by Frost

# Use O2 for ISA test coverage and performance
OPT_LEVEL := -O2
# Disable loop unrolling (causes compilation failure)
UNROLL_LOOPS :=

# Avoid GP-relative relocations for large rodata in isa_test
EXTRA_CFLAGS := -msmall-data-limit=0
# Pull in libgcc for 64-bit division/modulo builtins (e.g., __udivdi3)
EXTRA_LDFLAGS := -lgcc

SRC_C   := ../../lib/src/uart.c ../../lib/src/string.c isa_test.c
include ../../common/common.mk

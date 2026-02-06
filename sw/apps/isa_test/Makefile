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

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

# Self-checking tests for the RISC-V extensions FROST implements, plus M-mode
# CSRs and traps.

# -O2 instead of common.mk's default -O3, for ISA test coverage and performance.
OPT_LEVEL := -O2
UNROLL_LOOPS :=
# Compressed-instruction tests deliberately clobber s0. Keep that register
# available with DWARF/-Og too; ordinary frame-pointer unwinding is unavailable.
FROST_DEBUG_FRAME_POINTER := 0

# Put no objects in the small-data sections. The DDR-tier link fails without
# it (R_RISCV_HI20 overflow in c_test_trap_handler).
EXTRA_CFLAGS := -msmall-data-limit=0
EXTRA_LDFLAGS := -lgcc

SRC_C   := ../../lib/src/uart.c ../../lib/src/string.c isa_test.c
include ../../common/common.mk

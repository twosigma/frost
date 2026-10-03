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

# -O2 rather than common.mk's -O3: the checks are inline assembly, so the level
# only changes the C code around them, and -O2 keeps that code smaller.
OPT_LEVEL := -O2
# No -funroll-loops: the checks are inline assembly, so unrolling only grows the
# image (about 10 KiB) and slows the run.
UNROLL_LOOPS :=
# Compressed-instruction tests deliberately clobber s0. Keep that register
# available with DWARF/-Og too; ordinary frame-pointer unwinding is unavailable.
FROST_DEBUG_FRAME_POINTER := 0

SRC_C   := ../../lib/src/uart.c ../../lib/src/string.c isa_test.c
include ../../common/common.mk

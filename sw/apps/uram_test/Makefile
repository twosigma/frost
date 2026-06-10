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

# Makefile for URAM tier test application
# Writes/reads distinct patterns across the high-address UltraRAM tier
# (URAM_BASE = 0x0100_0000, 2 MiB) to exercise URAM stores + N-cycle loads
# through the new per-tier memory path. Code/data/stack stay in the low BRAM;
# the URAM region is reached purely via absolute-address volatile pointers, so
# no custom linker script is needed.
SRC_C   := ../../lib/src/uart.c uram_test.c
include ../../common/common.mk

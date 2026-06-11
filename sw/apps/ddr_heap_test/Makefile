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

# Makefile for the cached-region (DDR) heap capacity test.
# Allocates several MiB via malloc from the DDR-backed cached region and
# verifies the data reads back correctly through the cache hierarchy -- the
# capacity that unblocks the big CoreMark-PRO heaps. Uses the unified linker
# script, which places the heap at CACHED_BASE (0x8000_0000, ~1 GiB) while
# code/data/stack stay in low BRAM.
SRC_C   := ../../lib/src/uart.c ../../lib/src/memory.c ../../lib/src/string.c ddr_heap_test.c
LINKER_SCRIPT := ../../common/link_unified.ld
include ../../common/common.mk

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

# Page-table-walker vs dirty-L1D coherence directed test. The walker reads
# PTEs from the shared level (L2/memory) and never from the write-back L1D, so
# a PTE table left dirty in the L1D while its PMD pointer reaches L2 yields a
# torn walk (Sv39, M-mode/MPRV windows; page tables in cached DDR).
SRC_C := ../../lib/src/uart.c main.c
include ../../common/common.mk

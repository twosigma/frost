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

# Directed "skipped fall-through fetch window" reproducer with a self-defined
# _start (no crt0.S). M covers the driver's remu and the divu backpressure
# subtest, C the compressed code in every victim, and Zba+Zbb the sh1add.uw and
# minu in subtest G, a byte-for-byte copy of compiled zlib code.
include ../../common/arch.mk
ARCH := $(FROST_XLEN_PREFIX)imac_zicsr_zba_zbb
ABI := $(FROST_INT_ABI)
ASM_SRC := window_skip_repro.S

include ../../common/standalone_asm.mk

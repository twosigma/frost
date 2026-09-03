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

# RV64 smoke test (Phase 1 M2) with a self-defined _start (no crt0.S).
# Base ISA only: no compressed code (M4) and no M/A/F (M3).

include ../../common/arch.mk

ARCH := $(FROST_XLEN_PREFIX)i
ABI := $(FROST_INT_ABI)
ASM_SRC := rv64_smoke.S

include ../../common/standalone_asm.mk

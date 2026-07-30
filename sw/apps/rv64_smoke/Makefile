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
# rv64-only: W-ops/LD/SD do not exist at rv32, so this app requires the
# FROST_RV64=1 build axis (the cocotb runner sets it for this target).
# Base ISA only — no compressed code (M4) and no M/A/F (M3).

# XLEN axis: FROST_RV64=1 selects the rv64/lp64 build (see arch.mk)
include ../../common/arch.mk

ifneq ($(FROST_RV64),1)
$(error rv64_smoke is an rv64-only app: build with FROST_RV64=1)
endif

ARCH := $(FROST_XLEN_PREFIX)i
ABI := $(FROST_INT_ABI)
ASM_SRC := rv64_smoke.S

include ../../common/standalone_asm.mk

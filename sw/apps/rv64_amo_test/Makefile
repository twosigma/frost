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

# RV64 A-extension directed test (Phase 1 plan M6): the doubleword atomics
# and LR.D/SC.D, which rv64_smoke's M2-minimum slice predates.
include ../../common/arch.mk

ARCH := $(FROST_XLEN_PREFIX)ia_zicsr
ABI := $(FROST_INT_ABI)
ASM_SRC := rv64_amo_test.S

include ../../common/standalone_asm.mk

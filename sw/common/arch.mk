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

# Architecture strings for the rv64/lp64 software build (the core is
# RV64-only; rv32 support was retired after Phase 1).
#
# App and backend Makefiles compose their -march strings from
# $(FROST_XLEN_PREFIX) plus their own extension suffix, and pick the
# matching ABI / linker emulation from the variables below.

FROST_XLEN_PREFIX  := rv64
FROST_INT_ABI      := lp64
FROST_FP_ABI       := lp64d
FROST_LD_EMULATION := elf64lriscv

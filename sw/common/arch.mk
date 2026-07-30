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

# XLEN build axis (docs/rv64/phase1_plan.md, milestone M2 / decision D1).
#
# FROST_RV64=1 selects the rv64/lp64 software build to match the RTL's
# -DFROST_RV64 elaboration (tests/Makefile adds the define from the same
# environment variable, and verif/config.py reads it, so one knob flips
# hardware, software, and verification in lockstep). Unset/0 keeps the
# rv32/ilp32 production shape bit-for-bit.
#
# App and backend Makefiles compose their -march strings from
# $(FROST_XLEN_PREFIX) plus their own extension suffix, and pick the
# matching ABI / linker emulation from the variables below.

FROST_RV64 ?= 0

ifeq ($(FROST_RV64),1)
FROST_XLEN_PREFIX  := rv64
FROST_INT_ABI      := lp64
FROST_FP_ABI       := lp64d
FROST_LD_EMULATION := elf64lriscv
else
FROST_XLEN_PREFIX  := rv32
FROST_INT_ABI      := ilp32
FROST_FP_ABI       := ilp32d
FROST_LD_EMULATION := elf32lriscv
endif

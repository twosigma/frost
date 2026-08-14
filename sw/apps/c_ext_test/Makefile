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

# Compressed-instruction test with a self-defined _start (no crt0.S).
# Architecture must match common.mk's supported ISA.
# Architecture strings come from arch.mk
include ../../common/arch.mk
ARCH := $(FROST_XLEN_PREFIX)imac_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI := $(FROST_INT_ABI)
ASM_SRC := c_ext_test.S

include ../../common/standalone_asm.mk

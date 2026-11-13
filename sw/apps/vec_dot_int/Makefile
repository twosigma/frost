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

# Integer dot products at 8, 16, 32 and 64 bits.
# Vector-length agnostic: it reads vlenb at run time. VLEN selects the
# -march vector length floor (128, 256 or 512); the program runs on any
# hardware vector length at or above it.
VLEN ?= 128
SRC_C := ../../lib/src/uart.c ../../lib/src/string.c main.c
EXTRA_ASM_SRC := dot_rvv.S
INCLUDE_DIR := ../vec_common
FROST_MARCH_EXTENSIONS := imafdcv_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zfh_zvfh_zvfhmin_zvbb_zvbc_zvkt_zvkg_zvkned_zvknhb_zvksed_zvksh_zvl$(VLEN)b
APP_TUNE_FLAGS := -fno-tree-vectorize
include ../../common/common.mk

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

# Reorder complete, unmodified translation units for placement ensembles.
COREMARK_SOURCES := core_list_join core_main core_matrix core_state core_util
COREMARK_SOURCE_ORDER ?= $(COREMARK_SOURCES)
ifneq ($(sort $(COREMARK_SOURCE_ORDER)),$(sort $(COREMARK_SOURCES)))
$(error COREMARK_SOURCE_ORDER must contain each benchmark source exactly once)
endif
ifneq ($(words $(COREMARK_SOURCE_ORDER)),5)
$(error COREMARK_SOURCE_ORDER must contain five sources)
endif
SRC_C := ../../lib/src/uart.c $(addprefix coremark/,$(addsuffix .c,$(COREMARK_SOURCE_ORDER))) core_portme.c ../../lib/src/tomasulo_profile_cache.c
INCLUDE_DIR = ./coremark

# Use the RV64 hard-float ABI.
MABI := lp64d

# C remains opt-in until link-order ensembles show stable throughput despite
# the 64-bit fetch-window limit. scripts/coremark_sweep.py records both modes.
COREMARK_COMPRESSED ?= 0
ifeq ($(filter $(COREMARK_COMPRESSED),0 1),)
$(error COREMARK_COMPRESSED must be 0 or 1)
endif
FROST_MARCH_EXTENSIONS := imafd$(if $(filter 1,$(COREMARK_COMPRESSED)),c)_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause

COREMARK_SEED_SET ?= performance
ifeq ($(COREMARK_SEED_SET),performance)
COREMARK_SEED_FLAGS := -DPERFORMANCE_RUN=1
else ifeq ($(COREMARK_SEED_SET),validation)
COREMARK_SEED_FLAGS := -DVALIDATION_RUN=1
else
$(error COREMARK_SEED_SET must be performance or validation)
endif

# Compiler tuning for the pinned Bootlin toolchain. Inlining reduces hot calls;
# CB allocation and selective scheduling control spills and instruction order.
# Keep LTO paired with both peel caps to preserve GCC's CRC idiom recognition.
# The CPU tune is a compiler cost model, not a change to FROST's ISA.
# Validate both official seed sets and compare matched simulation/board runs
# when changing these flags; Spike instruction counts alone do not measure speed.
COREMARK_CPU_TUNE := -mtune=sifive-7-series

# Overridable for A/B runs.
COREMARK_BASE_TUNE := --param max-inline-insns-auto=200 -fira-algorithm=CB \
                      -fstrict-aliasing -fselective-scheduling
# Static-layout tuning is omitted when measured branch profiles are available.
COREMARK_STATIC_LAYOUT_TUNE := -fno-crossjumping -freorder-blocks-and-partition
# Keep LTO and peel caps together; PGO has a separate flag set below.
COREMARK_LTO_TUNE := -flto --param max-completely-peeled-insns=0 \
                     --param max-completely-peel-times=0

# Optional PGO uses the official profile data set (1200 bytes, seeds 8/8/8).
# APP_TUNE_FLAGS discloses the profile flags in the reported compiler settings.
# Use -fbranch-probabilities to read edge counts without enabling the extra
# transformations in -fprofile-use.
#
# iss/generate_profile.py regenerates profiles for the five benchmark units;
# the Spike port layer is different and has no profile here. The existence
# check prevents missing profiles from silently changing the build. See
# iss/README.md for generation and validation.
COREMARK_PGO_TUNE := -fbranch-probabilities -fprofile-correction \
                     -Wno-missing-profile
COREMARK_PGO ?= 0
COREMARK_PGO_PROFILES :=
ifeq ($(COREMARK_PGO),1)
COREMARK_PGO_PROFILES := $(addsuffix .gcda,$(addprefix sw.elf-,\
    core_list_join core_main core_matrix core_state core_util))
$(foreach profile,$(COREMARK_PGO_PROFILES),\
    $(if $(wildcard $(profile)),,$(error COREMARK_PGO=1 needs $(profile); run \
    ./scripts/frost.py run sw/apps/coremark/iss/generate_profile.py)))
APP_TUNE_FLAGS ?= $(COREMARK_BASE_TUNE) $(COREMARK_PGO_TUNE) $(COREMARK_CPU_TUNE)
else ifeq ($(COREMARK_PGO),0)
APP_TUNE_FLAGS ?= $(COREMARK_BASE_TUNE) $(COREMARK_STATIC_LAYOUT_TUNE) \
                  $(COREMARK_LTO_TUNE) $(COREMARK_CPU_TUNE)
else
$(error COREMARK_PGO must be 0 or 1)
endif

# 11000 iterations is about ten seconds at the rated 300 MHz baseline.
# Faster implementations need more iterations; use at least 14000 when
# evaluating the 4 CoreMark/MHz, 322.265625 MHz target and check elapsed time.
ITERATIONS ?= 11000

# CoreMark allocates its workspace on the stack. Both settings stay
# overridable so a targeted reproducer run can place it elsewhere.
COREMARK_MEM_METHOD ?= MEM_STACK
COREMARK_MEM_LOCATION ?= "STACK"

COREMARK_EXTRA_CFLAGS ?=
COREMARK_EXTRA_LDFLAGS ?=

# common.mk folds EXTRA_CFLAGS/EXTRA_LDFLAGS into its own flags, so set them
# before the include.
EXTRA_CFLAGS = '-DITERATIONS=$(ITERATIONS)' -DUART_PRINTF_ENABLE_FLOAT=1 \
               -DMEM_METHOD=$(COREMARK_MEM_METHOD) \
               '-DMEM_LOCATION=$(COREMARK_MEM_LOCATION)' \
               $(COREMARK_SEED_FLAGS) $(COREMARK_EXTRA_CFLAGS)
EXTRA_LDFLAGS = -lgcc $(COREMARK_EXTRA_LDFLAGS)

include ../../common/common.mk

# A regenerated profile must relink: common.mk's build-config stamp hashes the
# flags, not the profile bytes.
$(EXECUTABLE_ELF_FILE): $(COREMARK_PGO_PROFILES)

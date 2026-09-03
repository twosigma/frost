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

SRC_C   := ../../lib/src/uart.c coremark/core_list_join.c coremark/core_main.c coremark/core_matrix.c coremark/core_state.c coremark/core_util.c core_portme.c ../../lib/src/tomasulo_profile_cache.c
INCLUDE_DIR = ./coremark

# lp64d ABI per the Phase 1 plan (M6).
MABI := lp64d

# 11000 iterations is about a 10 second run on X3 at 300 MHz. Boards at a
# different clock override this from the environment.
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
               $(COREMARK_EXTRA_CFLAGS)
EXTRA_LDFLAGS = -lgcc $(COREMARK_EXTRA_LDFLAGS)

include ../../common/common.mk

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

# lp64d ABI per the Phase 1 plan (M6). There is no ABI retreat from the 32-bit
# data this benchmark keeps: the pinned GCC 15.2 rejects every -mabi=ilp32*
# spelling on rv64 with "ABI requires '-march=rv32'" (RV64ILP32 exists only as
# a psABI proposal, unsupported here), so the cost is paid down in codegen. The
# residual is measured rather than assumed: running the same sources through
# Spike at matched flags, with C retained symmetrically in both ABI lanes,
# ilp32d retires 221,578 timed-region instructions to lp64d's 251,089 (+13.3%),
# up from +11.7% untuned. The ABI penalty grows slightly with tuning, so what
# the settings below recover is XLEN-independent headroom, not the lp64 gap.
MABI := lp64d

# Drop the C extension for this program only (the core still implements it and
# every other app keeps it). CoreMark is front-end bound on FROST: with RVC the
# 2-wide bundler loses slot 2 whenever a 32b+32b pair spans the 64-bit fetch
# window, and where those boundaries land is decided by code placement. The
# measurements in this paragraph and the flag ablation below were taken at RTL
# revision 7bddb24, the tuning branch's base. Over 18 link-order permutations
# of this program (semantically identical binaries; only function placement
# moves), rv64gcb spans 345k-380k timed-region ticks/iteration -- a 10.0% spread
# from placement alone, correlated with the "64b fetch-window limit" slot-2
# kill counter at r=0.60 -- while the build shipped below spans 0.30% over the
# same 18 and that counter reads exactly zero in every one. 2-wide IF delivery
# rises 42.7% -> 52.1%. Costs ~11% more .text on its own (still far inside the
# 96 KiB ROM region) and no instructions: instret moves by 6 out of 285,711.
FROST_MARCH_EXTENSIONS := imafd_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause

# Codegen tuning, appended last so it wins over common.mk's defaults. Measured
# in cycle-exact simulation as timed-region ticks per iteration; the untuned
# build of this source order is 363k, which is the shipped 827 CoreMark at
# 300 MHz:
#
#   --param max-inline-insns-auto=200   the big one. -O3's default auto-inline
#       budget leaves core_state_transition, cmp_complex and matrix_test out of
#       line; they are the per-element bodies of all three workloads, and
#       cmp_complex only becomes a direct call once core_list_mergesort is
#       cloned for its constant function-pointer argument. 285,711 -> 258,445
#       instructions retired (-9.5%), 363k -> 329k ticks. 100 is already enough;
#       60 is not. Text grows to ~61 KiB, still inside the 96 KiB ROM region.
#   -fira-algorithm=priority            -1.7% on the inlined-and-larger
#       functions, which spill under the default CB allocator.
#   -fstrict-aliasing                   -1.8%; overrides common.mk's global
#       -fno-strict-aliasing. This is how EEMBC's own reference build compiles
#       CoreMark (GCC's default at -O2/-O3). It builds warning-clean: the only
#       MMIO here is uart.c, and mmio.h now marks its punned register accessors
#       may_alias, so -Wstrict-aliasing is silent. CoreMark's own workspace
#       carving (one ee_u8 array read back as list_head/list_data/MATDAT/MATRES)
#       is type-punned by construction, but the regions are disjoint and the
#       run's CRC check covers it. Drop this one flag to keep the blanket
#       -fno-strict-aliasing guarantee for 1.8%.
#
# Together with the -march change above at revision 7bddb24: 363,677 -> 305,064
# ticks/iteration cold, and 362,727 -> 304,116 steady state (ITERATIONS=1/3/8
# marginal cost, linear to 0.02% between (t3-t1)/2 and (t8-t3)/5) -- -16.2%.
# At that RTL this projected to ~987 CoreMark at 300 MHz against the 827.32
# measured on silicon; the untuned build's 362,727 cycles predict that baseline
# within 0.03%. That projection is not
# current: after the Phase 3 low-BRAM predecode change, a matched two-run,
# one-iteration cocotb A/B averages 361,535 stock versus 353,923 tuned cycles
# (-2.11%, or ~848 at 300 MHz). Instret still falls from 285,705 to 252,302, but
# out-of-overlay front-end repeats consume most of the gain; ROADMAP Phase 6
# tracks the RTL recovery. See the X3 baseline note in fpga/hw_regression.py;
# the board number is not re-measured yet. Both CoreMark seed sets validate
# unchanged on the tuned build (performance 0xe9f5 and validation 0x18f2 ->
# crclist 0xe3c1, crcmatrix 0x0747, crcstate 0x8d84).
# Overridable for A/B runs.
APP_TUNE_FLAGS ?= --param max-inline-insns-auto=200 -fira-algorithm=priority \
                  -fstrict-aliasing

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

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
# data this benchmark keeps: GCC 15.2 in the original study rejects -mabi=ilp32*
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

# Historical xPack GCC 15.2 tuning, followed below by the Bootlin 15.3 retune.
# Flags are appended last so they win over common.mk's defaults. Measured
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
#   -fselective-scheduling -fno-crossjumping -freorder-blocks-and-partition
#       -0.76% (305,096 -> 302,764 ticks/iteration cold at the current RTL),
#       and only as a set: -fno-crossjumping alone is +1.49%, the pair without
#       the selective scheduler +1.43%, -fselective-scheduling alone -0.23%,
#       and -freorder-blocks-and-partition alone -0.01%. Crossjumping buys code
#       size by routing duplicate tails through extra jumps, and every control
#       transfer ends a bundle on this front end; the selective scheduler is
#       what makes the resulting straight-line code pay for itself. Four
#       different spellings of the same set land within 28 ticks of each other,
#       against a 0.045% placement floor (same code, .text shifted by
#       0/64/128/256/512/1024 bytes). This is the live part of NaxRiscv's
#       published flag set: its -fno-if-conversion2 costs +0.66% here, and its
#       -falign-{functions,jumps,loops}=4 and -finline-limit=1000 are no-ops
#       against the settings above. -fselective-scheduling is GCC's
#       experimental scheduler, not enabled by any -O level; it replaces the
#       first scheduler pass, and dropping scheduling entirely costs +3.28%.
#   -flto --param max-completely-peeled-insns=0
#         --param max-completely-peel-times=0
#       the set above plus these three is -2.85% (296,416), and the ROM image
#       drops from 60,620 to 38,380 bytes. The peel caps are not optional and
#       not independent: -flto on its own is +8.0%, the caps on their own are
#       neutral (305,010), and only together do they help. What plain LTO
#       loses is GCC's CRC idiom -- the baseline recognises crcu8, crcu16,
#       crcu32 and crc16, plain LTO only crcu16, and static rev8+brev8 falls
#       48 -> 18 -- which costs more than the cross-TU inlining gains, and
#       matches -fno-optimize-crc's own +10.3%. Capping the peel budget keeps
#       both: rev8+brev8 rises to 138 and the four routines stay recognised.
#       max-completely-peeled-insns=0 alone is enough (297,904 against the
#       pair's 297,915); both are set so a future GCC cannot reach the same
#       shape through the times budget.
#
# Together with the -march change above, the first three of those at revision
# 7bddb24 (the fourth is 2026-09-20, at the current RTL): 363,677 -> 305,064
# ticks/iteration cold, and 362,727 -> 304,116 steady state (ITERATIONS=1/3/8
# marginal cost, linear to 0.02% between (t3-t1)/2 and (t8-t3)/5) -- -16.2%.
# At that RTL this projected to ~987 CoreMark at 300 MHz against the 827.32
# measured on silicon; the untuned build's 362,727 cycles predict that baseline
# within 0.03%. The later 16 KiB low-BRAM predecode overlay obscured that gain:
# a matched two-run A/B averaged 361,535 stock versus 353,923 tuned cycles,
# despite the retired-instruction reduction from 285,705 to 252,302. The
# 64 KiB overlay recovers 305,059 / 304,727 cycles with the exact same tuned
# executable, a 13.85% cycle reduction from the regressed RTL. This is an RTL
# recovery, not another compiler retune. ROADMAP Phase 3 tracks it; see the
# X3 baseline note in fpga/hw_regression.py, armed from the board
# measurement. The original compiler-retune checks validated both seed sets on
# the tuned build (performance 0xe9f5 and validation 0x18f2 ->
# crclist 0xe3c1, crcmatrix 0x0747, crcstate 0x8d84).
#
# 2026-09-20 software-only sweep at this RTL: 186 configurations against the
# 305,096-tick baseline, every one that built validating seedcrc 0xe9f5 /
# crcfinal 0xe714, plus 27 warm-slope runs at ITERATIONS=1/3/8. In that sweep,
# the four settings above were the only ones that cleared the measurement floor.
# Dropping any of the first three costs between 1.8% and 12.5%. The negatives
# are the useful part, because they are what a reader would try next:
#
#   -ftracer +11.3%. Its superblock formation turns core_state_transition into
#       a jump table inside core_bench_state, and an unpredicted indirect jump
#       behind an unresolved branch is the one thing that hard-stalls this
#       front end (ooo_pipeline_control.sv): the Control-flow serialize counter
#       goes 0 -> 14,192 cycles and Pred fence indirect 536 -> 17,943.
#       --param tracer-dynamic-coverage=10 avoids the jump table and is then
#       merely neutral.
#   -fno-optimize-crc +10.3%. GCC 15 recognises all four of CoreMark's CRC
#       routines and replaces the bit loops with table lookups; that is worth
#       more than every tuning flag in this file combined.
#   -flto +8.0%, and it is the same mechanism: LTO loses the CRC idiom in
#       crcu8/crcu32/crc16 (static rev8+brev8 drop 48 -> 18) and adds 4.5%
#       timed-region instructions. Its 15 KiB ROM saving is almost all cold
#       .cache_profile_text; .text itself grows.
#   -falign-* +1.3% at 8 and +4.1% at 16. The fetch window is PC-relative, not
#       8-byte aligned -- imem_predecode.sv takes two independent word
#       addresses -- so with C dropped every window already delivers two
#       consecutive instructions and alignment padding is executed NOPs.
#       GCC's RISC-V defaults are already minimal; forcing =1 changes nothing.
#   Re-enabling C +6.3%, -Os +72.7%, --param max-inline-insns-auto=30 (GCC's
#       default) +12.5%, -freorder-blocks-algorithm=simple +4.0%,
#       -fno-reorder-blocks +8.1%, -fno-guess-branch-probability +11.0%.
#
# Measured neutral inside the 0.045% placement floor, so worth not retrying:
# -mmovcc; raised RTL if-conversion budgets (454 czero instructions against the
# baseline's 7, for -0.04%, so trading a branch for a Zicond data dependency is
# a wash here); -fipa-pta; -fsched-spec-load; every -fira-region setting;
# -mno-strict-align; -mshorten-memrefs; MEM_METHOD=MEM_STATIC; stack-top shifts
# of 64..2048 bytes (the 2,000-byte workspace self-conflicts in the 1 KiB
# direct-mapped LQ L0 wherever it sits); --param max-inline-insns-auto above
# 200 (300/400/800 are bit-identical); and -fno-unroll-loops -fno-peel-loops
# -fno-unswitch-loops, which scores within one tick with 4.1 KiB less .text --
# common.mk's global -funroll-loops earns nothing for this program.
#
# 2026-09-21 Bootlin 2026.08-1 / GCC 15.3 retune at RTL 0c0be1ec:
# copied xPack flags regressed score by 0.78-0.79%. A 31-case screen found
# that CB register allocation plus the sifive-7-series tuning model removes
# that regression without changing the ISA, ABI, source, or enabling PGO.
# First-boot / reset ITERATIONS=1: 295,639 / 295,205 cycles versus xPack's
# 296,400 / 295,941. ITERATIONS=8: 2,359,773 versus 2,366,130. Both official
# seed sets passed before and after reset. See docs/tooling.md for the gate.
# The scheduling model is a compiler cost model; FROST retains its own ISA.
# Keep its flag last to preserve the qualified build's exact flag string.
COREMARK_CPU_TUNE := -mtune=sifive-7-series

# Overridable for A/B runs.
COREMARK_BASE_TUNE := --param max-inline-insns-auto=200 -fira-algorithm=CB \
                      -fstrict-aliasing -fselective-scheduling
# Compensation for GCC's static branch-probability guesses; see above. With a
# real profile there is nothing left to compensate for, so the PGO lane drops
# them: keeping them there measures 301,116 against 294,640.
COREMARK_STATIC_LAYOUT_TUNE := -fno-crossjumping -freorder-blocks-and-partition
# Link-time optimization with complete peeling capped; see above. Excluded
# from the PGO lane because -flto and -fbranch-probabilities together are an
# internal compiler error in the original GCC 15.2 study ("lto1: internal compiler
# error: Segmentation fault"), with or without the caps.
COREMARK_LTO_TUNE := -flto --param max-completely-peeled-insns=0 \
                     --param max-completely-peel-times=0

# Profile-guided optimization, off by default. CoreMark's run rules permit it
# when the profile comes from the official profile data set (TOTAL_DATA_SIZE
# 1200, seeds 8/8/8 -- what core_portme.h calls PROFILE_RUN), and the reporting
# string discloses it by itself, because COMPILER_FLAGS carries APP_TUNE_FLAGS.
# Vendors generally do not publish PGO scores, so this stays opt-in; it is here
# because it is the largest software effect measured on this core and the
# number should be reproducible.
#
# Historical GCC 15.2 COREMARK_PGO=1 measurements: 294,640 ticks/iteration
# against 305,096 (-3.43%). This holds warm: at ITERATIONS=8 the marginal cost
# is 294,180 against the baseline's 304,276, -3.32%, linear to 0.008% between (t3-t1)/2 and
# (t8-t3)/5. Against the default lane above (296,416) it is worth a further
# 0.6% for 23 KiB more ROM image and a committed profile, which is why the
# default does not use it. It
# works by reallocating the inlining budget rather than enlarging it -- the
# comparator and core_list_mergesort go back out of line while core_bench_matrix
# and core_bench_state grow -- for 252,302 -> 234,090 retired instructions
# (-7.2%) and 308,386 -> 297,948 cycles on the counter build.
# -fbranch-probabilities, not -fprofile-use: the full -fprofile-use turns on
# -ftracer (+6.6% here), and even with -fno-tracer it measures 296,500. Reading
# the edge counts is the entire win.
#
# iss/generate_profile.py regenerates the five .gcda files under Spike; see
# iss/README.md. Only the five benchmark translation units carry a profile (the
# Spike port layer differs from this one), hence -Wno-missing-profile and the
# explicit existence check -- without it a deleted profile would quietly
# degrade the build instead of failing it.
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

# A regenerated profile must relink: common.mk's build-config stamp hashes the
# flags, not the profile bytes.
$(EXECUTABLE_ELF_FILE): $(COREMARK_PGO_PROFILES)

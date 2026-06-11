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

# ============================================================================
# FROST bare-metal build of the EEMBC CoreMark-PRO workloads.
#
#   make WORKLOAD=<name>
#
# builds sw.elf + sw.mem for any of the nine CoreMark-PRO workloads:
#
#   core                       (default; integer CoreMark)
#   cjpeg-rose7-preset         (JPEG compress; libjpeg + libbmp)
#   linear_alg-mid-100x100-sp  (LINPACK, single precision)
#   loops-all-mid-10k-sp       (Livermore/SciMark loops, single precision)
#   nnet_test                  (back-propagation neural net)
#   parser-125k                (XML/ezxml parser)
#   radix2-big-64k             (radix-2 FFT)
#   sha-test                   (SHA-256)
#   zip-test                   (zlib deflate/inflate)
#
# By default, each workload runs in a MINIMAL but still CRC-VERIFIED
# configuration so it completes in a simulation-friendly cycle count while
# remaining a true end-to-end correctness check. The minimal dataset for each
# workload is selected the same way the upstream PGO "training" run does
# (pgo_training_run, which picks each benchmark's smallest verified preset) --
# except cjpeg, which uses its smallest still-compiled preset (Rose256)
# directly. See the per-workload notes further down and frost_mith_main.c.
#
# Hardware loads pass COREMARK_PRO_OFFICIAL=1 plus COREMARK_PRO_RUN_ARGS="-v0
# -iN". Official mode disables pgo_training_run and selects the EEMBC
# README-specified macros/datasets; the run args disable verification and set
# an explicit hardware-sized outer iteration count.
#
# NOTE on iteration count: the MITH harness forces the workload's *outer*
# iteration count to 1 whenever verify_output is set (mith_lib.c
# mith_main_loop: "for a validation run there is no reason to run more than one
# iteration"). verify_output defaults to 1, so the big default outer loops
# (radix2 1000, sha/cjpeg/nnet 10, linpack/loops 50) collapse to a single
# verified pass automatically. The simulation path tunes dataset size via the
# preset, not the iteration count.
#
# (Running in simulation is out of scope here; this Makefile only links the
# image. The lead runs the sims.)
#
# ----------------------------------------------------------------------------
# Header-shadowing rationale (READ BEFORE EDITING INCLUDE PATHS):
#
# The MITH/workload sources need the *toolchain's* <string.h>/<stdlib.h>/
# <time.h> (full newlib declarations). The FROST sw/lib headers are named
# string.h / stdlib.h / ... and would shadow the toolchain headers if their
# directory were on the MITH compile include path. So we split compilation:
#
#   * FROST libc sources (sw/lib/src/*.c) and al_frost.c are compiled in
#     ISOLATION with -I../../lib/include  (they want the FROST headers).
#   * MITH/workload sources are compiled with ONLY the MITH include dirs plus
#     the toolchain's system headers (NO -I../../lib/include).
#
# All objects are then linked together: the libc *definitions* come from the
# FROST objects, while the MITH code saw the correct system header
# *declarations* at compile time. This mirrors sw/apps/riscv_tests/
# Makefile.bench (which compiles frostlib_*.o separately for the same reason).
# ============================================================================

# --- Workload / run selection ----------------------------------------------
WORKLOAD ?= core
COREMARK_PRO_RUN_ARGS ?=
COREMARK_PRO_OFFICIAL ?= 0
COREMARK_PRO_TRACE ?= 0
FROST_MALLOC_DISABLE_FREE ?= 0
FROST_MALLOC_GUARD_FREE ?= 0
FROST_MALLOC_EVICT_FREE ?= 0
FROST_MEMORY_FENCE_WRITES ?= 0

# --- Toolchain -------------------------------------------------------------
RISCV_PREFIX ?= riscv-none-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
SIZE    := $(RISCV_PREFIX)size
NM      := $(RISCV_PREFIX)nm

# --- CoreMark-PRO source (git submodule) -----------------------------------
# Vendored as a submodule at sw/apps/coremark_pro/coremark-pro (pinned), mirroring
# how sw/apps/coremark/coremark vendors eembc/coremark. The path is relative to
# this Makefile's directory (the build runs here, like the cocotb flow does), and
# is overridable, e.g. `make CMP_DIR=/abs/path/to/coremark-pro`.
CMP_DIR ?= coremark-pro

# --- FROST target architecture / ABI ---------------------------------------
ARCH := rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI  := ilp32d

# Low clock avoids overflow in the MITH score calculation (the regular CoreMark
# FROST port does the same).
FPGA_CPU_CLK_FREQ ?= 30000000

# Base flags shared by every translation unit (matches the FROST project flags
# and the upstream util/make/gccrv32.mak "FROST sizing" toolchain file).
BASE_FLAGS := -march=$(ARCH) -mabi=$(ABI) -O2 \
              -nostdlib -nostartfiles -ffreestanding \
              -ffunction-sections -fdata-sections -fno-strict-aliasing \
              -DCOREMARK_PRO_TRACE=$(COREMARK_PRO_TRACE)

# ============================================================================
# Per-workload configuration.
#
# For each workload we define:
#   WL_DIR      : workload subdir under $(CMP_DIR)/workloads
#   WL_BENCH    : list of $(CMP_DIR)-relative benchmark source files (kernel +
#                 dataset + any libraries) to compile into the image
#   WL_INC      : extra include dirs (benchmark dirs, dataset dir, lib dirs)
#   WL_DEFINES  : extra -D defines required by the benchmark/library
#   WL_PGO      : 1 -> FROST main() sets pgo_training_run=1 to select the
#                 benchmark's smallest verified preset; 0 -> use the workload's
#                 default preset index (only cjpeg, where the small preset is
#                 the one already compiled in).
#
# The workload's own main() lives in $(CMP_DIR)/workloads/$(WL_DIR)/$(WORKLOAD).c
# and is renamed to cmp_workload_main via -Dmain (see rules below).
# ============================================================================

# Convenience: benchmark / mith subtrees.
B := benchmarks
F := benchmarks/fp

ifeq ($(WORKLOAD),core)
  WL_DIR   := core
  WL_BENCH := \
      $(B)/core/core_list_join.c \
      $(B)/core/core_matrix.c \
      $(B)/core/core_mith.c \
      $(B)/core/core_state.c \
      $(B)/core/core_util.c \
      $(B)/core/core_portme.c
  WL_INC     := -I$(CMP_DIR)/$(B)/core
  WL_DEFINES :=
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_PGO     := 0
  else
    WL_PGO     := 1
  endif

else ifeq ($(WORKLOAD),cjpeg-rose7-preset)
  # consumer_v2/cjpeg = libjpeg compressor driven by the MITH "lite" harness.
  # Official builds use the Rose256 preset required by cjpeg-rose7-preset.
  # Cocotb builds use a FROST-owned tiny BMP wrapper to keep sim runtime short
  # while still exercising and CRC-checking the upstream cjpeg compressor.
  WL_DIR   := cjpeg-rose7-preset
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_BENCH := \
        $(B)/consumer_v2/cjpeg/bmark_lite.c \
        $(B)/consumer_v2/cjpeg/bm_lib.c \
        $(B)/consumer_v2/cjpeg/cdjpeg.c \
        $(B)/consumer_v2/cjpeg/cjpeg.c \
        $(B)/consumer_v2/cjpeg/filedata.c \
        $(B)/consumer_v2/cjpeg/jcapimin.c \
        $(B)/consumer_v2/cjpeg/jcapistd.c \
        $(B)/consumer_v2/cjpeg/jccoefct.c \
        $(B)/consumer_v2/cjpeg/jccolor.c \
        $(B)/consumer_v2/cjpeg/jcdctmgr.c \
        $(B)/consumer_v2/cjpeg/jchuff.c \
        $(B)/consumer_v2/cjpeg/jcinit.c \
        $(B)/consumer_v2/cjpeg/jcmainct.c \
        $(B)/consumer_v2/cjpeg/jcmarker.c \
        $(B)/consumer_v2/cjpeg/jcmaster.c \
        $(B)/consumer_v2/cjpeg/jcomapi.c \
        $(B)/consumer_v2/cjpeg/jcparam.c \
        $(B)/consumer_v2/cjpeg/jcprepct.c \
        $(B)/consumer_v2/cjpeg/jcsample.c \
        $(B)/consumer_v2/cjpeg/jdatadst.c \
        $(B)/consumer_v2/cjpeg/jerror.c \
        $(B)/consumer_v2/cjpeg/jfdctint.c \
        $(B)/consumer_v2/cjpeg/jmemansi.c \
        $(B)/consumer_v2/cjpeg/jmemmgr.c \
        $(B)/consumer_v2/cjpeg/jutils.c \
        $(B)/consumer_v2/cjpeg/rdbmp.c \
        $(B)/consumer_v2/cjpeg/data/Rose256_bmp.c
    WL_DEFINES := -DUSE_PRESET=1 -DSELECT_PRESET_ID=1
  else
    WORKLOAD_SRC := frost_cjpeg_tiny.c
    WL_BENCH := \
        $(B)/consumer_v2/cjpeg/bm_lib.c \
        $(B)/consumer_v2/cjpeg/cdjpeg.c \
        $(B)/consumer_v2/cjpeg/cjpeg.c \
        $(B)/consumer_v2/cjpeg/jcapimin.c \
        $(B)/consumer_v2/cjpeg/jcapistd.c \
        $(B)/consumer_v2/cjpeg/jccoefct.c \
        $(B)/consumer_v2/cjpeg/jccolor.c \
        $(B)/consumer_v2/cjpeg/jcdctmgr.c \
        $(B)/consumer_v2/cjpeg/jchuff.c \
        $(B)/consumer_v2/cjpeg/jcinit.c \
        $(B)/consumer_v2/cjpeg/jcmainct.c \
        $(B)/consumer_v2/cjpeg/jcmarker.c \
        $(B)/consumer_v2/cjpeg/jcmaster.c \
        $(B)/consumer_v2/cjpeg/jcomapi.c \
        $(B)/consumer_v2/cjpeg/jcparam.c \
        $(B)/consumer_v2/cjpeg/jcprepct.c \
        $(B)/consumer_v2/cjpeg/jcsample.c \
        $(B)/consumer_v2/cjpeg/jdatadst.c \
        $(B)/consumer_v2/cjpeg/jerror.c \
        $(B)/consumer_v2/cjpeg/jfdctint.c \
        $(B)/consumer_v2/cjpeg/jmemansi.c \
        $(B)/consumer_v2/cjpeg/jmemmgr.c \
        $(B)/consumer_v2/cjpeg/jutils.c \
        $(B)/consumer_v2/cjpeg/rdbmp.c
    WL_DEFINES :=
  endif
  WL_INC := -I$(CMP_DIR)/$(B)/consumer_v2/cjpeg \
            -I$(CMP_DIR)/$(B)/consumer_v2/cjpeg/data
  WL_PGO     := 0

else ifeq ($(WORKLOAD),linear_alg-mid-100x100-sp)
  # fp/linpack, single precision. pgo_training_run picks preset 5 (n=50),
  # smaller than the workload default preset 4 (n=100). SNR-verified per pass.
  WL_DIR   := linear_alg-mid-100x100-sp
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_BENCH := \
        $(F)/linpack/linpack.c \
        $(F)/linpack/ref/inputs_f32.c
  else
    # Cocotb uses an even smaller FROST-owned preset 5 (n=10, ntimes=1).
    WL_BENCH := \
        $(F)/linpack/linpack.c \
        ../frost_linpack_tiny_f32.c
  endif
  WL_INC     := -I$(CMP_DIR)/$(F)/linpack
  WL_DEFINES := -DUSE_FP32 -DSP=1
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_PGO     := 0
  else
    WL_PGO     := 1
  endif

else ifeq ($(WORKLOAD),loops-all-mid-10k-sp)
  # fp/loops, single precision. pgo_training_run picks preset 4 (32-element
  # dataset), far smaller than the workload default preset 1 (10k). All 25 loop
  # kernels still run and are SNR-verified per pass. All 8 dataset files are
  # linked (init_preset_0..7 are all called) but the 32-element set is tiny.
  WL_DIR   := loops-all-mid-10k-sp
  WL_BENCH := \
      $(F)/loops/loops.c \
      $(F)/loops/ref-sp/32.c \
      $(F)/loops/ref-sp/100.c \
      $(F)/loops/ref-sp/1k.c \
      $(F)/loops/ref-sp/10k.c \
      $(F)/loops/ref-sp/100k.c \
      $(F)/loops/ref-sp/1kdot.c \
      $(F)/loops/ref-sp/10kdot.c \
      $(F)/loops/ref-sp/100kdot.c
  WL_INC     := -I$(CMP_DIR)/$(F)/loops
  WL_DEFINES := -DUSE_FP32 -DSP=1
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_PGO     := 0
  else
    WL_PGO     := 1
  endif

else ifeq ($(WORKLOAD),nnet_test)
  # fp/nnet. Official CoreMark-PRO uses double precision with fp/nnet/ref/*.c.
  # The default simulation path uses single precision ref-sp data so cocotb
  # stays small and fast.
  WL_DIR   := nnet_test
  WL_INC     := -I$(CMP_DIR)/$(F)/nnet
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_BENCH := \
        $(F)/nnet/nnet.c \
        $(F)/nnet/ref/letters.c \
        $(F)/nnet/ref/1letter.c
    WL_DEFINES := -DUSE_FP64=1
    WL_PGO     := 0
  else
    WL_BENCH := \
        $(F)/nnet/nnet.c \
        $(F)/nnet/ref-sp/letters.c \
        $(F)/nnet/ref-sp/1letter.c
    WL_DEFINES := -DUSE_FP32=1 -DSP=1
    WL_PGO     := 1
  endif

else ifeq ($(WORKLOAD),parser-125k)
  # darkmark/parser (ezxml). pgo_training_run picks preset 2 (~414-byte XML),
  # vs the workload default preset 0 (~125k). The XML is generated on the fly,
  # so no large data tables land in ROM. CRC-verified per pass.
  WL_DIR   := parser-125k
  WL_BENCH := \
      $(B)/darkmark/parser/parser.c \
      $(B)/darkmark/parser/ezxml.c
  WL_INC     := -I$(CMP_DIR)/$(B)/darkmark/parser
  WL_DEFINES := -DEZXML_NOMMAP=1
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_PGO     := 0
  else
    WL_PGO     := 1
  endif

else ifeq ($(WORKLOAD),radix2-big-64k)
  # fp/fft_radix2 (double precision). The "-big-64k" workload normally bakes
  # the 65536-point reference (data3_big.c, ~786 KB) and runs preset 3.
  # pgo_training_run forces preset index 0, so we compile preset 0's reference
  # (2K.c, N=2048) plus fake_0.c (empty init_preset_1..9). This gives a real
  # 2048-point FFT with SNR verification against the matching 2K reference, at a
  # fraction of the ROM and cycle cost. (A genuine 64K run would need the
  # 786 KB data3_big reference -- see notes; it is omitted to stay sim-fast.)
  WL_DIR   := radix2-big-64k
  WL_INC     := -I$(CMP_DIR)/$(F)/fft_radix2
  WL_DEFINES := -DUSE_FP64
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_BENCH := \
        $(F)/fft_radix2/fft_radix2.c \
        $(F)/fft_radix2/ref/data3_big.c \
        $(F)/preset/fake_3.c
    WL_PGO     := 0
  else
    WL_BENCH := \
        $(F)/fft_radix2/fft_radix2.c \
        $(F)/fft_radix2/ref/2K.c \
        $(F)/preset/fake_0.c
    WL_PGO     := 1
  endif

else ifeq ($(WORKLOAD),sha-test)
  # darkmark/sha = SHA-256. pgo_training_run picks preset 2 (128-byte input,
  # known digest), vs the workload default preset 0 (1 MiB). The presets are
  # inline tables in shabench.c. Digest compared per pass.
  WL_DIR   := sha-test
  WL_BENCH := \
      $(B)/darkmark/sha/sha256.c \
      $(B)/darkmark/sha/shabench.c
  WL_INC     := -I$(CMP_DIR)/$(B)/darkmark/sha
  WL_DEFINES :=
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_PGO     := 0
  else
    WL_PGO     := 1
  endif

else ifeq ($(WORKLOAD),zip-test)
  # darkmark/zip = zlib 1.2.8 deflate. pgo_training_run picks preset 4
  # (1000-byte input, known compressed-buffer CRC), vs the workload default
  # preset 0 (~1 MiB). The input is generated on the fly. CRC-verified per pass.
  ZLIB := $(B)/darkmark/zip/zlib-1.2.8
  WL_DIR   := zip-test
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_BENCH := \
        $(B)/darkmark/zip/zip_darkmark.c \
        $(ZLIB)/adler32.c \
        $(ZLIB)/crc32.c \
        $(ZLIB)/deflate.c \
        $(ZLIB)/infback.c \
        $(ZLIB)/inffast.c \
        $(ZLIB)/inflate.c \
        $(ZLIB)/inftrees.c \
        $(ZLIB)/trees.c \
        $(ZLIB)/zutil.c \
        $(ZLIB)/compress.c \
        $(ZLIB)/uncompr.c \
        $(ZLIB)/gzclose.c \
        $(ZLIB)/gzlib.c
  else
    # Cocotb uses a 100-byte generated input and zlib FASTEST to avoid spending
    # CI time in the default slow deflate configuration.
    WL_BENCH := \
        ../frost_zip_darkmark_sim.c \
        $(ZLIB)/adler32.c \
        $(ZLIB)/crc32.c \
        $(ZLIB)/deflate.c \
        $(ZLIB)/infback.c \
        $(ZLIB)/inffast.c \
        $(ZLIB)/inflate.c \
        $(ZLIB)/inftrees.c \
        $(ZLIB)/trees.c \
        $(ZLIB)/zutil.c \
        $(ZLIB)/compress.c \
        $(ZLIB)/uncompr.c \
        $(ZLIB)/gzclose.c \
        $(ZLIB)/gzlib.c
  endif
  WL_INC     := -I$(CMP_DIR)/$(B)/darkmark/zip -I$(CMP_DIR)/$(ZLIB)
  WL_DEFINES := -DMITH_MEMORY_ONLY_VERSION=1 -DZLIB_COMPAT_ALL -DZLIB_ANSI
  ifeq ($(COREMARK_PRO_OFFICIAL),1)
    WL_PGO     := 0
  else
    WL_DEFINES += -DFASTEST
    WL_PGO     := 0
  endif

else
  $(error Unknown WORKLOAD '$(WORKLOAD)'. Valid: core cjpeg-rose7-preset \
    linear_alg-mid-100x100-sp loops-all-mid-10k-sp nnet_test parser-125k \
    radix2-big-64k sha-test zip-test)
endif

# --- MITH / workload configuration defines ---------------------------------
# HOST_EXAMPLE_CODE=1 : the !HOST_EXAMPLE_CODE paths in th_al.c are #error
#                       stubs, so the host path is the one to compile; we route
#                       its host functions to FROST hardware via al_frost.c.
# FAKE_FILEIO=1       : these workloads use no real files (parser/zip read from
#                       generated in-memory buffers in their pgo configs). This
#                       collapses al_file.c to trivial stubs and removes the
#                       entire stdio dependency surface. This is the upstream-
#                       sanctioned bare-metal path (util/make/fakeio.mak).
# NO_ALIGNED_ALLOC    : maps the malloc_aligned()/th_aligned_malloc() macros to
#                       plain malloc() (8-byte aligned), avoiding a
#                       posix_memalign() dependency in th_lib.c.
# USE_SINGLE_CONTEXT=1: no pthreads; single context (we skip al_smp.c).
# USE_TH_PRINTF=0     : route th_printf -> al_printf -> vprintf (our shim).
MITH_DEFINES := -DHOST_EXAMPLE_CODE=1 \
                -DFAKE_FILEIO=1 \
                -DNO_ALIGNED_ALLOC \
                -DUSE_SINGLE_CONTEXT=1 \
                -DUSE_TH_PRINTF=0 \
                -DNDEBUG \
                -DEE_SIZEOF_INT=4 -DEE_SIZEOF_LONG=4 \
                -DEE_SIZEOF_PTR=4 -DEE_PTR_ALIGN=4 \
                -DFPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ) \
                -DUART_PRINTF_ENABLE_FLOAT=1

# GCC 15 defaults to C23, where implicit declarations / int<->ptr conversions
# are hard errors. The MITH AL and several benchmark kernels use POSIX
# prototypes / K&R idioms they expect the system to supply; build them as gnu11
# and downgrade those to warnings (then silence with -w), as the upstream
# gccrv32.mak does. GCC 14+ additionally promotes -Wincompatible-pointer-types
# / -Wint-conversion to *errors* that -w does NOT downgrade, so demote them
# explicitly.
MITH_COMPAT := -std=gnu11 -w -fsigned-char \
               -Wno-implicit-function-declaration \
               -Wno-int-conversion -Wno-implicit-int \
               -Wno-error=incompatible-pointer-types \
               -Wno-error=int-conversion \
               -Wno-error=implicit-function-declaration

# Keep -ffreestanding for the bare-metal port, but still let FP benchmark code
# use hardware sqrt instructions instead of tail-calling newlib's software sqrt.
MITH_MATH_BUILTINS := -fno-math-errno \
                      -Dsqrtf=__builtin_sqrtf -Dsqrt=__builtin_sqrt

# MITH / workload include paths ONLY (no FROST lib headers here — see top).
MITH_INC := -I$(CMP_DIR)/mith/include \
            -I$(CMP_DIR)/mith/al/include \
            -I$(CMP_DIR)/workloads/$(WL_DIR) \
            $(WL_INC)

MITH_CFLAGS := $(BASE_FLAGS) $(MITH_COMPAT) $(MITH_MATH_BUILTINS) \
               $(MITH_DEFINES) $(WL_DEFINES) $(MITH_INC)

# --- FROST libc / shim compile flags (isolated, FROST headers) -------------
LIB_DIR  := ../../lib
FROST_CFLAGS := $(BASE_FLAGS) -I$(LIB_DIR)/include \
                -DFPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ) \
                -DUART_PRINTF_ENABLE_FLOAT=1 \
                -DFROST_MALLOC_DISABLE_FREE=$(FROST_MALLOC_DISABLE_FREE) \
                -DFROST_MALLOC_GUARD_FREE=$(FROST_MALLOC_GUARD_FREE) \
                -DFROST_MALLOC_EVICT_FREE=$(FROST_MALLOC_EVICT_FREE) \
                -DFROST_MEMORY_FENCE_WRITES=$(FROST_MEMORY_FENCE_WRITES)

# FROST interpose: passes the chosen pgo flag and argv string (see
# frost_mith_main.c). Hardware app aliases pass workload-specific -v0/-i args.
INTERPOSE_CFLAGS := $(MITH_CFLAGS) -DCMP_PGO_TRAINING=$(WL_PGO) \
                    '-DCOREMARK_PRO_RUN_ARGS="$(COREMARK_PRO_RUN_ARGS)"'

# --- Linker ----------------------------------------------------------------
# Unified memory map (sw/common/link_unified.ld): code/data/stack in the
# 256 KiB low BRAM, heap (and any .ddr_* sections, e.g. radix2's FFT tables)
# in the DDR-backed 1 GiB cached region at 0x8000_0000 -- identical on both
# boards and in simulation.
LINKER_SCRIPT := ../../common/link_unified.ld
# -lm covers libm symbols (cos/sin/pow/sqrt/log10) used by the FP workloads
# (linpack/loops/nnet/radix2); harmless for the integer workloads. -lgcc
# supplies soft helpers (64-bit divide in the timing math, soft float helpers).
LDFLAGS := $(BASE_FLAGS) -T $(LINKER_SCRIPT) -Wl,--gc-sections -lm -lgcc

# --- Source sets -----------------------------------------------------------
CRT0 := crt0_coremark_pro.S

# Workload wrapper (contains the per-workload main()).
WORKLOAD_SRC ?= $(CMP_DIR)/workloads/$(WL_DIR)/$(WORKLOAD).c

# Benchmark sources (kernel + dataset + libs), as absolute paths.
KERNEL_SRC := $(addprefix $(CMP_DIR)/,$(WL_BENCH))

# MITH harness sources.
MITH_SRC := \
    $(CMP_DIR)/mith/src/mith_lib.c \
    $(CMP_DIR)/mith/src/mith_workload.c \
    $(CMP_DIR)/mith/src/th_lib.c \
    $(CMP_DIR)/mith/src/th_getopt.c \
    $(CMP_DIR)/mith/src/th_rand.c \
    $(CMP_DIR)/mith/src/th_encode.c \
    $(CMP_DIR)/mith/src/th_math.c \
    $(CMP_DIR)/mith/src/th_bignum.c \
    $(CMP_DIR)/mith/src/md5.c

# MITH adaptation layer (single context: al_single + al_file, NOT al_smp).
MITH_AL_SRC := \
    $(CMP_DIR)/mith/al/src/th_al.c \
    $(CMP_DIR)/mith/al/src/al_single.c \
    $(CMP_DIR)/mith/al/src/al_file.c

# Every MITH/workload/benchmark source compiles to a flat <name>.o in this dir.
# vpath lets a single pattern rule find each source in its own subdir.
NON_WORKLOAD_MITH_SRC := $(KERNEL_SRC) $(MITH_SRC) $(MITH_AL_SRC)
ALL_MITH_SRC := $(WORKLOAD_SRC) $(NON_WORKLOAD_MITH_SRC)
MITH_OBJS    := $(WORKLOAD).o $(notdir $(NON_WORKLOAD_MITH_SRC:.c=.o))

# Search path for the pattern rule below (all directories that hold a source we
# compile with the MITH flags). sort/uniq keeps it tidy.
vpath %.c $(sort $(dir $(ALL_MITH_SRC)))

# FROST libc objects, compiled in isolation with the FROST include path.
FROST_LIB_OBJS := \
    frostlib_uart.o \
    frostlib_string.o \
    frostlib_memory.o \
    frostlib_stdlib.o \
    frostlib_ctype.o \
    frostlib_sprintf.o

# FROST shims (also compiled with the FROST include path).
SHIM_OBJS := al_frost.o

# FROST-authored MITH interpose that emits the <<PASS>>/<<FAIL>> UART marker
# and selects the minimal preset (see frost_mith_main.c). Compiled with the
# MITH headers/types, NOT the FROST lib headers.
INTERPOSE_OBJS := frost_mith_main.o

ALL_OBJS := $(CRT0) $(MITH_OBJS) $(INTERPOSE_OBJS) $(FROST_LIB_OBJS) $(SHIM_OBJS)

# --- Output files ----------------------------------------------------------
EXECUTABLE_ELF_FILE := sw.elf
VERILOG_HEX_FILE    := sw.mem
RAW_BINARY_FILE     := sw.bin
VIVADO_BRAM_FILE    := sw.txt
DDR_HEX_FILE        := sw_ddr.mem
DISASSEMBLY_FILE    := sw.S

# --- Build targets ---------------------------------------------------------
all: $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) \
     $(DDR_HEX_FILE) $(DISASSEMBLY_FILE)

# FROST libc objects: compiled with the lib's own include path in isolation so
# the MITH sources never see the FROST headers (no header shadowing).
frostlib_%.o: $(LIB_DIR)/src/%.c
	$(CC) $(FROST_CFLAGS) -c $< -o $@

# FROST shims (need csr.h / uart.h / sprintf.h from sw/lib).
al_frost.o: al_frost.c
	$(CC) $(FROST_CFLAGS) -c $< -o $@

# Generic rule for every MITH / workload / benchmark / dataset / library
# source. vpath (above) resolves each <name>.c to its source directory.
%.o: %.c
	$(CC) $(MITH_CFLAGS) -c $< -o $@

# mith_lib.c: rename the harness entry mith_main() -> mith_main_real() so the
# FROST interpose (frost_mith_main.c) can wrap it. This explicit rule overrides
# the generic pattern for just this translation unit; the workload's mith_main()
# call site is compiled normally and therefore resolves to our wrapper.
mith_lib.o: $(CMP_DIR)/mith/src/mith_lib.c
	$(CC) $(MITH_CFLAGS) -Dmith_main=mith_main_real -c $< -o $@

# The workload wrapper ($(WORKLOAD).c): rename its main() -> cmp_workload_main()
# so the FROST main() in frost_mith_main.c can select a simulation-friendly
# preset before running it. Explicit rule (overrides the generic pattern) so
# only the wrapper is renamed.
$(WORKLOAD).o: $(WORKLOAD_SRC)
	$(CC) $(MITH_CFLAGS) -Dmain=cmp_workload_main -c $< -o $@

# FROST interpose (local source; needs the MITH headers/types). Provides the
# FROST main() and the mith_main() PASS/FAIL wrapper. CMP_PGO_TRAINING selects
# whether main() enables pgo_training_run (the minimal-preset selector).
frost_mith_main.o: frost_mith_main.c
	$(CC) $(INTERPOSE_CFLAGS) -c $< -o $@

# Link everything. The libc definitions resolve from the FROST objects; the
# MITH code saw correct system-header declarations at compile time.
$(EXECUTABLE_ELF_FILE): $(ALL_OBJS) $(LINKER_SCRIPT)
	$(CC) $(BASE_FLAGS) $(CRT0) $(MITH_OBJS) $(INTERPOSE_OBJS) $(FROST_LIB_OBJS) $(SHIM_OBJS) $(LDFLAGS) -o $@

$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id \
	      -R .ddr_rodata -R .ddr_data $< $@

$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id \
	      -R .ddr_rodata -R .ddr_data $< $@

# Cached-region (DDR) image: only the .ddr_* loaded sections, rebased so file
# offset 0 = CACHED_BASE (0x8000_0000). Always exists (zero word fallback) so
# the behavioral DDR model / loader can unconditionally consume it.
$(DDR_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	-$(OBJCOPY) -O verilog --verilog-data-width 4 -j .ddr_rodata -j .ddr_data \
	      --change-addresses -0x80000000 $< $@ 2>/dev/null
	@if [ ! -s $@ ]; then echo 00000000 > $@; fi

$(VIVADO_BRAM_FILE): $(RAW_BINARY_FILE)
	xxd -e -g4 -c4 $< | awk '{printf "%08x\n", strtonum("0x" $$2)}' > $@

$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

size: $(EXECUTABLE_ELF_FILE)
	$(SIZE) $<

clean:
	$(RM) *.o $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(VIVADO_BRAM_FILE) \
	      $(DDR_HEX_FILE) $(DISASSEMBLY_FILE)

.PHONY: all size clean

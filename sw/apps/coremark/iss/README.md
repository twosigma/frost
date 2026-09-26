# CoreMark under Spike: instruction counts and PGO training

This directory builds the unmodified CoreMark sources in `../coremark/`
against a small port layer for [Spike](https://github.com/riscv-software-src/riscv-isa-sim),
the RISC-V reference simulator, and runs these tools on the result:

- `count_instructions.py` counts the instructions CoreMark's timed region
  retires, which separates "the compiler emits more instructions" from "the
  core retires them more slowly". Nothing else depends on it.
- `generate_profile.py` trains the profile-guided optimization (PGO) data
  that `../Makefile` builds with by default (`COREMARK_PGO=1`). Its output is
  committed and is a build input.

The tools run only on demand and need the pinned toolchain and Spike, so run
them inside the image. Spike counts retired instructions; it does not model FROST's
cycles, caches, branch prediction, or issue width. Measure CoreMark scores in
simulation or on hardware.

## Counting instructions

```bash
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --matrix    # the fixed flag-set matrix
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --xlen 64   # base flags only
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --xlen 64 \
    -- --param max-inline-insns-auto=200                                    # base flags plus your own
```

Counts are for RV64 with the pinned Bootlin compiler. `--xlen 32` needs an
external RV32/ILP32D toolchain selected with `RISCV_PREFIX`; the image
supplies only RV64.

### Measurement limits

The port layer replaces FROST's UART and timer. The program's only two
`cycle` CSR reads mark the start and end of the timed region, and the script
counts the instructions between them in Spike's commit log.

- `uart_printf` is a sink, so the tool never sees CoreMark's CRC check or
  error report. Seeing both markers proves only that execution crossed the
  timed region. Pair every count used in an analysis with a cocotb or board
  run that prints and validates the required CRCs.
- The matrix uses fixed flag sets, not the Makefile's current
  `APP_TUNE_FLAGS`, and every row keeps the C extension, which the shipped
  build leaves out by default.
- The port layer shifts the timed-region boundary slightly, so absolute counts
  and RV32/RV64 ratios are estimates.

## Profile-guided optimization training

CoreMark's run rules allow PGO when the profile comes from the official
profile data set: `TOTAL_DATA_SIZE` 1200 with seeds 8/8/8, which
`../core_portme.h` selects as `PROFILE_RUN`. `generate_profile.py` builds
exactly that configuration:

```bash
./scripts/frost.py run sw/apps/coremark/iss/generate_profile.py
```

The script compiles the benchmark with `-fprofile-arcs`, runs it under Spike,
streams the counters out through Spike's host interface, converts the stream
with `riscv64-linux-gcov-tool merge-stream`, and installs the
`sw.elf-<source>.gcda` files next to `../Makefile`. Edge counts are
architectural, so Spike's match the RTL's, except for `core_main.c`'s checks
of elapsed time: the Spike port always reports one second, while FROST's
measures it. Spike also avoids the tens of millions of simulated cycles the
FROST UART would need to print the profile.

The measured build reads only edge counts (`-fbranch-probabilities`), so
training skips value profiling, which would pull in libgcov's Linux TLS
runtime. The dumper, `pgo_dump.c`, replaces libgcov's unused merge and `mmap`
hooks with stubs that abort visibly, so the image never links libgcov's
filesystem runtime, and the script rejects a training ELF that contains TLS,
dynamic loading, or Linux syscalls.

Regenerate the committed profiles whenever the compiler or the training flags
change. Arguments after `--` replace the script's default tuning flags, the
Makefile's `COREMARK_BASE_TUNE` and `COREMARK_CPU_TUNE` (`-mtune=sifive-7-series`).
The PGO build, which is the published configuration
([single-core performance](../../../../docs/single_core_performance.md)),
uses `COREMARK_PGO_CPU_TUNE` (`-mtune=generic-ooo`), but with the pinned GCC
the tuning model does not change the profile: training with either gives the
same counts and the same benchmark image.

These details of the training build are easy to get wrong:

- Compile the benchmark sources from the app directory with the same relative
  paths `../Makefile` uses. GCC folds the source path into each function's
  line-number checksum, so an absolute path makes every record mismatch under
  `-fbranch-probabilities`.
- GCC names each gcda file after the link output, so the training link writes
  `sw.elf` and the installed files are `sw.elf-<source>.gcda`.

Only the five benchmark translation units get a profile. `uart.c`,
`core_portme.c`, and `tomasulo_profile_cache.c` sit outside the timed region
and compile without one, so `../Makefile` passes `-Wno-missing-profile` and
checks for the five expected files itself.

Regeneration is reproducible in content but not byte for byte: GCC writes a
fresh per-build stamp into every gcda. Before concluding that a regenerated
profile changed, compare with the stamp removed:

```bash
riscv64-linux-gcov-dump -l sw.elf-core_state.gcda | sed '/stamp/d'
```

To check that a new profile leaves the benchmark unchanged, rebuild the
published configuration and compare its `sw.bin`. Do not compare `sw.elf`: its
hash differs even between identical builds, because its symbol table names a
temporary `ccXXXXXX.o` object file.

# CoreMark under Spike: instruction counts and PGO training

Two Spike-hosted tools over the unmodified CoreMark sources in `../coremark/`.
`count_instructions.py` reports how many instructions the timed region retires
at **either XLEN**, and is not part of any build, test or board flow.
`generate_profile.py` produces the profile data `../Makefile` reads when
`COREMARK_PGO=1`, so its output *is* a build input; the harness itself still
runs only on demand.

## Why it exists

Compare compiler options and the RV32/ILP32D and RV64/LP64D ABIs by retired
instruction count. FROST itself is RV64-only. Spike does not model cycles or
IPC; use simulation or hardware to measure a CoreMark score.

## Usage

Needs the pinned toolchain and Spike, so run it inside the image:

```bash
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --matrix
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --xlen 64
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --xlen 32 \
    -- --param max-inline-insns-auto=200
```

`--matrix` reproduces the ablation quoted in `../Makefile`:

```
flags                                   rv32/ilp32d   rv64/lp64d    lp64
stock                                       254,726      284,492   11.7%
inline                                      227,779      257,229   12.9%
inline_sa                                   221,613      251,220   13.4%
full                                        221,578      251,089   13.3%
```

## Profile-guided optimization training

`generate_profile.py` produces the `sw.elf-<source>.gcda` files that
`../Makefile` consumes when `COREMARK_PGO=1`. CoreMark's run rules allow
profile-guided optimization when the profile comes from the official profile
data set -- `TOTAL_DATA_SIZE` 1200 with seeds 8/8/8, which `../core_portme.h`
selects as `PROFILE_RUN` -- and that is what the script builds.

```bash
./scripts/frost.py run sw/apps/coremark/iss/generate_profile.py
```

The script runs an instrumented benchmark under Spike and converts its
profile stream to gcda files using `riscv-none-elf-gcov-tool merge-stream`.

When changing the training build:

* The benchmark sources must be compiled from the app directory with the same
  relative path spellings `../Makefile` uses. GCC folds the source path into
  each function's line-number checksum, so an absolute path makes every record
  mismatch at `-fprofile-use`.
* GCC derives the gcda name from the link output, which is why the training
  link writes to `sw.elf` and the installed files are `sw.elf-<source>.gcda`.

Only the five benchmark translation units get a profile. `uart.c`,
`core_portme.c` and `tomasulo_profile_cache.c` are not part of the timed region
and compile without one, which is why `../Makefile` passes
`-Wno-missing-profile` and checks the five expected files itself.

Regeneration is reproducible in content but not byte for byte: GCC writes a
fresh per-build stamp into every gcda. Before believing a regenerated profile
has changed, compare with the stamp removed:

```bash
riscv-none-elf-gcov-dump -l sw.elf-core_state.gcda | sed '/stamp/d'
```

## How it works, and what it is not

The counting harness replaces MMIO and timer access with a Spike port. It
uses two `cycle` CSR reads as markers around the timed region and counts the
instructions between them in Spike's commit trace.

The UART implementation is a sink, so this tool cannot observe CoreMark's CRC
or error report. Seeing both markers proves only that execution crossed the
timed region. Pair every count used in an analysis with a cocotb or board run
that prints and validates the required CRCs.

**Calibration.** The matrix's `full` row is the tuning set recorded in
`../Makefile`, not the app's current `APP_TUNE_FLAGS`. Every matrix row keeps
C enabled; the shipped app disables it for front-end timing. Port
instrumentation also affects the timed-region boundary, so absolute counts
and ABI ratios are estimates.

Spike does not model fetch, branch prediction, caches, or two-wide issue.
Fewer instructions do not necessarily mean a faster FROST run.

# CoreMark under Spike: instruction counts and PGO training

Two Spike-hosted tools over the unmodified CoreMark sources in `../coremark/`.
`count_instructions.py` reports how many instructions the timed region retires
at RV64 with the pinned Bootlin compiler, and is not part of any build, test or board flow.
`generate_profile.py` produces the profile data `../Makefile` reads when
`COREMARK_PGO=1`, so its output *is* a build input; the harness itself still
runs only on demand.

Spike counts retired instructions; it does not model FROST cycles, caches,
branch prediction, or issue width. Measure CoreMark scores in simulation or
on hardware.

## Usage

Needs the pinned toolchain and Spike, so run it inside the image:

```bash
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --matrix
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --xlen 64
./scripts/frost.py run sw/apps/coremark/iss/count_instructions.py --xlen 64 \
    -- --param max-inline-insns-auto=200
```

`--matrix` compares fixed flag sets at RV64. `--xlen 32` requires an external
RV32/ILP32D toolchain via `RISCV_PREFIX`; the image supplies only RV64.

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
profile stream to gcda files using `riscv64-linux-gcov-tool merge-stream`.
Training uses `-fprofile-arcs`: the measured build reads edge counts with
`-fbranch-probabilities`, so Linux TLS-based value profiling is unnecessary.
The streaming dumper supplies fail-fast stubs for unused merge/mapping hooks
instead of linking libgcov's filesystem runtime. The generator rejects a
training ELF containing TLS, dynamic loading or Linux syscalls. Regenerate the
committed profiles whenever the compiler or training flags change; PGO is opt-in.

When changing the training build:

* The benchmark sources must be compiled from the app directory with the same
  relative path spellings `../Makefile` uses. GCC folds the source path into
  each function's line-number checksum, so an absolute path makes every record
  mismatch at `-fbranch-probabilities`.
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
riscv64-linux-gcov-dump -l sw.elf-core_state.gcda | sed '/stamp/d'
```

## Measurement limits

The counting harness replaces MMIO and timer access with a Spike port. It
uses two `cycle` CSR reads as markers around the timed region and counts the
instructions between them in Spike's commit trace.

The UART implementation is a sink, so this tool cannot observe CoreMark's CRC
or error report. Seeing both markers proves only that execution crossed the
timed region. Pair every count used in an analysis with a cocotb or board run
that prints and validates the required CRCs.

The matrix uses fixed flag sets, not the app's current `APP_TUNE_FLAGS`. Every matrix row keeps
C enabled; the shipped app disables it for front-end timing. Port
instrumentation also affects the timed-region boundary, so absolute counts
and ABI ratios are estimates.

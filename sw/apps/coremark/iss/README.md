# CoreMark under Spike: instruction counts and PGO training

Two Spike-hosted tools over the unmodified CoreMark sources in `../coremark/`.
`count_instructions.py` reports how many instructions the timed region retires
at **either XLEN**, and is not part of any build, test or board flow.
`generate_profile.py` produces the profile data `../Makefile` reads when
`COREMARK_PGO=1`, so its output *is* a build input; the harness itself still
runs only on demand.

## Why it exists

The core is RV64-only — the rv32 lane was retired in `c0be5bc` — so a question
like "how much of CoreMark's lp64 cost is the ABI, and how much is codegen we
left on the table?" cannot be answered on the RTL any more. Instruction counts,
unlike cycles, depend only on the toolchain, so they *can* still be measured
across both ABIs. That is all this harness does.

It answers the "how many instructions" half. The "how fast does the machine
retire them" half still needs `./scripts/frost.py cocotb coremark`, which is
the only thing that produces a CoreMark score.

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

It compiles the five benchmark translation units plus this directory's port
layer with `-fprofile-generate -fprofile-info-section`, runs the result under
Spike, and streams the gcda out over HTIF. `pgo_dump.c` walks the `.gcov_info`
table that `link_spike_pgo.ld` bounds and hands each entry to libgcov's
`__gcov_info_to_gcda()`; `riscv-none-elf-gcov-tool merge-stream` turns the
stream back into files.

Spike rather than the RTL because execution counts are architectural, so both
agree on them, while printing the ~5 KB stream over the modelled UART would
cost tens of millions of simulated cycles.

Two build details are easy to get wrong and both are fatal rather than subtle:

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

`core_portme.c` here replaces the app's port layer: no MMIO, no timer.
`start_time()` and `stop_time()` each execute one `csrr x0, cycle`, and nothing
else in the program reads that CSR, so `count_instructions.py` slices Spike's
`--log-commits` trace to exactly the timed region. `uart.h` is a shim that lets
the app's own `../core_portme.h` compile unchanged (the real MMIO header is
never on the include path), and `stub.c` supplies the few libc entry points GCC
can synthesize calls to. `crt0_spike.S` enables `mstatus.FS` — Spike resets it
to Off, and CoreMark's prologue stores an FP register.

The UART implementation is a sink, so this tool cannot observe CoreMark's CRC
or error report. Seeing both markers proves only that execution crossed the
timed region. Pair every count used in an analysis with a cocotb or board run
that prints and validates the required CRCs.

**Calibration.** `full` is the 2026-08-27 tuning set, which is what the
`../Makefile` ablation quotes; `APP_TUNE_FLAGS` has since gained scheduling and
block-layout options that do not change the ABI ratio this matrix measures. The
matrix keeps C enabled in every row and ABI lane so its only changes are the
compiler options named in the first column. The shipped
app additionally drops C for cycle-level front-end reasons; on the tuning
branch's base RTL that changed timed `instret` by only 6 instructions. With the
remaining full tuning flags, this harness lands within about 0.5% of the cocotb
profiled-region `instret` at both XLENs, and the offset has the same sign and
similar magnitude in both lanes (the difference is port instrumentation around
the timer boundary). Absolute counts and ratios remain estimates, but the
matched ratios are more informative than the absolute counts.

**It cannot tell you about IPC, cycles, or a score.** Spike is functional only.
Fetch-window behaviour, branch prediction, cache effects and the 2-wide bundler
— which is where most of FROST's CoreMark headroom turned out to be — are
invisible here.

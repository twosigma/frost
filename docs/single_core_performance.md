# Single-core performance

The CPU/SoC separation has been measured on X3 at 161.132812 MHz with the
standard benchmark builds. Compared with the earlier platform at the same
clock, both benchmark scores meet the original 1% regression tolerance:

| Benchmark | Earlier platform | AXI CPU boundary | Score change |
| --- | ---: | ---: | ---: |
| CoreMark | 687.441404 | 681.431231 | -0.87% |
| CoreMark-PRO, all nine workloads | 46.09 | 45.636421 | -0.984% |

The full X3 hardware regression passes all 48 stages, including Debian,
networking, and DDR ECC. Both official CoreMark seed sets pass their CRC checks
with 14,000 iterations: the performance run takes 20.544993 seconds and the
validation run takes 20.982811 seconds.
Workloads, compiler flags, memory placement, and baseline thresholds are
unchanged. The complete CoreMark-PRO sweep passes every workload's verification
and reports 45.64 after rounding; the acceptance comparison uses the unrounded
aggregate, above the 45.6291 floor.

These results come from a complete repeat on the same bitstream after the
first run passed 47 of 48 stages. That run's Debian check found a degraded
system: a 60-second login timeout expired while APT startup competed with
the user service. The repeat passes with the same Linux configuration and
checks; no timeout or health check was relaxed.

The aggregate does not imply that every workload has the same performance.
SHA takes 29.251 seconds versus 22.662 before the refactor, about 29.1% longer;
other workloads improve, including ZIP. The individual timed sections are:

| CoreMark-PRO workload | Earlier seconds | Current seconds | Runtime change |
| --- | ---: | ---: | ---: |
| core | 43.001 | 41.672 | -3.09% |
| cjpeg | 18.297 | 18.333 | +0.20% |
| linear_alg | 70.034 | 68.874 | -1.66% |
| loops | 70.277 | 69.964 | -0.45% |
| nnet | 128.811 | 128.456 | -0.28% |
| parser | 17.350 | 17.542 | +1.11% |
| radix2 | 76.475 | 76.233 | -0.32% |
| sha | 22.662 | 29.251 | +29.08% |
| zip | 19.517 | 17.305 | -11.33% |

FROST enables the CPU's optional Normal read caches: an 8 KiB direct
instruction cache and dword data fills into a 256-entry (2 KiB) L0.
Stores remain narrow write-through accesses, with byte updates to L0 and
queue ownership retained until the AXI write response. The debug data page
and all Device accesses bypass these caches. There are no dirty BRAM cache
lines. The standalone CPU defaults to strict uncached Normal memory; see the
[interface contract](../hw/rtl/cpu_top/README.md#optional-normal-read-caching-and-write-through-stores).

The final 161 MHz implementation passes setup (+0.077 ns), hold (+0.012 ns),
pulse-width, and all 74 bus-skew checks, with no DRC errors. The same RTL
passes post-opt setup at 322.265625 MHz (+0.034 ns, zero failing endpoints),
using the normal build settings and constraints. Full 322 MHz placement,
routing, and hardware validation remain pending. The earlier full-rate
platform measured 1,375 CoreMark, or 4.27 CoreMark/MHz; that is a historical
baseline, not a measured full-rate result for this boundary.

The initial performance diagnosis used identical CoreMark images on the
earlier platform and the fully uncached AXI prototype, with the pinned
container and DDR timing seed `cpu-top-performance-ddr`:

| Code/data placement | Stack placement | Earlier timed cycles | Uncached prototype timed cycles |
| --- | --- | ---: | ---: |
| Cached DDR | Uncached BRAM, as in `link_ddr.ld` | 304,836 | 830,701 |
| Cached DDR | Cached DDR at `0x81000000`, diagnostic only | 351,745 | 352,072 |

All CRCs pass. This comparison isolated the uncached-access cost and motivated
the Normal read caches; it did not change the platform linker or replace the
BRAM hardware baseline. The rest of this page describes the CPU defaults,
benchmark configuration, and measurement procedure.

## CPU configuration

FPGA builds, whole-core simulation, and Yosys synthesis share these CPU
defaults:

| Setting | Value |
| --- | --- |
| Decoded queue | Four two-instruction bundles, bypassed when empty |
| INT reservation station | 16 entries; the second issue port scans the lowest eight |
| Early load wakeup | A load's result wakes dependent memory operations a cycle early, through an idle result-bus lane |
| Load preparation while the memory port is busy | The next load's address is staged; an unrelated L0 hit can complete while an older Normal read or buffered store waits for its response, after store disambiguation |
| Load-queue L0 cache | 256 entries with Normal read caching; 128 otherwise |
| Normal instruction cache | 256 direct-mapped 32-byte lines (8 KiB), enabled by the FROST wrapper |
| Normal data policy | L0 read caching and narrow write-through stores, excluding the debug data page |
| Word multiply / divide latency | 3 / 33 cycles |
| Full-width multiply / divide latency | 6 / 65 cycles |

The decoded queue absorbs front-end stalls. Early wakeup shortens chains of
dependent loads, and busy-port preparation overlaps a load's address staging
with the previous memory transaction. Limiting the second INT issue port to
eight entries keeps its selection logic shallow without reducing the
station's capacity.

## Benchmark configuration

CoreMark runs from BRAM with its workspace on the stack, without compressed
instructions, and with the profiling counters left out of the bitstream. The
compiler is Bootlin GCC 15.3.0 (2026.08-1) with the RV64 hard-float ABI and
profile-guided optimization (PGO) trained on the official profile data set.
The tuning flags are:

```text
--param max-inline-insns-auto=200 -fira-algorithm=CB -fstrict-aliasing -fselective-scheduling -fbranch-probabilities -fprofile-correction -Wno-missing-profile -mtune=generic-ooo
```

These are the CoreMark Makefile's defaults. `COREMARK_PGO=0` builds without
the profiles instead, with `-mtune=sifive-7-series` and static-layout and LTO
flags.

PGO training uses the official profile data set (1,200 bytes, seeds 8/8/8).
Generate the profiles in the pinned image:

```bash
./scripts/frost.py run sw/apps/coremark/iss/generate_profile.py
```

The script trains with the Makefile's `COREMARK_BASE_TUNE` and
`COREMARK_CPU_TUNE` (`-mtune=sifive-7-series`). The tuning model does not
change the profile: with the pinned GCC, training with `-mtune=generic-ooo`
gives the same counts and the same benchmark image.

| Build variable | Purpose |
| --- | --- |
| `COREMARK_PGO=0` | Build without the branch profiles (the default, `1`, uses them and the tuning flags above) |
| `APP_TUNE_FLAGS` | Replace the default tuning flags |
| `COREMARK_SEED_SET=performance` or `validation` | Select the official seed set |
| `COREMARK_COMPRESSED=0` or `1` | Disable or enable compressed instructions |
| `COREMARK_SOURCE_ORDER` | Reorder the benchmark's translation units |
| `ITERATIONS` | Timed iterations (default 14,000) |

A reportable score comes from a run of at least ten seconds with both seed
sets, and every seed, list, matrix, and state CRC must pass. At
322.265625 MHz, the historical baseline took a little over ten seconds for
14,000 iterations. Check the actual elapsed time after an RTL or clock
change. The loader sets the software timebase to the board clock.

CoreMark/MHz is the score divided by the clock in MHz. For a cycle-counted run
it is `1,000,000 × iterations / timed_cycles`. Compiler flags, PGO,
compressed instructions, and memory placement all affect the score, so report
them with it.

## Reproducing and retaining measurements

The sweep script runs cycle-exact CoreMark simulations in the pinned Docker
image and archives everything needed to reproduce each result: source
fingerprints, commands, compiler flags, PGO inputs, ELF and load images,
disassembly, hashes, cycle counts, and CRC results. Run it from the main
checkout with the output directory outside it. It cleans before each
simulation and stops if the sources change during the run. Compare builds by
the hashes of `sw.bin` or `sw.S`: `sw.elf` differs even between identical
builds, because its symbol table names a temporary `ccXXXXXX.o` object file.

```bash
# PGO cycle counts with the CPU defaults and the published tuning
python3 scripts/coremark_sweep.py --output /absolute/new/coremark-results --orders 1 --compressed 0 --memory bram --seeds performance validation --runs 1 --pgo 1

# Compressed code and link order in both memory tiers, without PGO
python3 scripts/coremark_sweep.py --output /absolute/new/layout-results --orders 4 --compressed 0 1 --memory bram ddr --seeds performance validation --runs 2 --pgo 0
```

BRAM runs honor `--runs`; DDR runs once per invocation. The direction
predictors and the memories keep their state across reset (the BTB and return
stack do not), so compare runs with the same reset index. These are one-iteration simulations with a synthetic timer, useful for
comparing cycle counts; only the ten-second hardware runs above produce a
score.

On hardware, with the [regression environment](../fpga/README.md#hardware-regression)
set up, build and test natively:

```bash
./fpga/build/build.py x3
./fpga/program_bitstream/program_bitstream.py x3
./fpga/hw_regression.py --board x3
COREMARK_SEED_SET=validation ./fpga/hw_regression.py --board x3 coremark
```

The full hardware regression uses CoreMark's performance seed set. The
additional stage checks the official validation seed set; two CPU-reset
runs of one simulation image do not replace this check. Keep both runs at
the same board clock and confirm each lasts at least ten seconds. When
reporting a score, keep the benchmark ELF, load images, and flags with the result, along
with the source revision, tool versions, bitstream, UART output, and final
timing reports.

With `FROST_CPU_CLK_HZ` set for a divided-clock build, the runner checks
functional results but skips the standard-clock performance threshold.
Compare measured scores at the same frequency, or compare cycles per
iteration; a functional PASS alone does not establish performance parity.

## Comparing changes

For an RTL change:

- Use identical binaries and matching reset indices.
- Run both CoreMark seed sets, compressed-code and link-order variations, and
  all nine CoreMark-PRO workloads in BRAM and DDR.
- In a link-order sweep, count distinct `sw.bin` images: different source
  orders can produce identical code.
- Use the performance counters to explain cycle changes, then measure the
  benchmark with counters disabled.
- Check routed timing and run the full hardware regression, including Debian.

The next goal is 5 CoreMark/MHz at the same clock, or 200,000 cycles per
CoreMark iteration; see the [roadmap](../ROADMAP.md).

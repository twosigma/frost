# Single-core performance

FROST runs CoreMark at 3.91 CoreMark/MHz on the X3, measured on the board at
161.1328125 MHz. The score at the full 322.265625 MHz clock, 1,259 CoreMark,
is that rate times the clock in MHz, not a separate measurement. The measured
build's second INT issue port scanned all 16 reservation-station entries. The
current default scans the lowest eight, which in simulation takes about 0.5%
more cycles per CoreMark iteration.
This page describes the current CPU defaults and the benchmark configuration,
how to measure the score, and how to compare changes.

## CPU configuration

FPGA builds, whole-core simulation, and Yosys synthesis share these CPU
defaults:

| Setting | Value |
| --- | --- |
| Decoded queue | Four two-instruction bundles, bypassed when empty |
| INT reservation station | 16 entries; the second issue port scans the lowest eight |
| Early load wakeup | A load's result wakes dependent memory operations a cycle early, through an idle result-bus lane |
| Load preparation while the memory port is busy | The next load's address is staged; its store-queue check, use of an L0 hit, and memory request wait for the port |
| Load-queue L0 cache | 128 entries |
| Word multiply / divide latency | 3 / 17 cycles |
| Full-width multiply / divide latency | 6 / 33 cycles |

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

These are the CoreMark Makefile's defaults for `COREMARK_PGO=1`. Its defaults
without PGO use `-mtune=sifive-7-series` and add static-layout and LTO flags.

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
| `COREMARK_PGO=1` | Use the generated branch profiles and the tuning flags above |
| `APP_TUNE_FLAGS` | Replace the default tuning flags |
| `COREMARK_SEED_SET=performance` or `validation` | Select the official seed set |
| `COREMARK_COMPRESSED=0` or `1` | Disable or enable compressed instructions |
| `COREMARK_SOURCE_ORDER` | Reorder the benchmark's translation units |
| `ITERATIONS` | Timed iterations (default 14,000) |

A reportable score comes from a run of at least ten seconds with both seed
sets, and every seed, list, matrix, and state CRC must pass. At
322.265625 MHz, 14,000 iterations take a little over ten seconds; check the
reported elapsed time. The loader sets the software timebase to the board
clock.

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
python3 scripts/coremark_sweep.py --output /absolute/new/layout-results --orders 4 --compressed 0 1 --memory bram ddr --seeds performance validation --runs 2
```

BRAM runs honor `--runs`; DDR runs once per invocation. Predictors and
memories keep their state across reset, so compare runs with the same reset
index. These are one-iteration simulations with a synthetic timer, useful for
comparing cycle counts; only the ten-second hardware runs above produce a
score.

On hardware, with the [regression environment](../fpga/README.md#hardware-regression)
set up, build and test natively:

```bash
./fpga/build/build.py x3 --no-perf-counters
./fpga/program_bitstream/program_bitstream.py x3
./fpga/hw_regression.py --board x3
```

The hardware regression uses the standard application builds, not the tuned
PGO build. When reporting a tuned score, keep the benchmark ELF, load images,
and flags with the result, along with the source revision, tool versions,
bitstream, UART output, and final timing reports.

## Comparing changes

RTL changes are also compared with FROST's earlier RV32 configuration at
revision `501f777b920f056471a6c65245ea007576c294ca`. Both architectures use
xPack GCC 15.2.0-1 with matched tuning: hard-float D ABI, BRAM, counters on,
and compressed instructions and PGO off.

- Compare identical binaries and matching reset indices when changing RTL.
- Run both CoreMark seed sets, compressed-code and link-order variations, and
  all nine CoreMark-PRO workloads in BRAM and DDR.
- In a link-order sweep, count distinct `sw.bin` images: different source
  orders can produce identical code.
- Use the performance counters to explain cycle changes, then measure the
  benchmark with counters disabled.
- After RTL changes, check routed timing and run the full hardware regression,
  including Debian.

The next goal is 4 CoreMark/MHz at the same clock, or 250,000 cycles per
CoreMark iteration; see the [roadmap](../ROADMAP.md).

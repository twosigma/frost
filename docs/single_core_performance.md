# Single-core performance

FROST runs at **322.265625 MHz** on X3 and delivers **3.91 CoreMark/MHz** with
profile-guided optimization (PGO).

## CPU configuration

FPGA builds, whole-core simulation and Yosys share these CPU defaults:

| Setting | Value |
| --- | --- |
| Decoded queue | Four two-instruction bundles, with empty-queue bypass |
| INT reservation station | 16 entries; second issue port scans the lowest eight |
| Early load wakeup | Staged non-faulting loads use an idle CDB lane at MEM_RS |
| Load preparation during port ownership | Address staging; SQ probes, L0 consumption and memory requests wait for the port |
| LQ L0 cache | 128 entries |
| Word multiply / divide latency | 3 / 17 cycles |
| Full-width multiply / divide latency | 6 / 33 cycles |

The decoded queue absorbs frontend stalls. Early wakeup shortens dependent
load chains, and busy-port preparation overlaps address staging with the
previous memory transaction. The eight-entry second-issue window bounds
selector and operand-mux depth independently of the sixteen-entry capacity.

## Benchmark configuration

CoreMark uses BRAM code/data, stack workspace, uncompressed instructions and
profiling counters disabled. The compiler is Bootlin GCC 15.3.0 (2026.08-1),
with the RV64 hard-float ABI, official-dataset PGO and these tuning flags:

```text
--param max-inline-insns-auto=200 -fira-algorithm=CB -fstrict-aliasing -fselective-scheduling -fbranch-probabilities -fprofile-correction -Wno-missing-profile -mtune=generic-ooo
```

The PGO training dataset uses 1,200 bytes and seeds 8/8/8. Generate profiles
through the pinned image:

```bash
./scripts/frost.py run sw/apps/coremark/iss/generate_profile.py
```

| Build variable | Purpose |
| --- | --- |
| `COREMARK_PGO=1` | Use the generated branch profiles |
| `APP_TUNE_FLAGS` | Select the tuning flags above |
| `COREMARK_SEED_SET=performance` or `validation` | Select the official seed set |
| `COREMARK_COMPRESSED=0` or `1` | Disable or enable compressed instructions |
| `COREMARK_SOURCE_ORDER` | Reorder the five complete benchmark translation units |
| `ITERATIONS` | Set the timed run length |

Run both seed sets for at least ten seconds and check all seed/list/matrix/state
CRCs. At 322.265625 MHz, use at least **14,000 iterations** and verify elapsed
time. Set `FROST_CPU_CLK_HZ=322265625` when loading the image so its timebase
matches the hardware.

CoreMark/MHz is the score divided by the CPU clock in MHz. For a cycle-counted
run, it is `1,000,000 × iterations / timed_cycles`. Compiler flags, PGO,
compressed instructions and memory placement affect the result and belong
with each reported score.

## Reproducing and retaining measurements

Run from the main checkout with output outside it. The sweep uses the pinned
Docker image, cleans before each simulation and rejects source changes during
the run.

```bash
# PGO cycle comparison with the CPU defaults and benchmark tuning.
python3 scripts/coremark_sweep.py --output /absolute/new/coremark-results --orders 1 --compressed 0 --memory bram --seeds performance validation --runs 1 --pgo 1 --tune-flags='--param max-inline-insns-auto=200 -fira-algorithm=CB -fstrict-aliasing -fselective-scheduling -fbranch-probabilities -fprofile-correction -Wno-missing-profile -mtune=generic-ooo'

# Compressed-code and link-order comparison in both memory tiers, without PGO.
python3 scripts/coremark_sweep.py --output /absolute/new/layout-results --orders 4 --compressed 0 1 --memory bram ddr --seeds performance validation --runs 2
```

The sweep saves source fingerprints, commands, compiler flags, PGO inputs,
ELF/loadable binaries, disassembly, hashes, cycle counts and CRC results.
BRAM honors `--runs`; DDR runs once per invocation. Compare matching reset/run
indices because predictors and memories retain state across reset. These
one-iteration simulations use a synthetic timer; hardware scores require the
ten-second runs above.

With the [regression environment](../fpga/README.md#hardware-regression)
configured, build and exercise the FPGA natively:

```bash
./fpga/build/build.py x3 --cpu-base-clock-hz 322265625 --no-perf-counters
./fpga/program_bitstream/program_bitstream.py x3
FROST_CPU_CLK_HZ=322265625 ./fpga/hw_regression.py --board x3
```

The hardware regression uses its standard software builds. For a tuned PGO
measurement, retain the separately built benchmark ELF, load images and flags.
Archive the source revision, tool versions, bitstream hash, programming record,
UART output, and final setup/hold/pulse-width/bus-skew reports with the result.

## Comparing changes

The locked RV32 reference is revision
`501f777b920f056471a6c65245ea007576c294ca`, with matched software tuning and
xPack GCC 15.2.0-1 on both architectures: hard-float D ABI, BRAM, counters on,
C and PGO off.

- Compare identical binaries and matched reset indices when changing RTL.
- Run both CoreMark seed sets, compressed-code/link-order ensembles and all
  nine CoreMark-PRO workloads in BRAM and DDR.
- Count distinct loadable binaries in a layout ensemble: different source
  orders can produce identical code.
- Use performance counters to explain cycle changes, then measure the
  benchmark with counters disabled.
- Check routed timing, full hardware regression and Debian after RTL changes.

The next throughput goal is **4 CoreMark/MHz** at the same clock, equivalent
to 250,000 cycles per CoreMark iteration.

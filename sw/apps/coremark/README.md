# CoreMark

[EEMBC CoreMark](https://github.com/eembc/coremark), unmodified in `coremark/`,
with FROST's port layer in `core_portme.c` and `core_portme.h`.

## Build

CoreMark runs from BRAM with its workspace on the stack, without compressed
instructions, and with the profiling counters left out of the bitstream. The
compiler is Bootlin's GCC 16.2.0 (2026.08-1 bleeding-edge bundle), pinned in
the Docker image, at `-O3` with the RV64 hard-float ABI. The default build
uses branch profiles trained on the official profile data set (1,200 bytes,
seeds 8/8/8) and these tuning flags:

```text
--param max-inline-insns-auto=200 -fira-algorithm=CB -fstrict-aliasing -fselective-scheduling -fbranch-probabilities -fprofile-correction -Wno-missing-profile -mtune=generic-ooo
```

The architecture flags include Zbc and Zbkc for carry-less multiplication.
CoreMark's report prints the complete compiler flags. [iss/README.md](iss/README.md)
covers training the profiles.

| Build variable | Purpose |
| --- | --- |
| `COREMARK_PGO=0` | Build without the branch profiles, with `-mtune=sifive-7-series` and static-layout and LTO flags instead (default `1`) |
| `APP_TUNE_FLAGS` | Replace the tuning flags |
| `COREMARK_SEED_SET` | `performance` (default) or `validation`, the two official seed sets |
| `COREMARK_COMPRESSED=1` | Build with compressed instructions |
| `COREMARK_SOURCE_ORDER` | Reorder the benchmark's translation units |
| `ITERATIONS` | Timed iterations (default 14,000) |

## Measuring

A score comes from a run of at least ten seconds that passes every seed, list,
matrix and state CRC, with both seed sets. At 322 MHz the default 14,000
iterations take a little over ten seconds. CoreMark/MHz is the score divided by
the clock in MHz.

On the X3, with the [hardware regression environment](../../../fpga/README.md#hardware-regression)
set up:

```bash
./fpga/hw_regression.py --board x3 coremark
COREMARK_SEED_SET=validation ./fpga/hw_regression.py --board x3 coremark
```

`scripts/coremark_sweep.py` runs and archives cycle-exact simulations across
seed sets, link orders, compressed code and memory tiers. They use one
iteration and a synthetic timer, so they compare cycle counts and do not
produce a score.

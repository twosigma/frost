# FROST FPGA Build and Deployment

This directory contains the Xilinx FPGA build, programming, and software-loading tools.

## Overview

| Directory            | Purpose                                    |
|----------------------|--------------------------------------------|
| `build/`             | Synthesize and generate bitstream          |
| `program_bitstream/` | Program FPGA with bitstream via JTAG       |
| `load_software/`     | Load software images into low BRAM and optional DDR without reprogramming |
| `debug/`             | OpenOCD configurations for the RISC-V debug module (simulation, Genesys 2, X3) |

The two common flows are:

```text
RTL → build/build.py → bitstream → program_bitstream/program_bitstream.py → FPGA
app source → make → sw.txt (+ sw_ddr.txt) → load_software/load_software.py → FPGA
```

Loader data path: JTAG-AXI → AXI-to-BRAM → low BRAM → CPU. DDR images
use the board's separate burst-capable JTAG-AXI master.

Debugging (Phase 3 M3): the RISC-V debug module hangs off the FPGA TAP
through two BSCAN USER chains (see `boards/README.md`); `debug/` holds the
OpenOCD configurations. Close hw_server first (one cable owner), then

```bash
openocd -f fpga/debug/openocd_genesys2.cfg   # or openocd_x3.cfg
riscv-none-elf-gdb sw/apps/hello_world/sw.elf -ex 'target extended-remote :3333'
```

`openocd_sim.cfg` is the same target over `remote_bitbang` against the
cocotb bench (`debug_openocd_test`). Software breakpoints work in BRAM and
DDR code alike; there are no hardware triggers, and memory is reached
through the program buffer (no system bus), so `load` of a whole image is
slow — use the JTAG loader for images and the debugger for debugging.

`hw_regression.py` loads and UART-checks every bare-metal app, runs all nine
CoreMark-PRO workloads with per-board score gates, then boots Linux to the
Buildroot login prompt:

```bash
./fpga/hw_regression.py --board x3
```

## Prerequisites

- **Vivado** (see [main README](../README.md#prerequisites) for validated versions)
- Python 3
- JTAG cable connected to target board
- For remote programming: Vivado Hardware Server running on remote host

## Supported Boards

| Board    | FPGA                       | FROST Clock | Status         |
|----------|----------------------------|-------------|----------------|
| X3       | Alveo UltraScale+ (xcux35) | 300 MHz     | Primary target |
| Genesys2 | Kintex-7 (xc7k325t)        | 133.33 MHz  | Supported      |

## Quick Start

```bash
# 1. Build the bitstream
./fpga/build/build.py x3

# 2. Program the FPGA
./fpga/program_bitstream/program_bitstream.py x3

# 3. (Optional) Load different software without reprogramming
./fpga/load_software/load_software.py x3 coremark
```

## Building

The script compiles `hello_world` into board-local BRAM contents, then runs the
Vivado pipeline. Non-sweep steps use their defaults unless a `--*-directive`
flag overrides them. Checkpoints support starting or stopping at any step. Both
boards build RV64GCB.

Promoting a new post-opt checkpoint also removes ad hoc
`audit_post_opt_*` reports and retired `post_opt_fence_*` diagnostics;
regenerate any manual audits from the promoted DCP so they cannot be confused
with diagnostics from an older checkpoint.

The X3 flow carries no timing exceptions: every path is timed. A functional
false path through the front end would need the released control to be stable
across the cycle before every sensitive cycle, and the prediction-release
companion can arm a pending-prediction episode in the very next cycle, so no
such cut is sound; the one that was tried was worth 12 ps of post-opt WNS. The
`prediction_release` formal target still proves the front-end invariants it
was written for (a buffer-release companion never overlaps a live pending
episode, and every pending-state consumer is masked outside one), and
`tests/test_fpga_build.py` locks the flow against exceptions.

Commit-mispredict recovery has one structural gate. The front-end validity
tracker exports preflush slot candidates, and `dispatch.i_flush` applies the
single architectural recovery qualification before every allocation side
effect. Recovery-qualified companions retain the existing debug view. CPU and
dispatch assertions check that the direct gate suppresses both slots and that
the preceding recovery edge clears even the preflush candidates before the
gate reopens.

X3 placement ignores `--place-directive`. By default it runs four directives
(`ExtraNetDelay_high`, `ExtraPostPlacementOpt`, `AltSpreadLogic_high`, and
`AltSpreadLogic_medium`) at six setup uncertainties from 0.500 to 0.250 ns: a
24-job grid plus the off-grid `ExtraPostPlacementOpt`/0.425 seed, for 25 jobs.
`--directives` accepts a nonempty unique subset of legal directives;
`--num-uncertainties` accepts 1–10 values in 50 ps steps from 0.500 ns (the tenth
is 0.050 ns). The grid size is the product of both counts; the qualified
off-grid seed is appended unless the grid already contains it.

Three qualified candidates use a temporary placer cost group:
`ExtraNetDelay_high`/0.500 and `ExtraPostPlacementOpt`/0.450 or 0.425. It
contains the fourteen predecode-metadata launches — the pinned low-address
scalar LUTRAM output FFs of `IsCompressedLo/Hi`, `EvenLocalPairValid`, `PairableNativeLo`,
`PairableCompressedHi`, `PairableNativeHi`, and `Slot2StartValidLo` on both
IMEM parities — to selected and state PC bits 0–63, sequential halfword-PC
bits 0–62, and pending-valid. The fourteen launches must be exact.
Topology-derived queries require one canonical endpoint per architectural
bit/control, only FD endpoints on `clock_from_mmcm`, disjoint families, and no
unexpected namespace members.

The audit repeats these invariants after placement and a clean DCP reopen.
Each validation also requires every individual launch to retain a timing path
to its intended endpoint family; aggregate connectivity from the remaining
launches cannot hide a disconnected source.
Physical synthesis may change noncanonical replica names and counts, so they
are reacquired after placement; the reopen must then preserve the complete
post-place launch and endpoint-name sets. The custom group must own no paths,
and the cone must return to `clock_from_mmcm`, before scoring at the restored
0.500 ns uncertainty. The winning guided seed promotes its audit and cone
report; an unguided winner clears them. The historical `compressed` group,
audit, and report names remain stable although the cone now covers every
predecode metadata predicate on both parities.

Placement rejects congestion estimates at
`FROST_PLACE_CONGESTION_VETO_LEVEL` (default 5). If every seed is rejected, the
least-congested survive. The leading
`FROST_PLACE_QUICK_ROUTE_COUNT` candidates (default 3) by
zero-uncertainty-equivalent WNS are quick-routed at real constraints; routed
WNS selects the winner, with router congestion warnings last. A count of zero
uses post-place WNS. The promoted checkpoint retains 0.500 ns uncertainty until
routing.

```bash
# Full build with default directives
./fpga/build/build.py x3

# Override the board's default synthesis directive (AlternateRoutability)
./fpga/build/build.py x3 --synth-directive PerformanceOptimized

# Resume at the x3 placement sweep
./fpga/build/build.py x3 --start-at place

# Run only placement with a 2×4 grid plus the off-grid seed (9 jobs)
./fpga/build/build.py x3 --start-at place --stop-after place \
  --directives ExtraNetDelay_low ExtraTimingOpt --num-uncertainties 4

# Resume placement on Genesys2 with a specific directive
./fpga/build/build.py genesys2 --start-at place --place-directive ExtraTimingOpt

# Synth only
./fpga/build/build.py x3 --stop-after synth
```

Run `./fpga/build/build.py --help` for the full list of directives and options.

## Programming the FPGA

```bash
./fpga/program_bitstream/program_bitstream.py <board> [remote_host] [--target PATTERN] [--list-targets]
```

Arguments:

- `board` — target board: `x3` or `genesys2`
- `remote_host` — remote FPGA hostname
- `--target PATTERN` — target index or case-insensitive name/serial substring
- `--list-targets` — list this board's targets and exit

Examples:

```bash
# Local FPGA (auto-selects if only one matching target, prompts if multiple)
./fpga/program_bitstream/program_bitstream.py x3

# List available targets for this board (filtered by vendor)
./fpga/program_bitstream/program_bitstream.py genesys2 --list-targets

# Select target by index (from filtered list)
./fpga/program_bitstream/program_bitstream.py genesys2 --target 0

# Select target by serial number
./fpga/program_bitstream/program_bitstream.py genesys2 --target 210299A8B4D1

# Remote FPGA (requires Vivado Hardware Server on remote host)
./fpga/program_bitstream/program_bitstream.py x3 fpga-server.local
```

## Loading Software

The loader compiles the app for the board's clock, bursts a nonempty
`sw_ddr.txt` into cached DDR while low-BRAM keepalive writes hold reset, then
writes the full `sw.txt` image at `0x00000000` and releases reset. It also scales
CoreMark iterations for the board.

```bash
./fpga/load_software/load_software.py <board> <app> [remote_host] [--target PATTERN] [--list-targets]
```

Arguments:

- `board` — target board: `x3` or `genesys2`
- `app` — application listed by `--help`
- `remote_host` — remote FPGA hostname
- `--target PATTERN` — target index or case-insensitive name/serial substring
- `--list-targets` — list this board's targets without requiring `app`

Use a serial terminal configured for 115200 baud, 8 data bits, no parity, and
1 stop bit (8N1) to view the board UART console.

CoreMark-PRO requires `-v1` for validation or `-v0` for registry-calibrated
performance runs. Cached data such as radix2's ~800 KiB tables is burst-loaded
through the automatically identified DDR JTAG master before low BRAM.

Examples:

```bash
# Load coremark on X3 locally
./fpga/load_software/load_software.py x3 coremark

# Load hello_world on remote Genesys2
./fpga/load_software/load_software.py genesys2 hello_world fpga-server.local

# Load FreeRTOS demo on Genesys2
./fpga/load_software/load_software.py genesys2 freertos_demo

# CoreMark-PRO validation and performance
./fpga/load_software/load_software.py x3 coremark_pro_core -v1
./fpga/load_software/load_software.py genesys2 coremark_pro_radix2 -v1
./fpga/load_software/load_software.py x3 coremark_pro_linear_alg -v0

# List targets for this board (doesn't require app argument)
./fpga/load_software/load_software.py genesys2 --list-targets

# Select specific target by serial number
./fpga/load_software/load_software.py genesys2 hello_world --target 210299A8B4D1
```

## Multiple Hardware Targets

Target discovery filters Genesys2 to `Digilent` and X3 to `Xilinx`, including
for `--list-targets`. A unique match is selected automatically; multiple
matches prompt for selection.

Target names follow the format `hostname:port/xilinx_tcf/<vendor>/<serial>`:

- Digilent boards: `localhost:3121/xilinx_tcf/Digilent/210299A8B4D1`
- Alveo boards: `localhost:3121/xilinx_tcf/Xilinx/00001234abcd`

`--target` accepts a case-insensitive substring such as a serial number, or an
index (`0`, `1`, …) from the filtered list.

## Remote Programming

Start Vivado Hardware Server on the remote host, then pass its hostname:

```bash
hw_server -d  # port 3121
./fpga/program_bitstream/program_bitstream.py x3 remote-hostname
./fpga/load_software/load_software.py x3 coremark remote-hostname
```

## Customization

### Adding a New Board

1. Create `boards/<board>/` with:
   - `<board>_frost.sv` — top-level wrapper with clock generation
     - Generate CPU clock and /4 clock using MMCM
     - Instantiate the board's DDR controller subsystem (the `ddr_subsys`
       block design built by `build/<board>_ddr_bd.tcl`) and the FROST
       cache-bridge AXI / `mem_ok` calibration wiring
     - Instantiate `xilinx_frost_subsystem` (see `boards/xilinx_frost_subsystem.sv`),
       passing `ENABLE_CACHED_TIER`/`CACHED_HAS_L2` for the board's hierarchy
       shape (`CACHED_HAS_L2=1` only where UltraRAM exists, e.g. X3)
   - `constr/<board>.xdc` — pin assignments and timing constraints
   - `<board>_frost.f` — file list for synthesis (include the subsystem and core)

   The Xilinx IP cores (`jtag_axi_0`, `axi_bram_ctrl_0`) and the per-board DDR
   `ddr_subsys` block design are created on the fly during synthesis by
   `build/build_step.tcl`, so no per-board `ip/` directory is needed.

2. Add a `build/<board>_ddr_bd.tcl` that assembles the DDR `ddr_subsys` block
   design (memory controller + SmartConnect + a JTAG-AXI DDR-image-load master)
   and have `build/build_step.tcl` source it during the synth step.

3. Add the board (FPGA part, clock frequency) to:
   - `BOARD_CONFIG` in `build/build.py` and in `load_software/load_software.py`
     (the loader entry also carries `coremark_iterations` and a `has_ddr` flag)
   - the board-name argument `choices` in `build/build.py`,
     `program_bitstream/program_bitstream.py`, and `load_software/load_software.py`
   - the board/part handling in `build/build_step.tcl`
   - the UART device, JTAG target pattern, and hardware-run timeout defaults in
     `common/hw_defaults.py`

4. Add the board's vendor filter to `BOARD_VENDOR_INFO` in `common/hw_target.py`
   so the programming and loading scripts can auto-select its JTAG target

5. See `boards/README.md` for detailed instructions and board comparison

### Adding a New Application

1. Add a `sw/apps/<app>/` directory whose `make` produces `sw.txt` (hex format,
   one 32-bit word per line) and `sw.mem`. An app that places code or data in
   the cached DDR region also produces a `sw_ddr.txt`/`sw_ddr.mem` image that
   the loader bursts into DDR over a second JTAG-AXI master.

2. Register the app name in both `VALID_APPS` in
   `load_software/load_software.py` and the `valid_apps` list in
   `load_software/load_software.tcl` (the loader rejects unknown app names)

3. Load it (the loader compiles the app for the target board automatically):
   ```bash
   ./fpga/load_software/load_software.py <board> <app>
   ```

## Troubleshooting

**"No hardware targets found"**
- Ensure JTAG cable is connected
- Check that the board is powered on
- For remote: verify `hw_server` is running on the remote host
- Use `--list-targets` to see what targets are detected

**"Multiple hardware targets detected" / wrong board selected**
- Use `--list-targets` to see available targets
- Use `--target <pattern>` to select the correct board by index, vendor, or serial number

**Timing failures**
- Try different directives for the failing step (see `./fpga/build/build.py --help`)
- Check `build/<board>/work/final_timing.rpt` for failing paths
- Consider reducing clock frequency in the board's constraint file

**Software not running after load**
- Verify the hex file format (one 32-bit word per line, no address prefix)
- Check that the low-BRAM image fits and any required `sw_ddr.txt` image was loaded

## License

Copyright 2026 Two Sigma Open Source, LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

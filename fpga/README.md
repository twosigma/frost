# FROST FPGA Build and Deployment

Xilinx FPGA build, programming, software-loading, and debug tools.

## Layout and flows

| Directory            | Purpose                                    |
|----------------------|--------------------------------------------|
| `build/`             | Synthesize and generate bitstream          |
| `program_bitstream/` | Program FPGA with bitstream via JTAG       |
| `load_software/`     | Load software images into low BRAM and optional DDR without reprogramming |
| `debug/`             | OpenOCD configurations for the RISC-V debug module (simulation and X3) |

The two common flows are:

```text
RTL → build/build.py → bitstream → program_bitstream/program_bitstream.py → FPGA
app source → make → sw.txt (+ sw_ddr.txt) → load_software/load_software.py → FPGA
```

The loader data path is JTAG-AXI → AXI-to-BRAM → low BRAM → CPU. DDR images
go through the board's separate burst-capable JTAG-AXI master.

The RISC-V debug module (Phase 3 M3) shares the FPGA's own TAP through two
BSCAN USER chains (see `../boards/README.md`); `debug/` holds the OpenOCD
configurations. The cable has one owner, so close hw_server before starting
OpenOCD:

```bash
openocd -f fpga/debug/openocd_x3.cfg
riscv-none-elf-gdb sw/apps/hello_world/sw.elf -ex 'target extended-remote :3333'
```

`openocd_sim.cfg` is the same target over `remote_bitbang` against the
cocotb bench (`debug_openocd_test`). Software breakpoints work in BRAM and
DDR code alike. There are no hardware triggers, and memory is reached
through the program buffer rather than a system bus, so `load` of a whole
image is slow. Use the JTAG loader for images and the debugger for debugging.

`hw_regression.py` loads and UART-checks every bare-metal app, runs all nine
CoreMark-PRO workloads with per-board score gates, then boots Linux to the
Buildroot login prompt:

```bash
./fpga/hw_regression.py --board x3
```

The regression's `--timeout` is a common end-to-end base (build and load
included). The CoreMark-PRO sweep raises it when a workload has a larger
board-specific minimum in `../sw/apps/software_registry.py`. In particular,
X3 ZIP gets 600 seconds because its conforming official 1 MiB input generator
does several minutes of untimed repeated-`strcat` setup before the scored
interval; this budget does not alter the workload or its reported score.

## Prerequisites

- Vivado (see the [main README](../README.md#prerequisites) for the validated version)
- Python 3
- JTAG cable connected to the target board
- For remote programming: Vivado Hardware Server running on the remote host

## Supported Boards

| Board    | FPGA                       | FROST Clock | Status         |
|----------|----------------------------|-------------|----------------|
| X3       | Alveo UltraScale+ (xcux35) | 300 MHz     | Primary target |

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

`build/build.py` compiles `hello_world` into the board's initial BRAM
contents, then runs the Vivado pipeline. Every step writes a checkpoint, so
`--start-at` and `--stop-after` can resume from or stop after any step.
Non-sweep steps use their defaults unless a `--*-directive` flag overrides
them. The current X3 target builds RV64GCB; board configuration remains
table-driven so another target can be added without restructuring the flow.

Promoting a new post-opt checkpoint deletes ad hoc `audit_post_opt_*` reports
and retired `post_opt_fence_*` diagnostics from the work directory, so neither
can be mistaken for evidence about the new DCP. Regenerate manual audits from
the promoted checkpoint.

The X3 flow carries no timing exceptions; every path is timed. A functional
false path through the front end would be sound only if the released control
were stable across the cycle before every sensitive cycle, and the front-end
recovery state does not guarantee that. The one cut that was tried was worth
12 ps of post-opt WNS and was retired. The `prediction_release` formal target
proves that the atomic target handoff suppresses old-path buffer validity,
exercises both raw-capture cofactors, keeps the integrated release sources
clear, and masks every pending-state consumer outside a live episode.
`../tests/test_fpga_build.py` locks the flow against exceptions.

Commit-mispredict recovery has one structural gate. The front-end validity
tracker exports preflush slot candidates, and `dispatch.i_flush` applies the
single architectural recovery qualification before any allocation side
effect. The recovery-qualified companions remain debug and invariant views.
Assertions in `cpu_ooo` and `dispatch` check that the direct gate suppresses
both slots and that the preceding recovery edge has cleared even the preflush
candidates before the gate reopens.

X3 placement ignores `--place-directive`. By default it runs four directives
(`ExtraNetDelay_high`, `ExtraPostPlacementOpt`, `AltSpreadLogic_high`, and
`AltSpreadLogic_medium`) at six setup uncertainties from 0.500 to 0.250 ns: a
24-job grid plus the off-grid `ExtraPostPlacementOpt`/0.425 seed, for 25 jobs.
`--directives` accepts a nonempty unique subset of legal directives;
`--num-uncertainties` accepts 1–10 values in 50 ps steps from 0.500 ns (the tenth
is 0.050 ns). The grid size is the product of both counts; the qualified
off-grid seed is appended unless the grid already contains it.

Three qualified candidates use a temporary placer cost group:
`ExtraNetDelay_high`/0.500 and `ExtraPostPlacementOpt`/0.450 or 0.425. The
group holds the paths from the fourteen predecode-metadata launches to
selected and state PC bits 0–63, sequential halfword-PC bits 0–62, and
pending-valid. Those launches are the pinned low-address scalar LUTRAM output
FFs of `IsCompressedLo/Hi`, `EvenLocalPairValid`, `PairableNativeLo`,
`PairableCompressedHi`, `PairableNativeHi`, and `Slot2StartValidLo` on both
IMEM parities, and all fourteen must match exactly. Topology-derived queries
require one canonical endpoint per architectural bit/control, only FD endpoints
on `clock_from_mmcm`, disjoint families, and no unexpected namespace members.

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

# Synth only
./fpga/build/build.py x3 --stop-after synth
```

Run `./fpga/build/build.py --help` for the full list of directives and options.

## Programming the FPGA

```bash
./fpga/program_bitstream/program_bitstream.py <board> [remote_host] [--target PATTERN] [--list-targets]
```

Arguments:

- `board`: `x3`
- `remote_host`: hostname of a remote Vivado Hardware Server
- `--target PATTERN`: target index or case-insensitive name/serial substring
- `--list-targets`: list this board's targets and exit

Examples:

```bash
# Local FPGA (auto-selects if only one matching target, prompts if multiple)
./fpga/program_bitstream/program_bitstream.py x3

# List available targets for this board (filtered by vendor)
./fpga/program_bitstream/program_bitstream.py x3 --list-targets

# Select target by index (from filtered list)
./fpga/program_bitstream/program_bitstream.py x3 --target 0

# Select target by serial-number substring
./fpga/program_bitstream/program_bitstream.py x3 --target 507711333S8VAA

# Remote FPGA (requires Vivado Hardware Server on remote host)
./fpga/program_bitstream/program_bitstream.py x3 fpga-server.local
```

## Loading Software

The loader compiles the app for the board's clock (scaling CoreMark
iterations to the board), bursts a nonempty `sw_ddr.txt` into cached DDR
while low-BRAM keepalive writes hold the CPU in image reset, then writes the
full `sw.txt` image at `0x00000000`. The image-load reset, which every
low-BRAM write re-arms, expires after the last write and the CPU starts the
new image.

```bash
./fpga/load_software/load_software.py <board> <app> [remote_host] [--target PATTERN] [--list-targets]
```

Arguments:

- `board`: `x3`
- `app`: an application listed by `--help`
- `remote_host`: hostname of a remote Vivado Hardware Server
- `--target PATTERN`: target index or case-insensitive name/serial substring
- `--list-targets`: list this board's targets; `app` is not required

Use a serial terminal configured for 115200 baud, 8 data bits, no parity, and
1 stop bit (8N1) to view the board UART console.

CoreMark-PRO workloads require `-v1` (validation) or `-v0` (performance run
with the iteration counts from `../sw/apps/software_registry.py`). Data placed
in the cached region, such as radix2's ~800 KiB FFT tables, is burst-loaded
before the low-BRAM image through the DDR JTAG master, which the loader
identifies automatically.

Examples:

```bash
# Load coremark on X3 locally
./fpga/load_software/load_software.py x3 coremark

# Load hello_world through a remote hardware server
./fpga/load_software/load_software.py x3 hello_world fpga-server.local

# Load FreeRTOS demo
./fpga/load_software/load_software.py x3 freertos_demo

# CoreMark-PRO validation and performance
./fpga/load_software/load_software.py x3 coremark_pro_core -v1
./fpga/load_software/load_software.py x3 coremark_pro_radix2 -v1
./fpga/load_software/load_software.py x3 coremark_pro_linear_alg -v0

# List targets for this board (doesn't require app argument)
./fpga/load_software/load_software.py x3 --list-targets

# Select specific target by serial number
./fpga/load_software/load_software.py x3 hello_world --target 507711333S8VAA
```

## Multiple Hardware Targets

Target discovery applies the vendor filter registered for each board,
including for `--list-targets`; X3 targets use `Xilinx`. A unique match is
selected automatically, while multiple matches prompt for selection.

Target names follow the format `hostname:port/xilinx_tcf/<vendor>/<serial>`:

- Alveo boards: `localhost:3121/xilinx_tcf/Xilinx/507711333S8VAA`

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

1. Create `../boards/<board>/` with:
   - `<board>_frost.sv`: top-level wrapper. It generates the CPU clock and the
     /4 clock with an MMCM and instantiates `xilinx_frost_subsystem`
     (`../boards/xilinx_frost_subsystem.sv`). A DDR-capable target also
     instantiates the `ddr_subsys` block design built by
     `build/<board>_ddr_bd.tcl`, wires the cache-bridge AXI and `mem_ok`, and
     enables the cached tier. That full-system hierarchy includes the 2 MiB
     UltraRAM L2, so a DDR-capable target must provide sufficient UltraRAM. A
     BRAM-only target leaves the cached tier disabled.
   - `constr/<board>.xdc`: pin assignments and timing constraints
   - `<board>_frost.f`: file list for synthesis, including the subsystem and core

   The Xilinx IP cores (`jtag_axi_0`, `axi_bram_ctrl_0`) and, for a DDR-capable
   board, its `ddr_subsys` block design are created during synthesis by
   `build/build_step.tcl`, so no per-board `ip/` directory is needed.

2. For a DDR-capable board, add `build/<board>_ddr_bd.tcl` to assemble the
   `ddr_subsys` block design (memory controller + SmartConnect + a JTAG-AXI
   DDR-image-load master). A BRAM-only board does not need this file.

3. Register the board throughout the table-driven tool layer:
   - `BOARD_CONFIG` in `build/build.py` for its clock, FPGA family, and default
     synthesis directive, plus `BOARD_INFO` in
     `build/extract_timing_and_util_summary.py`
   - `board_build_configs` in `build/build_step.tcl` for its FPGA part and
     `has_ddr` capability; its other per-board names derive from the board key
   - `BOARD_CONFIG` in `load_software/load_software.py` for its clock, CoreMark
     iterations, and DDR capability
   - `BOARD_VENDOR_INFO` in `common/hw_target.py` and all three maps in
     `common/hw_defaults.py` for JTAG, UART, and timeout defaults
   - `supported_boards` in `program_bitstream/program_bitstream.tcl` for direct
     Tcl use. The Python build/load/programming and hardware-regression CLIs
     derive their choices from the registries above

4. Calibrate every CoreMark-PRO workload's `hardware_iterations` entry in
   `../sw/apps/software_registry.py`. If a workload's untimed setup can exceed
   the board's common timeout, also set its `hardware_timeout_minimums` entry.
   Optionally record silicon score gates in `BASELINE_SCORES` in
   `hw_regression.py`.

5. See `../boards/README.md` for the complete board-integration checklist.

### Adding a New Application

1. Add a `../sw/apps/<app>/` directory whose `make` produces `sw.txt` (one
   32-bit hex word per line) and `sw.mem`. An app that places code or data in
   the cached DDR region also produces `sw_ddr.txt`/`sw_ddr.mem`, which the
   loader bursts into DDR over the second JTAG-AXI master.

2. Register the app name in both `VALID_APPS` in
   `load_software/load_software.py` and the `valid_apps` list in
   `load_software/load_software.tcl` (the loader rejects unknown app names)

3. Load it (the loader compiles the app for the target board automatically):
   ```bash
   ./fpga/load_software/load_software.py <board> <app>
   ```

## Troubleshooting

**"No hardware targets found"**
- Check that the JTAG cable is connected and the board is powered on
- For remote: verify `hw_server` is running on the remote host
- Use `--list-targets` to see what targets are detected

**"Multiple hardware targets detected" / wrong board selected**
- Use `--list-targets` to see available targets
- Use `--target <pattern>` to select the correct board by index, vendor, or serial number

**Timing failures**
- Try different directives for the failing step (see `./fpga/build/build.py --help`)
- Check `build/<board>/work/final_timing.rpt` for failing paths
- Lowering the CPU clock means changing the MMCM parameters in
  `../boards/<board>/<board>_frost.sv` and the `clock_freq` entries in
  `build/build.py` and `load_software/load_software.py`

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

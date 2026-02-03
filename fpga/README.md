# FROST FPGA Build and Deployment

This directory contains the complete infrastructure for building, programming, and deploying FROST to Xilinx FPGAs.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          FPGA Development Workflow                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────────┐     ┌──────────────────┐     ┌───────────────────────┐   │
│   │  RTL Source  │────>│  build/build.py  │────>│  Bitstream (.bit)     │   │
│   │  (hw/rtl/)   │     │                  │     │  (build/<board>/work/)│   │
│   └──────────────┘     │  6-Step Pipeline │     └───────────┬───────────┘   │
│                        │  with parallel   │                 │               │
│                        │  directive sweeps│                 │               │
│                        └──────────────────┘                 v               │
│                                              ┌──────────────────────────┐   │
│                                              │ program_bitstream.py     │   │
│                                              │ (programs FPGA via JTAG) │   │
│                                              └─────────────┬────────────┘   │
│                                                            │                │
│   ┌──────────────┐     ┌──────────────────┐                v                │
│   │  C Source    │────>│  make (in sw/)   │     ┌───────────────────────┐   │
│   │  (sw/apps/)  │     │  (compiles app)  │     │   FPGA Running FROST  │   │
│   └──────────────┘     └────────┬─────────┘     └───────────┬───────────┘   │
│                                 │                           │               │
│                                 v                           │               │
│                        ┌──────────────────┐                 │               │
│                        │  sw.txt (hex)    │                 │               │
│                        └────────┬─────────┘                 │               │
│                                 │                           │               │
│                                 v                           v               │
│                        ┌──────────────────────────────────────────────┐     │
│                        │         load_software/load_software.py       │     │
│                        │    (loads program to BRAM via JTAG - fast)   │     │
│                        └──────────────────────────────────────────────┘     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

The FPGA tooling is organized into three main workflows:

| Directory            | Purpose                                    |
|----------------------|--------------------------------------------|
| `build/`             | Synthesize and generate bitstream          |
| `program_bitstream/` | Program FPGA with bitstream via JTAG       |
| `load_software/`     | Load software into BRAM without reprogramming |

## Prerequisites

- **Vivado** (see [main README](../README.md#prerequisites) for validated versions)
- Python 3
- JTAG cable connected to target board
- For remote programming: Vivado Hardware Server running on remote host

## Supported Boards

| Board    | FPGA                       | FROST Clock | Status         |
|----------|----------------------------|-------------|----------------|
| X3       | Alveo UltraScale+ (xcux35) | 300 MHz     | Primary target |
| Genesys2 | Kintex-7 (xc7k325t)        | 133 MHz     | Supported      |
| Nexys A7 | Artix-7 (xc7a100t)         | 80 MHz      | Supported      |

## Quick Start

```bash
# 1. Build the bitstream (runs parallel sweeps at each stage)
./fpga/build/build.py x3

# 2. Program the FPGA
./fpga/program_bitstream/program_bitstream.py x3

# 3. (Optional) Load different software without reprogramming
./fpga/load_software/load_software.py x3 coremark
```

## Building

The unified build script runs a 6-step pipeline with parallel directive sweeps at each stage for maximum timing closure probability.

```bash
./fpga/build/build.py <board> [--start-at STEP] [--stop-after STEP] [--retiming] [--no-sweeping] [--keep-temps]
```

### The Build Steps

| Step | Description | Parallel Jobs |
|------|-------------|---------------|
| 1. `synth` | Synthesis with directive sweep | 8 directives |
| 2. `opt` | Optimization with directive sweep | 8 directives |
| 3. `place` | Placement with directive sweep (includes 0.5ns overconstrain) | 12 directives |
| 4. `post_place_physopt` | Post-place phys_opt loop of sweeps | 8 directives per pass |
| 5-6. `route` + `post_route_physopt` | Route+phys_opt meta-loop (see below) | 8-9 + 8 directives |

### How It Works

**Early vs Final Steps:**
- **Early steps** (synth, opt, place, post_place_physopt): Wait for ALL jobs to complete and pick the best WNS. This maximizes timing margin for subsequent steps.
- **Final steps** (route, post_route_physopt): Early-terminate as soon as any job achieves WNS >= 0. Timing is already met, no need to wait.

**Phys_opt Loops:**
- Each pass runs a parallel sweep of all phys_opt directives
- Picks winner based on greatest WNS/TNS improvement
- Continues until WNS >= 0 OR no improvement in either WNS or TNS

**Route + Post-route Meta-loop:**
When both route and post_route_physopt steps are run, they execute as a single iterating meta-loop:
1. Run route sweep (early-terminates on timing met)
2. Run post_route phys_opt loop (early-terminates on timing met)
3. If improvement was made, go back to step 1 (route from post_place_physopt again)
4. If route doesn't improve over previous iteration, stop and keep the previous best result
5. Continue until timing is met or no further improvement

This allows the build to explore multiple route+physopt combinations to find the best timing closure.

### Arguments

- `board` - Target board: `x3`, `genesys2`, or `nexys_a7` (default: x3)
- `--start-at STEP` - Start at this step (requires appropriate checkpoint)
- `--stop-after STEP` - Stop after this step
- `--retiming` - Enable global retiming during synthesis
- `--no-sweeping` - Use only Default directive (default for genesys2/nexys_a7)
- `--sweep` - Force parallel directive sweeps (override default for genesys2/nexys_a7)
- `--keep-temps` - Keep temporary work directories
- `--vivado-path PATH` - Path to Vivado executable

### Checkpoints

Each step produces a checkpoint that enables resuming:

| Checkpoint | Required to start at |
|------------|---------------------|
| `post_synth.dcp` | `opt` |
| `post_opt.dcp` | `place` |
| `post_place.dcp` | `post_place_physopt` |
| `post_place_physopt.dcp` | `route` |
| `post_route.dcp` | `post_route_physopt` |
| `final.dcp` | (final output) |

### Examples

```bash
# Full build with all sweeps (default for x3)
./fpga/build/build.py x3

# Build for Genesys2 (no sweeping by default)
./fpga/build/build.py genesys2

# Resume from placement (skip synth and opt)
./fpga/build/build.py x3 --start-at place

# Run only synth, opt, and place (stop before phys_opt)
./fpga/build/build.py x3 --stop-after place

# Re-run the route+physopt meta-loop from post_place_physopt checkpoint
./fpga/build/build.py x3 --start-at route

# Re-run just post-route phys_opt (no re-routing, uses existing post_route.dcp)
./fpga/build/build.py x3 --start-at post_route_physopt

# Enable retiming during synthesis
./fpga/build/build.py x3 --retiming

# Fast build with Default directives only (no parallel sweeps)
./fpga/build/build.py x3 --no-sweeping

# Force parallel sweeps for genesys2 (not default)
./fpga/build/build.py genesys2 --sweep

# Keep temp directories for debugging
./fpga/build/build.py x3 --keep-temps
```

### Outputs

**Build artifacts** (in `build/<board>/work/`, not tracked in git):
- `<board>_frost.bit` - Final bitstream
- `*.dcp` - Design checkpoints at each stage
- `*_timing.rpt` - Timing analysis reports
- `*_util.rpt` - Resource utilization reports
- `*_high_fanout.rpt` - High fanout net analysis
- `*_failing_paths.csv` - Detailed failing path analysis

**Summaries** (in `build/<board>/`, tracked in git):
- `SUMMARY_post_synth.md` - Timing and utilization after synthesis
- `SUMMARY_post_opt.md` - Timing and utilization after optimization
- `SUMMARY_post_place.md` - Timing and utilization after placement
- `SUMMARY_post_place_physopt.md` - Timing and utilization after post-place phys_opt
- `SUMMARY_post_route.md` - Timing and utilization after routing
- `SUMMARY_final.md` - Final timing and utilization

### Directives Tested

**Synthesis (8 directives):**
- Default, PerformanceOptimized, AreaOptimized_high, AreaOptimized_medium
- AlternateRoutability, AreaMapLargeShiftRegToBRAM, AreaMultThresholdDSP, FewerCarryChains

**Optimization (8 directives):**
- Default, Explore, ExploreArea, ExploreWithRemap
- ExploreSequentialArea, AddRemap, NoBramPowerOpt, RuntimeOptimized

**Placement (12 directives):**
- Default, Explore, ExtraNetDelay_high, ExtraNetDelay_low
- ExtraPostPlacementOpt, ExtraTimingOpt, AltSpreadLogic_high, AltSpreadLogic_low
- AltSpreadLogic_medium, SpreadLogic_high, SpreadLogic_low, EarlyBlockPlacement

**Routing (8-9 directives):**
- Default, Explore, AggressiveExplore, NoTimingRelaxation
- MoreGlobalIterations, HigherDelayCost, AdvancedSkewModeling, RuntimeOptimized
- AlternateCLBRouting (UltraScale only)

**Phys_opt (8 directives):**
- Default, Explore, ExploreWithHoldFix, AggressiveExplore
- AlternateReplication, AggressiveFanoutOpt, AlternateFlowWithRetiming, RuntimeOptimized

## Programming the FPGA

Program the FPGA with the generated bitstream via JTAG.

```bash
./fpga/program_bitstream/program_bitstream.py <board> [remote_host] [--target PATTERN] [--list-targets]
```

**Arguments:**
- `board` - Target board: `x3`, `genesys2`, or `nexys_a7`
- `remote_host` - (Optional) Hostname for remote FPGA programming
- `--target PATTERN` - (Optional) Select hardware target by index (0, 1, 2...) or pattern (e.g., serial number)
- `--list-targets` - (Optional) List available hardware targets for this board and exit

**Examples:**
```bash
# Local FPGA (auto-selects if only one matching target, prompts if multiple)
./fpga/program_bitstream/program_bitstream.py x3

# List available targets for this board (filtered by vendor)
./fpga/program_bitstream/program_bitstream.py nexys_a7 --list-targets

# Select target by index (from filtered list)
./fpga/program_bitstream/program_bitstream.py nexys_a7 --target 0

# Select target by serial number
./fpga/program_bitstream/program_bitstream.py nexys_a7 --target 210299A8B4D1

# Remote FPGA (requires Vivado Hardware Server on remote host)
./fpga/program_bitstream/program_bitstream.py x3 fpga-server.local
```

## Loading Software

Load software into instruction memory without regenerating the bitstream. This enables rapid iteration during development. Applications are compiled automatically before loading—no manual build step required. The board argument sets the correct clock frequency and scales CoreMark iterations appropriately.

```bash
./fpga/load_software/load_software.py <board> <app> [remote_host] [--target PATTERN] [--list-targets]
```

**Arguments:**
- `board` - Target board: `x3`, `genesys2`, or `nexys_a7`
- `app` - Application name (see table below)
- `remote_host` - (Optional) Hostname for remote FPGA
- `--target PATTERN` - (Optional) Select hardware target by index (0, 1, 2...) or pattern (e.g., serial number)
- `--list-targets` - (Optional) List available hardware targets for this board and exit (does not require `app`)

**Available Applications:**

| Application         | Description                                          |
|---------------------|------------------------------------------------------|
| `hello_world`       | Simple test program (prints message every second)    |
| `isa_test`          | ISA compliance test suite                            |
| `coremark`          | Industry-standard CPU benchmark                      |
| `freertos_demo`     | FreeRTOS RTOS demo with timer interrupts             |
| `csr_test`          | CSR and trap handling tests                          |
| `memory_test`       | Memory allocator test suite                          |
| `strings_test`      | String library test suite                            |
| `packet_parser`     | FIX protocol message parser                          |
| `c_ext_test`        | C extension (compressed instruction) test            |
| `call_stress`       | Function call stress test                            |
| `spanning_test`     | Instruction spanning boundary test                   |
| `uart_echo`         | Interactive UART receive demo (echo, hex, commands)  |
| `branch_pred_test`  | Branch predictor verification (45 tests)             |
| `ras_test`          | Return Address Stack (RAS) comprehensive test suite  |
| `ras_stress_test`   | Stress test mixing calls, returns, and branches      |
| `fpu_assembly_test` | FPU assembly hazard tests                            |
| `print_clock_speed` | Clock speed measurement utility                      |

The script compiles the application with the correct clock frequency for the target board and writes the resulting hex file to BRAM starting at address `0x00000000`.

**Examples:**
```bash
# Load coremark on X3 locally
./fpga/load_software/load_software.py x3 coremark

# Load hello_world on remote Genesys2
./fpga/load_software/load_software.py genesys2 hello_world fpga-server.local

# Load FreeRTOS demo on Nexys A7
./fpga/load_software/load_software.py nexys_a7 freertos_demo

# List targets for this board (doesn't require app argument)
./fpga/load_software/load_software.py nexys_a7 --list-targets

# Select specific target by serial number
./fpga/load_software/load_software.py nexys_a7 hello_world --target 210299A8B4D1
```

## Multiple Hardware Targets

When multiple FPGA boards are connected to the same host, the scripts automatically detect all available hardware targets and filter them based on the board type:

**Automatic vendor filtering:**
- `nexys_a7` and `genesys2` → auto-filters for `Digilent` targets
- `x3` → auto-filters for `Xilinx` targets

This filtering applies to all operations including `--list-targets`. If you have both Digilent and Alveo boards connected, specifying `nexys_a7` will only show/select Digilent targets and `x3` will only show/select Xilinx targets.

**Selection behavior:**
- **Single matching target**: Automatically selected without prompting
- **Multiple matching targets, no `--target` flag**: Lists matching targets and prompts for selection
- **`--target` with unique match**: Automatically selects the matching target
- **`--target` with multiple matches**: Lists matching targets and prompts for selection

Target names follow the format `hostname:port/xilinx_tcf/<vendor>/<serial>`:
- Digilent boards: `localhost:3121/xilinx_tcf/Digilent/210299A8B4D1`
- Alveo boards: `localhost:3121/xilinx_tcf/Xilinx/00001234abcd`

The `--target` pattern matching is case-insensitive and matches anywhere in the target name, so you can use:
- `210299A8B4D1` - matches a specific board by serial number
- `0`, `1`, `2` - select by index from the filtered target list

## Architecture

```
+----------------------------------------------------------------------+
|                            Host Computer                             |
|  +-----------+    +------------------+    +---------------+          |
|  |  build.py |    | program_bitstream|    | load_software |          |
|  +-----+-----+    +--------+---------+    +-------+-------+          |
|        |                   |                      |                  |
|        v                   v                      v                  |
|  +-------------------------------------------------------+           |
|  |                        Vivado                         |           |
|  +-------------------------------------------------------+           |
+----------------------------------------------------------------------+
                                   | JTAG
                                   v
+----------------------------------------------------------------------+
|                                FPGA                                  |
|  +--------------+    +--------------+    +--------------+            |
|  |  JTAG-to-AXI |--->| AXI-to-BRAM  |--->|     BRAM     |            |
|  |    Bridge    |    |  Controller  |    | (Program Mem)|            |
|  +--------------+    +--------------+    +------+-------+            |
|                                                  |                   |
|                                                  v                   |
|                                          +--------------+            |
|                                          |  FROST CPU   |            |
|                                          |   (RISC-V)   |            |
|                                          +--------------+            |
+----------------------------------------------------------------------+
```

## Remote Programming

To program or load software on a remote FPGA:

1. Start Vivado Hardware Server on the remote machine:
   ```bash
   hw_server -d
   ```
   This listens on port 3121 by default.

2. Use the `remote_host` argument:
   ```bash
   ./fpga/program_bitstream/program_bitstream.py x3 remote-hostname
   ./fpga/load_software/load_software.py x3 coremark remote-hostname
   ```

## Customization

### Adding a New Board

1. Create `boards/<board>/` with:
   - `<board>_frost.sv` - Top-level wrapper with clock generation
     - Generate CPU clock and /4 clock using MMCM
     - Instantiate `xilinx_frost_subsystem` (see `boards/xilinx_frost_subsystem.sv`)
   - `constr/<board>.xdc` - Pin assignments and timing constraints
   - `ip/` - Copy Xilinx IP cores from an existing board (Vivado will auto-migrate)
   - `<board>_frost.f` - File list for synthesis

2. Update `build/build_step.tcl` to handle the new board name

3. Update `program_bitstream/program_bitstream.tcl` with the bitstream path

4. See `boards/README.md` for detailed instructions and board comparison

### Adding a New Application

1. Compile your application to produce `sw/apps/<app>/sw.txt` (hex format, one 32-bit word per line)

2. Load it:
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
- The build script automatically sweeps directives at each stage
- Check `build/<board>/work/final_timing.rpt` for failing paths
- Consider reducing clock frequency in the board's constraint file

**Software not running after load**
- Verify the hex file format (one 32-bit word per line, no address prefix)
- Check that the program fits in available BRAM

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

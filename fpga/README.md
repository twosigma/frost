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
│   │  (hw/rtl/)   │     │        -or-      │     │  (build/<board>/work/)│   │
│   └──────────────┘     │ build_*_sweep.py │     └───────────┬───────────┘   │
│                        └──────────────────┘                 │               │
│                                                             │               │
│                                                             v               │
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
| X3       | Alveo UltraScale+ (xcux35) | 322 MHz     | Primary target |
| Genesys2 | Kintex-7 (xc7k325t)        | 133 MHz     | Supported      |
| Nexys A7 | Artix-7 (xc7a100t)         | 80 MHz      | Supported      |

## Quick Start

```bash
# 1. Build the bitstream (takes ~15-30 minutes)
./fpga/build/build.py x3

# 2. Program the FPGA
./fpga/program_bitstream/program_bitstream.py x3

# 3. (Optional) Load different software without reprogramming
./fpga/load_software/load_software.py x3 coremark
```

## Building

The build system uses Vivado in batch mode to synthesize, place, and route the design.

```bash
./fpga/build/build.py <board> [--synth-only] [--retiming]
```

**Arguments:**
- `board` - Target board: `x3`, `genesys2`, or `nexys_a7`
- `--synth-only` - (Optional) Stop after synthesis, skipping implementation and bitstream generation
- `--retiming` - (Optional) Enable global retiming during synthesis for improved timing

**Outputs:**
- `build/<board>/work/` - Build artifacts (not tracked in git):
  - `<board>_frost.bit` - Final bitstream (full build only)
  - `*.dcp` - Design checkpoints (post-synth, post-opt, post-place, post-route)
  - `*_timing.rpt` - Timing analysis reports
  - `*_util.rpt` - Resource utilization reports
- `build/<board>/` - Summaries (tracked in git):
  - `SUMMARY_post_synth.md` - Timing and utilization after synthesis
  - `SUMMARY_post_opt.md` - Timing and utilization after optimization
  - `SUMMARY_post_place.md` - Timing and utilization after placement
  - `SUMMARY_post_route.md` - Timing and utilization after routing

**Examples:**
```bash
# Full build
./fpga/build/build.py x3
# Output: fpga/build/x3/work/x3_frost.bit

# Synthesis only (faster, useful for checking resource utilization)
./fpga/build/build.py x3 --synth-only
# Output: fpga/build/x3/work/post_synth.dcp

# Full build with global retiming enabled
./fpga/build/build.py x3 --retiming
```

### Placer Directive Sweep

For the X3 target (322 MHz), timing closure can be challenging and results vary significantly between different placer directives. The `build_placer_sweep.py` script runs multiple place+route jobs in parallel with different directives and automatically selects the first one that passes timing.

```bash
./fpga/build/build_placer_sweep.py [--skip-synth-opt] [--auto] [--keep-all]
```

**How it works:**
1. Runs synthesis and opt_design once (shared across all runs)
2. Launches 12 parallel Vivado place+route jobs, each with a different placer directive
3. As soon as any run passes timing, kills all remaining jobs and uses that result
4. If no run passes timing, selects the result with the best WNS

**Arguments:**
- `--skip-synth-opt` - Skip synthesis/opt and reuse existing `post_opt.dcp` checkpoint (for re-running sweeps)
- `--auto` - Include ML-predicted Auto_1/2/3 directives (15 total jobs)
- `--all` - Include SSI-specific directives (19 total jobs, only useful for stacked silicon devices)
- `--keep-all` - Keep all work directories instead of cleaning up non-winners
- `--retiming` - Enable global retiming during synthesis

**Examples:**
```bash
# Full sweep (synthesis + 12 parallel place+route jobs)
./fpga/build/build_placer_sweep.py

# Re-run sweep from existing synthesis checkpoint
./fpga/build/build_placer_sweep.py --skip-synth-opt

# Include ML-predicted directives
./fpga/build/build_placer_sweep.py --auto
```

**Default directives tested:**
- Default, Explore, WLDrivenBlockPlacement, EarlyBlockPlacement
- ExtraNetDelay_high, ExtraNetDelay_low
- AltSpreadLogic_high, AltSpreadLogic_medium, AltSpreadLogic_low
- ExtraPostPlacementOpt, ExtraTimingOpt, RuntimeOptimized

Results are printed in a table showing WNS/TNS for each directive, with the winner copied to the main `work/` directory.

### Synthesis Directive Sweep

The `build_synth_sweep.py` script runs synthesis with all available `synth_design` directives in parallel to explore area/timing tradeoffs at the synthesis stage.

```bash
./fpga/build/build_synth_sweep.py [board] [--directives DIR ...] [--retiming] [--clean-after]
```

**How it works:**
1. Compiles hello_world for initial BRAM contents
2. Launches 10 parallel Vivado synthesis jobs, each with a different synthesis directive
3. Reports timing (WNS/TNS) and utilization (LUTs, FFs, BRAM, DSP) for all runs
4. Results are sorted by timing and by area for easy comparison

**Arguments:**
- `board` - Target board (default: x3)
- `--directives` - Run only specific directives (default: all 10)
- `--retiming` - Enable global retiming during synthesis
- `--clean-after` - Delete work directories after reporting results (default: keep all)

**Examples:**
```bash
# Run all synthesis directives for x3
./fpga/build/build_synth_sweep.py x3

# Run with retiming enabled
./fpga/build/build_synth_sweep.py x3 --retiming

# Run only specific directives
./fpga/build/build_synth_sweep.py x3 --directives default AreaOptimized_high PerformanceOptimized

# Clean up after (default keeps all work directories)
./fpga/build/build_synth_sweep.py x3 --clean-after
```

**Directives tested:**
- `default` - Default synthesis
- `runtimeoptimized` - Fewer optimizations, faster runtime
- `AreaOptimized_high` - Aggressive area optimization
- `AreaOptimized_medium` - Moderate area optimization
- `AlternateRoutability` - Improved routability, reduced MUXFs/CARRYs
- `AreaMapLargeShiftRegToBRAM` - Map large shift registers to BRAM
- `AreaMultThresholdDSP` - Lower threshold for DSP inference
- `FewerCarryChains` - Higher threshold for carry chain usage
- `PerformanceOptimized` - Timing optimization at expense of area
- `LogicCompaction` - Pack multipliers into smaller areas

Results are saved in `build/<board>/work_<directive>/` directories with checkpoints and reports.

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

## Build Directives

The build system uses aggressive optimization settings for maximum frequency:

| Stage        | Directive                   | Purpose                                                             |
|--------------|-----------------------------|---------------------------------------------------------------------|
| Synthesis    | `AlternateRoutability`      | Prevent local congestion                                            |
| Synthesis    | `global_retiming on`        | Move registers across logic for timing (optional, via `--retiming`) |
| Optimization | `ExploreWithRemap`          | LUT optimization                                                    |
| Placement    | (varies)                    | `build.py`: AltSpreadLogic_high; `build_placer_sweep.py`: tries 12+ directives |
| Routing      | `AggressiveExplore`         | Maximum routing effort                                              |
| Routing      | `AlternateFlowWithRetiming` | Enable retiming optimizations                                       |

## Customization

### Adding a New Board

1. Create `boards/<board>/` with:
   - `<board>_frost.sv` - Top-level wrapper with clock generation
     - Generate CPU clock and /4 clock using MMCM
     - Instantiate `xilinx_frost_subsystem` (see `boards/xilinx_frost_subsystem.sv`)
   - `constr/<board>.xdc` - Pin assignments and timing constraints
   - `ip/` - Copy Xilinx IP cores from an existing board (Vivado will auto-migrate)
   - `<board>_frost.f` - File list for synthesis

2. Update `build/build.tcl` to handle the new board name

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
- Use `build_placer_sweep.py` to try multiple placer directives in parallel
- Check `build/<board>/work/post_route_timing.rpt` for failing paths
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

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
│   └──────────────┘     │  Multi-Step      │     └───────────┬───────────┘   │
│                        │  pipeline with   │                 │               │
│                        │  per-step        │                 │               │
│                        │  directive select│                 │               │
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

The build script runs the Vivado implementation pipeline and compiles
`hello_world` into board-local initial BRAM contents before synthesis. Each
step uses the configured default directive unless overridden via
`--*-directive` flags. Steps can be started/stopped at any point using
checkpoints.

```bash
# Full build with default directives
./fpga/build/build.py x3

# Choose a specific synthesis directive
./fpga/build/build.py x3 --synth-directive PerformanceOptimized

# Resume from placement with a specific placer directive
./fpga/build/build.py x3 --start-at place --place-directive ExtraTimingOpt

# Synth only
./fpga/build/build.py x3 --stop-after synth
```

Run `./fpga/build/build.py --help` for the full list of directives and options.

## Programming the FPGA

Program the FPGA with the generated bitstream via JTAG.

```bash
./fpga/program_bitstream/program_bitstream.py <board> [remote_host] [--target PATTERN] [--list-targets]
```

**Arguments:**
- `board` - Target board: `x3` or `genesys2`
- `remote_host` - (Optional) Hostname for remote FPGA programming
- `--target PATTERN` - (Optional) Select hardware target by index (0, 1, 2...) or pattern (e.g., serial number)
- `--list-targets` - (Optional) List available hardware targets for this board and exit

**Examples:**
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

Load software into instruction memory without regenerating the bitstream. This enables rapid iteration during development. Applications are compiled automatically before loading—no manual build step required. The board argument sets the correct clock frequency and scales CoreMark iterations appropriately.

```bash
./fpga/load_software/load_software.py <board> <app> [remote_host] [--target PATTERN] [--list-targets]
```

**Arguments:**
- `board` - Target board: `x3` or `genesys2`
- `app` - Application name (run `./fpga/load_software/load_software.py --help` for choices)
- `remote_host` - (Optional) Hostname for remote FPGA
- `--target PATTERN` - (Optional) Select hardware target by index (0, 1, 2...) or pattern (e.g., serial number)
- `--list-targets` - (Optional) List available hardware targets for this board and exit (does not require `app`)

The script compiles the application with the correct clock frequency for the target board and writes the resulting hex file to BRAM starting at address `0x00000000`.

Use a serial terminal configured for 115200 baud, 8 data bits, no parity, and
1 stop bit (8N1) to view the board UART console.

**Examples:**
```bash
# Load coremark on X3 locally
./fpga/load_software/load_software.py x3 coremark

# Load hello_world on remote Genesys2
./fpga/load_software/load_software.py genesys2 hello_world fpga-server.local

# Load FreeRTOS demo on Genesys2
./fpga/load_software/load_software.py genesys2 freertos_demo

# CoreMark-PRO workloads (both boards; heaps live in the 1 GiB cached DDR
# region) take a mandatory mode flag: -v1 runs self-validation, -v0 runs the
# performance configuration with the per-workload iteration counts from
# sw/apps/software_registry.py. Workloads with data in the cached region
# (e.g. radix2's ~800 KiB FFT tables in sw_ddr.txt) are burst-loaded into DDR
# over a dedicated JTAG-AXI master before the low-BRAM image; the loader
# identifies the two JTAG masters automatically and prints its selection.
./fpga/load_software/load_software.py x3 coremark_pro_core -v1
./fpga/load_software/load_software.py genesys2 coremark_pro_radix2 -v1
./fpga/load_software/load_software.py x3 coremark_pro_linear_alg -v0

# List targets for this board (doesn't require app argument)
./fpga/load_software/load_software.py genesys2 --list-targets

# Select specific target by serial number
./fpga/load_software/load_software.py genesys2 hello_world --target 210299A8B4D1
```

## Multiple Hardware Targets

When multiple FPGA boards are connected to the same host, the scripts automatically detect all available hardware targets and filter them based on the board type:

**Automatic vendor filtering:**
- `genesys2` → auto-filters for `Digilent` targets
- `x3` → auto-filters for `Xilinx` targets

This filtering applies to all operations including `--list-targets`. If you have both Digilent and Alveo boards connected, specifying `genesys2` will only show/select Digilent targets and `x3` will only show/select Xilinx targets.

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
     - Instantiate the board's DDR controller subsystem (the `ddr_subsys`
       block design built by `build/<board>_ddr_bd.tcl`) and the FROST
       cache-bridge AXI / `mem_ok` calibration wiring
     - Instantiate `xilinx_frost_subsystem` (see `boards/xilinx_frost_subsystem.sv`),
       passing `ENABLE_CACHED_TIER`/`CACHED_HAS_L2` for the board's hierarchy
       shape (`CACHED_HAS_L2=1` only where UltraRAM exists, e.g. X3)
   - `constr/<board>.xdc` - Pin assignments and timing constraints
   - `<board>_frost.f` - File list for synthesis (include the subsystem and core)

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

4. Add the board's vendor filter to `BOARD_VENDOR_INFO` in `common/hw_target.py`
   so the programming and loading scripts can auto-select its JTAG target

5. See `boards/README.md` for detailed instructions and board comparison

### Adding a New Application

1. Add a `sw/apps/<app>/` directory whose `make` produces `sw.txt` (hex format,
   one 32-bit word per line) and `sw.mem`. An app that places a working set in
   the cached DDR region (built with `MEM_CONFIG=ddr`) also produces a
   `sw_ddr.txt`/`sw_ddr.mem` image that the loader bursts into DDR over a
   second JTAG-AXI master.

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

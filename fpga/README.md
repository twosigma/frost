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
│   │  (hw/rtl/)   │     │       -or-       │     │  (build/<board>/work/)│   │
│   └──────────────┘     │  Sweep Pipeline: │     └───────────┬───────────┘   │
│                        │  synth -> opt -> │                 │               │
│                        │     placer       │                 │               │
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

**For challenging timing closure** (e.g., X3 at 322 MHz), use one of the sweep builds:

```bash
# Full build sweeping ALL stages (synth, opt, placer, router) - maximum exploration
./fpga/build/build_sweep_all.py x3

# Or just sweep placer stage (faster, often sufficient)
./fpga/build/build_with_placer_sweep.py x3
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

For the X3 target (322 MHz), timing closure can be challenging and results vary significantly between different placer directives. The `build_placer_sweep.py` script runs multiple place_design jobs in parallel with different directives.

```bash
./fpga/build/build_placer_sweep.py [--skip-synth-opt] [--auto] [--keep-all]
```

**How it works:**
1. Runs synthesis and opt_design once (shared across all runs)
2. Launches 12 parallel Vivado place_design jobs, each with a different placer directive
3. Selects the result with the best WNS
4. Moves winner to `work/` with `post_place.dcp` ready for the router sweep

**Arguments:**
- `--skip-synth-opt` - Skip synthesis/opt and reuse existing `post_opt.dcp` checkpoint (for re-running sweeps)
- `--auto` - Include ML-predicted Auto_1/2/3 directives (15 total jobs)
- `--all` - Include SSI-specific directives (19 total jobs, only useful for stacked silicon devices)
- `--keep-all` - Keep all work directories instead of cleaning up non-winners
- `--retiming` - Enable global retiming during synthesis

**Examples:**
```bash
# Full sweep (synthesis + opt + 12 parallel place_design jobs)
./fpga/build/build_placer_sweep.py

# Re-run sweep from existing opt checkpoint
./fpga/build/build_placer_sweep.py --skip-synth-opt

# Include ML-predicted directives
./fpga/build/build_placer_sweep.py --auto
```

**Default directives tested:**
- Default, Explore, WLDrivenBlockPlacement, EarlyBlockPlacement
- ExtraNetDelay_high, ExtraNetDelay_low
- AltSpreadLogic_high, AltSpreadLogic_medium, AltSpreadLogic_low
- ExtraPostPlacementOpt, ExtraTimingOpt, RuntimeOptimized

The winner is moved to `build/<board>/work/` with `post_place.dcp` ready for the router sweep.

### Full Build with Placer Sweep

The `build_with_placer_sweep.py` script performs a complete build (synth → opt → place → route → bitstream) but sweeps multiple placer directives in parallel during placement. This is the recommended approach when you want a complete bitstream with placer exploration.

```bash
./fpga/build/build_with_placer_sweep.py [board] [--directives DIR ...] [--router-directive DIR] [--skip-synth-opt] [--retiming] [--keep-all]
```

**How it works:**
1. Compiles hello_world for initial BRAM contents
2. Runs synthesis and opt_design once (shared starting point)
3. Launches 12 parallel Vivado place_design jobs, each with a different placer directive
4. Selects the placement with the best WNS
5. Continues with route_design using the winning placement
6. Runs post-route phys_opt (AggressiveExplore + AlternateFlowWithRetiming)
7. Generates final bitstream

**Arguments:**
- `board` - Target board (default: x3)
- `--directives` - Run only specific placer directives (default: all 12 non-SSI)
- `--router-directive` - Router directive to use (default: AggressiveExplore)
- `--skip-synth-opt` - Skip synthesis/opt, use existing `post_opt.dcp` checkpoint
- `--auto` - Include ML-predicted Auto_1/2/3 placer directives (15 total)
- `--all` - Include SSI-specific placer directives (19 total)
- `--retiming` - Enable global retiming during synthesis
- `--keep-all` - Keep all placer work directories (don't clean up non-winners)

**Examples:**
```bash
# Full build with placer sweep (12 parallel placer jobs, then route)
./fpga/build/build_with_placer_sweep.py x3

# Use existing synthesis/opt checkpoint
./fpga/build/build_with_placer_sweep.py x3 --skip-synth-opt

# Specify router directive
./fpga/build/build_with_placer_sweep.py x3 --router-directive MoreGlobalIterations

# Run only specific placer directives
./fpga/build/build_with_placer_sweep.py x3 --directives Explore AltSpreadLogic_high ExtraTimingOpt

# Enable retiming and include ML-predicted directives
./fpga/build/build_with_placer_sweep.py x3 --retiming --auto
```

**Output:**
- Prints results table showing WNS/TNS for each placer directive
- Produces final bitstream at `build/<board>/work/<board>_frost.bit`
- Reports post-route timing summary

**Comparison with other scripts:**

| Script | Sweeps | Produces Bitstream |
|--------|--------|-------------------|
| `build.py` | None (single run) | Yes |
| `build_placer_sweep.py` | Placer only | No (stops after placement) |
| `build_with_placer_sweep.py` | Placer only | Yes (continues through routing) |
| `build_sweep_all.py` | All 4 stages | Yes (sweeps everything) |
| Full sweep pipeline | All stages | Yes (manual 4-step process) |

Use `build_with_placer_sweep.py` when you want placer exploration with a complete build in one command.
Use `build_sweep_all.py` when you want maximum exploration of all stages in a single command.

### Full Build with All Sweeps

The `build_sweep_all.py` script performs a complete build sweeping ALL four stages in parallel. This is the most comprehensive approach for timing closure.

```bash
./fpga/build/build_sweep_all.py [board] [--synth-directives ...] [--opt-directives ...] [--placer-directives ...] [--router-directives ...] [--retiming] [--keep-all]
```

**How it works:**
1. **Synthesis sweep**: 10 synth_design directives in parallel → pick best WNS
2. **Opt sweep**: 6 opt_design directives in parallel → pick best WNS
3. **Placer sweep**: 12 place_design directives in parallel → pick best WNS
   - Applies overconstraining (+1.0ns) before placement
   - Runs phys_opt_design after placement
4. **Router sweep**: 8-9 route_design directives in parallel → pick best WNS
   - Removes overconstraining before routing
   - Runs two phys_opt_design passes after routing
5. Generates final reports and bitstream

**Arguments:**
- `board` - Target board (default: x3)
- `--synth-directives` - Specific synthesis directives (default: all 10)
- `--opt-directives` - Specific opt_design directives (default: all 6)
- `--placer-directives` - Specific placer directives (default: all 12 non-SSI)
- `--router-directives` - Specific router directives (default: all 8-9)
- `--all-placer` - Include SSI-specific placer directives (19 total)
- `--auto-placer` - Include ML-predicted Auto_1/2/3 placer directives
- `--retiming` - Enable global retiming during synthesis
- `--keep-all` - Keep all work directories (don't clean up non-winners)

**Examples:**
```bash
# Full sweep of all stages (10 + 6 + 12 + 9 = 37 parallel jobs across stages)
./fpga/build/build_sweep_all.py x3

# With retiming enabled
./fpga/build/build_sweep_all.py x3 --retiming

# Limit to specific directives for faster runs
./fpga/build/build_sweep_all.py x3 \
    --synth-directives PerformanceOptimized default \
    --opt-directives ExploreWithRemap Explore \
    --placer-directives AltSpreadLogic_high ExtraTimingOpt Explore \
    --router-directives AggressiveExplore Explore

# Include all placer directives including ML-predicted
./fpga/build/build_sweep_all.py x3 --all-placer --auto-placer
```

**Output:**
- Prints results table for each stage showing WNS/TNS for all directives
- Reports winning directive for each stage
- Produces final bitstream at `build/<board>/work/<board>_frost.bit`

**Parallel job count by stage:**
| Stage | Default Jobs | With --all-placer | Notes |
|-------|--------------|-------------------|-------|
| Synthesis | 10 | 10 | |
| Opt | 6 | 6 | |
| Placer | 12 | 19 | +3 more with --auto-placer |
| Router | 9 (x3) / 8 (others) | 9/8 | x3 includes AlternateCLBRouting |

### Full Sweep Pipeline (Manual)

For maximum timing closure probability, you can also run all four sweep scripts in sequence. Each script picks the best result and sets up the checkpoint for the next stage:

```bash
# 1. Synth sweep - find best synthesis directive
./fpga/build/build_synth_sweep.py x3

# 2. Opt sweep - find best opt_design directive (uses post_synth.dcp from step 1)
./fpga/build/build_opt_sweep.py x3 --skip-synth

# 3. Placer sweep - find best placer directive (uses post_opt.dcp from step 2)
./fpga/build/build_placer_sweep.py x3 --skip-synth-opt

# 4. Router sweep - find best router directive (uses post_place.dcp from step 3)
./fpga/build/build_router_sweep.py x3 --skip-place
```

Each script prints the suggested next command when it completes.

### Synthesis Directive Sweep

The `build_synth_sweep.py` script runs synthesis with all available `synth_design` directives in parallel to explore area/timing tradeoffs at the synthesis stage.

```bash
./fpga/build/build_synth_sweep.py [board] [--directives DIR ...] [--retiming] [--keep-all]
```

**How it works:**
1. Compiles hello_world for initial BRAM contents
2. Launches 10 parallel Vivado synthesis jobs, each with a different synthesis directive
3. Reports timing (WNS/TNS) and utilization (LUTs, FFs, BRAM, DSP) for all runs
4. Selects the winner by best WNS (then TNS as tiebreaker)
5. Moves winner to main `work/` directory, cleans up others

**Arguments:**
- `board` - Target board (default: x3)
- `--directives` - Run only specific directives (default: all 10)
- `--retiming` - Enable global retiming during synthesis
- `--keep-all` - Keep all work directories (don't clean up non-winners)

**Examples:**
```bash
# Run all synthesis directives for x3
./fpga/build/build_synth_sweep.py x3

# Run with retiming enabled
./fpga/build/build_synth_sweep.py x3 --retiming

# Run only specific directives
./fpga/build/build_synth_sweep.py x3 --directives default AreaOptimized_high PerformanceOptimized

# Keep all work directories for analysis
./fpga/build/build_synth_sweep.py x3 --keep-all
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

The winner is moved to `build/<board>/work/` with `post_synth.dcp` ready for the opt sweep.

### Optimization Directive Sweep

The `build_opt_sweep.py` script runs `opt_design` with all available directives in parallel to find the best optimization strategy.

```bash
./fpga/build/build_opt_sweep.py [board] [--directives DIR ...] [--skip-synth] [--retiming] [--keep-all]
```

**How it works:**
1. Runs synthesis once (or uses existing `post_synth.dcp` with `--skip-synth`)
2. Launches 6 parallel Vivado opt_design jobs, each with a different directive
3. Reports timing (WNS/TNS) and utilization (LUTs, FFs, BRAM, DSP) for all runs
4. Selects the winner by best WNS (then TNS as tiebreaker)
5. Moves winner to main `work/` directory (preserving `post_synth.*` files), cleans up others

**Arguments:**
- `board` - Target board (default: x3)
- `--directives` - Run only specific directives (default: all 6)
- `--skip-synth` - Skip synthesis, use existing `post_synth.dcp` checkpoint
- `--retiming` - Enable global retiming during synthesis
- `--keep-all` - Keep all work directories (don't clean up non-winners)

**Examples:**
```bash
# Full run (synthesis + parallel opt_design)
./fpga/build/build_opt_sweep.py x3

# Use existing synthesis checkpoint (from synth_sweep or previous run)
./fpga/build/build_opt_sweep.py x3 --skip-synth

# Run only specific directives
./fpga/build/build_opt_sweep.py x3 --directives Explore ExploreWithRemap ExploreArea
```

**Directives tested:**
- `Default` - Default optimization
- `Explore` - Run additional optimizations to improve results
- `ExploreArea` - Explore with resynth_area to reduce LUTs
- `ExploreWithRemap` - Explore with aggressive remap to compress logic levels
- `ExploreSequentialArea` - Explore with resynth_seq_area to reduce registers
- `RuntimeOptimized` - Fewest optimizations, faster runtime

The winner is moved to `build/<board>/work/` with `post_opt.dcp` ready for the placer sweep.

### Router Directive Sweep

The `build_router_sweep.py` script runs `route_design` with all available directives in parallel to find the best routing strategy.

```bash
./fpga/build/build_router_sweep.py [board] [--directives DIR ...] [--skip-place] [--ultrascale] [--keep-all]
```

**How it works:**
1. Runs synthesis, opt_design, and place_design once (or uses existing `post_place.dcp` with `--skip-place`)
2. Launches 8-9 parallel Vivado route_design jobs, each with a different directive
3. Selects the winner by timing met first, then best WNS
4. Moves winner to main `work/` directory (preserving earlier checkpoints), generates bitstream

**Arguments:**
- `board` - Target board (default: x3)
- `--directives` - Run only specific directives (default: all router directives)
- `--skip-place` - Skip synth/opt/place, use existing `post_place.dcp` checkpoint
- `--ultrascale` - Include UltraScale-only directives (auto-enabled for x3)
- `--retiming` - Enable global retiming during synthesis
- `--keep-all` - Keep all work directories (don't clean up non-winners)

**Examples:**
```bash
# Full run (synth + opt + place + parallel route_design)
./fpga/build/build_router_sweep.py x3

# Use existing placement checkpoint (from placer_sweep or previous run)
./fpga/build/build_router_sweep.py x3 --skip-place

# Run only specific directives
./fpga/build/build_router_sweep.py x3 --directives Explore AggressiveExplore NoTimingRelaxation
```

**Directives tested:**
- `Default` - Default routing
- `Explore` - Explore different critical path routes after initial route
- `AggressiveExplore` - Further expand exploration with aggressive thresholds
- `NoTimingRelaxation` - Prevent timing relaxation, run longer to meet constraints
- `MoreGlobalIterations` - Use detailed timing analysis throughout all stages
- `HigherDelayCost` - Emphasize delay over iterations in cost functions
- `AdvancedSkewModeling` - More accurate skew modeling for high-skew clocks
- `RuntimeOptimized` - Fewest iterations, faster runtime
- `AlternateCLBRouting` - (UltraScale only) Alternate algorithms for congestion

The winner is moved to `build/<board>/work/` with the final bitstream.

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

## Build Directives

The build system uses aggressive optimization settings for maximum frequency:

| Stage        | Directive                   | Purpose                                                             |
|--------------|-----------------------------|---------------------------------------------------------------------|
| Synthesis    | `PerformanceOptimized`      | Default; `build_synth_sweep.py` tries 10 directives                 |
| Synthesis    | `global_retiming on`        | Move registers across logic for timing (optional, via `--retiming`) |
| Optimization | `ExploreWithRemap`          | Default; `build_opt_sweep.py` tries 6 directives                    |
| Placement    | `AltSpreadLogic_high`       | Default; `build_placer_sweep.py` tries 12+ directives               |
| Routing      | `AggressiveExplore`         | Default; `build_router_sweep.py` tries 8-9 directives               |
| Post-Route   | `AlternateFlowWithRetiming` | Post-route phys_opt with retiming                                   |

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

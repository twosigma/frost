# ASIC flow

This directory runs FROST through
[OpenROAD-flow-scripts](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts)
(ORFS) on its Nangate45 platform: the FreePDK45 process with the Nangate
Open Cell Library. Yosys synthesizes `cpu_and_mem`; OpenROAD floorplans,
places, builds the clock trees, and routes it; KLayout writes the GDS.
OpenSTA reports timing after each stage. FreePDK45 is not a manufacturable
process, so the flow shows that the RTL maps onto standard cells and
estimates its area and timing. It does not replace a foundry flow.

The large memories are mocked: each memory larger than 4,096 bits keeps a
single row, built from flip-flops, until an SRAM macro takes its place. The
area therefore leaves out most of the storage, and paths through the memories
do not have SRAM timing. The threshold also catches some shallow, wide
arrays, such as queues and register-file banks, that an ASIC would build from
flip-flops, so the logic area is low as well. The summary lists every mocked
memory with its dimensions.

## Running

From the repository root:

```bash
./asic/orfs.py run                    # the whole flow, with a thread per CPU
./asic/orfs.py run --num-cores 16     # limit the tools' threads
./asic/orfs.py run --target grt       # stop after synth, floorplan, place, cts, grt, or route
./asic/orfs.py run --from route       # rerun detailed routing and finishing from asic/build
./asic/orfs.py run --clock-period 1.6 # set the core clock period in ns
./asic/orfs.py summary                # summarize asic/build again
./asic/orfs.py paths --stage grt      # report a stage's setup paths by block
```

The script needs Docker and the `frost` image (see the
[tooling guide](../docs/tooling.md)). Its first run pulls the ORFS image.
`--frost-image`, or `FROST_DOCKER_IMAGE`, names another frost image. Both
images run as the invoking user, with the checkout mounted at `/workspace`,
and everything the flow writes goes under `asic/build`, which git ignores.
With 16 threads the whole flow takes about three hours. Detailed routing
needs about 18 GB of memory, and the stages' databases about 15 GB of disk.

`run` has three steps:

1. In the frost image, `orfs.py prepare` compiles `hello_world` for the data
   memory's `$readmemh` image, converts the NIC and MAC/PCS sources with sv2v
   as [`tests/test_run_yosys.py`](../tests/test_run_yosys.py) does, and
   writes the source list from [`hw/rtl/frost.f`](../hw/rtl/frost.f) to
   `asic/build/sources.mk`.
2. In the ORFS image, ORFS's Makefile runs the flow with
   [`config.mk`](config.mk). Make reruns only the stages whose input files
   changed since the last run. It does not track `config.mk`, so delete
   `asic/build` after changing the configuration, or rerun the affected
   stages with `--from`. Nor does it track the core clock period, so `run`
   refuses to continue a build made with another period, and `--from` keeps
   the build's period.
3. `make elapsed` and the flow's metrics become `asic/build/summary.md`.

The stages follow ORFS's make targets: `grt` is global routing and `route`
is detailed routing. `--from` skips the first step and reruns every stage
from the one it names, whatever the files' timestamps, from the results of
the stage before it.

| Output in `asic/build` | Contents |
| --- | --- |
| `summary.md` | Core clock period, cell count and area, worst slack for each clock, elapsed time and peak memory for each step, and the mocked memories |
| `paths_<stage>.md` | The setup report of `paths` for one stage |
| `orfs.log` | Output of both containers |
| `logs/nangate45/frost/base/` | A log and a metrics file for each step |
| `reports/nangate45/frost/base/` | Timing, DRC, and congestion reports, including `6_clock_slack.rpt` and the path tables of `paths` |
| `results/nangate45/frost/base/` | The netlists and OpenROAD databases of each stage, `6_final.gds`, and `6_final.spef` |

## Design

| Setting | Value |
| --- | --- |
| Top module | `cpu_and_mem`, with `ENABLE_CACHED_TIER=1` and `USE_BEHAVIORAL_DDR=0`, so the cached tier ends at the DDR AXI port; other parameters keep their defaults |
| Defines | `SYNTHESIS`; not `FROST_XILINX_PRIMS`, so every block uses its portable version |
| Memories | `SYNTH_MOCK_LARGE_MEMORIES=1`: memories over 4,096 bits keep one row; smaller ones become flip-flops |
| Die size | `CORE_UTILIZATION=40`: the core is sized so that the synthesized cells fill 40% of it |
| Placement density | `PLACE_DENSITY_LB_ADDON=0.20`, since the platform's default density, 0.30, is below the utilization |
| Equivalence check | `LEC_CHECK=0`: ORFS's formal check of the final netlist against synthesis needs over 40 GB of memory on this design |

[`canonicalize.tcl`](canonicalize.tcl) edits the elaborated design before
synthesis. It keeps the 10G receive parser's state encoding, as the Yosys
checks do. It also clocks the data memory's program-loading port from `i_clk`
instead of `i_clk_div4`: the data memory (`tdp_bram_dc_byte_en`) is written
from both clocks, and flip-flops cannot implement a memory with two write
clocks, even mocked as one row. A two-port SRAM macro removes the need for
this. [`clock_slack.tcl`](clock_slack.tcl) runs after the final report and
writes each clock's worst setup and hold slack.

## Timing constraints

[`constraint.sdc`](constraint.sdc) defines one clock per clock input:

| Clock | Port | Period | Source |
| --- | --- | --- | --- |
| `core_clk` | `i_clk` | 3.103 ns (322.265625 MHz), or `--clock-period` | The X3 CPU clock |
| `core_clk_div4` | `i_clk_div4` | Four core periods, 12.412 ns | The program-loading port's clock, a quarter of the CPU clock |
| `nic_tx_clk` | `i_nic_tx_clk` | 6.206 ns (161.1328125 MHz) | The X3 transceiver's TX user clock |
| `nic_rx_clk` | `i_nic_rx_clk` | 6.206 ns | The X3 transceiver's recovered RX user clock |
| `jtag_tck` | `i_jtag_tck` | 100 ns (10 MHz) | The JTAG TAP inside `cpu_and_mem` (`DEBUG_JTAG_TAP=1`) |

`core_clk_div4` is derived from the core clock, as on the X3, so the two are
related: both rise at time 0, and OpenSTA times the paths between them, as
Vivado does on the X3. The debug slice writer's crossing to the
program-loading port depends on that timing: its `dc_fifo` passes binary
pointers through synchronizers whose first stage must meet timing. The NIC's
TX and RX clocks and the JTAG clock are asynchronous to the core clocks and
to each other, and the RTL synchronizes those crossings with Gray-coded FIFOs,
two-flop synchronizers, and handshakes.

Inputs and outputs take a fifth of their clock's period outside the design:
the program-loading port on `core_clk_div4`, the raw transceiver data on the
NIC clocks, the JTAG pins on `jtag_tck`, and the other ports on `core_clk`.
The asynchronous levels (`i_jtag_trst_n`, the NIC's clock-presence and PHY
status inputs) are not timed. A missed target does not stop the flow: ORFS's
repair steps after synthesis work toward it with their default effort, and
synthesis maps the same netlist for any target
([Finding the fmax](#finding-the-fmax)).

The mocked memories add paths between the two core clocks that SRAM macros do
not have: the instruction memory's single row is written on `i_clk_div4` and
read by registers on `i_clk`, and the data memory's reclocked programming
port meets the `i_clk_div4` logic with one core cycle. The flow times and
repairs them like any other path.

## Finding the fmax

A target the design cannot meet shows how fast it can run and which paths
stop it. `--clock-period` sets the core clock period in ns, below 100 ns with
at most four decimals; the quarter-rate clock and the I/O delays follow it.
With a period shorter than the design reaches, ORFS's repair steps resize,
buffer, clone, and swap pins on the failing paths until no move helps, and
the worst slack that remains gives the fmax, 1 / (period - WNS). `paths`
reports the setup paths of one stage's database:

```bash
./asic/orfs.py run --target grt --num-cores 16 --clock-period 1.6
./asic/orfs.py paths --stage place    # or cts, grt, final
```

`paths` runs [`critical_paths.tcl`](critical_paths.tcl) in the ORFS image
with the parasitics and clocks of the stage's own report, logs OpenROAD to
`asic/build/logs/paths/`, and writes `asic/build/paths_<stage>.md`:

| Table | Contents |
| --- | --- |
| Worst slack by capture clock | Endpoints, failing endpoints, WNS, and TNS of each clock |
| Paths between core clock registers | The worst path between registers for each pair of launching and capturing core clocks, and the fmax it allows |
| Core clock endpoints by block | The blocks whose registers have the worst core clock slack |
| Core clock paths by start and end block | Each endpoint's worst path, grouped by the blocks of its startpoint and endpoint, with its cells and notes on ports, the quarter-rate clock, and mocked memories |

A block is the first three levels of a register's instance name. The fmax
counts only paths between registers: the I/O delays are a fifth of the period
on each side of a port, so a port's slack shrinks faster than the period. The
tables behind the report are in `reports/nangate45/frost/base/`:
`<database>_paths.tsv` has the worst path to every endpoint,
`<database>_register_paths.tsv` the worst path for each pair of core clocks,
`<database>_worst_paths.json` the worst 100 core clock paths pin by pin, and
`<database>_worst_paths.rpt` the worst five paths of each clock.

Synthesis does not depend on the period. ORFS hands the period to ABC as a
delay target, but the ABC script it runs maps for delay without reading the
target, so every period gives the same netlist: the 1.6 ns build's
`1_synth.odb` matches the default build's byte for byte. The period steers
the steps after synthesis, which resize gates in the floorplan, weight the
global placement, and repair the paths after clock tree synthesis and global
routing.

### Results

These runs used the RTL of commit `e6eb7a47`, eight threads each, and ORFS's
default repair settings; the repair after global routing took 12 minutes at
1.6 ns, and the 1.6 ns run took 2.7 hours through global routing. The core
WNS, TNS, and failing endpoints are those of the core clock's endpoints, and
the fmax is that of the worst path between registers. A met target bounds the
fmax from below, since the repairs stop once a path meets it.

| Core period | Stage | Core WNS (ns) | Core TNS (ns) | Failing core endpoints | fmax (MHz) |
| --- | --- | ---: | ---: | ---: | ---: |
| 1.6 ns | Detailed placement | -0.620 | -94.4 | 982 | 450.3 |
| 1.6 ns | Clock tree synthesis | -0.510 | -54.3 | 2,231 | 474.0 |
| 1.6 ns | Global routing | -0.527 | -15.6 | 217 | 470.1 |
| 2.2 ns | Detailed placement | -0.227 | -23.7 | 130 | 448.3 |
| 2.2 ns | Clock tree synthesis | 0.005 | 0 | 0 | at least 455.6 |
| 2.2 ns | Global routing | 0.001 | 0 | 0 | at least 454.8 |
| 3.103 ns | Global routing | 0.453 | 0 | 0 | at least 377.3 |

The 2.2 ns run's worst core endpoint after placement is the program-loading
port's input to the data memory; its worst path between registers has -0.031
ns. Both over-constrained runs fail on the same path after placement, with
fmax estimates 2 MHz apart, and the 2.2 ns run meets its target after clock
tree synthesis, and after global routing with 0.001 ns to spare on that path.

| Stage | 3.103 ns cells | 3.103 ns area (um^2) | 2.2 ns cells | 2.2 ns area (um^2) | 1.6 ns cells | 1.6 ns area (um^2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Synthesis | 704,111 | 1,357,860 | 704,111 | 1,357,860 | 704,111 | 1,357,860 |
| Detailed placement | 672,470 | 1,337,590 | 675,543 | 1,341,860 | 692,830 | 1,368,670 |
| Clock tree synthesis | 711,783 | 1,379,050 | 717,028 | 1,385,060 | 736,807 | 1,415,490 |
| Global routing | 712,593 | 1,380,190 | 717,615 | 1,385,960 | 737,252 | 1,416,420 |

Asking for 1.6 ns costs 3.5% more cells and 2.6% more area after global
routing than the default target, and 2.2 ns costs 0.7% and 0.4%.

### What limits the fmax

At 1.6 ns the worst path after every stage runs through the integer ALU's bit
count, Zbb's `cpop`: from the INT RS issue register that holds the operand,
through the population count and the result multiplexers, into the ALU
adapter's result register. Yosys merges the RTL's tree of small adders
(`cpop32` in `riscv_pkg.sv`) into a carry-save sum, and ORFS maps adders onto
the library's full-adder and half-adder cells before ABC runs (the platform's
`ADDER_MAP_FILE`), so ABC cannot restructure them. After global routing the
path passes through 14 of those cells, which take 1.43 ns of its 1.95 ns
between the registers. Both integer ALUs have it. Synthesized alone, the
64-bit count takes 1.21 ns through the full-adder cells and 0.82 ns when ABC
maps the same logic, which costs 15% more area.

The table gives the time each family needs, the core period less the slack of
its worst path, after global routing. The 3.103 ns run repairs a path only
until it meets 3.103 ns, so its column shows how each family comes out of
synthesis and placement, and the 1.6 ns column what the repairs reach.

| Family | Worst path | Cells at 1.6 ns | 3.103 ns run (ns) | 1.6 ns run (ns) |
| --- | --- | ---: | ---: | ---: |
| ALU bit count | INT RS operand to ALU adapter result | 26 | 2.42 | 2.13 |
| Multiplier, first stage | Multiplier operands to the 27 x 35 tile products | 32 | 2.26 | 1.86 |
| ROB to reservation stations | ROB head pointer to the INT RS dispatch-full flag | 28 | 2.35 | 1.67 |
| PC and fetch prediction loop | `pc_controller` PC to PC | 32 | 2.04 | 1.63 |
| Store queue early address repair | Repair immediate to `sq_address` | 31 | 2.00 | 1.59 |
| Wakeup to MEM RS payload | CDB valid to the MEM RS issue registers | - | 2.65 | 1.60 or less |
| Decoded queue to INT RS | RAT source address to INT RS source values | 24 | 2.16 | 1.54 |
| INT RS wakeup to MUL RS | CDB tag to MUL RS issue registers | 21 | 1.97 | 1.38 |
| L2 response to L1 MSHR | L2 MSHR response to L1 MSHR state | 19 | 1.40 | 1.32 |
| Data memory read to load queue | Data memory read register to LQ data | 14 | 1.07 | 0.97 |

One family holds the fmax back. The multiplier's first stage comes next:
`dsp_tiled_multiplier_unsigned` splits the product into 27 x 35 tiles that
the X3 maps to DSP48E2 slices, and here each tile is a gate-level multiplier.
After those two, the rest of the core comes within 0.07 ns of the 1.6 ns
target: after global routing, 217 core endpoints fail, 96 of them in the ALU
adapters and the multiplier, and the worst path between registers among the
rest needs 1.67 ns. That says the pipeline stages are close to one another
apart from the arithmetic; it does not say the rest of the core tops out near
600 MHz, since the repairs stop working on a path once it meets the target.
The worst path at the default target, from the CDB through the MEM RS's
wakeup and select to its payload read, needs 2.65 ns there and meets 1.6 ns
here, so sizing and buffering fix it; the bit count needs 2.42 ns at the
default target and comes down only to 2.13 ns. The worst 200 paths between
registers after global routing have a median of 34 cells, 7 of them buffers
or inverters.

The full-adder cells decide the bit count's place at the top. A third 1.6 ns
run with the platform's adder map turned off (`ADDER_MAP_FILE` empty in
`config.mk`, so that ABC maps the adders too), taken through clock tree
synthesis, reaches 505.8 MHz there instead of 474.0, and its bit count needs
1.61 ns instead of 2.11. The multiplier's first stage limits that build at
1.98 ns, and the FP shim, the store queue's early address repair, pre-decode
to decode, and the NIC's MAC follow within 0.15 ns, each about 0.2 ns slower
than with the full-adder cells; 2,692 core endpoints fail after clock tree
synthesis instead of 2,231. That build has 1.2% more cells after synthesis
and 0.6% less area. Without the full-adder cells, then, no single family
stands out, but the families behind the multiplier are slower.

### What the mocked memories hide

Each mocked memory is one row of flip-flops, so these timings leave out what
the memories cost. A synchronous read here is a flip-flop feeding the read
register, where an SRAM macro would put its output; the macro's
clock-to-output time replaces the flip-flop's. The paths after those read
registers have room at 1.6 ns: 0.63 ns from the data memory's read register to
the load queue, and 0.99 ns from the L1 data array's. ORFS's `fakeram45` model
of a 2,048 x 39 array, as one reference, gives 0.435 ns from the clock to the
output.

The shallow arrays that the threshold also catches are distributed RAMs,
read without a clock, which the X3 builds from LUTs: the BTB and TAGE tables,
the ROB's allocation banks, the INT RS's branch payload banks, the decoded
queue, and the load queue's L0 data. Mocking removes their read multiplexers
and the address paths into them; the ROB's value banks and the other arrays
of 4,096 bits or less keep theirs. In this library, a 256 x 55 flip-flop
array like a BTB tag table takes 0.48 ns from its read address to its data
before wiring, and a 512 x 14 TAGE table 0.50 ns. The PC loop reads the BTB
and TAGE tables, so this flow understates the X3's worst family: here the path
from the BTB update table's row to the PC needs 1.40 ns, and a real table adds
its read in front.

The paths that end at a mocked row are timed (the worst, a write to the L0
data RAM, has 0.12 ns of slack at 1.6 ns), but not the write decoders, banking,
and ports that real memories add, and real memories would change placement
and congestion around them. The worst port path at 1.6 ns, a register to
`o_fifo0_wr_en` with its 0.32 ns output delay, misses by 0.11 ns, and the
paths that cross to or from `core_clk_div4` have at least 0.29 ns of slack.
All of these numbers use the typical corner without derating or clock
uncertainty, and global routing's parasitics.

### Compared with the X3

The X3's critical families are the PC and fetch prediction loop, INT RS
wakeup to the MUL RS, the data memory read to the load queue, the ROB's values
to the reservation stations, the store queue's early address repair, the
decoded queue to the INT RS, and the L2 response to the L1 MSHR, all in the
table above.
Here the repairs bring five of them to between 1.32 and 1.67 ns: the ROB to
the reservation stations, the early address repair, the decoded queue (whose
four-entry packet array is mocked, leaving out a small read multiplexer),
INT RS wakeup, and the L2 response. The two families that set the ASIC fmax
are arithmetic, which the X3 builds from carry chains and DSP slices, so the
results are consistent with FPGA-shaped arithmetic becoming expensive in this
mapping. The PC loop reads the BTB and TAGE tables and the load path reads the
data memory, all mocked here, so this flow cannot rank those two families
until SRAM macros or real arrays replace the mocks.

## CI

Two chained jobs run the flow on every pull request and every push to `main`.
`ASIC Flow (synthesis to global routing)` runs
`./asic/orfs.py run --target grt` and passes the global routing database to
`ASIC Flow (detailed routing to GDS)`, which runs
`./asic/orfs.py run --from route`. The second job's step summary shows
`summary.md`, and its `asic-flow-results` artifact holds the logs, reports,
and summary of both jobs. The routing job adds swap space for detailed
routing, and both jobs delete preinstalled toolchains to make room for the
databases.

## The ORFS image

[`orfs.py`](orfs.py) pins the image by digest:
`openroad/orfs:26Q3-705-gecb3cfdeb@sha256:6da005d1c3447799f7401215174196c75ba9ec7e28417624d0c20225f85d594c`.
It is the ORFS 26Q4 quarterly release, commit `ecb3cfdeb`, which Docker Hub
publishes under its `git describe` tag. It contains Yosys 0.68, OpenROAD
`c487fc70`, and KLayout 0.30.12; the frost image's Yosys 0.69 reads the same
sources. To update the image, change `ORFS_IMAGE` and run the whole flow.

# ASIC flow

This directory runs FROST through
[OpenROAD-flow-scripts](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts)
(ORFS) on its Nangate45 platform: the FreePDK45 process with the Nangate
Open Cell Library. Yosys synthesizes `cpu_and_mem`; OpenROAD floorplans,
places, builds the clock trees, and routes it; KLayout writes the GDS.
OpenSTA reports timing after each stage. FreePDK45 is not a manufacturable
process, so the flow shows that the RTL maps onto standard cells and SRAM
macros and estimates its area and timing. It does not replace a foundry flow.

The memories behind the RAM wrappers in
[`hw/rtl/lib/ram`](../hw/rtl/lib/ram) are dual-port SRAM macros that
[OpenRAM](https://github.com/VLSIDA/OpenRAM) generates for FreePDK45: the
caches' data, the L1D's and the L2's tags, the L2's replacement state, the
data memory, the NIC's FIFOs, and the BTB's slot-2 payload tables
([SRAM macros](#sram-macros)). Arrays of 4,096 bits or less, such as the
L1I's tags and the L1s' replacement state, become flip-flops. The other
memories larger than 4,096 bits are mocked: each keeps a single row, built
from flip-flops. They are the instruction memory, which infers its own
arrays in `imem_predecode.sv`; the NIC's frame and packet buffers, which the
NIC infers; and the arrays read without a clock, such as the BTB tags, the
TAGE tables, and banks of the ROB and the INT RS, which an ASIC would build
from flip-flops or latches rather than SRAM. Their area and the paths through
them are therefore missing. The summary lists the macros and every mocked
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
With 16 threads the whole flow takes about three and a quarter hours.
Global routing needs about 39 GB of memory, the final report 33 GB, and
detailed routing 31 GB, and the stages' databases about 29 GB of disk.

`run` has three steps:

1. In the frost image, `orfs.py prepare` converts the NIC and MAC/PCS
   sources with sv2v as [`tests/test_run_yosys.py`](../tests/test_run_yosys.py)
   does, and writes the source list from [`hw/rtl/frost.f`](../hw/rtl/frost.f)
   to `asic/build/sources.mk`. No memory reads a `$readmemh` image here: the
   SRAM macros have no initial contents, and the instruction memory reads its
   images only outside Yosys.
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
| `summary.md` | Core clock period, cell and macro counts and areas, worst slack for each clock, elapsed time and peak memory for each step, the SRAM macros, and the mocked memories |
| `paths_<stage>.md` | The setup report of `paths` for one stage |
| `orfs.log` | Output of both containers |
| `logs/nangate45/frost/base/` | A log and a metrics file for each step |
| `reports/nangate45/frost/base/` | Timing, DRC, and congestion reports, including `6_clock_slack.rpt` and the path tables of `paths` |
| `results/nangate45/frost/base/` | The netlists and OpenROAD databases of each stage, `6_final.gds`, and `6_final.spef` |

## Design

| Setting | Value |
| --- | --- |
| Top module | `cpu_and_mem`, with `ENABLE_CACHED_TIER=1` and `USE_BEHAVIORAL_DDR=0`, so the cached tier ends at the DDR AXI port; other parameters keep their defaults |
| Defines | `SYNTHESIS`, and `FROST_SRAM_MACROS` for the [SRAM macros](#sram-macros); not `FROST_XILINX_PRIMS`, so every block uses its portable version |
| Memories | The RAM wrappers' memories are SRAM macros. `SYNTH_MOCK_LARGE_MEMORIES=1`: other memories over 4,096 bits keep one row; smaller ones become flip-flops |
| Die size | `DIE_AREA`: 9.6 by 7.315 mm; `CORE_AREA` leaves 15 um on each side. The core fits the macro placement |
| Macro placement | [`macro_placement.tcl`](macro_placement.tcl) (`MACRO_PLACEMENT_TCL`) |
| Power grid | The platform's, with [`sram_power.tcl`](sram_power.tcl) (`PRE_PDN_TCL`) connecting the macros' supply pins and [`check_power_grid.tcl`](check_power_grid.tcl) (`POST_PDN_TCL`) checking that everything placed reaches the grid |
| Placement density | `PLACE_DENSITY_LB_ADDON=0.20`: the lower bound plus a fifth of the remaining room |
| Clock tree synthesis | `CTS_ARGS`: ORFS's default arguments, with the clock ports' nets as the roots ([Timing constraints](#timing-constraints)) |
| Repairs after global routing | `SKIP_INCREMENTAL_REPAIR=1`: on this die they take hours, more than a CI job allows; the repairs after placement and clock tree synthesis still run |
| Equivalence check | `LEC_CHECK=0`: ORFS's formal check of the final netlist against synthesis needs over 40 GB of memory on this design |

[`canonicalize.tcl`](canonicalize.tcl) edits the elaborated design before
synthesis: it keeps the 10G receive parser's state encoding, as the Yosys
checks do. [`clock_slack.tcl`](clock_slack.tcl) runs after the final report
and writes each clock's worst setup and hold slack.

## SRAM macros

[`config.mk`](config.mk) defines `FROST_SRAM_MACROS`, as do the simulations
of the macros' models below; the FPGA build and the other simulations never
do. Under it, the RAM wrappers in
[`hw/rtl/lib/ram`](../hw/rtl/lib/ram) keep their storage in two modules:
[`frost_sram_1w1r`](sram/frost_sram_1w1r.sv), with a write port and a read
port, for `sdp_block_ram`, `sdp_block_ram_dc`, `sdp_ram_byte_en`, and
`sdp_packed_tag_uram`; and [`frost_sram_2rw`](sram/frost_sram_2rw.sv), with
two read and write ports on their own clocks, for `tdp_bram_dc_byte_en`. A
memory of more than 4,096 bits whose depth and width are multiples of a
macro's, with write-mask lanes that the macro can build, becomes a grid of
that macro: its high address bits select a row of macros, and each column
holds a slice of the word. Other memories stay behavioral arrays, which
synthesis builds from flip-flops, or mocks above 4,096 bits. Without the
define, the wrappers' code is unchanged, and the FPGA build and the other
simulations never read these modules.

| Macro | Words x bits | Write mask | Size (um) | Read (ns) | Minimum period (ns) | Instances | Memories |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `sram_1w1r_4096x64_m8` | 4,096 x 64 | Bytes | 751.9 x 845.1 | 0.514 to 0.581 | 2.15 | 64 | L2 data, 8 rows of 8 |
| `sram_2rw_4096x64_m8` | 4,096 x 64 | Bytes, both ports | 752.5 x 859.4 | 0.514 to 0.581 | 2.15 | 4 | Data memory, 4 rows |
| `sram_1w1r_4096x15` | 4,096 x 15 | | 383.1 x 491.6 | 0.353 to 0.420 | 1.56 | 8 | L2 tags, 2 rows of 4 ways |
| `sram_1w1r_4096x3` | 4,096 x 3 | | 133.6 x 489.1 | 0.255 to 0.322 | 1.19 | 2 | L2 replacement state, 2 rows |
| `sram_1w1r_1024x64_m8` | 1,024 x 64 | Bytes | 416.5 x 436.5 | 0.378 to 0.445 | 1.65 | 16 | L1D data, 1 row of 4 in each way's bank |
| `sram_1w1r_1024x19` | 1,024 x 19 | | 263.4 x 261.0 | 0.306 to 0.373 | 1.38 | 4 | L1D tags, one for each way |
| `sram_1w1r_512x68` | 512 x 68 | | 436.7 x 245.7 | 0.384 to 0.451 | 1.67 | 2 | The NIC's receive and transmit FIFOs |
| `sram_1w1r_256x36` | 256 x 36 | | 167.6 x 237.2 | 0.266 to 0.334 | 1.24 | 3 | The BTB's slot-2 payload tables |
| `sram_1w1r_128x64_m8` | 128 x 64 | Bytes | 248.6 x 143.5 | 0.308 to 0.376 | 1.39 | 16 | L1I data, 1 row of 4 in each way's bank |

The macros cover 49.0 mm^2, 70% of the die. Read is the delay
from the read clock's falling edge to the read data in the macro's Liberty
model, driving 0.84 fF and 53.5 fF: an OpenRAM macro registers its inputs at
the rising edge and reads in the second half of the cycle, so a read returns
its word in the next cycle, as a block RAM's registered read does. A macro
needs a clock period of at least its minimum period, so the 4,096 by 64
macros would limit a run with `--clock-period` below 2.15 ns. The macros
differ from the block RAMs they replace in these cases:

- A macro's read of the word that its write port writes in the same cycle
  returns undefined data, where a block RAM on one clock returns the old
  word. For the memories that write whole words on one clock, the L1D tags,
  the L2's replacement state, and the BTB's payload tables,
  `frost_sram_1w1r` keeps the block RAM's behavior: the macros take each
  write a cycle late, from a register, and a read of the word that the
  register holds returns the register's copy. The L1D depends on it: a fill
  writes its line's tag in a cycle in which a request for another line of
  the set can read the tags, and the old tag, invalid, keeps that request
  from hitting the fill's way. The memories with write lanes, the caches'
  data and the L2's tags, keep the undefined read, which frost_cache never
  uses: in simulation its data arrays reject such a read when the cache uses
  its data (`sdp_ram_byte_en`), and the L2 discards a delayed tag read that a
  write of its set crossed. Across the data memory's two clocks, such a read
  is undefined in a block RAM as well.
- A data memory port's read data after a cycle that writes that port is
  undefined, where the block RAM returns the written bytes. The CPU accepts
  no load while it stores, and the debug slice writer reads the
  program-loading port only in cycles that do not write it.
- The L2 data macros' read data is undefined in the cycle after one
  without a read, where the block RAM keeps the word it last read, and the
  read pipeline of `sdp_ram_byte_en` carries it on. frost_cache uses the
  array's read data only when a request's data is due.
- A macro completes a write half a write-clock period after the clock edge.
  The NIC's FIFOs use a word's read data only from two and a half
  read-clock periods after its write pointer leaves the write side, which
  covers that while the write clock's period is under five read-clock
  periods. The NIC's clocks keep their 6.206 ns period, twice the core
  clock's at the default target, so the receive FIFO, which the NIC writes
  and the core reads, needs a core clock period above 1.25 ns.
- The macros have no initial contents and no bulk clear. Simulation starts
  the data memory with its program image, which a chip would load through
  the program-loading port. The caches clear their tags and replacement
  state with a sweep at reset; simulation's fast maintenance
  (`SIM_FAST_MAINT`) clears those macros' models directly.

The registry's `sram_macros_*` benches build each wrapper with the
parameters of one of the design's memories and the macros' Verilog models,
check the grid of macros, and compare random reads and writes with a model
of the wrapper, including reads of the word being written where the macros
hold writes. The `*_sram_macros` programs run `isa_test`, `ddr_test`,
`ddr_exec_test`, and `nic_loopback` on the SoC built from the macros. In
both, the X that a model drives for undefined read data becomes a random
value, as does a macro's read of the word that it writes in the same cycle,
so a user that depended on one would fail.

[`openram.py`](openram.py) generates the macros:

```bash
./asic/openram.py generate                    # every macro, all at once
./asic/openram.py generate sram_1w1r_4096x3   # one macro
./asic/openram.py list
```

It runs OpenRAM in the ORFS image that `orfs.py` pins, in a virtual
environment of the Python packages that
[`sram/requirements.txt`](sram/requirements.txt) pins by hash, with OpenRAM
fetched at the commit that `OPENRAM_COMMIT` names, from its dev branch. The
last release, 1.2.48 from January 2024, connects an array's cells to the
supply nets in quadratic time and caps the slew at the address pins at
0.04 ns; on a 512 by 64 macro with a read-write port and a read port it had
not finished routing the supply ring after 41 minutes, where the dev branch
builds the same macro in 8 minutes. OpenRAM characterizes the macros with
its analytical delay model at the Nangate45 library's corner, typical
process at 1.1 V and 25 C, so no SPICE simulator is needed. Its tables reach
53.5 fF of load and 0.5 ns of input slew (`LOAD_SCALES` and `SLEW_SCALES`);
with OpenRAM's defaults, which stop at 0.84 fF, the read data's maximum
capacitance would be below a single Nangate45 gate's input, so the flow
could not buffer it. OpenRAM sets the minimum period to 3.7 times the read
delay at the largest load. It skips DRC and LVS, which need Magic and
Netgen. Each macro has a supply ring on metal3 and metal4 and its pins on
its edges. The 4,096 by 64 macros take about half an hour and 3.5 GB each,
on one thread, and the others less than ten minutes; all of them at once
take 34 minutes. OpenRAM could not route the pins of a 512 by 128 macro to
its edges, so the L1s' data uses 64-bit macros, four to a way's 256-bit
line.

The generator copies each macro's abstract LEF, Liberty model, and Verilog
model into `sram/macros/<macro>/`, 386 KB in all, which git tracks, so the
flow and CI never run OpenRAM. It fixes Python's hash seed, which sets the
order in which OpenRAM writes shapes, so a rerun writes the same views byte
for byte. Everything else stays in `asic/build/openram`, which git ignores,
including each macro's GDS, 20 MB for a 4,096 by 64 macro. The final GDS
therefore leaves the macros' cells empty, as ORFS allows for macros without
layouts (`GDS_ALLOW_EMPTY`). OpenRAM draws FreePDK45 on a 2.5 nm grid, and
OpenROAD's router rejects a pin off Nangate45's 5 nm manufacturing grid, so
the generator widens the macro's outline and each rectangle in its LEF to
that grid, moving an edge outward by at most 2.5 nm. In the Verilog models,
the generator sets `VERBOSE` to 0, which also silences their collision
warnings, and their delays to 0.1 and 0.5 ns, to fit the simulations' 3 ns
clock.

[`macro_placement.tcl`](macro_placement.tcl) places the macros in three
columns of the core. The L2 data's eight 64-bit slices fill the left and
right columns, four each; a slice is a column of eight macros, one for each
eighth of the {way, set} lines, so a bit's eight-way read multiplexer spans
one column. The middle column holds the L1D data at the top, a row of four
macros for each way; the data memory at the bottom; the L1D tags, the L1I
data, and the smaller macros above the data memory; and at its sides,
around the logic, two stacks of L2 tags, one for each row of the tag array,
with the row's replacement state on top. Macros above one another stand 40 um
apart and the columns 80 um. Macros side by side stand 62 um apart, because
the cell rows between them take their power from the metal4 straps that
cross the gap: the platform's grid has a strap of each supply every 56 um
and keeps the straps' vias 2 um from a macro, so a 40 um gap can leave its
rows without one. A 120 um ring of free core surrounds the columns and
carries the wires from the pins to the logic; with the macros against the
core's edges, global routing could not get the wires past the macros'
corners. The I/O placer puts over a thousand pins, most of them the DDR
port's, on the bottom or the top edge in front of the center column,
whichever the DDR port's logic lands nearer to, so the data memory and the
L1D data stand 360 um from those edges, room for those pins' wires and the
logic they reach. The smaller macros stand 160 um above the data memory:
wires from the logic below the data memory turn up between them, and with
80 um global routing overflowed there.
[`check_power_grid.tcl`](check_power_grid.tcl) stops the
floorplan if a macro or a row is cut off from the grid, which the final
report's IR drop analysis would otherwise find at the end of the flow. The
platform's grid straps each macro's supply ring through metal5 and metal6,
and [`sram_power.tcl`](sram_power.tcl) connects OpenRAM's `vdd` and `gnd`
pins to the grid's nets.

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
The delays count from the clock as it arrives inside the design, as if a PLL
aligned the board's clock with a point inside the chip, or the logic beyond
the ports shared the clock tree. Each clock has an I/O copy, a generated
clock named after it with `_io` appended, defined at the clock pin of one
register at its interface, and each port's delay is set against its clock's
copy:

| Clock | Pin of its I/O copy |
| --- | --- |
| `core_clk` | The DDR bridge's AXI read request register |
| `core_clk_div4` | The program-loading port of the data memory's first macro |
| `nic_tx_clk` | The NIC's transmit gearbox |
| `nic_rx_clk` | The NIC's receive gearbox |
| `jtag_tck` | The JTAG TAP's bypass register |

After clock tree synthesis, a copy's edges arrive with the tree's delay to
its pin, and the paths through the ports are timed against the skew between
that pin and the registers they reach. Against the clock at the port, every
path to an output would lose the tree's whole delay, and the hold repair
would add as much in buffers in front of every input. Before clock tree
synthesis, while the clocks are ideal, a copy's edges are its clock's.
OpenSTA's `-reference_pin` option to `set_input_delay` would say the same,
but the OpenROAD build in the ORFS image crashes on any input delay that
uses it. Clock tree synthesis takes the nets of the clock ports as its
roots from `CTS_ARGS` in [`config.mk`](config.mk): from the SDC's clocks, it
would take each copy for a second clock on its master's net and stop.

The register at a copy's pin is clocked by the copy. In the tables of worst
slack by capture clock, in `summary.md` and the `paths` report, each copy
has its own row for the paths that it captures: those to the output ports
and to that register. The `paths` report's other tables count a copy's
paths as its clock's. The asynchronous levels (`i_jtag_trst_n`, the NIC's
clock-presence and PHY status inputs) are not timed. A missed target does
not stop the flow: ORFS's repair steps after synthesis work toward it, and
synthesis maps the same netlist for any target
([Finding the fmax](#finding-the-fmax)).

The data memory's macros clock their program-loading port with `i_clk_div4`
and their core port with `i_clk`, as the X3's block RAMs do. The instruction
memory's mocked row adds paths between the two core clocks that a two-port
memory would not have: it is written on `i_clk_div4` and read by registers on
`i_clk`. The flow times and repairs them like any other path.

## Results with the SRAM macros

The default run at the X3's 3.103 ns core clock, with 16 threads, against the
last run with every memory over 4,096 bits mocked whose results are recorded
here, which CI made before the caches became 4-way set-associative (commit
`e54df6da`) and which counted the I/O delays from the clock at its port:

| | Memories mocked | SRAM macros |
| --- | ---: | ---: |
| Die | 1.89 by 1.89 mm, 3.58 mm^2 | 9.6 by 7.315 mm, 70.2 mm^2 |
| SRAM macros | | 119, 49.0 mm^2 |
| Standard cells, final | 752,118, 1.46 mm^2 | 1,045,105, 1.78 mm^2 |
| Hold buffers from clock tree synthesis | 11,347 | 22,495 |
| Routed wire | 20.1 m | 68.6 m |
| Core clock latency, final | about 1 ns | 2.94 to 3.65 ns |
| Clock skew, final | 0.15 ns | 0.55 ns |
| Core clock setup WNS, final | 0.375 ns | -0.955 ns |
| Worst core path between registers, final | met | -0.955 ns |
| `core_clk_div4` setup WNS, final | 1.774 ns | 0.057 ns |
| Core clock hold WNS, final | 0.025 ns | -0.119 ns |
| Detailed-route DRC errors | 0 | 0 |
| Worst IR drop on VDD | 49 mV | 193 mV |

The macros take 70% of the die, and the logic fills the space between them,
so the wires grow long: the routed wire more than triples, and the L2 data's
outer columns sit millimeters from the cache's logic. The clock tree spans the
die: a register's clock passes 16 buffers on the wire from the clock pin and
then about 40 of the platform's `CLKBUF_X3` cells, and its latency rises from
about 1 ns to 2.9 to 3.7 ns.

The ports meet timing, since their I/O delays count from the clocks' I/O
copies ([Timing constraints](#timing-constraints)): the worst output has
0.74 ns of setup slack and 0.65 ns of hold slack, and the worst input 0.60 ns
of hold slack. The worst input's setup slack, 0.06 ns, is that of `i_rst` to
the quarter-rate clock's reset synchronizer, which also sets the
`core_clk_div4` WNS: the quarter-rate clock's tree, with about 400 registers
and the data memory's four macros, reaches them about 1 ns after its clock
pin, and the core clock's tree reaches the I/O copy's register about 2.5 ns
later than that. The hold repair adds 22,495 buffers, about as many as with
no hold checks at the core clocks' inputs.

Between registers, the paths from the macros fail worst: the L2 data macros
to the L2's read register, by up to 0.955 ns; the data memory to the load
queue, by up to 0.716 ns; the BTB's payload tables to the PC controller and
the rest of the fetch logic, by up to 0.349 ns; and the L1D's tags to its
request registers, by up to 0.230 ns. A macro drives its read data 0.3 to
0.6 ns after the clock's falling edge, which leaves those paths about 1 ns of
the 3.103 ns cycle, less the skew between the macro's clock and the
capturing register's, and the L2's outer columns put millimeters of buffered
wire in its paths. The multiplexer that returns a held write adds 0.07 to
0.11 ns to the BTB's and the L1D's paths. Of the paths that start at no
macro, only the multiply and divide unit's fail, by 0.070 ns. Since the flow
skips the repairs after global routing, the final design keeps 770
maximum-slew and 6,602 maximum-capacitance violations (none and 632 in the
mocked run, which ran those repairs) and 70 hold violations. The worst IR
drop is 193 mV on VDD and 116 mV on VSS; ORFS's map of the VSS drop puts its
worst where the channels between the data memory's four macros meet.

## Finding the fmax

A target the design cannot meet shows how fast it can run and which paths
stop it. `--clock-period` sets the core clock period in ns, below 100 ns with
at most four decimals; the quarter-rate clock and the I/O delays follow it.
With a period shorter than the design reaches, ORFS's repair steps resize,
buffer, clone, and swap pins on the failing paths until no move helps, and
the worst slack that remains gives the fmax, 1 / (period - WNS). Since the
flow skips the repairs after global routing, those after clock tree
synthesis are the last, and below 2.15 ns the 4,096 by 64 macros miss
their minimum period. `paths` reports the setup paths of one stage's
database:

```bash
./asic/orfs.py run --target grt --num-cores 16 --clock-period 2.2
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

These runs predate the SRAM macros: they used the RTL of commit `e6eb7a47`
with every memory over 4,096 bits mocked, I/O delays counted from the clock
at its port rather than from an I/O copy, eight threads each, and ORFS's
default repair settings, including the repairs after global routing, which
took 12 minutes at 1.6 ns; the 1.6 ns run took 2.7 hours through global
routing. The core
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
the memories cost. A synchronous read in these runs is a flip-flop feeding
the read register, where an SRAM macro puts its output; the paths after
those read registers had room at 1.6 ns: 0.63 ns from the data memory's read
register to the load queue, and 0.99 ns from the L1 data array's. With the
SRAM macros, the paths from the L2 data and the data memory fail worst at the
X3's clock ([Results with the SRAM macros](#results-with-the-sram-macros)).

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
mapping. The PC loop reads the BTB and TAGE tables, which the flow still
mocks, so it cannot rank that family until real arrays replace the mocks.

## CI

Four chained jobs run the flow on every pull request and every push to
`main`, each resuming from the database of the one before:

| Job | Runs |
| --- | --- |
| `ASIC Flow (synthesis to clock tree synthesis)` | `./asic/orfs.py run --target cts` |
| `ASIC Flow (global routing)` | `./asic/orfs.py run --from grt --target grt` |
| `ASIC Flow (detailed routing)` | `./asic/orfs.py run --from route --target route` |
| `ASIC Flow (GDS and final report)` | `./asic/orfs.py run --from finish` |

The last job's step summary shows `summary.md`, and its `asic-flow-results`
artifact holds the logs, reports, and summary of all four. The runners have
four CPUs and 16 GB of memory, and the steps peak at 18 to 39 GB, so each job
adds swap space; each also deletes preinstalled toolchains to make room for
the databases.

## The ORFS image

[`orfs.py`](orfs.py) pins the image by digest:
`openroad/orfs:26Q3-705-gecb3cfdeb@sha256:6da005d1c3447799f7401215174196c75ba9ec7e28417624d0c20225f85d594c`.
It is the ORFS 26Q4 quarterly release, commit `ecb3cfdeb`, which Docker Hub
publishes under its `git describe` tag. It contains Yosys 0.68, OpenROAD
`c487fc70`, and KLayout 0.30.12; the frost image's Yosys 0.70 reads the same
sources. To update the image, change `ORFS_IMAGE` and run the whole flow.

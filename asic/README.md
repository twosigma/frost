# ASIC flow

This directory runs FROST through
[OpenROAD-flow-scripts](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts)
(ORFS) on its Nangate45 platform: the FreePDK45 process with the Nangate
Open Cell Library. Yosys synthesizes `platform_top`; OpenROAD floorplans,
places, builds the clock trees, and routes it; KLayout writes the GDS.
OpenSTA reports timing after each stage. FreePDK45 is not a manufacturable
process, so the flow shows that the RTL maps onto standard cells and SRAM
macros and estimates its area and timing. It does not replace a foundry flow.

The memories behind the RAM wrappers in
[`hw/rtl/lib/ram`](../hw/rtl/lib/ram) are dual-port SRAM macros that
[OpenRAM](https://github.com/VLSIDA/OpenRAM) generates for FreePDK45: the
caches' data, the L1D's and the L2's tags, the data memory, the instruction
memory, the NIC's FIFOs and MAC frame and packet buffers, and the BTB's
slot-2 payload tables ([SRAM macros](#sram-macros)). The L2 holds 256 KiB,
where the X3's holds 2 MiB, so that the flow fits CI's runners ([CI](#ci)).
Arrays of 4,096 bits or less, such as the L1I's tags and the caches'
replacement state, become flip-flops. The other memories larger than 4,096 bits are mocked: each keeps
a single row, built from flip-flops. They are arrays read without a clock,
such as the BTB tags, the TAGE tables, the instruction memory's PC-metadata
overlays, the MAC's packet descriptors, and banks of the ROB and the INT RS,
which an ASIC would build from flip-flops or latches rather than SRAM.
Their area and the paths through them are therefore missing. The summary
lists the macros and every mocked memory with its dimensions.

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
With 16 threads the whole flow takes about three and a half hours. The final
report needs about 28 GB of memory, detailed routing 22 GB, and global
routing 17 GB, and the stages' databases about 23 GB of disk.

`run` has three steps:

1. In the frost image, `orfs.py prepare` converts the NIC and MAC/PCS
   sources with sv2v as [`tests/test_run_yosys.py`](../tests/test_run_yosys.py)
   does, and writes the source list from [`hw/rtl/frost.f`](../hw/rtl/frost.f)
   to `asic/build/sources.mk`. No memory reads a `$readmemh` image here: the
   SRAM macros have no initial contents, and the instruction memory's
   PC-metadata overlays read their images only outside Yosys.
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
| Top module | `platform_top`, with `ENABLE_CACHED_TIER=1` and `USE_BEHAVIORAL_DDR=0`, so the cached tier ends at the DDR AXI port, and `L2_CACHE_BYTES=262144`, a 256 KiB L2 where the X3's holds 2 MiB, so that the flow fits CI's runners ([CI](#ci)); other parameters keep their defaults |
| Defines | `SYNTHESIS`, and `FROST_SRAM_MACROS` for the [SRAM macros](#sram-macros); not `FROST_XILINX_PRIMS`, so every block uses its portable version |
| Memories | The RAM wrappers' memories are SRAM macros. `SYNTH_MOCK_LARGE_MEMORIES=1`: other memories over 4,096 bits keep one row; smaller ones become flip-flops |
| Die size | `DIE_AREA`: 5.13 by 6.105 mm; `CORE_AREA` leaves 15 um on each side. The core fits the macro placement |
| Macro placement | [`macro_placement.tcl`](macro_placement.tcl) (`MACRO_PLACEMENT_TCL`) |
| Pin placement | `PLACE_PINS_ARGS`: the die's left and right edges only, which pass the logic band |
| Power grid | The platform's, with [`sram_power.tcl`](sram_power.tcl) (`PRE_PDN_TCL`) connecting the macros' supply pins and [`check_power_grid.tcl`](check_power_grid.tcl) (`POST_PDN_TCL`) checking that everything placed reaches the grid |
| Placement density | `PLACE_DENSITY_LB_ADDON=0.20`: the lower bound plus a fifth of the remaining room |
| Clock tree synthesis | `CTS_ARGS`: ORFS's default arguments, with the clock ports' nets as the roots ([Timing constraints](#timing-constraints)) |
| Repairs after global routing | `SKIP_INCREMENTAL_REPAIR=1`: with 4 threads they add over two hours to global routing, 82 minutes of it repairing slew and capacitance over the routed wires and 49 the timing repair, and raise its peak memory from 15.6 to 21.1 GB, more than a CI job allows; the repairs after placement and clock tree synthesis still run |
| Antenna repair after global routing | `SKIP_ANTENNA_REPAIR=1`: it finds nothing to repair, and the placement check after it needs 4.5 GB of memory |
| Antenna repair after detailed routing | `SKIP_ANTENNA_REPAIR_POST_DRT=1`: prevents diode insertion before another detailed routing call reuses pin access; the platform has no antenna diode cell, and the final antenna check still writes `reports/.../drt_antennas.log` |
| Detailed routing | `DETAILED_ROUTE_ARGS` replaces the script's defaults with `-droute_end_iter 64 -verbose 1 -drc_report_iter_step 5 -no_pin_access`, reusing global routing's saved access points; this requires all three repair skips above to stay 1 and `RECOVER_POWER` to stay at its default 0 so cells and placement stay unchanged |
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
port, for `sdp_block_ram`, `sdp_block_ram_dc`, `sdp_block_ram_dc_init`,
`sdp_ram_byte_en`, and `sdp_packed_tag_uram`; and
[`frost_sram_2rw`](sram/frost_sram_2rw.sv), with two read and write ports on
their own clocks, for `tdp_bram_dc_byte_en`. A memory of more than 4,096
bits whose depth and width are multiples of a macro's, with write-mask lanes
that the macro can build, becomes a grid of that macro: its high address
bits select a row of macros, and each column holds a slice of the word.
Other memories stay behavioral arrays, which synthesis builds from
flip-flops, or mocks above 4,096 bits. Without the define, the wrappers'
code is unchanged, and the FPGA build and the other simulations never read
these modules.

| Macro | Words x bits | Write mask | Size (um) | Read (ns) | Minimum period (ns) | Instances | Memories |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `sram_1w1r_4096x64_m8` | 4,096 x 64 | Bytes | 751.9 x 845.1 | 0.514 to 0.581 | 2.15 | 9 | L2 data, 1 row of 8; the NIC's transmit frame buffer, 1 macro |
| `sram_2rw_4096x64_m8` | 4,096 x 64 | Bytes, both ports | 752.5 x 859.4 | 0.514 to 0.581 | 2.15 | 4 | Data memory, 4 rows |
| `sram_1w1r_1024x64_m8` | 1,024 x 64 | Bytes | 416.5 x 436.5 | 0.378 to 0.445 | 1.65 | 16 | L1D data, 1 row of 4 in each way's bank |
| `sram_1w1r_1024x19` | 1,024 x 19 | | 263.4 x 261.0 | 0.306 to 0.373 | 1.38 | 4 | L1D tags, one for each way |
| `sram_1w1r_1024x18` | 1,024 x 18 | | 253.5 x 260.7 | 0.302 to 0.369 | 1.37 | 4 | L2 tags, 1 row of 4 ways |
| `sram_1w1r_512x68` | 512 x 68 | | 436.7 x 245.7 | 0.384 to 0.451 | 1.67 | 2 | The NIC's receive and transmit FIFOs |
| `sram_1w1r_256x36` | 256 x 36 | | 167.6 x 237.2 | 0.266 to 0.334 | 1.24 | 3 | The BTB's slot-2 payload tables |
| `sram_1w1r_128x64_m8` | 128 x 64 | Bytes | 248.6 x 143.5 | 0.308 to 0.376 | 1.39 | 16 | L1I data, 1 row of 4 in each way's bank |
| `sram_1w1r_8192x28` | 8,192 x 28 | | 665.7 x 877.4 | 0.466 to 0.533 | 1.97 | 4 | Instruction memory's cold banks, 2 rows in each parity's |
| `sram_1w1r_8192x4` | 8,192 x 4 | | 173.1 x 871.8 | 0.268 to 0.335 | 1.24 | 8 | Instruction memory's frontend-hot and compressed banks, 2 rows in each |
| `sram_1w1r_4096x8` | 4,096 x 8 | | 234.2 x 489.9 | 0.294 to 0.362 | 1.34 | 8 | The NIC's receive packet buffer, 1 macro per byte lane |

The macros cover 17.1 mm^2, more than half of the die. Read is the delay
from the read clock's falling edge to the read data in the macro's Liberty
model, driving 0.84 fF and 53.5 fF: an OpenRAM macro registers its inputs at
the rising edge and reads in the second half of the cycle, so a read returns
its word in the next cycle, as a block RAM's registered read does. A macro
needs a clock period of at least its minimum period, so the 4,096 by 64
macros would limit a run with `--clock-period` below 2.15 ns. The macros
differ from the block RAMs they replace in these cases:

- A macro's read of the word that its write port writes in the same cycle
  returns undefined data, where a block RAM on one clock returns the old
  word. For the memories that write whole words on one clock, the L1D tags
  and the BTB's payload tables, `frost_sram_1w1r` keeps the block RAM's
  behavior: the macros take each
  write a cycle late, from a register, and a read of the word that the
  register holds returns the register's copy. The L1D depends on it: a fill
  writes its line's tag in a cycle in which a request for another line of
  the set can read the tags, and the old tag, invalid, keeps that request
  from hitting the fill's way. The memories with write lanes, the caches'
  data and the L2's tags, keep the undefined read, which frost_cache never
  uses: in simulation its data arrays reject such a read when the cache uses
  its data (`sdp_ram_byte_en`), and the L2 discards a delayed tag read that a
  write of its set crossed. Across the data memory's and the instruction
  memory's two clocks, such a read is undefined in a block RAM as well.
- A data memory port's read data after a cycle that writes that port is
  undefined, where the block RAM returns the written bytes. The CPU accepts
  no load while it stores, and the debug slice writer reads the
  program-loading port only in cycles that do not write it.
- The L2 data macros' read data is undefined in the cycle after one
  without a read, where the block RAM keeps the word it last read, and the
  read pipeline of `sdp_ram_byte_en` carries it on. frost_cache uses the
  array's read data only when a request's data is due. The instruction
  memory's banks and the MAC's transmit buffer keep the block RAM's behavior
  with a register of the last word read (`sdp_block_ram_dc_init`). Synthesis
  removes that register from the instruction banks, since `soc_top` reads
  them every cycle. The MAC's receive lanes also read every cycle and need
  no holding register.
- A macro completes a write half a write-clock period after the clock edge.
  The NIC's FIFOs use a word's read data only from two and a half
  read-clock periods after its write pointer leaves the write side, which
  covers that while the write clock's period is under five read-clock
  periods. The NIC's clocks keep their 6.206 ns period, twice the core
  clock's at the default target, so the receive FIFO, which the NIC writes
  and the core reads, needs a core clock period above 1.25 ns. The
  instruction memory takes its writes on the quarter-rate clock, so its
  macros complete a write two core cycles after the edge. `soc_top` reads the
  instruction memory every cycle, and the CPU fetches a written word only
  after the program loader releases the CPU's reset or after the debug slice
  writer reports the write done, four core cycles after the macros complete
  it. For readers of `imem_predecode`'s readiness flag, its write quarantine
  lets through a read one and a half core cycles after that, with the
  quarter-rate clock phase-locked to the core's, as on the X3.
- The MAC's frame and packet buffers have both ports on their direction's
  clock, TX or RX. TX sets `buffer_full` on the edge that writes the final
  beat, so its first read starts at least one rising edge later, after the
  macro completes that write at the intervening falling edge. Ingress cannot
  overwrite that buffer until transmission releases it. RX reads every
  clock, but copies a word only for a published packet. Publication follows
  the final write or shares its edge; the first word's final write edge
  precedes publication by at least seven clocks, and each copied word was
  fetched after its final write. Its macro write therefore completes at least
  half a period before the rising edge that requests that read. Output
  handshakes return storage credit after copying, so allocation cannot
  overwrite a word that the reader needs. Unused RX fetches may collide with writes;
  the reader discards them and fetches again. The RX simulation check
  rejects a copied word whose fetch shared a write's edge.
- The macros have no initial contents and no bulk clear. Simulation starts
  the data memory and the instruction memory with their program images,
  which a chip would load through the program-loading port; the instruction
  memory's come from the app's block-RAM images, which its build writes with
  `GENERATE_IMEM_INIT=1`. The caches clear their tags and replacement
  state with a sweep at reset; simulation's fast maintenance
  (`SIM_FAST_MAINT`) clears those macros' models directly.

The registry's `sram_macros_*` benches build each wrapper with the
parameters of one of the design's memories and the macros' Verilog models,
check the grid of macros, and compare random reads and writes with a model
of the wrapper, including reads of the word being written where the macros
hold writes; the instruction memory's banks take writes on a clock a
quarter of the read clock's rate, as on the X3. The `*_sram_macros`
programs run `isa_test`, `ddr_test`, `ddr_exec_test`, and `nic_loopback` on
the SoC built from the macros. In
both, the X that a model drives for undefined read data becomes a random
value, as does a macro's read of the word that it writes in the same cycle,
so a user that depended on one would fail.

The standalone [Ethernet benches](../tests/net10g/README.md) also run their
TX, RX, and MAC/PCS integration cases with `FROST_SRAM_MACROS`, including
stalls, wraparound, rotated frames, and reset. Their clocks exercise the
macro models' falling-edge writes and delayed reads.

[`openram.py`](openram.py) generates the macros:

```bash
./asic/openram.py generate                    # every macro, all at once
./asic/openram.py generate sram_1w1r_1024x18  # one macro
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
on one thread, the 8,192 by 28 macro about 25 minutes, and the others less
than ten minutes; all of them at once take 34 minutes. OpenRAM could not
route the pins of a 512 by 128 macro to its edges, so the L1s' data uses
64-bit macros, four to a way's 256-bit line. A macro holds at most 8,192
words, 512 rows of 16, so each of the instruction memory's 16,384-word
banks takes two rows of macros.

The MAC's receive packet buffer uses eight 4,096 by 8 macros, one per byte
lane, covering 0.918 mm^2. Frames starting on XGMII lane four write the two
four-byte lane groups at different word addresses in the same cycle, so
one 64-bit byte-write macro cannot supply those ports. Each lane has its own
write enable and address and shares the read address. The transmit frame
buffer uses one 4,096 by 64 byte-write macro, with all byte enables tied
together, covering 0.635 mm^2.

The generator copies each macro's abstract LEF, Liberty model, and Verilog
model into `sram/macros/<macro>/`, 444 KB in all, which git tracks, so the
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
bands across the core, with the logic in a band between the top two. The
bottom band holds the L2 data's eight 64-bit slices, a macro each, in two
blocks of two by two, and the data memory's four macros between them. The
band above it holds the instruction memory's twelve macros in a row: each
parity's cold, frontend-hot, and compressed banks side by side, two macros a
bank, the even parity at the left and the odd parity, in mirror order, at
the right. The top band holds the L1D data in the middle, a row of four
macros for each way; at its left the L1I data, arranged the same way, then
the NIC's FIFOs, the BTB's payload tables, and two rows of four receive
packet macros; and at its right the L1D tags, the L2 tags, and the transmit
frame macro. The logic band is 800 um high, and the script stops the flow if
the core leaves less than 600 um for it.
Macros above one another stand 40 um apart and groups of macros 80 um.
Macros side by side stand 62 um apart, because the cell rows between them
take their power from the metal4 straps that cross the gap: the platform's
grid has a strap of each supply every 56 um and keeps the straps' vias 2 um
from a macro, so a 40 um gap can leave its rows without one. A 120 um ring
of free core surrounds the macros and carries the wires from the pins past
the macros' corners; with the macros against the core's edges, global
routing could not get the wires past them. The I/O placer puts the pins,
over a thousand of them the DDR port's, on the die's left and right edges
(`PLACE_PINS_ARGS`): the DDR port's write data beside the bottom band, its
read data beside the instruction memory's row and the logic band, and the
NIC's transceiver data beside the top band.
[`check_power_grid.tcl`](check_power_grid.tcl) stops the
floorplan if a macro or a row is cut off from the grid, which the final
report's IR drop analysis would otherwise find at the end of the flow. The
platform's grid straps each macro's supply ring through metal5 and metal6,
and [`sram_power.tcl`](sram_power.tcl) connects OpenRAM's `vdd` and `gnd`
pins to the grid's nets.

### Instances built from SRAM macros

These RAM wrapper instances, named in `platform_top`'s hierarchy, keep their
memories in SRAM macros; synthesis names each macro after its instance, as
in `soc.data_memory.u_sram.gen_row[0].u_macro`. An index `w` runs from 0
to 3, one for each way.

| Instance | Wrapper | Memory | Macros |
| --- | --- | --- | --- |
| `cpu.cluster_memory.gen_cached_tier.cluster_cache.l2_cache.gen_data_array.data_array` | `sdp_ram_byte_en` | 4,096 x 512, byte lanes | 1 row of 8 `sram_1w1r_4096x64_m8` |
| `cpu.cluster_memory.gen_cached_tier.cluster_cache.l2_cache.gen_tag_ultra.tag_array` | `sdp_packed_tag_uram` | 4,096 tags of 18 bits, read four at a time | 1 row of 4 `sram_1w1r_1024x18` |
| `cpu.hart.gen_cached_tier.hart_cache.l1_cache.gen_data_banks.gen_bank[w].data_bank` | `sdp_ram_byte_en` | 1,024 x 256, byte lanes | 1 row of 4 `sram_1w1r_1024x64_m8` each |
| `cpu.hart.gen_cached_tier.hart_cache.l1_cache.gen_tag_block.gen_way[w].tag_array` | `sdp_block_ram` | 1,024 x 19 | 1 `sram_1w1r_1024x19` each |
| `cpu.hart.gen_cached_tier.hart_cache.l1i_cache.gen_data_banks.gen_bank[w].data_bank` | `sdp_ram_byte_en` | 128 x 256, byte lanes | 1 row of 4 `sram_1w1r_128x64_m8` each |
| `cpu.hart.cpu_inst.if_stage_inst.branch_prediction_controller_inst.branch_predictor_inst.btb_payload_ram_lookup_2`, `_alt`, and `_rot` | `sdp_block_ram` | 256 x 36 | 1 `sram_1w1r_256x36` each |
| `soc.data_memory` | `tdp_bram_dc_byte_en` | 16,384 x 64, byte lanes, two ports | 4 rows of 1 `sram_2rw_4096x64_m8` |
| `soc.instruction_memory.u_even_cold` and `u_odd_cold` | `sdp_block_ram_dc_init` | 16,384 x 28 | 2 rows of 1 `sram_1w1r_8192x28` each |
| `soc.instruction_memory.u_even_frontend_hot`, `u_odd_frontend_hot`, `u_even_compressed`, and `u_odd_compressed` | `sdp_block_ram_dc_init` | 16,384 x 4 | 2 rows of 1 `sram_1w1r_8192x4` each |
| `soc.gen_cached_tier.nic.u_mac.u_rx_fifo.storage` and `u_tx_fifo.storage` | `sdp_block_ram_dc` | 512 x 68 | 1 `sram_1w1r_512x68` each |
| `soc.gen_cached_tier.nic.u_mac.u_mac.mac_tx.u_frame_memory` | `sdp_block_ram_dc_init` | 4,096 x 64 | 1 `sram_1w1r_4096x64_m8` |
| `soc.gen_cached_tier.nic.u_mac.u_mac.mac_rx.g_memory_lane[0..7].u_packet_memory` | `sdp_block_ram_dc_init` | 4,096 x 8 each | 1 `sram_1w1r_4096x8` each |

The instruction memory's sideband banks, `u_even_sideband` and
`u_odd_sideband`, are `sdp_block_ram_dc_init` instances that only simulation
reads, so synthesis removes them; simulations of the macros build them from
`sram_1w1r_8192x4` macros too. The wrappers of distributed RAMs, such as the
instruction memory's PC-metadata overlays (`sdp_dist_ram_init`), keep
behavioral arrays.

## Timing constraints

[`constraint.sdc`](constraint.sdc) defines one clock per clock input:

| Clock | Port | Period | Source |
| --- | --- | --- | --- |
| `core_clk` | `i_clk` | 3.103 ns (322.265625 MHz), or `--clock-period` | The X3 CPU clock |
| `core_clk_div4` | `i_clk_div4` | Four core periods, 12.412 ns | The program-loading port's clock, a quarter of the CPU clock |
| `nic_tx_clk` | `i_nic_tx_clk` | 6.206 ns (161.1328125 MHz) | The X3 transceiver's TX user clock |
| `nic_rx_clk` | `i_nic_rx_clk` | 6.206 ns | The X3 transceiver's recovered RX user clock |
| `jtag_tck` | `i_jtag_tck` | 100 ns (10 MHz) | The JTAG TAP inside `platform_top` (`DEBUG_JTAG_TAP=1`) |

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
and their core port with `i_clk`, and the instruction memory's macros their
write port and their read port, as the X3's block RAMs do.

## Results with the SRAM macros

The 256 KiB L2 column uses the default 3.103 ns core clock and 16 threads.
The 2 MiB L2 column uses the X3's L2 size and a mocked instruction memory at
commit `ea7289e0`. The mocked-memory column uses commit `e54df6da`, before
the caches became 4-way set-associative, with every memory over 4,096 bits
mocked and I/O delays counted from the clock at its port.

| | Memories mocked | 2 MiB L2 | 256 KiB L2 |
| --- | ---: | ---: | ---: |
| Die | 1.89 by 1.89 mm, 3.58 mm^2 | 9.6 by 7.315 mm, 70.2 mm^2 | 5.13 by 6.105 mm, 31.3 mm^2 |
| SRAM macros | | 119, 49.0 mm^2 | 78, 17.1 mm^2 |
| Standard cells, final | 752,118, 1.46 mm^2 | 1,045,105, 1.78 mm^2 | 988,462, 1.83 mm^2 |
| Hold buffers from clock tree synthesis | 11,347 | 22,495 | 642 |
| Routed wire | 20.1 m | 68.6 m | 48.5 m |
| Core clock latency, final | about 1 ns | 2.94 to 3.65 ns | 1.93 / 2.44 ns, worst-skew path |
| Clock skew, final | 0.15 ns | 0.55 ns | 0.51 ns |
| Core clock setup WNS, final | 0.375 ns | -0.955 ns | -0.350 ns |
| Worst core path between registers, final | met | -0.955 ns | -0.350 ns |
| Core clock fmax estimate, final | | 199.5 MHz | 263.0 MHz |
| `core_clk_div4` setup WNS, final | 1.774 ns | 0.057 ns | 0.459 ns |
| Core clock hold WNS, final | 0.025 ns | -0.119 ns | -0.055 ns |
| Detailed-route DRC errors | 0 | 0 | 0 |
| Worst IR drop on VDD | 49 mV | 193 mV | 88 mV |

The macros occupy 17.1 mm^2 of the 31.3 mm^2 die. The L2's eight data
macros take 5.1 mm^2, the instruction memory's twelve take 3.5 mm^2, and
the MAC's nine frame and packet macros take 1.55 mm^2. The logic fills the
band between the top macros and the instruction memory's row and the room
around the macros. The routed wire totals 48.5 m. The core clock path with
the largest setup skew has 2.44 ns of source latency and 1.93 ns of capture
latency, giving 0.51 ns of skew.

Between registers, the paths from the L1D's tag macros to its read-way
selection registers fail worst, by up to 0.350 ns. The data memory's macros
to `soc_top`'s local response register (`local_resp_data`) fail by up to
0.280 ns, the instruction memory's macros to that register by 0.231 ns,
and the BTB's payload tables to the PC controller by 0.079 ns. A macro
drives its read data 0.3 to 0.6 ns after the clock's falling edge, leaving
about 1 ns of the 3.103 ns cycle, less the clock skew, for the path to a
register. The worst path launches at 1.5515 ns and captures at 3.103 ns.
Its -0.349602125 ns slack gives a minimum period of 3.802204250 ns and an
estimated fmax of 263.0 MHz, using the saved final path report's unrounded
TSV slack. The L2 data macros' paths to their read registers meet setup
with at least 0.054 ns to spare.

The NIC TX clock has 1.061 ns of setup slack and 0.040 ns of hold slack;
RX has 2.252 ns and 0.018 ns. The quarter-rate and JTAG clocks and all I/O
clock copies also meet setup and hold. Clock tree synthesis inserts 642
hold buffers. The final design has 513 setup violations and 33 hold
violations, all on the core clock, with the worst hold slack at -0.055 ns.
The flow skips repairs after global routing, and the final design has
223 maximum-slew and 2,376 maximum-capacitance violations. Detailed routing
has no DRC errors. The worst IR drop is 88 mV on VDD and 65 mV on VSS.

## Finding the fmax

A target the design cannot meet shows how fast it can run and which paths
stop it. `--clock-period` sets the core clock period in ns, below 100 ns with
at most four decimals; the quarter-rate clock and the I/O delays follow it.
With a period shorter than the design reaches, ORFS's repair steps resize,
buffer, clone, and swap pins on the failing paths until no move helps. For a
register path whose launch and capture edges span f core periods, its slack
gives a minimum period of P - slack / f. The fmax estimate is the smallest
1 / (P - slack / f) across the reported register paths. The expression
1 / (period - WNS) applies only when those paths have a full core cycle.
OpenRAM reads launch on the falling edge and reach rising-edge registers
with half a cycle, so f is 0.5 for those core paths. The flow skips the
repairs after global routing, so clock tree synthesis is the last stage
that repairs timing in this configuration. Below 2.15 ns the 4,096 by 64
macros also miss their minimum period. `paths` reports the setup paths of
one stage's database:

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
| Paths between core clock registers | The worst path between registers for each pair of core clocks and launching edge, and the fmax it allows |
| Core clock endpoints by block | The blocks whose registers have the worst core clock slack |
| Core clock paths by start and end block | Each endpoint's worst path, grouped by the blocks of its startpoint and endpoint, with its cells and notes on ports, the quarter-rate clock, and mocked memories |

A block is the first four levels of a register's instance name, such as
`cpu.hart.cpu_inst.u_tomasulo` for the out-of-order back end. The fmax
counts only paths between registers: the I/O delays are a fifth of the period
on each side of a port, so a port's slack shrinks faster than the period. The
tables behind the report are in `reports/nangate45/frost/base/`:
`<database>_paths.tsv` has the worst path to every endpoint,
`<database>_register_paths.tsv` the worst path for each pair of core clocks
and launching edge, including its launch and capture edge times without
clock latency, `<database>_worst_paths.json` the worst 100 core clock paths
pin by pin, and `<database>_worst_paths.rpt` the worst five paths of each clock.

Synthesis does not depend on the period. ORFS hands the period to ABC as a
delay target, but the ABC script it runs maps for delay without reading the
target, so every period gives the same netlist: the 1.6 ns build's
`1_synth.odb` matches the default build's byte for byte. The period steers
the steps after synthesis, which resize gates in the floorplan, weight the
global placement, and finish timing repair at clock tree synthesis.

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
its worst path, after global routing. These mocked-memory paths have a full
core cycle. The 3.103 ns run repairs a path only until it meets 3.103 ns, so
its column shows how each family comes out of synthesis and placement, and
the 1.6 ns column what the repairs reach.

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
SRAM macros, the paths from the L1D's tags to its read-way selection
registers fail worst at the X3's clock, and with the X3's 2 MiB L2, those
from the L2 data
([Results with the SRAM macros](#results-with-the-sram-macros)).

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
four CPUs and 16 GB of memory. The global routing, detailed routing, and
final report jobs add swap space. Each job also deletes preinstalled
toolchains to make room for the databases.

Detailed routing reuses the pin access saved in the global routing database.
On the same 256 KiB input with four threads, `-no_pin_access` cut its CPU
time from 24,280 to 18,282 seconds, about 25%, and produced byte-identical
routed DEF with no DRC or antenna violations. The detailed routing job
takes 3 to 3.5 hours, below the six-hour job limit.

Those three steps hold the design's cell connectivity, routing guides,
and power-grid shapes in memory. The final report also runs IR drop
analysis and renders layout images. With 16 threads, global routing,
detailed routing, and the final report peak at 17, 22, and 28 GB.

## The ORFS image

[`orfs.py`](orfs.py) pins the image by digest:
`openroad/orfs:26Q3-705-gecb3cfdeb@sha256:6da005d1c3447799f7401215174196c75ba9ec7e28417624d0c20225f85d594c`.
It is the ORFS 26Q4 quarterly release, commit `ecb3cfdeb`, which Docker Hub
publishes under its `git describe` tag. It contains Yosys 0.68, OpenROAD
`c487fc70`, and KLayout 0.30.12; the frost image's Yosys 0.70 reads the same
sources. To update the image, recheck `detail_route.tcl`'s default arguments
and the pin access assumptions, update `ORFS_IMAGE`, `DETAILED_ROUTE_ARGS`,
and the guard in `tests/test_asic_flow.py` as needed, and run the whole flow.

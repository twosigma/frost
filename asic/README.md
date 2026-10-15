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
./asic/orfs.py summary                # summarize asic/build again
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
   stages with `--from`.
3. `make elapsed` and the flow's metrics become `asic/build/summary.md`.

The stages follow ORFS's make targets: `grt` is global routing and `route`
is detailed routing. `--from` skips the first step and reruns every stage
from the one it names, whatever the files' timestamps, from the results of
the stage before it.

| Output in `asic/build` | Contents |
| --- | --- |
| `summary.md` | Cell count and area, worst slack for each clock, elapsed time and peak memory for each step, and the mocked memories |
| `orfs.log` | Output of both containers |
| `logs/nangate45/frost/base/` | A log and a metrics file for each step |
| `reports/nangate45/frost/base/` | Timing, DRC, and congestion reports, including `6_clock_slack.rpt` |
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
| `core_clk` | `i_clk` | 3.103 ns (322.265625 MHz) | The X3 CPU clock |
| `core_clk_div4` | `i_clk_div4` | 12.412 ns | The program-loading port's clock, a quarter of the CPU clock |
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
status inputs) are not timed. The core clock target only reports timing; the
flow repairs timing with ORFS's default effort.

The mocked memories add paths between the two core clocks that SRAM macros do
not have: the instruction memory's single row is written on `i_clk_div4` and
read by registers on `i_clk`, and the data memory's reclocked programming
port meets the `i_clk_div4` logic with one core cycle. The flow times and
repairs them like any other path.

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

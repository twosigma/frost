# FROST FPGA Board Support

Each board subdirectory holds its top-level RTL wrapper, synthesis file list,
and pin constraints. Xilinx IP generation lives under `fpga/build/`.

## Supported Boards

| Board     | FPGA                               | CPU Clock | Cache hierarchy → main memory                          |
|-----------|------------------------------------|-----------|--------------------------------------------------------|
| [X3](x3/) | Xilinx Alveo X3522PV (UltraScale+) | 300 MHz   | 128 KiB L1D + 16 KiB L1I → 2 MiB URAM L2 → 1 GiB DDR4 |

X3 provides 256 KiB of local BRAM and 1 GiB of cached DDR at `0x8000_0000`.
The CPU starts after DDR calibration completes and the region has been
written once.

## Architecture Overview

The X3 wrapper connects three blocks: `xilinx_frost_subsystem` for the CPU,
BRAM, loading, and debug; `ddr_subsys` for DDR4 and its JTAG loader; and
`x3_nic_gty` for the Ethernet transceiver and MAC clocks.

[![X3 board integration: CPU and divided clocks, separate BRAM and DDR loaders, BSCAN debug, shared DDR AXI, and reset sequencing](../docs/diagrams/x3-board-integration.svg)](../docs/diagrams/x3-board-integration.svg)

Module boundaries are shown; individual modules span several clock domains.
The core and runtime memory ports use the CPU clock, while UART, software
loading, and the common subsystem's reset timers use CPU clock/4. BSCAN and
the DTM transport use JTAG TCK and cross into the CPU domain. SmartConnect
bridges the CPU, /4, and independent DDR UI clocks; the DDR controller has a
separate 300 MHz reference input.

The cache bridge presents 256-bit AXI with addresses relative to the cached
region. SmartConnect combines it with the DDR JTAG master and converts to
the controller's 512-bit memory AXI interface. The first 1 GiB is mapped at
CPU address `0x8000_0000`; the controller's ECC management interface is
reachable only from the DDR JTAG master, at region offset `0x4000_0000`.

The 72-bit DDR interface uses ECC. After calibration, `x3_ddr_init` zeroes
the exposed region using full-width writes so every location has valid ECC
before any read. This takes about 110 ms at the rated clock. Read the
controller's error state with `fpga/ddr_ecc/ddr_ecc_status.py`.

DDR calibration passes through a two-flop synchronizer in `x3_frost`, and
that, the MMCM lock and the region writer's completion together release the
common subsystem reset and the DDR JTAG master, so nothing reads or writes the
array before it has been written. DDR transport reset depends on MMCM lock;
startup and image-load holds apply separately inside the common subsystem. The diagram selects the board-level connections; see the
[CPU architecture diagram](../docs/diagrams/frost-architecture.svg) for the
core and cache hierarchy.

## JTAG-based software loading

Programs load over JTAG without reprogramming the FPGA bitstream. Program the
bitstream once, then run `fpga/load_software/load_software.py` (a Vivado
hardware-manager Tcl flow) for each new image. One load runs as follows:

1. If the app emitted a non-empty `sw_ddr.txt`, the loader writes the first
   word of the low-BRAM image to address 0 to assert the image-load reset,
   then bursts the cached-region image into DDR through the board's second
   JTAG-AXI master (`jtag_axi_ddr` inside `ddr_subsys`). A multi-MB image
   outlasts the reset counter, so the loader repeats that low-BRAM write
   between bursts to re-arm it.
2. The loader writes the full low-BRAM image (`sw.txt`) from address 0.
3. The CPU starts when the image-load reset counter expires after the last
   write.

The image-load reset in `xilinx_frost_subsystem` runs on the /4 clock. Every
low-BRAM write asserts the CPU reset and restarts a 27-bit cycle counter, so
the CPU is released about 1.8 s after the last write on X3's 75 MHz /4 clock
with the loading sequence above keeping it in reset throughout the transfer.
A 16-bit startup counter also delays the programming IP and CPU after the
board reset releases. `frost` then synchronizes its combined reset into the
CPU and /4 domains.

## RISC-V debug over BSCAN (OpenOCD)

The RISC-V debug module's transport shares the FPGA's own JTAG
TAP. `xilinx_frost_subsystem` instantiates two `BSCANE2` USER chains, USER3
for the DTM's `dtmcs` register and USER4 for `dmi`; the Vivado debug hub
behind `jtag_axi` keeps USER1. The subsystem passes the BSCAN bundle into
`frost` with `DEBUG_JTAG_TAP=0`. OpenOCD reaches the DTM through the FPGA's
IDCODE and USER instructions (`riscv set_ir idcode 0x09`, `dtmcs 0x22`,
`dmi 0x23`; six-bit FPGA IR). The configurations live in
`fpga/debug/`. The cable has one owner: close Vivado's hw_server (the
loader/programmer) before starting OpenOCD, and vice versa.

## Directory Structure

```
boards/
├── README.md                    # This file
├── xilinx_frost_subsystem.sv    # Common subsystem (JTAG loader, BSCAN debug chains, BRAM, CPU, reset)
└── x3/
    ├── x3_frost.sv              # Clocks, DDR integration, calibration/reset, common subsystem
    ├── x3_ddr_init.sv           # Writes the DDR region once after calibration (the array is ECC-checked)
    ├── x3_nic_gty.sv            # NIC GTY transceiver: wizard core, free-running clock, reset supervisor
    ├── x3_frost.f               # File list for synthesis tools
    └── constr/
        └── x3.xdc               # Pin assignments & timing constraints
```

The build flow generates the Xilinx IP cores (`jtag_axi_0`, `axi_bram_ctrl_0`),
for DDR-capable boards the `ddr_subsys` block design, and for boards with a
NIC transceiver its wizard core during synthesis (`fpga/build/build_step.tcl`
sources `fpga/build/<board>_ddr_bd.tcl` and `fpga/build/<board>_gty_ip.tcl`),
so no IP output tied to one Vivado release is checked in.

## Building

### Prerequisites

- Xilinx Vivado (see [main README](../README.md#prerequisites) for validated versions)
- Target FPGA development board
- USB cable for JTAG programming

### Synthesis

For automated builds, use:
```bash
./fpga/build/build.py x3
```

For manual Vivado project setup:
1. Create a new Vivado project targeting your board's FPGA
2. Add the RTL sources:
   - The CPU core, as listed in `hw/rtl/frost.f`
   - `boards/xilinx_frost_subsystem.sv` (common subsystem)
   - The board-specific wrappers (e.g., `x3/x3_nic_gty.sv` and `x3/x3_frost.sv`)
3. Add the constraint file from `constr/`
4. Generate the Xilinx IP cores (`jtag_axi_0`, `axi_bram_ctrl_0`), when the
   board has DDR its `ddr_subsys` block design, and when it has a NIC
   transceiver its wizard core; `fpga/build/build_step.tcl`,
   `fpga/build/<board>_ddr_bd.tcl` and `fpga/build/<board>_gty_ip.tcl` hold
   their configuration
5. Set the top module (e.g., `x3_frost`)
6. Run synthesis and implementation
7. Generate the bitstream

### Programming Software

After the FPGA is programmed with the bitstream:

1. Run `fpga/load_software/load_software.py <board> <app>`. It rebuilds the
   application for the selected board by default.
2. The loader bursts the cached-region image (`sw_ddr.txt`, when non-empty)
   into DDR, then writes `sw.txt` to low BRAM; the CPU leaves reset once the
   image-load counter expires (see
   [JTAG-based software loading](#jtag-based-software-loading)).

## I/O Connections

### X3

| Signal       | Direction | Pin  | Description                            |
|--------------|-----------|------|----------------------------------------|
| `i_sysclk_p` | Input     | AK23 | 300 MHz differential clock (positive) |
| `i_sysclk_n` | Input     | AL23 | 300 MHz differential clock (negative) |
| `o_uart_tx`  | Output    | AP24 | UART transmit for debug console        |
| `i_uart_rx`  | Input     | AR24 | UART receive for debug console input   |
| `i_nic_refclk_p` / `i_nic_refclk_n` | Input | P9 / P8 | 161.1328125 MHz Ethernet reference clock (MGTREFCLK0, quad 231) |
| `o_nic_txp` / `o_nic_txn` | Output | J7 / J6 | NIC transceiver TX (GTY X0Y28, DSFP28 cage labelled 2, lane 1) |
| `i_nic_rxp` / `i_nic_rxn` | Input | K4 / K3 | NIC transceiver RX (GTY X0Y28) |

Use 115200 baud, 8 data bits, no parity, and 1 stop bit (8N1) for the board
UART debug console.

## Clock Generation

An MMCM generates each CPU clock from the board reference oscillator:

| Board | Input Clock | VCO Freq | CPU Clock | Calculation     |
|-------|-------------|----------|-----------|-----------------|
| X3    | 300 MHz     | 1200 MHz | 300 MHz   | 300 × 4 / 1 / 4 |

The X3 top takes a `CPU_CLK_DIV` parameter (`build.py --cpu-clock-div N`)
that multiplies the MMCM output divide, so a functional-validation bitstream
runs the CPU at 300/N MHz with the same RTL; the reference oscillator and the
DDR4 controller clocking are unchanged.

It also takes a `PERF_COUNTERS` parameter (`build.py --perf-counters`; left
out of a full-rate build, included in a divided-clock build unless
`--no-perf-counters`): 1 includes the profiling counters behind the `mperf*`
CSRs, 0 leaves them out of the netlist, those CSRs read zero, and
`mperfsel`/`mperfctl` ignore writes.

Two `BUFGCE_DIV` instances share the MMCM output: divide-by-one supplies the
CPU clock, and divide-by-four supplies the loader IP, UART, and reset timers.
The /4 clock is 75 MHz by default and 75/N MHz when `CPU_CLK_DIV=N`. The
DDR controller's dedicated 300 MHz reference is independent of both.

The NIC's MAC clocks come from its GTY transceiver (`x3_nic_gty.sv`): TX and
recovered RX user clocks at 161.13 MHz, derived from the 161.1328125 MHz
reference clock, unaffected by `CPU_CLK_DIV`. The transceiver's reset
controller runs on a third `BUFGCE_DIV`, which halves the 300 MHz input
before the MMCM (150 MHz), so it runs from configuration and depends on
neither the MMCM nor the transceiver.

## Adding Support for New Boards

To support another Xilinx FPGA board:

1. Create a new subdirectory named after the board
2. Start from the existing `x3_frost.sv` wrapper
3. Adapt the clock generation:
   - Set the MMCM parameters for the board's input clock frequency
   - Drive the CPU clock from CLKOUT0, and derive the /4 clock with a suitable
     global clock divider for the target family
4. Instantiate `xilinx_frost_subsystem`. For a DDR-capable board, also
   instantiate its `ddr_subsys` block design, wire the FROST cache-bridge AXI,
   and hold the CPU in reset until `mem_ok` (DDR calibrated), and, on a board
   whose memory is ECC-checked, until the region has been written. Pass
   `ENABLE_CACHED_TIER=1` and `USE_BEHAVIORAL_DDR=0`; the full-system hierarchy
   includes a 2 MiB UltraRAM L2, so the board must have sufficient UltraRAM.
   A BRAM-only board leaves the cached tier disabled and needs no DDR block design
5. Create a constraint file with the board's pin assignments. For a
   DDR-capable board, include the DDR pins unless they come from a MIG
   `.prj`/board interface
6. Update the file list (`.f` file) to include the subsystem
7. Add the board's FPGA part and its `has_ddr` and `has_gty` capabilities to
   `board_build_configs` in `fpga/build/build_step.tcl`. For a DDR-capable
   board, add `fpga/build/<board>_ddr_bd.tcl` for its `ddr_subsys` block design.
   The CPU port's `S00_AXI` range determines the memory advertised to Linux.
   For a board with a NIC transceiver, add `fpga/build/<board>_gty_ip.tcl` for
   its wizard core. The Tcl flow derives the wrapper, file-list, constraint,
   DDR-script, DDR-creation, transceiver-script and transceiver-creation
   procedure names from `<board>`; it skips the DDR pair for a BRAM-only board
   and the transceiver pair for a board without a transceiver
8. Register the board in the remaining FPGA-tool metadata:
   - `BOARD_CONFIG` in `fpga/build/build.py` for its clock, family, and tuned
     synthesis directive
   - `BOARD_INFO` in `fpga/build/extract_timing_and_util_summary.py`
   - `BOARD_CONFIG` in `fpga/load_software/load_software.py` for its clock,
     CoreMark iterations, and DDR capability
   - `BOARD_VENDOR_INFO` in `fpga/common/hw_target.py` and all three maps in
     `fpga/common/hw_defaults.py` for JTAG, UART, and timeout defaults
   - `supported_boards` in `fpga/program_bitstream/program_bitstream.tcl` for
     direct Tcl use. The Python programmer derives its choices from
     `BOARD_VENDOR_INFO`; the regression, soak, and sweep tools likewise derive
     their choices from the registries above
9. Calibrate the board's CoreMark-PRO `hardware_iterations` entries in
   `sw/apps/software_registry.py`. Set `hardware_timeout_minimums` if untimed
   setup exceeds the board's default timeout. Optionally record score gates
   in `BASELINE_SCORES` in `fpga/hw_regression.py`
10. Update this README with the new board's specifications

Before building, check that the MMCM VCO frequency produces the target CPU
clock, that the timing constraints match the input clock period, that the I/O
standards match the board's bank voltages, and that the board-appropriate DDR
controller IP is configured for its soldered or SODIMM memory. A non-Xilinx
FPGA (Altera, Lattice) would need a new subsystem, since
`xilinx_frost_subsystem` uses Xilinx IP and `BSCANE2` primitives.

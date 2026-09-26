# FPGA Board Support

The supported board is the **Alveo X3522PV (X3)**: a 322.265625 MHz CPU,
256 KiB BRAM, 16 KiB L1I, 128 KiB L1D, 2 MiB URAM L2, and 1 GiB DDR4.
See the [FPGA guide](../fpga/README.md) for build, programming, and loading
commands.

## Architecture Overview

[![X3 clocks, memory, loading, and debug connections](../docs/diagrams/x3-board-integration.svg)](../docs/diagrams/x3-board-integration.svg)

| Module | Role |
|--------|------|
| `xilinx_frost_subsystem.sv` | CPU and BRAM, JTAG software loader, BSCAN debug, reset timers |
| `x3/x3_frost.sv` | Board clocks, DDR and NIC integration, reset sequencing |
| `x3/x3_ddr_init.sv` | Initializes the exposed DDR region with valid ECC |
| `x3/x3_nic_gty.sv` | Ethernet transceiver, MAC clocks, transceiver reset supervisor |
| `x3/constr/x3.xdc` | Pin and timing constraints |

`x3/x3_frost.f` lists the board RTL. The Vivado flow generates the loader,
DDR, and transceiver IP from `fpga/build/build_step.tcl`, `x3_ddr_bd.tcl`, and
`x3_gty_ip.tcl`.

The cache hierarchy's bridge issues 256-bit AXI transactions with
region-relative addresses. A SmartConnect merges them with the DDR JTAG
master, crosses the CPU, CPU/4, and DDR clocks, and converts to the
controller's 512-bit interface. CPU address `0x80000000` maps the first 1 GiB.
ECC management sits at region offset `0x40000000` and is reachable only from
the DDR JTAG master.

After calibration, `x3_ddr_init` zeroes the region so every word has valid ECC
(about 0.1 seconds). It writes whole 512-bit controller words, as aligned
two-beat bursts: a half-word write would make the controller read the
uninitialized other half to recompute ECC. The CPU and the DDR loader leave
reset once calibration, MMCM lock, and initialization are all complete. Check
for ECC errors with `fpga/ddr_ecc/ddr_ecc_status.py`.

## Clock Generation

| Domain | Clock |
|--------|-------|
| CPU | 300 MHz input / 8 × 34.375 / 4 = 322.265625 MHz |
| Loader, UART, reset timers | CPU/4 = 80.56640625 MHz |
| DDR reference | Independent 300 MHz |
| Ethernet TX / recovered RX | GTY user clocks, about 161.13 MHz |
| GTY reset controller | Input/2 = 150 MHz, independent of the MMCM and the link |

`build.py --cpu-clock-div N` sets the board top's `CPU_CLK_DIV` generic,
which divides the CPU and CPU/4 clocks by N; the DDR and Ethernet clocks do
not change. Load software with the matching clock. The `PERF_COUNTERS`
generic includes the profiling counters (`--perf-counters`).

## JTAG-based software loading

The loader writes images through two JTAG-to-AXI masters, one for low BRAM
and one for DDR (`jtag_axi_ddr`):

1. A first BRAM write puts the CPU in reset.
2. The DDR image (`sw_ddr.txt`), if any, is written to DDR. Periodic BRAM
   writes keep the CPU in reset meanwhile.
3. The BRAM image (`sw.txt`) is written.

Every BRAM write restarts a 27-bit counter on the CPU/4 clock, and the CPU
leaves reset when the counter runs out: about 1.67 seconds after the last
write at 322.265625 MHz. A separate 16-bit counter holds the loader and CPU in
reset briefly after board reset, until the clocks are stable. `frost`
synchronizes resets into both clock domains.

## RISC-V debug over BSCAN (OpenOCD)

Debug shares the FPGA's own TAP. BSCANE2 USER3 carries `dtmcs`, USER4 carries
`dmi`, and the Vivado debug hub keeps USER1. The subsystem sets
`DEBUG_JTAG_TAP=0`. The six-bit IR uses IDCODE `0x09`, DTMCS `0x22`, and DMI
`0x23`; the OpenOCD configurations are in `fpga/debug/`. Only one process can
own the cable, so stop Vivado's hardware server before starting OpenOCD, and
the reverse.

## I/O Connections

| Signal       | Direction | Pin  | Description                            |
|--------------|-----------|------|----------------------------------------|
| `i_sysclk_p` | Input     | AK23 | 300 MHz differential clock (positive) |
| `i_sysclk_n` | Input     | AL23 | 300 MHz differential clock (negative) |
| `o_uart_tx`  | Output    | AP24 | UART transmit for debug console        |
| `i_uart_rx`  | Input     | AR24 | UART receive for debug console input   |
| `i_nic_refclk_p` / `i_nic_refclk_n` | Input | P9 / P8 | 161.1328125 MHz Ethernet reference clock (MGTREFCLK0, quad 231) |
| `o_nic_txp` / `o_nic_txn` | Output | J7 / J6 | NIC transceiver TX (GTY X0Y28, DSFP28 cage labelled 2, lane 1) |
| `i_nic_rxp` / `i_nic_rxn` | Input | K4 / K3 | NIC transceiver RX (GTY X0Y28) |

The UART console uses 115200 baud, 8N1.

## Adding Support for New Boards

To support another Xilinx FPGA board:

1. Create a subdirectory named after the board.
2. Start from the `x3_frost.sv` wrapper.
3. Adapt the clock generation: set the MMCM parameters for the board's input
   clock, drive the CPU clock from CLKOUT0, and derive the /4 clock with a
   global clock divider suitable for the FPGA family.
4. Instantiate `xilinx_frost_subsystem`. For a board with DDR, also
   instantiate its `ddr_subsys` block design, wire the cache bridge's AXI
   port to it, and pass `ENABLE_CACHED_TIER=1` and `USE_BEHAVIORAL_DDR=0`.
   Hold the CPU in reset until DDR calibration (`mem_ok`) and, if the memory
   has ECC, until the region has been written. The cached tier includes a
   2 MiB UltraRAM L2, so the FPGA needs enough UltraRAM. A BRAM-only board
   leaves the cached tier off and needs no DDR block design.
5. Write a constraint file with the board's pin assignments, including the
   DDR pins unless a MIG `.prj` or board interface supplies them.
6. Add the subsystem to the board's `.f` file list.
7. Add the board's FPGA part and its `has_ddr` and `has_gty` capabilities to
   `board_build_configs` in `fpga/build/build_step.tcl`. The Tcl flow derives
   the board's wrapper, file-list, constraint, and IP-creation procedure names
   from its name. A board with DDR also needs `fpga/build/<board>_ddr_bd.tcl`
   for its `ddr_subsys` block design; the CPU port's `S00_AXI` range sets the
   memory size advertised to Linux. A board with a NIC transceiver needs
   `fpga/build/<board>_gty_ip.tcl` for its transceiver wizard core.
8. Register the board in the FPGA tools:
   - `BOARD_CONFIG` in `fpga/build/build.py`: clock, family, and synthesis
     directive.
   - `BOARD_INFO` in `fpga/build/extract_timing_and_util_summary.py`.
   - `BOARD_CONFIG` in `fpga/load_software/load_software.py`: clock,
     CoreMark iterations, and DDR support.
   - `BOARD_VENDOR_INFO` in `fpga/common/hw_target.py`, and
     `DEFAULT_TARGETS`, `DEFAULT_SERIALS`, and `DEFAULT_TIMEOUTS` in
     `fpga/common/hw_defaults.py`.
   - `supported_boards` in `fpga/program_bitstream/program_bitstream.tcl`,
     for direct Tcl use. The Python programmer, regression, soak, and sweep
     tools take their board lists from the registries above.
9. Calibrate the board's CoreMark-PRO `hardware_iterations` in
   `sw/apps/software_registry.py`, and set `hardware_timeout_minimums` if
   setup takes longer than the board's default timeout. Optionally record
   score gates in `BASELINE_SCORES` in `fpga/hw_regression.py`.
10. Add the board to this README.

Before the first build, check that:

- the MMCM VCO frequency and dividers produce the target CPU clock;
- the timing constraints match the input clock period;
- the I/O standards match the board's bank voltages;
- the DDR controller IP matches the board's soldered or SODIMM memory.

A non-Xilinx FPGA would need a new subsystem, because
`xilinx_frost_subsystem` uses Xilinx IP and `BSCANE2` primitives.

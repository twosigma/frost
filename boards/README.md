# FROST FPGA Board Support

Each board subdirectory holds that board's clock generation, pin constraints,
top-level wrapper, and Xilinx IP setup.

## Supported Boards

| Board     | FPGA                               | CPU Clock | Cache hierarchy → main memory                          |
|-----------|------------------------------------|-----------|--------------------------------------------------------|
| [X3](x3/) | Xilinx Alveo X3522PV (UltraScale+) | 300 MHz   | 128 KiB L1D + 16 KiB L1I → 2 MiB URAM L2 → 1 GiB DDR4 |

X3 ships the RV64GCB configuration and exposes 256 KiB of uncached low BRAM
plus a 1 GiB cached region at `0x8000_0000` for execute-from-DDR code, heap,
and large data. Low-BRAM data access is 1-cycle. Instruction metadata is
1-cycle for windows wholly in `[0, 64 KiB)` and takes one request repeat otherwise.

The DDR controller lives in a small `ddr_subsys` block design that the build
flow assembles from `fpga/build/x3_ddr_bd.tcl`. The design holds the DDR4
controller IP, a SmartConnect front end that carries the FROST cache-bridge AXI
and a JTAG-AXI master for DDR image loading, and the calibration and reset
sequencing. The board top holds the CPU in reset until the controller
calibrates; `mem_ok` is synchronized into the core clock domain before it
releases the reset. All nine CoreMark-PRO workloads run on X3.

## Architecture Overview

Each board wrapper handles clock generation and instantiates a common `xilinx_frost_subsystem` module:

```
┌───────────────────────────────────────────────────────────────────────────┐
│                           Board Top Module                                │
│                              (x3_frost)                                   │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                        Clock Generation                             │  │
│  │                                                                     │  │
│  │  Clock      ┌────────┐   ┌──────┐   ┌────────┐                      │  │
│  │  Input ────>│ IBUF/  │──>│ MMCM │──>│  BUFG  │──> CPU Clock         │  │
│  │             │ IBUFDS │   └──┬───┘   └────────┘    (300 MHz)         │  │
│  │             └────────┘      │                                       │  │
│  │                             └──────>┌────────┐                      │  │
│  │                                     │  BUFG  │──> /4 Clock          │  │
│  │                                     └────────┘    (75 MHz)          │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                    xilinx_frost_subsystem                           │  │
│  │                                                                     │  │
│  │  ┌───────────────────────────────────────────────────────────────┐  │  │
│  │  │                  JTAG Software Loading (/4 clock)             │  │  │
│  │  │                                                               │  │  │
│  │  │  JTAG     ┌─────────────┐  AXI   ┌─────────────────┐          │  │  │
│  │  │  Port ───>│ jtag_axi_0  │───────>│ axi_bram_ctrl_0 │          │  │  │
│  │  │           └─────────────┘        └────────┬────────┘          │  │  │
│  │  │                                           │                   │  │  │
│  │  │      ┌────────────────────────────────────┘                   │  │  │
│  │  │      │  BRAM Interface                                        │  │  │
│  │  │      v  (en, we, addr, wrdata)                                │  │  │
│  │  └──────┼────────────────────────────────────────────────────────┘  │  │
│  │         │                                                           │  │
│  │  ┌──────┼────────────────────────────────────────────────────────┐  │  │
│  │  │      │                    FROST CPU                           │  │  │
│  │  │      v                                                        │  │  │
│  │  │  ┌─────────────┐   ┌────────────────────┐   ┌─────────────┐   │  │  │
│  │  │  │  Low BRAM   │<──│  FROST OOO CPU     │   │  UART TX    │───┼──┼─>│
│  │  │  │ code/data   │   │ (IF-PD-ID+Tomasulo)│   │  UART RX    │<──┼──┼──│
│  │  │  │  + loader   │   └────────────────────┘   └─────────────┘   │  │  │
│  │  │  └─────────────┘                                              │  │  │
│  │  │                                                               │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────┐  │  │  │
│  │  │  │ Image Load Reset Logic                                  │  │  │  │
│  │  │  │ • Detects JTAG software-image loads                     │  │  │  │
│  │  │  │ • Holds CPU in reset during software loading            │  │  │  │
│  │  │  │ • Releases reset after counter expires                  │  │  │  │
│  │  │  └─────────────────────────────────────────────────────────┘  │  │  │
│  │  └───────────────────────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

The diagram is simplified. Low BRAM is the uncached region, with the
instruction-metadata latency split described above. High-address instruction
fetch and data accesses go through the L1I/L1D cache hierarchy and the board's
DDR subsystem.

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
and never executes a partial or stale image.

## RISC-V debug over BSCAN (OpenOCD)

The RISC-V debug module's transport (Phase 3 M3) shares the FPGA's own JTAG
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
    ├── x3_frost.sv              # Top-level board wrapper (clock generation)
    ├── x3_frost.f               # File list for synthesis tools
    └── constr/
        └── x3.xdc               # Pin assignments & timing constraints
```

The build flow generates the Xilinx IP cores (`jtag_axi_0`, `axi_bram_ctrl_0`)
and, for DDR-capable boards, the `ddr_subsys` block design during synthesis
(`fpga/build/build_step.tcl` sources `fpga/build/<board>_ddr_bd.tcl`), so no IP
output tied to one Vivado release is checked in.

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
   - The board-specific wrapper (e.g., `x3/x3_frost.sv`)
3. Add the constraint file from `constr/`
4. Generate the Xilinx IP cores (`jtag_axi_0`, `axi_bram_ctrl_0`) and, when the
   board has DDR, its `ddr_subsys` block design; `fpga/build/build_step.tcl`
   and `fpga/build/<board>_ddr_bd.tcl` hold their configuration
5. Set the top module (e.g., `x3_frost`)
6. Run synthesis and implementation
7. Generate the bitstream

### Programming Software

After the FPGA is programmed with the bitstream:

1. Build the application under `sw/apps/<app>/`.
2. Run `fpga/load_software/load_software.py <board> <app>`.
3. The loader bursts the cached-region image (`sw_ddr.txt`, when non-empty)
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

Use 115200 baud, 8 data bits, no parity, and 1 stop bit (8N1) for the board
UART debug console.

## Clock Generation

An MMCM generates each CPU clock from the board reference oscillator:

| Board | Input Clock | VCO Freq | CPU Clock | Calculation     |
|-------|-------------|----------|-----------|-----------------|
| X3    | 300 MHz     | 1200 MHz | 300 MHz   | 300 × 4 / 1 / 4 |

X3 divides the CPU clock with a `BUFGCE_DIV` to produce the 75 MHz /4 clock
for the JTAG loader IP and UART.

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
   and hold the CPU in reset until `mem_ok` (DDR calibrated). Pass
   `ENABLE_CACHED_TIER=1` and `USE_BEHAVIORAL_DDR=0`; the full-system hierarchy
   includes the UltraRAM L2. A BRAM-only board leaves the cached tier disabled
   and needs no DDR block design
5. Create a constraint file with the board's pin assignments. For a
   DDR-capable board, include the DDR pins unless they come from a MIG
   `.prj`/board interface
6. Update the file list (`.f` file) to include the subsystem
7. Add the board's FPGA part and `has_ddr` capability to
   `board_build_configs` in `fpga/build/build_step.tcl`. For a DDR-capable
   board, add `fpga/build/<board>_ddr_bd.tcl` for its `ddr_subsys` block design.
   The Tcl flow derives the wrapper, file-list, constraint, DDR-script, and
   DDR-creation procedure names from `<board>`; it skips the latter two for a
   BRAM-only board
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
   `sw/apps/software_registry.py`. Optionally record silicon score gates in
   `BASELINE_SCORES` in `fpga/hw_regression.py`
10. Update this README with the new board's specifications

Before building, check that the MMCM VCO frequency produces the target CPU
clock, that the timing constraints match the input clock period, that the I/O
standards match the board's bank voltages, and that the board-appropriate DDR
controller IP is configured for its soldered or SODIMM memory. A non-Xilinx
FPGA (Altera, Lattice) would need a new subsystem, since
`xilinx_frost_subsystem` uses Xilinx IP and `BSCANE2` primitives.

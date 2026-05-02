# FROST FPGA Board Support

This directory contains board-specific wrappers that enable the FROST RISC-V processor to run on real FPGA hardware. Each subdirectory targets a specific development board with its own clock configuration, pin constraints, and Xilinx IP cores.

## Supported Boards

| Board                  | FPGA                               | CPU Clock  | Features                 |
|------------------------|------------------------------------|------------|--------------------------|
| [Genesys2](genesys2/)  | Xilinx Kintex-7 (xc7k325t)         | 133.33 MHz | Entry-level development  |
| [X3](x3/)              | Xilinx Alveo X3522PV (UltraScale+) | 300 MHz    | High-performance target  |

## Architecture Overview

Each board wrapper handles clock generation and instantiates a common `xilinx_frost_subsystem` module:

```
┌───────────────────────────────────────────────────────────────────────────┐
│                           Board Top Module                                │
│                      (genesys2_frost, x3_frost)                           │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                        Clock Generation                             │  │
│  │                                                                     │  │
│  │  Clock      ┌────────┐   ┌──────┐   ┌────────┐                      │  │
│  │  Input ────>│ IBUF/  │──>│ MMCM │──>│  BUFG  │──> CPU Clock         │  │
│  │             │ IBUFDS │   └──┬───┘   └────────┘    (80-300 MHz)      │  │
│  │             └────────┘      │                                       │  │
│  │                             └──────>┌────────┐                      │  │
│  │                                     │  BUFG  │──> /4 Clock          │  │
│  │                                     └────────┘    (20-80 MHz)       │  │
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
│  │  │  │ Instruction │<──│  FROST OOO CPU     │   │  UART TX    │───┼──┼─>│
│  │  │  │   Memory    │   │ (IF-PD-ID+Tomasulo)│   │  UART RX    │<──┼──┼──│
│  │  │  │   (BRAM)    │   └────────────────────┘   └─────────────┘   │  │  │
│  │  │  └─────────────┘                                              │  │  │
│  │  │                                                               │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────┐  │  │  │
│  │  │  │ Image Load Reset Logic                                  │  │  │  │
│  │  │  │ • Detects JTAG writes to instruction memory             │  │  │  │
│  │  │  │ • Holds CPU in reset during software loading            │  │  │  │
│  │  │  │ • Releases reset after counter expires                  │  │  │  │
│  │  │  └─────────────────────────────────────────────────────────┘  │  │  │
│  │  └───────────────────────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

## Key Features

### JTAG-Based Software Loading

Programs are loaded into instruction memory via JTAG without reprogramming the FPGA bitstream. This enables rapid software iteration:

1. Synthesize and program the FPGA bitstream once
2. Load new software via Vivado Hardware Manager as needed
3. CPU automatically resets during loading and starts execution when complete

### Automatic Reset Synchronization

The board wrappers include logic that:
- Detects when software is being written to instruction memory
- Holds the CPU in reset during the load process
- Releases reset automatically when loading completes

This prevents the CPU from executing partially-loaded or stale instructions.

## Directory Structure

```
boards/
├── README.md                    # This file
├── xilinx_frost_subsystem.sv    # Common subsystem (JTAG, BRAM, CPU, reset)
├── genesys2/
│   ├── genesys2_frost.sv        # Top-level board wrapper (clock generation)
│   ├── genesys2_frost.f         # File list for synthesis tools
│   └── constr/
│       └── genesys2.xdc         # Pin assignments & timing constraints
└── x3/
    ├── x3_frost.sv              # Top-level board wrapper (clock generation)
    ├── x3_frost.f               # File list for synthesis tools
    └── constr/
        └── x3.xdc               # Pin assignments & timing constraints
```

**Note:** Xilinx IP cores (jtag_axi, axi_bram_ctrl) are generated on-the-fly during synthesis to ensure compatibility across Vivado versions.

## Building

### Prerequisites

- Xilinx Vivado (see [main README](../README.md#prerequisites) for validated versions)
- Target FPGA development board
- USB cable for JTAG programming

### Synthesis

For automated builds, use the build script (recommended):
```bash
./fpga/build/build.py <board>   # e.g., genesys2, x3
```

For manual Vivado project setup:
1. Create a new Vivado project targeting your board's FPGA
2. Add the RTL sources:
   - All files from `hw/rtl/` (the CPU core)
   - `boards/xilinx_frost_subsystem.sv` (common subsystem)
   - The board-specific wrapper (e.g., `genesys2/genesys2_frost.sv`)
3. Add the constraint file from `constr/`
4. Generate the required Xilinx IP cores (jtag_axi_0, axi_bram_ctrl_0) - see `fpga/build/build.tcl` for configuration
5. Set the top module (e.g., `genesys2_frost`)
6. Run synthesis and implementation
7. Generate the bitstream

### Programming Software

After the FPGA is programmed with the bitstream:

1. Open Vivado Hardware Manager
2. Connect to the target board
3. Use the JTAG-AXI core to write your program to instruction memory:
   ```tcl
   # Example: Write instruction words starting at address 0
   create_hw_axi_txn write_txn [get_hw_axis hw_axi_1] \
       -type write -address 0x00000000 -data {<your_program_hex>}
   run_hw_axi write_txn
   ```

## I/O Connections

### Genesys2

| Signal        | Direction | Pin  | Description                              |
|---------------|-----------|------|------------------------------------------|
| `i_sysclk_p`  | Input     | AD12 | 200 MHz differential clock (positive)   |
| `i_sysclk_n`  | Input     | AD11 | 200 MHz differential clock (negative)   |
| `i_pb_resetn` | Input     | R19  | Push-button reset (active-low)           |
| `o_uart_tx`   | Output    | Y23  | UART transmit for debug console          |
| `i_uart_rx`   | Input     | Y20  | UART receive for debug console input     |
| `o_fan_pwm`   | Output    | W19  | Fan PWM control (disabled, prevents noise) |

### X3

| Signal       | Direction | Pin  | Description                            |
|--------------|-----------|------|----------------------------------------|
| `i_sysclk_p` | Input     | AL23 | 300 MHz differential clock (positive) |
| `i_sysclk_n` | Input     | AK23 | 300 MHz differential clock (negative) |
| `o_uart_tx`  | Output    | AP24 | UART transmit for debug console        |
| `i_uart_rx`  | Input     | AR24 | UART receive for debug console input   |

## Clock Generation

All boards use an MMCM (Mixed-Mode Clock Manager) to generate the CPU clock from the board's reference oscillator:

| Board    | Input Clock | VCO Freq | CPU Clock  | Calculation            |
|----------|-------------|----------|------------|------------------------|
| Genesys2 | 200 MHz     | 800 MHz  | 133.33 MHz | 200 × 4 / 6            |
| X3       | 300 MHz     | 1200 MHz | 300 MHz    | 300 × 4 / 1 / 4        |

**Note:** All boards generate a /4 clock for JTAG and UART clock domain crossing.

## Board Comparison

| Feature           | Genesys2             | X3                          |
|-------------------|----------------------|-----------------------------|
| **FPGA Family**   | Kintex-7             | UltraScale+                 |
| **FPGA Part**     | xc7k325tffg900-2     | xcux35-vsva1365-3-e         |
| **CPU Clock**     | 133.33 MHz           | 300 MHz                     |
| **Div4 Clock**    | 33.33 MHz            | 75 MHz                      |
| **Reset**         | Push-button + JTAG   | JTAG load only              |
| **Use Case**      | Development/learning | Production/high-performance |

## Adding Support for New Boards

To add support for a new Xilinx FPGA board:

1. Create a new subdirectory named after the board
2. Copy an existing wrapper (e.g., `genesys2_frost.sv`) as a starting point
3. Modify the clock generation:
   - Adjust MMCM parameters for your board's input clock frequency
   - Configure CLKOUT0 for CPU clock and CLKOUT1 for /4 clock
   - Use appropriate clock buffers (BUFG for 7-series, BUFGCE_DIV for UltraScale+)
4. Instantiate `xilinx_frost_subsystem` with your clocks and reset
5. Create a constraint file with your board's pin assignments
6. Update the file list (`.f` file) to include the subsystem
7. Update `fpga/build/build.tcl` to handle the new board name
8. Update this README with the new board's specifications

Key considerations:
- Match the MMCM VCO frequency to your target CPU clock
- Ensure timing constraints match your input clock period
- Verify I/O voltage standards match your board's bank voltages
- For non-Xilinx FPGAs (Altera, Lattice), a new subsystem would be needed

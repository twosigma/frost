<!--
   Copyright 2026 John Goodacre

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-->

# AMD/Xilinx VCU118 Evaluation Board Target

This directory provides the board wrapper, clocking infrastructure, pin constraints, and floorplanning implementation for the **AMD/Xilinx VCU118 Evaluation Board** (`xcvu9p-flga2104-2L-e`).

---

## 1. Hardware Architecture Overview

- **FPGA Device**: AMD Virtex UltraScale+ `xcvu9p-flga2104-2L-e`
  - Speed Grade: **-2L** (low-power $0.72\text{ V}$ core voltage).
  - Architecture: **3 Stacked Silicon Interconnect (SSI) Super Logic Regions (SLRs)**:
    - **SLR 0**: Clock regions `X0Y0` to `X5Y4` (394k LUTs, DDR4 Channel 2 Banks 40–42).
    - **SLR 1**: Clock regions `X0Y5` to `X5Y9` (394k LUTs, QSFP1 Quad 231).
    - **SLR 2**: Clock regions `X0Y10` to `X5Y14` (394k LUTs, `SYSCLK1_300` Bank 65, USB-UART Bank 64, DDR4 Channel 1 Banks 71–73).
- **System Clocks**:
  - `SYSCLK1_300` (pins `G31` / `F31`, Bank 65 in SLR2): 300.000 MHz differential clock from onboard Silicon Labs SI5335A oscillator.
  - Dedicated DDR4 Reference Clock: 250.000 MHz differential clock (`AW26`/`AW27` for Channel 2 in Bank 41; `E12`/`D12` for Channel 1 in Bank 71).
  - QSFP1 MGT Reference Clock: 156.250 MHz differential clock (`W9`/`W8`, Quad 231 in Bank 231).
- **Onboard Component Memory**:
  - Two independent 72-bit channels of soldered Micron `MT40A256M16GE-083E` components (64-bit data + 8-bit native ECC, 2400 MT/s, 300 MHz controller `ui_clk`):
    - **Channel 1 (C1)**: Physical Banks 71–73 (located in **SLR2**).
    - **Channel 2 (C2)**: Physical Banks 40–42 (located in **SLR0**).
- **Board Peripherals**:
  - Console: Silicon Labs CP2105 USB-UART (Bank 64: `BB21` TX, `AW25` RX, interface 1) at 115200 baud.
  - 1Gb RJ-45 Ethernet (`eth1`): TI DP83867ISRGZ PHY (Bank 64 SGMII-over-LVDS: `AT22`/`AU22` 625 MHz clock, `AU21`/`AV21` TX, `AU24`/`AV24` RX, `AV23` MDC, `AR23` MDIO, `BA21` reset) with AMD `gig_ethernet_pcs_pma:17.0` + FROST coherent DMA NIC (`0x4002_2000`, APLIC Source 2).
  - 10Gb QSFP28 Ethernet (`eth0`): QSFP1 Lane 0 (Quad 231 `GTYE4_CHANNEL_X1Y48`: `W9`/`W8` 156.25 MHz refclk, `V7`/`V6` TX, `Y2`/`Y1` RX) with FROST 10GBASE-R MAC/PCS + coherent DMA NIC (`0x4003_0000`, APLIC Source 4).
  - Pushbutton Reset: SW6 CPU reset (`L19`, Bank 65 in SLR2).
  - Status LEDs: Bank 67/68 (`AT32`, `AV34`, `AY30`, `BB32` in SLR2).

---

## 2. Floorplanning & Single-Die Implementation (SLR2)

All active logic of the single-core FROST target is floorplanned inside **SLR2** (`pblock_slr2`), co-locating the core and memory controller on a single silicon die:

- **Resource Placement**:
  - Active modules: FROST Tomasulo out-of-order CPU core, L0/L1/L2 cache hierarchy, boot BRAM, 16550 UART console, APLIC interrupt controller, MMCM clock generator, DDR4 initialization engine, and DDR4 MIG Channel 1.
  - Resource footprint: ~175k LUTs (~44% of SLR2 capacity of 394k LUTs).
- **Intra-Die Routing Placement**:
  - Floorplanning confines all active logic to SLR2, routing all clock, control, and data paths entirely across intra-die interconnect.
- **Skew-Balanced Clock Tree**:
  - Global clock distribution buffer is centered at `USER_CLOCK_ROOT X2Y12` (the geometric center of SLR2), minimizing clock skew across the Tomasulo execution and memory pipelines.
- **Hardware ECC Initialization**:
  - `vcu118_ddr_init.sv` performs sequential 512-bit burst writes across the DDR4 address space immediately upon DRAM calibration completion, writing valid ECC syndrome bytes before CPU reset is deasserted.

---

## 3. Clocking Architecture & Build Targets

`vcu118_clock.sv` synthesizes all required synchronous clock domains from the onboard 300.0 MHz differential oscillator (`SYSCLK1_300`):

| Frequency Target | Role / Configuration | Input Clock | DIVCLK_DIV | CLKFBOUT_MULT | FVCO | CLKOUT0_DIV (clk_cpu) | CLKOUT1_DIV (clk_div4) | Build Duration |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **200.0 MHz (Default)** | **Production Baseline** | 300.0 MHz | `1` | `4.000` | 1200.0 MHz | `6.000` (200.0 MHz) | `24` (50.0 MHz) | **~45–60 min** |
| **240.0 MHz (Hero)** | **Pushed -2L Performance** | 300.0 MHz | `1` | `4.000` | 1200.0 MHz | `5.000` (240.0 MHz) | `20` (60.0 MHz) | Multi-pass sweep |
| **250.0 MHz** | Experimental | 300.0 MHz | `3` | `10.000` | 1000.0 MHz | `4.000` (250.0 MHz) | `16` (62.5 MHz) | Multi-pass sweep |
| **280.0 MHz** | Peak Swept | 300.0 MHz | `3` | `14.000` | 1400.0 MHz | `5.000` (280.0 MHz) | `20` (70.0 MHz) | Multi-pass sweep |

### 1. Default Production Target: 200.000 MHz
- **Target Frequency**: 200.000 MHz (`CPU_CLK_HZ = 200_000_000`, 5.000 ns period).
- **Timing Closure**: Closes timing with positive setup slack ($WNS > +0.20\text{ ns}$) on the initial routing pass using AlternateRoutability directives.
- **Build Command**:
  ```bash
  export RISCV_PREFIX=riscv64-unknown-elf-
  ./fpga/build/build.py vcu118 --start-at synth
  ```

### 2. Hero Target: 240.000 MHz
- **Target Frequency**: 240.000 MHz (`CPU_CLK_HZ = 240_000_000`, 4.167 ns period).
- **Timing Profile**: Represents the high-effort timing envelope for -2L silicon ($0.72\text{ V}$).
- **Build Command**:
  ```bash
  export RISCV_PREFIX=riscv64-unknown-elf-
  ./fpga/build/build.py vcu118 --clock-freq 240000000 --start-at synth
  ```

---

## 4. Post-Route Resource Utilization & Timing Summary

### Resource Utilization Breakdown (xcvu9p-flga2104-2L-e @ 200.0 MHz, Dual-NIC 10Gb + 1Gb)

| Resource | Used | Available | Utilization |
| :--- | :--- | :--- | :--- |
| **CLB LUTs** | 199,044 | 1,182,240 | 16.84% |
| - LUT as Logic | 173,649 | 1,182,240 | 14.69% |
| - LUT as Distributed RAM | 24,648 | 591,840 | 4.16% |
| - LUT as Shift Register | 747 | 591,840 | 0.13% |
| **CLB Registers** | 126,801 | 2,364,480 | 5.36% |
| **CARRY8** | 3,047 | 147,780 | 2.06% |
| **F7 / F8 / F9 Muxes** | 2,905 | 1,034,460 | 0.28% |
| **Block RAM Tile (36 Kb)** | 225.5 | 2,160 | 10.44% |
| **UltraRAM (URAM)** | 66 | 960 | 6.88% |
| **DSP48E2** | 27 | 6,840 | 0.39% |
| **Bonded IOB** | 149 | 832 | 17.91% |
| **GTYE4_CHANNEL / COMMON** | 1 / 1 | 52 / 13 | 1.92% / 7.69% |
| **MMCM** | 2 | 30 | 6.67% |
| **PLL** | 5 | 60 | 8.33% |

### Timing Closure Metrics

| Clock Domain | Frequency | Worst Setup (WNS) | Total Negative (TNS) | Failing / Total Setup | Worst Hold (WHS) | Total Hold (THS) | Failing / Total Hold |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU Main (`clk_cpu`)** | 200.020 MHz | **+0.004 ns** | 0.000 ns | 0 / 358,621 | **+0.010 ns** | 0.000 ns | 0 / 358,621 |
| **JTAG / Loader (`clk_div4`)** | 50.005 MHz | **+11.430 ns** | 0.000 ns | 0 / 55,241 | **+0.010 ns** | 0.000 ns | 0 / 55,241 |
| **10Gb GTY Supervisor (`freerun_clk_150`)** | 150.015 MHz | **+3.663 ns** | 0.000 ns | 0 / 587 | **+0.041 ns** | 0.000 ns | 0 / 587 |
| **10Gb GTY PCS (`nic_tx_clk` / `nic_rx_clk`)** | 161.133 MHz | **+0.874 ns** | 0.000 ns | 0 / 6,772 | **+0.018 ns** | 0.000 ns | 0 / 6,772 |
| **1Gb SGMII PCS (`IntTx_ClkOut1`)** | 125.000 MHz | **+1.887 ns** | 0.000 ns | 0 / 6,146 | **+0.028 ns** | 0.000 ns | 0 / 6,146 |
| **DDR4 Reference** | 250.000 MHz | **+2.475 ns** | 0.000 ns | 0 / 23 | **+0.042 ns** | 0.000 ns | 0 / 23 |
| **DDR4 Memory Controller** | 300.000 MHz | **+0.011 ns** | 0.000 ns | 0 / 71,937 | **+0.010 ns** | 0.000 ns | 0 / 71,937 |
| **Overall Design** | — | **+0.004 ns** | **0.000 ns** | **0 / 516,627** | **+0.010 ns** | **0.000 ns** | **0 / 515,767** |

---

## 5. Execution Methodology & Software Loading

### Step 1: Programming the Bitstream
Program the generated bitstream (`fpga/build/vcu118/work/vcu118_frost.bit`) over JTAG using Vivado Hardware Manager or the provided script:
```bash
python3 fpga/program_bitstream/program_bitstream.py vcu118
```

### Step 2: Serial Console Connection
Connect a terminal emulator (such as `picocom`, `minicom`, or `screen`) to the onboard Silicon Labs CP2105 USB-UART bridge at 115200 baud, 8N1 framing:
```bash
# Interface 1 connects to the FPGA UART pins (BB21/AW25)
picocom -b 115200 /dev/serial/by-id/usb-Silicon_Labs_CP2105*-if01-port0
```

### Step 3: Loading Bare-Metal and Diagnostic Software
Load and run bare-metal applications over JTAG into boot BRAM or cached DDR4:
```bash
# Hello World
python3 fpga/load_software/load_software.py vcu118 hello_world

# CoreMark 1.0 Benchmark
python3 fpga/load_software/load_software.py vcu118 coremark

# Cached-region DDR Tier Test
python3 fpga/load_software/load_software.py vcu118 ddr_test

# OpenSBI Firmware and Smoke Suite
python3 fpga/load_software/load_software.py vcu118 opensbi_smoke
```

### Step 4: Booting Linux
Load OpenSBI, Linux kernel, device tree, and Busybox userspace into DDR4 and boot:
```bash
export RISCV_PREFIX=<path-to-toolchain>/riscv64-linux-
python3 fpga/load_software/load_software.py vcu118 linux_boot
```

---

## 6. Network Boot Architecture & Requirements (TFTP / NFS)

When booting Linux over network interfaces via U-Boot or Ethernet, the target environment requires standard host network services:

```
+------------------------------------------------------------------------------------+
|                                 Network Infrastructure                             |
|                                                                                    |
|   +--------------------+                    +----------------------------------+   |
|   | VCU118 Evaluation  |                    | Network Gateway / Router / DHCP  |   |
|   | Board (RJ-45)      |                    |                                  |   |
|   | IP: <board-ip>     | <----------------> | (Assigns IP / Routes Subnets)    |   |
|   +---------+----------+                    +-----------------+----------------+   |
|             |                                                 |                    |
+-------------|-------------------------------------------------|--------------------+
              |                                                 |
              +-----------------------+-------------------------+
                                      |
+-------------------------------------|----------------------------------------------+
|                                     v                                              |
|                               Boot Server Host                                     |
|                                                                                    |
|   +------------------------------------+                                           |
|   | Services:                          |                                           |
|   | - DHCP (IP lease assignment)       |                                           |
|   | - TFTP (Kernel Image & DTB)        |                                           |
|   | - NFSv3 (Root filesystem export)   |                                           |
|   | IP: <server-ip>                    |                                           |
|   +------------------------------------+                                           |
+------------------------------------------------------------------------------------+
```

### Service Requirements & Configuration

1. **DHCP Service**:
   - Assigns a dynamic or static IPv4 lease, netmask, default gateway, and optional TFTP server address to the board.

2. **TFTP Service (`tftpd-hpa` or compatible)**:
   - Request port: UDP `69`.
   - Ephemeral transfer ports: Optional port range pinning (e.g., `49500-49600`) to simplify firewall rules.
   - Hosts the compiled Linux kernel image (`Image`) and device tree blob (`frost-vcu118.dtb`).

3. **NFSv3 Service (`nfs-kernel-server` or compatible)**:
   - RPC Portmapper: TCP/UDP `111`.
   - NFS Daemon: TCP/UDP `2049`.
   - Mount Daemon (`rpc.mountd`): Statically pinned to a predictable port (e.g., `20048` via `/etc/nfs.conf` or `/etc/default/nfs-kernel-server`) to enable firewall traversal.
   - Export configuration (`/etc/exports`):
     ```text
     <export-directory> <board-subnet>/<mask-bits>(rw,sync,no_subtree_check,no_root_squash,insecure)
     ```
     *(The `insecure` option permits connection requests originating on unprivileged ports $> 1024$, required when traffic is routed across subnets).*

4. **U-Boot Network Boot Sequence**:
   ```text
   setenv autoload no
   dhcp
   setenv serverip <server-ip>
   tftpboot 0x84000000 Image
   tftpboot 0x88000000 frost-vcu118.dtb
   setenv bootargs "console=ttyS0,115200 root=/dev/nfs nfsroot=<server-ip>:<export-directory>,vers=3,tcp,nolock ip=dhcp rw"
   booti 0x84000000 - 0x88000000
   ```

---

## 7. Multi-Die SMP Architecture Roadmap

For multi-core SMP scaling and accelerator expansion, the VCU118 floorplanning architecture scales across all three Super Logic Regions:

```
┌────────────────────────────────────────────────────────────────────────┐
│ SLR 2: High-Speed CPU Domain (200–240+ MHz)                            │
│        - SMP CPU Cluster (multiple cpu_top instances)                  │
│        - L2/Coherent Interconnect                                      │
│        - MIG Channel 1 (Banks 71–73, 300 MHz ui_clk) — Local DRAM      │
├────────────────────────────────────────────────────────────────────────┤
│                     ▼  Asynchronous AXI CDC Boundary (SLLs)            │
├────────────────────────────────────────────────────────────────────────┤
│ SLR 1: Interconnect & Expansion (Accelerators / NPU Fabric)             │
├────────────────────────────────────────────────────────────────────────┤
│ SLR 0: SoC & System Memory Domain                                      │
│        - soc_top (APLIC, system interconnect, UART, Ethernet, BRAM)   │
│        - MIG Channel 2 (Banks 40–42, 300 MHz ui_clk) — 2nd DRAM Channel│
└────────────────────────────────────────────────────────────────────────┘
```

### Architectural Principles

1. **Asynchronous CDC Isolation around `cpu_top`**:
   - Upstream `platform_top` decomposes into `cpu_top` + `soc_top`.
   - Wrapping `cpu_top` (or the multi-core SMP cluster) with an **asynchronous AXI CDC** completely decouples the high-speed CPU clock from peripheral and memory clocks.
   - Asynchronous synchronizers absorb SLL micro-bump crossing latency between SLRs, maintaining independent CPU clock frequency.

2. **Dual-MIG Memory Architecture**:
   - **Channel 1 (SLR2)**: Local high-bandwidth memory for the CPU cluster.
   - **Channel 2 (SLR0)**: System memory accessible to the SoC, DMA engines, and accelerators.
   - Cacheline interleaving across both channels on address bit 6 (`addr[6]`) delivers **$2\times$ concurrent burst bandwidth (38.4 GB/s)** and **4.0 GB total DRAM capacity**.

3. **Multi-Die Role Separation**:
   - **SLR 2**: Dedicated high-speed compute and local memory.
   - **SLR 1**: Intermediate routing, second cluster, and accelerator/NPU fabric.
   - **SLR 0**: Peripheral I/O fabric, networking, and second high-speed memory controller.

---

## 8. Physical Silicon Hardware Validation

The timing-closed 200.0 MHz VCU118 bitstream was programmed and validated on physical hardware:

- **Hardware Configuration**:
  - Target Board: AMD/Xilinx VCU118 (`xcvu9p-flga2104-2L-e`)
  - Target Cable: Digilent JTAG-SMT2NC
  - Console UART: Silicon Labs CP2105 dual-UART bridge at 115200 baud (Interface 1)

- **Hardware Test Results**:
  1. **`hello_world`**: Cycle timer (`rdtime`) measured 200,004,014 ticks/sec, matching the 200.0 MHz hardware clock.
  2. **`coremark` (CoreMark 1.0)**: Executed 10,800 iterations with Bootlin GCC 15.3.0 `-O3 -mtune=generic-ooo`. All validation CRCs matched (`0xe9f5`, `0xe714`, `0x1fd7`, `0x8e3a`, `0x4983`). Score: **784.22 Iterations/sec (3.92 CoreMark/MHz)** with `<<PASS>>`.
  3. **`ddr_test` (Cached-Region DDR Tier Test)**: Validated word/byte reads, RAW stores, 24-line cache eviction sweeps, preloaded `.ddr_rodata`, and atomic memory operations (AMO cached read-modify-write). Result: `<<PASS>>`.
  4. **`opensbi_smoke`**: OpenSBI v1.9 booted, probed all standard SBI extensions (`time`, `rfnc`, `ipi`, `base`, `hsm`, `pmu`, `dbcn`, `fwft`, `legacy`, `sse`), configured Sv39 page tables, and tested supervisor misaligned emulation. Result: `<<PASS>>`.
  5. **`linux_boot` (Debian Linux 6.12.113 SMP + Buildroot initramfs)**:
     - Booted Debian Linux 6.12.113 kernel with Sv39 virtual memory, AIA/IMSIC interrupt controller, and 2.0 GB memory aperture (`MemTotal: 1949 MB`).
     - Probed active ISA extensions including hardware carryless multiplier (`zbc`, `zbkc`).
     - Loaded out-of-tree `frost_net10g` and `frost_memerr` modules (`FROST_NET10G_MODULE_PASS 6.12.113+deb13-riscv64`, `FROST_MEMERR_MODULE_PASS 6.12.113+deb13-riscv64`) and passed userspace stress (`FROST_USERSPACE_STRESS_PASS`).
     - Registered both `eth0` (10Gb QSFP28 at `0x4003_0000`, IRQ 12, MAC `02:11:22:33:44:55`) and `eth1` (1Gb RJ-45 SGMII at `0x4002_2000`, IRQ 13, MAC `02:11:22:33:44:56`).
     - **10Gb QSFP28 (`eth0`) GTY Near-End PMA Loopback**: Executed `frost_nettest eth0`, verifying 514 frames across MTU 9000 jumbo frames, short frame padding (14..160 B), boundary frames (1514..9014 B), and 300-frame bursts through the GTY transceiver PMA (`GTYE4_CHANNEL_X1Y48`) with 0 errors (`FROST_NET_LOOPBACK_PASS`).
     - **1Gb RJ-45 (`eth1`) Live LAN, DHCP & SSH Console**: Linked at 1000BASE-T Full Duplex via TI DP83867 + AMD `gig_ethernet_pcs_pma`, acquired IPv4 address via `udhcpc` (`S45frost-net`), passed bidirectional ICMP `ping` (0% loss), and verified concurrent interactive `ssh root@<board-ip>` login (`dropbear`) alongside the `/dev/ttyS0` UART console.

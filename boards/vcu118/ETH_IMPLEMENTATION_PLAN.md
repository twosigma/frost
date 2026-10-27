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

# VCU118 Dual Networking (1Gb RJ-45 & 10Gb QSFP28) Architecture & Implementation Plan

This document specifies the architecture, hardware integration, loopback verification, and Linux networking stack for dual-networking support on the **AMD/Xilinx VCU118 Evaluation Board** (`xcvu9p-flga2104-2L-e`), satisfying two primary objectives:
1. **1Gb RJ-45 Ethernet**: AMD AXI Ethernet MAC/PCS (SGMII) + AXI DMA connected to the onboard Texas Instruments DP83867 PHY for LAN connectivity, TFTP/NFS boot, and network consoles.
2. **10Gb QSFP28 Ethernet**: FROST native `net10g` soft MAC/PCS connected to QSFP1 (Quad 231 GTY), with operational validation via hardware PMA/MAC loopback mode.

---

## 1. Architectural Principles & Isolation Guarantees

### 1.1 Strict X3 Target Isolation (Zero Regression)
- **Zero modification to X3 behavior**: The Alveo X3 board target remains completely untouched and operational as today.
- **Build-Time Parameterization**: All shared RTL (such as `soc_top.sv` and `xilinx_frost_subsystem.sv`) guards any new VCU118-specific logic behind parameters defaulted to disable them (`ENABLE_1G_ETH = 0`).
- **Board-Specific Encapsulation**: All board-specific IP generators (`vcu118_eth_bd.tcl`, `vcu118_gty_ip.tcl`), RTL wrappers (`vcu118_frost.sv`, `vcu118_nic_gty.sv`), and pin constraints (`vcu118_eth.xdc`) reside strictly under `boards/vcu118/` and `fpga/build/vcu118_*`.

### 1.2 Unified Linux Kernel & Userspace
- **Single Kernel Image (`Image`)**: The Linux kernel binary remains identical and shared between X3 and VCU118.
- **Device Tree Driven Probing**:
  - Peripheral drivers (`xilinx_axienet`, `dp83867`, and `frost_net10g`) probe dynamically based on nodes present in the board's Device Tree (`.dtb`).
  - On X3: 1Gb node is absent or disabled; only 10Gb NIC probes.
  - On VCU118: Both 1Gb (`eth0`) and 10Gb (`eth1`) nodes are active and probe cleanly.
- **Common Buildroot Userspace**: Dynamic network configuration (`udhcpc`, `dropbear` SSH daemon, NFS client, netconsole) automatically manages available network interfaces at boot.

---

## 2. Complete Dual-Networking System Architecture

```mermaid
flowchart TD
    subgraph FROST_Core ["FROST Core & Coherent Interconnect"]
        CPU["FROST Tomasulo Out-of-Order CPU\n(RV64GCB Zba Zbb Zbc Zbkc)"]
        L2["L2 Cache Hierarchy (Unified)"]
        COH["axi_coherent_bridge (Cache-Coherent Ingress)"]
        XBAR["soc_top AXI4-Lite Crossbar"]
        MUX["axi_mux (Multi-Master DMA Arbiter)"]
        APLIC["APLIC Interrupt Controller"]
        
        CPU --> L2
        COH --> L2
        MUX --> COH
    end

    subgraph Eth_1G_Subsystem ["1Gb Subsystem (AMD AXI Ethernet + DMA)"]
        DMA_1G["AMD AXI DMA (PG021)\n- Scatter-Gather Engine\n- 64-bit Memory Master"]
        MAC_1G["AMD AXI 1G/2.5G Ethernet Subsystem (PG138)\n- Tri-Mode Ethernet MAC (TEMAC)\n- SGMII PCS/PMA Core"]
        
        XBAR -->|0x4002_0000| MAC_1G
        XBAR -->|0x4003_0000| DMA_1G
        DMA_1G -->|AXI4 Master| MUX
        DMA_1G <-->|AXI4-Stream TX/RX| MAC_1G
        DMA_1G -->|TX IRQ (Src 5) / RX IRQ (Src 6)| APLIC
        MAC_1G -->|Link Change IRQ (Src 7)| APLIC
    end

    subgraph Eth_10G_Subsystem ["10Gb Subsystem (FROST Native net10g)"]
        NIC_10G["FROST Native 10G NIC (nic_top)\n- Descriptor Engines & FIFOs\n- Soft 10GBASE-R MAC/PCS\n- Loopback Control Register"]
        GTY_10G["VCU118 GTY Transceiver (vcu118_nic_gty)\n- Quad 231 Channel 0\n- PMA Near-End Loopback Mux"]
        
        XBAR -->|0x4004_0000| NIC_10G
        NIC_10G -->|AXI4 Master| MUX
        NIC_10G -->|NIC IRQ (Src 4)| APLIC
        NIC_10G <-->|64-bit Raw Data @ 161.13 MHz| GTY_10G
    end

    subgraph VCU118_Hardware ["VCU118 Board Physical Layer"]
        CLK_125["125.0 MHz Ref Clock (AK34/AK35)"]
        PHY_1G["TI DP83867 PHY (Bank 64 / Bank 128)"]
        RJ45["Onboard RJ-45 Jack (1000BASE-T LAN)"]
        
        CLK_156["156.25 MHz Ref Clock (W9/W8)"]
        QSFP1["QSFP28 Cage 1 (Quad 231)"]
        
        CLK_125 --> MAC_1G
        MAC_1G <-->|SGMII Serial (AU40/AV38)| PHY_1G
        MAC_1G -->|MDIO/MDC (AK39/AR39)| PHY_1G
        PHY_1G <--> RJ45
        
        CLK_156 --> GTY_10G
        GTY_10G <-->|10.3125 Gbps Serial (V7/Y2)| QSFP1
        GTY_10G -.->|Internal PMA Loopback| GTY_10G
    end
```

---

## 3. Hardware Resource Mapping & Pinout

### 3.1 1Gb RJ-45 Ethernet Subsystem (TI DP83867)

| Signal Name | FPGA Pin | Bank / Location | I/O Standard | Function |
| :--- | :--- | :--- | :--- | :--- |
| `sgmii_tx_p` / `_n` | `AU40` / `AU41` | Bank 128 (Quad 128) | High-Speed Serial | SGMII Serial TX Data Differential Pair |
| `sgmii_rx_p` / `_n` | `AV38` / `AV39` | Bank 128 (Quad 128) | High-Speed Serial | SGMII Serial RX Data Differential Pair |
| `sgmii_clk_p` / `_n` | `AK34` / `AK35` | Bank 128 (Quad 128) | LVDS | 125.0 MHz Differential SGMII Clock |
| `mdio_gem_mdc` | `AR39` | Bank 64 (1.8V) | LVCMOS18 | Management Data Clock |
| `mdio_gem_mdio` | `AK39` | Bank 64 (1.8V) | LVCMOS18 | Management Data Input / Output |
| `mdio_gem_rst_n` | `AN39` | Bank 64 (1.8V) | LVCMOS18 | Active-Low Hardware PHY Reset |
| `mdio_gem_irq_n` | `AM39` | Bank 64 (1.8V) | LVCMOS18 | Active-Low Hardware PHY Interrupt |

### 3.2 10Gb QSFP28 Subsystem (QSFP1 / Quad 231)

| Signal Name | FPGA Pin | Bank / Location | I/O Standard | Function |
| :--- | :--- | :--- | :--- | :--- |
| `qsfp1_mgtrefclk_p` / `_n` | `W9` / `W8` | Bank 231 (Quad 231) | High-Speed Diff | 156.250 MHz Differential MGT Reference Clock |
| `qsfp1_tx_p` / `_n` (Lane 0) | `V7` / `V6` | Bank 231 (Quad 231) | High-Speed Serial | 10.3125 Gbps Transmit Data Differential Pair |
| `qsfp1_rx_p` / `_n` (Lane 0) | `Y2` / `Y1` | Bank 231 (Quad 231) | High-Speed Serial | 10.3125 Gbps Receive Data Differential Pair |
| `qsfp1_modsel_l` | `AL21` | Bank 65 (1.8V) | LVCMOS18 | Module Select (Active-Low) |
| `qsfp1_reset_l` | `AM21` | Bank 65 (1.8V) | LVCMOS18 | Module Hardware Reset (Active-Low) |
| `qsfp1_lpmode` | `AN21` | Bank 65 (1.8V) | LVCMOS18 | Low Power Mode Override |

### 3.3 Memory-Mapped I/O (MMIO) Allocations

| Address Range | Size | Component | Function |
| :--- | :--- | :--- | :--- |
| `0x4002_0000 – 0x4002_ffff` | 64 KiB | AMD AXI Ethernet MAC | TEMAC control, SGMII PCS status, MDIO registers |
| `0x4003_0000 – 0x4003_ffff` | 64 KiB | AMD AXI DMA | 1Gb Scatter-Gather TX/RX descriptor rings & control |
| `0x4004_0000 – 0x4004_ffff` | 64 KiB | FROST 10G NIC (`nic_top`) | 10G Ring buffers, CSRs, `PHY_CTRL` loopback register |

### 3.4 Interrupt Allocation (APLIC)

| APLIC Source ID | Interrupt Source | Trigger Type | Function |
| :--- | :--- | :--- | :--- |
| `Source 4` | FROST 10G NIC IRQ | Level High | 10G TX/RX completion, descriptor ring status |
| `Source 5` | AXI DMA TX IRQ | Level High | 1Gb Frame transmission completion |
| `Source 6` | AXI DMA RX IRQ | Level High | 1Gb Frame reception notification |
| `Source 7` | AXI Ethernet MAC IRQ | Level High | 1Gb Link status change, auto-negotiation complete |

---

## 4. 10Gb Loopback Verification Strategy

To prove operational status of the 10Gb pipeline without requiring an external 10G switch or host:
1. **Near-End PMA Loopback Mode**:
   - The GTY transceiver channel in Quad 231 is configured with `ENABLE_OPTIONAL_PORTS {loopback_in}`.
   - Writing `0x4` to CSR `PHY_CTRL` (`0x4004_0064`, bit 2 = `PMA_LOOPBACK`) asserts GTY `LOOPBACK = 3'b010`.
   - In this mode, the TX serializer loops directly to the RX deserializer inside the GTY PMA.
2. **Soft MAC Loopback Mode**:
   - Setting bit 0 (`MAC_LOOPBACK`) in `PHY_CTRL` loops frames back immediately before transmission.
3. **Verification Scope**:
   - **TX Datapath**: TX DMA descriptor fetch -> packet packing -> 64b/66b scrambler/encoder -> gearbox -> GTY serializer.
   - **RX Datapath**: GTY deserializer -> recovered clock aligner -> gearbox -> 64b/66b descrambler/decoder -> block lock state machine -> packet unpacking -> RX DMA ring writeback.
   - **Driver Verification**: Running ping or raw packet loopback via the `frost_net10g` Linux driver validates that RX and TX rings advance synchronously, frame checksums match, and packet loss is zero.

---

## 5. Linux Boot & Multi-Console Infrastructure

### 5.1 TFTP and NFS Boot Over 1Gb Ethernet
1. **DHCP & Network Initialization**:
   - The Linux kernel IP autoconfiguration (`CONFIG_IP_PNP=y`, `CONFIG_IP_PNP_DHCP=y`) or initial ramdisk acquires an IPv4 address on `eth0` via the local LAN DHCP server.
2. **NFS Root Mounting**:
   - Kernel command line parameter:
     ```text
     console=ttyS0,115200 root=/dev/nfs nfsroot=<server-ip>:/srv/nfs/frost,tcp,v3 rw ip=dhcp
     ```
   - Kernel initializes `xilinx_axienet`, achieves link partner auto-negotiation at 1000 Mbps with the DP83867 PHY, negotiates DHCP lease, and mounts `/` over NFSv3.
3. **TFTP Kernel Loading**:
   - OpenSBI / U-Boot payload can fetch updated kernel images or device tree blobs directly from a local TFTP server over `eth0`.

### 5.2 Simultaneous Linux Login Consoles
- **Physical UART Console**: Interactive `/dev/ttyS0` serial login at 115200 baud on the CP2105 USB-UART.
- **1Gb SSH Console (`eth0`)**: Dropbear SSH server listening on port 22 reachable at the DHCP-assigned LAN address.
- **10Gb Network Console (`eth1`)**: Available for SSH or direct packet testing when connected to a 10G switch or host, or active during loopback diagnostics.
- **Netconsole**: Kernel printk mirroring via UDP packets targeting a host syslog listener.

---

## 6. Implementation Phases & Work Breakdown

### Phase 1: Vivado IP Block Design for 1Gb Ethernet (`fpga/build/vcu118_eth_bd.tcl`)
- Generate `xilinx.com:ip:axi_ethernet:7.2` in `1G_PCS_PMA_SGMII` mode with internal clocking.
- Generate `xilinx.com:ip:axi_dma:7.1` in Scatter-Gather mode with 64-bit memory interface.
- Export AXI4-Lite control ports, coherent AXI4 DMA master, and interrupt lines.

### Phase 2: VCU118 10G Transceiver Core (`fpga/build/vcu118_gty_ip.tcl` & `boards/vcu118/vcu118_nic_gty.sv`)
- Generate `gtwizard_ultrascale` core for Quad 231 (Channel 0: `X0Y28`, 156.25 MHz reference clock from `W9`/`W8`).
- Configure raw 64-bit PMA interface at 10.3125 Gbps.
- Expose `loopback_in` for runtime PMA near-end loopback switching.
- Adapt `vcu118_nic_gty.sv` supervisor to monitor CDR lock, block lock, and PMA loopback transitions.

### Phase 3: Top-Level Board Integration (`boards/vcu118/vcu118_frost.sv`)
- Instantiate 1Gb Ethernet subsystem and 10Gb GTY wrapper.
- Integrate both 64-bit DMA masters into `soc_top` via `axi_mux` to `axi_coherent_bridge`.
- Connect interrupt signals (APLIC Sources 4, 5, 6, 7).
- Expose physical pinout for Bank 128 (SGMII), Bank 64 (MDIO), and Bank 231 (QSFP1).

### Phase 4: Physical Constraints (`boards/vcu118/constr/vcu118_eth.xdc`)
- Pin placement and I/O standard definitions for SGMII, MDIO, and QSFP1 pins.
- Timing constraints:
  - 125.0 MHz differential clock constraint for SGMII.
  - 156.25 MHz differential clock constraint for QSFP1.
  - Asynchronous clock groups between CPU main clock, 125 MHz SGMII clock, and 161.13 MHz 10G MAC clock domains.

### Phase 5: Common Linux Device Tree & Kernel Config
- Add `xlnx,axi-ethernet-1.00.a` node with DP83867 MDIO phy subnode to `frost.dts`.
- Add `frost_net10g` node with Quad 231 GTY aperture.
- Enable kernel options: `CONFIG_XILINX_AXI_EMAC=y`, `CONFIG_DP83867_PHY=y`, `CONFIG_FROST_NET10G=y`, `CONFIG_IP_PNP_DHCP=y`, `CONFIG_ROOT_NFS=y`.
- Configure Buildroot with `dropbear`, `udhcpc`, and NFS rootfs support.

### Phase 6: Hardware Testing & Validation
1. **10Gb Loopback Test**: Run internal PMA loopback packet test; verify block lock, byte count, zero packet loss, and interrupt firing.
2. **1Gb LAN Test**: Verify DP83867 auto-negotiation and obtain DHCP lease on local network.
3. **TFTP / NFS Boot**: Boot Linux kernel with NFS root filesystem over `eth0`.
4. **Concurrent Multi-Console**: Establish simultaneous interactive sessions on UART `/dev/ttyS0` and SSH over `eth0`.

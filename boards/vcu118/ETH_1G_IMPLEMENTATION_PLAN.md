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

# VCU118 1Gb Ethernet Architecture & Implementation Plan

This document specifies the hardware architecture and implementation methodology for enabling 10/100/1000 Mbps Ethernet on the **AMD/Xilinx VCU118 Evaluation Board** (`xcvu9p-flga2104-2L-e`) using the onboard **Texas Instruments DP83867ISRGZ** PHY and standard RJ-45 jack.

---

## 1. System Architecture Overview

The 1Gb Ethernet subsystem connects the onboard DP83867 PHY to the FROST out-of-order processor using AMD/Xilinx AXI Ethernet IP, standard AXI DMA, and the FROST coherent interconnect:

```mermaid
flowchart TD
    subgraph FROST_Core_SLR2 ["FROST Core Domain (SLR2)"]
        CPU["FROST Tomasulo Out-of-Order CPU"]
        L2["L2 Cache Hierarchy"]
        COH["axi_coherent_bridge (Coherent Ingress)"]
        CPU --> L2
        COH --> L2
    end

    subgraph SoC_Interconnect ["SoC Interconnect Domain"]
        XBAR["soc_top AXI4-Lite Register Decoder"]
        MUX["axi_mux (DMA Master Arbiter)"]
        APLIC["APLIC Interrupt Controller"]
        MUX --> COH
    end

    subgraph Ethernet_Subsystem ["Ethernet Subsystem"]
        AXI_DMA["AMD AXI DMA (PG021)\n- Scatter-Gather Engine\n- 64-bit Memory Master"]
        AXI_MAC["AMD AXI 1G/2.5G Ethernet Subsystem (PG138)\n- Tri-Mode Ethernet MAC (TEMAC)\n- SGMII PCS/PMA Core"]
        
        XBAR -->|AXI4-Lite MMIO| AXI_DMA
        XBAR -->|AXI4-Lite MMIO| AXI_MAC
        AXI_DMA -->|AXI4 DMA Master| MUX
        AXI_DMA <-->|AXI4-Stream TX/RX| AXI_MAC
        AXI_DMA -->|TX/RX IRQ| APLIC
        AXI_MAC -->|Link Change IRQ| APLIC
    end

    subgraph Physical_PHY ["Onboard VCU118 Hardware"]
        SGMII_CLK["125.0 MHz Differential Ref Clock\n(Bank 128: AK34/AK35)"]
        PHY["Texas Instruments DP83867ISRGZ PHY"]
        RJ45["Standard 8P8C (RJ-45) Ethernet Jack"]
        
        SGMII_CLK --> AXI_MAC
        AXI_MAC <-->|SGMII (1.25 Gbps Serial)| PHY
        AXI_MAC -->|MDIO / MDC (Management)| PHY
        PHY <-->|1000BASE-T Magnetics| RJ45
    end
```

---

## 2. Hardware Interfaces & Resource Mapping

### 2.1 Physical Layer Pinout (VCU118 UG1224)

| Signal Name | FPGA Pin | I/O Bank | I/O Standard | Description |
| :--- | :--- | :--- | :--- | :--- |
| `sgmii_tx_p` | `AU40` | Bank 128 (GTY Quad 128) | High-Speed Serial | SGMII Serial TX Data Positive |
| `sgmii_tx_n` | `AU41` | Bank 128 (GTY Quad 128) | High-Speed Serial | SGMII Serial TX Data Negative |
| `sgmii_rx_p` | `AV38` | Bank 128 (GTY Quad 128) | High-Speed Serial | SGMII Serial RX Data Positive |
| `sgmii_rx_n` | `AV39` | Bank 128 (GTY Quad 128) | High-Speed Serial | SGMII Serial RX Data Negative |
| `sgmii_clk_p` | `AK34` | Bank 128 (GTY Quad 128) | LVDS | 125.0 MHz Differential SGMII Clock (+) |
| `sgmii_clk_n` | `AK35` | Bank 128 (GTY Quad 128) | LVDS | 125.0 MHz Differential SGMII Clock (-) |
| `mdio_gem_mdc` | `AR39` | Bank 64 | LVCMOS18 | Management Data Clock |
| `mdio_gem_mdio` | `AK39` | Bank 64 | LVCMOS18 | Management Data Input/Output |
| `mdio_gem_rst_n` | `AN39` | Bank 64 | LVCMOS18 | Active-Low Hardware PHY Reset |
| `mdio_gem_irq_n` | `AM39` | Bank 64 | LVCMOS18 | Active-Low Hardware Interrupt from PHY |

### 2.2 Memory-Mapped I/O (MMIO) Apertures

The Ethernet subsystem registers attach to `soc_top` via 32-bit AXI4-Lite channels:

| Address Range | Size | Component | Function |
| :--- | :--- | :--- | :--- |
| `0x4002_0000 – 0x4002_ffff` | 64 KiB | AXI 1G/2.5G Ethernet Subsystem | TEMAC control, SGMII PCS configuration, MDIO PHY registers |
| `0x4003_0000 – 0x4003_ffff` | 64 KiB | AXI DMA | Scatter-Gather descriptor engines, channel control, status registers |

### 2.3 Coherent DMA Ingress

- **Protocol**: AXI4 with 64-bit data bus and 32-bit address bus.
- **Interconnect**: Connects into `axi_mux` alongside the existing DMA engine.
- **Coherency**: Transactions route directly through `axi_coherent_bridge` into the L2 cache, maintaining hardware coherency across DDR4 without software cache-flush overhead.

### 2.4 Interrupt Mapping (APLIC)

The subsystem connects to the Advanced Platform-Level Interrupt Controller:

| APLIC Source ID | Interrupt Source | Description |
| :--- | :--- | :--- |
| `Source 5` | AXI DMA TX Interrupt | Frame transmission completion and descriptor ring writeback |
| `Source 6` | AXI DMA RX Interrupt | Frame reception notification and buffer ring writeback |
| `Source 7` | AXI Ethernet Core Interrupt | Link status change and auto-negotiation completion |

---

## 3. Work Breakdown & Implementation Phases

### Phase 1: Vivado Block Design Generator (`fpga/build/vcu118_eth_bd.tcl`)
- Instantiate `xilinx.com:ip:axi_ethernet:7.2`:
  - Component Mode: `1G_PCS_PMA_SGMII`
  - PHY Type: SGMII with internal clocking
  - Management: MDIO enabled
  - Data Interface: AXI4-Stream (8-bit streaming interface)
- Instantiate `xilinx.com:ip:axi_dma:7.1`:
  - Memory Data Width: 64-bit
  - Stream Data Width: 32-bit
  - Scatter-Gather Mode: Enabled (`CONFIG.c_include_sg {1}`)
  - Micro DMA: Disabled
- Connect AXI-Stream interfaces between Ethernet Subsystem and AXI DMA.
- Export AXI-Lite control interfaces and AXI4 memory master interface.

### Phase 2: Board RTL Wrapper Integration (`boards/vcu118/vcu118_frost.sv`)
- Add external top-level ports for SGMII serial lines, 125 MHz reference clock, MDIO, MDC, and PHY reset.
- Instantiate the Ethernet subsystem block design wrapper.
- Connect AXI4-Lite register interfaces to `soc_top` peripheral decode.
- Connect AXI4 DMA master port to `axi_mux` input on `axi_coherent_bridge`.
- Connect interrupt signals (`dma_tx_irq`, `dma_rx_irq`, `eth_irq`) to APLIC input lines.

### Phase 3: Physical Constraints (`boards/vcu118/constr/vcu118_eth.xdc`)
- Add pin placement and I/O standard constraints for Bank 64 and Bank 128 signals.
- Constrain SGMII 125.0 MHz differential clock:
  ```tcl
  create_clock -period 8.000 -name sgmii_ref_clk [get_ports sgmii_clk_p]
  ```
- Define asynchronous clock group boundaries between CPU main clock domain and SGMII 125 MHz domain.

### Phase 4: Linux Device Tree (`frost.dts`)
- Add standard Open Firmware node for `xilinx_axienet`:
  ```dts
  ethernet@40020000 {
      compatible = "xlnx,axi-ethernet-1.00.a";
      device_type = "network";
      reg = <0x0 0x40020000 0x0 0x10000>,
            <0x0 0x40030000 0x0 0x10000>;
      reg-names = "eth_mac", "eth_dma";
      interrupt-parent = <&aplic>;
      interrupts = <5 4>, <6 4>;
      interrupt-names = "dma_tx", "dma_rx";
      phy-mode = "sgmii";
      phy-handle = <&phy0>;
      xlnx,rxs-cntrl = <1>;
      
      mdio {
          #address-cells = <1>;
          #size-cells = <0>;
          phy0: ethernet-phy@3 {
              device_type = "ethernet-phy";
              reg = <3>;
              ti,rx-internal-delay = <0x8>;
              ti,tx-internal-delay = <0xa>;
              ti,fifo-depth = <0x1>;
          };
      };
  };
  ```

### Phase 5: Kernel Driver Configuration & Network Console
1. **Linux Kernel Drivers**:
   - `CONFIG_NET_ETHERNET=y`
   - `CONFIG_NET_VENDOR_XILINX=y`
   - `CONFIG_XILINX_AXI_EMAC=y`
   - `CONFIG_DP83867_PHY=y`
2. **Network Services (Buildroot)**:
   - Dynamic IP lease via Busybox `udhcpc` on interface `eth0`.
   - SSH server: `dropbear` for interactive network console access.
   - Telnet daemon: `busybox telnetd` for lightweight local access.
   - Kernel UDP logging: `CONFIG_NETCONSOLE=y` targeting host syslog port `6666`.

---

## 4. Verification Methodology

1. **Hardware Link Verification**:
   - Verify 1000BASE-T link partner auto-negotiation and speed LED status on the physical VCU118 RJ-45 jack.
2. **Loopback & Packet Framing**:
   - Run standard packet ping diagnostics over local network subnet.
   - Validate Scatter-Gather descriptor ring allocation and frame checksum offload.
3. **Interactive Network Login**:
   - Establish interactive shell session over SSH:
     ```bash
     ssh root@<board-ip>
     ```
   - Validate full bi-directional terminal control over Ethernet concurrently with serial UART diagnostics.

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

This document specifies the ground-truth hardware architecture, RTL integration, Vivado IP configuration, loopback verification, and Linux networking stack for dual-networking support on the **AMD/Xilinx VCU118 Evaluation Board** (`xcvu9p-flga2104-2L-e`), satisfying two primary objectives:
1. **1Gb RJ-45 Ethernet (`eth1`)**: License-free AMD `gig_ethernet_pcs_pma:17.0` configured in **SGMII over LVDS** mode (Bank 64 High-Speed SelectIO `BITSLICE`) + autonomous TI DP83867ISRGZ MDIO initializer + FROST coherent DMA NIC (`nic_top` with `GMII_MODE = 1`) for 1000BASE-T LAN connectivity, DHCP, TFTP/NFS boot, and SSH login console.
2. **10Gb QSFP28 Ethernet (`eth0`)**: FROST native `net10g` 10GBASE-R soft MAC/PCS (`nic_top` with `GMII_MODE = 0, RAW_LOOPBACK = 0`) connected to QSFP1 Lane 0 (Quad 231 `GTYE4_CHANNEL_X1Y48`), verified on hardware via GTY near-end PMA loopback (`frost_nettest`) and ready for external 10Gb switch/host connectivity.

---

## 1. Architectural Principles & Right-First-Time Guarantees

### 1.1 Strict Alveo X3 Target Isolation (Zero Regression)
- **Zero modification to X3 behavior**: All shared modules (`soc_top.sv`, `frost.sv`, `xilinx_frost_subsystem.sv`, `nic_top.sv`, `nic_mac_wrap.sv`) guard the second (1Gb) NIC behind build-time parameters defaulting to disabled (`ENABLE_1G_ETH = 0`, `GMII_MODE = 0`).
- **Identical X3 Synthesis & Simulation**: With `ENABLE_1G_ETH = 0`, `soc_top` builds the exact 2-port `axi_mux` (`DmaPorts = 2`), MMIO map, and APLIC interrupt wiring used on X3 today.
- **Board-Specific Encapsulation**: All VCU118 transceiver/PCS IP generation (`fpga/build/vcu118_gty_ip.tcl`), PHY/GTY wrappers (`boards/vcu118/vcu118_nic_gty.sv`, `boards/vcu118/vcu118_eth1g.sv`), and physical constraints (`boards/vcu118/constr/vcu118.xdc`) are isolated to VCU118 build targets.

### 1.2 License-Free Vivado 2025.2.1 IP & Coherent DMA Unification
- **Avoidance of Paid TEMAC License (`Design_Linking` Blocker)**: In Vivado 2025.2.1, `axi_ethernet:8.0` and `tri_mode_ethernet_mac:9.0` require a paid `tri_mode_eth_mac` license (`Design_Linking`), which blocks `write_bitstream`. By contrast, **`gig_ethernet_pcs_pma:17.0`** (1G/2.5G Ethernet PCS/PMA or SGMII) and **`gtwizard_ultrascale:1.7`** have license status **`Included`** (100% free bitstream generation).
- **Unified Coherent DMA & MAC Engine**:
  - The 1Gb subsystem uses `gig_ethernet_pcs_pma:17.0` in `SGMII over LVDS` mode (`clk125_out` 125 MHz GMII interface with `sgmii_clk_en`) coupled to a second instance of `nic_top` configured with `GMII_MODE = 1`.
  - In `GMII_MODE = 1`, `nic_mac_wrap` reuses FROST's store-and-forward `eth10g_mac_tx` (with IEEE 802.3 60-byte minimum frame padding and 32-bit FCS generation) and `eth10g_mac_rx` (with 32-bit FCS validation and bad-frame rollback) through an 8:1 XGMII-to-GMII TX serializer and 1:8 GMII-to-XGMII RX deserializer, bypassing the 10GBASE-R 64b/66b PCS/gearbox.
  - Both the 10Gb NIC (`0x4003_0000`) and 1Gb NIC (`0x4002_2000`) use the exact same 256-bit `LINE_BYTES = 32` cache-coherent DMA protocol into `axi_mux` -> `axi_coherent_bridge` -> L2 cache, and both bind to the same out-of-tree `frost_net10g.ko` kernel module compiled by `linux/debian_kernel.py` against Debian's `vmlinux-6.12.113+deb13-riscv64` kernel.

### 1.3 Common Linux Image & Device Tree Across X3 and VCU118
- **Single Kernel & Initramfs**: Both X3 and VCU118 boot the exact same Debian `vmlinux-6.12.113+deb13-riscv64` kernel and module-augmented initramfs (`rootfs.cpio`).
- **Hardware-Probed Device Tree**:
  - `frost.dts` declares `ethernet@40030000` (10Gb NIC, APLIC Source 4, MAC `02:11:22:33:44:55`) first and `ethernet@40022000` (1Gb NIC, APLIC Source 2, MAC `02:11:22:33:44:56`) second.
  - On **Alveo X3** (`ENABLE_1G_ETH = 0`): `0x4002_2000` reads `0x0000_0000`, so `frost_probe` returns `-ENODEV` for `ethernet@40022000` and registers only `eth0` (10Gb GTY).
  - On **VCU118** (`ENABLE_1G_ETH = 1`): `ethernet@40030000` registers as **`eth0`** (10Gb QSFP28) and `ethernet@40022000` registers as **`eth1`** (1Gb RJ-45).
  - Because `eth0` is the 10Gb QSFP28 interface, running `frost_nettest` automatically selects `eth0` (`FROST_NET_LOOPBACK_PASS`) without disrupting live 1Gb RJ-45 LAN / SSH / NFS traffic on `eth1`. `frost_nettest` also accepts an optional interface name (`frost_nettest eth1`) to test 1Gb loopback on demand.

---

## 2. Complete Dual-Networking System Architecture

```mermaid
flowchart TD
    subgraph FROST_Core ["FROST SoC (soc_top.sv in SLR2)"]
        CPU["FROST Out-of-Order RISC-V Core\n(200 MHz main_clock)"]
        L2["Unified L2 Cache + DDR4 ECC"]
        COH["axi_coherent_bridge\n(256-bit Coherent Line Port)"]
        MUX["axi_mux\n(DmaPorts = 3 on VCU118, 2 on X3)"]
        AXIL["MMIO AXI4-Lite Demux"]
        APLIC["APLIC Interrupt Controller\n(Sources 1..5)"]

        NIC10G["u_nic: nic_top (GMII_MODE=0, RAW_LOOPBACK=0)\nMMIO: 0x4003_0000 | IRQ: APLIC Src 4\nLinux: eth0 (10Gb QSFP28)"]
        NIC1G["u_nic_1g: nic_top (GMII_MODE=1, ENABLE_1G_ETH=1)\nMMIO: 0x4002_2000 | IRQ: APLIC Src 2\nLinux: eth1 (1Gb RJ-45)"]

        CPU --> L2
        COH --> L2
        MUX --> COH
        AXIL -->|0x4003_0000| NIC10G
        AXIL -->|0x4002_2000| NIC1G
        NIC10G -->|256-bit DMA| MUX
        NIC1G -->|256-bit DMA| MUX
        NIC10G -->|IRQ Src 4| APLIC
        NIC1G -->|IRQ Src 2| APLIC
    end

    subgraph VCU118_10G ["10Gb QSFP28 Wrapper (vcu118_nic_gty.sv)"]
        SUP10G["x3_nic_gty_supervisor\n(150 MHz freerun from sysclk1_300 / 2)"]
        GTY10G["vcu118_nic_gty_wiz (gtwizard_ultrascale:1.7)\nQuad 231 GTYE4_CHANNEL_X1Y48\n10.3125 Gbps, 64-bit Raw PMA @ 161.13 MHz"]
        QSFP1["QSFP28 Cage 1 (QSFP1)\nRefClk0: W9/W8 (156.25 MHz)\nTX0: V7/V6 | RX0: Y2/Y1\nControl: AM21/BA22/AN21"]

        NIC10G <-->|64-bit Raw PMA| GTY10G
        SUP10G --> GTY10G
        GTY10G <--> QSFP1
        GTY10G -.->|PMA Loopback (3'b010)| GTY10G
    end

    subgraph VCU118_1G ["1Gb RJ-45 SGMII Wrapper (vcu118_eth1g.sv)"]
        MDIO_INIT["DP83867 MDIO Initializer (50 MHz clk_div4)\nPHY Addr 0x03:\n1. CFG4 (0x0031) <= 0x0070\n2. SGMIICTL1 (0x00D3) <= 0x4000 (625 MHz Clk En)\n3. 10M_SGMII_CFG (0x016F) <= 0x0015"]
        PCS1G["vcu118_pcs_pma_1g (gig_ethernet_pcs_pma:17.0)\nSGMII over LVDS (Bank 64 BITSLICE)\nDIFF_PAIR_2 TX / DIFF_PAIR_0 RX\n125 MHz GMII (clk125_out + sgmii_clk_en)"]
        PHY1G["TI DP83867ISRGZ PHY + RJ-45 Jack\n625 MHz RefClk: AT22/AU22\nSGMII TX: AU21/AV21 | RX: AU24/AV24\nMDC: AV23 | MDIO: AR23 | RST_N: BA21"]

        NIC1G <-->|GMII @ 125 MHz| PCS1G
        MDIO_INIT -->|MDC/MDIO/RST_N| PHY1G
        MDIO_INIT -->|Release Reset After 625MHz Clk Up| PCS1G
        PCS1G <-->|SGMII LVDS| PHY1G
    end
```

---

## 3. Verified Hardware Pinout, Bank Rules & Resource Map

### 3.1 1Gb RJ-45 SGMII-over-LVDS Pinout (Bank 64, TI DP83867ISRGZ)
Verified against official Xilinx VCU118 board definition files (`part0_pins.xml`, `board.xml`, `preset.xml`, UG1224):

| Signal Name | FPGA Pin | Bank | I/O Standard & Properties | Function |
| :--- | :--- | :--- | :--- | :--- |
| `sgmii_phyclk_p` / `_n` | `AT22` / `AU22` | Bank 64 | `LVDS`, `DIFF_TERM_ADV = TERM_100` | **625.0 MHz** differential SGMII clock from DP83867 PHY |
| `sgmii_txp` / `sgmii_txn` | `AU21` / `AV21` | Bank 64 | `LVDS` (or `DIFF_HSTL_I_DCI_18`), `DIFF_PAIR_2` | SGMII differential serial transmit data (1.25 Gbps) |
| `sgmii_rxp` / `sgmii_rxn` | `AU24` / `AV24` | Bank 64 | `LVDS`, `DIFF_TERM_ADV = TERM_100`, `DIFF_PAIR_0` | SGMII differential serial receive data (1.25 Gbps) |
| `phy_rst_n` | `BA21` | Bank 64 | `LVCMOS18`, `SLEW SLOW`, `DRIVE 8` | Active-low hardware PHY reset |
| `phy_mdc` | `AV23` | Bank 64 | `LVCMOS18`, `SLEW SLOW`, `DRIVE 8` | MDIO management clock (~1.56 MHz from 50 MHz `clk_div4`) |
| `phy_mdio` | `AR23` | Bank 64 | `LVCMOS18`, `SLEW SLOW`, `DRIVE 8` | Bidirectional MDIO management data (`PHY_ADDR = 5'h03`) |

**Mandatory UltraScale+ Bank 64/65 & BITSLICE Configuration**:
- `vcu118_pcs_pma_1g` (`gig_ethernet_pcs_pma:17.0`):
  - `CONFIG.Standard {SGMII}`
  - `CONFIG.Physical_Interface {LVDS}`
  - `CONFIG.Management_Interface {false}` (driven directly via `configuration_vector_0 = {1'b1, 2'b00, pma_loopback, 1'b0}` and `an_adv_config_vector_0 = 16'hd801`)
  - `CONFIG.Auto_Negotiation {true}`
  - `CONFIG.SupportLevel {Include_Shared_Logic_in_Core}`
  - `CONFIG.LvdsRefClk {625}`
  - `CONFIG.Tx_In_Upper_Nibble {0}`
  - `CONFIG.RxNibbleBitslice0Used {false}`
  - `CONFIG.TxLane0_Placement {DIFF_PAIR_2}`
  - `CONFIG.RxLane0_Placement {DIFF_PAIR_0}`
- **DP83867 625 MHz Clock Bootstrap Requirement**:
  - Out of hardware reset (`BA21`), the TI DP83867 PHY on VCU118 defaults to 4-wire SGMII (`SGMIICTL1` bit 14 = `0`), keeping the 625 MHz differential clock output (`AT22`/`AU22`) disabled.
  - `vcu118_eth1g.sv` runs an autonomous MDIO state machine on the free-running 50 MHz `i_clk_div4` clock that:
    1. Holds `phy_rst_n = 0` for ~16 ms, releases `phy_rst_n = 1`, and waits ~16 ms for internal PHY initialization.
    2. Performs 14 Clause-22 MDIO writes to `PHY_ADDR = 5'h03` using indirect extended addressing (`REGCR = 5'h0D`, `ADDAR = 5'h0E`) and direct standard registers:
       - Extended Reg `0x0031` (`CFG4`) `<= 16'h0070` (SGMII AN timer = 11 ms).
       - Extended Reg `0x00D3` (`SGMIICTL1`) `<= 16'h4000` (Enable 6-wire SGMII 625 MHz differential clock output).
       - Extended Reg `0x016F` (`10M_SGMII_CFG`) `<= 16'h0015` (10M SGMII configuration).
       - Standard Reg `0x0010` (`PHYCR`) `<= 16'h5848` (Enable SGMII interface mode, bit 11 = `1`, MDI crossover auto).
       - Standard Reg `0x0000` (`BMCR`) `<= 16'h1340` (Enable Auto-Negotiation, restart AN, 1000 Mbps Full Duplex).
    3. Waits ~2 ms after initialization completes so the 625 MHz differential clock on `AT22`/`AU22` is stable before releasing `vcu118_pcs_pma_1g.reset`, ensuring reliable UltraScale+ BITSLICE RIU/delay calibration.

### 3.2 10Gb QSFP28 Pinout (Quad 231, QSFP1 Cage)
Verified against VCU118 schematic and `xcvu9p-flga2104-2L-e` package layout:

| Signal Name | FPGA Pin | Bank / Site | I/O Standard | Function |
| :--- | :--- | :--- | :--- | :--- |
| `i_qsfp1_refclk_p` / `_n` | `W9` / `W8` | Quad 231 (`MGTREFCLK0_231`) | GTY RefClk | **156.250 MHz** differential reference clock (`X1Y48 clk0`) |
| `o_qsfp1_tx_p` / `_n` | `V7` / `V6` | Quad 231 (`GTYE4_CHANNEL_X1Y48`) | GTY Serial | 10.3125 Gbps QSFP1 Lane 0 serial TX |
| `i_qsfp1_rx_p` / `_n` | `Y2` / `Y1` | Quad 231 (`GTYE4_CHANNEL_X1Y48`) | GTY Serial | 10.3125 Gbps QSFP1 Lane 0 serial RX |
| `o_qsfp1_modsell` | `AM21` | Bank 64 | `LVCMOS18` | QSFP1 Module Select (driven `1'b0` = selected) |
| `o_qsfp1_resetl` | `BA22` | Bank 64 | `LVCMOS18` | QSFP1 Module Reset (driven `1'b1` = not in reset) |
| `o_qsfp1_lpmode` | `AN21` | Bank 64 | `LVCMOS18` | QSFP1 Low-Power Mode (driven `1'b0` = normal high-power mode) |
| `i_qsfp1_modprsl` | `AL21` | Bank 64 | `LVCMOS18`, `PULLUP true` | QSFP1 Module Present (active-low; `0` = module inserted) |

### 3.3 Memory Map & APLIC Interrupts (`soc_top.sv`)

| Peripheral | Physical Address Window | Size | APLIC Source | Linux Device / Driver |
| :--- | :--- | :--- | :--- | :--- |
| `ns16550a` UART | `0x4000_1000 – 0x4000_10ff` | 256 B | Source 1 | `/dev/ttyS0` (`serial8250`) |
| SiFive CLINT | `0x4001_0000 – 0x4001_bfff` | 48 KiB | Timer / IPI | `clint` |
| DMA Test Engine | `0x4002_0000 – 0x4002_00ff` | 256 B | Source 3 | `frost,dma-test-engine` |
| Memory Error Unit | `0x4002_1000 – 0x4002_10ff` | 256 B | Source 5 | `frost_memerr.ko` |
| **1Gb RJ-45 NIC (`u_nic_1g`)** | **`0x4002_2000 – 0x4002_2fff`** | **4 KiB** | **Source 2** | **`eth1` (`frost_net10g.ko`, VCU118 only)** |
| **10Gb QSFP28 NIC (`u_nic`)** | **`0x4003_0000 – 0x4003_0fff`** | **4 KiB** | **Source 4** | **`eth0` (`frost_net10g.ko`, X3 & VCU118)** |

> [!NOTE]
> `0x4002_2000 – 0x4002_2fff` already resides inside the strongly-ordered device PMA range `[MmioFirstPage, MmioLastPage]` (`0x4000_0000 – 0x4003_0fff`), and APLIC Source 2 is already allocated in `aplic_inst` (`NUM_SOURCES = 5`). Thus `riscv_pkg.sv` and the APLIC configuration require zero structural changes.

---

## 4. 10Gb QSFP28 & 1Gb RJ-45 Loopback Verification

1. **10Gb QSFP28 Near-End PMA Loopback (`eth0`)**:
   - `vcu118_nic_gty_wiz` (`gtwizard_ultrascale:1.7` on `GTYE4_CHANNEL_X1Y48`) exposes `loopback_in[2:0]`.
   - Since `RAW_LOOPBACK = 0` on hardware (independent TX and RX GTY recovered clocks), `PHY_STATUS.CLK_SHARED` reads `0`.
   - When `frost_nettest` enables `ethtool -K eth0 loopback on` and brings `eth0` up, `frost_net10g.ko` sets `PHY_CTRL.PMA_LOOPBACK` (`bit 2`), which drives `loopback_in = 3'b010` (GTY Near-End PMA loopback) and forces `rx_signal_ok = 1'b1`.
   - `x3_nic_gty_supervisor` completes TX and RX GTY reset sequencing on the free-running 150 MHz clock (`sysclk1_300 / 2`), locks the 64b/66b PCS block aligner, asserts carrier (`NET10G_LINK_CARRIER`), and streams 9000-byte jumbo frames, short padded frames (14..160 bytes), and 300-frame bursts through TX DMA -> 64b/66b PCS -> GTY PMA serializer -> GTY PMA deserializer -> 64b/66b PCS -> RX DMA -> L2 cache, printing `FROST_NET_LOOPBACK_PASS`.
2. **1Gb RJ-45 SGMII Loopback (`eth1`)**:
   - `u_nic_1g` (`GMII_MODE = 1, RAW_LOOPBACK = 1`) shares `clk125_out` for TX and RX, supporting both `MAC_LOOPBACK` (GMII TX directly into GMII RX) and PCS loopback (`configuration_vector_0[1]`).

---

## 5. Linux Networking, SSH Console & TFTP/NFS Boot

1. **Automatic Interface Bring-Up & DHCP (`S03frost-net10g` / `S45frost-net`)**:
   - At boot, `S03frost-net10g` loads `frost_net10g.ko` and prints `FROST_NET10G_MODULE_PASS 6.12.113+deb13-riscv64`.
   - When `eth1` (the 1Gb RJ-45 interface on VCU118) is present, `/etc/init.d/S45frost-net` brings `eth1` up (`ip link set eth1 up`) and launches `udhcpc -i eth1 -b -q -S` in the background (using Buildroot's `/usr/share/udhcpc/default.script` to configure the IPv4 address, default route, and `/etc/resolv.conf` when a DHCP lease is granted).
   - `eth0` (10Gb QSFP28) is left down at boot so `frost_nettest` can immediately run 10Gb PMA loopback verification without conflict; when a 10Gb switch/host is connected, `ip link set eth0 up && udhcpc -i eth0 -b` brings up 10Gb networking.
2. **Simultaneous Login Consoles (UART + 1Gb SSH + 10Gb SSH)**:
   - **UART Console**: `/sbin/getty -L console 0 vt100` on `/dev/ttyS0` (115200 baud).
   - **SSH Server (`dropbear`)**: Enabled in Buildroot (`BR2_PACKAGE_DROPBEAR=y`) with blank-password root login enabled for evaluation (`DROPBEAR_ARGS="-B"` in `/etc/default/dropbear`), listening on TCP port 22 across all active interfaces (`eth1` 1Gb RJ-45 and `eth0` 10Gb QSFP28).
3. **TFTP & NFS Root Boot Support**:
   - BusyBox `tftp` and in-kernel NFSv3 client support (`mount -t nfs -o nolock,vers=3,tcp`) are available in the Debian 6.12 + Buildroot environment for fetching kernels/files via TFTP and mounting NFSv3 shares directly from userspace.
   - Full NFS root boot (`FROST_LINUX_NFSROOT=<server-ip>:/<path>`) is supported via `sw/apps/linux_boot/Makefile` and `frost_boot_image.py` (`boot=nfs root=/dev/nfs nfsroot=... rw ip=dhcp`).

---

## 6. Implementation Phases & File Manifest

| Phase | Files Modified / Created | Description |
| :--- | :--- | :--- |
| **Phase 1: 1Gb GMII Mode & Dual-NIC SoC RTL** | `hw/rtl/peripherals/nic/nic_mac_wrap.sv`<br>`hw/rtl/peripherals/nic/nic_top.sv`<br>`hw/rtl/soc_top/soc_top.sv`<br>`hw/rtl/platform_top.sv`<br>`hw/rtl/frost.sv`<br>`boards/xilinx_frost_subsystem.sv` | Add `GMII_MODE` (`0` default, `1` for 8:1 XGMII<->GMII adapter with `eth10g_mac_tx`/`rx`) and `ENABLE_1G_ETH` (`0` default, `1` on VCU118 for `u_nic_1g` at `0x4002_2000`, APLIC Src 2, `DmaPorts = 3`). |
| **Phase 2: Vivado Transceiver & PCS/PMA IPs** | `fpga/build/vcu118_gty_ip.tcl`<br>`fpga/build/build_step.tcl` | Generate `vcu118_nic_gty_wiz` (`gtwizard_ultrascale:1.7` on `X1Y48`, 156.25 MHz refclk, 10.3125 Gbps) and `vcu118_pcs_pma_1g` (`gig_ethernet_pcs_pma:17.0` in SGMII over LVDS mode, 625 MHz refclk). |
| **Phase 3: VCU118 Board Wrappers & Constraints** | `boards/vcu118/vcu118_nic_gty.sv`<br>`boards/vcu118/vcu118_eth1g.sv`<br>`boards/vcu118/vcu118_clock.sv`<br>`boards/vcu118/vcu118_frost.sv`<br>`boards/vcu118/vcu118_frost.f`<br>`boards/vcu118/constr/vcu118.xdc` | Implement 150 MHz free-running clock (`BUFGCE_DIV`), 10G GTY wrapper, 1G DP83867 MDIO initializer + SGMII PCS/PMA wrapper, top-level ports, and Bank 64 / Quad 231 pin & timing constraints. |
| **Phase 4: Linux DTB, Driver & Userspace** | `linux/frost-net10g/frost_net10g.c`<br>`linux/buildroot-external/board/frost/frost_boot_image.py`<br>`linux/buildroot-external/package/frost-stress/src/frost_nettest.c`<br>`linux/buildroot-external/configs/frost_rv64_defconfig`<br>`linux/buildroot-external/board/frost/rootfs-overlay-mmu/etc/default/dropbear`<br>`linux/buildroot-external/board/frost/rootfs-overlay-mmu/etc/init.d/S45frost-net` | Add `ethernet@40022000` to DTB, quiet `-ENODEV` when `NET10G_ID == 0`, optional interface arg in `frost_nettest`, enable `dropbear` SSH + `udhcpc` DHCP, and auto-configure `eth1`. |
| **Phase 5: Bitstream Build & Hardware Verification** | `fpga/build/build.py vcu118`<br>`fpga/program_bitstream/program_bitstream.py vcu118`<br>`fpga/load_software/load_software.py vcu118 linux_boot` | Synthesize, place, route, verify timing closure ($WNS \ge 0\text{ ns}$), program VCU118, verify `frost_nettest` 10Gb PMA loopback (`FROST_NET_LOOPBACK_PASS`), 1Gb link/DHCP/ping/SSH login, and TFTP/NFS. |

---

## 7. Post-Route Implementation & Silicon Verification Results

### 7.1 Post-Route Timing Closure & Resource Utilization (`xcvu9p-flga2104-2L-e` @ 200.0 MHz)
- **Overall Setup Timing**: **$WNS = +0.004\text{ ns}$, $TNS = 0.000\text{ ns}$ (0 / 516,627 failing endpoints)**
- **Overall Hold Timing**: **$WHS = +0.010\text{ ns}$, $THS = 0.000\text{ ns}$ (0 / 515,767 failing endpoints)**
- **Key Clock Domains**:
  - `clk_cpu_unbuf` (200.020 MHz): $WNS = +0.004\text{ ns}$, $WHS = +0.010\text{ ns}$
  - `mmcm_clkout0` (300.000 MHz DDR4 UI): $WNS = +0.011\text{ ns}$, $WHS = +0.010\text{ ns}$
  - `nic_tx_clk` / `nic_rx_clk` (161.133 MHz 10Gb GTY): $WNS = +0.874\text{ ns}$ / $+0.930\text{ ns}$, $WHS = +0.041\text{ ns}$ / $+0.018\text{ ns}$
  - `IntTx_ClkOut1` / `IntRx_ClkOut0` (125.0 MHz / 312.5 MHz 1Gb SGMII PCS/PMA): $WNS = +1.887\text{ ns}$ / $+0.143\text{ ns}$, $WHS = +0.028\text{ ns}$ / $+0.025\text{ ns}$
  - `freerun_clk_150` (150.015 MHz GTY supervisor): $WNS = +3.663\text{ ns}$, $WHS = +0.041\text{ ns}$
- **Resource Utilization**:
  - CLB LUTs: 199,044 / 1,182,240 (16.84%)
  - CLB Registers: 126,801 / 2,364,480 (5.36%)
  - Block RAM Tiles: 225.5 / 2,160 (10.44%), UltraRAM: 66 / 960 (6.88%)
  - High-Speed I/O & Transceivers: 1 `GTYE4_CHANNEL` + 1 `GTYE4_COMMON` (Quad 231), `vcu118_pcs_pma_1g` BITSLICEs in Bank 64.

### 7.2 Physical Hardware Verification on VCU118
1. **Linux 6.12 Boot & Dual-NIC Driver Registration**:
   - `FROST_NET10G_MODULE_PASS 6.12.113+deb13-riscv64`
   - `frost_net10g 40030000.ethernet eth0: FROST 10G Ethernet at 0x40030000, irq 12, mac 02:11:22:33:44:55`
   - `frost_net10g 40022000.ethernet eth1: FROST 10G Ethernet at 0x40022000, irq 13, mac 02:11:22:33:44:56`
2. **Objective 2 — 10Gb QSFP28 (`eth0`) GTY Near-End PMA Loopback**:
   - Executed `frost_nettest eth0` on physical VCU118 silicon:
     - Verified GTY PMA loopback link lock (`carrier = 1` on `GTYE4_CHANNEL_X1Y48`), MTU 9000 jumbo frames, short frame padding (`14..160` bytes), boundary lengths (`1514..9014` bytes), 300-frame back-to-back burst, and 64-frame ring drain (`514` frames TX/RX, `0` errors) -> **`FROST_NET_LOOPBACK_PASS`**.
3. **Objective 1 — 1Gb RJ-45 (`eth1`) Live LAN, DHCP & Concurrent SSH Console**:
   - Autonomous MDIO state machine initialized TI DP83867 (`PHY_ADDR = 5'h03`) into 6-wire SGMII mode (`625 MHz` differential clock active) and negotiated 1000BASE-T Full Duplex (`carrier = 1`).
   - `S45frost-net` acquired IPv4 lease via `udhcpc` on `eth1`, verified 0% packet loss on bidirectional ICMP `ping`, and verified live interactive `ssh root@<board-ip>` login into the RISC-V Linux shell concurrently with the `/dev/ttyS0` UART console.

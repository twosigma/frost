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

# VCU118 Evaluation Board Target

The VCU118 target uses `xcvu9p-flga2104-2L-e`, the shared FROST subsystem,
a USB-UART console, status LEDs, one DDR4 controller, and two Ethernet
interfaces: RJ-45 and QSFP1 lane 0. It has 256 KiB of
BRAM, a 32 KiB instruction cache, a 128 KiB data cache, and a 4 MiB L2 cache.
The L1I uses four ways, 256 sets and 32-byte lines; it is indexed by the
translated line address, so its 8 KiB ways create no virtual aliases, and its
256-deep banks occupy the same block RAMs as the 16 KiB default's 128-deep
ones. The L2 uses four ways, 16,384 sets and 64-byte lines. The board top
passes `L1I_CACHE_BYTES` and `L2_CACHE_BYTES` through the shared subsystem;
their defaults remain 16 KiB and 2 MiB for other boards. The software loader sets
`L1I_TEST_BYTES=32768` and `FROST_L2_CACHE_BYTES=4194304` for VCU118
applications so cache-geometry and conflicting-set tests use the same geometry.

## Board integration

`vcu118_clock.sv` generates the CPU and CPU/4 clocks with an MMCM driven by
`SYSCLK1_300`. The build and software loader use a fixed clock configuration.
The DDR controller uses its independent reference input. The optional GTY
CPU clock wrapper is outside the active board file list.
The networking build generates the GTY and SGMII PCS/PMA cores.

The board's clock-source jumpers must select the SYSCLK1_300 source. The
Rev 2.0 board defaults to 0.85 V VCCINT; earlier revisions use 0.72 V.

| Signal | Pins | Bank | SLR |
|---|---|---|---|
| SYSCLK1_300 | G31/F31 | 47 | 1 |
| CPU reset, SW5 | L19 | 73 | 2 |
| FPGA UART TX/RX | BB21/AW25 | 64 | 1 |
| Status LEDs | AT32, AV34, AY30, BB32 | 40 | 0 |
| DDR reference | E12/D12 | 71 | 2 |

The console uses the CP2105 standard port, interface 1, at 115200 baud.
The loader's serial default prefers its `/dev/serial/by-id/` entry;
`--serial` on the hardware runner overrides it. The LED bits report clock
lock, DDR initialization completion, heartbeat, and the reset button.

`pblock_slr2` contains movable logic from the FROST subsystem, DDR subsystem
and DDR initializer. The XDC creates the region directly and assigns that
logic to SLR2. The clock generator's dedicated primitives are excluded from the
region. Configuration primitives remain at their fixed device sites. Peripheral
pins span multiple SLRs; top-level reset and status logic is outside that
hierarchy selection.

The PCS/PMA IP supplies the SGMII reference clock constraint. The reset
button and UART receive input are asynchronous inputs; the UART receiver
uses a two-register synchronizer. MDC and MDIO form a write-only PHY
bootstrap interface, with MDIO data updated while MDC is low.

## Memory and reset

The board has two physical 80-bit DDR4 interfaces. This target uses one
interface in banks 71–73 with 64 data bits and eight ECC bits, exposing
2 GiB at CPU address `0x80000000`. The CPU bridge uses 512-bit AXI data,
31-bit region offsets and five-bit IDs. The CPU and JTAG loader share the
controller through SmartConnect. The `ddr_ecc` stage reads the controller's
ECC registers through a JTAG control window at region offset `0x80000000`.
The CPU's memory error unit reports DDR AXI errors.

Svpbmt NC and IO mappings of DDR raise an access fault on this 2 GiB map:
its 32-bit physical address space has no room for an uncached DDR alias.
Device mappings support NC and IO attributes.
The `svpbmt_cmo_test` application requires the DDR aliases.

The CPU performs plain misaligned loads and stores to cached DDR in hardware
by default. Misaligned accesses to low BRAM or mapped device registers raise
the address-misaligned exception (cause 4 or 6). To use firmware emulation,
build with `fpga/build/build.py vcu118 --no-misaligned-hw`. This sets the
top-level `MISALIGNED_HW` parameter to 0. Disabling the cached tier also
leaves the engine out.

Power-up, a press of SW5 or loss of CPU clock lock resets the DDR
controller and discards the contents of the mapped 2 GiB. The core,
initializer and JTAG DDR loader enter reset at the same instant as
SmartConnect and FROST's DDR transport, even when both clocks stop.
Loss of lock also clears the calibration-ready synchronizer. The transport
releases when the clock is locked and SW5 is released. The initializer
leaves reset after three CPU clock edges. Once synchronized calibration
is ready, it starts at offset zero and writes a full 64-byte word of zeros
to every address in the region to establish its ECC bits.

The address and data channels hold their payloads until accepted and insert
an idle cycle after each transfer. The CPU and JTAG loader wait for the
entire sweep, including the last OKAY write response. A write error holds
them in reset until the next controller reset starts another sweep. The
release takes four CPU clocks for the core and two CPU/4 clocks for JTAG
once initialization and synchronized calibration are both ready.

Loss of calibration alone holds the core and JTAG loader in reset. It
preserves the completed sweep and leaves the transport and its write mux
running so that accepted requests can drain. Recalibration then releases
the requesters without clearing memory again.
The controller provides ECC, but this wrapper does not forward its error
telemetry to the CPU memory error unit.

## Ethernet and boot controller

The RJ-45 port uses the DP83867 PHY and an SGMII PCS/PMA connected to a
pluggable 1G GMII MAC block (`nic_mac_1g`) paired with its own `nic_engine`
in full-duplex mode. Its registers occupy `0x40022000`
and use APLIC source 2. The PHY reports the negotiated copper link through
SGMII. QSFP1 lane 0 uses a GTY channel and a 10GBASE-R MAC block (`nic_mac_10g`)
paired with its own `nic_engine`. Its NIC
registers occupy `0x40030000` and use APLIC source 4. Both NIC engines use coherent
DMA through the shared memory hierarchy and talk to their MAC blocks across the
same core-clock 64-bit AXI4-Stream and sideband boundary.

The PHY management sequencer completes the existing bootstrap before polling
DP83867 RECR. Each acknowledged read is followed by a dummy write to clear the
saturating counter; polling does not rewrite link configuration. Samples remain
stable until the NIC acknowledges them. Missing PHY responses leave the last
sample unchanged. The FCS diagnostic slots are reserved and read zero because
this PHY exposes no FCS error count; use the MAC's `rx_mac_bad_fcs` instead. See the [NIC counter map](../../hw/rtl/peripherals/nic/README.md).

The boot controller at `0x40023000` provides SPI transfers through STARTUPE3,
DDR status and an instruction-SRAM programming port. The initial BRAM
application loads an FSBL from flash into executable SRAM. The FSBL loads
OpenSBI, a device tree and U-Boot into DDR after checking their checksums.
With this flash boot path, Linux `reboot` requests SYSRESET, re-enters the
surviving BRAM ROM and reloads these stages before U-Boot follows its boot
command; `poweroff` halts with power still applied.

## Build and load

Run from the repository root with Vivado and the RISC-V toolchain available.
The Vivado license must cover the target device.

```bash
./fpga/build/build.py vcu118
python3 fpga/program_bitstream/program_bitstream.py vcu118
python3 fpga/load_software/load_software.py vcu118 hello_world
```

`--build-dir` selects an external build directory. Pass its generated
`.bit` file with the programmer's `--bitstream` option. Target selection and
hardware-server options are described in the [FPGA guide](../../fpga/README.md).

Software loading uses separate JTAG AXI masters for BRAM and DDR. BRAM
writes hold the CPU in reset while the loader transfers the DDR image and
then the BRAM image. Software starts after the BRAM reset timer expires.

The Linux application packages OpenSBI, the kernel, device tree and initramfs
for the same JTAG loading path. Linux uses the board's DDR capacity unless
`FROST_LINUX_MEM_SIZE` selects a smaller supported allocation.

```bash
python3 fpga/load_software/load_software.py vcu118 opensbi_smoke
python3 fpga/load_software/load_software.py vcu118 linux_boot
```

Use the serial console to interact with Linux. U-Boot provides an interactive
console, SPI flash commands and network loading through the Ethernet NICs.

## Flash boot and U-Boot

Flash boot requires a Rev 2.0 board with QSPI configuration memory; earlier
revisions have BPI flash. The configuration flash holds the FPGA image at
offset zero, in the first 64 MiB of the 128 MiB part, and the four
software stages from `0x04000000`. Each software stage has a
32-byte header with its load address, length, entry address and CRC-32.
The boot stages reject invalid bounds and
checksums. The ROM loads the FSBL at reset; the FSBL enters OpenSBI, which
starts U-Boot in supervisor mode. No JTAG software load is needed for this
path. The FSBL is a flash stage, not a standalone JTAG application.

| Stage | Flash offset | Load address | Maximum payload |
|---|---|---|---|
| FSBL | `0x04000000` | `0x00004000` | 79 KiB |
| OpenSBI | `0x04100000` | `0x80000000` | 1 MiB minus 32 bytes |
| Device tree | `0x04200000` | `0x82200000` | 128 KiB |
| U-Boot | `0x04300000` | `0x80200000` | 1 MiB minus 32 bytes |

Build the firmware and pack the software image from the repository root:

```bash
./scripts/frost.py run make -C sw/uboot firmware
python3 fpga/flash/make_flash_image.py --output /path/to/boot.bin
python3 fpga/flash/program_flash.py --boot-image /path/to/boot.bin \
  --fpga-image /path/to/vcu118_frost.bit --output-dir /path/to/flash-output \
  --prepare-only
```

The U-Boot build fetches its pinned v2026.10 source revision into
`sw/uboot/build/source`. OpenSBI uses the repository's FROST configuration;
the device tree is compiled from `dts/frost_vcu118.dts`. Component overrides
on the packer are `--fsbl`, `--opensbi`, `--dtb`, and `--uboot`.

Remove `--prepare-only` to program the selected VCU118 configuration flash.
Use `--target-exact` and `--hw-server-url` to select a cable and server.
`--boot-only` replaces `--fpga-image` when updating the four software
partitions. Select the board's SPI configuration boot mode for startup
from flash. The programmer erases and verifies the ranges in its generated
configuration-memory file.

The mode switch is SW16. Positions 2, 3 and 4 are M2, M1 and M0 (ON = 1);
position 1 is not a mode bit. Set **ON / OFF / OFF / ON** for Master SPI
(M[2:0] = 001). With M[2:0] = 101 (JTAG) the FPGA ignores the flash, the user
LEDs stay dark, and `boot_hw_device` fails. Read the pins from an unconfigured
device with `list_property` on `REGISTER.CONFIG_STATUS.SLR0.*` after
`refresh_hw_device`; they update as the switch moves. A configured design
lights one user LED steadily and blinks another.

U-Boot stops at `frost=>`. Its environment is volatile; `saveenv` is not
supported. It provides `sf` commands for flash access and DHCP, ping and TFTP
through either NIC. For RJ-45 network loading, set the server address and use
that interface. This example loads a kernel, a DTB and an initramfs; the
command chain stops on a failed transfer:

```text
setenv ethact ethernet@40022000
setenv autoload no
setenv serverip 192.0.2.1
dhcp && tftpboot 0x84000000 Image && tftpboot 0x88000000 frost.dtb && tftpboot 0x88100000 rootfs.cpio && booti 0x84000000 0x88100000:${filesize} 0x88000000
```

The kernel and initramfs must support the FROST NIC and the selected root
filesystem. The software flash image contains firmware and a DTB, without a
kernel or root filesystem.

OpenSBI configures the hart from the flash DTB, and Linux reads the DTB that
`booti` passes, so build both from `dts/frost_vcu118.dts` and replace them
together. OpenSBI sets `menvcfg.CBZE` when the flash DTB lists `zicboz`. Linux
then zeroes pages with `cbo.zero`, sets `senvcfg.CBZE` for user space and
reports the extension and its 64-byte block through `riscv_hwprobe`, all from
the `zicboz` entry and `riscv,cboz-block-size` in its own DTB. A kernel DTB that
lists `zicboz` needs a flash DTB that lists it too: `cbo.zero` in supervisor
mode requires `menvcfg.CBZE`. In the same way, OpenSBI sets `menvcfg.CBCFE`
and sets `menvcfg.CBIE` to 11 when the flash DTB lists `zicbom`; without them
`cbo.clean`, `cbo.flush` and `cbo.inval` are illegal in supervisor mode.

The Linux build can compose the test initramfs with the driver modules and
startup scripts for its pinned Debian kernel, then wrap it as `rootfs.uimg`:

```bash
./scripts/frost.py run make -C sw/apps/linux_boot rootfs.uimg
```

The target uses `mkimage` from `PATH` or the built U-Boot host tools;
`MKIMAGE` selects another executable. Serve the matching kernel `Image`,
the VCU118 DTB and `rootfs.uimg` over TFTP. Use this command chain after
selecting the interface and server as above:

```text
dhcp && tftpboot 0x84000000 Image && tftpboot 0x88000000 frost.dtb && tftpboot 0x88100000 rootfs.uimg && booti 0x84000000 0x88100000 0x88000000
```

The wrapped image supplies its length to U-Boot. The composed test
initramfs includes the NIC loader; RJ-45 DHCP and SSH key setup are
described below.

The initramfs runs a key-only SSH server (password logins are disabled). Add
your public key by appending a second newc cpio archive that holds
`root/.ssh/authorized_keys` (mode 600, directory mode 700) to
`sw/apps/linux_boot/rootfs.cpio`, then wrap it again with `mkimage -A riscv -O
linux -T ramdisk -C none` and copy it to the TFTP directory. Keep the keys
outside the repository.

### 10G throughput benchmark

`nic_bench` measures what the 10G NIC and its DMA engine move with the port's
TX looped back to its RX, for example by a QSFP28 loopback module in QSFP1. It
uses both 256-entry rings with one unused slot each from bare metal (polled,
no Linux), checks every frame's length and outcome, compares one frame in 32 byte for byte, and prints
frame-byte and wire-byte rates for frame sizes from 64 to 9000 bytes, with the
NIC's error counters. The 10GBASE-R MAC rate is 10 Gb/s on the wire.

```bash
export RISCV_PREFIX=riscv64-unknown-elf-
python3 fpga/load_software/load_software.py vcu118 nic_bench
```

The full benchmark requires an external loopback and is excluded from unattended
test sequences. The `NIC_BENCH_QUICK` build uses raw MAC loopback
and a short frame plan for functional simulation.

## Debian over NFS

Both Ethernet interfaces support the shared Linux NIC driver and NFS boot.
Follow the [Debian guide](../../docs/debian_nfsroot.md) to prepare the server,
kernel, NIC module and initramfs. Use `vcu118` for the JTAG loader's board
argument. The supplied device trees enumerate QSFP1 as `eth0` and RJ-45 as
`eth1`; use `eth1` in the kernel `ip=` parameter for RJ-45 and preserve that
interface's configuration in Debian.

```bash
FROST_LINUX_KERNEL=/path/to/Image \
FROST_LINUX_INITRD=/path/to/initrd.img \
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
FROST_LINUX_IP=192.0.2.2::192.0.2.1:255.255.255.0:frost:eth1:off \
python3 fpga/load_software/load_software.py vcu118 linux_boot
```

The default MAC addresses are `02:11:22:33:44:55` for QSFP1 and
`02:11:22:33:44:56` for RJ-45. The JTAG packer's `FROST_LINUX_MAC` sets the
first address; RJ-45 uses the next last octet. Each interface needs a unique
address on its network. The Buildroot test initramfs starts DHCP on RJ-45
when it has no IPv4 address. Its SSH server accepts keys; include a
`root/.ssh/authorized_keys` file in the rootfs overlay to enable access.

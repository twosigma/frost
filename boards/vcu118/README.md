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
BRAM, a 16 KiB instruction cache, a 128 KiB data cache, and a 2 MiB L2 cache.

## Board integration

`vcu118_clock.sv` generates the CPU and CPU/4 clocks with an MMCM driven by
`SYSCLK1_300`. The build and software loader use a fixed clock configuration. The DDR controller uses its
independent reference input. The optional GTY CPU clock wrapper is outside
the active board file list.
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

`pblock_slr2` contains the FROST subsystem, clock generator, DDR subsystem,
and DDR initializer. Peripheral pins span multiple SLRs; top-level reset
and status logic is outside that hierarchy selection.

## Memory and reset

The board has two physical 80-bit DDR4 interfaces. This target uses one
interface in banks 71–73 with 64 data bits and eight ECC bits, exposing
2 GiB at CPU address `0x80000000`. The CPU bridge uses 512-bit AXI data,
31-bit region offsets and five-bit IDs. The CPU and JTAG loader share the
controller through SmartConnect. The JTAG master can also access ECC
control registers at region offset `0x80000000`; the CPU port cannot.

After calibration, `vcu118_ddr_init` writes zeros across the mapped region
using full controller words. It waits for write responses before releasing
the CPU and DDR loader from reset. An error response prevents completion.
The controller provides ECC, but this wrapper does not forward its error
telemetry to the CPU memory error unit.

## Ethernet and boot controller

The RJ-45 port uses the DP83867 PHY and an SGMII PCS/PMA connected to the
NIC's GMII adapter in full-duplex mode. Its registers occupy `0x40022000` and use APLIC source 2.
The PHY reports the negotiated copper link through SGMII. QSFP1 lane 0 uses a GTY channel and the shared 10GBASE-R MAC/PCS. Its NIC
registers occupy `0x40030000` and use APLIC source 4. Both NICs use coherent
DMA through the shared memory hierarchy.

The boot controller at `0x40023000` provides SPI transfers through STARTUPE3,
DDR status and an instruction-SRAM programming port. The initial BRAM
application loads an FSBL from flash into executable SRAM. The FSBL loads
OpenSBI, a device tree and U-Boot into DDR after checking their checksums.

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
revisions have BPI flash. The configuration flash holds the FPGA image at offset zero and the software
stages below. Each software stage has a 32-byte header with its load address,
length, entry address and CRC-32. The boot stages reject invalid bounds and
checksums. The ROM loads the FSBL at reset; the FSBL enters OpenSBI, which
starts U-Boot in supervisor mode. No JTAG software load is needed for this path.

| Stage | Flash offset | Load address | Maximum payload |
|---|---|---|---|
| FSBL | `0x03000000` | `0x00004000` | 79 KiB |
| OpenSBI | `0x03100000` | `0x80000000` | 1 MiB minus 32 bytes |
| Device tree | `0x03200000` | `0x82200000` | 128 KiB |
| U-Boot | `0x03300000` | `0x80200000` | 1 MiB minus 32 bytes |

Build the firmware and pack the software image from the repository root:

```bash
./scripts/frost.py run make -C sw/uboot firmware
python3 fpga/flash/make_flash_image.py --output /path/to/boot.bin
python3 fpga/flash/program_flash.py --boot-image /path/to/boot.bin \
  --bitstream /path/to/vcu118_frost.bit --output-dir /path/to/flash-output \
  --prepare-only
```

The U-Boot build fetches its pinned v2026.10 source revision into
`sw/uboot/build/source`. OpenSBI uses the repository's FROST configuration;
the device tree is compiled from `dts/frost_vcu118.dts`. Component overrides
on the packer are `--fsbl`, `--opensbi`, `--dtb`, and `--uboot`.

Remove `--prepare-only` to program the selected VCU118 configuration flash.
Use `--target-exact` and `--hw-server-url` to select a cable and server.
`--boot-only` replaces `--bitstream` when updating the four software
partitions. Select the board's SPI configuration boot mode for startup
from flash. The programmer erases and verifies the ranges in its generated
configuration-memory file.

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

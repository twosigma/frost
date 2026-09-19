# Debian on an NFS root

This guide boots Debian 13 (trixie, riscv64) on the Alveo X3 with Debian's own
kernel and its root filesystem on an NFSv3 export, reached over the NIC's
10GBASE-R link. The export holds the kernel (`linux-image-riscv64`), the NIC
driver built as a DKMS module from
[`linux/frost-net10g`](../linux/frost-net10g/README.md), and the initramfs that
Debian's initramfs-tools generates, which loads the driver, configures the
interface and mounts the export. `load_software.py` packs that kernel and
initramfs with this repository's OpenSBI and device tree
(`sw/apps/linux_boot`) and loads them over JTAG. The boot contract (bootargs,
`ip=` syntax, MAC address, advertised memory) is in
[`linux/README.md`](../linux/README.md), "NFS root" and "Memory map".

The steps were verified on an X3 whose bitstream was built with
`--cpu-clock-div 2`, a 150 MHz CPU clock
([`fpga/README.md`](../fpga/README.md), "Functional-validation builds"), with
Debian's 6.12.107+deb13-riscv64 kernel; the full-clock build has yet to close
timing. The examples use 192.0.2.1 for the server, 192.0.2.2 for the board and
`/srv/nfs/debian` for the export; substitute your own.

## Requirements

What the board needs from the network:

| Need | Detail |
|---|---|
| Link | An SFP+ 10GBASE-R optical module in the X3's DSFP28 cage labelled 2, with fiber to a matching optic on any 10GBASE-R partner: a server NIC port, a switch port, or a media converter whose ports both run at 10G. The NIC's GTY channel (X0Y28) is lane 1 of that cage, the lane an SFP+ module in a DSFP cage uses ([`hw/rtl/peripherals/nic/README.md`](../hw/rtl/peripherals/nic/README.md), "Integration"). |
| Address | IPv4, which the initramfs configures from the kernel's `ip=` before it mounts the root: static, or DHCP with a reservation for the board's MAC and an infinite or very long lease. The initramfs takes one lease at boot and nothing renews it, and Debian does not take DNS servers from it. |
| MAC | A locally administered address unique on the network (`FROST_LINUX_MAC`); every board defaults to `02:11:22:33:44:55`. |
| NFS server | Linux with `nfs-kernel-server` serving NFSv3 over TCP. The initramfs mounts with `vers=3,tcp,hard`, and its `nfsmount` (klibc) speaks only NFSv2 and NFSv3, so an NFSv4-only server will not work. One riscv64 root tree per board, exported read-write to that board's address with `no_root_squash`. |
| Firewall | TCP from the board to the server's rpcbind (111), mountd and nfsd (2049). mountd's port is dynamic unless `port=` is set under `[mountd]` in `/etc/nfs.conf`. |
| apt (optional) | DNS, a route to a Debian mirror or an apt proxy, and a time source: the board has no RTC. |

Also needed: a terminal on the board's UART at 115200 8N1, and a host with
Vivado that programs the X3 and runs `load_software.py`
([`fpga/README.md`](../fpga/README.md)) with `make`, `dtc` and the
`riscv-none-elf-` toolchain. OpenSBI comes from this repository's Buildroot
build, so that host's checkout needs the `linux/buildroot` submodule and the
Buildroot images, built once
([`linux/buildroot-external/README.md`](../linux/buildroot-external/README.md),
"Build"); without the images, the loader starts that build itself. The loader
reads Debian's kernel and initramfs by path (step 5).

## 1. Build the root filesystem

On the server (Debian or Ubuntu), as root. mmdebstrap, and `chroot` after it,
run the riscv64 programs under qemu user emulation registered through binfmt.
Every path below goes through `${R:?}`, so a command refuses to run, rather
than touch the server's own files, if `R` is unset.

```bash
apt install nfs-kernel-server mmdebstrap qemu-user qemu-user-binfmt
# With QEMU older than 9.1 (Debian 12, Ubuntu 24.04), install qemu-user-static
# in place of qemu-user and qemu-user-binfmt. A server that is not Debian
# itself (Ubuntu, say) also needs debian-archive-keyring.
R=/srv/nfs/debian
mmdebstrap --arch=riscv64 \
  --include=openssh-server,ca-certificates,dbus,libpam-systemd,systemd-timesyncd \
  trixie ${R:?} http://deb.debian.org/debian

# Debian's kernel, its headers and DKMS.
chroot ${R:?} apt-get update
chroot ${R:?} apt-get install -y --no-install-recommends \
  linux-image-riscv64 linux-headers-riscv64 dkms
```

mmdebstrap takes a few minutes and leaves a tree of about 200 MB; the kernel,
its headers and the compiler DKMS uses bring it to about 1.1 GB. Naming the
mirror leaves only `trixie main` in the tree's apt sources; without it,
mmdebstrap also adds `trixie-updates` and `trixie-security`. The chroot's apt
resolves names through the tree's `/etc/resolv.conf`, which is still the
server's copy until step 2 replaces it. Installing the kernel builds an
initramfs without the NIC driver, which step 3 rebuilds, and prints
`W: No zstd in /usr/bin:/sbin:/bin, using gzip`: zstd is only a
recommendation, and the kernel reads gzip as well.

## 2. Configure the tree

Edit the tree as root on the server; with `no_root_squash` the board sees
those files as root's.

```bash
R=/srv/nfs/debian

# SSH: root logs in with a key only.
install -d -m 700 ${R:?}/root/.ssh
install -m 600 /path/to/key.pub ${R:?}/root/.ssh/authorized_keys
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
  > ${R:?}/etc/ssh/sshd_config.d/keys-only.conf

# Name. mmdebstrap copied the server's /etc/hostname and /etc/resolv.conf.
echo frost > ${R:?}/etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\tfrost\n' > ${R:?}/etc/hosts

# Keep the kernel's interface name, eth0: mask udev's predictable naming.
ln -sf /dev/null ${R:?}/etc/systemd/network/99-default.link

# A resolver the board can reach; the copy may be a local stub (127.0.0.53).
rm -f ${R:?}/etc/resolv.conf
echo 'nameserver <resolver-ip>' > ${R:?}/etc/resolv.conf

# A time source the board can reach. It has no RTC and boots at systemd's build
# date, and apt rejects current repository metadata until the clock is set.
mkdir -p ${R:?}/etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=<ntp-server>\n' > ${R:?}/etc/systemd/timesyncd.conf.d/ntp.conf

# Optional: console autologin as root, for debugging.
mkdir -p ${R:?}/etc/systemd/system/serial-getty@ttyS0.service.d
cat > ${R:?}/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noreset --noclear --keep-baud 115200,57600,38400,9600 - ${TERM}
EOF
```

- The initramfs configures eth0 and mounts the root over it before Debian
  starts, so renaming or reconfiguring eth0 cuts the board off from its root.
  Leave eth0 out of `/etc/network/interfaces` and `interfaces.d`, and enable
  no DHCP client, systemd-networkd or NetworkManager for it. The initramfs
  that step 3 builds copies the `99-default.link` mask, so make the mask
  first.
- `/etc/fstab` needs no root entry; the initramfs mounts `/`.
- root has no usable password: log in over SSH, or use the autologin above
  where the console getty starts; at 150 MHz it does not (see
  Troubleshooting).

## 3. Build the NIC driver into the initramfs

Debian's kernel has no FROST driver and mounts an NFS root only from its
initramfs, so the driver is built as a DKMS module and listed for the
initramfs, as [`linux/frost-net10g/README.md`](../linux/frost-net10g/README.md)
describes ("As a DKMS module on Debian"). In the chroot, `uname -r` is the
server's kernel, so every command below names the tree's kernel with `-k`.
Run them from the top of a checkout of this repository on the server, after
step 2:

```bash
R=/srv/nfs/debian
K=$(ls ${R:?}/lib/modules)   # the tree's kernel version: 6.12.107+deb13-riscv64 here
ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' linux/frost-net10g/dkms.conf)
cp -r linux/frost-net10g ${R:?}/tmp/
chroot ${R:?} dkms add /tmp/frost-net10g   # copies it to /usr/src/frost-net10g-$ver
chroot ${R:?} dkms build "frost-net10g/$ver" -k "$K"
chroot ${R:?} dkms install "frost-net10g/$ver" -k "$K"
rm -r ${R:?}/tmp/frost-net10g

# initramfs-tools' default MODULES=most leaves DKMS modules out: list it.
echo frost_net10g >> ${R:?}/etc/initramfs-tools/modules
chroot ${R:?} update-initramfs -u -k "$K"
chroot ${R:?} lsinitramfs "/boot/initrd.img-$K" | grep frost_net10g
```

A fresh tree has one kernel in `/lib/modules`; with more, set `K` to the one
to boot. The last command must print
`usr/lib/modules/<version>/updates/dkms/frost_net10g.ko.xz`. Nothing else in
`/etc/initramfs-tools` changes: `initramfs.conf` keeps Debian's defaults, whose
`MODULES=most` carries the NFS client, and the bootargs that step 5 packs
select the NFS boot, the export and the interface.

## 4. Export it

Give the server an address on the board's link (192.0.2.1/24 here), then:

```bash
echo '/srv/nfs/debian 192.0.2.2(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
exportfs -ra
rpcinfo -p | grep -w nfs     # must list version 3 over tcp
showmount -e localhost       # lists the export
```

If version 3 is missing, set `vers3=y` under `[nfsd]` in `/etc/nfs.conf` and
restart `nfs-server`.

## 5. Boot

Build and program the half-clock bitstream, open the UART console, and load
the tree's kernel and initramfs:

```bash
./fpga/build/build.py x3 --cpu-clock-div 2
./fpga/program_bitstream/program_bitstream.py x3
K=6.12.107+deb13-riscv64   # step 3's K, the version in the tree's /boot
FROST_CPU_CLK_HZ=150000000 \
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
FROST_LINUX_IP=192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off \
FROST_LINUX_KERNEL=/srv/nfs/debian/boot/vmlinux-$K \
FROST_LINUX_INITRD=/srv/nfs/debian/boot/initrd.img-$K \
  ./fpga/load_software/load_software.py x3 linux_boot
```

- `FROST_CPU_CLK_HZ` must match the programmed bitstream's CPU clock; unset,
  it is the rated 300 MHz.
- `FROST_LINUX_IP` is the `ip=` that the initramfs's `ipconfig` reads, in the
  kernel's syntax, and `dhcp` when unset. Its gateway field (192.0.2.1 here)
  is the board's default route, which step 7 uses. `FROST_LINUX_MAC=<board-mac>`
  sets the NIC's address when other FROST boards share the network.
- `FROST_LINUX_KERNEL` and `FROST_LINUX_INITRD` are absolute paths, on the host
  that runs the loader, to the kernel and initramfs of one version; if that
  host is not the server, copy both files to it. The packer takes the kernel
  as an uncompressed Linux `Image`, which it recognizes by its header, and
  decompresses nothing. Debian installs its riscv64 kernel that way, as
  `/boot/vmlinux-<version>`; the tree's `/vmlinuz` links to it, and `file`
  reports `Linux kernel RISC-V boot executable Image, little-endian`. The
  initramfs is packed as it is and the kernel unpacks it, so initramfs-tools'
  output needs no conversion. `file` reports it as an ASCII cpio archive
  because its first segment holds the already-compressed modules uncompressed;
  the rest is compressed.
- Before loading, the packer prints a summary that must read `Linux Image`,
  not `raw payload`, and `memory 0x40000000 B`. With this kernel it puts the
  DTB at `0x82200000` and the initramfs at `0x82210000`. The image is about
  78 MB, and the load takes several minutes.
- Leave the `FROST_LINUX_*` variables unset for the hardware regression, which
  boots the Buildroot test image.

At 150 MHz the console shows the following, and `systemd-analyze` then
reports about 2 min 21 s in the kernel, initramfs included, and 3 min 20 s in
userspace:

| Kernel time | Console |
|---|---|
| ~23 s | `Freeing initrd memory:` |
| ~40 s | `Run /init as init process`, then `Loading, please wait...` |
| ~79 s | `frost_net10g 40030000.ethernet eth0: FROST net10g, IRQ <n>, MAC <board-mac>`, after two lines saying that the module taints the kernel |
| ~85 s | `IP-Config: eth0 complete:` and the address |
| ~110 s | `Begin: Running /scripts/nfs-bottom ... done.`, with no `Retrying nfs mount` lines before it |
| ~148 s | the systemd banner, then `Welcome to Debian GNU/Linux 13 (trixie)!` |
| ~4 min 45 s | `[ TIME ] Timed out waiting for device dev-ttyS0.device`: the console gets no login (see Troubleshooting) |
| ~5 min 40 s | `Reached target multi-user.target`; SSH answers |

Two other messages look like errors but are expected. Early on, the kernel
lists `boot=nfs`, `nfsroot=` and `ip=` as
`Unknown kernel command line parameters`: the initramfs reads them. With a
static address, the initramfs prints
`no search or nameservers found in /run/net-eth0.conf`.

## 6. Verify

```bash
# Optional, on a client that can read the tree: pin the board's host key.
k=$(cut -d' ' -f1,2 /srv/nfs/debian/etc/ssh/ssh_host_ed25519_key.pub) &&
  echo "192.0.2.2 $k" >> ~/.ssh/known_hosts

ssh root@192.0.2.2
uname -r                       # the packed kernel: 6.12.107+deb13-riscv64 here
lsmod | grep frost_net10g      # the NIC driver, loaded by the initramfs
findmnt /                      # 192.0.2.1:/srv/nfs/debian, nfs, vers=3 ... hard,nolock,proto=tcp
systemctl is-system-running    # running; systemctl --failed lists any failed unit
free -m                        # ~940 MiB of the X3's 1 GiB
```

## 7. apt

One way to route the board to a mirror is NAT on the server, its gateway in
the `ip=` above (needs `iptables`):

```bash
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-board-nat.conf
sysctl -p /etc/sysctl.d/90-board-nat.conf
cat > /etc/systemd/system/board-nat.service <<'EOF'
[Unit]
Description=NAT for the board's subnet

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables -t nat -A POSTROUTING -s 192.0.2.0/24 ! -d 192.0.2.0/24 -j MASQUERADE
ExecStop=/usr/sbin/iptables -t nat -D POSTROUTING -s 192.0.2.0/24 ! -d 192.0.2.0/24 -j MASQUERADE

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now board-nat.service
```

With `ip_forward` set, the server routes for any host that points at it
unless its `FORWARD` policy is `DROP` (Docker sets that), the safer choice on
a shared network. Under `DROP`, add `ExecStart=` rules for the board's
traffic and its replies, each deleted by a matching `ExecStop=` (`-D`) line:
`iptables -I FORWARD -s 192.0.2.0/24 -j ACCEPT` and
`iptables -I FORWARD -d 192.0.2.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`.
An apt proxy replaces NAT: `Acquire::http::Proxy "http://<proxy>:<port>/";`
in `/srv/nfs/debian/etc/apt/apt.conf.d/90proxy`.

If no time source is reachable yet, set the clock once from a host whose
clock is right, then update; at 150 MHz each apt step takes minutes:

```bash
ssh root@192.0.2.2 date -s @$(date +%s)
ssh root@192.0.2.2 'apt update && apt install -y <package>'
```

A kernel update takes effect only after a new load (see "Operation").

## Operation

- One tree per board. Never export a tree read-write to two boards: the
  initramfs mounts with `nolock`, so file locks are local to each board.
- The root is a `hard` mount. If the server or the link goes away, processes
  that touch the root block and resume when it returns; a server restart is
  tolerated.
- `no_root_squash` gives the board's root full ownership of the tree; export
  it to the board's address only.
- Kernel updates. apt installs a new kernel next to the running one, and when
  its headers come in the same run, as `linux-headers-riscv64` arranges, DKMS
  builds `frost_net10g` for it before `update-initramfs` builds its initramfs
  ([`linux/frost-net10g/README.md`](../linux/frost-net10g/README.md#an-nfs-root-needs-the-module-in-the-initramfs)
  covers the other case). Check the new initramfs with `lsinitramfs` as in
  step 3. The board boots whatever the last load packed, so load again with
  the new version's `vmlinux` and `initrd.img` (step 5). Until then keep the
  running kernel installed: its `/lib/modules/<version>` in the tree supplies
  every module loaded after the initramfs. `apt autoremove`, and
  `apt full-upgrade`, which also removes unused kernels, keep the running
  kernel when they run on the board; in a chroot on the server, `uname -r`
  names the server's kernel instead.
- Manage the tree's packages from one place at a time: apt on the board while
  it runs from the tree, the chroot only while the board is stopped. Two
  package managers writing one dpkg database corrupt it.
- The SoC has no software reset or power-off, so `reboot` and `poweroff` leave
  the board stopped; load again to boot. Run `poweroff` (or `sync`) before
  reloading so the board's writes reach the server.

## Troubleshooting

| Console shows | Cause and fix |
|---|---|
| `Begin: Waiting up to 180 secs for eth0 to become available ... Failure: Network device did not appear in time` (`for any network device` with DHCP), then `ipconfig:` errors such as `eth0: SIOCGIFINDEX: No such device` | The initramfs has no NIC driver for the running kernel, and the `frost_net10g ... eth0: FROST net10g` line is missing. The initramfs's `modprobe` is quiet, so run step 3's `lsinitramfs` check on the packed initramfs: it must list `frost_net10g.ko.xz` under `usr/lib/modules/<version>`, for the version on the console's `Linux version` line. Nothing listed means the module was not listed in `/etc/initramfs-tools/modules` or DKMS never built it for that kernel (`dkms status` in the chroot): redo step 3. Another version means `FROST_LINUX_KERNEL` and `FROST_LINUX_INITRD` name different versions. |
| `IP-Config: no response after N secs - giving up`, repeated | With DHCP: no answer. Fix the DHCP server or the reservation, check that the partner port has a link, or set a static `FROST_LINUX_IP`. |
| After `IP-Config: eth0 complete`, errors such as `connect: No route to host` or `NFS over TCP not available from 192.0.2.1`, and a `Begin: Retrying nfs mount ...` line per attempt | The board cannot reach the server's rpcbind, mountd or nfsd over TCP: no link (an SFP+ 10GBASE-R module in the DSFP28 cage labelled 2, fiber from each end's TX to the other's RX, and the partner port up at 10GBASE-R), a wrong server address in `FROST_LINUX_NFSROOT`, or the firewall. `NFS over TCP not available` with no error line before it means rpcbind answered but lists no NFSv3 over TCP (step 4's `rpcinfo` check). |
| `mount call failed - server replied: Permission denied.`, then `Begin: Retrying nfs mount ...` | The server refused the mount: check the export's path and client address (`exportfs -v`). |
| `Target filesystem doesn't have requested /sbin/init.`, `No init found. Try passing init= bootarg.` and an `(initramfs)` prompt | After mount errors, the initramfs gave up on the mount (the rows above). With none, the export mounted but is not a complete riscv64 root: a wrong path, an empty directory, or an interrupted mmdebstrap. |
| Permission errors from systemd and services after the root mounts | The export squashes root: add `no_root_squash` and run `exportfs -ra`. |
| `nfs: server 192.0.2.1 not responding, still trying` | The server or the link is down. The hard mount waits and logs `nfs: server 192.0.2.1 OK` when it returns. |
| systemd stalls, or the root stops responding once userspace starts | Something renamed or reconfigured eth0: check the `99-default.link` mask and that no `interfaces` stanza, DHCP client, systemd-networkd or NetworkManager touches eth0. |
| `[ TIME ] Timed out waiting for device dev-ttyS0.device - /dev/ttyS0.`, then `[DEPEND] Dependency failed for serial-getty…S0.service - Serial Getty on ttyS0.` | Expected at 150 MHz: udev reaches ttyS0 only after systemd has stopped waiting for the device (`DefaultDeviceTimeoutSec`, 90 s by default), so the console has no login prompt. SSH is unaffected. |
| `eth0: re-enabled RX after a MAC domain reset (N)` | Informational: the transceiver reset its receiver while the link was down, and the driver enabled receive again when the carrier returned. |
| apt: `Release file for ... is not valid yet` | The clock is behind. Fix the time source, or set the date as in step 7. |
| apt: `Temporary failure resolving ...` | No DNS: the tree's `/etc/resolv.conf`, or the board's route to that resolver. |
| On the board, `modprobe` fails with `Module ... not found in directory /lib/modules/<version>` | `ls /lib/modules` must list `uname -r`. If it does not, the running kernel's package was removed while the board still boots it, by `apt autoremove` in a chroot for example: reinstall that package, or load an installed kernel (step 5). If it does, the module is not built for this kernel; for `frost_net10g`, check `dkms status` and install it as in step 3. |
| ssh: `Permission denied (publickey)` | `/root/.ssh` must be mode 700 and `authorized_keys` 600, both owned by root, holding the client's public key. |

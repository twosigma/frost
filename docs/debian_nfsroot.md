# Debian on an NFS root

This guide boots Debian 13 (trixie, riscv64) on the Alveo X3 with its root
filesystem on an NFSv3 export, reached over the NIC's 10GBASE-R link. The
kernel (Linux 6.18.7 with the `frost,net10g` driver), OpenSBI and the
device tree come from this repository's Buildroot-based build, which
`sw/apps/linux_boot` packs when `load_software.py` loads it; Debian supplies
only the root filesystem, so no Debian kernel or installer is involved. The
Buildroot initramfs stays the default `linux_boot` image, the self-contained
test image that the X3 hardware regression and CI's QEMU job boot with no
server, and `FROST_LINUX_NFSROOT` switches the same kernel to the Debian root.
The boot contract (bootargs, `ip=` syntax, MAC address, advertised memory) is
in [`linux/README.md`](../linux/README.md), "NFS root" and "Memory map".

The steps were verified on an X3 whose bitstream was built with
`--cpu-clock-div 2`, a 150 MHz CPU clock
([`fpga/README.md`](../fpga/README.md), "Functional-validation builds"); the
full-clock build has yet to close timing. The examples use 192.0.2.1 for the
server, 192.0.2.2 for the board and `/srv/nfs/debian` for the export;
substitute your own.

## Requirements

What the board needs from the network:

| Need | Detail |
|---|---|
| Link | An SFP+ 10GBASE-R optical module in the X3's DSFP28 cage labelled 2, with fiber to a matching optic on any 10GBASE-R partner: a server NIC port, a switch port, or a media converter whose ports both run at 10G. The NIC's GTY channel (X0Y28) is lane 1 of that cage, the lane an SFP+ module in a DSFP cage uses ([`hw/rtl/peripherals/nic/README.md`](../hw/rtl/peripherals/nic/README.md), "Integration"). |
| Address | IPv4; the kernel has no IPv6. Static through the kernel's `ip=`, or DHCP with a reservation for the board's MAC and an infinite or very long lease: the kernel takes one lease at boot and never renews it, and Debian does not take DNS servers from it. |
| MAC | A locally administered address unique on the network (`FROST_LINUX_MAC`); every board defaults to `02:11:22:33:44:55`. |
| NFS server | Linux with `nfs-kernel-server` serving NFSv3 over TCP. The kernel mounts with `vers=3,tcp,hard` and has no NFSv4 client, so an NFSv4-only server will not work. One riscv64 root tree per board, exported read-write to that board's address with `no_root_squash`. |
| Firewall | TCP from the board to the server's rpcbind (111), mountd and nfsd (2049). mountd's port is dynamic unless `port=` is set under `[mountd]` in `/etc/nfs.conf`. |
| apt (optional) | DNS, a route to a Debian mirror or an apt proxy, and a time source: the board has no RTC. |

Also needed: a terminal on the board's UART at 115200 8N1, and a host with
Vivado that programs the X3 and runs `load_software.py`
([`fpga/README.md`](../fpga/README.md)) with `make`, `dtc` and the
`riscv-none-elf-` toolchain. Its checkout needs the `linux/buildroot`
submodule and the kernel images, built once
([`linux/buildroot-external/README.md`](../linux/buildroot-external/README.md),
"Build"); without the images, the loader starts that build itself.

## 1. Build the root filesystem

On the server (Debian or Ubuntu), as root. mmdebstrap runs the riscv64
package scripts under qemu user emulation registered through binfmt:

```bash
apt install nfs-kernel-server mmdebstrap qemu-user qemu-user-binfmt
# With QEMU older than 9.1 (Debian 12, Ubuntu 24.04), install qemu-user-static
# in place of qemu-user and qemu-user-binfmt. A server that is not Debian
# itself (Ubuntu, say) also needs debian-archive-keyring.
mmdebstrap --arch=riscv64 \
  --include=openssh-server,ca-certificates,dbus,libpam-systemd,systemd-timesyncd \
  trixie /srv/nfs/debian http://deb.debian.org/debian
```

The tree is about 200 MB and takes a few minutes. Naming the mirror leaves
only `trixie main` in the tree's apt sources; without it, mmdebstrap also adds
`trixie-updates` and `trixie-security`.

## 2. Configure the tree

Edit the tree as root on the server; with `no_root_squash` the board sees
those files as root's. Every path below goes through `${R:?}`, so a command
refuses to run, rather than edit the server's own `/etc`, if `R` is unset.

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

- The kernel configures eth0 and mounts the root over it before Debian
  starts, so renaming or reconfiguring eth0 cuts the board off from its root.
  Leave eth0 out of `/etc/network/interfaces` and `interfaces.d`, and enable
  no DHCP client, systemd-networkd or NetworkManager for it.
- `/etc/fstab` needs no root entry; the kernel mounts `/`.
- root has no usable password: log in over SSH, or use the autologin above.

## 3. Export it

Give the server an address on the board's link (192.0.2.1/24 here), then:

```bash
echo '/srv/nfs/debian 192.0.2.2(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
exportfs -ra
rpcinfo -p | grep -w nfs     # must list version 3 over tcp
showmount -e localhost       # lists the export
```

If version 3 is missing, set `vers3=y` under `[nfsd]` in `/etc/nfs.conf` and
restart `nfs-server`.

## 4. Boot

Build and program the half-clock bitstream, open the UART console, and load:

```bash
./fpga/build/build.py x3 --cpu-clock-div 2
./fpga/program_bitstream/program_bitstream.py x3
FROST_CPU_CLK_HZ=150000000 \
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
FROST_LINUX_IP=192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off \
  ./fpga/load_software/load_software.py x3 linux_boot
```

- `FROST_CPU_CLK_HZ` must match the programmed bitstream's CPU clock; unset,
  it is the rated 300 MHz.
- `FROST_LINUX_IP` is the kernel's `ip=`, `dhcp` when unset. Its gateway field
  (192.0.2.1 here) is the board's default route, which step 6 uses.

At 150 MHz the console shows the following, and `systemd-analyze` then
reports about 4.2 s in the kernel and 3 min 16 s in userspace:

| When | Console |
|---|---|
| ~1.2 s (kernel time) | `IP-Config: Complete:` |
| ~1.4 s | `VFS: Mounted root (nfs filesystem)` |
| ~5 s | the systemd banner, then `Welcome to Debian GNU/Linux 13 (trixie)!` |
| ~3.5 min after the load | `frost login:` |

## 5. Verify

```bash
# Optional, on a client that can read the tree: pin the board's host key.
k=$(cut -d' ' -f1,2 /srv/nfs/debian/etc/ssh/ssh_host_ed25519_key.pub) &&
  echo "192.0.2.2 $k" >> ~/.ssh/known_hosts

ssh root@192.0.2.2
systemctl is-system-running    # running; systemctl --failed lists any failed unit
findmnt /                      # 192.0.2.1:/srv/nfs/debian, nfs, vers=3 ... hard
free -m                        # ~994 MiB of the X3's 1 GiB, ~43 MiB used after boot
```

## 6. apt

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

## Operation

- One tree per board. Never export a tree read-write to two boards: nfsroot
  mounts with `nolock`, so file locks are local to each board.
- The root is a `hard` mount. If the server or the link goes away, processes
  that touch the root block and resume when it returns; a server restart is
  tolerated.
- `no_root_squash` gives the board's root full ownership of the tree; export
  it to the board's address only.
- The kernel is minimal ([`linux/README.md`](../linux/README.md), "Kernel
  configuration contract"): no modules, netfilter, FUSE, overlayfs or user
  namespaces, so packages that need them do not work on the board.
- The SoC has no software reset or power-off, so `reboot` and `poweroff` leave
  the board stopped; load again to boot. Run `poweroff` (or `sync`) before
  reloading so the board's writes reach the server.
- Throughput at 150 MHz, as an expectation: raw TCP receive about 11.6 MB/s;
  NFS reads about 3.6 MB/s and writes about 2.0 MB/s with nfsroot's default
  4 KiB `rsize` and `wsize`.

## Troubleshooting

| Console shows | Cause and fix |
|---|---|
| `Waiting up to N more seconds for network.` | No carrier. After 120 s a static `ip=` goes on to fail the mount, and DHCP waits again on every retry, so fix the link first: an SFP+ 10GBASE-R module in the DSFP28 cage labelled 2, fiber from each end's TX to the other's RX, and the partner port up at 10GBASE-R. |
| `Sending DHCP requests ... timed out!`, then `IP-Config: Retrying forever (NFS root)...` | With no `Waiting up to` lines before it, no DHCP answer: fix the DHCP server or the reservation, or set a static `FROST_LINUX_IP`. |
| `VFS: Unable to mount root fs via NFS.`, then `Kernel panic - not syncing: No working init found.` | With no `Waiting up to` lines before it, the server refused or did not answer: check the export's path and client address (`exportfs -v`), NFSv3 over TCP (step 3), and the firewall. |
| `VFS: Mounted root (nfs filesystem)`, then `No working init found` or `/sbin/init exists but couldn't execute it` | The export is not a complete riscv64 root: a wrong path, an empty directory, or an interrupted mmdebstrap. |
| Permission errors from systemd and services after the root mounts | The export squashes root: add `no_root_squash` and run `exportfs -ra`. |
| `nfs: server 192.0.2.1 not responding, still trying` | The server or the link is down. The hard mount waits and logs `nfs: server 192.0.2.1 OK` when it returns. |
| systemd stalls, or the root stops responding once userspace starts | Something renamed or reconfigured eth0: check the `99-default.link` mask and that no `interfaces` stanza, DHCP client, systemd-networkd or NetworkManager touches eth0. |
| `eth0: re-enabled RX after a MAC domain reset (N)` | Informational: the transceiver reset its receiver while the link was down, and the driver enabled receive again when the carrier returned. |
| apt: `Release file for ... is not valid yet` | The clock is behind. Fix the time source, or set the date as in step 6. |
| apt: `Temporary failure resolving ...` | No DNS: the tree's `/etc/resolv.conf`, or the board's route to that resolver. |
| ssh: `Permission denied (publickey)` | `/root/.ssh` must be mode 700 and `authorized_keys` 600, both owned by root, holding the client's public key. |

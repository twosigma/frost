# Debian on an NFS root

Boot Debian 13 (trixie, riscv64) on the Alveo X3 from an NFSv3 root over
10GBASE-R. Debian's initramfs loads the FROST NIC module and mounts the export;
the JTAG loader packs it with the kernel, OpenSBI, and device tree.
See the [Linux boot contract](../linux/README.md).

Examples use server `192.0.2.1`, board `192.0.2.2`, and export
`/srv/nfs/debian`; substitute your own values. The loader defaults to the
322.265625 MHz CPU clock. Divided-clock builds take longer to boot.

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

The loading host needs Vivado, Python, Make, dtc, the
[native RISC-V compiler](tooling.md#shared-risc-v-toolchain), and access to the
kernel/initramfs files. Open a UART terminal at 115200 baud, 8N1.
The loader builds missing [firmware/test-image components](../linux/buildroot-external/README.md#build)
automatically.

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

The tree needs about 1.1 GB including kernel headers and build tools.
The installed kernel may differ from the repository pin; always load its
matching initramfs. Hardware regression requires the pinned release.
The explicit mirror selects `trixie main`; configure updates/security sources
as needed. The chroot initially uses the server's copied resolver settings.

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

# Console root autologin, required by hardware regression.
mkdir -p ${R:?}/etc/systemd/system/serial-getty@ttyS0.service.d
cat > ${R:?}/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noreset --noclear --keep-baud 115200,57600,38400,9600 - ${TERM}
EOF

# Allow slower bitstreams enough time for udev to create ttyS0.
mkdir -p ${R:?}/etc/systemd/system.conf.d
cat > ${R:?}/etc/systemd/system.conf.d/device-timeout.conf <<'EOF'
[Manager]
DefaultDeviceTimeoutSec=300s
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
  on the console.

## 3. Build the NIC driver into the initramfs

Build the [DKMS module](../linux/frost-net10g/README.md) and include it in
the initramfs. Run from the repository root on the server. Explicit `-k`
selects the target kernel because chroot's `uname -r` reports the host kernel.

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

With multiple kernels installed, set `K` explicitly. `lsinitramfs` must show
`frost_net10g.ko` (possibly compressed) under that version's module directory.
Keep `MODULES=most` to include the NFS client.

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

Use a separate filesystem or size-limited image for the export so filling the
board's root cannot fill the server's root. For a file-backed filesystem, with
the board stopped:

```bash
truncate -s 20G /srv/nfs/debian.img          # sparse: no space used yet
mkfs.ext4 -q -F -L frost-root /srv/nfs/debian.img
# with the board stopped, move the tree into it and mount it in its place
mkdir /mnt/img && mount -o loop /srv/nfs/debian.img /mnt/img
cp -a /srv/nfs/debian/. /mnt/img/ && umount /mnt/img
mv /srv/nfs/debian /srv/nfs/debian.old && mkdir /srv/nfs/debian
echo '/srv/nfs/debian.img /srv/nfs/debian ext4 loop,nofail,defaults 0 2' >> /etc/fstab
mount /srv/nfs/debian && exportfs -ra
```

`nofail` keeps a missing image from blocking the server's own boot. Reboot the
board afterwards: the server identifies an exported filesystem internally, and
that identity changes with the swap.

## 5. Boot

Build and program the bitstream, open the UART console, and load the tree's
kernel and initramfs:

```bash
./fpga/build/build.py x3
./fpga/program_bitstream/program_bitstream.py x3
K=6.12.107+deb13-riscv64   # step 3's K, the version in the tree's /boot
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
FROST_LINUX_IP=192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off \
FROST_LINUX_KERNEL=/srv/nfs/debian/boot/vmlinux-$K \
FROST_LINUX_INITRD=/srv/nfs/debian/boot/initrd.img-$K \
  ./fpga/load_software/load_software.py x3 linux_boot
```

- For a half-rate bitstream, set `FROST_CPU_CLK_HZ=161132812`.
- Use a unique `FROST_LINUX_MAC` for each board.
- `FROST_LINUX_IP` uses the kernel `ip=` syntax; unset defaults to DHCP.
- Kernel and initramfs paths must be absolute and readable on the loading host.
  Debian's `vmlinux-<version>` is an uncompressed RISC-V `Image`; no conversion
  is needed. The kernel unpacks the initramfs.
- Check the packer's summary: `Linux Image` and `memory 0x40000000 B` for X3.
  Loading the image takes several minutes.

Allow about three minutes after loading for multi-user startup.
The console should show the NIC, `IP-Config: eth0 complete`, the NFS mount,
and Debian/systemd startup. Divided-clock builds take roughly proportionally
longer. `Unknown kernel command line parameters` for `boot=nfs`, `nfsroot`,
and `ip` is expected: the initramfs consumes them. Static IP setup can also
report missing search/nameserver values; configure DNS in the root tree.

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

## Hardware regression

The Linux stage boots this Debian root. Configure the export and board
address in the Git-ignored `fpga/site.env`:

```
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian
FROST_LINUX_IP=192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off
```

The whole regression, or the stage alone, is then the command by itself:

```bash
./fpga/hw_regression.py --board x3 linux_boot
```

The stage derives the rest: the kernel is the pinned release's image that
`linux/debian_kernel.py` computes, and the initramfs is that release's
`boot/initrd.img-<version>` inside the export above. `FROST_LINUX_KERNEL` and
`FROST_LINUX_INITRD` override either, and the two site values can be given in
the environment instead, which wins over the file.

What the stage needs beyond a root that boots by hand:

| Need | Why, and where it comes from |
|---|---|
| The export directory on the host that runs the loader | The stage reads the tree's console configuration and installs into it. With the server elsewhere, mount the export on that host at the same path, or run the regression on the server. |
| A console autologin | The stage logs in over the UART, and this root's root has no usable password: the `serial-getty@ttyS0` drop-in from step 2 is required, not optional. |
| `usr/local/bin` writable by the user that runs the regression | The stage cross-compiles `frost_stress` and `frost_nettest` from `linux/buildroot-external/package/frost-stress` and installs them there before each run, so the programs it types are this checkout's. The tree belongs to root, so give that one directory away: `install -d -m 755 -o <user> /srv/nfs/debian/usr/local/bin`. |
| A riscv64 Linux cross compiler on that host | For those two programs, statically linked. Debian's `gcc-riscv64-linux-gnu`, a `FROST_LINUX_CROSS_COMPILE` prefix, or the toolchain Buildroot's own build leaves in `linux/build-mmu/host/bin`. |
| The pinned kernel version | The stage requires that release's banner, and its preflight reads the release out of the packed `Image` first. Keep the root on the version `linux/debian_kernel.py` pins, with `frost_net10g` in its initramfs for that version (step 3). |
| NFSv3 over TCP | Step 4. The preflight makes an NFSv3 NULL call to the server before any stage runs. |
| A server on the board's own subnet | `frost_nettest` takes the root's interface down. The kernel brings that interface's connected route back by itself, but not a route through the gateway, so a server reached through one may leave the root stranded. The preflight says which case this is, and the stage checks that the root came back. |
| The initramfs rebuilt after a driver change | The stage boots the initramfs it is given, and the driver in it is the DKMS build made in step 3. After editing `linux/frost-net10g`, redo step 3 -- otherwise the run exercises the module built last time. |

Preflight runs before any stage and reports setup failures as `ENV_FAIL`.
`--linux-timeout` defaults to 1200 seconds for loading, booting, systemd, and
tests; increase it for slower bitstreams.

The stage checks NFS and systemd, runs stress and counter tests, then runs
`frost_nettest` from executable `/dev/shm` because loopback temporarily removes
the root's network link. It disables IPv6 during the test, restores the MTU,
interface flags, and IPv6 setting, then requires a bounded write-and-sync to
NFS to prove recovery. The test tools remain in `/usr/local/bin`.
Reload the image for the next boot; the SoC has no software reset.

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
clock is right, then update. Each apt step takes minutes: the work is the
board's, and the root filesystem is on the far side of the link:

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

| Symptom | Check |
|---------|-------|
| eth0 never appears; `SIOCGIFINDEX: No such device` | Run `lsinitramfs` and `dkms status`: the loaded initramfs needs `frost_net10g` for the loaded kernel. Rebuild as in step 3. |
| DHCP `IP-Config: no response` | Check link and DHCP reservation, or select a static IP. |
| Repeated NFS mount retries; `No route to host` / `NFS over TCP not available` | Check the 10G optical link, server address, firewall, and `rpcinfo -p` for NFSv3/TCP. |
| NFS `Permission denied` | Check export path/client address with `exportfs -v`. |
| No `/sbin/init` after mount attempts | Resolve mount errors first; otherwise check that the export is a complete riscv64 root. |
| Service permission errors after mounting | Set `no_root_squash` and re-export. |
| `nfs: server ... not responding` | Restore the server/link; the hard mount resumes when it returns. |
| Root stops responding after userspace starts | Prevent renaming/reconfiguration of eth0; check step 2's mask and network managers. |
| ttyS0 device timeout; no console login | Increase `DefaultDeviceTimeoutSec` as in step 2; SSH can still work. |
| `eth0: re-enabled RX after a MAC domain reset` | Informational link-recovery message. |
| apt metadata is not valid yet | Set the clock or fix NTP. |
| apt cannot resolve names | Check `/etc/resolv.conf` and the route to its resolver. |
| Module missing under `/lib/modules/<version>` | Keep the running kernel installed; install its module or reload an installed kernel. Chroot autoremove sees the host kernel. |
| SSH public-key rejection | Check key contents, root ownership, mode 700 on `.ssh`, and mode 600 on `authorized_keys`. |
| Regression waits at login / `Login incorrect` | Add the console autologin drop-in from step 2. |
| Regression reports degraded systemd | Inspect `systemctl --failed` and `systemctl status <unit>`. |
| `/dev/shm/frost_nettest: Permission denied` | Remove `noexec` from the tmpfs used by the regression. |
| Regression `ENV_FAIL` | Follow the reported export, NFSv3, kernel/initramfs, write-permission, or compiler error. |

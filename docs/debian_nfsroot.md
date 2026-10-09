# Debian on an NFS root

This guide boots Debian 13 (trixie, riscv64) on the Alveo X3 with its root
filesystem on an NFS server, which the board reaches through the FROST NIC
over a 10GBASE-R optical link. The JTAG loader packs Debian's kernel and
initramfs with OpenSBI and a device tree; the initramfs loads the FROST NIC
module and mounts the export as `/`. The [Linux reference](../linux/README.md)
describes the boot interface.

Examples use server `192.0.2.1`, board `192.0.2.2`, and export
`/srv/nfs/debian`; substitute your own. The loader assumes the 322.265625 MHz
CPU clock. A divided-clock bitstream boots roughly proportionally slower.

## Requirements

What the board needs from the network:

| Need | Detail |
|---|---|
| Link | An SFP+ 10GBASE-R optic in the X3's DSFP28 cage labelled 2, with fiber to a matching optic on a 10GBASE-R partner: a server NIC port, a switch port, or a media converter running 10G on both ports. The NIC uses lane 1 of that cage (GTY X0Y28), the lane an SFP+ module occupies ([NIC integration](../hw/rtl/peripherals/nic/README.md#integration)). |
| Address | IPv4, which the initramfs configures from the kernel's `ip=` before it mounts the root. Use a static address, or DHCP with a reservation for the board's MAC and an infinite or very long lease: the initramfs takes one lease at boot and nothing renews it. Debian does not take DNS servers from that lease. |
| MAC | A locally administered address that is unique on the network (`FROST_LINUX_MAC`). Every board defaults to `02:11:22:33:44:55`. |
| NFS server | Linux `nfs-kernel-server` serving NFSv3 over TCP. The initramfs mounts with `vers=3,tcp,hard`, and its klibc `nfsmount` speaks only NFSv2 and NFSv3, so an NFSv4-only server does not work. Export one riscv64 root tree per board, read-write to that board's address, with `no_root_squash`. |
| Firewall | TCP from the board to the server's rpcbind (111), mountd, and nfsd (2049). mountd's port is dynamic unless `port=` is set under `[mountd]` in `/etc/nfs.conf`. |
| apt (optional) | DNS, a route to a Debian mirror or an apt proxy, and a time source: the board has no RTC. |

The loading host needs Vivado, Python, Make, `dtc`, the
[RISC-V toolchain](tooling.md#shared-risc-v-toolchain), and read access to
the kernel and initramfs files. The loader builds any missing
[firmware or test-image components](../linux/buildroot-external/README.md#build)
itself. Open a UART terminal at 115200 baud, 8N1.

## 1. Build the root filesystem

Run these on the server (Debian or Ubuntu) as root. `mmdebstrap`, and `chroot`
after it, run the riscv64 programs under QEMU user emulation registered
through binfmt. Every path goes through `${R:?}`, so a command refuses to run
if `R` is unset instead of touching the server's own files.

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

The tree needs about 1.1 GB, including kernel headers and build tools. The
explicit mirror selects only `trixie main`; add the updates and security
sources you need. The chroot starts with a copy of the server's resolver
settings.

apt installs Debian's current kernel, which may differ from the release the
repository pins. A manual boot works with any installed kernel and its
matching initramfs; the hardware regression requires the pinned release
(`python3 linux/debian_kernel.py release` prints it).

## 2. Configure the tree

Edit the tree as root on the server. With `no_root_squash`, the board sees
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
  no DHCP client, systemd-networkd, or NetworkManager for it.
- Create the `99-default.link` mask before step 3: the initramfs built there
  copies it.
- `/etc/fstab` needs no root entry; the initramfs mounts `/`.
- root has no usable password. Log in over SSH, or on the console through the
  autologin above.

## 3. Build the NIC driver into the initramfs

Build the [DKMS module](../linux/frost-net10g/README.md) and add it to the
initramfs. Run this from the repository root on the server. Pass `-k`
explicitly, because `uname -r` in the chroot reports the server's kernel.

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

With several kernels installed, set `K` by hand. `lsinitramfs` must show
`frost_net10g.ko` (possibly compressed) under that version's module
directory. Keep `MODULES=most` so the initramfs includes the NFS client.

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

Put the export on its own filesystem or a size-limited image, so a full board
root cannot fill the server's root. To move the tree into a file-backed
filesystem, with the board stopped:

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

`nofail` keeps a missing image from blocking the server's own boot. Boot the
board again afterwards: the server identifies an exported filesystem
internally, and the swap changes that identity.

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
- Give each board its own `FROST_LINUX_MAC`.
- `FROST_LINUX_IP` takes the kernel's `ip=` syntax; unset means DHCP.
- Kernel and initramfs paths must be absolute and readable on the loading
  host. Debian's `vmlinux-<version>` is an uncompressed RISC-V `Image` and
  needs no conversion; the compressed `vmlinuz-<version>` does not work. The
  kernel unpacks the initramfs itself.
- Check the packer's summary for `Linux Image` and, on X3,
  `memory 0x40000000 B`. The load takes several minutes.

Multi-user startup takes about three minutes after the load. The console
shows the NIC, `IP-Config: eth0 complete`, the NFS mount, and systemd's
startup. `Unknown kernel command line parameters` for `boot=nfs`, `nfsroot`,
and `ip` is expected: the initramfs consumes them. With a static IP, the
initramfs can also report missing search or nameserver values; configure DNS
in the root tree instead.

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

One way to give the board a route to a mirror is NAT on the server, which the
`ip=` above already names as the board's gateway. This needs `iptables`:

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

With `ip_forward` set, the server forwards traffic for any host that routes
through it, unless its `FORWARD` policy is `DROP`. `DROP` is the safer choice
on a shared network, and Docker sets it. Under `DROP`, also accept the board's
traffic and its replies, with a matching delete for each rule, in the
`[Service]` section:

```text
ExecStart=/usr/sbin/iptables -I FORWARD -s 192.0.2.0/24 -j ACCEPT
ExecStart=/usr/sbin/iptables -I FORWARD -d 192.0.2.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ExecStop=/usr/sbin/iptables -D FORWARD -s 192.0.2.0/24 -j ACCEPT
ExecStop=/usr/sbin/iptables -D FORWARD -d 192.0.2.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

An apt proxy replaces NAT: put `Acquire::http::Proxy "http://<proxy>:<port>/";`
in `/srv/nfs/debian/etc/apt/apt.conf.d/90proxy`.

Until the board reaches a time source, set its clock from a host whose clock
is right, then update. Each apt step takes minutes: the board does the work,
and its root filesystem is across the network.

```bash
ssh root@192.0.2.2 date -s @$(date +%s)
ssh root@192.0.2.2 'apt update && apt install -y <package>'
```

A kernel update takes effect only at the next load; see
[Operation](#operation).

## Hardware regression

The `linux_boot` stage of the hardware regression boots this root. Record the
export and the board's address in the Git-ignored `fpga/site.env`:

```
FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian
FROST_LINUX_IP=192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off
```

Run the stage alone, or leave off `linux_boot` to run the whole regression:

```bash
./fpga/hw_regression.py --board x3 linux_boot
```

The stage packs the pinned kernel from the checkout's cache
(`linux/debian-kernel`) and that release's `boot/initrd.img-<version>` from
the export. `FROST_LINUX_KERNEL` and `FROST_LINUX_INITRD` override either
file. `site.env` accepts these overrides too, and the environment wins over
the file.

Beyond a root that boots by hand, the stage needs:

| Need | Why |
|---|---|
| The export directory on the loading host | The stage reads the tree's console configuration and installs programs into it. If the server is another machine, mount the export on the loading host at the same path, or run the regression on the server. |
| The console autologin from step 2 | The stage logs in on the UART, and root has no usable password. |
| `usr/local/bin` writable by the user running the regression | Before each run, the stage cross-compiles `frost_stress` and `frost_nettest` from `linux/buildroot-external/package/frost-stress` and installs them there, so the programs it runs come from this checkout. The tree belongs to root, so give that one directory away: `install -d -m 755 -o <user> /srv/nfs/debian/usr/local/bin`. |
| A riscv64 Linux cross compiler on the loading host | It builds those programs as static binaries: Debian's `gcc-riscv64-linux-gnu`, a `FROST_LINUX_CROSS_COMPILE` prefix, or the toolchain a Buildroot build leaves in `linux/build-mmu/host/bin`. |
| The pinned kernel release on the root | The stage requires that release's boot banner, and the preflight reads the release out of the packed `Image` first. Install that version on the root, with `frost_net10g` in its initramfs (step 3). |
| The pinned kernel in the checkout's cache | Unless `FROST_LINUX_KERNEL` names a kernel, the stage packs the one in `linux/debian-kernel` (or `FROST_DEBIAN_KERNEL_CACHE`), and the preflight fails if it is not there yet. Run `python3 linux/debian_kernel.py fetch` once to fill the cache. |
| NFSv3 over TCP | Step 4. The preflight sends the server an NFSv3 NULL call. |
| A server on the board's own subnet | `frost_nettest` takes the root's interface down. When the interface comes back, the kernel restores its connected route but not a route through a gateway, so a server behind a gateway can leave the root stranded. The preflight reports which case applies. |
| An executable `/dev/shm` | `frost_nettest` runs from a copy in `/dev/shm` while the root's link is down, so that tmpfs must not be mounted `noexec`. |
| A fresh initramfs after driver changes | The initramfs carries the DKMS build from step 3. After editing `linux/frost-net10g`, repeat step 3, or the run tests the old module. |

Before any stage touches the board, a preflight checks the export, the NFS
server, the kernel and initramfs files, the autologin, and the cross build. It
reports a problem as `ENV_FAIL`, not as a board failure. Without
`--keep-going`, an `ENV_FAIL` stops the run before the first stage.

`--linux-timeout` (default 1200 seconds) covers the build, the JTAG load, the
boot, and the tests. Raise it for a divided-clock bitstream, or for a first
build that must download the Buildroot toolchain or the kernel.

The stage checks the NFS mount and systemd, runs the stress, counter, and NIC
loopback tests, and then writes and syncs a file on the root to prove that the
root came back after the loopback test took its link down. It leaves
`frost_stress` and `frost_nettest` in `/usr/local/bin`. The SoC has no
software reset, so reload the image before the next boot.

## Operation

- One tree per board. Never export a tree read-write to two boards: the
  initramfs mounts with `nolock`, so file locks are local to each board.
- The root is a `hard` mount. If the server or link goes away, processes that
  touch the root block until it returns. The board survives a server restart.
- `no_root_squash` gives the board's root user full control of the tree, so
  export it to the board's address only.
- Manage the tree's packages from one place at a time: apt on the board while
  it runs from the tree, or the chroot only while the board is stopped. Two
  package managers writing one dpkg database corrupt it.
- The SoC has no software reset or power-off, so `reboot` and `poweroff`
  leave the board stopped; load it again to boot. Run `poweroff` (or `sync`)
  before reloading so the board's writes reach the server.

### Kernel updates

apt installs a new kernel beside the running one. When its headers arrive in
the same apt run, as `linux-headers-riscv64` arranges, DKMS builds
`frost_net10g` for it before `update-initramfs` builds its initramfs. The
[driver guide](../linux/frost-net10g/README.md#an-nfs-root-needs-the-module-in-the-initramfs)
covers headers that arrive later. Then:

1. Check the new initramfs with `lsinitramfs`, as in step 3.
2. Load the new version's `vmlinux` and `initrd.img` (step 5). The board boots
   whatever the last load packed.
3. Until that load, keep the running kernel installed. Its
   `/lib/modules/<version>` in the tree supplies every module loaded after the
   initramfs.

`apt autoremove` and `apt full-upgrade` (which also removes unused kernels)
keep the running kernel when they run on the board. In a chroot on the
server, `uname -r` names the server's kernel instead, so apt cannot tell which
kernel the board runs.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| eth0 never appears; `SIOCGIFINDEX: No such device` | Run `lsinitramfs` and `dkms status`: the loaded initramfs needs `frost_net10g` for the loaded kernel. Rebuild as in step 3. |
| DHCP `IP-Config: no response` | Check the link and the DHCP reservation, or use a static IP. |
| Repeated NFS mount retries; `No route to host` / `NFS over TCP not available` | Check the 10G optical link, the server address, the firewall, and `rpcinfo -p` for NFSv3 over TCP. |
| NFS `Permission denied` | Check the export path and client address with `exportfs -v`. |
| No `/sbin/init` after mount attempts | Fix any mount errors first; otherwise check that the export is a complete riscv64 root. |
| Service permission errors after mounting | Set `no_root_squash` and re-export. |
| `nfs: server ... not responding` | Restore the server or link; the hard mount resumes when it returns. |
| Root stops responding after userspace starts | Something renamed or reconfigured eth0: check step 2's mask and any network managers. |
| ttyS0 device timeout; no console login | Increase `DefaultDeviceTimeoutSec` as in step 2. SSH can still work. |
| `eth0: re-enabled RX after a MAC domain reset` | Informational link-recovery message. |
| apt metadata is not valid yet | Set the clock or fix NTP. |
| apt cannot resolve names | Check `/etc/resolv.conf` and the route to its resolver. |
| Module missing under `/lib/modules/<version>` | Keep the running kernel installed; install its module, or load a kernel that is installed. An autoremove in the chroot sees the server's kernel. |
| SSH public-key rejection | Check the key, root ownership, mode 700 on `.ssh`, and mode 600 on `authorized_keys`. |
| Regression waits at login / `Login incorrect` | Add the console autologin drop-in from step 2. |
| Regression reports degraded systemd | Inspect `systemctl --failed` and `systemctl status <unit>`. |
| `/dev/shm/frost_nettest: Permission denied` | Remove `noexec` from the `/dev/shm` tmpfs. |
| Regression `ENV_FAIL` | Follow the reported export, NFSv3, kernel, initramfs, write-permission, or compiler error. |

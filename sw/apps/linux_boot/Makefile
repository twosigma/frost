#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# Builds the FROST memory images for the MMU Linux boot: Debian's own riscv64
# kernel, the OpenSBI firmware from the linux/opensbi submodule, and the test
# initramfs from the linux/buildroot submodule driven by the FROST BR2_EXTERNAL
# tree (linux/buildroot-external). frost_boot_image.py packs them into the
# low-BRAM shim (sw.{mem,txt}) plus the DDR image (sw_ddr.{mem,txt}) that
# fpga/load_software consumes. Everything is fetched or built from pinned
# sources, so a fresh `git clone --recurse-submodules` can build it.
# FROST_LINUX_KERNEL and FROST_LINUX_INITRD (below) swap in a kernel and an
# initramfs built elsewhere.
#
# Three stages, split so that re-loading for a different board is cheap:
#
#   Stage 1a (board-independent): Buildroot downloads its cross toolchain and
#     builds OpenSBI and the rootfs.cpio userspace, but no kernel (the kernel
#     is Debian's). A few minutes the first time, mostly the download; cached
#     in the build dir afterwards. Runs only when that initramfs or the
#     firmware is missing or older than the userspace sources its rule names,
#     so it does not re-run on every load.
#
#   Stage 1b (board-independent): linux/debian_kernel.py fetches Debian's
#     pinned kernel and builds the NIC driver as a module for it, then appends
#     that module and the init script that insmods it to Buildroot's
#     rootfs.cpio. Debian's kernel has no FROST driver built in, and
#     frost_nettest needs one. Cached under linux/debian-kernel.
#
#   Stage 2 (fast, board-dependent): frost_boot_image.py regenerates the DTB
#     (timebase + UART clock = FPGA_CPU_CLK_FREQ, memory = FROST_LINUX_MEM_SIZE)
#     and repacks the firmware, kernel and initramfs into the DDR image (with
#     FROST_LINUX_NFSROOT, an image that boots from an NFS root; see below).
#     `load_software.py <board> linux_boot` sets both per board and `make
#     clean`s first, so the DDR image is always repacked for the target board
#     while the Buildroot build and the Debian kernel cache are reused.
#
# sw_ddr.mem depends on the kernel Image, the initramfs, the firmware and the
# packer, so a newer one forces a repack.

# Repo-root-relative paths (this Makefile lives in sw/apps/linux_boot).
FROST_ROOT   := $(abspath $(CURDIR)/../../..)
BR2_SRC      := $(FROST_ROOT)/linux/buildroot
BR2_EXTERNAL := $(FROST_ROOT)/linux/buildroot-external
BOARD_DIR    := $(BR2_EXTERNAL)/board/frost

# OpenSBI fw_jump + the Sv39 kernel (linux/README.md, "Boot chain and entry
# state"), packed by frost_boot_image.py.
BR2_OUT      := $(FROST_ROOT)/linux/build-mmu
BR2_DEFCONFIG := frost_rv64_defconfig
IMAGES       := $(BR2_OUT)/images
BR2_INITRD   := $(IMAGES)/rootfs.cpio
FW_JUMP      := $(IMAGES)/fw_jump.bin

# Debian's kernel and the NIC module built for it (linux/debian_kernel.py holds
# the snapshot URL, version and checksums). The Image path is a pure query, so
# it costs no download; the rule below fetches when the file is absent.
# INITRD_IMG is Buildroot's userspace with that module and its loader appended.
DEBIAN_KERNEL := $(FROST_ROOT)/linux/debian_kernel.py
DEBIAN_IMAGE  := $(shell python3 "$(DEBIAN_KERNEL)" image --no-fetch)
DRIVER_DIR    := $(FROST_ROOT)/linux/frost-net10g
INITRD_IMG    := $(CURDIR)/rootfs.cpio
# The module is built with a Linux-target riscv64 cross toolchain. Prefer the
# one Buildroot's build just produced, so a host that has none installed (the
# Vivado host runs the loader natively) still builds it; the helper falls back
# to FROST_LINUX_CROSS_COMPILE, which the Docker image sets. Expanded when the
# recipe runs, by which time Buildroot has been built.
BR2_CROSS      = $(BR2_OUT)/host/bin/riscv64-linux-
MODULE_CROSS   = $(if $(wildcard $(BR2_CROSS)gcc),--cross "$(BR2_CROSS)")
ifeq ($(DEBIAN_IMAGE),)
$(error python3 "$(DEBIAN_KERNEL)" image --no-fetch printed no path; run it by \
hand to see why)
endif

# DTB timebase + UART clock. load_software.py exports this per board; the bare
# `make` default matches X3.
FPGA_CPU_CLK_FREQ ?= 322265625

# Kernel, root filesystem and NIC address. Unset, Debian's kernel and the test
# initramfs are packed with the packer's default bootargs.
# FROST_LINUX_KERNEL=<path> packs that Linux Image in place of Debian's, and
# FROST_LINUX_INITRD=<path> that initramfs in place of the test one; the
# firmware still comes from the Buildroot build. Give absolute paths: make
# runs in this directory.
# FROST_LINUX_NFSROOT=<server-ip>:/<path> boots from that NFS export instead,
# configuring the interface from FROST_LINUX_IP, an ip= parameter in the
# kernel's syntax (dhcp when unset; an error without FROST_LINUX_NFSROOT).
# Without FROST_LINUX_INITRD it packs no initramfs and the kernel mounts the
# export itself, which needs a kernel with CONFIG_IP_PNP and CONFIG_ROOT_NFS,
# not Debian's. With it, that initramfs mounts the export through
# initramfs-tools' NFS boot (boot=nfs), which is how Debian's kernel boots its
# own root.
# FROST_LINUX_MAC=aa:bb:cc:dd:ee:ff replaces the NIC's default
# local-mac-address in every case; each board on a shared network needs its
# own. load_software.py passes these through from the environment, like
# FROST_LINUX_PREBUILT.
PAYLOAD := $(or $(FROST_LINUX_KERNEL),$(DEBIAN_IMAGE))
# What to pack as the initramfs, empty for an NFS root that the kernel mounts
# itself. Naming it once keeps the composed initramfs out of the prerequisites
# when an override supplies one or an NFS root needs none, so the module rule
# below does not run; with FROST_LINUX_KERNEL set too, neither does the fetch
# rule. Buildroot's post-image hook still does both whenever Stage 1a runs.
ifdef FROST_LINUX_NFSROOT
PACK_INITRD := $(FROST_LINUX_INITRD)
PACK_ARGS := --nfsroot "$(FROST_LINUX_NFSROOT)" \
  $(if $(PACK_INITRD),--initrd "$(PACK_INITRD)")
else
PACK_INITRD := $(or $(FROST_LINUX_INITRD),$(INITRD_IMG))
PACK_ARGS := --initrd "$(PACK_INITRD)"
endif
PACK_ARGS += $(if $(FROST_LINUX_IP),--ip "$(FROST_LINUX_IP)")
PACK_ARGS += $(if $(FROST_LINUX_MAC),--mac "$(FROST_LINUX_MAC)")
# The packer takes FROST_INITRD from the environment as its --initrd default,
# which would give an NFS root an initramfs; only the variables above choose it.
unexport FROST_INITRD

# Memory size in bytes. load_software.py exports the board's DDR size (the
# CPU's range in fpga/build/<board>_ddr_bd.tcl, 1 GiB on the X3). Unset, the
# packer's default applies: 64 MiB (MEM_SIZE in frost_boot_image.py).
# sw/apps/compile_app.py keeps simulation builds from inheriting a board's size.
PACK_ARGS += $(if $(FROST_LINUX_MEM_SIZE),--mem-size "$(FROST_LINUX_MEM_SIZE)")

# Cross prefix for the tiny boot shim, which disables PIE itself: the first
# of RISCV_PREFIX, riscv64-linux- on PATH, and Buildroot's toolchain whose gcc
# exists. load_software.py picks RISCV_PREFIX before a cold build has installed
# Buildroot's toolchain, so the prefix it passes can name nothing yet. Expanded
# when the recipe runs, like MODULE_CROSS above. With none of them,
# frost_boot_image.py's default, riscv64-linux-, reports the missing compiler.
resolves   = $(if $(shell command -v "$(1)gcc" 2>/dev/null),$(1))
SHIM_PREFIX = $(or $(if $(RISCV_PREFIX),$(call resolves,$(RISCV_PREFIX))),\
  $(call resolves,riscv64-linux-),$(if $(wildcard $(BR2_CROSS)gcc),$(BR2_CROSS)))
SHIM_CROSS = $(if $(SHIM_PREFIX),FROST_CROSS_COMPILE=$(SHIM_PREFIX))

.PHONY: all clean distclean

# --- Prebuilt-image mode ------------------------------------------------------
# Images built elsewhere (another checkout, or a machine that can run Buildroot)
# can be staged here and loaded on a board. load_software.py does
# `make clean` + `make` on this app before every load. Without a Buildroot build
# in the clone, that clean would delete the staged images and the build
# would kick off a full Buildroot rebuild that overwrites them.
# FROST_LINUX_PREBUILT=1 declares the staged images authoritative: `make`
# verifies they exist and touches nothing; `make clean` keeps them and only
# removes packer scratch files.
ifeq ($(FROST_LINUX_PREBUILT),1)

# sw64.mem is a re-encoding of the staged sw.mem: dword rows for the 64-bit data
# BRAM, per hw/rtl/README.md "Data-tier bus contract". Deriving it locally does
# not contradict treating the staged images as authoritative.
all: sw64.mem
	@test -f sw.mem -a -f sw_ddr.mem || { \
	  echo "ERROR: FROST_LINUX_PREBUILT=1 but sw.mem / sw_ddr.mem are not staged here."; \
	  exit 1; }
	@echo "linux_boot: FROST_LINUX_PREBUILT=1 -> using staged images as-is"

sw64.mem: sw.mem ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py '$<' '$@'

clean:
	rm -f sw64.mem shim.elf shim.bin frost_boot_shim.S \
	      frost.dts frost.dtb

distclean: clean

else  # --- Normal self-build mode ---------------------------------------------

# The pack recipe writes all four images at once, so `all` names only
# sw_ddr.mem of the four; sw64.mem is derived from the packed sw.mem afterwards.
all: sw_ddr.mem sw64.mem

# Dword-paired copy of the boot shim image for the 64-bit data BRAM's
# $readmemh (hw/rtl/README.md, "Data-tier bus contract").
sw64.mem: sw.mem ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py '$<' '$@'

# Stage 1a: the test initramfs + OpenSBI via Buildroot. Runs when either file
# is missing or older than a frost-stress source or the overlay inittab.
# Grouped target (&:): one Buildroot invocation produces both files. A plain
# multi-target rule would run the recipe once per missing file, and under -j it
# could run two Buildroot makes concurrently in the same O= dir.
#
# Buildroot does not notice an edited package source by itself, so without
# these prerequisites an existing archive would keep the old programs, and the
# boot soak (fpga/linux_boot_soak.py), which boots this image, would run them.
# Naming the sources here rebuilds just that package. debian_kernel.py's
# check_base_initramfs, which refuses a frost_stress without the counter token,
# is the backstop for an archive whose timestamps lie.
#
# BR2_EXTERNAL goes on every Buildroot invocation, not just the defconfig.
# Buildroot would reuse the value the defconfig saved, but naming it keeps each
# call independent of that saved state.
#
# The build directory still belongs to one view of the checkout: its .config
# stores BR2_EXTERNAL_FROST_PATH as an absolute path, which a command-line
# BR2_EXTERNAL does not override. Re-running the defconfig is the only way to
# move it, and that is not something to do behind someone's back, so a
# directory configured elsewhere (a container build reached from a native
# loader, or the reverse) is reported rather than reconfigured.
#
# A directory configured by a tree that built its own kernel is reported too.
# Its .config selects BR2_LINUX_KERNEL and points BR2_GLOBAL_PATCH_DIR at
# board/frost/patches, which does not exist in this tree, so Buildroot stops
# with "BR2_GLOBAL_PATCH_DIR contains nonexistent directory" before any target
# runs. Re-running the defconfig over it would clear those symbols but leave
# perf and elfutils installed in target/ (Buildroot does not uninstall a
# deselected package), so the fix is to start over, and the message says so.
FROST_STRESS_SRC := $(wildcard $(BR2_EXTERNAL)/package/frost-stress/src/*.c)
BR2_OVERLAY := $(wildcard $(BOARD_DIR)/rootfs-overlay-mmu/etc/inittab)
BR2_RECORDED = $(patsubst "%",%,$(shell sed -n \
  's/^BR2_EXTERNAL_FROST_PATH=//p' "$(BR2_OUT)/.config" 2>/dev/null))
BR2_STALE_KERNEL = $(shell sed -n 's/^BR2_LINUX_KERNEL=y$$/y/p' \
  "$(BR2_OUT)/.config" 2>/dev/null)
$(BR2_INITRD) $(FW_JUMP) &: $(FROST_STRESS_SRC) $(BR2_OVERLAY)
	@test -f "$(BR2_SRC)/Makefile" || { \
	  echo "ERROR: buildroot submodule not initialized."; \
	  echo "  Run: git submodule update --init linux/buildroot"; \
	  exit 1; }
	@if [ ! -f "$(BR2_OUT)/.config" ]; then \
	  echo ">>> linux_boot: building the test initramfs + OpenSBI via Buildroot (first build a few minutes)..."; \
	  $(MAKE) -C "$(BR2_SRC)" O="$(BR2_OUT)" BR2_EXTERNAL="$(BR2_EXTERNAL)" \
	    $(BR2_DEFCONFIG) || exit 1; \
	elif [ -n "$(BR2_STALE_KERNEL)" ]; then \
	  echo "ERROR: $(BR2_OUT) is configured to build a kernel (its .config"; \
	  echo "       has BR2_LINUX_KERNEL=y and a BR2_GLOBAL_PATCH_DIR that does"; \
	  echo "       not exist). FROST boots Debian's kernel, and Buildroot"; \
	  echo "       cannot reuse that configuration. Start over:"; \
	  echo "         make -C sw/apps/linux_boot distclean"; \
	  exit 1; \
	elif [ "$(BR2_RECORDED)" != "$(BR2_EXTERNAL)" ]; then \
	  echo "ERROR: $(BR2_OUT) was configured for"; \
	  echo "         $(BR2_RECORDED)"; \
	  echo "       but this build sees the tree as"; \
	  echo "         $(BR2_EXTERNAL)"; \
	  echo "       Its .config stores that path, so it cannot be built from here."; \
	  echo "       Rebuild the test userspace from the other view, or start over:"; \
	  echo "         make -C sw/apps/linux_boot distclean"; \
	  exit 1; \
	else \
	  echo ">>> linux_boot: the test userspace changed; rebuilding frost-stress..."; \
	  $(MAKE) -C "$(BR2_SRC)" O="$(BR2_OUT)" BR2_EXTERNAL="$(BR2_EXTERNAL)" \
	    frost-stress-rebuild || exit 1; \
	fi
	$(MAKE) -C "$(BR2_SRC)" O="$(BR2_OUT)" BR2_EXTERNAL="$(BR2_EXTERNAL)"

# Stage 1b: Debian's kernel, cached under linux/debian-kernel. No prerequisites,
# so the fetch runs only when the Image is absent; a changed pin changes this
# path, and the helper re-checks its own cache whenever it is invoked.
$(DEBIAN_IMAGE):
	python3 "$(DEBIAN_KERNEL)" fetch

# Stage 1b: the test initramfs with the NIC module for Debian's kernel, and the
# init script that insmods it, appended. The driver's sources are prerequisites
# so an edited driver is rebuilt into the module.
$(INITRD_IMG): $(BR2_INITRD) $(DEBIAN_KERNEL) $(DRIVER_DIR)/frost_net10g.c \
    $(DRIVER_DIR)/Makefile | $(DEBIAN_IMAGE)
	python3 "$(DEBIAN_KERNEL)" $(MODULE_CROSS) initramfs \
	  --base "$(BR2_INITRD)" --out "$@"

# Stage 2: pack for this board's clock. The firmware that Buildroot's
# post-image hook built (images/fw_jump.bin) is packed with frost_boot_image.py.
# Grouped target (&:): one packer run writes all four files, so make -j must
# not start a second run for another of them.
sw_ddr.mem sw.mem sw_ddr.txt sw.txt &: $(PAYLOAD) $(PACK_INITRD) $(FW_JUMP) \
    $(BOARD_DIR)/frost_boot_image.py
	FPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ) $(SHIM_CROSS) \
	  python3 "$(BOARD_DIR)/frost_boot_image.py" \
	    --firmware "$(FW_JUMP)" --payload "$(PAYLOAD)" $(PACK_ARGS) \
	    --out "$(CURDIR)"

# Light clean: drop only the board-dependent pack outputs (Stage 2) and the
# composed initramfs, which is cheap to rebuild once the module is cached. The
# Buildroot build and the Debian kernel cache (Stage 1) survive, so a re-pack
# for another board is fast. This is what load_software.py runs before every
# load.
clean:
	rm -f sw.mem sw64.mem sw.txt sw_ddr.mem sw_ddr.txt rootfs.cpio \
	      shim.elf shim.bin frost_boot_shim.S \
	      frost.dts frost.dtb

# Full clean: also wipe the (slow) Buildroot build tree, forcing a Stage 1a
# rebuild. The Debian kernel cache is a download cache, like linux/dl, and is
# left alone; remove linux/debian-kernel by hand to force a refetch.
distclean: clean
	rm -rf "$(BR2_OUT)"

endif  # FROST_LINUX_PREBUILT

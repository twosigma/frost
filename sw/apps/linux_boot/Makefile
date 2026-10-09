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

# Build Linux boot images from Debian's pinned riscv64 kernel, OpenSBI
# (linux/opensbi), and Buildroot's initramfs (linux/buildroot, configured by
# linux/buildroot-external). frost_boot_image.py emits a low-BRAM shim
# (sw.mem, sw.txt) and a DDR image (sw_ddr.mem, sw_ddr.txt) for fpga/load_software.
#
# Stage 1a builds OpenSBI and userspace with Buildroot's downloaded toolchain.
# Stage 1b fetches Debian's kernel and adds the matching FROST NIC module and
# loader script to the initramfs; Debian's kernel lacks this driver.
# Stage 2 repacks the images and DTB for FPGA_CPU_CLK_FREQ (timer and UART)
# and FROST_LINUX_MEM_SIZE. The loader cleans Stage 2 before each load while
# reusing the Buildroot build and linux/debian-kernel cache.
# Kernel and initramfs overrides are described below.

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
# Prefer Buildroot's Linux-target toolchain, available when the recipe runs.
# The helper falls back to FROST_LINUX_CROSS_COMPILE, set by the Docker image.
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
# An initramfs override or a kernel-mounted NFS root skips the
# composed-initramfs rule; setting FROST_LINUX_KERNEL as well skips the kernel
# fetch rule. Buildroot's post-image hook still runs both helpers whenever
# Stage 1a runs.
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

# Select the first available boot-shim compiler: RISCV_PREFIX, riscv64-linux-
# on PATH, or Buildroot's toolchain. Resolve it when the recipe runs, after
# Buildroot can install its compiler; the loader's prefix may not exist yet.
# With none available, frost_boot_image.py reports the missing riscv64-linux-gcc.
# The shim build disables PIE.
resolves   = $(if $(shell command -v "$(1)gcc" 2>/dev/null),$(1))
SHIM_PREFIX = $(or $(if $(RISCV_PREFIX),$(call resolves,$(RISCV_PREFIX))),\
  $(call resolves,riscv64-linux-),$(if $(wildcard $(BR2_CROSS)gcc),$(BR2_CROSS)))
SHIM_CROSS = $(if $(SHIM_PREFIX),FROST_CROSS_COMPILE=$(SHIM_PREFIX))

.PHONY: all clean distclean

# --- Prebuilt-image mode ------------------------------------------------------
# The loader runs `make clean` and `make` before loading. Set
# FROST_LINUX_PREBUILT=1 to preserve staged images: make checks they exist and
# derives sw64.mem; clean removes only that derived image and packer scratch.
ifeq ($(FROST_LINUX_PREBUILT),1)

# Convert staged sw.mem to dword rows for the 64-bit data BRAM
# (hw/rtl/README.md, "Data-tier bus contract").
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

# Stage 1a: build the test initramfs and OpenSBI. A grouped target prevents
# parallel Buildroot invocations in the same O= directory.
# Package-source and inittab prerequisites trigger frost-stress-rebuild;
# Buildroot does not detect package-source edits itself. check_base_initramfs
# in debian_kernel.py also rejects frost_stress without the counter token.
#
# Pass BR2_EXTERNAL on every call. The saved absolute BR2_EXTERNAL_FROST_PATH
# still cannot be overridden this way, so reject builds configured through
# another filesystem path rather than silently rerunning defconfig.
#
# Reject configurations that build a kernel: their patch directory is absent
# here. Rerunning defconfig would leave perf and elfutils in target/, since
# Buildroot does not uninstall deselected packages; these builds need a new tree.
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

# Clean the board images and composed initramfs before each load. Keep the
# Buildroot build and Debian kernel cache for repacking on another board.
clean:
	rm -f sw.mem sw64.mem sw.txt sw_ddr.mem sw_ddr.txt rootfs.cpio \
	      shim.elf shim.bin frost_boot_shim.S \
	      frost.dts frost.dtb

# Also remove the Buildroot build tree. The Debian kernel download cache
# remains; remove linux/debian-kernel manually to force a refetch.
distclean: clean
	rm -rf "$(BR2_OUT)"

endif  # FROST_LINUX_PREBUILT

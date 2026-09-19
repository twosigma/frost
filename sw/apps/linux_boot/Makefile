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

# Builds the FROST memory images for the MMU Linux boot straight from source in
# this repo: OpenSBI, the Sv39 kernel and the initramfs come from the vendored
# submodules (linux/opensbi, linux/buildroot) driven by the FROST BR2_EXTERNAL
# tree (linux/buildroot-external), and frost_boot_image.py packs them into the
# low-BRAM shim (sw.{mem,txt}) plus the DDR image (sw_ddr.{mem,txt}) that
# fpga/load_software consumes. There are no prebuilt artifacts and no
# out-of-repo paths, so a fresh `git clone --recurse-submodules` can build
# it. FROST_LINUX_KERNEL and FROST_LINUX_INITRD (below) swap in a kernel and an
# initramfs built elsewhere, such as Debian's.
#
# Two stages, split so that re-loading for a different board is cheap:
#
#   Stage 1 (slow, board-independent): Buildroot builds its own cross toolchain,
#     OpenSBI, the kernel Image and the rootfs.cpio. ~30-60 min the first
#     time; cached in the build dir afterwards. Only runs when the
#     kernel Image is absent, so it does not re-run on every load.
#
#   Stage 2 (fast, board-dependent): frost_boot_image.py regenerates the DTB
#     (timebase + UART clock = FPGA_CPU_CLK_FREQ, memory = FROST_LINUX_MEM_SIZE)
#     and repacks the firmware, kernel and initramfs into the DDR image (with
#     FROST_LINUX_NFSROOT, an image that boots from an NFS root; see below).
#     `load_software.py <board> linux_boot` sets both per board and `make
#     clean`s first, so the DDR image is always repacked for the target board
#     without a kernel rebuild.
#
# sw_ddr.mem depends on the kernel Image, the initramfs and the packer, so a
# newer one forces a repack. It once had no prerequisites at all and never
# regenerated when the underlying image changed.

# Repo-root-relative paths (this Makefile lives in sw/apps/linux_boot).
FROST_ROOT   := $(abspath $(CURDIR)/../../..)
BR2_SRC      := $(FROST_ROOT)/linux/buildroot
BR2_EXTERNAL := $(FROST_ROOT)/linux/buildroot-external
BOARD_DIR    := $(BR2_EXTERNAL)/board/frost

# OpenSBI fw_jump + the Sv39 kernel (linux/README.md, "OpenSBI boot chain"),
# packed by frost_boot_image.py. The no-MMU M-mode lane was retired in Phase 3;
# this is the only lane.
BR2_OUT      := $(FROST_ROOT)/linux/build-mmu
BR2_DEFCONFIG := frost_rv64_defconfig
INITRD_IMG   := $(BR2_OUT)/images/rootfs.cpio
IMAGES       := $(BR2_OUT)/images
KIMAGE       := $(IMAGES)/Image
FW_JUMP      := $(IMAGES)/fw_jump.bin

# DTB timebase + UART clock. load_software.py exports this per board; the bare
# `make` default matches X3.
FPGA_CPU_CLK_FREQ ?= 300000000

# Kernel, root filesystem and NIC address. Unset, Buildroot's kernel and
# initramfs are packed with the packer's default bootargs.
# FROST_LINUX_KERNEL=<path> packs that Linux Image in place of Buildroot's
# kernel, and FROST_LINUX_INITRD=<path> that initramfs in place of rootfs.cpio;
# the firmware still comes from the Buildroot build. Give absolute paths: make
# runs in this directory.
# FROST_LINUX_NFSROOT=<server-ip>:/<path> boots from that NFS export instead,
# configuring the interface from FROST_LINUX_IP, an ip= parameter in the
# kernel's syntax (dhcp when unset; an error without FROST_LINUX_NFSROOT).
# Without FROST_LINUX_INITRD it packs no initramfs and the kernel mounts the
# export; with it, that initramfs mounts the export through initramfs-tools'
# NFS boot (boot=nfs), for a kernel with no NFS root of its own, such as
# Debian's. FROST_LINUX_MAC=aa:bb:cc:dd:ee:ff replaces the NIC's default
# local-mac-address in every case; each board on a shared network needs its
# own. load_software.py passes these through from the environment, like
# FROST_LINUX_PREBUILT.
PAYLOAD := $(or $(FROST_LINUX_KERNEL),$(KIMAGE))
ifdef FROST_LINUX_NFSROOT
PACK_ARGS := --nfsroot "$(FROST_LINUX_NFSROOT)" \
  $(if $(FROST_LINUX_INITRD),--initrd "$(FROST_LINUX_INITRD)")
else
PACK_ARGS := --initrd "$(or $(FROST_LINUX_INITRD),$(INITRD_IMG))"
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

# Cross prefix for the tiny boot shim. frost_boot_image.py defaults to
# riscv-none-elf-, the xPack bare-metal toolchain that load_software.py and the
# Docker image provide. RISCV_PREFIX from the environment overrides it.
ifdef RISCV_PREFIX
SHIM_CROSS := FROST_CROSS_COMPILE=$(RISCV_PREFIX)
endif

.PHONY: all clean distclean

# --- Prebuilt-image mode ------------------------------------------------------
# Images built elsewhere (another checkout, or a machine that has the kernel
# build) can be staged here and loaded on a board. load_software.py does
# `make clean` + `make` on this app before every load. Without a kernel build
# tree in the clone, that clean would delete the staged images and the build
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

# sw_ddr.mem's recipe emits all four images at once, so it is the canonical
# goal; sw64.mem is derived from the packed sw.mem afterwards.
all: sw_ddr.mem sw64.mem

# Dword-paired copy of the boot shim image for the 64-bit data BRAM's
# $readmemh (hw/rtl/README.md, "Data-tier bus contract").
sw64.mem: sw.mem ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py '$<' '$@'

# Stage 1: kernel Image + rootfs via Buildroot. Skipped when already built.
# Grouped target (&:): one Buildroot invocation produces both files. A plain
# multi-target rule would run the recipe once per missing file, and under -j it
# could run two Buildroot makes concurrently in the same O= dir.
$(KIMAGE) $(INITRD_IMG) &:
	@test -f "$(BR2_SRC)/Makefile" || { \
	  echo "ERROR: buildroot submodule not initialized."; \
	  echo "  Run: git submodule update --init linux/buildroot"; \
	  exit 1; }
	@echo ">>> linux_boot: building kernel + rootfs via Buildroot (first build ~30-60 min)..."
	$(MAKE) -C "$(BR2_SRC)" O="$(BR2_OUT)" BR2_EXTERNAL="$(BR2_EXTERNAL)" $(BR2_DEFCONFIG)
	$(MAKE) -C "$(BR2_SRC)" O="$(BR2_OUT)"

# Stage 2: pack for this board's clock. The firmware that Buildroot's
# post-image hook built (images/fw_jump.bin) is packed with frost_boot_image.py.
sw_ddr.mem sw.mem sw_ddr.txt sw.txt: $(KIMAGE) $(INITRD_IMG) $(FROST_LINUX_KERNEL) \
    $(FROST_LINUX_INITRD) $(BOARD_DIR)/frost_boot_image.py
	@test -f "$(FW_JUMP)" || { \
	  echo "ERROR: $(FW_JUMP) is missing; the Buildroot post-image hook builds it."; \
	  exit 1; }
	FPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ) $(SHIM_CROSS) \
	  python3 "$(BOARD_DIR)/frost_boot_image.py" \
	    --firmware "$(FW_JUMP)" --payload "$(PAYLOAD)" $(PACK_ARGS) \
	    --out "$(CURDIR)"

# Light clean: drop only the board-dependent pack outputs (Stage 2). The cached
# Buildroot kernel/rootfs (Stage 1) survive, so a re-pack for another board is
# fast. This is what load_software.py runs before every load.
clean:
	rm -f sw.mem sw64.mem sw.txt sw_ddr.mem sw_ddr.txt \
	      shim.elf shim.bin frost_boot_shim.S \
	      frost.dts frost.dtb

# Full clean: also wipe the (slow) Buildroot build tree, forcing a Stage 1 rebuild.
distclean: clean
	rm -rf "$(BR2_OUT)"

endif  # FROST_LINUX_PREBUILT

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

# Builds the FROST memory images for the no-MMU Linux boot straight from source
# in this repo: the kernel + busybox initramfs come from the vendored Buildroot
# submodule (linux/buildroot) driven by the FROST BR2_EXTERNAL tree
# (linux/buildroot-external), and build_fpga_boot.py packs them into the low-BRAM
# boot shim (sw.{mem,txt}) plus the DDR image (sw_ddr.{mem,txt}) that cocotb's
# linux_boot test and fpga/load_software consume. There are no prebuilt artifacts
# and no out-of-repo paths, so a fresh `git clone --recurse-submodules` can build
# it.
#
# Two stages, split so that re-loading for a different board is cheap:
#
#   Stage 1 (slow, board-independent): Buildroot builds its own uClibc cross
#     toolchain, the kernel Image and the rootfs.cpio.gz. ~30-60 min the first
#     time; cached in the lane's build dir afterwards. Only runs when the
#     kernel Image is absent, so it does not re-run on every load.
#
#   Stage 2 (fast, board-dependent): build_fpga_boot.py regenerates the DTB
#     (timebase + UART clock = FPGA_CPU_CLK_FREQ) and repacks the DDR image, then
#     patch_linux_image.py applies the initramfs fixups + env-gated bring-up
#     hooks (the ret_from_exception restore-window mutation was retired
#     2026-07-26; see that script's History note).
#     `load_software.py <board> linux_boot` sets FPGA_CPU_CLK_FREQ per board
#     (genesys2 = 133.33 MHz, x3 = 300 MHz) and `make clean`s first, so the DDR
#     image is always repacked for the target board without a kernel rebuild.
#
# sw_ddr.mem depends on the kernel Image and the packer, so a newer kernel or
# packer forces a repack. It once had no prerequisites at all and never
# regenerated when the underlying image changed.

# Repo-root-relative paths (this Makefile lives in sw/apps/linux_boot).
# The -rv64 suffixes in the build dir and defconfig names are historical: they
# namespaced this lane beside the retired rv32 one.
FROST_ROOT   := $(abspath $(CURDIR)/../../..)
BR2_SRC      := $(FROST_ROOT)/linux/buildroot
BR2_EXTERNAL := $(FROST_ROOT)/linux/buildroot-external
BR2_OUT      := $(FROST_ROOT)/linux/build-rv64
BR2_DEFCONFIG := frost_nommu_rv64_defconfig
BOARD_DIR    := $(BR2_EXTERNAL)/board/frost
IMAGES       := $(BR2_OUT)/images
KIMAGE       := $(IMAGES)/Image
INITRD_IMG   := $(IMAGES)/rootfs.cpio.gz

# DTB timebase + UART clock. load_software.py exports this per board; default is
# genesys2 (133.33 MHz) for a bare `make` on a dev box.
FPGA_CPU_CLK_FREQ ?= 133333333

# Cross prefix for the tiny boot shim. build_fpga_boot.py defaults to
# riscv-none-elf-, the xPack bare-metal toolchain that load_software.py and the
# Docker image provide. RISCV_PREFIX from the environment overrides it.
ifdef RISCV_PREFIX
SHIM_CROSS := FROST_CROSS_COMPILE=$(RISCV_PREFIX)
endif

.PHONY: all clean distclean

# --- Prebuilt-image mode (CI) -------------------------------------------------
# The CI linux-boot-cocotb job downloads the images that build-frost-linux
# produced and stages them here; the cocotb runner then does `make clean` +
# `make` on this app (compile_app clean_first=True). Without a kernel build
# tree in the clone, that clean would delete the staged images and the build
# would kick off a full in-job Buildroot rebuild that overwrites them.
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
	      frost-nommu-fpga.dts frost-nommu-fpga.dtb

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

# Stage 2: pack for this board's clock, then post-process the boot images.
sw_ddr.mem sw.mem sw_ddr.txt sw.txt: $(KIMAGE) $(INITRD_IMG) $(BOARD_DIR)/build_fpga_boot.py patch_linux_image.py
	FPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ) \
	  FROST_IMAGE="$(KIMAGE)" \
	  FROST_INITRD="$(INITRD_IMG)" \
	  FROST_OUTDIR="$(CURDIR)" \
	  $(SHIM_CROSS) \
	  python3 "$(BOARD_DIR)/build_fpga_boot.py"
	python3 ./patch_linux_image.py ./sw_ddr.mem ./sw_ddr.txt

# Light clean: drop only the board-dependent pack outputs (Stage 2). The cached
# Buildroot kernel/rootfs (Stage 1) survive, so a re-pack for another board is
# fast. This is what load_software.py runs before every load.
clean:
	rm -f sw.mem sw64.mem sw.txt sw_ddr.mem sw_ddr.txt \
	      shim.elf shim.bin frost_boot_shim.S \
	      frost-nommu-fpga.dts frost-nommu-fpga.dtb

# Full clean: also wipe the (slow) Buildroot build tree, forcing a Stage 1 rebuild.
distclean: clean
	rm -rf "$(BR2_OUT)"

endif  # FROST_LINUX_PREBUILT

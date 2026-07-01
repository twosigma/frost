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
# linux_boot test and fpga/load_software consume. No hand-built artifacts and no
# out-of-repo paths -- a fresh `git clone --recurse-submodules` can build it.
#
# Two stages, deliberately split so re-loading for a different board is cheap:
#
#   Stage 1 (slow, board-INDEPENDENT): Buildroot builds its own rv32 uClibc cross
#     toolchain, the kernel Image and the rootfs.cpio.gz. ~30-60 min the first
#     time; cached in linux/build afterwards. Only runs when the kernel Image is
#     absent, so it does not re-run on every load.
#
#   Stage 2 (fast, board-DEPENDENT): build_fpga_boot.py regenerates the DTB
#     (timebase + UART clock = FPGA_CPU_CLK_FREQ) and repacks the DDR image, then
#     patch_ret_from_exception.py applies the M-mode timer restore-window patch.
#     `load_software.py <board> linux_boot` sets FPGA_CPU_CLK_FREQ per board
#     (genesys2 = 133.33 MHz, x3 = 300 MHz) and `make clean`s first, so the DDR
#     image is always repacked for the target board without a kernel rebuild.
#
# The old footgun (sw_ddr.mem had no prerequisites, so it never regenerated when
# the underlying image changed) is gone: sw_ddr.mem now depends on the kernel
# Image and the packer, so a newer kernel or packer forces a repack.
#
# The patch clears mstatus.MIE in the MRET restore window: the M-mode variant of
# the timer-interrupt-resume-PC race is not yet fixed in hardware, so an
# unpatched kernel hangs at the CLINT clocksource switch once the periodic tick
# ramps up. It locates its target by unique machine-code word, so it survives
# kernel rebuilds. Drop it once the M-mode restore window is fixed in RTL.

# Repo-root-relative paths (this Makefile lives in sw/apps/linux_boot).
FROST_ROOT   := $(abspath $(CURDIR)/../../..)
BR2_SRC      := $(FROST_ROOT)/linux/buildroot
BR2_EXTERNAL := $(FROST_ROOT)/linux/buildroot-external
BR2_OUT      := $(FROST_ROOT)/linux/build
BOARD_DIR    := $(BR2_EXTERNAL)/board/frost
IMAGES       := $(BR2_OUT)/images
KIMAGE       := $(IMAGES)/Image
INITRD_IMG   := $(IMAGES)/rootfs.cpio.gz

# DTB timebase + UART clock. load_software.py exports this per board; default is
# genesys2 (133.33 MHz) for a bare `make` on a dev box.
FPGA_CPU_CLK_FREQ ?= 133333333

# The FROST cross prefix for the tiny boot shim (build_fpga_boot.py's default is
# riscv-none-elf-, the xPack bare-metal toolchain that load_software.py / the
# Docker image provide). Honor RISCV_PREFIX if the environment set one.
ifdef RISCV_PREFIX
SHIM_CROSS := FROST_CROSS_COMPILE=$(RISCV_PREFIX)
endif

.PHONY: all clean distclean

# sw_ddr.mem's recipe emits all four images at once, so it is the canonical goal.
all: sw_ddr.mem

# Stage 1: kernel Image + rootfs via Buildroot. Skipped when already built.
$(KIMAGE) $(INITRD_IMG):
	@test -f "$(BR2_SRC)/Makefile" || { \
	  echo "ERROR: buildroot submodule not initialized."; \
	  echo "  Run: git submodule update --init linux/buildroot"; \
	  exit 1; }
	@echo ">>> linux_boot: building kernel + rootfs via Buildroot (first build ~30-60 min)..."
	$(MAKE) -C "$(BR2_SRC)" O="$(BR2_OUT)" BR2_EXTERNAL="$(BR2_EXTERNAL)" frost_nommu_rv32_defconfig
	$(MAKE) -C "$(BR2_SRC)" O="$(BR2_OUT)"

# Stage 2: pack for this board's clock, then apply the M-mode timer patch.
sw_ddr.mem sw.mem sw_ddr.txt sw.txt: $(KIMAGE) $(INITRD_IMG) $(BOARD_DIR)/build_fpga_boot.py patch_ret_from_exception.py
	FPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ) \
	  FROST_IMAGE="$(KIMAGE)" \
	  FROST_INITRD="$(INITRD_IMG)" \
	  FROST_OUTDIR="$(CURDIR)" \
	  $(SHIM_CROSS) \
	  python3 "$(BOARD_DIR)/build_fpga_boot.py"
	python3 ./patch_ret_from_exception.py ./sw_ddr.mem ./sw_ddr.txt

# Light clean: drop only the board-dependent pack outputs (Stage 2). The cached
# Buildroot kernel/rootfs (Stage 1) survive, so a re-pack for another board is
# fast. This is what load_software.py runs before every load.
clean:
	rm -f sw.mem sw.txt sw_ddr.mem sw_ddr.txt \
	      shim.elf shim.bin frost_boot_shim.S \
	      frost-nommu-fpga.dts frost-nommu-fpga.dtb

# Full clean: also wipe the (slow) Buildroot build tree, forcing a Stage 1 rebuild.
distclean: clean
	rm -rf "$(BR2_OUT)"

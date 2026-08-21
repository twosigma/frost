#!/usr/bin/env bash

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

# Buildroot post-image hook for the FROST no-MMU Linux images.
#
# Buildroot runs this after the image stage with BINARIES_DIR, HOST_DIR, and
# BUILD_DIR exported. It locates the cross-toolchain and dtc, then emits:
#
#   $BINARIES_DIR/sw.{mem,txt}       low-BRAM boot shim
#   $BINARIES_DIR/sw_ddr.{mem,txt}   kernel Image + DTB + initramfs in DDR
#
# CI stages sw.mem/sw_ddr.mem in sw/apps/linux_boot/; see the external-tree README.

set -euo pipefail

BOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BINARIES_DIR:?BINARIES_DIR must be set (run me as a Buildroot post-image script)}"
: "${HOST_DIR:?HOST_DIR must be set (run me as a Buildroot post-image script)}"

# Locate Buildroot's RISC-V cross-toolchain.
gcc_path="$(ls "${HOST_DIR}"/bin/riscv*-gcc 2>/dev/null | head -n1 || true)"
if [ -z "${gcc_path}" ]; then
    echo "post-image.sh: no riscv*-gcc found in ${HOST_DIR}/bin" >&2
    exit 1
fi
cross_compile="${gcc_path%gcc}"

# Prefer the host dtc, then the kernel copy, then PATH.
dtc_path="${HOST_DIR}/bin/dtc"
if [ ! -x "${dtc_path}" ]; then
    dtc_path="$(ls "${BUILD_DIR:-}"/linux-*/scripts/dtc/dtc 2>/dev/null | head -n1 || true)"
fi
if [ -z "${dtc_path}" ] || [ ! -x "${dtc_path}" ]; then
    dtc_path="$(command -v dtc || true)"
fi
if [ -z "${dtc_path}" ]; then
    echo "post-image.sh: no dtc found (HOST_DIR/bin, kernel scripts/dtc, or PATH)" >&2
    exit 1
fi

export FROST_IMAGE="${BINARIES_DIR}/Image"
export FROST_INITRD="${BINARIES_DIR}/rootfs.cpio.gz"
export FROST_OUTDIR="${BINARIES_DIR}"
export FROST_CROSS_COMPILE="${cross_compile}"
export FROST_DTC="${dtc_path}"
# The boot shim is pure base-integer code (rv64i); use the Buildroot
# toolchain's own default -march/-mabi to avoid an ABI mismatch with its
# multilib layout (the standalone defaults, rv64i_zicsr with lp64, apply
# only when these are left unset entirely).
export FROST_SHIM_MARCH=""
export FROST_SHIM_MABI=""
export FPGA_CPU_CLK_FREQ="${FPGA_CPU_CLK_FREQ:-133333333}"

echo "post-image.sh: packaging FROST boot image"
echo "  Image  = ${FROST_IMAGE}"
echo "  initrd = ${FROST_INITRD}"
echo "  cross  = ${FROST_CROSS_COMPILE}"
echo "  dtc    = ${FROST_DTC}"
echo "  out    = ${FROST_OUTDIR}"

python3 "${BOARD_DIR}/build_fpga_boot.py"

# Apply mandatory initramfs fixups and env-gated bring-up hooks. QEMU boots
# Image+rootfs directly and does not consume sw_ddr.mem. The former
# ret_from_exception mutation was retired 2026-07-26; see patch_linux_image.py
# and sw/apps/restore_window_stress.
if [ -f "${BINARIES_DIR}/sw_ddr.mem" ]; then
    echo "post-image.sh: post-processing sw_ddr boot images"
    python3 "${BOARD_DIR}/patch_linux_image.py" \
        "${BINARIES_DIR}/sw_ddr.mem" "${BINARIES_DIR}/sw_ddr.txt"
fi

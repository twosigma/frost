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

# Buildroot post-image hook for the FROST MMU Linux lane (frost_rv64_defconfig).
#
# Buildroot runs this after the image stage with BINARIES_DIR, HOST_DIR, and
# BUILD_DIR exported. It builds the OpenSBI firmware from the linux/opensbi
# submodule with the lane's own (PIE-capable) toolchain, then packs
# firmware + Image + DTB + initramfs into the boot images with
# frost_boot_image.py:
#
#   $BINARIES_DIR/fw_jump.bin        OpenSBI fw_jump
#   $BINARIES_DIR/sw.{mem,txt}       low-BRAM boot shim
#   $BINARIES_DIR/sw_ddr.{mem,txt}   firmware + Image + DTB + initramfs in DDR
#   $BINARIES_DIR/frost.{dts,dtb}    the generated device tree
#
# Nothing is patched afterwards. CI stages sw.mem/sw_ddr.mem in
# sw/apps/linux_boot/; see linux/README.md for the boot ABI.

set -euo pipefail

BOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${BOARD_DIR}/../../../.." && pwd)"

: "${BINARIES_DIR:?BINARIES_DIR must be set (run me as a Buildroot post-image script)}"
: "${HOST_DIR:?HOST_DIR must be set (run me as a Buildroot post-image script)}"

# The lane's cross toolchain (Buildroot's external-toolchain wrapper links).
gcc_path="$(ls "${HOST_DIR}"/bin/riscv64-linux-gcc 2>/dev/null | head -n1 || true)"
if [ -z "${gcc_path}" ]; then
    echo "post-image-mmu.sh: no riscv64-linux-gcc found in ${HOST_DIR}/bin" >&2
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
    echo "post-image-mmu.sh: no dtc found (HOST_DIR/bin, kernel scripts/dtc, or PATH)" >&2
    exit 1
fi

echo "post-image-mmu.sh: building OpenSBI fw_jump with ${cross_compile}"
python3 "${REPO_ROOT}/linux/opensbi_build.py" \
    --out "${BINARIES_DIR}/opensbi" --cross "${cross_compile}"
cp "${BINARIES_DIR}/opensbi/platform/generic/firmware/fw_jump.bin" "${BINARIES_DIR}/fw_jump.bin"
cp "${BINARIES_DIR}/opensbi/platform/generic/firmware/fw_jump.elf" "${BINARIES_DIR}/fw_jump.elf"

echo "post-image-mmu.sh: packing the FROST boot image"
echo "  firmware = ${BINARIES_DIR}/fw_jump.bin"
echo "  Image    = ${BINARIES_DIR}/Image"
echo "  initrd   = ${BINARIES_DIR}/rootfs.cpio"
echo "  cross    = ${cross_compile}"
echo "  dtc      = ${dtc_path}"
echo "  clock    = ${FPGA_CPU_CLK_FREQ:-300000000} Hz"
# The shim is plain rv64i code; leave -march/-mabi to the toolchain's defaults
# so they match its multilib layout.
FROST_SHIM_MARCH="" FROST_SHIM_MABI="" \
python3 "${BOARD_DIR}/frost_boot_image.py" \
    --firmware "${BINARIES_DIR}/fw_jump.bin" \
    --payload "${BINARIES_DIR}/Image" \
    --initrd "${BINARIES_DIR}/rootfs.cpio" \
    --out "${BINARIES_DIR}" \
    --cross "${cross_compile}" \
    --dtc "${dtc_path}" \
    --clk "${FPGA_CPU_CLK_FREQ:-300000000}"

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

# Buildroot post-image hook for frost_rv64_defconfig.
#
# Buildroot exports BINARIES_DIR and HOST_DIR after the image stage. Build
# OpenSBI with its PIE-capable toolchain, stage Debian's kernel and the
# module-augmented initramfs via linux/debian_kernel.py, then run
# frost_boot_image.py. All outputs go to BINARIES_DIR.
#
# sw/apps/linux_boot packs its own boot images for each board load, from this
# build's fw_jump.bin and rootfs.cpio. For the boot interface, see
# linux/README.md, "Boot chain and entry state".

set -euo pipefail

BOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${BOARD_DIR}/../../../.." && pwd)"

: "${BINARIES_DIR:?BINARIES_DIR must be set (run me as a Buildroot post-image script)}"
: "${HOST_DIR:?HOST_DIR must be set (run me as a Buildroot post-image script)}"

# Buildroot's cross toolchain (its external-toolchain wrapper links).
gcc_path="$(ls "${HOST_DIR}"/bin/riscv64-linux-gcc 2>/dev/null | head -n1 || true)"
if [ -z "${gcc_path}" ]; then
    echo "post-image-mmu.sh: no riscv64-linux-gcc found in ${HOST_DIR}/bin" >&2
    exit 1
fi
cross_compile="${gcc_path%gcc}"

# Prefer HOST_DIR/bin/dtc, then PATH. Without a system dtc, enable
# BR2_PACKAGE_HOST_DTC=y; the frost image provides device-tree-compiler.
dtc_path="${HOST_DIR}/bin/dtc"
if [ ! -x "${dtc_path}" ]; then
    dtc_path="$(command -v dtc || true)"
fi
if [ -z "${dtc_path}" ]; then
    echo "post-image-mmu.sh: no dtc found (HOST_DIR/bin or PATH; set" \
        "BR2_PACKAGE_HOST_DTC=y to have Buildroot build one)" >&2
    exit 1
fi

echo "post-image-mmu.sh: building OpenSBI fw_jump with ${cross_compile}"
python3 "${REPO_ROOT}/linux/opensbi_build.py" \
    --out "${BINARIES_DIR}/opensbi" --cross "${cross_compile}"
cp "${BINARIES_DIR}/opensbi/platform/generic/firmware/fw_jump.bin" "${BINARIES_DIR}/fw_jump.bin"
cp "${BINARIES_DIR}/opensbi/platform/generic/firmware/fw_jump.elf" "${BINARIES_DIR}/fw_jump.elf"

echo "post-image-mmu.sh: staging Debian's kernel and the NIC module"
debian_kernel="${REPO_ROOT}/linux/debian_kernel.py"
# The helper reserves stdout for one path. Check it before copying.
debian_image="$(python3 "${debian_kernel}" image)"
if [ ! -f "${debian_image}" ]; then
    echo "post-image-mmu.sh: 'debian_kernel.py image' did not print one existing" \
        "path: ${debian_image}" >&2
    exit 1
fi
cp "${debian_image}" "${BINARIES_DIR}/Image-debian"
python3 "${debian_kernel}" --cross "${cross_compile}" initramfs \
    --base "${BINARIES_DIR}/rootfs.cpio" \
    --out "${BINARIES_DIR}/rootfs-frost.cpio"

echo "post-image-mmu.sh: packing the FROST boot image"
echo "  firmware = ${BINARIES_DIR}/fw_jump.bin"
echo "  Image    = ${BINARIES_DIR}/Image-debian ($(python3 "${debian_kernel}" release))"
echo "  initrd   = ${BINARIES_DIR}/rootfs-frost.cpio"
echo "  cross    = ${cross_compile}"
echo "  dtc      = ${dtc_path}"
echo "  clock    = ${FPGA_CPU_CLK_FREQ:-322265625} Hz"
# The shim is plain rv64i code; leave -march/-mabi to the toolchain's defaults
# so they match its multilib layout.
FROST_SHIM_MARCH="" FROST_SHIM_MABI="" \
python3 "${BOARD_DIR}/frost_boot_image.py" \
    --firmware "${BINARIES_DIR}/fw_jump.bin" \
    --payload "${BINARIES_DIR}/Image-debian" \
    --initrd "${BINARIES_DIR}/rootfs-frost.cpio" \
    --out "${BINARIES_DIR}" \
    --cross "${cross_compile}" \
    --dtc "${dtc_path}" \
    --clk "${FPGA_CPU_CLK_FREQ:-322265625}"

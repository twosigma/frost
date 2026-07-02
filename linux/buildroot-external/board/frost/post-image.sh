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

# Buildroot post-image hook for the FROST RV32 no-MMU Linux MVP.
#
# Buildroot runs this after the rootfs/image stage with BINARIES_DIR, HOST_DIR,
# BUILD_DIR (and BASE_DIR) exported. It locates the toolchain Buildroot just
# built and the device-tree compiler, then invokes build_fpga_boot.py to emit
# the FROST FPGA/sim memory images:
#
#   $BINARIES_DIR/sw.{mem,txt}       low-BRAM boot shim
#   $BINARIES_DIR/sw_ddr.{mem,txt}   kernel Image + DTB + initramfs in DDR
#
# CI then stages sw.mem / sw_ddr.mem into sw/apps/linux_boot/ for the cocotb
# linux_boot test (see linux/buildroot-external/README.md).

set -euo pipefail

BOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BINARIES_DIR:?BINARIES_DIR must be set (run me as a Buildroot post-image script)}"
: "${HOST_DIR:?HOST_DIR must be set (run me as a Buildroot post-image script)}"

# --- locate the rv32 cross toolchain Buildroot just produced ---
gcc_path="$(ls "${HOST_DIR}"/bin/riscv32-*-gcc 2>/dev/null | head -n1 || true)"
if [ -z "${gcc_path}" ]; then
    echo "post-image.sh: no riscv32-*-gcc found in ${HOST_DIR}/bin" >&2
    exit 1
fi
cross_compile="${gcc_path%gcc}"

# --- locate dtc: prefer the host build, fall back to the kernel's scripts/dtc ---
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
# The boot shim is pure rv32i integer code; use the Buildroot toolchain's own
# default -march/-mabi to avoid an ilp32-vs-ilp32d ABI mismatch (the standalone
# xPack default is rv32i_zicsr / ilp32, restored when these are unset).
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

# Apply the ret_from_exception M-mode restore-window software crutch to the
# packed DDR image. Required for the FROST core (cocotb sim + FPGA) until the
# RTL fix lands; idempotent (located by opcode, no-op if already patched).
# Harmless/irrelevant for QEMU, which boots Image+rootfs directly and never
# consumes sw_ddr.mem.
if [ -f "${BINARIES_DIR}/sw_ddr.mem" ]; then
    echo "post-image.sh: applying ret_from_exception M-mode-timer patch to sw_ddr"
    python3 "${BOARD_DIR}/patch_ret_from_exception.py" \
        "${BINARIES_DIR}/sw_ddr.mem" "${BINARIES_DIR}/sw_ddr.txt"
fi

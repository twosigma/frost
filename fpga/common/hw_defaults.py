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

"""Shared board defaults for FPGA hardware runners."""

import glob


def _get_vcu118_serial() -> str:
    # Match VCU118 onboard Silicon Labs CP2105 dual-UART bridge.
    # On VCU118, the FPGA UART console (pins BB21/AW25) connects to interface 1 (if01).
    matches_if01 = sorted(
        glob.glob("/dev/serial/by-id/usb-Silicon_Labs_CP2105*-if01-port0")
    )
    if matches_if01:
        return matches_if01[0]
    matches = sorted(glob.glob("/dev/serial/by-id/usb-Silicon_Labs_CP2105*-port0"))
    if matches:
        return matches[0]
    return "/dev/ttyUSB0"


class _BoardSerials(dict):
    def __getitem__(self, key: str) -> str:
        if key == "vcu118":
            return _get_vcu118_serial()
        return super().__getitem__(key)


# Match --target within the board vendor's targets. The X3 default selects one
# lab board by serial; override it for another board.
DEFAULT_TARGETS = {
    "x3": "localhost:3121/xilinx_tcf/Xilinx/507711333S8VAA",
    "vcu118": "localhost:3121/xilinx_tcf/Digilent",
}

# Default UART device per board (override with --serial, or --uart in
# linux_boot_soak.py). Resolves by-id for VCU118 to select CP2105 interface 1.
DEFAULT_SERIALS = _BoardSerials(
    {
        "x3": "/dev/ttyUSB3",
        "vcu118": "/dev/ttyUSB0",
    }
)

# Default per-application timeout per board, in seconds, including build and
# load time. --timeout replaces it; the CoreMark-PRO sweep raises either value
# to a workload's hardware_timeout_minimums entry (sw/apps/software_registry.py).
DEFAULT_TIMEOUTS = {
    "x3": 300.0,
    "vcu118": 300.0,
}

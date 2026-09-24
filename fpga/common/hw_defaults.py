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

# Default --target pattern per board for the hardware regression and the
# CoreMark-PRO sweep. Target selection keeps the board vendor's targets, then
# matches this pattern among them. The X3 default names one lab board by its
# serial; pass --target to select another board.
DEFAULT_TARGETS = {
    "x3": "localhost:3121/xilinx_tcf/Xilinx/507711333S8VAA",
}

# Default UART device per board (override with --serial, or --uart in
# linux_boot_soak.py).
DEFAULT_SERIALS = {
    "x3": "/dev/ttyUSB3",
}

# Default per-application timeout per board, in seconds, including build and
# load time. --timeout replaces it; the CoreMark-PRO sweep raises either value
# to a workload's hardware_timeout_minimums entry (sw/apps/software_registry.py).
DEFAULT_TIMEOUTS = {
    "x3": 300.0,
}

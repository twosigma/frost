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

# Default JTAG target pattern per board. load_software.py filters the targets
# by the board's vendor first, then matches this pattern within that list. X3
# pins the lab board's exact Xilinx serial. Pass --target to select another
# board of the same vendor.
DEFAULT_TARGETS = {
    "x3": "localhost:3121/xilinx_tcf/Xilinx/507711333S8VAA",
}

# Default UART device per board (override with --serial).
DEFAULT_SERIALS = {
    "x3": "/dev/ttyUSB3",
}

# Common per-app timeout budget per board, in seconds, build time included.
# --timeout overrides this base; workload policy may raise it to a calibrated
# hardware minimum when untimed setup is unusually long.
DEFAULT_TIMEOUTS = {
    "x3": 300.0,
}

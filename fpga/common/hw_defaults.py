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

# Default JTAG target pattern per board, passed through to load_software.py
# (which vendor-filters by board first, then matches this pattern). X3 pins the
# lab board's exact Xilinx serial; genesys2 falls back to the "Digilent" vendor
# substring, which resolves to the sole Digilent target. Pass --target when more
# than one board of a vendor is attached.
DEFAULT_TARGETS = {
    "x3": "localhost:3121/xilinx_tcf/Xilinx/507711333S8VAA",
    "genesys2": "Digilent",
}

# Default UART device per board (override with --serial).
DEFAULT_SERIALS = {
    "x3": "/dev/ttyUSB3",
    "genesys2": "/dev/ttyUSB0",
}

# Default per-app timeout (seconds, build included) per board. genesys2 runs at
# ~133 MHz vs X3's ~300 MHz, so the X3-calibrated workloads take roughly twice
# as long -- double the budget. Override with --timeout.
DEFAULT_TIMEOUTS = {
    "x3": 300.0,
    "genesys2": 600.0,
}

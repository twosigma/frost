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

"""Concurrent monitors that compare DUT outputs with expectations.

Monitors
--------
regfile_monitor
    Watches the register file output valid signal (o_vld) and checks x1-x31
    against the expected state when instructions retire. x0 reads as zero and
    is skipped.

fp_regfile_monitor
    Checks FP register file writes (f0-f31, all writeable).

pc_monitor
    Watches the program counter output valid signal (o_pc_vld) and checks the
    PC against the expected next PC for each instruction.

Memory writes have no monitor here. MemoryModel.driver_and_monitor checks them.

Monitors start with ``cocotb.start_soon()`` and run with the test loop:

1. Test loop generates instruction and computes expected result
2. Test loop queues expected value and drives instruction to DUT
3. Monitor waits for valid signal from DUT
4. Monitor pops expected value from queue and compares
5. Monitor raises AssertionError on mismatch

The decoupled queues accommodate variable pipeline latency.

Usage
-----
Test infrastructure starts monitors automatically::

    from monitors.monitors import regfile_monitor, pc_monitor

    cocotb.start_soon(regfile_monitor(dut, expected_regfile_queue))
    cocotb.start_soon(pc_monitor(dut, expected_pc_queue))
"""

from monitors.monitors import (
    regfile_monitor,
    fp_regfile_monitor,
    pc_monitor,
    Monitor,
    RegisterFileMonitor,
    ProgramCounterMonitor,
)

__all__ = [
    "regfile_monitor",
    "fp_regfile_monitor",
    "pc_monitor",
    "Monitor",
    "RegisterFileMonitor",
    "ProgramCounterMonitor",
]

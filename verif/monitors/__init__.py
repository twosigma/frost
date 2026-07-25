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

"""Runtime verification monitors for DUT output checking.

This package contains monitor coroutines that run concurrently with tests,
continuously checking that DUT outputs match expected values.

Monitors
--------
regfile_monitor
    Watches the register file output valid signal (o_vld) and verifies that
    all 32 register values match the expected state when instructions retire.

fp_regfile_monitor
    Verifies FP register file writes (f0-f31, all writeable). Imported from
    monitors.monitors directly; not re-exported by this package.

pc_monitor
    Watches the program counter output valid signal (o_pc_vld) and verifies
    that the PC value matches the expected next PC for each instruction.

(Memory monitoring is integrated into MemoryModel.driver_and_monitor)

How Monitors Work
-----------------
Monitors are async coroutines started with cocotb.start_soon() at test
initialization. They run in parallel with the main test loop:

1. Test loop generates instruction and computes expected result
2. Test loop queues expected value and drives instruction to DUT
3. Monitor waits for valid signal from DUT
4. Monitor pops expected value from queue and compares
5. Monitor raises AssertionError on mismatch

This decoupled approach handles variable pipeline latency gracefully.

Usage
-----
Monitors are started automatically by test infrastructure::

    from monitors.monitors import regfile_monitor, pc_monitor

    cocotb.start_soon(regfile_monitor(dut, expected_regfile_queue))
    cocotb.start_soon(pc_monitor(dut, expected_pc_queue))
"""

from monitors.monitors import (
    regfile_monitor,
    pc_monitor,
    Monitor,
    RegisterFileMonitor,
    ProgramCounterMonitor,
)

__all__ = [
    "regfile_monitor",
    "pc_monitor",
    "Monitor",
    "RegisterFileMonitor",
    "ProgramCounterMonitor",
]

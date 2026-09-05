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

"""Check synchronization, BER windows and reconciliation fault qualification.

Thresholds follow IEEE Clause49 and Clause46. The BER reset condition and timer
state transitions are reproduced in the IEEE presentation linked in the README;
these tests drive each monitor independently so one cannot hide another's error.
"""

from typing import Any

import cocotb
from cocotb.triggers import Timer

IDLE_COLUMN = 0x07070707
FAULT_COLUMNS = {1: 0x0100009C, 2: 0x0200009C}


class LinkBench:
    """Drive three independent monitors on a shared physical clock."""

    def __init__(self, dut: Any) -> None:
        """Initialize valid idle inputs for all three monitors."""
        self.dut = dut
        self.inputs = {
            "rst": 0,
            "signal_ok": 1,
            "block_valid": 0,
            "header": 1,
            "ber_locked": 0,
            "ber_valid": 0,
            "ber_header": 1,
            "fault_enable": 1,
            "pcs_ok": 1,
            "xgmii_data": 0x0707070707070707,
            "xgmii_ctrl": 0xFF,
        }

    async def step(self, **changes: int) -> int:
        """Apply changes and return combinational slip before the clock edge."""
        self.inputs.update(changes)
        self.dut.clk.value = 0
        for key, value in self.inputs.items():
            getattr(self.dut, key).value = value
        await Timer(5, unit="ns")
        slip = int(self.dut.slip.value)
        self.dut.clk.value = 1
        await Timer(5, unit="ns")
        return slip

    async def reset(self) -> None:
        """Reset all monitor state and leave the timer unstarted."""
        await self.step(rst=1)
        await self.step(rst=0)
        assert not int(self.dut.locked.value)
        assert not int(self.dut.high_ber_fast.value)
        assert not int(self.dut.high_ber_default.value)
        self.check_fault(0)

    def check_fault(self, expected: int) -> None:
        """Check mutually exclusive local and remote fault outputs."""
        assert int(self.dut.local_fault.value) == int(expected == 1)
        assert int(self.dut.remote_fault.value) == int(expected == 2)

    async def columns(self, first: int = 0, second: int = 0, **changes: int) -> None:
        """Send two independently selected idle/local/remote-fault columns."""
        first_data = FAULT_COLUMNS.get(first, IDLE_COLUMN)
        second_data = FAULT_COLUMNS.get(second, IDLE_COLUMN)
        ctrl = (1 if first else 15) | ((1 if second else 15) << 4)
        await self.step(
            xgmii_data=first_data | (second_data << 32), xgmii_ctrl=ctrl, **changes
        )


@cocotb.test()
async def block_acquisition_gating_slip_and_signal_loss(dut: Any) -> None:
    """Require 64 consecutive valid headers and same-candidate slip requests."""
    bench = LinkBench(dut)
    await bench.reset()
    for index in range(63):
        assert await bench.step(block_valid=1, header=1 + index % 2) == 0
        assert not int(dut.locked.value)
    for _ in range(50):
        assert await bench.step(block_valid=0, header=0) == 0
    assert not int(dut.locked.value)
    assert await bench.step(block_valid=1, header=3) == 1
    assert not int(dut.locked.value)
    for index in range(64):
        assert await bench.step(header=1 + index % 2) == 0
        assert int(dut.locked.value) == int(index == 63)
    assert await bench.step(signal_ok=0, block_valid=0) == 0
    assert not int(dut.locked.value)
    assert await bench.step(signal_ok=0, block_valid=1, header=0) == 0
    for index in range(64):
        await bench.step(signal_ok=1, header=1)
        assert int(dut.locked.value) == int(index == 63)


@cocotb.test()
async def block_loss_threshold_and_fixed_window_boundaries(dut: Any) -> None:
    """Distinguish the 16th error from 15 errors and reset counts every 64 blocks."""
    bench = LinkBench(dut)
    await bench.reset()
    for _ in range(64):
        await bench.step(block_valid=1, header=1)
    # End the first locked observation window with 15 errors. Those errors must
    # not leak into the next window, whose first 15 errors still preserve lock.
    for index in range(64):
        assert await bench.step(header=0 if index >= 49 else 2) == 0
        assert int(dut.locked.value)
    for index in range(15):
        assert await bench.step(header=index % 2 * 3) == 0
        assert int(dut.locked.value)
    for _ in range(10):
        assert await bench.step(block_valid=0, header=0) == 0
        assert int(dut.locked.value)
    assert await bench.step(block_valid=1, header=0) == 1
    assert not int(dut.locked.value)
    for _ in range(64):
        await bench.step(header=2)
    # The 16th error on the window's last candidate must beat window reset.
    for index in range(63):
        assert await bench.step(header=0 if index < 15 else 1) == 0
        assert int(dut.locked.value)
    assert await bench.step(header=3) == 1
    assert not int(dut.locked.value)


@cocotb.test()
async def ber_threshold_timing_and_lock_reset(dut: Any) -> None:
    """Check error threshold, physical-clock timer and reinitialization on unlock."""
    bench = LinkBench(dut)
    await bench.reset()
    for index in range(15):
        await bench.step(ber_locked=1, ber_valid=1, ber_header=0 if index % 2 else 3)
        assert not int(dut.high_ber_fast.value)
    # Invalid headers without block-valid never increment the error count.
    for _ in range(20):
        await bench.step(ber_valid=0)
        assert not int(dut.high_ber_fast.value)
    await bench.step(ber_valid=1)
    assert int(dut.high_ber_fast.value)
    # The alarm survives the end of the bad window and a full subsequent good
    # window is required for recovery. Valid gaps still advance the timer.
    for _ in range(128 - 36):
        await bench.step(ber_valid=0)
        assert int(dut.high_ber_fast.value)
    for _ in range(127):
        await bench.step()
        assert int(dut.high_ber_fast.value)
    await bench.step()
    assert not int(dut.high_ber_fast.value)
    for _ in range(16):
        await bench.step(ber_valid=1, ber_header=0)
    assert int(dut.high_ber_fast.value)
    await bench.step(ber_locked=0)
    assert not int(dut.high_ber_fast.value)
    assert not int(dut.high_ber_default.value)
    for _ in range(200):
        await bench.step()
        assert not int(dut.high_ber_fast.value)
    for _ in range(15):
        await bench.step(ber_locked=1)
        assert not int(dut.high_ber_fast.value)
    await bench.step()
    assert int(dut.high_ber_fast.value)


@cocotb.test()
async def ber_default_125_microsecond_window(dut: Any) -> None:
    """Verify the production 20142-clock timer, including a boundary error."""
    bench = LinkBench(dut)
    await bench.reset()
    # Fifteen errors in one complete production window must not carry forward.
    for index in range(20142):
        await bench.step(ber_locked=1, ber_valid=int(index < 15), ber_header=0)
        assert not int(dut.high_ber_default.value)
    # Put the sixteenth error exactly on the final clock of the next window.
    for index in range(20142):
        await bench.step(ber_valid=int(index < 15 or index == 20141))
        assert int(dut.high_ber_default.value) == int(index == 20141)
    for _ in range(20141):
        await bench.step(ber_valid=0)
        assert int(dut.high_ber_default.value)
    await bench.step()
    assert not int(dut.high_ber_default.value)


@cocotb.test()
async def fault_sequence_qualification_timeout_and_enable(dut: Any) -> None:
    """Qualify four sequences across both columns and clear after 128 quiet ones."""
    bench = LinkBench(dut)
    await bench.reset()
    # A fault in either column counts as one sequence; intervening idles do not
    # break qualification unless 128 consecutive columns pass without a fault.
    await bench.columns(1, 0)
    bench.check_fault(0)
    await bench.columns(0, 1)
    bench.check_fault(0)
    await bench.columns(1, 0)
    bench.check_fault(0)
    for _ in range(100):
        await bench.columns(1, 1, fault_enable=0)
        bench.check_fault(0)
    await bench.columns(0, 1, fault_enable=1)
    bench.check_fault(1)
    for _ in range(63):
        await bench.columns()
        bench.check_fault(1)
    await bench.columns()
    bench.check_fault(0)
    # Upper and lower columns both count, in lane order.
    await bench.columns(2, 2)
    bench.check_fault(0)
    await bench.columns(2, 2)
    bench.check_fault(2)
    await bench.columns(1, 1)
    bench.check_fault(2)
    await bench.columns(1, 1)
    bench.check_fault(1)


@cocotb.test()
async def fault_mixed_sequences_invalid_controls_pcs_loss_and_reset(dut: Any) -> None:
    """Reject mismatched sequence types and invalid ordered-set controls."""
    bench = LinkBench(dut)
    await bench.reset()
    for _ in range(30):
        await bench.columns(1, 2)
        bench.check_fault(0)
    for control in [0, 0x33, 0xFF]:
        for _ in range(3):
            await bench.step(xgmii_data=0x0100009C0100009C, xgmii_ctrl=control)
            bench.check_fault(0)
    for _ in range(3):
        # Last byte 03 is not an LF/RF sequence, despite proper /Q/ control.
        await bench.step(xgmii_data=0x0300009C0300009C, xgmii_ctrl=0x11)
        bench.check_fault(0)
    await bench.columns(2, 2)
    await bench.columns(2, 2)
    bench.check_fault(2)
    await bench.step(pcs_ok=0, fault_enable=0)
    bench.check_fault(1)
    await bench.step(pcs_ok=1)
    bench.check_fault(2)
    await bench.step(rst=1)
    bench.check_fault(0)
    await bench.columns(rst=0, fault_enable=1)
    bench.check_fault(0)
    # Timeout clears an incomplete qualification, not only active fault status.
    await bench.columns(1, 1)
    await bench.columns(0, 1)
    for _ in range(64):
        await bench.columns()
    await bench.columns(1, 0)
    bench.check_fault(0)

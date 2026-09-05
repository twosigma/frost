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

"""Check immediate RS fault response and suppression through packet boundaries."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

IDLE = (0x0707070707070707, 0xFF)
REMOTE_FAULT = (0x0200009C0200009C, 0x11)
START = (0xD5555555555555FB, 0x01)
PAYLOAD = (0x0123456789ABCDEF, 0x00)
TERMINATE = (0x0707070707FDCAFE, 0xFC)


class ReconcileBench:
    """Sample the combinational word before its consuming clock edge."""

    def __init__(self, dut: Any) -> None:
        """Initialize stimulus and enabled wire-word counts."""
        self.dut = dut
        self.starts = 0
        self.fault_words = 0
        self.idle_words = 0

    async def step(
        self,
        word: tuple[int, int] = IDLE,
        *,
        local: bool = False,
        remote: bool = False,
        enable: bool = True,
        reset: bool = False,
        expected: tuple[int, int] | None = None,
    ) -> tuple[int, int]:
        """Drive a source word and check the fault response before the edge."""
        dut = self.dut
        dut.i_clk.value = 0
        dut.i_rst.value = int(reset)
        dut.i_enable.value = int(enable)
        dut.i_local_fault.value = int(local)
        dut.i_remote_fault.value = int(remote)
        dut.i_xgmii_data.value = word[0]
        dut.i_xgmii_ctrl.value = word[1]
        await Timer(5, unit="ns")
        output = (int(dut.o_xgmii_data.value), int(dut.o_xgmii_ctrl.value))
        if expected is not None:
            assert output == expected, f"wire {output}, expected {expected}"
        if enable and not reset:
            self.starts += int(output == START)
            self.fault_words += int(output == REMOTE_FAULT)
            self.idle_words += int(output == IDLE)
        dut.i_clk.value = 1
        await Timer(5, unit="ns")
        return output

    async def reset(self) -> None:
        """Reset and establish the initial idle boundary."""
        await self.step(reset=True, expected=IDLE)
        await self.step(expected=IDLE)


@cocotb.test()
async def startup_and_normal_packets(dut: Any) -> None:
    """Require an enabled complete idle word before initial traffic passes."""
    bench = ReconcileBench(dut)
    await bench.step(START, reset=True, expected=IDLE)
    await bench.step(START, expected=IDLE)
    await bench.step(PAYLOAD, expected=IDLE)
    await bench.step(IDLE, enable=False, expected=IDLE)
    await bench.step(PAYLOAD, expected=IDLE)
    await bench.step(IDLE, expected=IDLE)
    for word in [START, PAYLOAD, PAYLOAD, TERMINATE, IDLE]:
        await bench.step(word, expected=word)
    assert bench.starts == 1
    assert bench.fault_words == 0


@cocotb.test()
async def abrupt_local_fault_never_exposes_a_packet_tail(dut: Any) -> None:
    """Override the faulting word immediately and recover after packet completion."""
    bench = ReconcileBench(dut)
    await bench.reset()
    await bench.step(START, expected=START)
    await bench.step(PAYLOAD, expected=PAYLOAD)
    await bench.step(PAYLOAD, local=True, expected=REMOTE_FAULT)
    # A one-clock fault can end long before the source packet finishes.
    for _ in range(20):
        await bench.step(PAYLOAD, expected=IDLE)
    await bench.step(TERMINATE, expected=IDLE)
    await bench.step(IDLE, expected=IDLE)
    for word in [START, PAYLOAD, TERMINATE, IDLE]:
        await bench.step(word, expected=word)
    assert bench.starts == 2
    assert bench.fault_words == 1


@cocotb.test()
async def remote_fault_priority_and_complete_idle_boundary(dut: Any) -> None:
    """Check fault priority and reject partial or malformed idle boundaries."""
    bench = ReconcileBench(dut)
    await bench.reset()
    await bench.step(START, expected=START)
    await bench.step(PAYLOAD, remote=True, expected=IDLE)
    await bench.step(PAYLOAD, remote=True, local=True, expected=REMOTE_FAULT)
    await bench.step(IDLE, remote=True, local=True, expected=REMOTE_FAULT)
    # Idles seen while either fault is asserted cannot release suppression.
    await bench.step(PAYLOAD, expected=IDLE)
    for word in [TERMINATE, (IDLE[0], 0xFE), (0x070707070707070E, 0xFF)]:
        await bench.step(word, expected=IDLE)
        await bench.step(PAYLOAD, expected=IDLE)
    await bench.step(IDLE, expected=IDLE)
    await bench.step(START, expected=START)
    assert bench.starts == 2
    assert bench.fault_words == 2


@cocotb.test()
async def disabled_word_cadence_remembers_fault_and_holds_recovery(dut: Any) -> None:
    """Remember a fault during a clock-enable pause and wait for consumed idle."""
    bench = ReconcileBench(dut)
    await bench.reset()
    await bench.step(START, expected=START)
    await bench.step(PAYLOAD, enable=False, local=True, expected=REMOTE_FAULT)
    await bench.step(PAYLOAD, enable=False, expected=IDLE)
    for _ in range(10):
        await bench.step(IDLE, enable=False, expected=IDLE)
    # Disabled idles cannot establish a wire-side packet boundary.
    await bench.step(PAYLOAD, expected=IDLE)
    await bench.step(TERMINATE, expected=IDLE)
    await bench.step(IDLE, expected=IDLE)
    await bench.step(START, expected=START)
    assert bench.starts == 2
    assert bench.fault_words == 0
    # Reset during a frame suppresses its remainder with enable low as well.
    await bench.step(PAYLOAD, enable=False, reset=True, expected=IDLE)
    await bench.step(PAYLOAD, expected=IDLE)
    await bench.step(IDLE, expected=IDLE)
    await bench.step(START, expected=START)
    assert bench.starts == 3

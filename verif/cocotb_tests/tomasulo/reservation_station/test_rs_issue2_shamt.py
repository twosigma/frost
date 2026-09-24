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

"""Tests for the port-1 shift amount of a dual-issue reservation station.

o_issue_shift_amount_2 is registered with port 1's operands: the immediate's
low six bits for an immediate shift or rotate, and the low six bits of the
final src2 value for a register shift or rotate. The DUT is the
reservation_station module itself.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from .rs_interface import RSInterface, unpack_rs_issue
from ..fu_shims.fp_add_shim_interface import _parse_instr_op_enum

OPS = _parse_instr_op_enum()
IMMEDIATE_OPS = {"SLLI", "SRLI", "SRAI", "RORI", "SLLIW", "SRLIW", "SRAIW", "RORIW"}
BARREL_OPS = (
    "SLL",
    "SRL",
    "SRA",
    "SLLI",
    "SRLI",
    "SRAI",
    "ROL",
    "ROR",
    "RORI",
    "SLLW",
    "SRLW",
    "SRAW",
    "SLLIW",
    "SRLIW",
    "SRAIW",
    "ROLW",
    "RORW",
    "RORIW",
)


def issue2(dut: Any) -> dict:
    """Unpack o_issue_2, including its payload while i_fu_ready_2 is low."""
    return unpack_rs_issue(int(dut.o_issue_2.value))


async def dispatch_pair(
    iface: RSInterface, name: str, amount: int, *, waiting: bool = False
) -> None:
    """Dispatch an ADD for port 0 and the tested operation for port 1.

    src2 carries amount and imm carries 63 - amount, while use_imm follows
    amount's low bit, so the captured amount shows which source was chosen.
    """
    iface.drive_dispatch(
        rob_tag=1,
        op=OPS["ADD"],
        src1_ready=True,
        src2_ready=True,
        src1_value=0x1111,
        src2_value=0x2222,
    )
    iface.drive_dispatch_2(
        intent_1=True,
        rob_tag=2,
        op=OPS[name],
        src1_ready=True,
        src1_value=0x8123_4567_89AB_CDEF,
        src2_ready=not waiting,
        src2_tag=19,
        src2_value=amount,
        imm=63 - amount,
        use_imm=bool(amount & 1),
    )
    await iface.step()
    iface.clear_dispatch()
    iface.clear_dispatch_2()
    await iface.step()


async def capture(iface: RSInterface) -> dict:
    """Raise i_fu_ready_2 and return the packet port 1 issues on the next edge.

    Port 0's i_fu_ready stays low, so port 1 issues on its own.
    """
    iface.dut.i_fu_ready_2.value = 1
    await iface.step()
    value = issue2(iface.dut)
    assert value["valid"] and value["rob_tag"] == 2
    return value


@cocotb.test()
async def test_every_barrel_amount_and_operation(dut: Any) -> None:
    """Check every shift and rotate that uses the barrel shifter at all 64 amounts."""
    Clock(dut.i_clk, 10, unit="ns").start()
    iface = RSInterface(dut)
    for name in BARREL_OPS:
        for amount in range(64):
            await iface.reset_dut()
            await dispatch_pair(iface, name, amount)
            packet = await capture(iface)
            assert packet["op"] == OPS[name]
            assert packet["src2_value"] == amount
            assert packet["imm"] == 63 - amount
            expected = 63 - amount if name in IMMEDIATE_OPS else amount
            assert int(dut.o_issue_shift_amount_2.value) == expected, (name, amount)


@cocotb.test()
async def test_live_cdb_hold_refill_and_flush(dut: Any) -> None:
    """Check CDB capture on both lanes, a held packet, refill, flushes, and reset.

    While port 1 is held, CDB traffic must not change its packet or amount.
    """
    Clock(dut.i_clk, 10, unit="ns").start()
    iface = RSInterface(dut)
    for lane in (0, 1):
        await iface.reset_dut()
        await dispatch_pair(iface, "SLL", 3, waiting=True)
        drive = iface.drive_cdb if lane == 0 else iface.drive_cdb_2
        drive(tag=19, value=0xAB00 + 41 + lane)
        packet = await capture(iface)
        assert packet["src2_value"] == 0xAB00 + 41 + lane
        assert int(dut.o_issue_shift_amount_2.value) == 41 + lane
        dut.i_fu_ready_2.value = 0
        for cycle in range(3):
            iface.drive_cdb(tag=19, value=cycle)
            iface.drive_cdb_2(tag=20, value=63 - cycle)
            await iface.step()
            held = issue2(dut)
            assert not held["valid"]
            assert held["src2_value"] == packet["src2_value"]
            assert int(dut.o_issue_shift_amount_2.value) == 41 + lane
        iface.clear_cdb()
        iface.clear_cdb_2()
        # A second port-1 candidate waits while port 1's stage 2 is held.
        iface.drive_dispatch(
            rob_tag=3,
            op=OPS["SRLI"],
            src1_ready=True,
            src2_ready=True,
            src2_value=9,
            imm=57,
            use_imm=False,
        )
        await iface.step()
        iface.clear_dispatch()
        await iface.step()
        dut.i_fu_ready_2.value = 1
        await Timer(1, unit="ns")
        assert issue2(dut)["rob_tag"] == 2  # held packet, accepted at the next edge
        await iface.step()
        assert issue2(dut)["valid"] and issue2(dut)["rob_tag"] == 3
        assert int(dut.o_issue_shift_amount_2.value) == 57
        dut.i_fu_ready_2.value = 0
        iface.drive_partial_flush(flush_tag=1, head_tag=0)
        await iface.step()
        iface.clear_partial_flush()
        dut.i_fu_ready_2.value = 1
        await Timer(1, unit="ns")
        assert not issue2(dut)["valid"]
        await iface.reset_dut()
        await dispatch_pair(iface, "RORI", 2)
        await capture(iface)
        iface.drive_flush_all()
        await iface.step()
        assert not issue2(dut)["valid"]
        iface.clear_flush_all()
        await iface.reset_dut()
        await dispatch_pair(iface, "SRAW", 35)
        await capture(iface)
        # Reset while port 1's stage 2 is full: its packet must not issue.
        await iface.reset_dut()
        dut.i_fu_ready_2.value = 1
        await Timer(1, unit="ns")
        assert not issue2(dut)["valid"]

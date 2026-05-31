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

"""Unit tests for the extracted CPU OOO commit action block."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_interface import COMMIT_FIELDS


CLOCK_PERIOD_NS = 10
MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1


def pack_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_commit_t struct value from named fields."""
    value = 0
    offset = sum(width for _, width in COMMIT_FIELDS)
    for name, width in COMMIT_FIELDS:
        offset -= width
        raw = int(fields.get(name, 0))
        value |= (raw & ((1 << width) - 1)) << offset
    return value


async def setup_test(dut: Any) -> None:
    """Start clock, reset state, and clear all inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_rob_commit.value = 0
    dut.i_rob_commit_2.value = 0
    dut.i_rob_commit_valid.value = 0
    dut.i_csr_read_data.value = 0
    dut.i_trap_taken.value = 0
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await Timer(1, unit="ns")


def drive_commit(
    dut: Any,
    *,
    slot1: Mapping[str, int | bool] | None = None,
    slot2: Mapping[str, int | bool] | None = None,
    rob_commit_valid: bool | None = None,
) -> None:
    """Drive slot-1 and slot-2 ROB commit inputs."""
    slot1_fields = dict(slot1 or {})
    slot2_fields = dict(slot2 or {})
    if rob_commit_valid is None:
        rob_commit_valid = bool(slot1_fields.get("valid", False))
    dut.i_rob_commit.value = pack_commit(slot1_fields)
    dut.i_rob_commit_2.value = pack_commit(slot2_fields)
    dut.i_rob_commit_valid.value = 1 if rob_commit_valid else 0


def clear_commit(dut: Any) -> None:
    """Clear ROB commit inputs."""
    drive_commit(dut)


def assert_port0_idle(dut: Any) -> None:
    """Assert that commit write port 0 is idle."""
    assert not dut.o_port0_int_we.value
    assert not dut.o_port0_fp_we.value


def assert_port1_idle(dut: Any) -> None:
    """Assert that commit write port 1 is idle."""
    assert not dut.o_port1_int_we.value
    assert not dut.o_port1_fp_we.value


@cocotb.test()
async def test_slot1_int_commit_writes_port0(dut: Any) -> None:
    """Slot-1 integer commit writes port 0 and retires one instruction."""
    await setup_test(dut)

    drive_commit(
        dut,
        slot1={
            "valid": True,
            "dest_valid": True,
            "dest_reg": 5,
            "value": 0x123456789ABCDEF0,
        },
    )
    await Timer(1, unit="ns")

    assert dut.o_port0_int_we.value
    assert int(dut.o_port0_int_addr.value) == 5
    assert int(dut.o_port0_int_data.value) == 0x9ABCDEF0
    assert not dut.o_port0_fp_we.value
    assert_port1_idle(dut)
    assert dut.o_vld.value
    assert dut.o_pc_vld.value
    assert int(dut.o_instruction_retired_count.value) == 1


@cocotb.test()
async def test_slot1_fp_commit_writes_port0_fp(dut: Any) -> None:
    """Slot-1 FP commit writes the FP port-0 outputs."""
    await setup_test(dut)

    value = 0x400921FB54442D18
    drive_commit(
        dut,
        slot1={
            "valid": True,
            "dest_rf": 1,
            "dest_valid": True,
            "dest_reg": 12,
            "value": value,
        },
    )
    await Timer(1, unit="ns")

    assert dut.o_port0_fp_we.value
    assert int(dut.o_port0_fp_addr.value) == 12
    assert int(dut.o_port0_fp_data.value) == value
    assert not dut.o_port0_int_we.value
    assert_port1_idle(dut)
    assert int(dut.o_instruction_retired_count.value) == 1


@cocotb.test()
async def test_slot2_int_commit_writes_port1_and_dual_retires(dut: Any) -> None:
    """Slot-2 integer commit writes port 1 while slot 1 retires."""
    await setup_test(dut)

    drive_commit(
        dut,
        slot1={
            "valid": True,
            "dest_valid": True,
            "dest_reg": 1,
            "value": 0x11111111,
        },
        slot2={
            "valid": True,
            "dest_valid": True,
            "dest_reg": 7,
            "value": 0xDEADBEEFCAFEBABE,
        },
    )
    await Timer(1, unit="ns")

    assert dut.o_port0_int_we.value
    assert int(dut.o_port0_int_addr.value) == 1
    assert int(dut.o_port0_int_data.value) == 0x11111111
    assert dut.o_port1_int_we.value
    assert int(dut.o_port1_int_addr.value) == 7
    assert int(dut.o_port1_int_data.value) == 0xCAFEBABE
    assert not dut.o_port1_fp_we.value
    assert int(dut.o_instruction_retired_count.value) == 2


@cocotb.test()
async def test_slot2_fp_commit_writes_port1_fp(dut: Any) -> None:
    """Slot-2 FP commit writes the FP port-1 outputs."""
    await setup_test(dut)

    value = 0x3FF0000000000000
    drive_commit(
        dut,
        slot1={"valid": True},
        slot2={
            "valid": True,
            "dest_rf": 1,
            "dest_valid": True,
            "dest_reg": 3,
            "value": value,
        },
    )
    await Timer(1, unit="ns")

    assert not dut.o_port1_int_we.value
    assert dut.o_port1_fp_we.value
    assert int(dut.o_port1_fp_addr.value) == 3
    assert int(dut.o_port1_fp_data.value) == value
    assert int(dut.o_instruction_retired_count.value) == 2


@cocotb.test()
async def test_exception_and_trap_suppress_retire_count(dut: Any) -> None:
    """Exceptions and trap-taken cycles do not increment instret."""
    await setup_test(dut)

    drive_commit(
        dut,
        slot1={
            "valid": True,
            "dest_valid": True,
            "exception": True,
            "dest_reg": 4,
            "value": 0x5555,
        },
    )
    await Timer(1, unit="ns")

    assert not dut.o_vld.value
    assert not dut.o_pc_vld.value
    assert int(dut.o_instruction_retired_count.value) == 0
    assert_port0_idle(dut)

    drive_commit(dut, slot1={"valid": True})
    dut.i_trap_taken.value = 1
    await Timer(1, unit="ns")

    assert dut.o_vld.value
    assert int(dut.o_instruction_retired_count.value) == 0


@cocotb.test()
async def test_csr_delayed_writeback_uses_port0(dut: Any) -> None:
    """CSR commits schedule a delayed port-0 integer writeback."""
    await setup_test(dut)

    drive_commit(
        dut,
        slot1={
            "valid": True,
            "dest_valid": True,
            "dest_reg": 9,
            "is_csr": True,
        },
    )
    await Timer(1, unit="ns")

    assert dut.o_csr_commit_fire.value
    assert not dut.o_port0_int_we.value
    assert int(dut.o_instruction_retired_count.value) == 1

    await RisingEdge(dut.i_clk)
    clear_commit(dut)
    dut.i_csr_read_data.value = 0xA5A55A5A
    await Timer(1, unit="ns")

    assert dut.o_csr_wb_pending.value
    assert dut.o_port0_int_we.value
    assert int(dut.o_port0_int_addr.value) == 9
    assert int(dut.o_port0_int_data.value) == 0xA5A55A5A
    assert_port1_idle(dut)

    clear_commit(dut)

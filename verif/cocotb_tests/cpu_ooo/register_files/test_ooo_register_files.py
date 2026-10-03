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

"""Unit tests for the CPU OOO architectural register files."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tests.cpu_structs import ID_TO_EX_FIELDS
from utils.packed_structs import pack_struct as _pack_struct


CLOCK_PERIOD_NS = 10


def _pack_id_to_ex(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_id_to_ex_t value."""
    return _pack_struct(ID_TO_EX_FIELDS, fields)


def _make_instr(
    *,
    source_reg_1: int = 0,
    source_reg_2: int = 0,
    fp_source_reg_3: int = 0,
) -> int:
    """Build the source-register fields used by ooo_register_files."""
    return (
        ((fp_source_reg_3 & 0x1F) << 27)
        | ((source_reg_2 & 0x1F) << 20)
        | ((source_reg_1 & 0x1F) << 15)
    )


def _int_reads(dut: Any) -> tuple[int, int, int, int]:
    """Return the INT dispatch reads (slot-1 rs1, rs2, slot-2 rs1, rs2)."""
    return (
        int(dut.o_int_rf_dispatch_rs1_data.value),
        int(dut.o_int_rf_dispatch_rs2_data.value),
        int(dut.o_int_rf_dispatch_rs1_data_2.value),
        int(dut.o_int_rf_dispatch_rs2_data_2.value),
    )


def _fp_reads(dut: Any) -> tuple[int, int, int, int, int, int]:
    """Return the FP dispatch reads (slot-1 rs1..rs3, slot-2 rs1..rs3)."""
    return (
        int(dut.o_fp_rf_dispatch_rs1_data.value),
        int(dut.o_fp_rf_dispatch_rs2_data.value),
        int(dut.o_fp_rf_dispatch_rs3_data.value),
        int(dut.o_fp_rf_dispatch_rs1_data_2.value),
        int(dut.o_fp_rf_dispatch_rs2_data_2.value),
        int(dut.o_fp_rf_dispatch_rs3_data_2.value),
    )


def _drive_ex_slot(
    dut: Any,
    *,
    rs1: int = 0,
    rs2: int = 0,
    fp_rs3: int = 0,
    slot2: bool = False,
) -> None:
    """Drive an ID-to-EX slot with dispatch read source fields."""
    value = _pack_id_to_ex(
        {
            "instruction": _make_instr(
                source_reg_1=rs1,
                source_reg_2=rs2,
                fp_source_reg_3=fp_rs3,
            )
        }
    )
    if slot2:
        dut.i_from_id_to_ex_2.value = value
    else:
        dut.i_from_id_to_ex.value = value


def _clear_writes(dut: Any) -> None:
    """Clear all commit write ports (and their bypass qualifiers)."""
    dut.i_port0_int_we.value = 0
    dut.i_port0_int_addr.value = 0
    dut.i_port0_int_data.value = 0
    dut.i_port1_int_we.value = 0
    dut.i_port1_int_addr.value = 0
    dut.i_port1_int_data.value = 0
    dut.i_port0_fp_we.value = 0
    dut.i_port0_fp_addr.value = 0
    dut.i_port0_fp_data.value = 0
    dut.i_port1_fp_we.value = 0
    dut.i_port1_fp_addr.value = 0
    dut.i_port1_fp_data.value = 0
    dut.i_bypass_p0_int_we.value = 0
    dut.i_bypass_p1_int_we.value = 0
    dut.i_bypass_p0_fp_we.value = 0
    dut.i_bypass_p1_fp_we.value = 0
    dut.i_bypass_p0_addr.value = 0
    dut.i_bypass_p1_addr.value = 0


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    _clear_writes(dut)
    _drive_ex_slot(dut)
    _drive_ex_slot(dut, slot2=True)


def _drive_int_write(
    dut: Any,
    *,
    port: int,
    addr: int,
    data: int,
    enable: bool = True,
) -> None:
    """Drive one integer commit write port.

    Mirrors cpu_ooo's invariant onto the pre-registered bypass qualifiers:
    i_bypass_pN_int_we == we && |addr, i_bypass_pN_addr == addr.
    """
    prefix = f"i_port{port}_int"
    getattr(dut, f"{prefix}_we").value = int(enable)
    getattr(dut, f"{prefix}_addr").value = addr
    getattr(dut, f"{prefix}_data").value = data
    getattr(dut, f"i_bypass_p{port}_int_we").value = int(enable and addr != 0)
    getattr(dut, f"i_bypass_p{port}_addr").value = addr


def _drive_fp_write(
    dut: Any,
    *,
    port: int,
    addr: int,
    data: int,
    enable: bool = True,
) -> None:
    """Drive one FP commit write port.

    Mirrors cpu_ooo's invariant onto the pre-registered bypass qualifiers:
    i_bypass_pN_fp_we == we, i_bypass_pN_addr == addr.
    """
    prefix = f"i_port{port}_fp"
    getattr(dut, f"{prefix}_we").value = int(enable)
    getattr(dut, f"{prefix}_addr").value = addr
    getattr(dut, f"{prefix}_data").value = data
    getattr(dut, f"i_bypass_p{port}_fp_we").value = int(enable)
    getattr(dut, f"i_bypass_p{port}_addr").value = addr


async def _setup_test(dut: Any) -> None:
    """Start the clock and initialize inputs."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut)
    await Timer(1, unit="ns")


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _commit_writes(dut: Any) -> None:
    """Clock in currently-driven writes and clear the write ports."""
    await _advance_cycle(dut)
    _clear_writes(dut)
    await _settle()


def _drive_all_int_reads(dut: Any, *, rs1: int, rs2: int) -> None:
    """Drive both INT slots to read the same source pair."""
    _drive_ex_slot(dut, rs1=rs1, rs2=rs2)
    _drive_ex_slot(dut, rs1=rs1, rs2=rs2, slot2=True)


def _drive_all_fp_reads(dut: Any, *, rs1: int, rs2: int, rs3: int) -> None:
    """Drive both FP slots to read the same source triple."""
    _drive_ex_slot(dut, rs1=rs1, rs2=rs2, fp_rs3=rs3)
    _drive_ex_slot(dut, rs1=rs1, rs2=rs2, fp_rs3=rs3, slot2=True)


@cocotb.test()
async def test_integer_register_reads_reach_both_slots(dut: Any) -> None:
    """Each INT dispatch read returns its own slot's source register."""
    await _setup_test(dut)

    _drive_int_write(dut, port=0, addr=5, data=0x11112222)
    _drive_int_write(dut, port=1, addr=6, data=0x33334444)
    await _commit_writes(dut)
    _drive_int_write(dut, port=0, addr=7, data=0x55556666)
    _drive_int_write(dut, port=1, addr=8, data=0x77778888)
    await _commit_writes(dut)

    _drive_ex_slot(dut, rs1=5, rs2=6)
    _drive_ex_slot(dut, rs1=7, rs2=8, slot2=True)
    await _settle()

    assert _int_reads(dut) == (0x11112222, 0x33334444, 0x55556666, 0x77778888)


@cocotb.test()
async def test_integer_bypass_reaches_each_read_port(dut: Any) -> None:
    """A same-cycle commit on either write port bypasses to each INT read that names it."""
    await _setup_test(dut)

    _drive_ex_slot(dut, rs1=10, rs2=11)
    _drive_ex_slot(dut, rs1=11, rs2=10, slot2=True)
    _drive_int_write(dut, port=0, addr=10, data=0xAAAA0000)
    _drive_int_write(dut, port=1, addr=11, data=0xBBBB1111)
    await _settle()

    assert _int_reads(dut) == (0xAAAA0000, 0xBBBB1111, 0xBBBB1111, 0xAAAA0000)

    await _commit_writes(dut)

    assert _int_reads(dut) == (0xAAAA0000, 0xBBBB1111, 0xBBBB1111, 0xAAAA0000)


@cocotb.test()
async def test_integer_same_cycle_bypass_prefers_port1(dut: Any) -> None:
    """INT same-cycle bypass chooses slot-2/port-1 data on same-address writes."""
    await _setup_test(dut)

    _drive_all_int_reads(dut, rs1=7, rs2=7)
    _drive_int_write(dut, port=0, addr=7, data=0xAAAA0000)
    _drive_int_write(dut, port=1, addr=7, data=0xBBBB1111)
    await _settle()

    assert _int_reads(dut) == (0xBBBB1111,) * 4

    await _commit_writes(dut)
    await _settle()

    assert _int_reads(dut) == (0xBBBB1111,) * 4


@cocotb.test()
async def test_integer_x0_write_is_not_bypassed_or_stored(dut: Any) -> None:
    """INT x0 ignores writes and suppresses same-cycle writeback bypass."""
    await _setup_test(dut)

    _drive_all_int_reads(dut, rs1=0, rs2=0)
    _drive_int_write(dut, port=0, addr=0, data=0x12345678)
    _drive_int_write(dut, port=1, addr=0, data=0x87654321)
    await _settle()

    assert _int_reads(dut) == (0, 0, 0, 0)

    await _commit_writes(dut)

    assert _int_reads(dut) == (0, 0, 0, 0)


@cocotb.test()
async def test_fp_register_reads_reach_all_sources_and_slots(dut: Any) -> None:
    """Each FP dispatch read returns its own slot's source register, rs3 included."""
    await _setup_test(dut)

    values = {
        3: 0x1111222233334444,
        4: 0x5555666677778888,
        5: 0x9999AAAABBBBCCCC,
        6: 0x0123456789ABCDEF,
        7: 0xFEDCBA9876543210,
        8: 0x0F1E2D3C4B5A6978,
    }
    regs = list(values)
    for port0_addr, port1_addr in zip(regs[0::2], regs[1::2]):
        _drive_fp_write(dut, port=0, addr=port0_addr, data=values[port0_addr])
        _drive_fp_write(dut, port=1, addr=port1_addr, data=values[port1_addr])
        await _commit_writes(dut)

    _drive_ex_slot(dut, rs1=3, rs2=4, fp_rs3=5)
    _drive_ex_slot(dut, rs1=6, rs2=7, fp_rs3=8, slot2=True)
    await _settle()

    assert _fp_reads(dut) == tuple(values[r] for r in regs)


@cocotb.test()
async def test_fp_same_cycle_bypass_prefers_port1(dut: Any) -> None:
    """FP same-cycle bypass chooses slot-2/port-1 data on same-address writes."""
    await _setup_test(dut)

    _drive_all_fp_reads(dut, rs1=9, rs2=9, rs3=9)
    _drive_fp_write(dut, port=0, addr=9, data=0xAAAABBBBCCCCDDDD)
    _drive_fp_write(dut, port=1, addr=9, data=0x1111222233334444)
    await _settle()

    assert _fp_reads(dut) == (0x1111222233334444,) * 6

    await _commit_writes(dut)

    assert _fp_reads(dut) == (0x1111222233334444,) * 6


@cocotb.test()
async def test_fp_bypass_reaches_each_read_port(dut: Any) -> None:
    """A same-cycle commit on either write port bypasses to each FP read that names it."""
    await _setup_test(dut)

    port0_data = 0xAAAABBBBCCCCDDDD
    port1_data = 0x1111222233334444
    _drive_ex_slot(dut, rs1=12, rs2=13, fp_rs3=12)
    _drive_ex_slot(dut, rs1=13, rs2=12, fp_rs3=13, slot2=True)
    _drive_fp_write(dut, port=0, addr=12, data=port0_data)
    _drive_fp_write(dut, port=1, addr=13, data=port1_data)
    await _settle()

    expected = (port0_data, port1_data, port0_data, port1_data, port0_data, port1_data)
    assert _fp_reads(dut) == expected

    await _commit_writes(dut)

    assert _fp_reads(dut) == expected


@cocotb.test()
async def test_fp_register_zero_is_written_and_bypassed(dut: Any) -> None:
    """FP f0 is a normal register, unlike integer x0."""
    await _setup_test(dut)

    _drive_all_fp_reads(dut, rs1=0, rs2=0, rs3=0)
    _drive_fp_write(dut, port=0, addr=0, data=0x0102030405060708)
    await _settle()

    assert _fp_reads(dut) == (0x0102030405060708,) * 6

    await _commit_writes(dut)

    assert _fp_reads(dut) == (0x0102030405060708,) * 6

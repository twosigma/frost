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

"""Unit tests for the IF-stage RAS instruction detector."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


OPC_JAL = 0b1101111
OPC_JALR = 0b1100111
OPC_OP_IMM = 0b0010011


def _make_instr(
    *,
    funct7: int = 0,
    rs2: int = 0,
    rs1: int = 0,
    funct3: int = 0,
    rd: int = 0,
    opcode: int = 0,
) -> int:
    """Pack an instr_t-compatible RISC-V instruction word."""
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def _make_jal(*, rd: int) -> int:
    """Build a JAL instruction with only detector-relevant fields set."""
    return _make_instr(rd=rd, opcode=OPC_JAL)


def _make_jalr(*, rd: int, rs1: int, imm: int = 0, funct3: int = 0) -> int:
    """Build a JALR instruction with detector-relevant fields set."""
    return _make_instr(
        funct7=(imm >> 5) & 0x7F,
        rs2=imm & 0x1F,
        rs1=rs1,
        funct3=funct3,
        rd=rd,
        opcode=OPC_JALR,
    )


def _make_c_jr(*, rs1: int) -> int:
    """Build a compressed C.JR raw parcel."""
    return (0b1000 << 12) | ((rs1 & 0x1F) << 7) | 0b10


def _make_c_jalr(*, rs1: int) -> int:
    """Build a compressed C.JALR raw parcel."""
    return (0b1001 << 12) | ((rs1 & 0x1F) << 7) | 0b10


def _make_c_jal() -> int:
    """Build a detector-recognized compressed C.JAL raw parcel."""
    return (0b001 << 13) | 0b01


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


def _drive(
    dut: Any,
    *,
    instruction: int = 0,
    raw_parcel: int = 0,
    compressed: bool = False,
    valid: bool = True,
) -> None:
    """Drive detector inputs."""
    dut.i_instruction.value = instruction
    dut.i_raw_parcel.value = raw_parcel
    dut.i_is_compressed.value = int(compressed)
    dut.i_instruction_valid.value = int(valid)


def _assert_classification(
    dut: Any,
    *,
    call: bool = False,
    ret: bool = False,
    coroutine: bool = False,
) -> None:
    """Assert detector outputs."""
    assert bool(dut.o_is_call.value) is call
    assert bool(dut.o_is_return.value) is ret
    assert bool(dut.o_is_coroutine.value) is coroutine


@cocotb.test()
async def test_invalid_instruction_suppresses_all_outputs(dut: Any) -> None:
    """Invalid instructions do not classify as RAS operations."""
    _drive(dut, instruction=_make_jal(rd=1), valid=False)
    await _settle()

    _assert_classification(dut)


@cocotb.test()
async def test_32bit_jal_and_jalr_calls_use_link_register_dests(dut: Any) -> None:
    """JAL/JALR calls require rd to be x1 or x5."""
    for rd in (1, 5):
        _drive(dut, instruction=_make_jal(rd=rd))
        await _settle()
        _assert_classification(dut, call=True)

        _drive(dut, instruction=_make_jalr(rd=rd, rs1=10))
        await _settle()
        _assert_classification(dut, call=True)

    _drive(dut, instruction=_make_jal(rd=2))
    await _settle()
    _assert_classification(dut)


@cocotb.test()
async def test_32bit_return_requires_jalr_x0_x1_zero_imm(dut: Any) -> None:
    """Returns are only JALR x0, x1, 0."""
    _drive(dut, instruction=_make_jalr(rd=0, rs1=1))
    await _settle()
    _assert_classification(dut, ret=True)

    for instruction in (
        _make_jalr(rd=0, rs1=5),
        _make_jalr(rd=0, rs1=1, imm=4),
        _make_jalr(rd=0, rs1=1, funct3=1),
    ):
        _drive(dut, instruction=instruction)
        await _settle()
        _assert_classification(dut)


@cocotb.test()
async def test_32bit_coroutine_requires_jalr_link_rd_from_x1(dut: Any) -> None:
    """Coroutine hints are JALR with link rd, rs1=x1, rd!=rs1, and zero imm."""
    _drive(dut, instruction=_make_jalr(rd=5, rs1=1))
    await _settle()
    _assert_classification(dut, call=True, coroutine=True)

    for instruction in (
        _make_jalr(rd=1, rs1=1),
        _make_jalr(rd=5, rs1=5),
        _make_jalr(rd=5, rs1=1, imm=1),
    ):
        _drive(dut, instruction=instruction)
        await _settle()
        _assert_classification(dut, call=True)


@cocotb.test()
async def test_compressed_call_return_and_coroutine_classification(dut: Any) -> None:
    """Compressed C.JAL/C.JALR call and C.JR return rules are recognized."""
    _drive(dut, raw_parcel=_make_c_jal(), compressed=True)
    await _settle()
    _assert_classification(dut, call=True)

    _drive(dut, raw_parcel=_make_c_jalr(rs1=5), compressed=True)
    await _settle()
    _assert_classification(dut, call=True)

    _drive(dut, raw_parcel=_make_c_jr(rs1=1), compressed=True)
    await _settle()
    _assert_classification(dut, ret=True)

    for raw_parcel in (_make_c_jr(rs1=5), _make_c_jalr(rs1=1), _make_c_jr(rs1=0)):
        _drive(dut, raw_parcel=raw_parcel, compressed=True)
        await _settle()
        expected_call = raw_parcel == _make_c_jalr(rs1=1)
        _assert_classification(dut, call=expected_call)


@cocotb.test()
async def test_compressed_mode_ignores_32bit_instruction_fields(dut: Any) -> None:
    """Compressed classification uses the raw parcel instead of instr_t fields."""
    _drive(
        dut,
        instruction=_make_jal(rd=1),
        raw_parcel=0,
        compressed=True,
    )
    await _settle()

    _assert_classification(dut)

    _drive(
        dut,
        instruction=_make_instr(opcode=OPC_OP_IMM),
        raw_parcel=_make_c_jr(rs1=1),
        compressed=True,
    )
    await _settle()

    _assert_classification(dut, ret=True)

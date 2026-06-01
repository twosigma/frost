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

"""Unit tests for the EX-stage branch/jump resolution unit."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


MASK32 = 0xFFFFFFFF

BREQ = 0
BRNE = 1
BRLT = 2
BRGE = 3
BRLTU = 4
BRGEU = 5
JUMP = 6
BR_NULL = 7

BRANCH_TARGET = 0x80001000
JAL_TARGET = 0x80002000


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


def _u32(value: int) -> int:
    """Return a value masked to 32 bits."""
    return value & MASK32


def _drive(
    dut: Any,
    *,
    branch_operation: int = BR_NULL,
    is_jal: bool = False,
    is_jalr: bool = False,
    operand_a: int = 0,
    operand_b: int = 0,
    branch_target: int = BRANCH_TARGET,
    jal_target: int = JAL_TARGET,
    immediate_i: int = 0,
) -> None:
    """Drive one branch/jump resolution scenario."""
    dut.i_branch_operation.value = branch_operation
    dut.i_is_jump_and_link.value = int(is_jal)
    dut.i_is_jump_and_link_register.value = int(is_jalr)
    dut.i_operand_a.value = _u32(operand_a)
    dut.i_operand_b.value = _u32(operand_b)
    dut.i_branch_target_precomputed.value = _u32(branch_target)
    dut.i_jal_target_precomputed.value = _u32(jal_target)
    dut.i_immediate_i_type.value = _u32(immediate_i)


def _assert_outputs(dut: Any, *, taken: bool, target: int) -> None:
    """Assert the resolved branch decision and target address."""
    assert bool(dut.o_branch_taken.value) is taken
    assert int(dut.o_branch_target_address.value) == _u32(target)


@cocotb.test()
async def test_equal_and_not_equal_branches(dut: Any) -> None:
    """BEQ and BNE resolve from the shared equality comparator."""
    _drive(dut, branch_operation=BREQ, operand_a=0x12345678, operand_b=0x12345678)
    await _settle()
    _assert_outputs(dut, taken=True, target=BRANCH_TARGET)

    _drive(dut, branch_operation=BREQ, operand_a=0x12345678, operand_b=0x87654321)
    await _settle()
    _assert_outputs(dut, taken=False, target=BRANCH_TARGET)

    _drive(dut, branch_operation=BRNE, operand_a=0x12345678, operand_b=0x87654321)
    await _settle()
    _assert_outputs(dut, taken=True, target=BRANCH_TARGET)

    _drive(dut, branch_operation=BRNE, operand_a=0x12345678, operand_b=0x12345678)
    await _settle()
    _assert_outputs(dut, taken=False, target=BRANCH_TARGET)


@cocotb.test()
async def test_signed_branch_comparisons(dut: Any) -> None:
    """BLT and BGE use signed comparisons of the operands."""
    _drive(dut, branch_operation=BRLT, operand_a=0xFFFFFFFF, operand_b=1)
    await _settle()
    _assert_outputs(dut, taken=True, target=BRANCH_TARGET)

    _drive(dut, branch_operation=BRGE, operand_a=0xFFFFFFFF, operand_b=1)
    await _settle()
    _assert_outputs(dut, taken=False, target=BRANCH_TARGET)

    _drive(dut, branch_operation=BRGE, operand_a=0, operand_b=0xFFFFFFFF)
    await _settle()
    _assert_outputs(dut, taken=True, target=BRANCH_TARGET)


@cocotb.test()
async def test_unsigned_branch_comparisons(dut: Any) -> None:
    """BLTU and BGEU use unsigned comparisons of the operands."""
    _drive(dut, branch_operation=BRLTU, operand_a=0xFFFFFFFF, operand_b=0)
    await _settle()
    _assert_outputs(dut, taken=False, target=BRANCH_TARGET)

    _drive(dut, branch_operation=BRGEU, operand_a=0xFFFFFFFF, operand_b=0)
    await _settle()
    _assert_outputs(dut, taken=True, target=BRANCH_TARGET)

    _drive(dut, branch_operation=BRLTU, operand_a=0, operand_b=0xFFFFFFFF)
    await _settle()
    _assert_outputs(dut, taken=True, target=BRANCH_TARGET)


@cocotb.test()
async def test_jal_uses_precomputed_target(dut: Any) -> None:
    """JAL is taken and selects the ID-stage precomputed JAL target."""
    _drive(dut, branch_operation=JUMP, is_jal=True, jal_target=JAL_TARGET + 0x40)
    await _settle()
    _assert_outputs(dut, taken=True, target=JAL_TARGET + 0x40)

    _drive(dut, branch_operation=JUMP)
    await _settle()
    _assert_outputs(dut, taken=False, target=BRANCH_TARGET)


@cocotb.test()
async def test_jalr_computes_target_from_operand_and_signed_immediate(dut: Any) -> None:
    """JALR computes rs1 plus signed I-immediate and clears bit zero."""
    _drive(
        dut,
        branch_operation=JUMP,
        is_jalr=True,
        operand_a=0x80001005,
        immediate_i=-4,
    )
    await _settle()
    _assert_outputs(dut, taken=True, target=0x80001000)

    _drive(
        dut,
        branch_operation=JUMP,
        is_jalr=True,
        operand_a=0x80001000,
        immediate_i=5,
    )
    await _settle()
    _assert_outputs(dut, taken=True, target=0x80001004)


@cocotb.test()
async def test_null_operation_is_idle_except_for_jal(dut: Any) -> None:
    """NULL is idle for ordinary inputs but still treats JAL as taken."""
    _drive(dut, branch_operation=BR_NULL)
    await _settle()
    _assert_outputs(dut, taken=False, target=BRANCH_TARGET)

    _drive(dut, branch_operation=BR_NULL, is_jal=True, jal_target=JAL_TARGET + 0x80)
    await _settle()
    _assert_outputs(dut, taken=True, target=JAL_TARGET + 0x80)

    _drive(
        dut,
        branch_operation=BR_NULL,
        is_jalr=True,
        operand_a=0x80001008,
        immediate_i=3,
    )
    await _settle()
    _assert_outputs(dut, taken=False, target=0x8000100A)


@cocotb.test()
async def test_conflicting_jump_flags_fall_back_to_branch_target(dut: Any) -> None:
    """When both jump flags are asserted, target selection falls back to branch target."""
    _drive(
        dut,
        branch_operation=JUMP,
        is_jal=True,
        is_jalr=True,
        operand_a=0x80001000,
        branch_target=BRANCH_TARGET + 0x100,
        jal_target=JAL_TARGET + 0x100,
        immediate_i=0x40,
    )
    await _settle()
    _assert_outputs(dut, taken=True, target=BRANCH_TARGET + 0x100)

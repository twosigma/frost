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

"""Unit tests for the IF-stage PC increment calculator."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


PC = 0x80001000
PC_HALFWORD = PC | 0x2
PC_REG = 0x80002000
PC_REG_HALFWORD = PC_REG | 0x2


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_pc.value = PC
    dut.i_pc_reg.value = PC_REG
    dut.i_spanning_wait_for_fetch.value = 0
    dut.i_spanning_in_progress.value = 0
    dut.i_spanning_eligible.value = 0
    dut.i_spanning_to_halfword.value = 0
    dut.i_spanning_to_halfword_registered.value = 0
    dut.i_is_compressed.value = 0
    dut.i_is_compressed_for_pc.value = 0
    dut.i_sel_nop.value = 0
    dut.i_slot2_valid.value = 0
    dut.i_slot2_is_compressed.value = 0
    dut.i_any_holdoff_safe.value = 0
    dut.i_prediction_holdoff.value = 0
    dut.i_prediction_from_buffer_holdoff.value = 0
    dut.i_control_flow_to_halfword_r.value = 0
    dut.i_stall_registered.value = 0
    dut.i_mid_32bit_correction.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _setup_test(dut: Any) -> None:
    """Initialize the combinational calculator inputs."""
    _clear_inputs(dut)
    await _settle()


def _assert_next(dut: Any, *, pc: int, pc_reg: int) -> None:
    """Assert next fetch PC and instruction PC outputs."""
    assert int(dut.o_seq_next_pc.value) == pc
    assert int(dut.o_seq_next_pc_reg.value) == pc_reg


@cocotb.test()
async def test_single_wide_compressed_and_32bit_increments(dut: Any) -> None:
    """Single-wide fetches advance by +2 for RVC and +4 for 32-bit instructions."""
    await _setup_test(dut)

    dut.i_is_compressed.value = 1
    await _settle()

    _assert_next(dut, pc=PC + 2, pc_reg=PC_REG + 2)

    dut.i_is_compressed.value = 0
    await _settle()

    _assert_next(dut, pc=PC + 4, pc_reg=PC_REG + 4)


@cocotb.test()
async def test_two_wide_bundle_increments_cover_all_size_pairs(dut: Any) -> None:
    """Two-wide bundles advance by the sum of slot-1 and slot-2 instruction sizes."""
    await _setup_test(dut)

    cases: tuple[tuple[bool, bool, int], ...] = (
        (True, True, 4),
        (True, False, 6),
        (False, True, 6),
        (False, False, 8),
    )

    dut.i_slot2_valid.value = 1
    for slot1_compressed, slot2_compressed, increment in cases:
        dut.i_is_compressed.value = int(slot1_compressed)
        dut.i_slot2_is_compressed.value = int(slot2_compressed)
        await _settle()

        _assert_next(dut, pc=PC + increment, pc_reg=PC_REG + increment)


@cocotb.test()
async def test_control_flow_halfword_state_uses_halfword_fetch_increment(
    dut: Any,
) -> None:
    """A remembered halfword target advances the fetch PC by +2."""
    await _setup_test(dut)

    dut.i_control_flow_to_halfword_r.value = 1
    dut.i_is_compressed.value = 0
    await _settle()

    _assert_next(dut, pc=PC + 2, pc_reg=PC_REG + 4)


@cocotb.test()
async def test_redirect_holdoff_holds_pc_reg_and_forces_fetch_plus_four(
    dut: Any,
) -> None:
    """Registered redirect holdoff keeps pc_reg stable and fetches +4."""
    await _setup_test(dut)

    dut.i_pc.value = PC_HALFWORD
    dut.i_is_compressed.value = 1
    dut.i_slot2_valid.value = 1
    dut.i_slot2_is_compressed.value = 1
    dut.i_any_holdoff_safe.value = 1
    dut.i_prediction_holdoff.value = 1
    dut.i_control_flow_to_halfword_r.value = 1
    await _settle()

    _assert_next(dut, pc=PC_HALFWORD + 4, pc_reg=PC_REG)


@cocotb.test()
async def test_prediction_holdoff_distinguishes_word_and_halfword_fetch_pc(
    dut: Any,
) -> None:
    """Prediction holdoff advances word PCs by +4 and halfword PCs by +2."""
    await _setup_test(dut)

    dut.i_prediction_holdoff.value = 1
    dut.i_is_compressed.value = 0
    await _settle()

    _assert_next(dut, pc=PC + 4, pc_reg=PC_REG + 4)

    dut.i_pc.value = PC_HALFWORD
    await _settle()

    _assert_next(dut, pc=PC_HALFWORD + 2, pc_reg=PC_REG + 4)


@cocotb.test()
async def test_sel_nop_forces_pc_reg_compressed_path_even_for_two_wide_inputs(
    dut: Any,
) -> None:
    """NOP cycles force pc_reg to the compressed path while fetch follows the bundle."""
    await _setup_test(dut)

    dut.i_is_compressed.value = 0
    dut.i_slot2_valid.value = 1
    dut.i_slot2_is_compressed.value = 0
    dut.i_sel_nop.value = 1
    await _settle()

    _assert_next(dut, pc=PC + 8, pc_reg=PC_REG + 2)


@cocotb.test()
async def test_mid_32bit_correction_overrides_normal_sequential_outputs(
    dut: Any,
) -> None:
    """Mid-32-bit correction derives both outputs from pc_reg."""
    await _setup_test(dut)

    dut.i_pc.value = PC
    dut.i_pc_reg.value = PC_REG_HALFWORD
    dut.i_is_compressed.value = 1
    dut.i_mid_32bit_correction.value = 1
    await _settle()

    expected_pc = ((PC_REG_HALFWORD + 2) & ~0x3) + 4
    _assert_next(dut, pc=expected_pc, pc_reg=PC_REG_HALFWORD + 2)


@cocotb.test()
async def test_prediction_from_buffer_holdoff_blocks_pc_reg_bundle_advance(
    dut: Any,
) -> None:
    """Prediction-from-buffer holdoff collapses pc_reg precompute outputs to +0."""
    await _setup_test(dut)

    dut.i_is_compressed.value = 0
    dut.i_slot2_valid.value = 1
    dut.i_slot2_is_compressed.value = 0
    dut.i_prediction_from_buffer_holdoff.value = 1
    await _settle()

    _assert_next(dut, pc=PC + 8, pc_reg=PC_REG)


@cocotb.test()
async def test_safe_holdoff_has_priority_over_mid_32bit_correction(dut: Any) -> None:
    """Registered holdoff holds pc_reg and suppresses mid-32-bit correction."""
    await _setup_test(dut)

    dut.i_pc.value = PC_HALFWORD
    dut.i_pc_reg.value = PC_REG_HALFWORD
    dut.i_any_holdoff_safe.value = 1
    dut.i_mid_32bit_correction.value = 1
    await _settle()

    _assert_next(dut, pc=PC_HALFWORD + 4, pc_reg=PC_REG_HALFWORD)

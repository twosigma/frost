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

"""Unit tests for the IF-stage C-extension state controller."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
PC_LO = 0x80001000
PC_HI = PC_LO | 0x2
INSTR_A = 0x11223344
INSTR_B = 0x55667788
NEXT_A = 0x99AABBCC
NEXT_B = 0xDDEEFF00
SIDEBAND_A = 0xA5
SIDEBAND_B = 0x3C


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_stall.value = 0
    dut.i_flush.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_stall_registered.value = 0
    dut.i_control_flow_holdoff.value = 0
    dut.i_any_holdoff_safe.value = 0
    dut.i_prediction_holdoff.value = 0
    dut.i_prediction_reset_state.value = 0
    dut.i_pending_prediction_active.value = 0
    dut.i_pending_prediction_target_handoff.value = 0
    dut.i_pending_prediction_target_holdoff.value = 0
    dut.i_prediction_from_buffer_holdoff.value = 0
    dut.i_effective_instr.value = 0
    dut.i_instr_next_word.value = 0
    dut.i_fetch_word_swapped.value = 0
    dut.i_pc.value = PC_LO
    dut.i_pc_reg.value = PC_LO
    dut.i_is_compressed.value = 0
    dut.i_sel_nop.value = 0
    dut.i_instr_sideband.value = 0
    dut.i_slot2_valid.value = 0


def _drive_instruction(
    dut: Any,
    *,
    instr: int = INSTR_A,
    next_word: int = NEXT_A,
    sideband: int = SIDEBAND_A,
    compressed: bool,
    pc_reg: int = PC_LO,
) -> None:
    """Drive live instruction metadata inputs."""
    dut.i_effective_instr.value = instr
    dut.i_instr_next_word.value = next_word
    dut.i_instr_sideband.value = sideband
    dut.i_is_compressed.value = int(compressed)
    dut.i_pc_reg.value = pc_reg


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset C-extension state, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_reset.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_reset.value = 0
    await _settle()


def _assert_buffer(
    dut: Any,
    *,
    instr: int,
    next_word: int,
    sideband: int,
) -> None:
    """Assert captured buffer contents."""
    assert int(dut.o_instr_buffer.value) == instr
    assert int(dut.o_next_word_buffer.value) == next_word
    assert int(dut.o_instr_buffer_sideband.value) == sideband


@cocotb.test()
async def test_reset_clears_registered_control_state(dut: Any) -> None:
    """Reset clears visible control state while leaving data registers don't-care."""
    await _setup_test(dut)

    assert not dut.o_prev_was_compressed_at_lo.value
    assert not dut.o_is_compressed_for_pc.value
    assert not dut.o_is_compressed_saved.value
    assert not dut.o_saved_values_valid.value
    assert not dut.o_use_buffer_after_prediction.value


@cocotb.test()
async def test_compressed_low_half_arms_buffer_and_captures_words(dut: Any) -> None:
    """A compressed instruction at the low half arms the buffer for the high half."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True)
    await _advance_cycle(dut)

    assert dut.o_prev_was_compressed_at_lo.value
    assert dut.o_is_compressed_for_pc.value
    assert dut.o_is_compressed_for_buffer.value
    _assert_buffer(dut, instr=INSTR_A, next_word=NEXT_A, sideband=SIDEBAND_A)


@cocotb.test()
async def test_slot2_valid_consumes_high_half_without_arming_buffer(dut: Any) -> None:
    """Slot-2 validity suppresses the low-half compressed buffer arm."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True)
    dut.i_slot2_valid.value = 1
    await _advance_cycle(dut)

    assert not dut.o_prev_was_compressed_at_lo.value
    assert dut.o_is_compressed_for_pc.value


@cocotb.test()
async def test_control_flow_holdoff_clears_buffer_state_and_pc_compression(
    dut: Any,
) -> None:
    """Registered control-flow holdoff clears buffer state and PC-size metadata."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True)
    await _advance_cycle(dut)
    assert dut.o_prev_was_compressed_at_lo.value
    assert dut.o_is_compressed_for_pc.value

    dut.i_control_flow_holdoff.value = 1
    await _advance_cycle(dut)

    assert not dut.o_prev_was_compressed_at_lo.value
    assert not dut.o_is_compressed_for_pc.value


@cocotb.test()
async def test_stall_start_saves_and_restores_instruction_metadata(dut: Any) -> None:
    """A valid stall-start snapshot is replayed when stall_registered is set."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True)
    dut.i_stall.value = 1
    await _advance_cycle(dut)

    assert dut.o_saved_values_valid.value
    assert dut.o_is_compressed_saved.value
    assert dut.o_is_compressed_for_pc.value

    dut.i_stall.value = 0
    dut.i_stall_registered.value = 1
    _drive_instruction(
        dut,
        instr=INSTR_B,
        next_word=NEXT_B,
        sideband=SIDEBAND_B,
        compressed=False,
    )
    await _settle()

    assert dut.o_is_compressed_for_buffer.value

    await _advance_cycle(dut)

    assert dut.o_prev_was_compressed_at_lo.value
    _assert_buffer(dut, instr=INSTR_A, next_word=NEXT_A, sideband=SIDEBAND_A)


@cocotb.test()
async def test_nop_at_stall_start_does_not_create_saved_values(dut: Any) -> None:
    """A NOP bubble at stall start is not captured as replayable state."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True)
    dut.i_stall.value = 1
    dut.i_sel_nop.value = 1
    await _advance_cycle(dut)

    assert not dut.o_saved_values_valid.value
    assert not dut.o_is_compressed_saved.value
    assert not dut.o_is_compressed_for_pc.value


@cocotb.test()
async def test_flush_clears_saved_stall_snapshot(dut: Any) -> None:
    """Flush invalidates stall-saved instruction metadata."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True)
    dut.i_stall.value = 1
    await _advance_cycle(dut)
    assert dut.o_saved_values_valid.value

    dut.i_stall.value = 0
    dut.i_flush.value = 1
    await _advance_cycle(dut)

    assert not dut.o_saved_values_valid.value
    assert not dut.o_is_compressed_saved.value


@cocotb.test()
async def test_prediction_reset_preserves_low_compressed_buffer_once(dut: Any) -> None:
    """A prediction reset preserves low-half compressed buffer state for one cycle."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True, pc_reg=PC_LO)
    dut.i_prediction_reset_state.value = 1
    await _advance_cycle(dut)

    assert dut.o_prev_was_compressed_at_lo.value
    _assert_buffer(dut, instr=INSTR_A, next_word=NEXT_A, sideband=SIDEBAND_A)

    _drive_instruction(dut, compressed=False, pc_reg=PC_LO)
    await _advance_cycle(dut)

    assert not dut.o_prev_was_compressed_at_lo.value


@cocotb.test()
async def test_prediction_from_buffer_holdoff_pulses_use_buffer_afterwards(
    dut: Any,
) -> None:
    """The cycle after prediction-from-buffer holdoff requests buffer reuse."""
    await _setup_test(dut)

    dut.i_prediction_from_buffer_holdoff.value = 1
    await _advance_cycle(dut)

    dut.i_prediction_from_buffer_holdoff.value = 0
    await _settle()

    assert dut.o_use_buffer_after_prediction.value

    dut.i_fence_i_flush.value = 1
    await _settle()

    assert not dut.o_use_buffer_after_prediction.value


@cocotb.test()
async def test_pending_prediction_target_holdoff_preserves_needed_buffer(
    dut: Any,
) -> None:
    """Pending halfword target holdoff preserves a needed compressed-low buffer."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True, pc_reg=PC_LO)
    await _advance_cycle(dut)
    assert dut.o_prev_was_compressed_at_lo.value

    _drive_instruction(
        dut,
        instr=INSTR_B,
        next_word=NEXT_B,
        sideband=SIDEBAND_B,
        compressed=False,
        pc_reg=PC_HI,
    )
    dut.i_pending_prediction_target_holdoff.value = 1
    await _advance_cycle(dut)

    assert dut.o_prev_was_compressed_at_lo.value
    _assert_buffer(dut, instr=INSTR_A, next_word=NEXT_A, sideband=SIDEBAND_A)

    dut.i_pending_prediction_target_holdoff.value = 0
    await _settle()

    assert dut.o_use_buffer_after_prediction.value


@cocotb.test()
async def test_pending_prediction_capture_overrides_prediction_holdoff(
    dut: Any,
) -> None:
    """Pending predictions can capture the old-path compressed buffer during holdoff."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True, pc_reg=PC_LO)
    dut.i_pending_prediction_active.value = 1
    dut.i_prediction_holdoff.value = 1
    await _advance_cycle(dut)

    assert dut.o_prev_was_compressed_at_lo.value
    assert not dut.o_is_compressed_for_pc.value
    _assert_buffer(dut, instr=INSTR_A, next_word=NEXT_A, sideband=SIDEBAND_A)


@cocotb.test()
async def test_is_compressed_for_pc_ignores_nops_and_pending_predictions(
    dut: Any,
) -> None:
    """Registered PC compression metadata ignores NOP and pending-prediction cycles."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True)
    await _advance_cycle(dut)
    assert dut.o_is_compressed_for_pc.value

    _drive_instruction(dut, compressed=False)
    dut.i_sel_nop.value = 1
    await _advance_cycle(dut)
    assert dut.o_is_compressed_for_pc.value

    dut.i_sel_nop.value = 0
    dut.i_pending_prediction_active.value = 1
    await _advance_cycle(dut)
    assert dut.o_is_compressed_for_pc.value

    dut.i_pending_prediction_active.value = 0
    dut.i_control_flow_holdoff.value = 1
    await _advance_cycle(dut)
    assert not dut.o_is_compressed_for_pc.value


@cocotb.test()
async def test_fetch_word_swapped_blocks_next_word_buffer_update(dut: Any) -> None:
    """Misaligned fetch data preserves the prior next-word buffer value."""
    await _setup_test(dut)

    _drive_instruction(dut, compressed=True)
    await _advance_cycle(dut)
    _assert_buffer(dut, instr=INSTR_A, next_word=NEXT_A, sideband=SIDEBAND_A)

    _drive_instruction(
        dut,
        instr=INSTR_B,
        next_word=NEXT_B,
        sideband=SIDEBAND_B,
        compressed=True,
    )
    dut.i_fetch_word_swapped.value = 1
    await _advance_cycle(dut)

    assert int(dut.o_instr_buffer.value) == INSTR_B
    assert int(dut.o_next_word_buffer.value) == NEXT_A
    assert int(dut.o_instr_buffer_sideband.value) == SIDEBAND_B

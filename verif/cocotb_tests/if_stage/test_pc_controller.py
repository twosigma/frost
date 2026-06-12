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

"""Unit tests for the IF-stage PC controller."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
BASE_PC = 0x80001000
BRANCH_TARGET = 0x80002000
PD_TARGET = 0x80003000
FENCE_TARGET = 0x80004000
TRAP_TARGET = 0x80005000
SLOT2_TARGET = 0x80006000
PRED_TARGET = 0x80007000
HALFWORD_PRED_TARGET = 0x80008002


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs except reset to idle values."""
    dut.i_stall.value = 0
    dut.i_stall_registered.value = 0
    dut.i_fetch_progress.value = 1
    dut.i_flush.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_fence_i_target.value = 0
    dut.i_branch_taken.value = 0
    dut.i_branch_target.value = 0
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0
    dut.i_trap_taken.value = 0
    dut.i_mret_taken.value = 0
    dut.i_trap_target.value = 0
    dut.i_spanning_wait_for_fetch.value = 0
    dut.i_spanning_in_progress.value = 0
    dut.i_spanning_eligible.value = 0
    dut.i_spanning_to_halfword.value = 0
    dut.i_spanning_to_halfword_registered.value = 0
    dut.i_is_compressed.value = 0
    dut.i_is_compressed_for_pc.value = 0
    dut.i_slot2_valid.value = 0
    dut.i_slot2_is_compressed.value = 0
    dut.i_predicted_taken.value = 0
    dut.i_predicted_target.value = 0
    dut.i_predicted_target_r.value = 0
    dut.i_prediction_used.value = 0
    dut.i_prediction_used_for_pc.value = 0
    dut.i_ras_predicted.value = 0
    dut.i_sel_prediction_r.value = 0
    dut.i_prediction_requires_pc_reg_handoff.value = 0
    dut.i_prediction_holdoff.value = 0
    dut.i_prediction_from_buffer_holdoff.value = 0
    dut.i_prediction_used_from_buffer.value = 0
    dut.i_sel_nop.value = 0
    dut.i_slot2_prediction_used.value = 0
    dut.i_slot2_prediction_used_for_pc.value = 0
    dut.i_slot2_predicted_target.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the PC controller, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_reset.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_reset.value = 0
    await _settle()


async def _clear_reset_holdoff(dut: Any) -> None:
    """Advance one cycle past reset holdoff."""
    await _advance_cycle(dut)


async def _consume_redirect_holdoff(dut: Any) -> None:
    """Clear redirect inputs and advance through the registered holdoff cycle."""
    _clear_inputs(dut)
    await _settle()
    await _advance_cycle(dut)


async def _start_word_stream_at(dut: Any, pc: int) -> None:
    """Redirect to a word-aligned PC and consume the redirect holdoff."""
    dut.i_branch_taken.value = 1
    dut.i_branch_target.value = pc
    await _advance_cycle(dut)
    _assert_pc(dut, pc=pc, pc_reg=pc)

    await _consume_redirect_holdoff(dut)
    _assert_pc(dut, pc=pc + 4, pc_reg=pc)


def _assert_pc(dut: Any, *, pc: int, pc_reg: int) -> None:
    """Assert fetch PC and instruction PC outputs."""
    assert int(dut.o_pc.value) == pc
    assert int(dut.o_pc_reg.value) == pc_reg


def _drive_slot1_prediction(dut: Any, *, target: int) -> None:
    """Drive a slot-1 prediction redirect."""
    dut.i_predicted_taken.value = 1
    dut.i_predicted_target.value = target
    dut.i_prediction_used.value = 1
    dut.i_prediction_used_for_pc.value = 1


@cocotb.test()
async def test_reset_holdoff_initializes_pc_stream(dut: Any) -> None:
    """Reset clears both PCs, then reset holdoff creates the initial fetch lead."""
    await _setup_test(dut)

    _assert_pc(dut, pc=0, pc_reg=0)
    assert dut.o_reset_holdoff.value
    assert dut.o_any_holdoff_safe.value

    await _advance_cycle(dut)

    _assert_pc(dut, pc=4, pc_reg=0)
    assert not dut.o_reset_holdoff.value
    assert not dut.o_any_holdoff_safe.value

    await _advance_cycle(dut)

    _assert_pc(dut, pc=8, pc_reg=4)


@cocotb.test()
async def test_redirect_priority_selects_oldest_or_highest_priority_source(
    dut: Any,
) -> None:
    """The final PC mux honors trap, fence, branch, PD, slot-2, slot-1 priority."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)

    dut.i_trap_taken.value = 1
    dut.i_trap_target.value = TRAP_TARGET
    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = FENCE_TARGET
    dut.i_branch_taken.value = 1
    dut.i_branch_target.value = BRANCH_TARGET
    await _advance_cycle(dut)
    _assert_pc(dut, pc=TRAP_TARGET, pc_reg=TRAP_TARGET)

    await _consume_redirect_holdoff(dut)
    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = FENCE_TARGET
    dut.i_branch_taken.value = 1
    dut.i_branch_target.value = BRANCH_TARGET
    await _advance_cycle(dut)
    _assert_pc(dut, pc=FENCE_TARGET, pc_reg=FENCE_TARGET)

    await _consume_redirect_holdoff(dut)
    dut.i_branch_taken.value = 1
    dut.i_branch_target.value = BRANCH_TARGET
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = PD_TARGET
    dut.i_slot2_prediction_used.value = 1
    dut.i_slot2_prediction_used_for_pc.value = 1
    dut.i_slot2_predicted_target.value = SLOT2_TARGET
    _drive_slot1_prediction(dut, target=PRED_TARGET)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=BRANCH_TARGET, pc_reg=BRANCH_TARGET)

    await _consume_redirect_holdoff(dut)
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = PD_TARGET
    dut.i_slot2_prediction_used.value = 1
    dut.i_slot2_prediction_used_for_pc.value = 1
    dut.i_slot2_predicted_target.value = SLOT2_TARGET
    _drive_slot1_prediction(dut, target=PRED_TARGET)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=PD_TARGET, pc_reg=PD_TARGET)

    await _consume_redirect_holdoff(dut)
    dut.i_slot2_prediction_used.value = 1
    dut.i_slot2_prediction_used_for_pc.value = 1
    dut.i_slot2_predicted_target.value = SLOT2_TARGET
    _drive_slot1_prediction(dut, target=PRED_TARGET)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=SLOT2_TARGET, pc_reg=SLOT2_TARGET)


@cocotb.test()
async def test_branch_redirect_enters_registered_holdoff(dut: Any) -> None:
    """A branch redirect updates both PCs, then holds pc_reg for one stale cycle."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)

    dut.i_branch_taken.value = 1
    dut.i_branch_target.value = BRANCH_TARGET
    await _settle()

    assert dut.o_control_flow_change.value
    assert dut.o_any_holdoff.value
    assert not dut.o_any_holdoff_safe.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=BRANCH_TARGET, pc_reg=BRANCH_TARGET)

    _clear_inputs(dut)
    await _settle()

    assert dut.o_control_flow_holdoff.value
    assert dut.o_any_holdoff_safe.value

    await _advance_cycle(dut)

    _assert_pc(dut, pc=BRANCH_TARGET + 4, pc_reg=BRANCH_TARGET)
    assert not dut.o_control_flow_holdoff.value
    assert not dut.o_any_holdoff_safe.value


@cocotb.test()
async def test_stall_holds_sequential_state_and_trap_overrides_stall(
    dut: Any,
) -> None:
    """Ordinary stalls hold both PCs, while traps and MRET still redirect."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    dut.i_stall.value = 1
    for _ in range(2):
        await _advance_cycle(dut)
        _assert_pc(dut, pc=BASE_PC + 4, pc_reg=BASE_PC)

    dut.i_trap_taken.value = 1
    dut.i_trap_target.value = TRAP_TARGET
    await _advance_cycle(dut)

    _assert_pc(dut, pc=TRAP_TARGET, pc_reg=TRAP_TARGET)


@cocotb.test()
async def test_two_wide_bundle_inputs_advance_pc_controller_outputs(
    dut: Any,
) -> None:
    """The controller forwards slot-2 bundle size to the sequential PC calculator."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    dut.i_slot2_valid.value = 1
    dut.i_is_compressed.value = 0
    dut.i_slot2_is_compressed.value = 0
    await _advance_cycle(dut)

    _assert_pc(dut, pc=BASE_PC + 12, pc_reg=BASE_PC + 8)


@cocotb.test()
async def test_slot2_prediction_redirects_immediately_and_pulses_bubble(
    dut: Any,
) -> None:
    """Slot-2 predictions redirect both PCs and assert the one-cycle bubble flag."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)

    dut.i_slot2_prediction_used.value = 1
    dut.i_slot2_prediction_used_for_pc.value = 1
    dut.i_slot2_predicted_target.value = SLOT2_TARGET
    _drive_slot1_prediction(dut, target=PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=SLOT2_TARGET, pc_reg=SLOT2_TARGET)
    assert dut.o_slot2_redirect_q.value
    assert dut.o_control_flow_holdoff.value

    await _consume_redirect_holdoff(dut)

    _assert_pc(dut, pc=SLOT2_TARGET + 4, pc_reg=SLOT2_TARGET)
    assert not dut.o_slot2_redirect_q.value


@cocotb.test()
async def test_registered_slot1_prediction_handoff_updates_pc_reg(
    dut: Any,
) -> None:
    """A word-aligned slot-1 prediction redirects fetch first, then pc_reg."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    _drive_slot1_prediction(dut, target=PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=PRED_TARGET, pc_reg=BASE_PC + 4)

    _clear_inputs(dut)
    dut.i_sel_prediction_r.value = 1
    dut.i_predicted_target_r.value = PRED_TARGET
    await _advance_cycle(dut)

    _assert_pc(dut, pc=PRED_TARGET + 4, pc_reg=PRED_TARGET)


@cocotb.test()
async def test_halfword_prediction_holds_fetch_until_pc_reg_reaches_branch(
    dut: Any,
) -> None:
    """Halfword prediction targets use pending state until pc_reg consumes the branch."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    branch_pc = BASE_PC + 4
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=branch_pc)
    assert dut.o_pending_prediction_active.value
    assert dut.o_pending_prediction_holdoff.value

    _clear_inputs(dut)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    assert dut.o_pending_prediction_active.value
    assert dut.o_pending_prediction_holdoff.value

    await _advance_cycle(dut)

    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    assert dut.o_pending_prediction_active.value
    assert dut.o_pending_prediction_holdoff.value

    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=HALFWORD_PRED_TARGET)
    assert not dut.o_pending_prediction_active.value
    assert dut.o_pending_prediction_target_holdoff.value

    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET + 2, pc_reg=HALFWORD_PRED_TARGET)
    assert not dut.o_pending_prediction_target_holdoff.value

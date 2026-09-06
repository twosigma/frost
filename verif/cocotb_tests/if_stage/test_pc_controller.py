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
PC_ADV_PLUS2 = 0
PC_ADV_PLUS4 = 1
PC_ADV_PLUS6 = 2


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
    dut.i_window_cannot_serve.value = 0
    dut.i_window_cannot_serve_raw.value = 0
    dut.i_trap_taken.value = 0
    dut.i_mret_taken.value = 0
    dut.i_trap_target.value = 0
    dut.i_is_compressed.value = 0
    dut.i_is_compressed_for_pc.value = 0
    dut.i_slot2_valid.value = 0
    dut.i_slot2_is_compressed.value = 0
    dut.i_pc_fetch_advance_sel.value = PC_ADV_PLUS4
    dut.i_pc_fetch_advance_sel_run.value = PC_ADV_PLUS4
    dut.i_pc_fetch_advance_sel_nop.value = PC_ADV_PLUS4
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS4
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS4
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS4
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
    dut.i_prediction_already_emitted.value = 0
    dut.i_sel_nop.value = 0
    dut.i_slot2_prediction_used.value = 0
    dut.i_slot2_prediction_used_for_pc.value = 0
    dut.i_slot2_predicted_target.value = 0
    dut.i_slot2_staged_prediction_used_for_pc.value = 0
    dut.i_slot1_aliases_slot2_candidate.value = 0
    dut.i_slot2_live_target_used_for_pc_cofactor.value = 0
    dut.i_slot2_staged_predicted_target.value = 0
    dut.i_slot2_live_predicted_target.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the PC controller, and clear inputs."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
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


def _drive_staged_slot2_prediction(dut: Any, *, target: int) -> None:
    """Drive a canonical slot-2 redirect sourced by the staged BTB image."""
    dut.i_slot2_prediction_used.value = 1
    dut.i_slot2_prediction_used_for_pc.value = 1
    dut.i_slot2_predicted_target.value = target
    dut.i_slot2_staged_prediction_used_for_pc.value = 1
    dut.i_slot2_staged_predicted_target.value = target


def _drive_live_slot2_fallback(dut: Any, *, target: int) -> None:
    """Drive the exact alias/cofactor representation of a live fallback."""
    dut.i_slot2_prediction_used.value = 1
    dut.i_slot2_prediction_used_for_pc.value = 1
    dut.i_slot2_predicted_target.value = target
    dut.i_slot1_aliases_slot2_candidate.value = 1
    dut.i_slot2_live_target_used_for_pc_cofactor.value = 1
    dut.i_slot2_live_predicted_target.value = target


def _assert_pending_predecessor_relation(dut: Any) -> None:
    """Check both registered predecessor tags and retired-adder equivalents."""
    width_mask = (1 << len(dut.o_pc)) - 1
    pending_pc = int(dut.pending_prediction_pc.value)
    compressed_predecessor_pc = int(dut.pending_prediction_prev_pc.value)
    native_predecessor_pc = int(dut.pending_prediction_prev_native_pc.value)
    pc_reg = int(dut.o_pc_reg.value)

    assert int(dut.o_pending_prediction_pc.value) == pending_pc
    assert int(dut.o_pending_prediction_prev_pc.value) == compressed_predecessor_pc
    assert int(dut.o_pending_prediction_prev_native_pc.value) == native_predecessor_pc
    assert compressed_predecessor_pc == (pending_pc - 2) & width_mask
    assert native_predecessor_pc == (pending_pc - 4) & width_mask
    assert (pc_reg == compressed_predecessor_pc) == (
        pending_pc == ((pc_reg + 2) & width_mask)
    )
    assert (pc_reg == native_predecessor_pc) == (
        pending_pc == ((pc_reg + 4) & width_mask)
    )


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
    _drive_staged_slot2_prediction(dut, target=SLOT2_TARGET)
    _drive_slot1_prediction(dut, target=PRED_TARGET)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=BRANCH_TARGET, pc_reg=BRANCH_TARGET)

    await _consume_redirect_holdoff(dut)
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = PD_TARGET
    _drive_staged_slot2_prediction(dut, target=SLOT2_TARGET)
    _drive_slot1_prediction(dut, target=PRED_TARGET)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=PD_TARGET, pc_reg=PD_TARGET)

    await _consume_redirect_holdoff(dut)
    _drive_staged_slot2_prediction(dut, target=SLOT2_TARGET)
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
async def test_pc_reg_clock_enable_factors_fetch_holds_and_preserves_priority(
    dut: Any,
) -> None:
    """The pc_reg CE exactly replaces the window/progress self-hold mux arms."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    # Sensitize a low-priority load datum which differs from the current
    # pc_reg. The datum stays independent of W/F; only the new CE changes.
    for window_cannot_serve, fetch_progress in (
        (1, 1),
        (0, 0),
        (1, 0),
        (0, 1),
    ):
        _clear_inputs(dut)
        dut.i_window_cannot_serve.value = window_cannot_serve
        dut.i_window_cannot_serve_raw.value = window_cannot_serve
        dut.i_fetch_progress.value = fetch_progress
        dut.i_sel_prediction_r.value = 1
        dut.i_predicted_target_r.value = PRED_TARGET
        await _settle()

        expected_load = bool(not window_cannot_serve and fetch_progress)
        assert bool(dut.pc_reg_load_en.value) == expected_load
        assert int(dut.next_pc_reg.value) == PRED_TARGET

        old_pc_reg = int(dut.o_pc_reg.value)
        await _advance_cycle(dut)
        expected_pc_reg = PRED_TARGET if expected_load else old_pc_reg
        assert int(dut.o_pc_reg.value) == expected_pc_reg
        assert int(dut.o_pc_reg_high_for_coverage.value) == ((expected_pc_reg >> 1) & 1)

    # Every redirect above the retired hold arms still wins with both holds
    # asserted. Trap/xRET/FENCE retain their outer stall override; branch and
    # PD retain their historical requirement that the pipeline is unstalled.
    redirect_cases = (
        ("i_trap_taken", "i_trap_target", TRAP_TARGET, True),
        ("i_mret_taken", "i_trap_target", TRAP_TARGET + 4, True),
        ("i_fence_i_flush", "i_fence_i_target", FENCE_TARGET, True),
        ("i_branch_taken", "i_branch_target", BRANCH_TARGET, False),
        ("i_pd_redirect", "i_pd_redirect_target", PD_TARGET, False),
    )
    for active_name, target_name, target, stalls in redirect_cases:
        _clear_inputs(dut)
        dut.i_stall.value = stalls
        dut.i_window_cannot_serve.value = 1
        dut.i_window_cannot_serve_raw.value = 1
        dut.i_fetch_progress.value = 0
        getattr(dut, active_name).value = 1
        getattr(dut, target_name).value = target
        await _settle()

        assert dut.pc_reg_load_en.value
        assert int(dut.next_pc_reg.value) == target
        await _advance_cycle(dut)
        assert int(dut.o_pc_reg.value) == target

    # Branch/PD are high in the data priority but do not newly override the
    # pre-existing outer stall gate as a side effect of the CE refactor.
    _clear_inputs(dut)
    dut.i_stall.value = 1
    dut.i_window_cannot_serve.value = 1
    dut.i_window_cannot_serve_raw.value = 1
    dut.i_fetch_progress.value = 0
    dut.i_branch_taken.value = 1
    dut.i_branch_target.value = BRANCH_TARGET + 4
    await _settle()

    old_pc_reg = int(dut.o_pc_reg.value)
    assert not dut.pc_reg_load_en.value
    assert int(dut.next_pc_reg.value) == BRANCH_TARGET + 4
    await _advance_cycle(dut)
    assert int(dut.o_pc_reg.value) == old_pc_reg


@cocotb.test()
async def test_two_wide_bundle_inputs_advance_pc_controller_outputs(
    dut: Any,
) -> None:
    """The controller forwards slot-2 bundle size to the sequential PC calculator."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    dut.i_slot2_valid.value = 1
    dut.i_is_compressed.value = 1
    dut.i_slot2_is_compressed.value = 0
    dut.i_pc_fetch_advance_sel.value = PC_ADV_PLUS6
    dut.i_pc_fetch_advance_sel_run.value = PC_ADV_PLUS6
    dut.i_pc_fetch_advance_sel_nop.value = PC_ADV_PLUS6
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS6
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS6
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS6
    await _advance_cycle(dut)

    _assert_pc(dut, pc=BASE_PC + 10, pc_reg=BASE_PC + 6)


@cocotb.test()
async def test_slot2_prediction_redirects_immediately_and_pulses_bubble(
    dut: Any,
) -> None:
    """Slot-2 predictions redirect both PCs and assert the one-cycle bubble flag."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)

    _drive_staged_slot2_prediction(dut, target=SLOT2_TARGET)
    _drive_slot1_prediction(dut, target=PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=SLOT2_TARGET, pc_reg=SLOT2_TARGET)
    assert dut.o_slot2_redirect_q.value
    assert dut.o_control_flow_holdoff.value

    await _consume_redirect_holdoff(dut)

    _assert_pc(dut, pc=SLOT2_TARGET + 4, pc_reg=SLOT2_TARGET)
    assert not dut.o_slot2_redirect_q.value


@cocotb.test()
async def test_live_slot2_fallback_alias_selects_pc_reg_last_and_keeps_priority(
    dut: Any,
) -> None:
    """The slow live-candidate alias is the final exact pc_reg selector."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    # With the alias removed, its otherwise-complete cofactor cannot redirect
    # pc_reg. The staged arm is independently clear, so sequential advance is
    # the selected no-live candidate.
    dut.i_slot2_live_target_used_for_pc_cofactor.value = 1
    dut.i_slot2_live_predicted_target.value = SLOT2_TARGET
    await _settle()
    assert dut.live_slot2_pc_reg_override_cofactor.value
    assert int(dut.next_pc_reg_if_slot2_alias.value) == SLOT2_TARGET
    assert int(dut.next_pc_reg.value) == BASE_PC + 4

    # Restore the exact alias and canonical combined interface. The live target
    # now wins in the same cycle, without a registered handoff.
    _drive_live_slot2_fallback(dut, target=SLOT2_TARGET)
    await _settle()
    assert dut.live_slot2_pc_reg_override_cofactor.value
    assert int(dut.next_pc_reg.value) == SLOT2_TARGET

    # The producer's one-hot candidate contract makes a staged/live overlap
    # unreachable architecturally, but the decomposition remains exact for
    # that binary input shape: the canonical target mux gives the live image
    # priority, while the alias-zero candidate still carries the staged image.
    dut.i_slot2_staged_prediction_used_for_pc.value = 1
    dut.i_slot2_staged_predicted_target.value = PRED_TARGET
    await _settle()
    assert int(dut.next_pc_reg_without_live_slot2.value) == PRED_TARGET
    assert int(dut.next_pc_reg_if_slot2_alias.value) == SLOT2_TARGET
    assert int(dut.next_pc_reg.value) == SLOT2_TARGET

    # Every older architectural redirect still outranks the final live mux,
    # including reset and the redirects which override an outer stall.
    redirect_cases = (
        ("i_reset", None, 0),
        ("i_trap_taken", "i_trap_target", TRAP_TARGET),
        ("i_mret_taken", "i_trap_target", TRAP_TARGET + 4),
        ("i_fence_i_flush", "i_fence_i_target", FENCE_TARGET),
        ("i_branch_taken", "i_branch_target", BRANCH_TARGET),
        ("i_pd_redirect", "i_pd_redirect_target", PD_TARGET),
    )
    for active_name, target_name, target in redirect_cases:
        _clear_inputs(dut)
        dut.i_reset.value = 0
        _drive_live_slot2_fallback(dut, target=SLOT2_TARGET)
        getattr(dut, active_name).value = 1
        if target_name is not None:
            getattr(dut, target_name).value = target
        await _settle()

        assert not dut.live_slot2_pc_reg_override_cofactor.value
        assert int(dut.next_pc_reg.value) == target

    # Sample one overlapping redirect through the register as well as the
    # combinational priority oracle above.
    _clear_inputs(dut)
    dut.i_reset.value = 0
    _drive_live_slot2_fallback(dut, target=SLOT2_TARGET)
    dut.i_branch_taken.value = 1
    dut.i_branch_target.value = BRANCH_TARGET
    await _advance_cycle(dut)
    _assert_pc(dut, pc=BRANCH_TARGET, pc_reg=BRANCH_TARGET)


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
async def test_already_emitted_prediction_uses_registered_halfword_target_handoff(
    dut: Any,
) -> None:
    """A no-lead branch cannot leave an orphan pending halfword episode."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    # Collapse fetch onto pc_reg, as a variable-latency response does before
    # the predicted packet is emitted directly from the live lookup.
    dut.i_window_cannot_serve.value = 1
    dut.i_window_cannot_serve_raw.value = 1
    await _advance_cycle(dut)
    _assert_pc(dut, pc=BASE_PC, pc_reg=BASE_PC)

    _clear_inputs(dut)
    dut.i_pc_fetch_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_prediction_already_emitted.value = 1
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=BASE_PC + 2)
    assert not dut.o_pending_prediction_active.value

    # A delayed target response holds the registered handoff, then applies it
    # on the first progress cycle without any pending-state intervention.
    _clear_inputs(dut)
    dut.i_fetch_progress.value = 0
    dut.i_sel_prediction_r.value = 1
    dut.i_predicted_target_r.value = HALFWORD_PRED_TARGET
    await _advance_cycle(dut)
    await _advance_cycle(dut)
    assert not dut.o_pending_prediction_active.value

    dut.i_fetch_progress.value = 1
    await _advance_cycle(dut)
    assert int(dut.o_pc_reg.value) == HALFWORD_PRED_TARGET
    assert not dut.o_pending_prediction_active.value


@cocotb.test()
async def test_halfword_prediction_holds_fetch_until_pc_reg_reaches_branch(
    dut: Any,
) -> None:
    """Halfword prediction targets stay pending until pc_reg consumes the branch."""
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


@cocotb.test()
async def test_pending_target_response_mismatch_retries_branch_handoff(
    dut: Any,
) -> None:
    """A target response cannot consume an owed pending branch handoff.

    A variable-latency provider may publish the prediction target on the same
    cycle pc_reg reaches the branch whose pending prediction is ready.  The
    target window does not cover that branch, so the served-window arm wins
    both PC muxes.  The pending state must survive that edge and retry after
    the provider's resteer returns the branch window.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    branch_pc = BASE_PC + 4
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=branch_pc)
    assert dut.o_pending_prediction_active.value

    # Let the pending controller bring fetch back to the branch and register
    # that pc_reg is ready for the non-cross target handoff.
    _clear_inputs(dut)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    assert dut.pending_prediction_target_handoff.value

    # The provider instead publishes the already-requested target. WCS has
    # priority, so neither PC can take the pending target on this edge.
    dut.i_window_cannot_serve.value = 1
    dut.i_window_cannot_serve_raw.value = 1
    await _settle()
    assert dut.pending_prediction_target_handoff.value
    assert not dut.pending_prediction_target_handoff_applies.value
    assert not dut.o_pending_prediction_target_handoff.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    assert dut.o_pending_prediction_active.value
    assert dut.pending_prediction_pc_ready_q.value
    assert not dut.o_pending_prediction_target_holdoff.value

    # Once the covering branch response arrives, the preserved handoff applies
    # exactly once and enters the normal target lead-restoring bubble.
    dut.i_window_cannot_serve.value = 0
    dut.i_window_cannot_serve_raw.value = 0
    await _settle()
    assert dut.pending_prediction_target_handoff_applies.value
    assert dut.o_pending_prediction_target_handoff.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=HALFWORD_PRED_TARGET)
    assert not dut.o_pending_prediction_active.value
    assert dut.o_pending_prediction_target_holdoff.value


async def _exercise_high_half_pending_retry(dut: Any, *, target: int) -> None:
    """Verify that a served-window retry returns fetch to the saved target.

    A variable-latency provider can publish the prediction target while
    ``pc_reg`` reaches a compressed predicted owner in a word's upper half.
    WCS resteers fetch to the owner's containing word. When that covering
    response arrives, the atomic owner handoff must send both PCs to the
    saved target; advancing fetch sequentially from the containing word
    would request the owner again and repeat the prediction forever.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    owner_pc = BASE_PC + 6

    # Move the one-word lookahead onto an upper-half owner while pc_reg is two
    # compressed parcels behind it.
    _clear_inputs(dut)
    dut.i_pc_fetch_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    await _advance_cycle(dut)
    _assert_pc(dut, pc=owner_pc, pc_reg=owner_pc - 4)

    # The prediction edge redirects fetch and advances pc_reg directly onto
    # the exact owner, as a two-instruction predecessor bundle does.
    _clear_inputs(dut)
    _drive_slot1_prediction(dut, target=target)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=target, pc_reg=owner_pc)
    assert dut.o_pending_prediction_active.value
    assert dut.pending_prediction_allow_cross.value

    # The first published response belongs to the already-requested target,
    # so WCS wins and fetch retries the owner's containing word.
    _clear_inputs(dut)
    dut.i_prediction_holdoff.value = 1
    dut.i_window_cannot_serve.value = 1
    dut.i_window_cannot_serve_raw.value = 1
    await _settle()
    assert dut.pending_prediction_target_handoff.value
    assert not dut.pending_prediction_target_handoff_applies.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=owner_pc - 2, pc_reg=owner_pc)
    assert dut.o_pending_prediction_active.value

    # The covering owner response now consumes the pending handoff. Fetch is
    # sitting on the containing word, not on the target, so sequential advance
    # would refetch the owner and start the same episode again.
    _clear_inputs(dut)
    dut.i_pc_fetch_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_nop.value = PC_ADV_PLUS2
    await _settle()
    assert dut.pending_prediction_target_handoff_applies.value
    assert dut.o_pending_prediction_target_handoff.value
    assert int(dut.o_npc_sel.value) == 1 << 10
    assert not (int(dut.o_npc_seq.value) & (1 << 10))
    assert int(dut.next_pc.value) == target

    await _advance_cycle(dut)
    _assert_pc(dut, pc=target, pc_reg=target)
    assert not dut.o_pending_prediction_active.value


@cocotb.test()
async def test_high_half_pending_retry_returns_fetch_to_word_target(dut: Any) -> None:
    """A high-half owner retry restores a word-aligned prediction target."""
    await _exercise_high_half_pending_retry(dut, target=PRED_TARGET)


@cocotb.test()
async def test_high_half_pending_retry_returns_fetch_to_halfword_target(
    dut: Any,
) -> None:
    """A high-half owner retry restores a halfword-aligned prediction target."""
    await _exercise_high_half_pending_retry(dut, target=HALFWORD_PRED_TARGET)


@cocotb.test()
async def test_first_exact_owner_from_buffer_holdoff_defers_handoff(
    dut: Any,
) -> None:
    """A stale instruction-buffer packet cannot consume an exact owner.

    The normal registered prediction holdoff makes an unbuffered first-cycle
    owner ready for an atomic target handoff. A prediction sourced from the
    instruction buffer is still a NOP during its separate buffer holdoff, so
    it must wait for the ordinary served-owner readiness handshake instead.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    branch_pc = BASE_PC + 4
    dut.i_prediction_used_from_buffer.value = 1
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=branch_pc)
    assert dut.o_pending_prediction_active.value
    assert dut.pending_prediction_valid.value
    assert dut.pending_prediction_from_buffer.value
    assert not dut.pending_prediction_pc_ready_q.value

    # The first exact-owner cycle still describes a stale buffered packet.
    # prediction_holdoff alone must not make that NOP eligible to consume.
    _clear_inputs(dut)
    dut.i_prediction_holdoff.value = 1
    dut.i_prediction_from_buffer_holdoff.value = 1
    dut.i_sel_nop.value = 1
    await _settle()

    assert not dut.pending_prediction_target_handoff.value
    assert not dut.pending_prediction_target_handoff_applies.value
    assert not dut.o_pending_prediction_target_handoff.value
    assert dut.o_pending_prediction_fetch_holdoff.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    assert dut.o_pending_prediction_active.value
    assert not dut.o_pending_prediction_target_holdoff.value

    # Once the stale-buffer phase ends, use the existing registered readiness
    # handshake. The first covering cycle arms pc_ready_q; only the following
    # cycle is allowed to consume the saved owner and target.
    _clear_inputs(dut)
    await _settle()
    assert not dut.pending_prediction_pc_ready_q.value
    assert not dut.pending_prediction_target_handoff.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    assert dut.pending_prediction_pc_ready_q.value
    assert dut.pending_prediction_target_handoff.value
    assert dut.pending_prediction_target_handoff_applies.value
    assert dut.o_pending_prediction_target_handoff.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=HALFWORD_PRED_TARGET)
    assert not dut.o_pending_prediction_active.value
    assert dut.o_pending_prediction_target_holdoff.value


@cocotb.test()
async def test_prediction_holdoff_predecessor_release_advances_pc_reg(
    dut: Any,
) -> None:
    """A released pending predecessor advances atomically and cannot replay.

    A taken prediction registers a control-flow holdoff at the same time that
    the pending controller still owes the compressed instruction immediately
    before the predicted owner.  That predecessor is released during
    ``i_prediction_holdoff``.  Its packet and ``pc_reg`` advance must happen
    on the same edge; leaving ``pc_reg`` behind lets a later DDR served-window
    retry dispatch the predecessor a second time.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    owner_pc = BASE_PC + 4

    # Arm a pending owner one compressed parcel beyond the next pc_reg. The
    # prediction edge advances pc_reg only onto the immediate predecessor.
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=owner_pc - 2)
    assert dut.o_pending_prediction_active.value
    assert dut.o_any_holdoff_safe.value
    assert dut.pim_base.value

    # The first post-prediction cycle releases that predecessor even though
    # the registered control-flow holdoff is active. The sequential pc_reg
    # result must advance to the owner on this same edge.
    _clear_inputs(dut)
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_prediction_holdoff.value = 1
    await _settle()

    assert dut.pending_predecessor_release_wcs0.value
    assert dut.pending_imm_pred_emit.value
    assert not dut.o_pending_prediction_fetch_holdoff.value
    assert int(dut.seq_next_pc_reg.value) == owner_pc

    await _advance_cycle(dut)
    assert int(dut.o_pc_reg.value) == owner_pc
    assert dut.o_pending_prediction_active.value
    assert not dut.pim_base.value

    # A subsequent variable-latency mismatch can retry the owner, but the
    # predecessor identity is now behind pc_reg and cannot reopen its carve.
    _clear_inputs(dut)
    dut.i_window_cannot_serve.value = 1
    dut.i_window_cannot_serve_raw.value = 1
    await _settle()
    assert not dut.pending_predecessor_release_wcs0.value
    assert not dut.pending_imm_pred_emit.value

    await _advance_cycle(dut)
    assert int(dut.o_pc_reg.value) == owner_pc
    assert not dut.carve_out_engaged_q.value


@cocotb.test()
async def test_wcs_defers_halfword_pending_predecessor_crossing(dut: Any) -> None:
    """A failed release cannot leave a false halfword-crossing witness.

    The WCS=0 predecessor-release cofactor does not depend on the raw
    served-window verdict.  If the architectural WCS arm wins on that
    nominal release cycle, ``pc_reg`` must remain at P-2 and the registered
    crossing witness must remain there with it.  Once the covering window
    arrives, the predecessor emits and advances exactly once before the
    halfword-aligned owner can consume its pending prediction.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    owner_pc = BASE_PC + 6

    # Create the normal one-word fetch lead with a halfword owner at BASE+6
    # and pc_reg two compressed parcels behind it.
    _clear_inputs(dut)
    dut.i_pc_fetch_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    await _advance_cycle(dut)
    _assert_pc(dut, pc=owner_pc, pc_reg=owner_pc - 4)

    # Arm the halfword owner while pc_reg advances only onto its immediate
    # predecessor.
    _clear_inputs(dut)
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=owner_pc - 2)
    assert dut.o_pending_prediction_active.value
    assert dut.pending_prediction_allow_cross.value
    assert dut.pim_base.value

    # The raw cofactor says this would be a predecessor release, but the
    # higher-priority architectural WCS arm means no packet is delivered and
    # neither the architectural PC nor its crossing witness may advance.
    _clear_inputs(dut)
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_prediction_holdoff.value = 1
    dut.i_window_cannot_serve.value = 1
    dut.i_window_cannot_serve_raw.value = 1
    await _settle()

    assert dut.pending_predecessor_release_wcs0.value
    assert int(dut.seq_next_pc_reg.value) == owner_pc
    assert not dut.pc_reg_load_en.value

    await _advance_cycle(dut)
    assert int(dut.o_pc_reg.value) == owner_pc - 2
    assert int(dut.seq_next_pc_reg_hw_q.value) == (owner_pc - 2) >> 1
    assert dut.carve_out_engaged_q.value

    # The covering cycle releases the real predecessor.  It must not be
    # mistaken for an already-completed crossing only because the failed
    # cycle's combinational sequential candidate reached the owner.
    _clear_inputs(dut)
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    await _settle()

    assert dut.pim_base.value
    assert dut.pending_predecessor_release_wcs0.value
    assert dut.pending_imm_pred_emit.value
    assert not dut.pending_prediction_crossing_pc_reg.value
    assert not dut.o_pending_prediction_fetch_holdoff.value
    assert int(dut.next_pc_reg.value) == owner_pc

    await _advance_cycle(dut)
    assert int(dut.o_pc_reg.value) == owner_pc
    assert dut.o_pending_prediction_active.value
    assert not dut.pim_base.value


@cocotb.test()
async def test_pending_predecessor_tag_survives_stall_and_episode_progress(
    dut: Any,
) -> None:
    """A pending episode uses a stable tag across a stall and predecessor emit."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    # Capture a prediction at BASE+4 while pc_reg advances by one compressed
    # parcel to BASE+2.  This is the exact immediate-predecessor carve-out.
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_window_cannot_serve_raw.value = 1
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=BASE_PC + 2)
    assert dut.o_pending_prediction_active.value
    assert dut.pim_base.value
    assert not dut.o_pending_prediction_fetch_holdoff.value
    assert dut.o_pending_prediction_fetch_holdoff_wcs0.value
    assert not dut.o_pending_prediction_fetch_holdoff_wcs.value
    _assert_pending_predecessor_relation(dut)
    captured_pending_pc = int(dut.pending_prediction_pc.value)
    captured_predecessor = int(dut.pending_prediction_prev_pc.value)

    # Sensitize the W=0 cofactor without taking an edge. With the carve latch
    # still clear, removing raw WCS restores the predecessor hold. The
    # companion must equal that canonical value while the W=1 companion keeps
    # the opposite cofactor computed in parallel.
    dut.i_window_cannot_serve_raw.value = 0
    await Timer(1, unit="ns")
    assert dut.o_pending_prediction_fetch_holdoff.value
    assert dut.o_pending_prediction_fetch_holdoff_wcs0.value
    assert not dut.o_pending_prediction_fetch_holdoff_wcs.value
    dut.i_window_cannot_serve_raw.value = 1
    await Timer(1, unit="ns")
    assert not dut.o_pending_prediction_fetch_holdoff.value

    # Fetch stalls freeze the speculative payload together with valid state.
    _clear_inputs(dut)
    dut.i_stall.value = 1
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=BASE_PC + 2)
    assert dut.o_pending_prediction_active.value
    assert int(dut.pending_prediction_pc.value) == captured_pending_pc
    assert int(dut.pending_prediction_prev_pc.value) == captured_predecessor
    _assert_pending_predecessor_relation(dut)

    # Resume the exact raw-WCS episode.  The registered post-prediction holdoff
    # drains first, while the raw condition engages the carve-out latch.
    dut.i_stall.value = 0
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_window_cannot_serve_raw.value = 1
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET + 4, pc_reg=BASE_PC + 2)
    assert dut.o_pending_prediction_active.value
    assert int(dut.pending_prediction_pc.value) == captured_pending_pc
    assert int(dut.pending_prediction_prev_pc.value) == captured_predecessor
    _assert_pending_predecessor_relation(dut)

    # On the following cycle the carve-out emits the predecessor and advances
    # pc_reg onto the pending branch without changing its captured payload.
    await _advance_cycle(dut)

    assert int(dut.o_pc_reg.value) == BASE_PC + 4
    assert dut.o_pending_prediction_active.value
    assert int(dut.pending_prediction_pc.value) == captured_pending_pc
    assert int(dut.pending_prediction_prev_pc.value) == captured_predecessor
    _assert_pending_predecessor_relation(dut)


@cocotb.test()
async def test_pending_predecessor_tag_redirect_kill_and_recapture(dut: Any) -> None:
    """Redirect kills valid state; the next invalid cycle recaptures a fresh tag."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_window_cannot_serve_raw.value = 1
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)

    assert dut.pending_prediction_valid.value
    _assert_pending_predecessor_relation(dut)
    killed_compressed_tag = int(dut.pending_prediction_prev_pc.value)
    killed_native_tag = int(dut.pending_prediction_prev_native_pc.value)

    _clear_inputs(dut)
    dut.i_branch_taken.value = 1
    dut.i_branch_target.value = BRANCH_TARGET
    await _advance_cycle(dut)

    _assert_pc(dut, pc=BRANCH_TARGET, pc_reg=BRANCH_TARGET)
    assert not dut.pending_prediction_valid.value
    assert not dut.o_pending_prediction_active.value
    # The payload is a don't-care while invalid. The redirect edge does not
    # overwrite it because the old pending-valid episode still owns it.
    assert int(dut.pending_prediction_prev_pc.value) == killed_compressed_tag
    assert int(dut.pending_prediction_prev_native_pc.value) == killed_native_tag

    _clear_inputs(dut)
    await _advance_cycle(dut)

    # Speculative capture resumes once valid is low.  The redirect target was
    # o_pc at this edge, so the pending PC and both predecessor tags retag
    # together.
    assert not dut.pending_prediction_valid.value
    assert int(dut.pending_prediction_pc.value) == BRANCH_TARGET
    assert int(dut.pending_prediction_prev_pc.value) == BRANCH_TARGET - 2
    assert int(dut.pending_prediction_prev_native_pc.value) == BRANCH_TARGET - 4
    _assert_pending_predecessor_relation(dut)

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
    """Drive a slot-2 prediction redirect from the staged BTB lookup."""
    dut.i_slot2_prediction_used.value = 1
    dut.i_slot2_prediction_used_for_pc.value = 1
    dut.i_slot2_predicted_target.value = target
    dut.i_slot2_staged_prediction_used_for_pc.value = 1
    dut.i_slot2_staged_predicted_target.value = target


def _drive_live_slot2_fallback(dut: Any, *, target: int) -> None:
    """Drive a slot-2 prediction from the live fallback, with the alias check true."""
    dut.i_slot2_prediction_used.value = 1
    dut.i_slot2_prediction_used_for_pc.value = 1
    dut.i_slot2_predicted_target.value = target
    dut.i_slot1_aliases_slot2_candidate.value = 1
    dut.i_slot2_live_target_used_for_pc_cofactor.value = 1
    dut.i_slot2_live_predicted_target.value = target


def _assert_pending_predecessor_relation(dut: Any) -> None:
    """Check that the predecessor tags equal the pending PC minus 2 and minus 4."""
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
    """The pc_reg load enable applies both fetch holds and keeps redirect priority."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    # Offer a low-priority load value (the registered prediction target) that
    # differs from pc_reg. That value does not depend on the resteer or on
    # fetch progress; only the load enable does.
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

    # Every redirect still loads with both holds asserted. Trap, xRET, and
    # FENCE-class redirects also load during a stall; branch and PD redirects
    # need the pipeline unstalled.
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

    # A branch redirect has priority in next_pc_reg but still does not load
    # during a stall.
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
    """The alias check picks the live slot-2 target last, below reset and redirects."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    # Without the alias, the live select alone cannot redirect pc_reg. The
    # staged select is clear too, so pc_reg advances sequentially.
    dut.i_slot2_live_target_used_for_pc_cofactor.value = 1
    dut.i_slot2_live_predicted_target.value = SLOT2_TARGET
    await _settle()
    assert dut.pc_reg_live_redirect_permission.value
    assert int(dut.next_pc_reg.value) == BASE_PC + 4

    # Drive the alias and the combined slot-2 inputs too. The live target now
    # wins in the same cycle, without a registered handoff.
    _drive_live_slot2_fallback(dut, target=SLOT2_TARGET)
    await _settle()
    assert int(dut.next_pc_reg.value) == SLOT2_TARGET

    # With one-hot slot-2 candidate valids, IF never sets the staged and live
    # selects together, but if both are set the live target still wins, as in
    # the combined target mux. Without the alias, the staged target wins.
    dut.i_slot2_staged_prediction_used_for_pc.value = 1
    dut.i_slot2_staged_predicted_target.value = PRED_TARGET
    await _settle()
    assert int(dut.next_pc_reg.value) == SLOT2_TARGET
    dut.i_slot1_aliases_slot2_candidate.value = 0
    dut.i_slot2_predicted_target.value = PRED_TARGET
    await _settle()
    assert int(dut.next_pc_reg.value) == PRED_TARGET

    # Reset and every redirect still outrank the live slot-2 target, including
    # the redirects that load during a stall.
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

        if active_name != "i_reset":
            assert not dut.pc_reg_live_redirect_permission.value
        assert int(dut.next_pc_reg.value) == target

    # Check one overlapping redirect through the register too, not just
    # next_pc_reg.
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
    """A prediction on an already-emitted branch does not pend for a halfword target."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    # Close the gap between fetch and pc_reg, as a slow fetch response does, so
    # the predicted packet is emitted in the cycle of its own lookup.
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

    # While the target response is late, the registered handoff waits; it
    # applies on the first cycle with fetch progress, and nothing pends.
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

    # Let the pending logic bring fetch back to the branch and register that
    # pc_reg is ready for the non-crossing target handoff.
    _clear_inputs(dut)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    assert dut.pending_prediction_target_handoff.value

    # The provider instead returns the already-requested target. The
    # served-window resteer (WCS) has priority, so neither PC can take the
    # pending target on this edge.
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

    # Once the window covering the branch arrives, the handoff applies exactly
    # once and takes the usual one-cycle target bubble.
    dut.i_window_cannot_serve.value = 0
    dut.i_window_cannot_serve_raw.value = 0
    await _settle()
    assert dut.pending_prediction_target_handoff_applies.value
    assert dut.o_pending_prediction_target_handoff.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=HALFWORD_PRED_TARGET)
    assert not dut.o_pending_prediction_active.value
    assert dut.o_pending_prediction_target_holdoff.value


@cocotb.test()
async def test_generic_slot2_prediction_vetoes_ready_pending_handoff(dut: Any) -> None:
    """With the default parameter, a slot-2 prediction blocks a ready pending handoff.

    if_stage never presents both, because a ready handoff disables prediction,
    and it sets PENDING_HANDOFF_EXCLUDES_SLOT2. The default (0) keeps the
    slot-2 check for standalone use.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    branch_pc = BASE_PC + 4
    _drive_slot1_prediction(dut, target=HALFWORD_PRED_TARGET)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=branch_pc)

    _clear_inputs(dut)
    await _advance_cycle(dut)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=branch_pc, pc_reg=branch_pc)
    assert dut.pending_prediction_target_handoff.value
    assert dut.o_pending_prediction_target_handoff.value

    _drive_staged_slot2_prediction(dut, target=SLOT2_TARGET)
    await _settle()
    assert dut.pending_prediction_target_handoff.value
    assert not dut.pending_prediction_target_handoff_applies.value
    assert not dut.o_pending_prediction_target_handoff.value

    await _advance_cycle(dut)
    _assert_pc(dut, pc=SLOT2_TARGET, pc_reg=SLOT2_TARGET)
    assert dut.o_slot2_redirect_q.value
    assert not dut.o_pending_prediction_target_holdoff.value


async def _exercise_high_half_pending_retry(dut: Any, *, target: int) -> None:
    """Check that a served-window retry returns fetch to the saved target.

    A variable-latency provider can return the prediction target's window
    while ``pc_reg`` reaches a compressed predicted branch in the upper half
    of a word. The served-window resteer sends fetch back to the branch's
    word. When the window covering the branch arrives, the handoff must move
    both PCs to the saved target; advancing fetch sequentially from the
    branch's word would fetch the branch again and repeat the prediction
    forever.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    owner_pc = BASE_PC + 6

    # Move fetch, one word ahead, onto the upper-half branch while pc_reg is
    # two compressed parcels behind it.
    _clear_inputs(dut)
    dut.i_pc_fetch_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    await _advance_cycle(dut)
    _assert_pc(dut, pc=owner_pc, pc_reg=owner_pc - 4)

    # The prediction edge redirects fetch and advances pc_reg straight onto
    # the branch, as a two-instruction bundle before it would.
    _clear_inputs(dut)
    _drive_slot1_prediction(dut, target=target)
    await _advance_cycle(dut)
    _assert_pc(dut, pc=target, pc_reg=owner_pc)
    assert dut.o_pending_prediction_active.value
    assert dut.pending_prediction_allow_cross.value

    # The first window to arrive is the already-requested target's, so the
    # served-window resteer wins and fetch retries the branch's word.
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

    # The window covering the branch now arrives and the pending handoff
    # applies. Fetch sits on the branch's word, not on the target, so a
    # sequential advance would refetch the branch and repeat the prediction.
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
    """A retry at an upper-half branch returns fetch to a word-aligned target."""
    await _exercise_high_half_pending_retry(dut, target=PRED_TARGET)


@cocotb.test()
async def test_high_half_pending_retry_returns_fetch_to_halfword_target(
    dut: Any,
) -> None:
    """A retry at an upper-half branch returns fetch to a halfword-aligned target."""
    await _exercise_high_half_pending_retry(dut, target=HALFWORD_PRED_TARGET)


@cocotb.test()
async def test_first_exact_owner_from_buffer_holdoff_defers_handoff(
    dut: Any,
) -> None:
    """A stale buffered packet at the pending branch cannot take the handoff.

    In the first prediction-holdoff cycle, a pending branch at pc_reg is ready
    for the target handoff, unless its prediction was made from the
    instruction buffer. That packet is still a NOP during its own buffer
    holdoff, so it waits for the registered readiness
    (pending_prediction_pc_ready_q).
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

    # In the first cycle with pc_reg at the branch, the packet is still the
    # stale buffered one. i_prediction_holdoff alone must not let that NOP take
    # the handoff.
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

    # After the stale-buffer cycle, the registered readiness applies. The first
    # cycle with fetch at the branch sets pending_prediction_pc_ready_q; only
    # the next cycle may take the saved branch and target.
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
    """A released predecessor advances pc_reg on the same edge and never replays.

    A taken prediction registers a control-flow holdoff while the compressed
    instruction just before the pending branch has not been emitted yet. That
    predecessor is released during ``i_prediction_holdoff``, and its packet
    and the ``pc_reg`` advance must happen on the same edge; leaving
    ``pc_reg`` behind lets a later served-window retry dispatch the
    predecessor a second time.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    owner_pc = BASE_PC + 4

    # Make a prediction pend for a branch one compressed parcel past the next
    # pc_reg. The prediction edge advances pc_reg only onto the branch's
    # immediate predecessor.
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
    # result must advance to the branch on this same edge.
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

    # A later served-window mismatch can retry the branch, but the predecessor
    # is now behind pc_reg and cannot be released again.
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
    """A blocked predecessor release must not make the pending branch look crossed.

    The raw-WCS = 0 version of the predecessor release ignores the raw
    served-window mismatch. If the served-window resteer wins in the cycle
    the release would happen, ``pc_reg`` must stay at P-2, and so must the
    registered sequential pc_reg that the crossing check reads
    (``seq_next_pc_reg_hw_q``). Once the covering window arrives, the
    predecessor emits and advances exactly once before the halfword-aligned
    branch at P can take its pending prediction.
    """
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    owner_pc = BASE_PC + 6

    # Set up the usual one-word fetch lead, with fetch at the upper-half
    # branch at BASE+6 and pc_reg two compressed parcels behind it.
    _clear_inputs(dut)
    dut.i_pc_fetch_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_fetch_advance_sel_nop.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_run.value = PC_ADV_PLUS2
    dut.i_pc_reg_advance_sel_nop.value = PC_ADV_PLUS2
    await _advance_cycle(dut)
    _assert_pc(dut, pc=owner_pc, pc_reg=owner_pc - 4)

    # Predict the branch at BASE+6 while pc_reg advances only onto its
    # immediate predecessor.
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

    # The raw-WCS = 0 release term is set, but the higher-priority
    # served-window resteer delivers no packet, so neither pc_reg nor
    # seq_next_pc_reg_hw_q may advance.
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

    # The covering cycle releases the real predecessor.  It must not look
    # like a completed crossing just because the blocked cycle's sequential
    # pc_reg candidate reached the branch.
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
    """The pending PC and tags hold through a stall and the predecessor's emit."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)
    await _start_word_stream_at(dut, BASE_PC)

    # Predict a branch at BASE+4 while pc_reg advances by one compressed
    # parcel to BASE+2, the branch's immediate predecessor.
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

    # Check the raw-WCS = 0 version without taking an edge. With
    # carve_out_engaged_q still clear, dropping raw WCS restores the
    # predecessor hold, so the live output must equal the WCS = 0 version,
    # while the WCS = 1 version, computed in parallel, stays clear.
    dut.i_window_cannot_serve_raw.value = 0
    await Timer(1, unit="ns")
    assert dut.o_pending_prediction_fetch_holdoff.value
    assert dut.o_pending_prediction_fetch_holdoff_wcs0.value
    assert not dut.o_pending_prediction_fetch_holdoff_wcs.value
    dut.i_window_cannot_serve_raw.value = 1
    await Timer(1, unit="ns")
    assert not dut.o_pending_prediction_fetch_holdoff.value

    # A stall freezes the pending PC and tags along with the valid bit.
    _clear_inputs(dut)
    dut.i_stall.value = 1
    await _advance_cycle(dut)

    _assert_pc(dut, pc=HALFWORD_PRED_TARGET, pc_reg=BASE_PC + 2)
    assert dut.o_pending_prediction_active.value
    assert int(dut.pending_prediction_pc.value) == captured_pending_pc
    assert int(dut.pending_prediction_prev_pc.value) == captured_predecessor
    _assert_pending_predecessor_relation(dut)

    # Resume with raw WCS still set.  The registered post-prediction holdoff
    # drains first, and raw WCS sets carve_out_engaged_q.
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

    # On the next cycle the predecessor is released: it emits, pc_reg advances
    # onto the pending branch, and the captured pending state does not change.
    await _advance_cycle(dut)

    assert int(dut.o_pc_reg.value) == BASE_PC + 4
    assert dut.o_pending_prediction_active.value
    assert int(dut.pending_prediction_pc.value) == captured_pending_pc
    assert int(dut.pending_prediction_prev_pc.value) == captured_predecessor
    _assert_pending_predecessor_relation(dut)


@cocotb.test()
async def test_pending_predecessor_tag_redirect_kill_and_recapture(dut: Any) -> None:
    """A redirect clears the pending valid bit; the next edge recaptures the PC and tags."""
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
    # The tags are don't-care while invalid. The redirect edge does not
    # overwrite them, because the valid bit was still set on that edge.
    assert int(dut.pending_prediction_prev_pc.value) == killed_compressed_tag
    assert int(dut.pending_prediction_prev_native_pc.value) == killed_native_tag

    _clear_inputs(dut)
    await _advance_cycle(dut)

    # Capture resumes once the valid bit is low.  o_pc held the redirect
    # target at this edge, so the pending PC and both predecessor tags update
    # together.
    assert not dut.pending_prediction_valid.value
    assert int(dut.pending_prediction_pc.value) == BRANCH_TARGET
    assert int(dut.pending_prediction_prev_pc.value) == BRANCH_TARGET - 2
    assert int(dut.pending_prediction_prev_native_pc.value) == BRANCH_TARGET - 4
    _assert_pending_predecessor_relation(dut)

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

"""Unit tests for the IF-stage prediction metadata tracker."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
TARGET_A = 0x80001000
TARGET_B = 0x80002000
TARGET_C = 0x80003000
PENDING_BRANCH_PC = 0x80000102
PENDING_PREDECESSOR_PC = PENDING_BRANCH_PC - 2


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_stall.value = 0
    dut.i_flush.value = 0
    dut.i_pending_prediction_kill.value = 0
    dut.i_stall_registered.value = 0
    dut.i_prediction_used_r.value = 0
    dut.i_predicted_target_r.value = 0
    dut.i_pending_prediction_active.value = 0
    dut.i_pending_prediction_pc.value = 0
    dut.i_output_pc.value = 0
    dut.i_live_prediction_for_output.value = 0
    dut.i_live_target_aligned_with_output.value = 0
    dut.i_live_predicted_target.value = 0
    dut.i_pending_prediction_fetch_holdoff.value = 0
    dut.i_pending_prediction_target_handoff.value = 0
    dut.i_sel_nop.value = 0
    dut.i_sel_nop_saved.value = 0
    dut.i_use_saved_values.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset saved metadata, and clear inputs."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut)
    dut.i_reset.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_reset.value = 0
    await _settle()


def _drive_live_prediction(dut: Any, *, used: bool, target: int) -> None:
    """Drive the registered prediction and a matching live target."""
    dut.i_prediction_used_r.value = int(used)
    dut.i_predicted_target_r.value = target
    dut.i_live_predicted_target.value = target


def _assert_metadata(dut: Any, *, hit: bool, taken: bool, target: int) -> None:
    """Assert the tracker metadata outputs."""
    assert bool(dut.o_btb_hit.value) is hit
    assert bool(dut.o_btb_predicted_taken.value) is taken
    assert int(dut.o_btb_predicted_target.value) == target


async def _save_pending_prediction(
    dut: Any,
    *,
    target: int = TARGET_A,
    owner_pc: int = PENDING_BRANCH_PC,
) -> None:
    """Capture a pending prediction, then present its owner with the target handoff."""
    _drive_live_prediction(dut, used=True, target=target)
    dut.i_pending_prediction_active.value = 1
    dut.i_pending_prediction_pc.value = owner_pc
    dut.i_output_pc.value = owner_pc
    dut.i_pending_prediction_fetch_holdoff.value = 1
    await _advance_cycle(dut)

    _drive_live_prediction(dut, used=False, target=TARGET_B)
    dut.i_pending_prediction_fetch_holdoff.value = 0
    dut.i_pending_prediction_target_handoff.value = 1
    await _settle()


@cocotb.test()
async def test_normal_metadata_passthrough_tracks_live_prediction(dut: Any) -> None:
    """Normal operation passes through the registered prediction metadata."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    _drive_live_prediction(dut, used=False, target=TARGET_B)
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)


@cocotb.test()
async def test_same_cycle_prediction_overrides_stale_registered_metadata(
    dut: Any,
) -> None:
    """A collapsed lookup lead attaches the same-cycle prediction to the emitted branch."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=False, target=TARGET_A)
    dut.i_live_prediction_for_output.value = 1
    dut.i_live_target_aligned_with_output.value = 1
    dut.i_live_predicted_target.value = TARGET_B
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_B)

    dut.i_sel_nop.value = 1
    await _settle()

    # NOP affects validity only; the aligned live target payload is harmless.
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)


@cocotb.test()
async def test_unowned_target_payload_is_independent_of_alignment_and_validity(
    dut: Any,
) -> None:
    """With no registered or pending prediction, the target output is the live target.

    The alignment, NOP, and holdoff inputs never change the target.
    """
    await _setup_test(dut)

    _drive_live_prediction(dut, used=False, target=TARGET_A)
    dut.i_live_predicted_target.value = TARGET_B

    # No prediction is valid, so the live target on the output is ignored.
    # PC alignment does not select the target.
    dut.i_live_target_aligned_with_output.value = 0
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)

    dut.i_live_target_aligned_with_output.value = 1
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)

    # NOP and pending-fetch holdoff clear validity without changing the target
    # source.
    dut.i_sel_nop.value = 1
    dut.i_pending_prediction_fetch_holdoff.value = 1
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)

    dut.i_sel_nop.value = 0
    dut.i_pending_prediction_fetch_holdoff.value = 0
    dut.i_live_prediction_for_output.value = 1
    await _settle()
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_B)


@cocotb.test()
async def test_registered_target_wins_over_same_pc_live_payload(dut: Any) -> None:
    """A live lookup cannot replace target metadata already attached to a packet."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_live_target_aligned_with_output.value = 1
    dut.i_live_predicted_target.value = TARGET_B
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    # A self-targeting prediction whose RAS entry has already popped: the live
    # lookup at the same packet PC now shows a different target while a
    # holdoff invalidates the output. The registered target stays on the
    # output.
    dut.i_pending_prediction_fetch_holdoff.value = 1
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)


@cocotb.test()
async def test_nop_output_clears_validity_without_zeroing_payload(dut: Any) -> None:
    """A NOP clears validity but leaves the target output unchanged."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_sel_nop.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)

    dut.i_sel_nop.value = 0
    dut.i_sel_nop_saved.value = 1
    dut.i_use_saved_values.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)


@cocotb.test()
async def test_stall_start_saves_and_restores_prediction_metadata(dut: Any) -> None:
    """The first stall cycle snapshots metadata for later saved-value replay."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_stall.value = 1
    dut.i_stall_registered.value = 0
    await _advance_cycle(dut)

    # branch_prediction_controller holds target_r while IF is stalled, so the
    # target needs no stall-saved copy.
    _drive_live_prediction(dut, used=False, target=TARGET_A)
    dut.i_stall.value = 0
    dut.i_stall_registered.value = 1
    dut.i_use_saved_values.value = 1
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    dut.i_stall_registered.value = 0
    dut.i_use_saved_values.value = 0
    _drive_live_prediction(dut, used=False, target=TARGET_B)
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)


@cocotb.test()
async def test_flush_clears_stall_saved_valid_metadata(dut: Any) -> None:
    """Flush clears the saved hit/taken bits captured at stall start."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_stall.value = 1
    await _advance_cycle(dut)

    dut.i_stall.value = 0
    dut.i_flush.value = 1
    await _advance_cycle(dut)

    dut.i_flush.value = 0
    dut.i_use_saved_values.value = 1
    await _settle()

    assert not dut.o_btb_hit.value
    assert not dut.o_btb_predicted_taken.value


@cocotb.test()
async def test_pending_prediction_replays_after_fetch_holdoff(dut: Any) -> None:
    """Pending prediction metadata is hidden during holdoff, then replayed once."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_pending_prediction_active.value = 1
    dut.i_pending_prediction_pc.value = PENDING_BRANCH_PC
    dut.i_output_pc.value = PENDING_BRANCH_PC
    dut.i_pending_prediction_fetch_holdoff.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)

    await _advance_cycle(dut)

    _drive_live_prediction(dut, used=False, target=TARGET_B)
    dut.i_pending_prediction_fetch_holdoff.value = 0
    dut.i_pending_prediction_target_handoff.value = 1
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    # pc_controller clears its pending state on the same handoff edge.
    dut.i_pending_prediction_active.value = 0
    await _advance_cycle(dut)

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)


@cocotb.test()
async def test_pending_prediction_survives_nop_until_real_instruction(dut: Any) -> None:
    """A NOP cycle suppresses pending replay without consuming the saved metadata."""
    await _setup_test(dut)
    await _save_pending_prediction(dut)

    dut.i_sel_nop.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)

    await _advance_cycle(dut)

    dut.i_sel_nop.value = 0
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)


@cocotb.test()
async def test_pending_prediction_waits_for_exact_owner_after_predecessor_replay(
    dut: Any,
) -> None:
    """A predecessor released ahead of the pending branch does not consume its metadata."""
    await _setup_test(dut)
    await _save_pending_prediction(dut)

    # pc_controller's immediate-predecessor exception on a stall-release packet:
    # the holdoff is open and the packet is real, but its saved PC is B-2, not
    # the pending branch B. It must not be marked predicted-taken or consume
    # the saved metadata.
    dut.i_use_saved_values.value = 1
    dut.i_output_pc.value = PENDING_PREDECESSOR_PC
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)

    await _advance_cycle(dut)
    assert bool(dut.prediction_pending_saved_valid.value)
    assert int(dut.prediction_pc_pending_saved.value) == PENDING_BRANCH_PC

    # Only the exact owner receives and consumes the saved prediction.
    dut.i_use_saved_values.value = 0
    dut.i_output_pc.value = PENDING_BRANCH_PC
    dut.i_pending_prediction_target_handoff.value = 1
    await _settle()
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    # pc_controller clears its pending state on the same handoff edge.
    dut.i_pending_prediction_active.value = 0
    await _advance_cycle(dut)
    assert not bool(dut.prediction_pending_saved_valid.value)
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)


@cocotb.test()
async def test_exact_pending_owner_replays_through_stall_then_consumes(
    dut: Any,
) -> None:
    """A stalled owner remains valid and consumes only on its release edge."""
    await _setup_test(dut)
    await _save_pending_prediction(dut)

    dut.i_output_pc.value = PENDING_BRANCH_PC
    dut.i_stall.value = 1
    dut.i_pending_prediction_target_handoff.value = 1
    await _settle()
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    await _advance_cycle(dut)
    assert bool(dut.prediction_pending_saved_valid.value)
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    dut.i_stall.value = 0
    await _advance_cycle(dut)
    assert not bool(dut.prediction_pending_saved_valid.value)


@cocotb.test()
async def test_pending_episode_cannot_be_recaptured_by_later_prediction(
    dut: Any,
) -> None:
    """The saved owner PC and target do not change until consumed or killed."""
    await _setup_test(dut)
    await _save_pending_prediction(dut, target=TARGET_A)

    # Keep the fetch holdoff active while an unrelated registered prediction
    # appears. The saved metadata must not be overwritten.
    dut.i_pending_prediction_fetch_holdoff.value = 1
    dut.i_pending_prediction_pc.value = PENDING_BRANCH_PC + 0x40
    dut.i_output_pc.value = PENDING_BRANCH_PC + 0x40
    _drive_live_prediction(dut, used=True, target=TARGET_C)
    await _advance_cycle(dut)

    assert bool(dut.prediction_pending_saved_valid.value)
    assert int(dut.prediction_pc_pending_saved.value) == PENDING_BRANCH_PC
    assert int(dut.prediction_target_pending_saved.value) == TARGET_A

    dut.i_pending_prediction_fetch_holdoff.value = 0
    dut.i_output_pc.value = PENDING_BRANCH_PC
    _drive_live_prediction(dut, used=False, target=TARGET_B)
    await _settle()
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)


@cocotb.test()
async def test_pending_owner_kill_dominates_recapture_and_new_episode_reuses_pc(
    dut: Any,
) -> None:
    """A killed owner cannot leak into a later prediction at the same PC."""
    await _setup_test(dut)
    await _save_pending_prediction(dut, target=TARGET_A)

    # A redirect kill in the same cycle as a new registered prediction must
    # clear the saved metadata. (Nothing can be captured this cycle, because
    # the saved copy is still valid; see the first-pending-cycle test below.)
    dut.i_pending_prediction_kill.value = 1
    dut.i_pending_prediction_fetch_holdoff.value = 1
    _drive_live_prediction(dut, used=True, target=TARGET_B)
    dut.i_pending_prediction_pc.value = PENDING_BRANCH_PC
    dut.i_output_pc.value = PENDING_BRANCH_PC
    await _advance_cycle(dut)

    dut.i_pending_prediction_kill.value = 0
    dut.i_pending_prediction_active.value = 0
    dut.i_pending_prediction_fetch_holdoff.value = 0
    _drive_live_prediction(dut, used=False, target=TARGET_B)
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)
    assert not bool(dut.prediction_pending_saved_valid.value)

    # A new pending prediction at the same PC carries its own target.
    await _save_pending_prediction(dut, target=TARGET_C)
    await _settle()
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_C)


@cocotb.test()
async def test_kill_on_first_pending_cycle_beats_capture(dut: Any) -> None:
    """A kill on the first pending cycle, where capture would fire, saves nothing."""
    await _setup_test(dut)

    # First pending cycle: nothing is saved yet and a prediction is pending,
    # so without the kill this edge would capture TARGET_A.
    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_pending_prediction_active.value = 1
    dut.i_pending_prediction_pc.value = PENDING_BRANCH_PC
    dut.i_output_pc.value = PENDING_BRANCH_PC
    dut.i_pending_prediction_fetch_holdoff.value = 1
    dut.i_pending_prediction_kill.value = 1
    await _settle()
    assert not bool(dut.prediction_pending_saved_valid.value)
    assert bool(dut.pending_prediction_capture.value)
    await _advance_cycle(dut)

    # The kill won: nothing was saved, so the owner presented with the target
    # handoff after the redirect gets no prediction.
    dut.i_pending_prediction_kill.value = 0
    dut.i_pending_prediction_active.value = 0
    dut.i_pending_prediction_fetch_holdoff.value = 0
    dut.i_pending_prediction_target_handoff.value = 1
    _drive_live_prediction(dut, used=False, target=TARGET_B)
    await _settle()
    assert not bool(dut.prediction_pending_saved_valid.value)
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)


@cocotb.test()
async def test_saved_nop_suppresses_pending_replay_without_consuming_it(
    dut: Any,
) -> None:
    """A stall-saved NOP suppresses the pending replay without consuming it."""
    await _setup_test(dut)
    await _save_pending_prediction(dut)

    dut.i_use_saved_values.value = 1
    dut.i_sel_nop_saved.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)

    await _advance_cycle(dut)

    dut.i_sel_nop_saved.value = 0
    dut.i_pending_prediction_target_handoff.value = 1
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)


@cocotb.test()
async def test_stall_preserves_pending_prediction_capture(dut: Any) -> None:
    """A stall on the first pending cycle does not block capture of the prediction."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_stall.value = 1
    dut.i_pending_prediction_active.value = 1
    dut.i_pending_prediction_pc.value = PENDING_BRANCH_PC
    dut.i_output_pc.value = PENDING_PREDECESSOR_PC
    # pc_controller's immediate-predecessor exception has already released the
    # fetch holdoff; capture follows i_pending_prediction_active instead.
    dut.i_pending_prediction_fetch_holdoff.value = 0
    await _advance_cycle(dut)

    dut.i_stall.value = 0
    _drive_live_prediction(dut, used=False, target=TARGET_B)
    dut.i_output_pc.value = PENDING_BRANCH_PC
    dut.i_pending_prediction_target_handoff.value = 1
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)


@cocotb.test()
async def test_raw_wcs_predecessor_captures_without_prior_fetch_holdoff(
    dut: Any,
) -> None:
    """A predecessor emitted with the holdoff open neither takes nor loses the metadata."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_pending_prediction_active.value = 1
    dut.i_pending_prediction_pc.value = PENDING_BRANCH_PC
    dut.i_output_pc.value = PENDING_PREDECESSOR_PC
    dut.i_pending_prediction_fetch_holdoff.value = 0
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)

    await _advance_cycle(dut)
    assert bool(dut.prediction_pending_saved_valid.value)
    assert int(dut.prediction_pc_pending_saved.value) == PENDING_BRANCH_PC

    _drive_live_prediction(dut, used=False, target=TARGET_B)
    dut.i_output_pc.value = PENDING_BRANCH_PC
    dut.i_pending_prediction_target_handoff.value = 1
    await _settle()
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)


@cocotb.test()
async def test_first_pending_owner_consumes_registered_metadata_without_replay(
    dut: Any,
) -> None:
    """An owner on the first pending cycle consumes the metadata without saving a copy."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_pending_prediction_active.value = 1
    dut.i_pending_prediction_pc.value = PENDING_BRANCH_PC
    dut.i_output_pc.value = PENDING_BRANCH_PC
    dut.i_pending_prediction_target_handoff.value = 1
    await _settle()
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    await _advance_cycle(dut)
    assert not bool(dut.prediction_pending_saved_valid.value)

    dut.i_pending_prediction_active.value = 0
    _drive_live_prediction(dut, used=False, target=TARGET_B)
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)


@cocotb.test()
async def test_flush_clears_pending_prediction_replay(dut: Any) -> None:
    """Flush discards pending prediction metadata before it can replay."""
    await _setup_test(dut)
    await _save_pending_prediction(dut)

    dut.i_flush.value = 1
    await _advance_cycle(dut)

    dut.i_flush.value = 0
    dut.i_pending_prediction_active.value = 0
    _drive_live_prediction(dut, used=False, target=TARGET_C)
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_C)

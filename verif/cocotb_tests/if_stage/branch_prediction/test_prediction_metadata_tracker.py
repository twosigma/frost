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
    dut.i_prediction_holdoff.value = 0
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
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_reset.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_reset.value = 0
    await _settle()


def _drive_live_prediction(dut: Any, *, used: bool, target: int) -> None:
    """Drive matching registered and live target provenance inputs."""
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
    """Save one prediction while its pending fetch episode is active."""
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
    """A no-lead emitted branch carries the prediction used that same cycle."""
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
    """An unowned invalid target stays live without alignment/control muxes."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=False, target=TARGET_A)
    dut.i_live_predicted_target.value = TARGET_B

    # Neither source is valid, so the live payload is harmless in both phases.
    # Raw PC alignment is not part of the wide target mux.
    dut.i_live_target_aligned_with_output.value = 0
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)

    dut.i_live_target_aligned_with_output.value = 1
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)

    # NOP and pending-fetch holdoff clear validity without changing the wide
    # payload source. This is the timing contract exercised by CSR stalls.
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

    # Model the self-target/RAS-pop corner: the raw lookup still has the same
    # packet PC but now exposes a different target while a holdoff invalidates
    # the output. The registered packet payload remains stable.
    dut.i_pending_prediction_fetch_holdoff.value = 1
    await _settle()
    _assert_metadata(dut, hit=False, taken=False, target=TARGET_A)


@cocotb.test()
async def test_nop_output_clears_validity_without_zeroing_payload(dut: Any) -> None:
    """NOP selection suppresses validity without entering the target dataplane."""
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
    # wide payload needs no separate stall-saved replica.
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

    # pc_controller drops the active episode on the same handoff edge.
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
    """A released predecessor cannot spend the younger branch's metadata."""
    await _setup_test(dut)
    await _save_pending_prediction(dut)

    # Model the served-window immediate-predecessor carve-out on a stall-release
    # packet: the holdoff is open and the packet is real, but its saved PC is
    # B-2 rather than the pending branch B. The old first-non-NOP policy stamped
    # this packet predicted-taken and consumed the metadata here.
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

    # pc_controller drops the active episode on the same handoff edge.
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
    """The first owner and target remain immutable until consume or kill."""
    await _setup_test(dut)
    await _save_pending_prediction(dut, target=TARGET_A)

    # Keep the episode's fetch holdoff active while an unrelated registered
    # prediction appears. The saved packet must not be overwritten.
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

    # A redirect kill coincident with another apparent capture must clear the
    # old packet; kill has priority over both capture and consume.
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

    # A fresh episode at the same PC owns its new target independently.
    await _save_pending_prediction(dut, target=TARGET_C)
    await _settle()
    _assert_metadata(dut, hit=True, taken=True, target=TARGET_C)


@cocotb.test()
async def test_saved_nop_suppresses_pending_replay_without_consuming_it(
    dut: Any,
) -> None:
    """Saved NOP state participates in pending replay suppression."""
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
    """A stall cannot hide the first pending-active registered prediction."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_stall.value = 1
    dut.i_pending_prediction_active.value = 1
    dut.i_pending_prediction_pc.value = PENDING_BRANCH_PC
    dut.i_output_pc.value = PENDING_PREDECESSOR_PC
    # The raw-WCS immediate-predecessor carve-out has already opened the fetch
    # holdoff; pending-active is the durable lifecycle signal.
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
    """The first open-holdoff predecessor cannot steal or lose branch metadata."""
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
    """A directly arriving owner does not leave an orphaned replay entry."""
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

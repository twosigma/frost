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


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_stall.value = 0
    dut.i_flush.value = 0
    dut.i_prediction_holdoff.value = 0
    dut.i_stall_registered.value = 0
    dut.i_prediction_used_r.value = 0
    dut.i_predicted_target_r.value = 0
    dut.i_pending_prediction_fetch_holdoff.value = 0
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
    """Drive the currently registered prediction metadata input."""
    dut.i_prediction_used_r.value = int(used)
    dut.i_predicted_target_r.value = target


def _assert_metadata(dut: Any, *, hit: bool, taken: bool, target: int) -> None:
    """Assert the tracker metadata outputs."""
    assert bool(dut.o_btb_hit.value) is hit
    assert bool(dut.o_btb_predicted_taken.value) is taken
    assert int(dut.o_btb_predicted_target.value) == target


async def _save_pending_prediction(dut: Any, *, target: int = TARGET_A) -> None:
    """Save one prediction while the pending fetch holdoff is active."""
    _drive_live_prediction(dut, used=True, target=target)
    dut.i_pending_prediction_fetch_holdoff.value = 1
    await _advance_cycle(dut)

    _drive_live_prediction(dut, used=False, target=TARGET_B)
    dut.i_pending_prediction_fetch_holdoff.value = 0
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
async def test_nop_output_clears_live_and_saved_metadata(dut: Any) -> None:
    """NOP selection suppresses stale prediction metadata."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_sel_nop.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=0)

    dut.i_sel_nop.value = 0
    dut.i_sel_nop_saved.value = 1
    dut.i_use_saved_values.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=0)


@cocotb.test()
async def test_stall_start_saves_and_restores_prediction_metadata(dut: Any) -> None:
    """The first stall cycle snapshots metadata for later saved-value replay."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_stall.value = 1
    dut.i_stall_registered.value = 0
    await _advance_cycle(dut)

    _drive_live_prediction(dut, used=False, target=TARGET_B)
    dut.i_stall.value = 0
    dut.i_stall_registered.value = 1
    dut.i_use_saved_values.value = 1
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    dut.i_use_saved_values.value = 0
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
    dut.i_pending_prediction_fetch_holdoff.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=0)

    await _advance_cycle(dut)

    _drive_live_prediction(dut, used=False, target=TARGET_B)
    dut.i_pending_prediction_fetch_holdoff.value = 0
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)

    await _advance_cycle(dut)

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_B)


@cocotb.test()
async def test_pending_prediction_survives_nop_until_real_instruction(dut: Any) -> None:
    """A NOP cycle suppresses pending replay without consuming the saved metadata."""
    await _setup_test(dut)
    await _save_pending_prediction(dut)

    dut.i_sel_nop.value = 1
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=0)

    await _advance_cycle(dut)

    dut.i_sel_nop.value = 0
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)


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

    _assert_metadata(dut, hit=False, taken=False, target=0)

    await _advance_cycle(dut)

    dut.i_sel_nop_saved.value = 0
    await _settle()

    _assert_metadata(dut, hit=True, taken=True, target=TARGET_A)


@cocotb.test()
async def test_stall_blocks_pending_prediction_capture(dut: Any) -> None:
    """Pending metadata is not captured while the front end is stalled."""
    await _setup_test(dut)

    _drive_live_prediction(dut, used=True, target=TARGET_A)
    dut.i_stall.value = 1
    dut.i_pending_prediction_fetch_holdoff.value = 1
    await _advance_cycle(dut)

    dut.i_stall.value = 0
    dut.i_pending_prediction_fetch_holdoff.value = 0
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
    _drive_live_prediction(dut, used=False, target=TARGET_C)
    await _settle()

    _assert_metadata(dut, hit=False, taken=False, target=TARGET_C)

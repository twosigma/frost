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

"""Unit tests for the IF-stage control-flow holdoff tracker."""

from typing import Any, Literal

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
WORD_TARGET = 0x80001000
HALFWORD_TARGET = 0x80001002
RedirectSource = Literal["branch", "trap", "mret", "pd", "prediction", "slot2"]


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_stall.value = 0
    dut.i_fetch_progress.value = 1
    dut.i_flush.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_trap_taken.value = 0
    dut.i_mret_taken.value = 0
    dut.i_branch_taken.value = 0
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0
    dut.i_prediction_used.value = 0
    dut.i_slot2_prediction_used.value = 0
    dut.i_slot2_predicted_target.value = 0
    dut.i_branch_target.value = 0
    dut.i_trap_target.value = 0
    dut.i_predicted_target.value = 0
    dut.i_spanning_to_halfword_registered.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the tracker, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_reset.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_reset.value = 0
    await _settle()


async def _clear_reset_holdoff(dut: Any) -> None:
    """Advance one idle cycle past the reset holdoff window."""
    await _advance_cycle(dut)


def _drive_redirect(dut: Any, source: RedirectSource, target: int) -> None:
    """Drive one redirect source and its matching target signal."""
    if source == "branch":
        dut.i_branch_taken.value = 1
        dut.i_branch_target.value = target
    elif source == "trap":
        dut.i_trap_taken.value = 1
        dut.i_trap_target.value = target
    elif source == "mret":
        dut.i_mret_taken.value = 1
        dut.i_trap_target.value = target
    elif source == "pd":
        dut.i_pd_redirect.value = 1
        dut.i_pd_redirect_target.value = target
    elif source == "prediction":
        dut.i_prediction_used.value = 1
        dut.i_predicted_target.value = target
    else:
        dut.i_slot2_prediction_used.value = 1
        dut.i_slot2_predicted_target.value = target


def _assert_holdoffs(
    dut: Any,
    *,
    change: bool,
    holdoff: bool,
    reset: bool,
    any_holdoff: bool,
    safe: bool,
) -> None:
    """Assert the tracker holdoff outputs."""
    assert bool(dut.o_control_flow_change.value) is change
    assert bool(dut.o_control_flow_holdoff.value) is holdoff
    assert bool(dut.o_reset_holdoff.value) is reset
    assert bool(dut.o_any_holdoff.value) is any_holdoff
    assert bool(dut.o_any_holdoff_safe.value) is safe


@cocotb.test()
async def test_reset_holdoff_asserts_until_idle_cycle(dut: Any) -> None:
    """Reset asserts the registered reset holdoff until an idle cycle passes."""
    await _setup_test(dut)

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=False,
        reset=True,
        any_holdoff=True,
        safe=True,
    )
    assert not dut.o_control_flow_to_halfword_r.value

    await _clear_reset_holdoff(dut)

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=False,
        reset=False,
        any_holdoff=False,
        safe=False,
    )


@cocotb.test()
async def test_reset_holdoff_persists_while_stalled(dut: Any) -> None:
    """Reset holdoff remains asserted while the front end is stalled."""
    await _setup_test(dut)

    dut.i_stall.value = 1
    await _advance_cycle(dut)

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=False,
        reset=True,
        any_holdoff=True,
        safe=True,
    )

    dut.i_stall.value = 0
    await _advance_cycle(dut)

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=False,
        reset=False,
        any_holdoff=False,
        safe=False,
    )


@cocotb.test()
async def test_redirect_sets_combinational_then_registered_holdoff(dut: Any) -> None:
    """Redirects assert any_holdoff immediately and safe holdoff next cycle."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)

    _drive_redirect(dut, "branch", WORD_TARGET)
    await _settle()

    _assert_holdoffs(
        dut,
        change=True,
        holdoff=False,
        reset=False,
        any_holdoff=True,
        safe=False,
    )

    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _settle()

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=True,
        reset=False,
        any_holdoff=True,
        safe=True,
    )

    await _advance_cycle(dut)

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=False,
        reset=False,
        any_holdoff=False,
        safe=False,
    )


@cocotb.test()
async def test_redirect_holdoff_stays_asserted_while_stalled(dut: Any) -> None:
    """A redirect holdoff is latched across front-end backpressure."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)

    _drive_redirect(dut, "prediction", WORD_TARGET)
    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _settle()

    dut.i_stall.value = 1
    for _ in range(2):
        await _advance_cycle(dut)
        _assert_holdoffs(
            dut,
            change=False,
            holdoff=True,
            reset=False,
            any_holdoff=True,
            safe=True,
        )

    dut.i_stall.value = 0
    await _advance_cycle(dut)

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=False,
        reset=False,
        any_holdoff=False,
        safe=False,
    )


@cocotb.test()
async def test_fence_i_flush_generates_holdoff_without_halfword_target(
    dut: Any,
) -> None:
    """FENCE.I flush arms a registered stale-fetch holdoff without a target."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)

    dut.i_fence_i_flush.value = 1
    await _settle()

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=False,
        reset=False,
        any_holdoff=False,
        safe=False,
    )
    assert not dut.o_control_flow_to_halfword.value

    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _settle()

    _assert_holdoffs(
        dut,
        change=False,
        holdoff=True,
        reset=False,
        any_holdoff=True,
        safe=True,
    )
    assert not dut.o_control_flow_to_halfword_r.value


@cocotb.test()
async def test_halfword_targets_are_latched_for_all_redirect_sources(dut: Any) -> None:
    """Every redirect target source contributes to halfword-target tracking."""
    redirect_sources: tuple[RedirectSource, ...] = (
        "branch",
        "trap",
        "mret",
        "pd",
        "prediction",
        "slot2",
    )

    for source in redirect_sources:
        await _setup_test(dut)
        await _clear_reset_holdoff(dut)

        _drive_redirect(dut, source, HALFWORD_TARGET)
        await _settle()

        assert dut.o_control_flow_change.value
        assert dut.o_control_flow_to_halfword.value

        await _advance_cycle(dut)
        _clear_inputs(dut)
        await _settle()

        assert dut.o_control_flow_to_halfword_r.value

        await _advance_cycle(dut)

        assert not dut.o_control_flow_to_halfword_r.value


@cocotb.test()
async def test_word_aligned_redirect_does_not_latch_halfword_state(dut: Any) -> None:
    """Word-aligned redirects do not mark the control flow as halfword-aligned."""
    await _setup_test(dut)
    await _clear_reset_holdoff(dut)

    _drive_redirect(dut, "slot2", WORD_TARGET)
    await _settle()

    assert dut.o_control_flow_change.value
    assert not dut.o_control_flow_to_halfword.value

    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _settle()

    assert not dut.o_control_flow_to_halfword_r.value

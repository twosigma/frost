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

"""Unit tests for the IF-stage return address stack."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
RAS_DEPTH = 8


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_stall_registered.value = 0
    dut.i_is_call.value = 0
    dut.i_is_return.value = 0
    dut.i_is_coroutine.value = 0
    dut.i_link_address.value = 0
    dut.i_prediction_allowed.value = 1
    dut.i_prediction_allowed_for_write.value = 1
    dut.i_btb_only_prediction_holdoff.value = 0
    dut.i_misprediction.value = 0
    dut.i_restore_tos.value = 0
    dut.i_restore_valid_count.value = 0
    dut.i_pop_after_restore.value = 0
    dut.i_push_after_restore.value = 0
    dut.i_push_address_after_restore.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the RAS, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await _settle()


async def _push(dut: Any, address: int) -> None:
    """Push one return address."""
    _clear_inputs(dut)
    dut.i_is_call.value = 1
    dut.i_link_address.value = address
    await _advance_cycle(dut)
    dut.i_is_call.value = 0
    await _settle()


def _drive_return(dut: Any, *, prediction_allowed: bool = True) -> None:
    """Drive a return prediction request."""
    dut.i_is_return.value = 1
    dut.i_prediction_allowed.value = int(prediction_allowed)


async def _pop(dut: Any) -> None:
    """Pop one return address."""
    _clear_inputs(dut)
    _drive_return(dut)
    await _advance_cycle(dut)
    dut.i_is_return.value = 0
    await _settle()


def _assert_checkpoint(dut: Any, *, tos: int, count: int) -> None:
    """Assert RAS checkpoint state."""
    assert int(dut.o_checkpoint_tos.value) == tos % RAS_DEPTH
    assert int(dut.o_checkpoint_valid_count.value) == count


@cocotb.test()
async def test_reset_and_empty_return_are_idle(dut: Any) -> None:
    """Reset clears checkpoint state and empty returns are invalid."""
    await _setup_test(dut)

    _drive_return(dut)
    await _settle()

    assert not dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0
    _assert_checkpoint(dut, tos=0, count=0)


@cocotb.test()
async def test_push_predict_and_pop_lifo_order(dut: Any) -> None:
    """Calls push return addresses and returns pop in LIFO order."""
    await _setup_test(dut)

    await _push(dut, 0x1004)
    _assert_checkpoint(dut, tos=1, count=1)

    await _push(dut, 0x2004)
    _assert_checkpoint(dut, tos=2, count=2)

    _drive_return(dut)
    await _settle()

    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0x2004

    await _pop(dut)
    _assert_checkpoint(dut, tos=1, count=1)

    _drive_return(dut)
    await _settle()

    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0x1004

    await _pop(dut)
    assert not dut.o_ras_valid.value
    _assert_checkpoint(dut, tos=0, count=0)


@cocotb.test()
async def test_return_valid_ignores_prediction_gate_but_pop_uses_it(dut: Any) -> None:
    """A blocked prediction remains visible but does not consume the stack."""
    await _setup_test(dut)
    await _push(dut, 0x3004)

    _clear_inputs(dut)
    dut.i_is_return.value = 1
    dut.i_prediction_allowed.value = 0
    dut.i_btb_only_prediction_holdoff.value = 1
    await _settle()

    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0x3004

    await _advance_cycle(dut)

    _assert_checkpoint(dut, tos=1, count=1)
    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0x3004


@cocotb.test()
async def test_stall_registered_blocks_push_and_pop_state_updates(dut: Any) -> None:
    """Registered stall blocks stack mutation for call and return operations."""
    await _setup_test(dut)

    dut.i_stall_registered.value = 1
    dut.i_is_call.value = 1
    dut.i_link_address.value = 0x4004
    await _advance_cycle(dut)

    _assert_checkpoint(dut, tos=0, count=0)

    _clear_inputs(dut)
    await _push(dut, 0x5004)

    dut.i_stall_registered.value = 1
    dut.i_is_return.value = 1
    await _settle()

    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0x5004

    await _advance_cycle(dut)

    _assert_checkpoint(dut, tos=1, count=1)


@cocotb.test()
async def test_coroutine_replaces_top_without_changing_depth(dut: Any) -> None:
    """Coroutine operation replaces the top return address without changing depth."""
    await _setup_test(dut)
    await _push(dut, 0x6004)

    _clear_inputs(dut)
    dut.i_is_coroutine.value = 1
    dut.i_link_address.value = 0x7004
    await _settle()

    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0x6004

    await _advance_cycle(dut)

    _assert_checkpoint(dut, tos=1, count=1)
    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0x7004


@cocotb.test()
async def test_restore_checkpoint_discards_speculative_pushes(dut: Any) -> None:
    """Misprediction restore returns the stack to an older checkpoint."""
    await _setup_test(dut)
    await _push(dut, 0x8004)
    saved_tos = int(dut.o_checkpoint_tos.value)
    saved_count = int(dut.o_checkpoint_valid_count.value)

    await _push(dut, 0x9004)
    _assert_checkpoint(dut, tos=2, count=2)

    _clear_inputs(dut)
    dut.i_misprediction.value = 1
    dut.i_restore_tos.value = saved_tos
    dut.i_restore_valid_count.value = saved_count
    await _advance_cycle(dut)

    _assert_checkpoint(dut, tos=1, count=1)
    _drive_return(dut)
    await _settle()

    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0x8004


@cocotb.test()
async def test_restore_with_pop_after_restore_replays_return_pop(dut: Any) -> None:
    """Recovery can restore a checkpoint and then consume one return entry."""
    await _setup_test(dut)
    await _push(dut, 0xA004)
    await _push(dut, 0xB004)

    _clear_inputs(dut)
    dut.i_misprediction.value = 1
    dut.i_restore_tos.value = 2
    dut.i_restore_valid_count.value = 2
    dut.i_pop_after_restore.value = 1
    await _advance_cycle(dut)

    _assert_checkpoint(dut, tos=1, count=1)
    _drive_return(dut)
    await _settle()

    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0xA004


@cocotb.test()
async def test_restore_with_push_after_restore_adds_return_address(dut: Any) -> None:
    """Recovery can restore a checkpoint and push a replacement return address."""
    await _setup_test(dut)

    _clear_inputs(dut)
    dut.i_misprediction.value = 1
    dut.i_restore_tos.value = 0
    dut.i_restore_valid_count.value = 0
    dut.i_push_after_restore.value = 1
    dut.i_push_address_after_restore.value = 0xC004
    await _advance_cycle(dut)

    _assert_checkpoint(dut, tos=1, count=1)
    _drive_return(dut)
    await _settle()

    assert dut.o_ras_valid.value
    assert int(dut.o_ras_target.value) == 0xC004

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

"""Unit tests for the IF-stage branch direction predictor."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
BIM_BITS = 10
BIM_MASK = (1 << BIM_BITS) - 1

PC_A = 0x80000100
PC_A_ODD_ALIAS = PC_A | 0x1
PC_A_HALFWORD = PC_A | 0x2
PC_B = 0x80000120
PC_C = 0x80000240


def _idx(pc: int) -> int:
    """Return the predictor index used by the RTL."""
    return (pc >> 1) & BIM_MASK


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_pc.value = 0
    dut.i_update_valid.value = 0
    dut.i_update_idx.value = 0
    dut.i_update_taken.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered RAM writes settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, apply reset, and clear inputs."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await _settle()


async def _lookup(dut: Any, pc: int) -> None:
    """Drive one lookup PC and wait for async read outputs."""
    dut.i_pc.value = pc
    await _settle()


async def _train_idx(dut: Any, idx: int, *, taken: bool) -> None:
    """Apply one commit-time training update to a carried prediction index."""
    dut.i_update_valid.value = 1
    dut.i_update_idx.value = idx
    dut.i_update_taken.value = int(taken)
    await _advance_cycle(dut)
    dut.i_update_valid.value = 0
    await _settle()


async def _train_pc(dut: Any, pc: int, *, taken: bool, count: int = 1) -> None:
    """Apply repeated training updates for the index selected by a fetch PC."""
    for _ in range(count):
        await _train_idx(dut, _idx(pc), taken=taken)


@cocotb.test()
async def test_initial_state_is_weak_not_taken_and_exports_pc_index(dut: Any) -> None:
    """Initial zeroed counters predict not-taken and expose pc[BIM_BITS:1]."""
    await _setup_test(dut)

    await _lookup(dut, PC_A)

    assert not dut.o_taken.value
    assert int(dut.o_pred_idx.value) == _idx(PC_A)


@cocotb.test()
async def test_pc_bit_zero_is_ignored_but_bit_one_selects_distinct_index(
    dut: Any,
) -> None:
    """Indexing drops PC[0] but keeps PC[1] for halfword-aligned branches."""
    await _setup_test(dut)

    await _lookup(dut, PC_A)
    assert int(dut.o_pred_idx.value) == _idx(PC_A_ODD_ALIAS)

    await _lookup(dut, PC_A_ODD_ALIAS)
    assert int(dut.o_pred_idx.value) == _idx(PC_A)

    await _lookup(dut, PC_A_HALFWORD)
    assert int(dut.o_pred_idx.value) == _idx(PC_A_HALFWORD)
    assert int(dut.o_pred_idx.value) != _idx(PC_A)


@cocotb.test()
async def test_taken_training_requires_two_updates_then_saturates(dut: Any) -> None:
    """The 2-bit counter starts weak-not-taken and saturates at strongly taken."""
    await _setup_test(dut)

    await _train_pc(dut, PC_A, taken=True)
    await _lookup(dut, PC_A)
    assert not dut.o_taken.value

    await _train_pc(dut, PC_A, taken=True)
    await _lookup(dut, PC_A)
    assert dut.o_taken.value

    await _train_pc(dut, PC_A, taken=True, count=2)
    await _train_pc(dut, PC_A, taken=False)
    await _lookup(dut, PC_A)
    assert dut.o_taken.value


@cocotb.test()
async def test_not_taken_training_has_hysteresis_and_saturates(dut: Any) -> None:
    """Taken counters tolerate one not-taken update before predicting not-taken."""
    await _setup_test(dut)

    await _train_pc(dut, PC_A, taken=True, count=3)
    await _lookup(dut, PC_A)
    assert dut.o_taken.value

    await _train_pc(dut, PC_A, taken=False)
    await _lookup(dut, PC_A)
    assert dut.o_taken.value

    await _train_pc(dut, PC_A, taken=False)
    await _lookup(dut, PC_A)
    assert not dut.o_taken.value

    await _train_pc(dut, PC_A, taken=False, count=2)
    await _train_pc(dut, PC_A, taken=True)
    await _lookup(dut, PC_A)
    assert not dut.o_taken.value


@cocotb.test()
async def test_training_uses_carried_update_index_not_current_lookup_pc(
    dut: Any,
) -> None:
    """Commit-time training writes i_update_idx even when i_pc points elsewhere."""
    await _setup_test(dut)

    await _lookup(dut, PC_A)
    await _train_idx(dut, _idx(PC_B), taken=True)
    await _train_idx(dut, _idx(PC_B), taken=True)

    await _lookup(dut, PC_A)
    assert not dut.o_taken.value

    await _lookup(dut, PC_B)
    assert dut.o_taken.value


@cocotb.test()
async def test_independent_indices_do_not_poison_each_other(dut: Any) -> None:
    """Training one direction index does not alter another predictor entry."""
    await _setup_test(dut)

    await _train_pc(dut, PC_A, taken=True, count=2)
    await _train_pc(dut, PC_C, taken=False, count=3)

    await _lookup(dut, PC_A)
    assert dut.o_taken.value

    await _lookup(dut, PC_C)
    assert not dut.o_taken.value

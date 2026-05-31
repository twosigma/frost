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

"""Unit tests for the IF-stage branch target buffer predictor."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
PC_A = 0x80000100
PC_B = 0x80000104
PC_A_HALFWORD_ALIAS = PC_A | 0x2
PC_A_INDEX_ALIAS = PC_A + 0x400
TARGET_A = 0x80001000
TARGET_B = 0x80002000


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_pc.value = 0
    dut.i_pc_2.value = 0
    dut.i_update.value = 0
    dut.i_update_pc.value = 0
    dut.i_update_target.value = 0
    dut.i_update_taken.value = 0
    dut.i_update_compressed.value = 0
    dut.i_update_requires_pc_reg_handoff.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset valid bits, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await _settle()


async def _update(
    dut: Any,
    *,
    pc: int,
    target: int,
    taken: bool,
    compressed: bool = False,
    handoff: bool = False,
) -> None:
    """Apply one BTB update and clear the update port."""
    dut.i_update.value = 1
    dut.i_update_pc.value = pc
    dut.i_update_target.value = target
    dut.i_update_taken.value = int(taken)
    dut.i_update_compressed.value = int(compressed)
    dut.i_update_requires_pc_reg_handoff.value = int(handoff)
    await _advance_cycle(dut)
    dut.i_update.value = 0
    await _settle()


async def _lookup(dut: Any, pc: int, *, slot2: bool = False) -> None:
    """Drive one lookup PC and wait for async read outputs."""
    if slot2:
        dut.i_pc_2.value = pc
    else:
        dut.i_pc.value = pc
    await _settle()


def _assert_slot1(
    dut: Any,
    *,
    hit: bool,
    taken: bool,
    target: int,
    compressed: bool = False,
    handoff: bool = False,
) -> None:
    """Assert slot-1 lookup outputs."""
    assert bool(dut.o_btb_hit.value) is hit
    assert bool(dut.o_predicted_taken.value) is taken
    assert int(dut.o_predicted_target.value) == target
    assert bool(dut.o_btb_compressed.value) is compressed
    assert bool(dut.o_btb_requires_pc_reg_handoff.value) is handoff


def _assert_slot2(
    dut: Any,
    *,
    hit: bool,
    taken: bool,
    target: int,
    compressed: bool = False,
    handoff: bool = False,
) -> None:
    """Assert slot-2 lookup outputs."""
    assert bool(dut.o_btb_hit_2.value) is hit
    assert bool(dut.o_predicted_taken_2.value) is taken
    assert int(dut.o_predicted_target_2.value) == target
    assert bool(dut.o_btb_compressed_2.value) is compressed
    assert bool(dut.o_btb_requires_pc_reg_handoff_2.value) is handoff


@cocotb.test()
async def test_reset_clears_valid_bits_for_both_lookup_ports(dut: Any) -> None:
    """Reset leaves both lookup ports as misses even at initialized RAM contents."""
    await _setup_test(dut)

    await _lookup(dut, PC_A)
    await _lookup(dut, PC_A, slot2=True)

    assert not dut.o_btb_hit.value
    assert not dut.o_predicted_taken.value
    assert not dut.o_btb_hit_2.value
    assert not dut.o_predicted_taken_2.value


@cocotb.test()
async def test_first_taken_update_creates_weak_taken_hit_with_metadata(
    dut: Any,
) -> None:
    """A first taken update creates a hit with weak-taken prediction metadata."""
    await _setup_test(dut)

    await _update(
        dut,
        pc=PC_A,
        target=TARGET_A,
        taken=True,
        compressed=True,
        handoff=True,
    )
    await _lookup(dut, PC_A)

    _assert_slot1(
        dut,
        hit=True,
        taken=True,
        target=TARGET_A,
        compressed=True,
        handoff=True,
    )


@cocotb.test()
async def test_first_not_taken_update_hits_but_does_not_predict_taken(dut: Any) -> None:
    """A first not-taken update creates a weak-not-taken hit."""
    await _setup_test(dut)

    await _update(dut, pc=PC_A, target=TARGET_A, taken=False)
    await _lookup(dut, PC_A)

    _assert_slot1(dut, hit=True, taken=False, target=TARGET_A)


@cocotb.test()
async def test_two_bit_counter_hysteresis_and_saturation(dut: Any) -> None:
    """The 2-bit counter tolerates one opposite outcome and saturates at edges."""
    await _setup_test(dut)

    for _ in range(3):
        await _update(dut, pc=PC_A, target=TARGET_A, taken=True)
    await _lookup(dut, PC_A)

    assert dut.o_predicted_taken.value

    await _update(dut, pc=PC_A, target=TARGET_A, taken=False)
    await _lookup(dut, PC_A)

    assert dut.o_predicted_taken.value

    await _update(dut, pc=PC_A, target=TARGET_A, taken=False)
    await _lookup(dut, PC_A)

    assert not dut.o_predicted_taken.value

    for _ in range(3):
        await _update(dut, pc=PC_A, target=TARGET_A, taken=False)
    await _lookup(dut, PC_A)

    assert not dut.o_predicted_taken.value

    await _update(dut, pc=PC_A, target=TARGET_A, taken=True)
    await _lookup(dut, PC_A)

    assert not dut.o_predicted_taken.value


@cocotb.test()
async def test_tag_includes_pc_bit_one_for_halfword_aligned_aliases(dut: Any) -> None:
    """PC[1] is part of the tag, so 0x...100 and 0x...102 do not alias."""
    await _setup_test(dut)

    await _update(dut, pc=PC_A, target=TARGET_A, taken=True)

    await _lookup(dut, PC_A)
    assert dut.o_btb_hit.value

    await _lookup(dut, PC_A_HALFWORD_ALIAS)
    assert not dut.o_btb_hit.value
    assert not dut.o_predicted_taken.value
    assert not dut.o_btb_compressed.value
    assert not dut.o_btb_requires_pc_reg_handoff.value


@cocotb.test()
async def test_tag_mismatch_replaces_direct_mapped_entry(dut: Any) -> None:
    """A same-index different-tag update replaces the old direct-mapped entry."""
    await _setup_test(dut)

    await _update(dut, pc=PC_A, target=TARGET_A, taken=True)
    await _update(dut, pc=PC_A_INDEX_ALIAS, target=TARGET_B, taken=True)

    await _lookup(dut, PC_A)
    assert not dut.o_btb_hit.value

    await _lookup(dut, PC_A_INDEX_ALIAS)
    _assert_slot1(dut, hit=True, taken=True, target=TARGET_B)


@cocotb.test()
async def test_slot2_lookup_matches_slot1_metadata(dut: Any) -> None:
    """The replicated slot-2 lookup port returns the same entry metadata."""
    await _setup_test(dut)

    await _update(
        dut,
        pc=PC_A,
        target=TARGET_A,
        taken=True,
        compressed=True,
        handoff=True,
    )

    await _lookup(dut, PC_A, slot2=True)

    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_A,
        compressed=True,
        handoff=True,
    )


@cocotb.test()
async def test_independent_indices_do_not_poison_each_other(dut: Any) -> None:
    """Updating one BTB index leaves a different-index entry intact."""
    await _setup_test(dut)

    await _update(dut, pc=PC_A, target=TARGET_A, taken=True, compressed=True)
    await _update(dut, pc=PC_B, target=TARGET_B, taken=False, handoff=True)

    await _lookup(dut, PC_A)
    _assert_slot1(dut, hit=True, taken=True, target=TARGET_A, compressed=True)

    await _lookup(dut, PC_B)
    _assert_slot1(dut, hit=True, taken=False, target=TARGET_B, handoff=True)

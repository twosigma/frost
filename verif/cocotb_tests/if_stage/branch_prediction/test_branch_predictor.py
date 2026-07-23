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
    dut.i_pc_2_base.value = 0
    dut.i_pc_2_use_alt.value = 0
    dut.i_update.value = 0
    dut.i_update_pc.value = 0
    dut.i_update_target.value = 0
    dut.i_update_taken.value = 0
    dut.i_update_compressed.value = 0
    dut.i_update_requires_pc_reg_handoff.value = 0
    dut.i_early_update_active.value = 0
    dut.i_early_update_pc.value = 0
    dut.i_early_update_taken.value = 0
    dut.i_late_update_pc.value = 0
    dut.i_late_update_taken.value = 0


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
    early_active: bool = False,
    early_pc: int | None = None,
    early_taken: bool | None = None,
    late_pc: int | None = None,
    late_taken: bool | None = None,
) -> None:
    """Apply one selected BTB write with independent early/late RMW inputs."""
    selected_early_pc = pc if early_active and early_pc is None else (early_pc or 0)
    selected_early_taken = (
        taken if early_active and early_taken is None else bool(early_taken)
    )
    selected_late_pc = pc if late_pc is None else late_pc
    selected_late_taken = taken if late_taken is None else late_taken
    if early_active:
        # This is the integration contract guaranteed by the update-priority
        # mux: the sideband chooses an RMW candidate, never a different write.
        assert selected_early_pc == pc
        assert selected_early_taken is taken
    else:
        assert selected_late_pc == pc
        assert selected_late_taken is taken

    dut.i_update.value = 1
    dut.i_update_pc.value = pc
    dut.i_update_target.value = target
    dut.i_update_taken.value = int(taken)
    dut.i_update_compressed.value = int(compressed)
    dut.i_update_requires_pc_reg_handoff.value = int(handoff)
    dut.i_early_update_active.value = int(early_active)
    dut.i_early_update_pc.value = selected_early_pc
    dut.i_early_update_taken.value = int(selected_early_taken)
    dut.i_late_update_pc.value = selected_late_pc
    dut.i_late_update_taken.value = int(selected_late_taken)
    await _advance_cycle(dut)
    dut.i_update.value = 0
    dut.i_early_update_active.value = 0
    await _settle()


async def _lookup(dut: Any, pc: int, *, slot2: bool = False) -> None:
    """Drive one lookup PC and wait for async read outputs."""
    if slot2:
        # The normal shifted replica stores actual U under predecessor U-2.
        dut.i_pc_2_base.value = (pc - 2) & 0xFFFFFFFF
        dut.i_pc_2_use_alt.value = 0
    else:
        dut.i_pc.value = pc
    await _settle()


async def _lookup_slot2_alt(dut: Any, base_pc: int) -> None:
    """Look up the actual base_pc+4 entry through the shifted ALT replica."""
    dut.i_pc_2_base.value = base_pc & 0xFFFFFFFF
    dut.i_pc_2_use_alt.value = 1
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
async def test_parallel_early_and_late_rmw_share_exact_counter_history(
    dut: Any,
) -> None:
    """Alternating candidate selection preserves one cycle-exact hysteresis stream."""
    await _setup_test(dut)

    # Build StronglyTaken exclusively through the late candidate.  The inactive
    # early sideband points at unrelated state so it cannot accidentally supply
    # the selected result.
    for _ in range(3):
        await _update(
            dut,
            pc=PC_A,
            target=TARGET_A,
            taken=True,
            early_pc=PC_B,
            early_taken=False,
        )

    # The early canonical replica must have received those late-selected writes.
    # One not-taken update therefore moves StronglyTaken -> WeaklyTaken and must
    # keep predicting taken.
    await _update(
        dut,
        pc=PC_A,
        target=TARGET_B,
        taken=False,
        early_active=True,
        late_pc=PC_B,
        late_taken=False,
    )
    await _lookup(dut, PC_A)
    _assert_slot1(dut, hit=True, taken=True, target=TARGET_B)

    await _lookup(dut, PC_A, slot2=True)
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_B)
    await _lookup_slot2_alt(dut, PC_A - 4)
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_B)

    # Consecutive early writes exercise same-index next-edge visibility.
    await _update(
        dut,
        pc=PC_A,
        target=TARGET_A,
        taken=False,
        early_active=True,
        late_pc=PC_B,
        late_taken=True,
    )
    await _lookup(dut, PC_A)
    _assert_slot1(dut, hit=True, taken=False, target=TARGET_A)

    # Switch straight back to late.  Its canonical state must include both
    # early-selected writes: WeaklyNotTaken + taken = WeaklyTaken.
    await _update(
        dut,
        pc=PC_A,
        target=TARGET_B,
        taken=True,
        early_pc=PC_B,
        early_taken=False,
    )
    await _lookup(dut, PC_A)
    _assert_slot1(dut, hit=True, taken=True, target=TARGET_B)


@cocotb.test()
async def test_early_rmw_preserves_same_index_tag_replacement_and_shifted_copies(
    dut: Any,
) -> None:
    """An early-selected replacement initializes weakly and updates all replicas."""
    await _setup_test(dut)

    for _ in range(3):
        await _update(
            dut,
            pc=PC_A,
            target=TARGET_A,
            taken=False,
            early_pc=PC_B,
            early_taken=True,
        )

    # PC_A_INDEX_ALIAS collides in the canonical table but has a different tag.
    # A taken replacement must initialize WeaklyTaken, not increment PC_A's
    # StronglyNotTaken counter.
    await _update(
        dut,
        pc=PC_A_INDEX_ALIAS,
        target=TARGET_B,
        taken=True,
        compressed=True,
        handoff=True,
        early_active=True,
        late_pc=PC_A,
        late_taken=False,
    )

    await _lookup(dut, PC_A)
    assert not dut.o_btb_hit.value
    await _lookup(dut, PC_A_INDEX_ALIAS)
    _assert_slot1(
        dut,
        hit=True,
        taken=True,
        target=TARGET_B,
        compressed=True,
        handoff=True,
    )
    await _lookup(dut, PC_A_INDEX_ALIAS, slot2=True)
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_B,
        compressed=True,
        handoff=True,
    )
    await _lookup_slot2_alt(dut, PC_A_INDEX_ALIAS - 4)
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_B,
        compressed=True,
        handoff=True,
    )

    # A lower-priority update on the immediately following edge observes the
    # replacement written by the early candidate.
    await _update(
        dut,
        pc=PC_A_INDEX_ALIAS,
        target=TARGET_A,
        taken=False,
        early_pc=PC_B,
        early_taken=True,
    )
    await _lookup(dut, PC_A_INDEX_ALIAS)
    _assert_slot1(dut, hit=True, taken=False, target=TARGET_A)


@cocotb.test()
async def test_early_rmw_lookup_raw_changes_only_at_selected_write_edge(
    dut: Any,
) -> None:
    """Same-address lookups see old state before the edge and new state after it."""
    await _setup_test(dut)

    await _update(dut, pc=PC_A, target=TARGET_A, taken=True)
    dut.i_pc.value = PC_A
    dut.i_pc_2_base.value = (PC_A - 2) & 0xFFFFFFFF
    dut.i_pc_2_use_alt.value = 0

    dut.i_update.value = 1
    dut.i_update_pc.value = PC_A
    dut.i_update_target.value = TARGET_B
    dut.i_update_taken.value = 0
    dut.i_update_compressed.value = 1
    dut.i_update_requires_pc_reg_handoff.value = 1
    dut.i_early_update_active.value = 1
    dut.i_early_update_pc.value = PC_A
    dut.i_early_update_taken.value = 0
    dut.i_late_update_pc.value = PC_B
    dut.i_late_update_taken.value = 1
    await _settle()

    _assert_slot1(dut, hit=True, taken=True, target=TARGET_A)
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_A)

    await _advance_cycle(dut)

    _assert_slot1(
        dut,
        hit=True,
        taken=False,
        target=TARGET_B,
        compressed=True,
        handoff=True,
    )
    _assert_slot2(
        dut,
        hit=True,
        taken=False,
        target=TARGET_B,
        compressed=True,
        handoff=True,
    )

    dut.i_update.value = 0
    dut.i_early_update_active.value = 0
    await _settle()


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
    """The shifted normal slot-2 replica returns the actual entry metadata."""
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
async def test_shifted_slot2_lookup_preserves_counter_and_exact_key_mapping(
    dut: Any,
) -> None:
    """The U-2 replica preserves counters, wrap, halfword tags, and replacement."""
    await _setup_test(dut)

    actual_pc = PC_A
    await _update(
        dut,
        pc=actual_pc,
        target=TARGET_A,
        taken=True,
        compressed=True,
        handoff=True,
    )
    await _lookup(dut, actual_pc, slot2=True)
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_A,
        compressed=True,
        handoff=True,
    )

    # Counter evolution is calculated from the conventional update replica and
    # written identically to the shifted lookup replica.
    await _update(dut, pc=actual_pc, target=TARGET_B, taken=False)
    await _lookup(dut, actual_pc, slot2=True)
    _assert_slot2(dut, hit=True, taken=False, target=TARGET_B)

    # Both entries occupy conventional index zero and shifted index 255.  The
    # second must replace the first across index/tag and full-XLEN borrow.
    first_pc = 0x80000400
    second_pc = 0x00000000
    await _update(dut, pc=first_pc, target=TARGET_A, taken=True)
    await _lookup(dut, first_pc, slot2=True)
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_A)
    await _update(dut, pc=second_pc, target=TARGET_B, taken=True)
    await _lookup(dut, second_pc, slot2=True)
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_B)
    await _lookup(dut, first_pc, slot2=True)
    assert not dut.o_btb_hit_2.value

    # U=...402 maps to base ...400, exercising the PC[1] transition without
    # an index borrow.
    halfword_pc = 0x00000402
    await _update(
        dut,
        pc=halfword_pc,
        target=TARGET_A + 2,
        taken=True,
        compressed=True,
        handoff=True,
    )
    await _lookup(dut, halfword_pc, slot2=True)
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_A + 2,
        compressed=True,
        handoff=True,
    )


@cocotb.test()
async def test_shifted_slot2_alt_lookup_preserves_metadata_and_counter(
    dut: Any,
) -> None:
    """The shifted alternate replica behaves exactly like a lookup at base+4."""
    await _setup_test(dut)

    actual_pc = PC_A
    base_pc = actual_pc - 4
    await _update(
        dut,
        pc=actual_pc,
        target=TARGET_A,
        taken=True,
        compressed=True,
        handoff=True,
    )
    await _lookup_slot2_alt(dut, base_pc)
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_A,
        compressed=True,
        handoff=True,
    )

    await _update(dut, pc=actual_pc, target=TARGET_B, taken=False)
    await _lookup_slot2_alt(dut, base_pc)
    _assert_slot2(dut, hit=True, taken=False, target=TARGET_B)


@cocotb.test()
async def test_shifted_slot2_alt_lookup_is_exact_across_key_wraps(dut: Any) -> None:
    """Index borrow, PC wrap, and halfword tags survive the U-to-U-4 mapping."""
    await _setup_test(dut)

    cases = [
        # update index 0 maps to shifted index 255 and borrows into the tag
        (0x80000400, 0x800003FC, TARGET_A, False),
        # full XLEN wrap: the actual entry at zero is keyed by 0xfffffffc
        (0x00000000, 0xFFFFFFFC, TARGET_B, False),
        # the same index borrow preserves PC[1] for a halfword-aligned entry
        (0x00000402, 0x000003FE, TARGET_A + 2, True),
    ]

    previous_base: int | None = None
    for actual_pc, base_pc, target, compressed in cases:
        await _update(
            dut,
            pc=actual_pc,
            target=target,
            taken=True,
            compressed=compressed,
            handoff=compressed,
        )
        await _lookup_slot2_alt(dut, base_pc)
        _assert_slot2(
            dut,
            hit=True,
            taken=True,
            target=target,
            compressed=compressed,
            handoff=compressed,
        )

        # All cases collide at direct-mapped index zero in the legacy BTB and
        # therefore at shifted index 255.  Replacement must invalidate the
        # prior shifted tag just as it invalidates the conventional one.
        if previous_base is not None:
            await _lookup_slot2_alt(dut, previous_base)
            assert not dut.o_btb_hit_2.value
            assert not dut.o_predicted_taken_2.value
        previous_base = base_pc


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

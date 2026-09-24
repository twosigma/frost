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

from config import MASK_XLEN
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
PC_A = 0x80000100
PC_B = 0x80000104
PC_A_HALFWORD_ALIAS = PC_A | 0x2
PC_A_INDEX_ALIAS = PC_A + 0x400
TARGET_A = 0x80001000
TARGET_B = 0x80002000
HIGH_CANONICAL_PC = 0xFFFF_FFFF_FFE0_117E
HIGH_CANONICAL_TARGET = 0xFFFF_FFFF_FFE0_1238


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_pc.value = 0
    dut.i_pc_2_lookup_base.value = 0
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
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
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
        # Upstream, the update-priority mux guarantees that the active
        # candidate (early when early_active, else late) carries the selected
        # write's PC and outcome.
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
    """Drive one lookup PC, including the slot-2 synchronous read stage."""
    if slot2:
        # T2 stores the entry for PC U under the key U-2.
        base_pc = (pc - 2) & MASK_XLEN
        dut.i_pc_2_lookup_base.value = base_pc
        await _advance_cycle(dut)
        dut.i_pc_2_base.value = base_pc
        dut.i_pc_2_use_alt.value = 0
    else:
        dut.i_pc.value = pc
    await _settle()


async def _lookup_slot2_alt(dut: Any, base_pc: int) -> None:
    """Stage and select the base_pc+4 entry from T4."""
    dut.i_pc_2_lookup_base.value = base_pc & MASK_XLEN
    await _advance_cycle(dut)
    dut.i_pc_2_base.value = base_pc & MASK_XLEN
    dut.i_pc_2_use_alt.value = 1
    await _settle()


async def _stage_slot2_images(dut: Any, lookup_base: int) -> None:
    """Launch the shared read index for the T2, T4, and rotated-T2 images."""
    dut.i_pc_2_lookup_base.value = lookup_base & MASK_XLEN
    await _advance_cycle(dut)


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
    """Alternating early and late updates to one entry step a single 2-bit counter."""
    await _setup_test(dut)

    # Build StronglyTaken through the late candidate only. The inactive early
    # inputs point at PC_B so they cannot supply the selected result.
    for _ in range(3):
        await _update(
            dut,
            pc=PC_A,
            target=TARGET_A,
            taken=True,
            early_pc=PC_B,
            early_taken=False,
        )

    # The early candidate's RAM copies must have received those late-selected
    # writes. One not-taken update therefore moves StronglyTaken -> WeaklyTaken
    # and must keep predicting taken.
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

    # A second early write to the same index must see the first.
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

    # Switch straight back to the late candidate. Its RAM copies must include
    # both early-selected writes: WeaklyNotTaken + taken = WeaklyTaken.
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
    """An early-selected replacement starts WeaklyTaken in the slot-1 table, T2, and T4."""
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

    # PC_A_INDEX_ALIAS has PC_A's index but a different tag. A taken
    # replacement must start at WeaklyTaken, not increment PC_A's
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
    """A staged same-address slot-2 read forwards the complete written row."""
    await _setup_test(dut)

    await _update(dut, pc=PC_A, target=TARGET_A, taken=True)
    dut.i_pc.value = PC_A
    slot2_base = (PC_A - 2) & MASK_XLEN
    await _stage_slot2_images(dut, slot2_base)
    dut.i_pc_2_base.value = slot2_base
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
    dut.i_pc_2_lookup_base.value = slot2_base
    await _settle()

    # Slot 1 remains asynchronous.  Slot 2 presents the row staged on the
    # prior edge until this write/read edge replaces it.
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
    """A slot-2 lookup through T2 returns the entry's own metadata."""
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
async def test_narrow_target_payload_restores_high_canonical_branch_region(
    dut: Any,
) -> None:
    """Both ports restore a high-canonical Sv39 target without wider RAMs."""
    await _setup_test(dut)

    await _update(
        dut,
        pc=HIGH_CANONICAL_PC,
        target=HIGH_CANONICAL_TARGET,
        taken=True,
        compressed=True,
        handoff=True,
    )

    await _lookup(dut, HIGH_CANONICAL_PC)
    _assert_slot1(
        dut,
        hit=True,
        taken=True,
        target=HIGH_CANONICAL_TARGET,
        compressed=True,
        handoff=True,
    )

    await _lookup(dut, HIGH_CANONICAL_PC, slot2=True)
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=HIGH_CANONICAL_TARGET,
        compressed=True,
        handoff=True,
    )

    await _lookup_slot2_alt(dut, HIGH_CANONICAL_PC - 4)
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=HIGH_CANONICAL_TARGET,
        compressed=True,
        handoff=True,
    )


@cocotb.test()
async def test_cross_region_target_update_invalidates_all_target_rows(
    dut: Any,
) -> None:
    """A cross-region update invalidates the entry instead of truncating its target."""
    await _setup_test(dut)

    # First allocate every image so the cross-region update has to invalidate
    # old state rather than decline a new allocation.
    await _update(dut, pc=PC_A, target=TARGET_A, taken=True)
    await _lookup(dut, PC_A)
    assert dut.o_btb_hit.value
    await _lookup(dut, PC_A, slot2=True)
    assert dut.o_btb_hit_2.value
    await _lookup_slot2_alt(dut, PC_A - 4)
    assert dut.o_btb_hit_2.value

    await _update(
        dut,
        pc=PC_A,
        target=HIGH_CANONICAL_TARGET,
        taken=True,
        compressed=True,
        handoff=True,
    )

    await _lookup(dut, PC_A)
    assert not dut.o_btb_hit.value
    assert not dut.o_predicted_taken.value
    await _lookup(dut, PC_A, slot2=True)
    assert not dut.o_btb_hit_2.value
    assert not dut.o_predicted_taken_2.value
    await _lookup_slot2_alt(dut, PC_A - 4)
    assert not dut.o_btb_hit_2.value
    assert not dut.o_predicted_taken_2.value


@cocotb.test()
async def test_staged_slot2_lookup_covers_same_index_halfword_base(
    dut: Any,
) -> None:
    """T2 and T4 read at A also serve base A+2 in the same RAM index."""
    await _setup_test(dut)

    lookup_base = PC_A
    current_base = PC_A + 2
    plus2_pc = current_base + 2
    plus4_pc = current_base + 4
    await _update(
        dut,
        pc=plus2_pc,
        target=TARGET_A,
        taken=True,
        compressed=True,
        handoff=True,
    )
    await _update(dut, pc=plus4_pc, target=TARGET_B, taken=True)

    await _stage_slot2_images(dut, lookup_base)
    dut.i_pc_2_base.value = current_base
    dut.i_pc_2_use_alt.value = 0
    await _settle()
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_A,
        compressed=True,
        handoff=True,
    )

    dut.i_pc_2_use_alt.value = 1
    await _settle()
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_B)


@cocotb.test()
async def test_staged_slot2_lookup_covers_next_index_and_rejects_later_index(
    dut: Any,
) -> None:
    """Rotated T2 serves A's successor word, while A+8 remains uncovered."""
    await _setup_test(dut)

    lookup_base = PC_A
    next_base = PC_A + 4
    plus2_pc = next_base + 2
    await _update(dut, pc=plus2_pc, target=TARGET_A, taken=True)

    await _stage_slot2_images(dut, lookup_base)
    dut.i_pc_2_base.value = next_base
    dut.i_pc_2_use_alt.value = 0
    await _settle()
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_A)

    # A served base whose index is neither the staged index nor the next one
    # must not use any of the three images' registered rows.
    dut.i_pc_2_base.value = lookup_base + 8
    await _settle()
    assert not dut.o_btb_hit_2.value
    assert not dut.o_predicted_taken_2.value
    assert not dut.o_predicted_taken_2_plus2.value
    assert not dut.o_predicted_taken_2_plus4.value
    assert not dut.o_btb_compressed_2.value
    assert not dut.o_btb_requires_pc_reg_handoff_2.value


@cocotb.test()
async def test_staged_slot2_t4_safely_misses_at_successor_index(dut: Any) -> None:
    """T4 misses for a base in the next word even when the staged row's tag matches."""
    await _setup_test(dut)

    lookup_base = PC_A
    current_base = lookup_base + 4

    # This update writes a valid T4 row at lookup_base's read index. The tag
    # leaves out the index bits, so that row's tag also matches current_base.
    # Only the coverage check (RT2 alone serves the next index) keeps the +4
    # candidate in the next word from using that row.
    await _update(
        dut,
        pc=lookup_base + 4,
        target=TARGET_A,
        taken=True,
        compressed=True,
        handoff=True,
    )

    await _stage_slot2_images(dut, lookup_base)
    dut.i_pc_2_base.value = current_base
    dut.i_pc_2_use_alt.value = 1
    await _settle()

    _assert_slot2(dut, hit=False, taken=False, target=0)
    assert not dut.o_predicted_taken_2_plus2.value
    assert not dut.o_predicted_taken_2_plus4.value


@cocotb.test()
async def test_staged_slot2_next_index_wraps_without_losing_the_full_tag(
    dut: Any,
) -> None:
    """Rotated T2 covers the all-ones-to-zero successor and preserves its tag."""
    await _setup_test(dut)

    lookup_base = (MASK_XLEN - 3) & MASK_XLEN
    current_base = 0
    actual_pc = 2
    await _update(
        dut,
        pc=actual_pc,
        target=TARGET_A,
        taken=True,
        compressed=True,
        handoff=True,
    )

    await _stage_slot2_images(dut, lookup_base)
    dut.i_pc_2_base.value = current_base
    dut.i_pc_2_use_alt.value = 0
    await _settle()
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_A,
        compressed=True,
        handoff=True,
    )


@cocotb.test()
async def test_staged_slot2_same_edge_write_forwards_full_replacement_row(
    dut: Any,
) -> None:
    """A colliding write/read edge forwards new tags, payload, and valid bits."""
    await _setup_test(dut)

    old_pc = PC_A
    old_base = (old_pc - 2) & MASK_XLEN
    new_pc = PC_A_INDEX_ALIAS
    new_normal_base = (new_pc - 2) & MASK_XLEN
    new_alt_base = (new_pc - 4) & MASK_XLEN
    await _update(dut, pc=old_pc, target=TARGET_A, taken=True)
    await _stage_slot2_images(dut, old_base)
    dut.i_pc_2_base.value = old_base
    dut.i_pc_2_use_alt.value = 0
    await _settle()
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_A)

    # The replacement's T2 key has the old key's index, and the lookup reads
    # that index on the write edge, so every row field must bypass the RAM's
    # implementation-defined read-during-write result.
    dut.i_pc_2_lookup_base.value = new_normal_base
    dut.i_update.value = 1
    dut.i_update_pc.value = new_pc
    dut.i_update_target.value = TARGET_B
    dut.i_update_taken.value = 1
    dut.i_update_compressed.value = 1
    dut.i_update_requires_pc_reg_handoff.value = 1
    dut.i_early_update_active.value = 0
    dut.i_late_update_pc.value = new_pc
    dut.i_late_update_taken.value = 1
    await _advance_cycle(dut)
    dut.i_update.value = 0

    dut.i_pc_2_base.value = new_normal_base
    dut.i_pc_2_use_alt.value = 0
    await _settle()
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_B,
        compressed=True,
        handoff=True,
    )

    # The T4 key (new_pc - 4) is in the same word index, so its row was staged
    # and forwarded on that edge too.
    dut.i_pc_2_base.value = new_alt_base
    dut.i_pc_2_use_alt.value = 1
    await _settle()
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_B,
        compressed=True,
        handoff=True,
    )

    # Switching the served base back to the evicted key misses without
    # another RAM read edge.
    dut.i_pc_2_base.value = old_base
    dut.i_pc_2_use_alt.value = 0
    await _settle()
    assert not dut.o_btb_hit_2.value
    assert not dut.o_predicted_taken_2.value


@cocotb.test()
async def test_slot2_rotated_image_same_edge_write_forwards_wrapped_replacement(
    dut: Any,
) -> None:
    """RT2 forwards a wrapped, different-tag write and its complete payload."""
    await _setup_test(dut)

    old_pc = 0x402
    new_pc = 0x2
    lookup_base = (MASK_XLEN - 3) & MASK_XLEN
    current_base = 0

    # Both updates land at RT2 index 255 with different T2 tags. The old row
    # makes a read-first RAM result distinguishable from the replacement that
    # must be forwarded on the colliding edge.
    await _update(dut, pc=old_pc, target=TARGET_A, taken=False)

    dut.i_pc_2_lookup_base.value = lookup_base
    dut.i_update.value = 1
    dut.i_update_pc.value = new_pc
    dut.i_update_target.value = TARGET_B
    dut.i_update_taken.value = 1
    dut.i_update_compressed.value = 1
    dut.i_update_requires_pc_reg_handoff.value = 1
    dut.i_early_update_active.value = 0
    dut.i_late_update_pc.value = new_pc
    dut.i_late_update_taken.value = 1
    await _advance_cycle(dut)
    dut.i_update.value = 0

    # The staged read is at the top of the address space and the served base
    # wraps to index zero, the next index, so the +2 selection uses RT2.
    dut.i_pc_2_base.value = current_base
    dut.i_pc_2_use_alt.value = 0
    await _settle()
    _assert_slot2(
        dut,
        hit=True,
        taken=True,
        target=TARGET_B,
        compressed=True,
        handoff=True,
    )


@cocotb.test()
async def test_shifted_slot2_lookup_preserves_counter_and_exact_key_mapping(
    dut: Any,
) -> None:
    """T2 (key U-2) follows the entry's counter and tag, and a cross-region key misses."""
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

    # The next counter value is computed from the update-side RAM copies and
    # written unchanged to the slot-2 images.
    await _update(dut, pc=actual_pc, target=TARGET_B, taken=False)
    await _lookup(dut, actual_pc, slot2=True)
    _assert_slot2(dut, hit=True, taken=False, target=TARGET_B)

    # Both entries use slot-1 index 0 and T2 index 255. The second branch's T2
    # key (U-2) is in a different 4-GiB region, so its write must invalidate
    # that T2 row rather than restore the target's upper bits from the key's
    # region. Slot 1 still trains.
    first_pc = 0x80000400
    second_pc = 0x00000000
    await _update(dut, pc=first_pc, target=TARGET_A, taken=True)
    await _lookup(dut, first_pc, slot2=True)
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_A)
    await _update(dut, pc=second_pc, target=TARGET_B, taken=True)
    await _lookup(dut, second_pc)
    _assert_slot1(dut, hit=True, taken=True, target=TARGET_B)
    await _lookup(dut, second_pc, slot2=True)
    assert not dut.o_btb_hit_2.value
    assert not dut.o_predicted_taken_2.value
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
async def test_shifted_slot2_lookup_uses_predecessor_key_collision_topology(
    dut: Any,
) -> None:
    """T2 is direct-mapped by its key U-2, including the key's PC[1]."""
    await _setup_test(dut)

    word_pc = PC_A
    halfword_pc = PC_A + 2
    next_word_pc = PC_A + 4

    # These two PCs share a slot-1 index, but their U-2 keys land at adjacent
    # T2 indices, so T2 keeps the older word-aligned entry after the slot-1
    # table replaces it.
    await _update(dut, pc=word_pc, target=TARGET_A, taken=True)
    await _update(
        dut,
        pc=halfword_pc,
        target=TARGET_B,
        taken=True,
        compressed=True,
    )
    await _lookup(dut, word_pc)
    assert not dut.o_btb_hit.value
    await _lookup(dut, word_pc, slot2=True)
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_A)

    # Conversely, these entries use adjacent slot-1 indices while their U-2
    # keys share one T2 index, so updating the next word evicts only the
    # halfword entry from T2.
    await _update(dut, pc=next_word_pc, target=TARGET_A + 4, taken=True)
    await _lookup(dut, halfword_pc)
    _assert_slot1(
        dut,
        hit=True,
        taken=True,
        target=TARGET_B,
        compressed=True,
    )
    await _lookup(dut, halfword_pc, slot2=True)
    assert not dut.o_btb_hit_2.value
    await _lookup(dut, next_word_pc, slot2=True)
    _assert_slot2(dut, hit=True, taken=True, target=TARGET_A + 4)


@cocotb.test()
async def test_shifted_slot2_alt_lookup_preserves_metadata_and_counter(
    dut: Any,
) -> None:
    """T4 returns the base+4 entry's metadata and follows its counter updates."""
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
    """U-to-U-4 mapping preserves tags and rejects a cross-region key."""
    await _setup_test(dut)

    cases = [
        # update index 0 maps to T4 index 255 and borrows into the tag
        (0x80000400, 0x800003FC, TARGET_A, False, True),
        # full XLEN wrap: the entry at zero is keyed by 0xffffffff_fffffffc.
        # That key is in a different region, so it must not allocate a
        # target-valid T4 row.
        (0x00000000, 0xFFFFFFFF_FFFFFFFC, TARGET_B, False, False),
        # the same index borrow preserves PC[1] for a halfword-aligned entry
        (0x00000402, 0x000003FE, TARGET_A + 2, True, True),
    ]

    previous_base: int | None = None
    for actual_pc, base_pc, target, compressed, shifted_predictable in cases:
        await _update(
            dut,
            pc=actual_pc,
            target=target,
            taken=True,
            compressed=compressed,
            handoff=compressed,
        )
        await _lookup_slot2_alt(dut, base_pc)
        if shifted_predictable:
            _assert_slot2(
                dut,
                hit=True,
                taken=True,
                target=target,
                compressed=compressed,
                handoff=compressed,
            )
        else:
            assert not dut.o_btb_hit_2.value
            assert not dut.o_predicted_taken_2.value

        # All cases share slot-1 index 0 and therefore T4 index 255. Each
        # replacement must evict the previous T4 row just as it replaces the
        # slot-1 entry.
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

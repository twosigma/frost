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

"""Unit tests for the tagged predictor's path history and saved lookups."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb_tests.cpu_structs import (
    ROB_TAG_WIDTH,
    TAGE_FTQ_IDX_BITS,
    TAGE_LOOKUP_FIELDS,
)
from utils.packed_structs import pack_struct, unpack_struct


CLOCK_PERIOD_NS = 10
HIST_BITS = 64
HIST_MASK = (1 << HIST_BITS) - 1
PATH_BITS = 2
FTQ_MASK = (1 << TAGE_FTQ_IDX_BITS) - 1

ARM_RESET = 0
ARM_TRAP = 1
ARM_FENCE = 2
ARM_RECOVERY = 3
ARM_PD_REDIRECT = 4

LOOKUP_A = {
    "index1": 0x055,
    "index2": 0x1AA,
    "tag1": 0x0F0,
    "tag2": 0x10F,
    "hit1": 1,
    "hit2": 0,
    "taken": 1,
}
LOOKUP_B = {
    "index1": 0x101,
    "index2": 0x022,
    "tag1": 0x033,
    "tag2": 0x144,
    "hit1": 1,
    "hit2": 1,
    "taken": 0,
    "alt_tagged": 1,
    "alt_tagged_taken": 1,
}


def _push(hist: int, bits: int) -> int:
    """Shift two target bits into the history."""
    return ((hist << PATH_BITS) | bits) & HIST_MASK


def _pair(values: tuple[int, int], width: int) -> int:
    """Pack a per-slot pair into a [1:0][width-1:0] vector (slot 1 low)."""
    return values[0] | (values[1] << width)


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_hist_push.value = 0
    dut.i_hist_restore_arm.value = 0
    dut.i_fetch_pc_path_bits.value = 0
    dut.i_pd_accept.value = 0
    dut.i_pd_cond_branch.value = 0
    dut.i_tage_slot_valid.value = 0
    dut.i_tage_slot_lookup.value = 0
    dut.i_tage_slot_lookup_2.value = 0
    dut.i_tage_slot_bank.value = 0
    dut.i_base_taken.value = 0
    dut.i_tage_lookup_hist.value = 0
    dut.i_pd_redirect_taken.value = 0
    dut.i_early_active.value = 0
    dut.i_early_tag.value = 0
    dut.i_early_taken.value = 0
    dut.i_flush_full.value = 0
    _clear_alloc(dut)
    _clear_commit(dut)


def _write_index(dut: Any) -> int:
    """Return the index the next accepted branch packet's entry takes."""
    return (int(dut.ftq_write_ptr.value) + int(dut.pd_entry_pending.value)) & FTQ_MASK


def _clear_alloc(dut: Any) -> None:
    """Drive no dispatch allocation."""
    dut.i_alloc_tag.value = 0
    dut.i_alloc_cond_branch.value = 0
    dut.i_alloc_q.value = 0


def _clear_commit(dut: Any) -> None:
    """Drive an idle registered commit bus."""
    dut.i_commit_valid.value = 0
    dut.i_commit_tag.value = 0
    dut.i_commit_cond_branch.value = 0
    dut.i_commit_taken_cf.value = 0
    dut.i_commit_taken.value = 0
    dut.i_commit_mispredicted.value = 0
    dut.i_commit_target_bits.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _step(dut: Any) -> None:
    """Clock one rising edge; return in the low phase with outputs settled."""
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)


async def _setup_test(dut: Any) -> None:
    """Start the clock, clear inputs, and apply reset."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await _step(dut)
    await _step(dut)
    dut.i_rst.value = 0
    await _settle()


def _lookup_hist(dut: Any) -> int:
    return int(dut.o_lookup_hist.value)


async def _accept_branch(
    dut: Any,
    *,
    slot: int = 0,
    lookup: dict[str, int] | None = None,
    lookup_valid: bool = True,
    bank: int = 0,
    base_taken: bool = False,
    hist: int = 0,
) -> int:
    """Pass one packet with a conditional branch in `slot` to ID; return its index."""
    idx = _write_index(dut)
    packed = pack_struct(TAGE_LOOKUP_FIELDS, lookup or {})
    dut.i_pd_accept.value = 1
    dut.i_pd_cond_branch.value = 1 << slot
    dut.i_tage_slot_valid.value = int(lookup_valid) << slot
    dut.i_tage_slot_bank.value = bank << slot
    dut.i_base_taken.value = int(base_taken) << slot
    if slot == 0:
        dut.i_tage_slot_lookup.value = packed
    else:
        dut.i_tage_slot_lookup_2.value = packed
    dut.i_tage_lookup_hist.value = hist
    await _step(dut)
    dut.i_pd_accept.value = 0
    dut.i_pd_cond_branch.value = 0
    dut.i_tage_slot_valid.value = 0
    await _settle()
    return idx


async def _allocate(
    dut: Any, tag: int, idx: int | None = None, *, slot: int = 0, cond: bool = True
) -> None:
    """Dispatch one instruction; return once its index write has landed.

    The ROB reports the allocation the cycle after dispatch presents it. A
    conditional branch takes dispatch's next index, which must be idx.
    """
    dut.i_alloc_tag.value = tag << (slot * ROB_TAG_WIDTH)
    dut.i_alloc_cond_branch.value = int(cond) << slot
    await _step(dut)
    _clear_alloc(dut)
    dut.i_alloc_q.value = 1 << slot
    await _settle()
    if cond and idx is not None:
        assert int(dut.ftq_dispatch_ptr.value) == idx
    await _step(dut)
    dut.i_alloc_q.value = 0
    await _settle()


def _drive_commit(dut: Any, slots: list[dict[str, int] | None]) -> None:
    """Drive the registered commit bus for slot 1 and slot 2 (None = idle)."""
    fields = {
        "valid": "i_commit_valid",
        "cond_branch": "i_commit_cond_branch",
        "taken_cf": "i_commit_taken_cf",
        "taken": "i_commit_taken",
        "mispredicted": "i_commit_mispredicted",
    }
    for key, name in fields.items():
        bits = [int(s.get(key, 0)) if s else 0 for s in slots]
        getattr(dut, name).value = _pair((bits[0], bits[1]), 1)
    tags = [int(s.get("tag", 0)) if s else 0 for s in slots]
    targets = [int(s.get("target_bits", 0)) if s else 0 for s in slots]
    dut.i_commit_tag.value = _pair((tags[0], tags[1]), ROB_TAG_WIDTH)
    dut.i_commit_target_bits.value = _pair((targets[0], targets[1]), PATH_BITS)


async def _commit(dut: Any, slots: list[dict[str, int] | None]) -> None:
    """Present one registered commit-bus cycle."""
    _drive_commit(dut, slots)
    await _step(dut)
    _clear_commit(dut)
    await _settle()


def _train(dut: Any) -> dict[str, Any]:
    """Return the registered training port."""
    return {
        "valid": bool(dut.o_train_valid.value),
        "lookup": unpack_struct(TAGE_LOOKUP_FIELDS, int(dut.o_train_lookup.value)),
        "bank": int(dut.o_train_bank.value),
        "alt_taken": bool(dut.o_train_alt_taken.value),
        "taken": bool(dut.o_train_taken.value),
        "mispredicted": bool(dut.o_train_mispredicted.value),
    }


@cocotb.test()
async def test_push_shifts_the_fetch_bits_into_the_lookup_history(dut: Any) -> None:
    """A registered push extends the history in its own cycle, then holds."""
    await _setup_test(dut)
    assert _lookup_hist(dut) == 0

    dut.i_hist_push.value = 1
    dut.i_fetch_pc_path_bits.value = 0b10
    await _settle()
    assert _lookup_hist(dut) == 0b10

    await _step(dut)
    dut.i_fetch_pc_path_bits.value = 0b01
    await _settle()
    assert _lookup_hist(dut) == 0b1001

    await _step(dut)
    dut.i_hist_push.value = 0
    dut.i_fetch_pc_path_bits.value = 0b11
    await _settle()
    assert _lookup_hist(dut) == 0b1001

    # The oldest bits shift out of the 64-bit history.
    dut.i_hist_push.value = 1
    for _ in range(HIST_BITS // PATH_BITS):
        await _step(dut)
    dut.i_hist_push.value = 0
    await _settle()
    assert _lookup_hist(dut) == HIST_MASK


@cocotb.test()
async def test_retired_taken_control_flow_builds_the_restore_history(dut: Any) -> None:
    """Trap, FENCE, and commit-recovery restores take the retirement history."""
    await _setup_test(dut)

    # Slot 1 then slot 2 in one cycle; a not-taken retirement adds nothing.
    await _commit(
        dut,
        [
            {"valid": 1, "taken_cf": 1, "target_bits": 0b01},
            {"valid": 1, "taken_cf": 1, "target_bits": 0b10},
        ],
    )
    await _commit(dut, [{"valid": 1, "cond_branch": 1}, None])
    await _commit(dut, [None, {"valid": 1, "taken_cf": 1, "target_bits": 0b11}])
    retired = 0b01_10_11

    # Speculative pushes that the restore discards.
    dut.i_hist_push.value = 1
    dut.i_fetch_pc_path_bits.value = 0b11
    await _step(dut)
    dut.i_hist_push.value = 0

    for arm in (ARM_TRAP, ARM_FENCE, ARM_RECOVERY):
        dut.i_hist_restore_arm.value = 1 << arm
        await _settle()
        assert _lookup_hist(dut) == retired, arm
        await _step(dut)
        dut.i_hist_restore_arm.value = 0
        await _settle()
        assert _lookup_hist(dut) == retired, arm
        dut.i_hist_push.value = 1
        await _step(dut)
        dut.i_hist_push.value = 0

    dut.i_hist_restore_arm.value = 1 << ARM_RESET
    await _settle()
    assert _lookup_hist(dut) == 0
    dut.i_hist_restore_arm.value = 0


@cocotb.test()
async def test_pd_redirect_restores_the_branch_history_and_pushes_if_taken(
    dut: Any,
) -> None:
    """A PD redirect restores its branch's lookup history, plus a push when taken."""
    await _setup_test(dut)

    for taken in (True, False):
        hist = 0x0123_4567_89AB_CDEF if taken else 0x0FED_CBA9_8765_4321
        await _accept_branch(dut, lookup=LOOKUP_A, hist=hist)
        # The redirect cycle: PD's register holds the branch.
        dut.i_pd_redirect_taken.value = int(taken)
        dut.i_fetch_pc_path_bits.value = 0b10
        await _step(dut)
        dut.i_pd_redirect_taken.value = 0
        # The next cycle: pc_controller's registered arm.
        dut.i_hist_restore_arm.value = 1 << ARM_PD_REDIRECT
        await _settle()
        expected = _push(hist, 0b10) if taken else hist
        assert _lookup_hist(dut) == expected, taken
        await _step(dut)
        dut.i_hist_restore_arm.value = 0
        await _settle()
        assert _lookup_hist(dut) == expected, taken


@cocotb.test()
async def test_early_recovery_restores_the_saved_history(dut: Any) -> None:
    """Early recovery reads the branch's saved history by ROB tag."""
    await _setup_test(dut)

    for taken in (True, False):
        hist = 0x5555_0000_AAAA_1234 if taken else 0x1111_2222_3333_4444
        tag = 7 if taken else 21
        idx = await _accept_branch(dut, lookup=LOOKUP_A, hist=hist)
        await _allocate(dut, tag, idx)
        # Younger branches move the history and the write pointer on.
        await _accept_branch(dut, lookup=LOOKUP_B, hist=hist ^ HIST_MASK)
        dut.i_hist_push.value = 1
        await _step(dut)
        dut.i_hist_push.value = 0

        dut.i_early_active.value = 1
        dut.i_early_tag.value = tag
        dut.i_early_taken.value = int(taken)
        dut.i_fetch_pc_path_bits.value = 0b01
        await _step(dut)
        dut.i_early_active.value = 0
        dut.i_hist_restore_arm.value = 1 << ARM_RECOVERY
        await _settle()
        assert _lookup_hist(dut) == (_push(hist, 0b01) if taken else hist), taken
        assert _write_index(dut) == (idx + 1) & FTQ_MASK, taken
        assert int(dut.ftq_dispatch_ptr.value) == (idx + 1) & FTQ_MASK, taken
        await _step(dut)
        dut.i_hist_restore_arm.value = 0
        await _settle()


@cocotb.test()
async def test_indices_advance_per_branch_packet_and_rewind_on_recovery(
    dut: Any,
) -> None:
    """PD and dispatch count branches in the same order; flushes rewind both."""
    await _setup_test(dut)
    start = _write_index(dut)

    # Only an accepted packet with a branch takes an entry.
    dut.i_pd_cond_branch.value = 0b01
    await _step(dut)  # not accepted
    dut.i_pd_cond_branch.value = 0
    dut.i_pd_accept.value = 1
    await _step(dut)  # accepted, no branch
    dut.i_pd_accept.value = 0
    await _settle()
    assert _write_index(dut) == start

    first = await _accept_branch(dut, lookup=LOOKUP_A)
    second = await _accept_branch(dut, slot=1, lookup=LOOKUP_B)
    third = await _accept_branch(dut, lookup=LOOKUP_A)
    assert (first, second, third) == (
        start,
        (start + 1) & FTQ_MASK,
        (start + 2) & FTQ_MASK,
    )
    for tag, idx in ((3, first), (4, second), (5, third)):
        await _allocate(dut, tag, idx)
    # Other instructions take no index.
    await _allocate(dut, 6, cond=False)
    assert int(dut.ftq_dispatch_ptr.value) == (start + 3) & FTQ_MASK

    # The first branch retires; a full flush keeps only entries after it.
    await _commit(dut, [{"valid": 1, "cond_branch": 1, "tag": 3}, None])
    dut.i_flush_full.value = 1
    # A simultaneous early recovery loses to the full flush.
    dut.i_early_active.value = 1
    dut.i_early_tag.value = 5
    await _step(dut)
    dut.i_flush_full.value = 0
    dut.i_early_active.value = 0
    await _settle()
    assert _write_index(dut) == (first + 1) & FTQ_MASK
    assert int(dut.ftq_dispatch_ptr.value) == (first + 1) & FTQ_MASK

    # The pointer wraps.
    for _ in range(FTQ_MASK + 1):
        await _accept_branch(dut, lookup=LOOKUP_A)
    assert _write_index(dut) == (first + 1) & FTQ_MASK


@cocotb.test()
async def test_retired_branch_trains_from_its_saved_lookup(dut: Any) -> None:
    """Commit trains with the saved lookup, bank, alternate, and outcome."""
    await _setup_test(dut)

    idx = await _accept_branch(dut, lookup=LOOKUP_A, bank=1, base_taken=False)
    await _allocate(dut, 9, idx)
    idx_b = await _accept_branch(dut, slot=1, lookup=LOOKUP_B, bank=0, base_taken=False)
    await _allocate(dut, 10, idx_b, slot=1)

    await _commit(
        dut,
        [{"valid": 1, "cond_branch": 1, "tag": 9, "taken": 1, "mispredicted": 1}, None],
    )
    train = _train(dut)
    assert train["valid"]
    assert {k: train["lookup"][k] for k in LOOKUP_A} == LOOKUP_A
    assert train["bank"] == 1
    assert not train["alt_taken"]  # the base direction (no T1 alternate)
    assert train["taken"]
    assert train["mispredicted"]

    await _commit(dut, [None, {"valid": 1, "cond_branch": 1, "tag": 10, "taken": 0}])
    train = _train(dut)
    assert train["valid"]
    assert {k: train["lookup"][k] for k in LOOKUP_B} == LOOKUP_B
    assert train["bank"] == 0
    assert train["alt_taken"]  # T1's direction behind the T2 provider
    assert not train["taken"]
    assert not train["mispredicted"]

    await _step(dut)
    assert not _train(dut)["valid"]


@cocotb.test()
async def test_branch_without_a_lookup_or_not_conditional_does_not_train(
    dut: Any,
) -> None:
    """Uncovered lookups and non-conditional retirements leave training idle."""
    await _setup_test(dut)

    idx = await _accept_branch(dut, lookup=LOOKUP_A, lookup_valid=False)
    await _allocate(dut, 12, idx)
    await _commit(dut, [{"valid": 1, "cond_branch": 1, "tag": 12, "taken": 1}, None])
    assert not _train(dut)["valid"]

    idx = await _accept_branch(dut, lookup=LOOKUP_A)
    await _allocate(dut, 13, idx)
    await _commit(dut, [{"valid": 1, "cond_branch": 0, "taken_cf": 1, "tag": 13}, None])
    assert not _train(dut)["valid"]


@cocotb.test()
async def test_slot2_training_waits_one_deep_and_newer_replaces_it(dut: Any) -> None:
    """Slot 1 trains first; a held slot-2 branch drains or is replaced."""
    await _setup_test(dut)

    # Each branch's saved lookup carries its tag in index1.
    for tag, lookup in (
        (1, LOOKUP_A),
        (2, LOOKUP_B),
        (3, LOOKUP_A),
        (4, LOOKUP_B),
        (5, LOOKUP_A),
    ):
        idx = await _accept_branch(dut, lookup={**lookup, "index1": tag}, bank=tag & 1)
        await _allocate(dut, tag, idx)

    def _branch(tag: int) -> dict[str, int]:
        return {"valid": 1, "cond_branch": 1, "tag": tag}

    # Both slots retire branches: slot 1 trains, slot 2 waits.
    await _commit(dut, [_branch(1), _branch(2)])
    assert _train(dut)["lookup"]["index1"] == 1
    # Slot 1 trains again and a newer slot 2 replaces the held one.
    await _commit(dut, [_branch(3), _branch(4)])
    assert _train(dut)["lookup"]["index1"] == 3
    # A cycle without slot-1 training drains the hold.
    await _commit(dut, [None, None])
    train = _train(dut)
    assert train["valid"]
    assert train["lookup"]["index1"] == 4
    await _step(dut)
    assert not _train(dut)["valid"]

    # With nothing held, a lone slot-2 branch trains at once.
    await _commit(dut, [None, _branch(5)])
    train = _train(dut)
    assert train["valid"]
    assert train["lookup"]["index1"] == 5


@cocotb.test()
async def test_held_slot2_training_is_dropped_when_its_entry_is_reused(
    dut: Any,
) -> None:
    """A slot-2 branch held behind constant slot-1 training loses its entry."""
    await _setup_test(dut)

    first = await _accept_branch(dut, lookup={**LOOKUP_A, "index1": 1})
    await _allocate(dut, 1, first)
    second = await _accept_branch(dut, lookup={**LOOKUP_B, "index1": 2})
    await _allocate(dut, 2, second)
    await _commit(
        dut,
        [
            {"valid": 1, "cond_branch": 1, "tag": 1},
            {"valid": 1, "cond_branch": 1, "tag": 2},
        ],
    )

    # Slot 1 trains every cycle while new branch packets take every entry,
    # including the held branch's. An entry is written the cycle after its
    # packet, so the held entry's turn comes on the 65th edge.
    _drive_commit(dut, [{"valid": 1, "cond_branch": 1, "tag": 1}, None])
    dut.i_pd_accept.value = 1
    dut.i_pd_cond_branch.value = 0b01
    dut.i_tage_slot_valid.value = 0b01
    dut.i_tage_slot_lookup.value = pack_struct(
        TAGE_LOOKUP_FIELDS, {**LOOKUP_A, "index1": 3}
    )
    for _ in range(FTQ_MASK + 2):
        await _step(dut)
        assert _train(dut)["valid"]
    _clear_commit(dut)
    dut.i_pd_accept.value = 0
    dut.i_pd_cond_branch.value = 0
    dut.i_tage_slot_valid.value = 0

    # The first cycle without slot-1 training would have drained the hold.
    await _step(dut)
    assert not _train(dut)["valid"]

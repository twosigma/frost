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

"""Unit tests for the tagged direction predictor (tage_predictor)."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb_tests.cpu_structs import (
    TAGE_INDEX_BITS,
    TAGE_LOOKUP_FIELDS,
    TAGE_TAG_BITS,
)
from utils.packed_structs import pack_struct, unpack_struct


CLOCK_PERIOD_NS = 10
HIST_BITS = 64
T1_HIST_BITS = 16
WORD_BITS = 2 * TAGE_INDEX_BITS + 1  # word-address bits [20:2]
WORD_MASK = (1 << WORD_BITS) - 1
INDEX_MASK = (1 << TAGE_INDEX_BITS) - 1
TAG_MASK = (1 << TAGE_TAG_BITS) - 1
HIST_MASK = (1 << HIST_BITS) - 1
T1_HIST_MASK = (1 << T1_HIST_BITS) - 1

CTR_WEAK_TAKEN = 4
CTR_WEAK_NOT_TAKEN = 3

PC_A = 0x80000100  # even word: bank 0
PC_B = 0x80000344  # odd word: bank 1


def _fold(hist: int, width: int) -> int:
    """XOR-fold the history into width bits (bit b lands on b % width)."""
    folded = 0
    for b in range(HIST_BITS):
        if (hist >> b) & 1:
            folded ^= 1 << (b % width)
    return folded


def _word(pc: int) -> int:
    """Return the word-address bits [20:2] the predictor hashes."""
    return (pc >> 2) & WORD_MASK


def _hash_index(word: int, hist: int) -> int:
    """Model hash_index: PC[11:3] ^ PC[20:12] ^ folded history."""
    return (
        (word >> 1) ^ (word >> (1 + TAGE_INDEX_BITS)) ^ _fold(hist, TAGE_INDEX_BITS)
    ) & (INDEX_MASK)


def _hash_tag(word: int, hist: int) -> int:
    """Model hash_tag: PC[10:2] ^ fold9 ^ (fold8 << 1)."""
    folded = _fold(hist, TAGE_TAG_BITS) ^ (_fold(hist, TAGE_TAG_BITS - 1) << 1)
    return (word ^ folded) & TAG_MASK


def _expected_keys(word: int, hist: int) -> dict[str, int]:
    """Return the indices and tags of one word's lookup."""
    hist_t1 = hist & T1_HIST_MASK
    return {
        "index1": _hash_index(word, hist_t1),
        "index2": _hash_index(word, hist),
        "tag1": _hash_tag(word, hist_t1),
        "tag2": _hash_tag(word, hist),
    }


def _bank_word(lookup_word: int, bank: int) -> int:
    """Return the word bank `bank` reads for a lookup at lookup_word."""
    return lookup_word if (lookup_word & 1) == bank else (lookup_word + 1) & WORD_MASK


# The tables have no reset, so entries persist from one test to the next.
# Each test looks up with a history whose entries no earlier test reached.
_used_entries: set[tuple[int, int, int]] = set()


def _fresh_hist(pc: int) -> int:
    """Return a history whose lookup at pc reaches only unused entries."""
    word = _word(pc)
    for seed in range(1, 1 << 16):
        hist = (seed * 0x9E37_79B9_7F4A_7C15) & HIST_MASK
        entries = set()
        for lookup_word in (word, (word + 1) & WORD_MASK):
            keys = _expected_keys(lookup_word, hist)
            for bank in (0, 1):
                entries.add((1, bank, keys["index1"]))
                entries.add((2, bank, keys["index2"]))
        if entries.isdisjoint(_used_entries):
            _used_entries.update(entries)
            return hist
    raise AssertionError("no history reaches unused entries")


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_lookup_word.value = 0
    dut.i_lookup_hist.value = 0
    dut.i_lookup_capture.value = 0
    dut.i_train_valid.value = 0
    dut.i_train_lookup.value = 0
    dut.i_train_bank.value = 0
    dut.i_train_alt_taken.value = 0
    dut.i_train_taken.value = 0
    dut.i_train_mispredicted.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _cycle(dut: Any) -> None:
    """Advance one clock edge and let registered state settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock and clear inputs. The tables start empty."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut)
    await FallingEdge(dut.i_clk)


def _bank(dut: Any, bank: int) -> dict[str, int | bool]:
    """Return one bank's registered lookup result."""
    signal = dut.o_bank1 if bank else dut.o_bank0
    return unpack_struct(TAGE_LOOKUP_FIELDS, int(signal.value))


async def _lookup(dut: Any, pc: int, hist: int) -> list[dict[str, int | bool]]:
    """Capture one lookup and return both banks' results."""
    dut.i_lookup_word.value = _word(pc)
    dut.i_lookup_hist.value = hist
    dut.i_lookup_capture.value = 1
    await _cycle(dut)
    dut.i_lookup_capture.value = 0
    await _settle()
    return [_bank(dut, 0), _bank(dut, 1)]


async def _lookup_word(dut: Any, pc: int, hist: int) -> dict[str, int | bool]:
    """Capture one lookup and return the result for the bank holding pc."""
    banks = await _lookup(dut, pc, hist)
    return banks[_word(pc) & 1]


def _drive_train(
    dut: Any,
    lookup: dict[str, int | bool],
    bank: int,
    *,
    taken: bool,
    mispredicted: bool,
    alt_taken: bool = False,
) -> None:
    """Drive one training request for a saved lookup."""
    dut.i_train_valid.value = 1
    dut.i_train_lookup.value = pack_struct(TAGE_LOOKUP_FIELDS, lookup)
    dut.i_train_bank.value = bank
    dut.i_train_alt_taken.value = int(alt_taken)
    dut.i_train_taken.value = int(taken)
    dut.i_train_mispredicted.value = int(mispredicted)


async def _train(
    dut: Any,
    lookup: dict[str, int | bool],
    bank: int,
    *,
    taken: bool,
    mispredicted: bool,
    alt_taken: bool = False,
) -> None:
    """Apply one training request; return once its write has landed."""
    _drive_train(
        dut, lookup, bank, taken=taken, mispredicted=mispredicted, alt_taken=alt_taken
    )
    await _cycle(dut)  # read stage
    dut.i_train_valid.value = 0
    await _cycle(dut)  # write stage


@cocotb.test()
async def test_cold_lookup_misses_and_reports_keys_for_both_words(dut: Any) -> None:
    """An empty table misses; each bank reports the hashed keys of its word."""
    await _setup_test(dut)

    for pc in (PC_A, PC_B):
        hist = _fresh_hist(pc)
        banks = await _lookup(dut, pc, hist)
        word = _word(pc)
        assert int(dut.o_lookup_word.value) == word
        assert int(dut.o_lookup_word_next.value) == (word + 1) & WORD_MASK
        assert int(dut.o_lookup_hist.value) == hist
        for bank in (0, 1):
            result = banks[bank]
            assert not result["hit1"]
            assert not result["hit2"]
            assert not result["alt_tagged"]
            for key, value in _expected_keys(_bank_word(word, bank), hist).items():
                assert result[key] == value, (pc, bank, key)


@cocotb.test()
async def test_t1_hashes_only_the_newest_history_bits(dut: Any) -> None:
    """History above T1_HIST_BITS changes T2's keys but not T1's."""
    await _setup_test(dut)

    hist = _fresh_hist(PC_A)
    base = await _lookup_word(dut, PC_A, hist)
    changed = await _lookup_word(dut, PC_A, hist ^ (1 << (T1_HIST_BITS + 3)))

    assert changed["index1"] == base["index1"]
    assert changed["tag1"] == base["tag1"]
    assert (changed["index2"], changed["tag2"]) != (base["index2"], base["tag2"])


@cocotb.test()
async def test_capture_low_holds_the_registered_lookup(dut: Any) -> None:
    """With i_lookup_capture low, new lookup inputs do not reach the outputs."""
    await _setup_test(dut)

    hist = _fresh_hist(PC_A)
    held = await _lookup(dut, PC_A, hist)
    dut.i_lookup_word.value = _word(PC_B)
    dut.i_lookup_hist.value = hist ^ HIST_MASK
    await _cycle(dut)
    await _cycle(dut)

    assert int(dut.o_lookup_word.value) == _word(PC_A)
    assert int(dut.o_lookup_hist.value) == hist
    assert [_bank(dut, 0), _bank(dut, 1)] == held


@cocotb.test()
async def test_mispredict_without_provider_allocates_weak_t1_entry(dut: Any) -> None:
    """A miss that mispredicts allocates T1 weakly in the outcome's direction."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=True)

    hit = await _lookup_word(dut, PC_A, hist)
    assert hit["hit1"]
    assert not hit["hit2"]
    assert hit["taken"]

    # Weakly taken: one not-taken outcome flips the direction.
    await _train(dut, hit, 0, taken=False, mispredicted=False)
    flipped = await _lookup_word(dut, PC_A, hist)
    assert flipped["hit1"]
    assert not flipped["taken"]


@cocotb.test()
async def test_correct_prediction_without_provider_does_not_allocate(dut: Any) -> None:
    """Only a misprediction allocates."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=False)

    again = await _lookup_word(dut, PC_A, hist)
    assert not again["hit1"]
    assert not again["hit2"]


@cocotb.test()
async def test_t1_provider_mispredict_allocates_t2_which_then_provides(
    dut: Any,
) -> None:
    """A T1 provider's misprediction allocates T2; T2 provides with T1 as alternate."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    t1 = await _lookup_word(dut, PC_A, hist)
    assert t1["hit1"] and t1["taken"]

    # T1 said taken; the branch went not-taken.
    await _train(dut, t1, 0, taken=False, mispredicted=True)
    both = await _lookup_word(dut, PC_A, hist)
    assert both["hit1"]
    assert both["hit2"]
    assert not both["taken"]  # T2, weakly not-taken
    assert both["alt_tagged"]
    # T1 moved from weakly taken to weakly not-taken.
    assert not both["alt_tagged_taken"]


@cocotb.test()
async def test_t2_provider_mispredict_updates_counter_without_allocating(
    dut: Any,
) -> None:
    """With T2 providing, a misprediction only moves T2's counter."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    t1 = await _lookup_word(dut, PC_A, hist)
    await _train(dut, t1, 0, taken=False, mispredicted=True)
    t2 = await _lookup_word(dut, PC_A, hist)
    assert t2["hit2"] and not t2["taken"]

    # T2 weakly not-taken; a taken outcome moves it to weakly taken.
    await _train(dut, t2, 0, taken=True, mispredicted=True)
    after = await _lookup_word(dut, PC_A, hist)
    assert after["hit1"]
    assert after["hit2"]
    assert after["taken"]
    # T1's counter is not the provider's and stays where it was.
    assert after["alt_tagged_taken"] == t2["alt_tagged_taken"]


@cocotb.test()
async def test_counters_saturate_in_both_directions(dut: Any) -> None:
    """Three-bit counters saturate; leaving saturation takes four updates."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    entry = await _lookup_word(dut, PC_A, hist)
    for _ in range(6):
        await _train(dut, entry, 0, taken=True, mispredicted=False)

    # 7 needs four not-taken outcomes to predict not-taken.
    for step in range(4):
        await _train(dut, entry, 0, taken=False, mispredicted=False)
        result = await _lookup_word(dut, PC_A, hist)
        assert result["taken"] == (step < 3), step

    for _ in range(6):
        await _train(dut, entry, 0, taken=False, mispredicted=False)
    for step in range(4):
        await _train(dut, entry, 0, taken=True, mispredicted=False)
        result = await _lookup_word(dut, PC_A, hist)
        assert result["taken"] == (step == 3), step


@cocotb.test()
async def test_banks_follow_word_parity(dut: Any) -> None:
    """Bank b holds the window word whose PC[2] is b, and banks train separately."""
    await _setup_test(dut)

    odd_pc = PC_B
    even_pc = odd_pc + 4
    assert _word(odd_pc) & 1 and not _word(even_pc) & 1

    # A lookup at the odd word reads it in bank 1 and the next word in bank 0.
    hist = _fresh_hist(odd_pc)
    banks = await _lookup(dut, odd_pc, hist)
    await _train(dut, banks[0], 0, taken=True, mispredicted=True)

    # The next word's own lookup finds the entry in bank 0 ...
    hit = await _lookup_word(dut, even_pc, hist)
    assert hit["hit1"] and hit["taken"]
    # ... and allocating the same keys in bank 1 leaves it alone.
    await _train(dut, banks[0], 1, taken=False, mispredicted=True)
    hit_again = await _lookup_word(dut, even_pc, hist)
    assert hit_again["hit1"] and hit_again["taken"]
    assert not hit_again["hit2"]


@cocotb.test()
async def test_provider_replaced_since_lookup_is_not_updated(dut: Any) -> None:
    """Training skips a provider entry whose tag changed after the lookup."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    owner = await _lookup_word(dut, PC_A, hist)

    # A saved lookup naming the same T1 entry with another branch's tag.
    stranger = dict(owner)
    stranger["tag1"] = owner["tag1"] ^ 1
    for _ in range(2):
        await _train(dut, stranger, 0, taken=False, mispredicted=False)

    result = await _lookup_word(dut, PC_A, hist)
    assert result["hit1"] and result["taken"]


@cocotb.test()
async def test_useful_entries_block_allocation_until_cleared(dut: Any) -> None:
    """Useful candidates are not replaced; a blocked allocation clears them."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    # Branch A: a T1 entry that is useful (right when the alternate was wrong).
    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    t1 = await _lookup_word(dut, PC_A, hist)
    await _train(dut, t1, 0, taken=True, mispredicted=False, alt_taken=False)

    # A T2 entry for A, made useful the same way. The alternate was wrong
    # too, so T1 stays useful.
    t1 = await _lookup_word(dut, PC_A, hist)
    await _train(dut, t1, 0, taken=False, mispredicted=True, alt_taken=True)
    t2 = await _lookup_word(dut, PC_A, hist)
    assert t2["hit1"] and t2["hit2"] and not t2["taken"]
    await _train(dut, t2, 0, taken=False, mispredicted=False, alt_taken=True)

    # Branch B collides with both of A's entries and mispredicts with no
    # provider: both candidates are useful, so their usefulness clears.
    other = {
        "index1": t2["index1"],
        "index2": t2["index2"],
        "tag1": t2["tag1"] ^ 1,
        "tag2": t2["tag2"] ^ 1,
    }
    await _train(dut, other, 0, taken=True, mispredicted=True)
    kept = await _lookup_word(dut, PC_A, hist)
    assert kept["hit1"] and kept["hit2"]

    # B's next misprediction replaces the T1 entry, now not useful.
    await _train(dut, other, 0, taken=True, mispredicted=True)
    replaced = await _lookup_word(dut, PC_A, hist)
    assert not replaced["hit1"]
    assert replaced["hit2"]


@cocotb.test()
async def test_lookup_in_the_write_cycle_reads_the_old_entry(dut: Any) -> None:
    """A training writes the cycle after its request; a lookup then sees the old entry."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    _drive_train(dut, cold, 0, taken=True, mispredicted=True)
    await _cycle(dut)  # read stage
    dut.i_train_valid.value = 0
    dut.i_lookup_word.value = _word(PC_A)
    dut.i_lookup_hist.value = hist
    dut.i_lookup_capture.value = 1
    await _cycle(dut)  # write stage, with a lookup captured
    dut.i_lookup_capture.value = 0
    await _settle()
    assert not _bank(dut, 0)["hit1"]

    after = await _lookup_word(dut, PC_A, hist)
    assert after["hit1"]


@cocotb.test()
async def test_back_to_back_trainings_of_one_entry_see_each_other(dut: Any) -> None:
    """A read of the entry being written takes the written value."""
    await _setup_test(dut)
    hist = _fresh_hist(PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    # The first allocates weakly taken; the second, the next cycle, finds the
    # new entry and strengthens it.
    _drive_train(dut, cold, 0, taken=True, mispredicted=True)
    await _cycle(dut)
    _drive_train(dut, {**cold, "hit1": 1}, 0, taken=True, mispredicted=False)
    await _cycle(dut)
    dut.i_train_valid.value = 0
    await _cycle(dut)

    # From 5, one not-taken outcome leaves the prediction taken.
    entry = await _lookup_word(dut, PC_A, hist)
    assert entry["hit1"] and entry["taken"]
    await _train(dut, entry, 0, taken=False, mispredicted=False)
    after = await _lookup_word(dut, PC_A, hist)
    assert after["hit1"] and after["taken"]

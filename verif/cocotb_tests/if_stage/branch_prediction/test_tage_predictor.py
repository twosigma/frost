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
    TAGE_TABLES,
    TAGE_TAG_BITS,
)
from utils.packed_structs import pack_struct, unpack_struct


CLOCK_PERIOD_NS = 10
HIST_BITS = 128
TABLE_HIST_BITS = (12, 24, 64, 128)  # riscv_pkg::TageTableHist
T1_HIST_BITS = TABLE_HIST_BITS[0]
WORD_BITS = 2 * TAGE_INDEX_BITS + 1  # word-address bits [20:2]
WORD_MASK = (1 << WORD_BITS) - 1
INDEX_MASK = (1 << TAGE_INDEX_BITS) - 1
TAG_MASK = (1 << TAGE_TAG_BITS) - 1
HIST_MASK = (1 << HIST_BITS) - 1

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
    """Model hash_tag: PC[11:2] ^ fold10 ^ (fold9 << 1)."""
    folded = _fold(hist, TAGE_TAG_BITS) ^ (_fold(hist, TAGE_TAG_BITS - 1) << 1)
    return (word ^ folded) & TAG_MASK


def _expected_keys(word: int, hist: int) -> dict[str, int]:
    """Return the indices and tags of one word's lookup."""
    keys = {}
    for n, bits in enumerate(TABLE_HIST_BITS, start=1):
        table_hist = hist & ((1 << bits) - 1)
        keys[f"index{n}"] = _hash_index(word, table_hist)
        keys[f"tag{n}"] = _hash_tag(word, table_hist)
    return keys


def _bank_word(lookup_word: int, bank: int) -> int:
    """Return the word bank `bank` reads for a lookup at lookup_word."""
    return lookup_word if (lookup_word & 1) == bank else (lookup_word + 1) & WORD_MASK


# Tables have no reset and may power up occupied. Tests that require empty
# allocation candidates prepare only their own rows; other entries stay arbitrary.
_used_entries: set[tuple[int, int, int]] = set()


def _fresh_hist(dut: Any, pc: int) -> int:
    """Reserve fresh rows and make their valid/useful bits empty for the case."""
    word = _word(pc)
    for seed in range(1, 1 << 16):
        hist = (seed * 0x9E37_79B9_7F4A_7C15) & HIST_MASK
        entries = set()
        for lookup_word in (word, (word + 1) & WORD_MASK):
            keys = _expected_keys(lookup_word, hist)
            for bank in (0, 1):
                for n in range(1, TAGE_TABLES + 1):
                    entries.add((n, bank, keys[f"index{n}"]))
        if entries.isdisjoint(_used_entries):
            _used_entries.update(entries)
            for table, bank, index in entries:
                storage = dut.gen_bank[bank].gen_table[table - 1]
                for copy in (storage.u_lookup_copy, storage.u_train_copy):
                    row = copy.ram[index]
                    payload_mask = ((1 << (len(row) - 1)) - 1) & ~3
                    row.value = int(row.value) & payload_mask
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
    """Start the clock and let the idle training input reach its write stage."""
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
async def test_empty_lookup_misses_and_reports_keys_for_both_words(dut: Any) -> None:
    """An empty table misses; each bank reports the hashed keys of its word."""
    await _setup_test(dut)

    for pc in (PC_A, PC_B):
        hist = _fresh_hist(dut, pc)
        banks = await _lookup(dut, pc, hist)
        word = _word(pc)
        assert int(dut.o_lookup_word.value) == word
        assert int(dut.o_lookup_word_next.value) == (word + 1) & WORD_MASK
        assert int(dut.o_lookup_hist.value) == hist
        for bank in (0, 1):
            result = banks[bank]
            for n in range(1, TAGE_TABLES + 1):
                assert not result[f"hit{n}"]
            assert not result["alt_tagged"]
            for key, value in _expected_keys(_bank_word(word, bank), hist).items():
                assert result[key] == value, (pc, bank, key)


@cocotb.test()
async def test_t1_hashes_only_the_newest_history_bits(dut: Any) -> None:
    """History above T1_HIST_BITS changes T2's keys but not T1's."""
    await _setup_test(dut)

    hist = _fresh_hist(dut, PC_A)
    base = await _lookup_word(dut, PC_A, hist)
    changed = await _lookup_word(dut, PC_A, hist ^ (1 << (T1_HIST_BITS + 3)))

    assert changed["index1"] == base["index1"]
    assert changed["tag1"] == base["tag1"]
    assert (changed["index2"], changed["tag2"]) != (base["index2"], base["tag2"])


@cocotb.test()
async def test_capture_low_holds_the_registered_lookup(dut: Any) -> None:
    """With i_lookup_capture low, new lookup inputs do not reach the outputs."""
    await _setup_test(dut)

    hist = _fresh_hist(dut, PC_A)
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
    hist = _fresh_hist(dut, PC_A)

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
    hist = _fresh_hist(dut, PC_A)

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
    hist = _fresh_hist(dut, PC_A)

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
async def test_top_provider_mispredict_updates_counter_without_allocating(
    dut: Any,
) -> None:
    """Each misprediction allocates one table higher; with T4 providing it only moves T4."""
    await _setup_test(dut)
    hist = _fresh_hist(dut, PC_A)

    lookup = await _lookup_word(dut, PC_A, hist)
    taken = True
    for n in range(1, TAGE_TABLES + 1):
        await _train(dut, lookup, 0, taken=taken, mispredicted=True)
        lookup = await _lookup_word(dut, PC_A, hist)
        assert all(lookup[f"hit{m}"] for m in range(1, n + 1)), n
        assert lookup["taken"] == taken, n  # the new top entry, weakly the outcome
        taken = not taken

    # T4 weakly in the last outcome's direction; the opposite outcome flips it.
    top = lookup
    await _train(dut, top, 0, taken=taken, mispredicted=True)
    after = await _lookup_word(dut, PC_A, hist)
    assert all(after[f"hit{m}"] for m in range(1, TAGE_TABLES + 1))
    assert after["taken"] == taken
    # T3, the alternate, is not the provider and stays where it was.
    assert after["alt_tagged"]
    assert after["alt_tagged_taken"] == top["alt_tagged_taken"]


@cocotb.test()
async def test_counters_saturate_in_both_directions(dut: Any) -> None:
    """Three-bit counters saturate; leaving saturation takes four updates."""
    await _setup_test(dut)
    hist = _fresh_hist(dut, PC_A)

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
    hist = _fresh_hist(dut, odd_pc)
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
    """A provider entry whose tag changed after the lookup keeps its value."""
    await _setup_test(dut)
    hist = _fresh_hist(dut, PC_A)

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


def _poke(
    dut: Any, table: int, bank: int, index: int, *, tag: int, ctr: int, useful: int
) -> None:
    """Write one entry into both read copies: {valid, tag, ctr[2:0], useful[1:0]}."""
    storage = dut.gen_bank[bank].gen_table[table - 1]
    value = (1 << (TAGE_TAG_BITS + 5)) | (tag << 5) | (ctr << 2) | useful
    for copy in (storage.u_lookup_copy, storage.u_train_copy):
        copy.ram[index].value = value


def _peek_useful(dut: Any, table: int, bank: int, index: int) -> int:
    return (
        int(dut.gen_bank[bank].gen_table[table - 1].u_lookup_copy.ram[index].value) & 3
    )


@cocotb.test()
async def test_useful_entries_block_allocation_until_they_count_down(dut: Any) -> None:
    """Useful candidates are not replaced; each blocked allocation counts them down."""
    await _setup_test(dut)
    hist = _fresh_hist(dut, PC_A)
    keys = _expected_keys(_word(PC_A), hist)

    # Another branch owns every table's entry, with usefulness 2 in T1 and 1 above.
    for n in range(1, TAGE_TABLES + 1):
        _poke(
            dut,
            n,
            0,
            keys[f"index{n}"],
            tag=keys[f"tag{n}"] ^ 1,
            ctr=4,
            useful=2 if n == 1 else 1,
        )
    cold = await _lookup_word(dut, PC_A, hist)
    assert not any(cold[f"hit{n}"] for n in range(1, TAGE_TABLES + 1))

    # The first misprediction finds no free candidate: every usefulness counts down.
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    assert [_peek_useful(dut, n, 0, keys[f"index{n}"]) for n in range(1, 5)] == [
        1,
        0,
        0,
        0,
    ]
    assert not (await _lookup_word(dut, PC_A, hist))["hit1"]

    # The next allocates in T2, the shortest table no longer useful; T1 keeps its entry.
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    after = await _lookup_word(dut, PC_A, hist)
    assert not after["hit1"] and after["hit2"] and after["taken"]
    assert _peek_useful(dut, 1, 0, keys["index1"]) == 1


@cocotb.test()
async def test_usefulness_counts_two_bits(dut: Any) -> None:
    """A provider right where the alternate was wrong counts usefulness up to 3."""
    await _setup_test(dut)
    hist = _fresh_hist(dut, PC_A)
    keys = _expected_keys(_word(PC_A), hist)

    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    entry = await _lookup_word(dut, PC_A, hist)
    for expected in (1, 2, 3, 3):
        await _train(dut, entry, 0, taken=True, mispredicted=False, alt_taken=False)
        assert _peek_useful(dut, 1, 0, keys["index1"]) == expected
    # Wrong where the alternate was right: one step down.
    await _train(dut, entry, 0, taken=False, mispredicted=True, alt_taken=False)
    assert _peek_useful(dut, 1, 0, keys["index1"]) == 2


@cocotb.test()
async def test_lookup_in_the_write_cycle_reads_the_old_entry(dut: Any) -> None:
    """A training writes the cycle after its request; a lookup then sees the old entry."""
    await _setup_test(dut)
    hist = _fresh_hist(dut, PC_A)

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
    hist = _fresh_hist(dut, PC_A)

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


def _entry(*, valid: bool, tag: int, ctr: int, useful: int) -> int:
    """Pack a table entry: valid, tag, 3-bit counter, 2-bit usefulness (most significant first)."""
    return (int(valid) << (TAGE_TAG_BITS + 5)) | (tag << 5) | (ctr << 2) | (useful & 3)


def _copies(dut: Any, table: int, bank: int, index: int) -> tuple[int, int]:
    """Return one entry's lookup-copy and training-copy values."""
    storage = dut.gen_bank[bank].gen_table[table - 1]
    return (
        int(storage.u_lookup_copy.ram[index].value),
        int(storage.u_train_copy.ram[index].value),
    )


@cocotb.test()
async def test_lookup_only_t2_entry_is_replaced_by_its_first_training(dut: Any) -> None:
    """A T2 entry that only the lookup copy holds stops providing after one training.

    The copies power up with independent contents. Here the lookup copy alone
    holds a not-taken T2 entry matching the branch, which overrides the
    branch's taken T1 entry. Training writes the training copy's entry back,
    so one misprediction later T1 provides and the copies agree.
    """
    await _setup_test(dut)
    hist = _fresh_hist(dut, PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    await _train(dut, cold, 0, taken=True, mispredicted=True)
    t1 = await _lookup_word(dut, PC_A, hist)
    assert t1["hit1"] and t1["taken"] and not t1["hit2"]

    index2 = int(t1["index2"])
    dut.gen_bank[0].gen_table[1].u_lookup_copy.ram[index2].value = _entry(
        valid=True, tag=int(t1["tag2"]), ctr=CTR_WEAK_NOT_TAKEN, useful=0
    )
    planted = await _lookup_word(dut, PC_A, hist)
    assert planted["hit1"] and planted["hit2"]
    assert not planted["taken"]
    assert planted["alt_tagged_taken"]

    await _train(dut, planted, 0, taken=True, mispredicted=True)
    lookup_row, train_row = _copies(dut, 2, 0, index2)
    assert lookup_row == train_row
    after = await _lookup_word(dut, PC_A, hist)
    assert after["hit1"] and not after["hit2"] and after["taken"]


@cocotb.test()
async def test_lookup_only_t1_entry_is_replaced_and_t2_allocated(dut: Any) -> None:
    """A T1 entry that only the lookup copy holds is replaced by its training.

    The misprediction it causes allocates T2 in the same training, so the
    next lookup predicts the outcome, and the T1 copies agree.
    """
    await _setup_test(dut)
    hist = _fresh_hist(dut, PC_A)

    cold = await _lookup_word(dut, PC_A, hist)
    index1 = int(cold["index1"])
    dut.gen_bank[0].gen_table[0].u_lookup_copy.ram[index1].value = _entry(
        valid=True, tag=int(cold["tag1"]), ctr=CTR_WEAK_NOT_TAKEN, useful=0
    )
    planted = await _lookup_word(dut, PC_A, hist)
    assert planted["hit1"] and not planted["hit2"] and not planted["taken"]

    await _train(dut, planted, 0, taken=True, mispredicted=True)
    lookup_row, train_row = _copies(dut, 1, 0, index1)
    assert lookup_row == train_row
    after = await _lookup_word(dut, PC_A, hist)
    assert not after["hit1"] and after["hit2"] and after["taken"]

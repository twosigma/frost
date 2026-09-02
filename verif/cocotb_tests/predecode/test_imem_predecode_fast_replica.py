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

"""Programming/fetch checks for imem_predecode's physical timing banks.

The five-lane block-RAM replica carries raw high-parcel ``C[15]``, ``C[13]``,
and ``C[12]``, the ``rd == x2`` predicate, and the high-parcel allows-slot-2
predicate. Every sideband predicate on the IF PC feedback cone
(``SCALAR_REPLICA_BITS``: both compressed-size flags, EvenLocalPairValid,
PairableNativeLo, PairableCompressedHi, PairableNativeHi, and
Slot2StartValidLo) comes from a pinned low-address per-parity scalar LUTRAM
with an output register. Above that overlay, the first response is withheld
while the same predicates are redecoded from the raw words into those same
scalar-bank output registers; repeating the address publishes them without
putting canonical sideband BRAM outputs on the PC path. The architectural data uses
resource-neutral 28-bit cold plus four-bit ``{word[15], word[10], word[7],
word[6]}`` block-RAM slices. This bench gives the overlay half the test IMEM's
depth, writes both interleaved banks through the programming port, then checks
complete data, predicate, and sideband windows inside and outside the overlay
(including both parcels' RVC source-hot metadata), both PC[2] swap cases, and
read-enable hold behavior. It also keeps an out-of-overlay fetch live across a
debug-style programming rewrite and checks that readiness is quarantined until
the raw word and registered slow predicates realign. The programming clock is
the production div4 clock, which gives the fetch-domain synchronizer its
documented lead over the staged array write.
"""

import importlib.util
from pathlib import Path
from types import ModuleType
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

PORT_A_PERIOD_NS = 40
PORT_B_PERIOD_NS = 10
WORD_COUNT = 16
OVERLAY_WORD_COUNT = 8
FAST_RAW_MASK = (1 << 31) | (1 << 29) | (1 << 28)
FRONTEND_HOT_RAW_MASK = (1 << 15) | (1 << 10) | (1 << 7) | (1 << 6)


def _load_generator() -> ModuleType:
    """Import the offline predecode generator as the sideband golden model."""
    path = (
        Path(__file__).resolve().parents[3]
        / "sw"
        / "common"
        / "generate_imem_predecode_init.py"
    )
    spec = importlib.util.spec_from_file_location("generate_imem_predecode_init", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_GENERATOR = _load_generator()
SIDEBAND_WIDTH = _GENERATOR.SIDEBAND_WIDTH
SCALAR_REPLICA_BITS = dict(_GENERATOR.SCALAR_REPLICA_BITS)


def _replica(word: int, sideband_bit: int) -> int:
    """Return the generator's scalar LUTRAM image bit for one word."""
    return _GENERATOR.make_sideband_bit_replica(word, sideband_bit)


SIDEBAND_MASK = (1 << SIDEBAND_WIDTH) - 1
FAST_SIDEBAND_MASK = (
    0b11
    | (1 << _GENERATOR.SB_ALLOWS_SLOT2_AFTER_HI)
    | (1 << _GENERATOR.SB_PAIRABLE_COMPRESSED_HI)
    | (1 << _GENERATOR.SB_PAIRABLE_NATIVE_HI)
    | (1 << _GENERATOR.SB_SLOT2_START_VALID_LO)
)


def _with_hi_opcode(word: int, opcode: int) -> int:
    """Replace the high parcel's native opcode, including its size quadrant."""
    return (word & ~(0x7F << 16)) | ((opcode & 0x7F) << 16)


def _with_lo_opcode(word: int, opcode: int) -> int:
    """Replace the low parcel's native opcode, including its size quadrant."""
    return (word & ~0x7F) | (opcode & 0x7F)


def _with_hi_size_allows_row(word: int, *, compressed: bool, allows: bool) -> int:
    """Set one row of the high-size/high-allows reconstruction truth table."""
    if not compressed:
        opcode = 0b011_0011 if allows else _GENERATOR.OPC_CSR
        return _with_hi_opcode(word, opcode)

    # C.ADDI (funct3=000) is non-control; C.J (funct3=101) is control.
    funct3 = 0b000 if allows else 0b101
    hi = (word >> 16) & 0xFFFF
    hi = (hi & ~((0x7 << 13) | 0x3)) | (funct3 << 13) | 0b01
    return (word & 0xFFFF) | (hi << 16)


def _expected_compressed_control(parcel: int) -> bool:
    """Independently classify compressed control-flow instructions."""
    funct3 = (parcel >> 13) & 0x7
    funct4 = (parcel >> 12) & 0xF
    rs1 = (parcel >> 7) & 0x1F
    rs2 = (parcel >> 2) & 0x1F
    op = parcel & 0x3
    return (op == 0b01 and funct3 in {0b001, 0b101, 0b110, 0b111}) or (
        op == 0b10 and rs2 == 0 and rs1 != 0 and funct4 in {0b1000, 0b1001}
    )


def _expected_allows_slot2_after_hi(word: int) -> int:
    """Independently model the timing-facing high allows-slot-2 lane."""
    hi = (word >> 16) & 0xFFFF
    opcode = hi & 0x7F
    compressed = (hi & 0x3) != 0b11
    if compressed:
        return int(not _expected_compressed_control(hi))

    native_control = opcode in {
        _GENERATOR.OPC_BRANCH,
        _GENERATOR.OPC_JAL,
        _GENERATOR.OPC_JALR,
    }
    native_serialize = opcode in {
        _GENERATOR.OPC_CSR,
        _GENERATOR.OPC_MISC_MEM,
        _GENERATOR.OPC_AMO,
    }
    return int(not native_control and not native_serialize)


def _expected_pairable_compressed_hi(word: int) -> int:
    """Reconstruct compressed-high pairability from size and allows."""
    compressed = ((word >> 16) & 0x3) != 0b11
    return int(compressed and _expected_allows_slot2_after_hi(word))


def _expected_pairable_native_hi(word: int) -> int:
    """Reconstruct native-high pairability from size and allows."""
    compressed = ((word >> 16) & 0x3) != 0b11
    return int(not compressed and _expected_allows_slot2_after_hi(word))


def _expected_slot2_start_valid_lo(word: int) -> int:
    """Independently model the dedicated bit-10 timing replica."""
    lo = word & 0xFFFF
    opcode = lo & 0x7F
    compressed = (lo & 0x3) != 0b11
    native_serialize = opcode in {
        _GENERATOR.OPC_CSR,
        _GENERATOR.OPC_MISC_MEM,
        _GENERATOR.OPC_AMO,
    }
    native_fp_compute = opcode in {
        _GENERATOR.OPC_OP_FP,
        _GENERATOR.OPC_FMADD,
        _GENERATOR.OPC_FMSUB,
        _GENERATOR.OPC_FNMSUB,
        _GENERATOR.OPC_FNMADD,
    }
    return int(compressed or not (native_serialize or native_fp_compute))


def _expected_compressed(word: int) -> int:
    """Return ``{compressed-hi, compressed-lo}`` for one word."""
    return int((word & 0x3) != 0b11) | (int(((word >> 16) & 0x3) != 0b11) << 1)


def _expected_fast_replica(word: int) -> int:
    """Independently pack the five replica lanes used by RTL and init files."""
    return (
        (_expected_allows_slot2_after_hi(word) << 4)
        | (((word >> 28) & 0b11) << 2)
        | (((word >> 31) & 1) << 1)
        | int(((word >> 23) & 0x1F) == 2)
    )


def _expected_scalar_replica(word: int, sideband_bit: int) -> int:
    """Independently model each scalar LUTRAM predicate image."""
    if sideband_bit == _GENERATOR.SB_IS_COMPRESSED_LO:
        return _expected_compressed(word) & 1
    if sideband_bit == _GENERATOR.SB_IS_COMPRESSED_HI:
        return _expected_compressed(word) >> 1
    if sideband_bit == _GENERATOR.SB_PAIRABLE_COMPRESSED_HI:
        return _expected_pairable_compressed_hi(word)
    if sideband_bit == _GENERATOR.SB_PAIRABLE_NATIVE_HI:
        return _expected_pairable_native_hi(word)
    if sideband_bit == _GENERATOR.SB_SLOT2_START_VALID_LO:
        return _expected_slot2_start_valid_lo(word)
    # EvenLocalPairValid and PairableNativeLo are word-local conjunctions of
    # the predicates above; the generator's sideband is their reference.
    assert sideband_bit in (
        _GENERATOR.SB_EVEN_LOCAL_PAIR_VALID,
        _GENERATOR.SB_PAIRABLE_NATIVE_LO,
    )
    return (_GENERATOR.make_sideband(word) >> sideband_bit) & 1


def _check_offline_init_replica(words: list[int]) -> None:
    """Check every generated physical-bank image and exact word reconstruction."""
    even_words, odd_words = _GENERATOR.split_words(dict(enumerate(words)), len(words))
    assert even_words == words[::2]
    assert odd_words == words[1::2]
    for bank_parity, bank_words in enumerate((even_words, odd_words)):
        for word in bank_words:
            expected_hot = (
                (((word >> 15) & 1) << 3)
                | (((word >> 10) & 1) << 2)
                | (((word >> 7) & 1) << 1)
                | ((word >> 6) & 1)
            )
            expected_cold = 0
            cold_bit = 0
            for word_bit in range(32):
                if FRONTEND_HOT_RAW_MASK & (1 << word_bit):
                    continue
                expected_cold |= ((word >> word_bit) & 1) << cold_bit
                cold_bit += 1
            assert cold_bit == _GENERATOR.COLD_DATA_WIDTH
            got_hot = _GENERATOR.pack_frontend_hot(word)
            got_cold = _GENERATOR.pack_cold_data(word)
            assert got_hot == expected_hot
            assert got_cold == expected_cold
            assert _GENERATOR.join_data_banks(got_cold, got_hot) == word
            assert _GENERATOR.make_fast_replica(word) == _expected_fast_replica(word)
            expected_pc_metadata = (
                (_expected_pairable_native_hi(word) << 3)
                | (_expected_pairable_compressed_hi(word) << 2)
                | _expected_compressed(word)
            )
            assert _GENERATOR.make_pc_metadata_replica(word) == expected_pc_metadata
            for sideband_bit in SCALAR_REPLICA_BITS.values():
                assert _replica(word, sideband_bit) == _expected_scalar_replica(
                    word, sideband_bit
                )


def _make_word(
    payload: int,
    *,
    fast_raw_bits: int,
    hi_rd: int,
    compressed_lo: bool,
    compressed_hi: bool,
) -> int:
    """Set all replica inputs without making the rest of the word trivial."""
    word = payload & ~FAST_RAW_MASK & 0xFFFF_FFFF
    word |= ((fast_raw_bits >> 2) & 1) << 31  # C[15]
    word |= ((fast_raw_bits >> 1) & 1) << 29  # C[13]
    word |= (fast_raw_bits & 1) << 28  # C[12]
    word = (word & ~(0x1F << 23)) | ((hi_rd & 0x1F) << 23)
    word = (word & ~0x3) | (0b01 if compressed_lo else 0b11)
    word = (word & ~(0x3 << 16)) | ((0b01 if compressed_hi else 0b11) << 16)
    return word


async def _write_word(dut: Any, word_index: int, word: int) -> None:
    """Program one word and check programming-port write-first behavior."""
    await FallingEdge(dut.i_port_a_clk)
    dut.i_port_a_enable.value = 1
    dut.i_port_a_byte_address.value = 4 * word_index
    dut.i_port_a_write_data.value = word
    dut.i_port_a_write_enable.value = 1
    await RisingEdge(dut.i_port_a_clk)
    await ReadOnly()
    assert int(dut.o_port_a_read_data.value) == word
    await FallingEdge(dut.i_port_a_clk)
    dut.i_port_a_enable.value = 0
    dut.i_port_a_write_enable.value = 0


async def _read_word(dut: Any, word_index: int, expected: int) -> None:
    """Read one word through port A to independently check its selected bank."""
    await FallingEdge(dut.i_port_a_clk)
    dut.i_port_a_enable.value = 1
    dut.i_port_a_byte_address.value = 4 * word_index
    dut.i_port_a_write_enable.value = 0
    await RisingEdge(dut.i_port_a_clk)
    await ReadOnly()
    assert int(dut.o_port_a_read_data.value) == expected
    await FallingEdge(dut.i_port_a_clk)
    dut.i_port_a_enable.value = 0


def _check_sideband_word(got: int, expected_word: int, label: str) -> None:
    """Check full predecode plus every field supplied by the fast mirror."""
    expected = _GENERATOR.make_sideband(expected_word)
    hex_digits = (SIDEBAND_WIDTH + 3) // 4
    assert (
        got == expected
    ), f"{label} sideband 0x{got:0{hex_digits}x}, want 0x{expected:0{hex_digits}x}"

    expected_compressed = _expected_compressed(expected_word)
    assert (
        got & 0x3 == expected_compressed
    ), f"{label} compressed mirror 0b{got & 0x3:02b}, want 0b{expected_compressed:02b}"
    assert got & FAST_SIDEBAND_MASK == expected & FAST_SIDEBAND_MASK, (
        f"{label} fast-sideband mirror 0x{got & FAST_SIDEBAND_MASK:03x}, "
        f"want 0x{expected & FAST_SIDEBAND_MASK:03x}"
    )
    fast_replica = _GENERATOR.make_fast_replica(expected_word, expected)
    allows_slot2_after_hi = _expected_allows_slot2_after_hi(expected_word)
    pairable_compressed_hi = _expected_pairable_compressed_hi(expected_word)
    pairable_native_hi = _expected_pairable_native_hi(expected_word)
    slot2_start_valid_lo = _expected_slot2_start_valid_lo(expected_word)
    assert (
        (expected >> _GENERATOR.SB_ALLOWS_SLOT2_AFTER_HI) & 1
    ) == allows_slot2_after_hi
    assert (
        (expected >> _GENERATOR.SB_PAIRABLE_COMPRESSED_HI) & 1
    ) == pairable_compressed_hi
    assert (expected >> _GENERATOR.SB_PAIRABLE_NATIVE_HI) & 1 == pairable_native_hi
    assert (expected >> _GENERATOR.SB_SLOT2_START_VALID_LO) & 1 == slot2_start_valid_lo
    assert fast_replica == _expected_fast_replica(expected_word)
    assert (
        _GENERATOR.make_sideband_bit_replica(
            expected_word, _GENERATOR.SB_SLOT2_START_VALID_LO, expected
        )
        == slot2_start_valid_lo
    )


async def _present_fetch_pair(
    dut: Any, byte_address: int, next_byte_address: int
) -> None:
    """Present one enabled request and stop after its registered response edge."""
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 1
    dut.i_port_b_byte_address.value = byte_address
    dut.i_port_b_next_byte_address.value = next_byte_address
    await RisingEdge(dut.i_port_b_clk)
    await ReadOnly()


def _check_fetch_window_outputs(
    dut: Any,
    words: list[int],
    current_index: int,
    *,
    label: str | None = None,
) -> None:
    """Check one ready response, including every folded predicate output."""
    window_label = label or f"window {current_index}"
    current_index %= len(words)
    current = words[current_index]
    next_word = words[(current_index + 1) % len(words)]
    got_data = int(dut.o_port_b_read_data.value)
    expected_data = (next_word << 32) | current
    assert (
        got_data == expected_data
    ), f"{window_label}: data 0x{got_data:016x}, want 0x{expected_data:016x}"
    got_hi_rd_is_x2 = int(dut.o_port_b_hi_rd_is_x2.value)
    expected_hi_rd_is_x2 = int(((current >> 23) & 0x1F) == 2) | (
        int(((next_word >> 23) & 0x1F) == 2) << 1
    )
    assert got_hi_rd_is_x2 == expected_hi_rd_is_x2, (
        f"{window_label}: hi-rd-x2 0b{got_hi_rd_is_x2:02b}, "
        f"want 0b{expected_hi_rd_is_x2:02b}"
    )

    got_sideband = int(dut.o_port_b_sideband.value)
    _check_sideband_word(
        got_sideband & SIDEBAND_MASK, current, f"{window_label} current"
    )
    _check_sideband_word(
        (got_sideband >> SIDEBAND_WIDTH) & SIDEBAND_MASK,
        next_word,
        f"{window_label} next",
    )
    expected_pc_metadata = (
        _GENERATOR.make_pc_metadata_replica(next_word) << 4
    ) | _GENERATOR.make_pc_metadata_replica(current)
    got_pc_metadata = int(dut.o_port_b_pc_metadata.value)
    assert got_pc_metadata == expected_pc_metadata, (
        f"{window_label}: PC metadata 0b{got_pc_metadata:08b}, "
        f"want 0b{expected_pc_metadata:08b}"
    )
    # The timing copies stay in physical-bank order even when the positional
    # fetch window swaps at an odd starting address.
    even_word = current if current_index % 2 == 0 else next_word
    odd_word = next_word if current_index % 2 == 0 else current
    expected_pc_metadata_by_parity = (
        _GENERATOR.make_pc_metadata_replica(odd_word) << 4
    ) | _GENERATOR.make_pc_metadata_replica(even_word)
    got_pc_metadata_by_parity = int(dut.o_port_b_pc_metadata_by_parity.value)
    assert got_pc_metadata_by_parity == expected_pc_metadata_by_parity, (
        f"{window_label}: raw PC metadata 0b{got_pc_metadata_by_parity:08b}, "
        f"want 0b{expected_pc_metadata_by_parity:08b}"
    )

    def pairability(word: int) -> int:
        sideband = _GENERATOR.make_sideband(word)
        return (((sideband >> _GENERATOR.SB_PAIRABLE_NATIVE_LO) & 1) << 1) | (
            (sideband >> _GENERATOR.SB_EVEN_LOCAL_PAIR_VALID) & 1
        )

    expected_pairability_by_parity = (pairability(odd_word) << 2) | pairability(
        even_word
    )
    got_pairability_by_parity = int(dut.o_port_b_pc_pairability_by_parity.value)
    assert got_pairability_by_parity == expected_pairability_by_parity, (
        f"{window_label}: raw pairability "
        f"0b{got_pairability_by_parity:04b}, "
        f"want 0b{expected_pairability_by_parity:04b}"
    )
    expected_start_valid_by_parity = (
        _expected_slot2_start_valid_lo(odd_word) << 1
    ) | _expected_slot2_start_valid_lo(even_word)
    got_start_valid_by_parity = int(dut.o_port_b_slot2_start_valid_lo_by_parity.value)
    assert got_start_valid_by_parity == expected_start_valid_by_parity, (
        f"{window_label}: raw slot2-start 0b{got_start_valid_by_parity:02b}, "
        f"want 0b{expected_start_valid_by_parity:02b}"
    )
    assert int(dut.o_port_b_bank_sel_r.value) == (current_index & 1)


async def _fetch_window(dut: Any, words: list[int], current_index: int) -> None:
    """Fetch one adjacent pair and check data, mirrored bits, and parity steer."""
    await _present_fetch_pair(dut, 4 * current_index, 4 * current_index + 4)

    window_overlay_hit = current_index + 1 < OVERLAY_WORD_COUNT
    assert int(dut.o_port_b_window_overlay_hit.value) == window_overlay_hit
    if window_overlay_hit:
        assert int(dut.o_port_b_response_ready.value) == 1
    else:
        # Mixed-boundary and fully outside windows are entirely slow. The
        # first response is quarantined; an identical second read aligns the
        # registered redecode predicates with the held raw payload.
        assert int(dut.o_port_b_response_ready.value) == 0
        await RisingEdge(dut.i_port_b_clk)
        await ReadOnly()
        assert int(dut.o_port_b_window_overlay_hit.value) == 0
        assert int(dut.o_port_b_response_ready.value) == 1

    _check_fetch_window_outputs(dut, words, current_index)
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0


@cocotb.test()
async def test_programmed_fast_replica_and_parity_swap(dut: Any) -> None:
    """Cover every replica field, bank-swap direction, and overwrite transition."""
    words = [0] * WORD_COUNT
    for fast_raw_bits in range(8):
        even_index = 2 * fast_raw_bits
        odd_index = even_index + 1
        odd_fast_raw_bits = fast_raw_bits ^ 0b111
        words[even_index] = _make_word(
            0x1357_9BDF ^ (even_index * 0x0101_0101),
            fast_raw_bits=fast_raw_bits,
            hi_rd=2 if fast_raw_bits & 1 else 3,
            compressed_lo=bool(fast_raw_bits & 1),
            compressed_hi=bool(fast_raw_bits & 2),
        )
        words[odd_index] = _make_word(
            0x2468_ACE0 ^ (odd_index * 0x0101_0101),
            fast_raw_bits=odd_fast_raw_bits,
            hi_rd=2 if odd_fast_raw_bits & 2 else 18,
            compressed_lo=bool(odd_fast_raw_bits & 2),
            compressed_hi=bool(odd_fast_raw_bits & 4),
        )

    # Exercise both values of every predicate replica in each physical bank,
    # including compressed, ordinary native, serialize, and FP-compute cases.
    high_size_allows_rows = [
        (False, False),
        (False, True),
        (True, False),
        (True, True),
    ]
    low_opcodes = [0b000_0001, 0b011_0011, _GENERATOR.OPC_CSR, _GENERATOR.OPC_OP_FP]
    for case_index in range(8):
        compressed_hi, allows_hi = high_size_allows_rows[
            case_index % len(high_size_allows_rows)
        ]
        low_opcode = low_opcodes[case_index % len(low_opcodes)]
        for word_index in (2 * case_index, 2 * case_index + 1):
            words[word_index] = _with_hi_size_allows_row(
                words[word_index], compressed=compressed_hi, allows=allows_hi
            )
            words[word_index] = _with_lo_opcode(words[word_index], low_opcode)

    # Direct both asymmetric odd-bank lane-3 combinations.  These repeated
    # high-size/high-allows rows leave the four-way matrix above intact while
    # proving that physical Slot2StartValidLo is not an alias of public
    # PairableNativeHi.
    words[9] = _with_hi_size_allows_row(words[9], compressed=False, allows=False)
    words[9] = _with_lo_opcode(words[9], 0b011_0011)
    words[11] = _with_hi_size_allows_row(words[11], compressed=False, allows=True)
    words[11] = _with_lo_opcode(words[11], _GENERATOR.OPC_CSR)

    # Case 1 has an ordinary native high parcel, so making the low parcel a
    # non-control C.ADDI creates EvenLocalPairValid=1 without disturbing the
    # four-way high-size/high-allows matrix. Cover that scalar lane in both
    # physical parity banks.
    for word_index in (2, 3):
        words[word_index] = (words[word_index] & 0xFFFF_0000) | 0x0001

    for bank_parity in (0, 1):
        observed_size_allows_rows = {
            (
                int(((word >> 16) & 0x3) != 0b11),
                _expected_allows_slot2_after_hi(word),
            )
            for word in words[bank_parity::2]
        }
        assert observed_size_allows_rows == {(0, 0), (0, 1), (1, 0), (1, 1)}
        mirrored_allows_values = {
            _expected_allows_slot2_after_hi(word) for word in words[bank_parity::2]
        }
        assert mirrored_allows_values == {0, 1}
        pairable_compressed_values = {
            _expected_pairable_compressed_hi(word) for word in words[bank_parity::2]
        }
        assert pairable_compressed_values == {0, 1}
        pairable_native_values = {
            _expected_pairable_native_hi(word) for word in words[bank_parity::2]
        }
        assert pairable_native_values == {0, 1}
        start_valid_values = {
            _expected_slot2_start_valid_lo(word) for word in words[bank_parity::2]
        }
        assert start_valid_values == {0, 1}
        for sideband_bit in SCALAR_REPLICA_BITS.values():
            assert {_replica(word, sideband_bit) for word in words[bank_parity::2]} == {
                0,
                1,
            }
    # Slot2StartValidLo and PairableNativeHi must differ in both directions,
    # proving that the test observes distinct scalar lanes rather than aliases.
    odd_slot2_native_hi_pairs = {
        (
            _expected_slot2_start_valid_lo(word),
            _expected_pairable_native_hi(word),
        )
        for word in words[1::2]
    }
    assert {(0, 1), (1, 0)} <= odd_slot2_native_hi_pairs
    _check_offline_init_replica(words)

    dut.i_port_a_enable.value = 0
    dut.i_port_a_byte_address.value = 0
    dut.i_port_a_write_data.value = 0
    dut.i_port_a_write_enable.value = 0
    dut.i_port_b_enable.value = 0
    dut.i_port_b_byte_address.value = 0
    dut.i_port_b_next_byte_address.value = 4
    cocotb.start_soon(Clock(dut.i_port_a_clk, PORT_A_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.i_port_b_clk, PORT_B_PERIOD_NS, unit="ns").start())

    for word_index, word in enumerate(words):
        await _write_word(dut, word_index, word)

    dut.i_port_a_enable.value = 0
    dut.i_port_a_write_enable.value = 0
    for word_index, word in enumerate(words):
        await _read_word(dut, word_index, word)

    dut.i_port_a_enable.value = 0
    for current_index in range(len(words)):
        await _fetch_window(dut, words, current_index)

    # Overlay hits must retain the original one-response-per-cycle behavior.
    # Keep enable asserted while both physical parity and every address change;
    # a helper that disabled between windows would miss a stale registered
    # overlay selector or a one-cycle shift in the folded output register.
    for current_index in (0, 1, 3, 5, 2, 6, 0):
        await _present_fetch_pair(dut, 4 * current_index, 4 * current_index + 4)
        assert int(dut.o_port_b_window_overlay_hit.value) == 1
        assert int(dut.o_port_b_response_ready.value) == 1
        _check_fetch_window_outputs(
            dut, words, current_index, label=f"streaming overlay {current_index}"
        )
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0

    # Exercise both selector directions without disabling the read port. The
    # mixed {last-overlay-word, first-outside-word} pair must send BOTH parity
    # outputs through the folded slow input, withhold once, then publish the
    # repeated pair. Returning to an overlay pair is immediately ready.
    await _present_fetch_pair(dut, 4 * 6, 4 * 7)
    assert int(dut.o_port_b_window_overlay_hit.value) == 1
    assert int(dut.o_port_b_response_ready.value) == 1
    _check_fetch_window_outputs(dut, words, 6, label="boundary predecessor")

    await _present_fetch_pair(dut, 4 * 7, 4 * 8)
    assert int(dut.o_port_b_window_overlay_hit.value) == 0
    assert int(dut.o_port_b_response_ready.value) == 0

    await _present_fetch_pair(dut, 4 * 7, 4 * 8)
    assert int(dut.o_port_b_window_overlay_hit.value) == 0
    assert int(dut.o_port_b_response_ready.value) == 1
    _check_fetch_window_outputs(dut, words, 7, label="mixed boundary repeat")

    await _present_fetch_pair(dut, 4 * 2, 4 * 3)
    assert int(dut.o_port_b_window_overlay_hit.value) == 1
    assert int(dut.o_port_b_response_ready.value) == 1
    _check_fetch_window_outputs(dut, words, 2, label="boundary return to overlay")
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0

    # ADDR_WIDTH=4 aliases byte address bits above bit 5 at the physical BRAM
    # pins. Read two distinct full address pairs with identical truncated pins
    # back-to-back: the second pair must still be a fresh miss, proving both
    # repeat detection and overlay qualification use all 32 address bits.
    for alias_base in (0x40, 0x80):
        await _present_fetch_pair(dut, alias_base, alias_base + 4)
        assert int(dut.o_port_b_window_overlay_hit.value) == 0
        assert int(dut.o_port_b_response_ready.value) == 0

        await _present_fetch_pair(dut, alias_base, alias_base + 4)
        assert int(dut.o_port_b_window_overlay_hit.value) == 0
        assert int(dut.o_port_b_response_ready.value) == 1
        _check_fetch_window_outputs(
            dut, words, 0, label=f"full-address alias 0x{alias_base:02x}"
        )
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0

    # An outside-overlay response is publishable only when the exact ordered
    # physical-address pair repeats on consecutive enabled reads. Alternating
    # two valid pairs must therefore remain unready indefinitely.
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 1
    for current_index in (8, 10, 8, 10):
        dut.i_port_b_byte_address.value = 4 * current_index
        dut.i_port_b_next_byte_address.value = 4 * current_index + 4
        await RisingEdge(dut.i_port_b_clk)
        await ReadOnly()
        assert int(dut.o_port_b_window_overlay_hit.value) == 0
        assert int(dut.o_port_b_response_ready.value) == 0
        await FallingEdge(dut.i_port_b_clk)

    # Once a pair has repeated, disabling the read port invalidates its
    # history. Re-enabling the same pair must rebuild the slow predicates and
    # withhold that first response again.
    await RisingEdge(dut.i_port_b_clk)
    await ReadOnly()
    assert int(dut.o_port_b_response_ready.value) == 1
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0
    await RisingEdge(dut.i_port_b_clk)
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 1
    await RisingEdge(dut.i_port_b_clk)
    await ReadOnly()
    assert int(dut.o_port_b_window_overlay_hit.value) == 0
    assert int(dut.o_port_b_response_ready.value) == 0
    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0

    # Exercise 000 -> 111 and 111 -> 000 in both physical banks. Distinctive
    # replacement payloads make the complete fetched-word comparison catch any
    # stale BRAM field as well as a stale replica lane.
    overwrites = {
        0: _with_hi_opcode(
            _make_word(
                0x0BAD_C0DE,
                fast_raw_bits=0b111,
                hi_rd=2,
                compressed_lo=True,
                compressed_hi=False,
            ),
            0b001_0011,
        ),
        1: _with_hi_opcode(
            _make_word(
                0x1234_5678,
                fast_raw_bits=0b000,
                hi_rd=31,
                compressed_lo=False,
                compressed_hi=True,
            ),
            0b001_0011,
        ),
        14: _with_hi_opcode(
            _make_word(
                0x89AB_CDEF,
                fast_raw_bits=0b000,
                hi_rd=0,
                compressed_lo=True,
                compressed_hi=True,
            ),
            0b111_0011,
        ),
        15: _with_hi_opcode(
            _make_word(
                0x55AA_33CC,
                fast_raw_bits=0b111,
                hi_rd=2,
                compressed_lo=False,
                compressed_hi=False,
            ),
            0b000_0001,
        ),
    }
    # Flip the high-allows and low-start-valid replicas on every overwrite so
    # stale values are observable in both banks and both sides of the swap mux.
    for word_index, word in tuple(overwrites.items()):
        old_allows = _expected_allows_slot2_after_hi(words[word_index])
        replacement_hi_opcode = _GENERATOR.OPC_CSR if old_allows else 0b011_0011
        word = _with_hi_opcode(word, replacement_hi_opcode)
        old_start_valid = _expected_slot2_start_valid_lo(words[word_index])
        replacement_opcode = _GENERATOR.OPC_OP_FP if old_start_valid else 0b011_0011
        word = _with_lo_opcode(word, replacement_opcode)
        if word_index in (14, 15):
            # Also flip both scalar EvenLocalPairValid mirrors: a low C.ADDI
            # followed by high JAL preserves the high-allows, low-start, and
            # pairable-compressed-high overwrite transitions checked below.
            word = _with_hi_opcode(word, _GENERATOR.OPC_JAL)
            word = (word & 0xFFFF_0000) | 0x0001
        overwrites[word_index] = word
    for word_index, word in overwrites.items():
        assert _expected_allows_slot2_after_hi(word) != _expected_allows_slot2_after_hi(
            words[word_index]
        )
        assert _expected_slot2_start_valid_lo(word) != _expected_slot2_start_valid_lo(
            words[word_index]
        )
    for word_index in (14, 15):
        assert _replica(
            overwrites[word_index], _GENERATOR.SB_EVEN_LOCAL_PAIR_VALID
        ) != _replica(words[word_index], _GENERATOR.SB_EVEN_LOCAL_PAIR_VALID)
    for word_index in overwrites:
        assert _replica(
            overwrites[word_index], _GENERATOR.SB_PAIRABLE_NATIVE_LO
        ) != _replica(words[word_index], _GENERATOR.SB_PAIRABLE_NATIVE_LO)
    for word_index in (0, 1):
        assert _replica(
            overwrites[word_index], _GENERATOR.SB_PAIRABLE_NATIVE_HI
        ) != _replica(words[word_index], _GENERATOR.SB_PAIRABLE_NATIVE_HI)
    _check_offline_init_replica(list(overwrites.values()))
    for word_index, word in overwrites.items():
        await _write_word(dut, word_index, word)
        words[word_index] = word

    for word_index, word in overwrites.items():
        await _read_word(dut, word_index, word)

    for current_index in range(len(words)):
        await _fetch_window(dut, words, current_index)

    # Every scalar LUTRAM uses an asynchronous primitive read followed by an
    # enabled output register. Prove that changing the address to a row whose
    # predicate differs cannot leak through while the shared fetch enable is
    # disabled, for every predicate on both physical parities.
    def parity_word_indices(index: int) -> tuple[int, int]:
        even_index = index if index % 2 == 0 else index + 1
        odd_index = index + 1 if index % 2 == 0 else index
        return even_index, odd_index

    hold_indices = []
    for sideband_bit in SCALAR_REPLICA_BITS.values():
        for parity in (0, 1):
            hold_indices.append(
                next(
                    index
                    for index in range(1, len(words) - 1)
                    if _replica(words[parity_word_indices(index)[parity]], sideband_bit)
                    != _replica(words[parity], sideband_bit)
                )
            )
    await _fetch_window(dut, words, 0)
    held_pc_metadata = int(dut.o_port_b_pc_metadata.value)
    held_pc_metadata_by_parity = int(dut.o_port_b_pc_metadata_by_parity.value)
    held_pairability_by_parity = int(dut.o_port_b_pc_pairability_by_parity.value)
    held_slot2_start_by_parity = int(dut.o_port_b_slot2_start_valid_lo_by_parity.value)
    held_sideband = int(dut.o_port_b_sideband.value)
    held_overlay_hit = int(dut.o_port_b_window_overlay_hit.value)
    held_response_ready = int(dut.o_port_b_response_ready.value)
    for hold_index in hold_indices:
        dut.i_port_b_byte_address.value = 4 * hold_index
        dut.i_port_b_next_byte_address.value = 4 * hold_index + 4
        await RisingEdge(dut.i_port_b_clk)
        await ReadOnly()
        assert int(dut.o_port_b_pc_metadata.value) == held_pc_metadata
        assert (
            int(dut.o_port_b_pc_metadata_by_parity.value) == held_pc_metadata_by_parity
        )
        assert (
            int(dut.o_port_b_pc_pairability_by_parity.value)
            == held_pairability_by_parity
        )
        assert (
            int(dut.o_port_b_slot2_start_valid_lo_by_parity.value)
            == held_slot2_start_by_parity
        )
        assert int(dut.o_port_b_sideband.value) == held_sideband
        assert int(dut.o_port_b_window_overlay_hit.value) == held_overlay_hit
        assert int(dut.o_port_b_response_ready.value) == held_response_ready
        await FallingEdge(dut.i_port_b_clk)

    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0

    # A halted hart keeps fetching from the debug execution slice while the
    # debug module rewrites it through port A. That slice lies outside the
    # pinned overlay, so the canonical BRAM sees a new word one response before
    # the registered slow scalar fallback. Repeated-address history must drop
    # readiness across the write and rebuild it before publishing the new pair.
    live_index = 14
    replacement = _with_lo_opcode(words[live_index], 0b011_0011)
    if _replica(replacement, _GENERATOR.SB_PAIRABLE_NATIVE_LO) == _replica(
        words[live_index], _GENERATOR.SB_PAIRABLE_NATIVE_LO
    ):
        replacement = _with_lo_opcode(words[live_index], _GENERATOR.OPC_CSR)
    assert _replica(replacement, _GENERATOR.SB_PAIRABLE_NATIVE_LO) != _replica(
        words[live_index], _GENERATOR.SB_PAIRABLE_NATIVE_LO
    )

    await _present_fetch_pair(dut, 4 * live_index, 4 * live_index + 4)
    assert not dut.o_port_b_response_ready.value
    await RisingEdge(dut.i_port_b_clk)
    await ReadOnly()
    assert dut.o_port_b_response_ready.value

    await _write_word(dut, live_index, replacement)
    words[live_index] = replacement

    saw_write_quarantine = False
    saw_rebuilt_response = False
    for _ in range(16):
        await RisingEdge(dut.i_port_b_clk)
        await ReadOnly()
        if not dut.o_port_b_response_ready.value:
            saw_write_quarantine = True
        elif saw_write_quarantine:
            _check_fetch_window_outputs(
                dut, words, live_index, label="post-programming slow response"
            )
            saw_rebuilt_response = True
            break
    assert saw_write_quarantine
    assert saw_rebuilt_response

    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0

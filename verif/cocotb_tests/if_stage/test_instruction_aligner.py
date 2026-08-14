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

"""Unit tests for the IF-stage instruction aligner."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


PC_LO = 0x80001000
PC_HI = PC_LO | 0x2
PC_BANK1_LO = PC_LO | 0x4
OPC_BRANCH = 0b1100011
OPC_JAL = 0b1101111
COMPRESSED_NOP = 0x0001
COMPRESSED_J = (0b101 << 13) | 0b01

SB_IS_COMPRESSED_LO = 0
SB_IS_COMPRESSED_HI = 1
SB_EVEN_LOCAL_PAIR_VALID = 2
SB_PAIRABLE_NATIVE_LO = 3
SB_NATIVE_SERIALIZE_LO = 4
SB_NATIVE_SERIALIZE_HI = 5
SB_PAIRABLE_COMPRESSED_HI = 6
SB_PAIRABLE_NATIVE_HI = 7
SB_ALLOWS_SLOT2_AFTER_LO = 8
SB_ALLOWS_SLOT2_AFTER_HI = 9
SB_SLOT2_START_VALID_LO = 10
SB_SLOT2_START_VALID_HI = 11
SB_RVC_SOURCE_HOT_LO_LSB = 12
SB_RVC_SOURCE_HOT_HI_LSB = 15
SIDEBAND_WIDTH = 18


def _word(*, lo: int, hi: int) -> int:
    """Pack two 16-bit parcels into one instruction word."""
    return ((hi & 0xFFFF) << 16) | (lo & 0xFFFF)


def _fetch(*, current_word: int, next_word: int) -> int:
    """Pack the 64-bit fetch bus as {next_word, current_word}."""
    return ((next_word & 0xFFFFFFFF) << 32) | (current_word & 0xFFFFFFFF)


def _source_hot(instruction: int) -> int:
    """Return packed {rs2[1], rs1[2:1]} from a final instruction."""
    return ((instruction >> 19) & 0x4) | ((instruction >> 16) & 0x3)


def _bit(enabled: bool, bit: int) -> int:
    """Return one sideband bit when enabled."""
    return int(enabled) << bit


def _sideband(
    *,
    compressed_lo: bool = False,
    compressed_hi: bool = False,
    compressed_control_lo: bool = False,
    compressed_control_hi: bool = False,
    native_serialize_lo: bool = False,
    native_serialize_hi: bool = False,
    native_fp_compute_lo: bool = False,
    native_fp_compute_hi: bool = False,
    native_pairable_lo: bool = False,
    native_pairable_hi: bool = False,
    rvc_source_hot_lo: int = 0,
    rvc_source_hot_hi: int = 0,
) -> int:
    """Build one 32-bit-word instruction-memory sideband value."""
    allows_slot2_after_lo = (compressed_lo and not compressed_control_lo) or (
        not compressed_lo and native_pairable_lo
    )
    allows_slot2_after_hi = (compressed_hi and not compressed_control_hi) or (
        not compressed_hi and native_pairable_hi
    )
    slot2_start_valid_lo = compressed_lo or not (
        native_serialize_lo or native_fp_compute_lo
    )
    slot2_start_valid_hi = compressed_hi or not (
        native_serialize_hi or native_fp_compute_hi
    )
    even_local_pair_valid = (
        compressed_lo and allows_slot2_after_lo and slot2_start_valid_hi
    )
    return (
        _bit(compressed_lo, SB_IS_COMPRESSED_LO)
        | _bit(compressed_hi, SB_IS_COMPRESSED_HI)
        | _bit(even_local_pair_valid, SB_EVEN_LOCAL_PAIR_VALID)
        | _bit(
            not compressed_lo and allows_slot2_after_lo,
            SB_PAIRABLE_NATIVE_LO,
        )
        | _bit(native_serialize_lo, SB_NATIVE_SERIALIZE_LO)
        | _bit(native_serialize_hi, SB_NATIVE_SERIALIZE_HI)
        | _bit(
            compressed_hi and allows_slot2_after_hi,
            SB_PAIRABLE_COMPRESSED_HI,
        )
        | _bit(
            not compressed_hi and allows_slot2_after_hi,
            SB_PAIRABLE_NATIVE_HI,
        )
        | _bit(allows_slot2_after_lo, SB_ALLOWS_SLOT2_AFTER_LO)
        | _bit(allows_slot2_after_hi, SB_ALLOWS_SLOT2_AFTER_HI)
        | _bit(slot2_start_valid_lo, SB_SLOT2_START_VALID_LO)
        | _bit(slot2_start_valid_hi, SB_SLOT2_START_VALID_HI)
        | ((rvc_source_hot_lo & 0x7) << SB_RVC_SOURCE_HOT_LO_LSB)
        | ((rvc_source_hot_hi & 0x7) << SB_RVC_SOURCE_HOT_HI_LSB)
    )


def _fetch_sideband(*, current_sb: int = 0, next_sb: int = 0) -> int:
    """Pack the fetch sideband bus as {next_word_sideband, current_word_sideband}."""
    mask = (1 << SIDEBAND_WIDTH) - 1
    return ((next_sb & mask) << SIDEBAND_WIDTH) | (current_sb & mask)


def _pc_compressed_from_fetch_sideband(fetch_sideband: int) -> int:
    """Pack the PC-only size window as {next[hi,lo], current[hi,lo]}."""
    current_sb = fetch_sideband & ((1 << SIDEBAND_WIDTH) - 1)
    next_sb = (fetch_sideband >> SIDEBAND_WIDTH) & ((1 << SIDEBAND_WIDTH) - 1)
    return ((next_sb & 0b11) << 2) | (current_sb & 0b11)


def _fetch_hi_rd_is_x2(*, current_word: int, next_word: int) -> int:
    """Pack the high-parcel rd==x2 predicates as {next,current}."""
    return int(((current_word >> 23) & 0x1F) == 2) | (
        int(((next_word >> 23) & 0x1F) == 2) << 1
    )


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    current_word = _word(lo=COMPRESSED_NOP, hi=0x0013)
    next_word = _word(lo=0x0023, hi=0x0033)
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_hi_rd_is_x2.value = _fetch_hi_rd_is_x2(
        current_word=current_word, next_word=next_word
    )
    fetch_sideband = _fetch_sideband(
        current_sb=_sideband(compressed_lo=True),
    )
    dut.i_instr_sideband.value = fetch_sideband
    dut.i_instr_pc_compressed.value = _pc_compressed_from_fetch_sideband(fetch_sideband)
    dut.i_instr_bank_sel_r.value = 0
    dut.i_instr_buffer.value = 0
    dut.i_instr_buffer_sideband.value = 0
    dut.i_pc_reg.value = PC_LO
    dut.i_prev_was_compressed_at_lo.value = 0
    dut.i_use_buffer_after_prediction.value = 0
    dut.i_mid_32bit_correction.value = 0
    dut.i_prediction_holdoff.value = 0
    dut.i_prediction_from_buffer_holdoff.value = 0
    dut.i_stall_registered.value = 0
    dut.i_prev_was_compressed_at_lo_saved.value = 0
    dut.i_is_compressed_saved.value = 0
    dut.i_saved_values_valid.value = 0


async def _settle(dut: Any) -> None:
    """Drive the exact fetch predicate and let combinational outputs settle."""
    # Apply any instruction-bus write made by the caller before deriving its
    # companion predicate; an immediate VPI read can still see the old value.
    await Timer(1, unit="ps")
    dut.i_instr_pc_compressed.value = _pc_compressed_from_fetch_sideband(
        int(dut.i_instr_sideband.value)
    )
    fetch = int(dut.i_instr.value)
    current_word = fetch & 0xFFFF_FFFF
    next_word = (fetch >> 32) & 0xFFFF_FFFF
    dut.i_instr_hi_rd_is_x2.value = _fetch_hi_rd_is_x2(
        current_word=current_word, next_word=next_word
    )
    await Timer(1, unit="ns")


async def _setup_test(dut: Any) -> None:
    """Initialize the combinational aligner inputs."""
    _clear_inputs(dut)
    await _settle(dut)


def _assert_slot1(
    dut: Any,
    *,
    raw: int,
    effective: int,
    compressed: bool,
    fast_compressed: bool,
    sel_nop: bool = False,
    use_buffer: bool = False,
    branch: bool = False,
) -> None:
    """Assert slot-1 alignment outputs."""
    assert int(dut.o_raw_parcel.value) == raw
    assert int(dut.o_effective_instr.value) == effective
    assert bool(dut.o_is_compressed.value) is compressed
    assert bool(dut.o_is_compressed_fast.value) is fast_compressed
    assert bool(dut.o_is_compressed_for_pc_advance.value) is fast_compressed
    assert bool(dut.o_sel_compressed.value) is compressed
    assert bool(dut.o_sel_nop.value) is sel_nop
    assert bool(dut.o_use_instr_buffer.value) is use_buffer
    assert bool(dut.o_slot1_is_branch.value) is branch


def _assert_slot2(
    dut: Any,
    *,
    raw: int,
    effective: int,
    compressed: bool,
    sel_nop: bool,
) -> None:
    """Assert slot-2 alignment outputs."""
    assert int(dut.o_raw_parcel_2.value) == raw
    assert int(dut.o_effective_instr_2.value) == effective
    assert bool(dut.o_is_compressed_2.value) is compressed
    assert bool(dut.o_sel_compressed_2.value) is compressed
    assert bool(dut.o_sel_nop_2.value) is sel_nop
    assert bool(dut.o_slot2_valid_for_pc.value) is (not sel_nop)
    assert int(dut.o_source_hot_2.value) == _source_hot(effective)
    if not sel_nop:
        assert bool(dut.o_slot2_is_compressed_for_pc.value) is compressed


def _assert_slot2_btb_candidate_sizes(
    dut: Any,
    *,
    plus2_compressed: bool,
    plus4_compressed: bool,
) -> None:
    """Assert the fixed candidate sizes exported before slot-1-size selection."""
    assert bool(dut.o_slot2_is_compressed_plus2_for_btb.value) is plus2_compressed
    assert bool(dut.o_slot2_is_compressed_plus4_for_btb.value) is plus4_compressed


@cocotb.test()
async def test_pc_size_replica_is_consumer_local(dut: Any) -> None:
    """Only the PC-advance size view follows the dedicated replica."""
    await _setup_test(dut)
    current_sb = _sideband(compressed_lo=True)
    dut.i_instr_sideband.value = _fetch_sideband(current_sb=current_sb)
    await _settle(dut)

    assert bool(dut.o_is_compressed.value)
    assert bool(dut.o_is_compressed_fast.value)
    assert bool(dut.o_is_compressed_for_pc_advance.value)

    # Artificially diverge the timing copy to prove the architectural/general
    # aligner view remains sourced from the canonical sideband.
    dut.i_instr_pc_compressed.value = 0
    await Timer(1, unit="ns")
    assert bool(dut.o_is_compressed.value)
    assert bool(dut.o_is_compressed_fast.value)
    assert not bool(dut.o_is_compressed_for_pc_advance.value)


@cocotb.test()
async def test_low_parcel_selects_current_word_and_current_hi_slot2(dut: Any) -> None:
    """Low-half slot-1 uses current word and slot-2 can start at current hi."""
    await _setup_test(dut)

    current_word = _word(lo=COMPRESSED_NOP, hi=0x2223)
    next_word = _word(lo=0x3333, hi=0x4444)
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(compressed_lo=True),
    )
    await _settle(dut)

    _assert_slot1(
        dut,
        raw=COMPRESSED_NOP,
        effective=current_word,
        compressed=True,
        fast_compressed=True,
    )
    _assert_slot2(
        dut,
        raw=0x2223,
        effective=_word(lo=0x2223, hi=0x3333),
        compressed=False,
        sel_nop=False,
    )
    _assert_slot2_btb_candidate_sizes(
        dut, plus2_compressed=False, plus4_compressed=False
    )


@cocotb.test()
async def test_high_parcel_selects_current_hi_and_next_lo_slot2(dut: Any) -> None:
    """High-half compressed slot-1 takes slot-2 from next word low half."""
    await _setup_test(dut)

    current_word = _word(lo=0x1111, hi=COMPRESSED_NOP)
    next_word = _word(lo=0x3331, hi=0x4444)
    dut.i_pc_reg.value = PC_HI
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(compressed_hi=True, rvc_source_hot_hi=0),
        next_sb=_sideband(compressed_lo=True, rvc_source_hot_lo=3),
    )
    await _settle(dut)

    _assert_slot1(
        dut,
        raw=COMPRESSED_NOP,
        effective=current_word,
        compressed=True,
        fast_compressed=True,
    )
    _assert_slot2(
        dut,
        raw=0x3331,
        # effective carries the RVC expansion: parcel 0x3331 is
        # C.ADDIW x6, -20.
        effective=0xFEC3031B,
        compressed=True,
        sel_nop=False,
    )
    assert int(dut.o_rvc_source_hot.value) == 0
    assert int(dut.o_source_hot_2.value) == 3


@cocotb.test()
async def test_precomputed_pc_qualifiers_cover_all_four_pair_shapes(dut: Any) -> None:
    """The word-local qualifier bits preserve every slot-1 position/size shape."""
    await _setup_test(dut)

    # A: compressed slot-1 at even -> same-word CURRENT_HI slot-2.
    current_word = _word(lo=COMPRESSED_NOP, hi=0x2223)
    next_word = _word(lo=0x3333, hi=0x4444)
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(compressed_lo=True),
    )
    await _settle(dut)
    _assert_slot2(
        dut,
        raw=0x2223,
        effective=_word(lo=0x2223, hi=0x3333),
        compressed=False,
        sel_nop=False,
    )

    # B: native slot-1 at even -> NEXT_LO compressed slot-2.
    _clear_inputs(dut)
    current_word = 0x00B50533  # add a0,a0,a1
    next_word = _word(lo=COMPRESSED_NOP, hi=0x5555)
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(native_pairable_lo=True),
        next_sb=_sideband(compressed_lo=True),
    )
    await _settle(dut)
    _assert_slot2(
        dut,
        raw=COMPRESSED_NOP,
        effective=0x00000013,
        compressed=True,
        sel_nop=False,
    )
    _assert_slot2_btb_candidate_sizes(
        dut, plus2_compressed=False, plus4_compressed=True
    )

    # The same B qualifier also permits a native NEXT_LO, the +8 bundle.
    next_word = 0x00C585B3  # add a1,a1,a2
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(native_pairable_lo=True),
        next_sb=_sideband(),
    )
    await _settle(dut)
    _assert_slot2(
        dut,
        raw=next_word & 0xFFFF,
        effective=next_word,
        compressed=False,
        sel_nop=False,
    )
    _assert_slot2_btb_candidate_sizes(
        dut, plus2_compressed=False, plus4_compressed=False
    )

    # C: compressed slot-1 at odd -> NEXT_LO native slot-2.
    _clear_inputs(dut)
    current_word = _word(lo=0x1111, hi=COMPRESSED_NOP)
    next_word = 0x00C585B3  # add a1,a1,a2
    dut.i_pc_reg.value = PC_HI
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(compressed_hi=True),
        next_sb=_sideband(),
    )
    await _settle(dut)
    _assert_slot2(
        dut,
        raw=next_word & 0xFFFF,
        effective=next_word,
        compressed=False,
        sel_nop=False,
    )
    _assert_slot2_btb_candidate_sizes(
        dut, plus2_compressed=False, plus4_compressed=False
    )

    # D: native slot-1 at odd -> NEXT_HI compressed slot-2.  A native NEXT_HI
    # remains invalid because it would extend beyond the 64-bit fetch window.
    _clear_inputs(dut)
    current_word = _word(lo=0x1111, hi=0x0533)
    next_word = _word(lo=0x00B5, hi=COMPRESSED_NOP)
    dut.i_pc_reg.value = PC_HI
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(native_pairable_hi=True),
        next_sb=_sideband(compressed_hi=True),
    )
    await _settle(dut)
    _assert_slot2(
        dut,
        raw=COMPRESSED_NOP,
        effective=0x00000013,
        compressed=True,
        sel_nop=False,
    )
    _assert_slot2_btb_candidate_sizes(
        dut, plus2_compressed=False, plus4_compressed=True
    )

    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(native_pairable_hi=True),
        next_sb=_sideband(),
    )
    await _settle(dut)
    assert bool(dut.o_slot2_valid_for_pc.value) is False
    assert bool(dut.o_sel_nop_2.value) is True


@cocotb.test()
async def test_bank_swapped_fetch_realigns_current_word_and_sideband(dut: Any) -> None:
    """When fetch bank parity differs, slot-1 current word comes from upper fetch bits."""
    await _setup_test(dut)

    lower_word = _word(lo=0xAAAA, hi=0xBBBB)
    upper_word = _word(lo=COMPRESSED_NOP, hi=0xCCCC)
    dut.i_pc_reg.value = PC_LO
    dut.i_instr_bank_sel_r.value = 1
    dut.i_instr.value = _fetch(current_word=lower_word, next_word=upper_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(),
        next_sb=_sideband(
            compressed_lo=True,
            compressed_hi=True,
            rvc_source_hot_lo=0,
            rvc_source_hot_hi=4,
        ),
    )
    await _settle(dut)

    _assert_slot1(
        dut,
        raw=COMPRESSED_NOP,
        effective=upper_word,
        compressed=True,
        fast_compressed=True,
    )
    _assert_slot2(
        dut,
        raw=0xCCCC,
        # effective now carries the RVC expansion (C.SW 0xCCCC -> SW x11,28(x9))
        effective=0x00B4AE23,
        compressed=True,
        sel_nop=False,
    )
    assert int(dut.o_rvc_source_hot.value) == 0
    assert int(dut.o_source_hot_2.value) == 4


@cocotb.test()
async def test_buffer_selection_uses_buffer_word_and_sideband(dut: Any) -> None:
    """A compressed low-half predecessor makes high-half slot-1 use the buffer."""
    await _setup_test(dut)

    buffer_word = _word(lo=0x5555, hi=COMPRESSED_NOP)
    dut.i_pc_reg.value = PC_HI
    dut.i_prev_was_compressed_at_lo.value = 1
    dut.i_instr_buffer.value = buffer_word
    dut.i_instr_buffer_sideband.value = _sideband(
        compressed_hi=True,
        rvc_source_hot_hi=0,
    )
    await _settle(dut)

    _assert_slot1(
        dut,
        raw=COMPRESSED_NOP,
        effective=buffer_word,
        compressed=True,
        fast_compressed=True,
        use_buffer=True,
    )
    assert int(dut.o_rvc_source_hot.value) == 0


@cocotb.test()
async def test_prediction_buffer_at_low_pc_invalidates_slot2(dut: Any) -> None:
    """Prediction-buffer use at a low-half PC punts slot-2 as an unsupported shape."""
    await _setup_test(dut)

    buffer_word = _word(lo=COMPRESSED_NOP, hi=0x7777)
    dut.i_pc_reg.value = PC_LO
    dut.i_use_buffer_after_prediction.value = 1
    dut.i_instr_buffer.value = buffer_word
    dut.i_instr_buffer_sideband.value = _sideband(compressed_lo=True)
    await _settle(dut)

    _assert_slot1(
        dut,
        raw=COMPRESSED_NOP,
        effective=buffer_word,
        compressed=True,
        fast_compressed=True,
        use_buffer=True,
    )
    _assert_slot2(dut, raw=0, effective=0x00000013, compressed=False, sel_nop=True)


@cocotb.test()
async def test_saved_stall_values_drive_fast_compressed_path(dut: Any) -> None:
    """The fast compressed output can use saved stall metadata independent of sideband."""
    await _setup_test(dut)

    buffer_word = _word(lo=0x5555, hi=0x6666)
    dut.i_pc_reg.value = PC_HI
    dut.i_stall_registered.value = 1
    dut.i_saved_values_valid.value = 1
    dut.i_prev_was_compressed_at_lo_saved.value = 1
    dut.i_is_compressed_saved.value = 1
    dut.i_instr_buffer.value = buffer_word
    dut.i_instr_buffer_sideband.value = _sideband()
    await _settle(dut)

    _assert_slot1(
        dut,
        raw=0x6666,
        effective=buffer_word,
        compressed=False,
        fast_compressed=True,
        use_buffer=True,
    )


@cocotb.test()
async def test_nop_sources_suppress_slot1_and_slot2(dut: Any) -> None:
    """Mid-instruction and prediction holdoffs create slot-1/slot-2 NOP cycles."""
    await _setup_test(dut)

    for signal_name in (
        "i_mid_32bit_correction",
        "i_prediction_holdoff",
        "i_prediction_from_buffer_holdoff",
    ):
        _clear_inputs(dut)
        setattr(getattr(dut, signal_name), "value", 1)
        await _settle(dut)

        assert bool(dut.o_sel_nop.value) is True
        assert bool(dut.o_slot1_is_branch.value) is False
        assert bool(dut.o_sel_nop_2.value) is True


@cocotb.test()
async def test_slot1_branch_detection_handles_compressed_and_native(dut: Any) -> None:
    """Slot-1 branch detection covers compressed and native halfword starts."""
    await _setup_test(dut)

    current_word = _word(lo=COMPRESSED_J, hi=0x2222)
    dut.i_instr.value = _fetch(current_word=current_word, next_word=0)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(compressed_lo=True, compressed_control_lo=True),
    )
    await _settle(dut)

    assert bool(dut.o_slot1_is_branch.value) is True
    assert bool(dut.o_sel_nop_2.value) is True

    _clear_inputs(dut)
    current_word = _word(lo=0x1111, hi=OPC_JAL)
    dut.i_pc_reg.value = PC_HI
    dut.i_instr.value = _fetch(current_word=current_word, next_word=0)
    dut.i_instr_sideband.value = _fetch_sideband(current_sb=_sideband())
    await _settle(dut)

    assert bool(dut.o_is_compressed.value) is False
    assert bool(dut.o_slot1_is_branch.value) is True
    assert bool(dut.o_sel_nop_2.value) is True


@cocotb.test()
async def test_slot2_sideband_blocks_serialize_and_fp_compute_ops(dut: Any) -> None:
    """Native serialize and FP-compute sideband bits force slot-2 invalid."""
    await _setup_test(dut)

    for current_sb in (
        _sideband(compressed_lo=True, native_serialize_hi=True),
        _sideband(compressed_lo=True, native_fp_compute_hi=True),
    ):
        _clear_inputs(dut)
        dut.i_instr.value = _fetch(
            current_word=_word(lo=COMPRESSED_NOP, hi=OPC_BRANCH),
            next_word=0,
        )
        dut.i_instr_sideband.value = _fetch_sideband(current_sb=current_sb)
        await _settle(dut)

        assert bool(dut.o_is_compressed.value) is True
        assert bool(dut.o_is_compressed_2.value) is False
        assert bool(dut.o_sel_nop_2.value) is True


@cocotb.test()
async def test_bram_unsafe_swap_only_allows_current_hi_compressed_slot2(
    dut: Any,
) -> None:
    """In a swapped no-buffer cycle, only current-hi compressed slot-2 can fire."""
    await _setup_test(dut)

    lower_word = _word(lo=0xAAAA, hi=0xBBBB)
    upper_word = _word(lo=COMPRESSED_NOP, hi=0xCCCC)
    dut.i_pc_reg.value = PC_BANK1_LO
    dut.i_instr_bank_sel_r.value = 0
    dut.i_instr.value = _fetch(current_word=lower_word, next_word=upper_word)
    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(),
        next_sb=_sideband(
            compressed_lo=True,
            compressed_hi=True,
            rvc_source_hot_hi=4,
        ),
    )
    await _settle(dut)

    # effective carries the RVC expansion (C.SW 0xCCCC -> SW x11,28(x9))
    _assert_slot2(dut, raw=0xCCCC, effective=0x00B4AE23, compressed=True, sel_nop=False)

    dut.i_instr_sideband.value = _fetch_sideband(
        current_sb=_sideband(),
        next_sb=_sideband(compressed_lo=True),
    )
    await _settle(dut)

    _assert_slot2(
        dut,
        raw=0xCCCC,
        effective=_word(lo=0xCCCC, hi=0xAAAA),
        compressed=False,
        sel_nop=True,
    )


@cocotb.test()
async def test_high_parcel_rd_x2_predecode_follows_fetch_word_swap(dut: Any) -> None:
    """The C.ADDI16SP predicate remains paired with its word across a swap."""
    await _setup_test(dut)

    # C.ADDI16SP x2,x2,16.  Toggling bit 7 changes rd from x2 to x3,
    # making the otherwise-identical parcel C.LUI instead.
    c_addi16sp = (0b011 << 13) | (2 << 7) | (1 << 6) | 0b01
    c_lui_x3 = c_addi16sp ^ (1 << 7)
    word_with_x2 = _word(lo=COMPRESSED_NOP, hi=c_addi16sp)
    near_miss_word = _word(lo=0x0003, hi=c_lui_x3)

    for swapped in (False, True):
        _clear_inputs(dut)
        dut.i_pc_reg.value = PC_LO
        dut.i_instr_bank_sel_r.value = int(swapped)

        if swapped:
            # Physical {next,current} is reversed relative to the PC-aligned
            # words; the predicate bus must reverse with it.
            physical_current = near_miss_word
            physical_next = word_with_x2
            current_sb = _sideband(compressed_hi=True, rvc_source_hot_hi=1)
            next_sb = _sideband(
                compressed_lo=True,
                compressed_hi=True,
                rvc_source_hot_hi=1,
            )
        else:
            physical_current = word_with_x2
            physical_next = near_miss_word
            current_sb = _sideband(
                compressed_lo=True,
                compressed_hi=True,
                rvc_source_hot_hi=1,
            )
            next_sb = _sideband(compressed_hi=True, rvc_source_hot_hi=1)

        dut.i_instr_hi_rd_is_x2.value = _fetch_hi_rd_is_x2(
            current_word=physical_current,
            next_word=physical_next,
        )
        dut.i_instr.value = _fetch(
            current_word=physical_current,
            next_word=physical_next,
        )
        dut.i_instr_sideband.value = _fetch_sideband(
            current_sb=current_sb,
            next_sb=next_sb,
        )
        await _settle(dut)

        assert int(dut.i_instr_hi_rd_is_x2.value) == (0b10 if swapped else 0b01)
        assert bool(dut.fetch_word_swapped_slot2.value) is swapped
        assert bool(dut.aligned_current_hi_rd_is_x2.value) is True
        assert bool(dut.aligned_next_hi_rd_is_x2.value) is False
        _assert_slot2(
            dut,
            raw=c_addi16sp,
            effective=0x01010113,  # addi x2,x2,16
            compressed=True,
            sel_nop=False,
        )


@cocotb.test()
async def test_next_high_rd_x2_predecode_follows_fetch_word_swap(dut: Any) -> None:
    """The NEXT_HI C.ADDI16SP candidate receives the aligned predicate."""
    await _setup_test(dut)

    c_addi16sp = (0b011 << 13) | (2 << 7) | (1 << 6) | 0b01
    logical_current = _word(lo=0x1111, hi=0x0533)
    logical_next = _word(lo=0x00B5, hi=c_addi16sp)
    logical_current_sb = _sideband(native_pairable_hi=True)
    logical_next_sb = _sideband(
        compressed_lo=True,
        compressed_hi=True,
        rvc_source_hot_hi=1,
    )

    for swapped in (False, True):
        _clear_inputs(dut)
        dut.i_pc_reg.value = PC_HI
        dut.i_instr_bank_sel_r.value = int(swapped)

        if swapped:
            physical_current, physical_next = logical_next, logical_current
            current_sb, next_sb = logical_next_sb, logical_current_sb
        else:
            physical_current, physical_next = logical_current, logical_next
            current_sb, next_sb = logical_current_sb, logical_next_sb

        dut.i_instr_hi_rd_is_x2.value = _fetch_hi_rd_is_x2(
            current_word=physical_current,
            next_word=physical_next,
        )
        dut.i_instr.value = _fetch(
            current_word=physical_current,
            next_word=physical_next,
        )
        dut.i_instr_sideband.value = _fetch_sideband(
            current_sb=current_sb,
            next_sb=next_sb,
        )
        await _settle(dut)

        assert int(dut.i_instr_hi_rd_is_x2.value) == (0b01 if swapped else 0b10)
        assert bool(dut.fetch_word_swapped_slot2.value) is swapped
        assert bool(dut.aligned_current_hi_rd_is_x2.value) is False
        assert bool(dut.aligned_next_hi_rd_is_x2.value) is True
        _assert_slot2(
            dut,
            raw=c_addi16sp,
            effective=0x01010113,  # addi x2,x2,16
            compressed=True,
            # NEXT_HI is deliberately suppressed in the transient no-buffer
            # swapped state, but its fixed candidate must still be correct.
            sel_nop=swapped,
        )

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

"""Integration tests for the IF-stage top level."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from config import XLEN


CLOCK_PERIOD_NS = 10
RAS_PTR_BITS = 3
BP_DIR_IDX_BITS = 10
NOP_INSTR = 0x00000013
CALL_RA_INSTR = 0x000000EF
RETURN_RA_INSTR = 0x00008067
ADD_INSTR_A = 0x00B50533
ADD_INSTR_B = 0x00C585B3
ADD_INSTR_C = 0x00D60633
COMPRESSED_NOP = 0x0001
COMPRESSED_HINT = 0x2221
# Quadrant-1/funct3=001 is C.ADDIW x4, x4, 8.
COMPRESSED_HINT_EXPANDED = 0x0082021B
BASE_PC = 0x80001000
BRANCH_TARGET = 0x80002000
FENCE_TARGET = 0x80003000

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

PIPELINE_CTRL_FIELDS = [
    ("reset", 1),
    ("stall", 1),
    ("stall_registered", 1),
    ("stall_for_trap_check", 1),
    ("flush", 1),
    ("trap_taken_registered", 1),
    ("mret_taken_registered", 1),
]

FROM_EX_FIELDS = [
    ("branch_taken", 1),
    ("branch_target_address", XLEN),
    ("btb_update", 1),
    ("btb_update_pc", XLEN),
    ("btb_update_target", XLEN),
    ("btb_update_taken", 1),
    ("btb_update_compressed", 1),
    ("btb_update_requires_pc_reg_handoff", 1),
    ("ras_misprediction", 1),
    ("ras_restore_tos", RAS_PTR_BITS),
    ("ras_restore_valid_count", RAS_PTR_BITS + 1),
    ("ras_pop_after_restore", 1),
    ("ras_push_after_restore", 1),
    ("ras_push_address_after_restore", XLEN),
]

TRAP_CTRL_FIELDS = [
    ("trap_taken", 1),
    ("mret_taken", 1),
    ("trap_target", XLEN),
]

IF_TO_PD_FIELDS = [
    ("program_counter", XLEN),
    ("raw_parcel", 16),
    ("sel_nop", 1),
    ("sel_compressed", 1),
    ("effective_instr", 32),
    ("source_hot_predecoded", 3),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_predicted", 1),
    ("ras_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("bp_dir_taken", 1),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
    ("fetch_fault", 1),
    ("fetch_fault_page", 1),
    ("fetch_fault_hi", 1),
    ("decomp_illegal", 1),
]


def _pack_struct(
    fields: list[tuple[str, int]],
    values: Mapping[str, int | bool],
) -> int:
    """Pack a SystemVerilog packed struct from declaration-ordered fields."""
    packed = 0
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = int(values.get(name, 0))
        packed |= (raw & ((1 << width) - 1)) << offset
    return packed


def _unpack_struct(fields: list[tuple[str, int]], packed: int) -> dict[str, Any]:
    """Unpack a SystemVerilog packed struct into named Python values."""
    result: dict[str, Any] = {}
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = (packed >> offset) & ((1 << width) - 1)
        result[name] = bool(raw) if width == 1 else raw
    return result


def _word(*, lo: int, hi: int) -> int:
    """Pack two 16-bit parcels into one instruction word."""
    return ((hi & 0xFFFF) << 16) | (lo & 0xFFFF)


def _fetch(*, current_word: int, next_word: int) -> int:
    """Pack the 64-bit instruction fetch bus as {next_word, current_word}."""
    return ((next_word & 0xFFFFFFFF) << 32) | (current_word & 0xFFFFFFFF)


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


def _pc_metadata(*, current_sb: int = 0, next_sb: int = 0) -> int:
    """Pack the PC-only metadata window as {next[3:0], current[3:0]}."""

    def word_metadata(sideband: int) -> int:
        return (
            (((sideband >> SB_PAIRABLE_NATIVE_HI) & 1) << 3)
            | (((sideband >> SB_PAIRABLE_COMPRESSED_HI) & 1) << 2)
            | (sideband & 0b11)
        )

    return (word_metadata(next_sb) << 4) | word_metadata(current_sb)


def _source_hot(instruction: int) -> int:
    """Return packed {rs2[1], rs1[2:1]} from a 32-bit instruction."""
    return (((instruction >> 21) & 1) << 2) | ((instruction >> 16) & 0x3)


def _pack_pipeline_ctrl(fields: Mapping[str, int | bool]) -> int:
    """Pack a pipeline_ctrl_t value."""
    return _pack_struct(PIPELINE_CTRL_FIELDS, fields)


def _pack_from_ex(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_ex_comb_t value."""
    return _pack_struct(FROM_EX_FIELDS, fields)


def _pack_trap_ctrl(fields: Mapping[str, int | bool]) -> int:
    """Pack a trap_ctrl_t value."""
    return _pack_struct(TRAP_CTRL_FIELDS, fields)


def _drive_pipeline_ctrl(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive packed pipeline control inputs."""
    dut.i_pipeline_ctrl.value = _pack_pipeline_ctrl(fields)


def _drive_from_ex(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive packed EX feedback and its matching lower-priority RMW sideband."""
    dut.i_from_ex_comb.value = _pack_from_ex(fields)
    dut.i_btb_late_update_pc.value = int(fields.get("btb_update_pc", 0))
    dut.i_btb_late_update_taken.value = int(fields.get("btb_update_taken", 0))


def _drive_trap_ctrl(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive packed trap control inputs."""
    dut.i_trap_ctrl.value = _pack_trap_ctrl(fields)


def _drive_fetch(
    dut: Any,
    *,
    current_word: int,
    next_word: int = NOP_INSTR,
    current_sb: int = 0,
    next_sb: int = 0,
    bank_sel: int = 0,
    served_high: int = 0,
) -> None:
    """Drive instruction data, predecode sideband, and exact rd predicates."""
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(current_sb=current_sb, next_sb=next_sb)
    positional_metadata = _pc_metadata(current_sb=current_sb, next_sb=next_sb)
    dut.i_instr_pc_metadata.value = positional_metadata
    metadata_by_parity = (
        ((positional_metadata & 0xF) << 4) | (positional_metadata >> 4)
        if bank_sel
        else positional_metadata
    )
    positional_start_valid = (((next_sb >> SB_SLOT2_START_VALID_LO) & 1) << 1) | (
        (current_sb >> SB_SLOT2_START_VALID_LO) & 1
    )
    start_valid_by_parity = (
        ((positional_start_valid & 1) << 1) | (positional_start_valid >> 1)
        if bank_sel
        else positional_start_valid
    )
    current_pairability = (((current_sb >> SB_PAIRABLE_NATIVE_LO) & 1) << 1) | (
        (current_sb >> SB_EVEN_LOCAL_PAIR_VALID) & 1
    )
    next_pairability = (((next_sb >> SB_PAIRABLE_NATIVE_LO) & 1) << 1) | (
        (next_sb >> SB_EVEN_LOCAL_PAIR_VALID) & 1
    )
    positional_pairability = (next_pairability << 2) | current_pairability
    pairability_by_parity = (
        ((positional_pairability & 0x3) << 2) | (positional_pairability >> 2)
        if bank_sel
        else positional_pairability
    )
    dut.i_instr_pc_metadata_by_provider_parity.value = metadata_by_parity << (
        8 if served_high else 0
    )
    dut.i_pc_pairability_by_provider_parity.value = pairability_by_parity << (
        4 if served_high else 0
    )
    dut.i_slot2_start_valid_lo_by_provider_parity.value = start_valid_by_parity << (
        2 if served_high else 0
    )
    dut.i_instr_hi_rd_is_x2.value = int(((current_word >> 23) & 0x1F) == 2) | (
        int(((next_word >> 23) & 0x1F) == 2) << 1
    )
    dut.i_instr_bank_sel_r.value = bank_sel
    dut.i_served_high.value = served_high
    dut.i_instr_pc_metadata_served_high.value = served_high


def _read_if_packet(dut: Any, *, slot2: bool = False) -> dict[str, Any]:
    """Read and unpack one IF-to-PD output packet."""
    signal = dut.o_from_if_to_pd_2 if slot2 else dut.o_from_if_to_pd
    return _unpack_struct(IF_TO_PD_FIELDS, int(signal.value))


def _assert_packet(
    packet: Mapping[str, Any],
    *,
    pc: int,
    raw: int,
    effective: int,
    compressed: bool,
    nop: bool = False,
) -> None:
    """Assert the core instruction-selection fields of an IF-to-PD packet."""
    assert packet["program_counter"] == pc
    assert packet["raw_parcel"] == raw
    assert packet["sel_nop"] is nop
    assert packet["sel_compressed"] is compressed
    assert packet["effective_instr"] == effective


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


def _drive_served_word_tags(
    dut: Any, served_word: int, *, provider: str | None = None
) -> None:
    """Drive one or both provider-local S/S+1/S-1 tag sets."""
    phys_mask = (1 << 30) - 1
    served_word &= phys_mask
    providers = ("low", "high") if provider is None else (provider,)
    for lane in providers:
        getattr(dut, f"i_served_word_{lane}").value = served_word
        getattr(dut, f"i_served_last_word_{lane}").value = (served_word + 1) & phys_mask
        getattr(dut, f"i_served_prev_word_{lane}").value = (served_word - 1) & phys_mask
        getattr(dut, f"i_served_prev_word_valid_{lane}").value = int(served_word != 0)


def _clear_inputs(dut: Any) -> None:
    """Drive all IF-stage inputs to safe idle values."""
    _drive_from_ex(dut, {})
    dut.i_btb_early_update_active.value = 0
    dut.i_btb_early_update_pc.value = 0
    dut.i_btb_early_update_taken.value = 0
    dut.i_btb_late_update_pc.value = 0
    dut.i_btb_late_update_taken.value = 0
    dut.i_dir_update_valid.value = 0
    dut.i_dir_update_idx.value = 0
    dut.i_dir_update_taken.value = 0
    _drive_fetch(dut, current_word=NOP_INSTR, next_word=NOP_INSTR)
    dut.i_instr_valid.value = 1
    _drive_served_word_tags(dut, 0)
    # Phase 3 M5 fetch-translation seam: translation off, a clean served
    # window from the ready low-BRAM overlay model, no walker traffic.
    dut.i_instr_fault0.value = 0
    dut.i_instr_fault0_page.value = 0
    dut.i_instr_fault1.value = 0
    dut.i_instr_fault1_page.value = 0
    dut.i_served_high.value = 0
    dut.i_instr_pc_metadata_served_high.value = 0
    dut.i_fetch_translation_active.value = 0
    dut.i_fetch_priv_u.value = 0
    dut.i_tlb_invalidate.value = 0
    dut.i_walk_req_ready.value = 0
    dut.i_walk_resp_valid.value = 0
    dut.i_walk_resp.value = 0
    _drive_pipeline_ctrl(dut, {})
    _drive_trap_ctrl(dut, {})
    dut.i_frontend_state_flush.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_fence_i_target.value = 0
    dut.i_disable_branch_prediction.value = 1
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0


def _start_served_addr_tracker(dut: Any, *, word_offset: int = 0) -> None:
    """Model both providers' payload-aligned served-window tags.

    if_stage's served-window guard
    squashes the IF output and holds pc_reg whenever the served 64-bit fetch
    window does not cover pc_reg's word (S relative to P: delta 0, delta -1,
    or delta +1 gated on use_instr_buffer). The guard applies in both cached and low address
    regions, except that low-region saved-replay cycles are deliberately
    exempt; these directed tests use cached PCs (BASE_PC=0x80001000). Register
    S+1, S-1, and S!=0 exactly as every production provider does. pc_reg only
    changes on a clock edge, so refreshing once per edge keeps both provider
    tag sets aligned between reads.

    word_offset>0 deliberately leads the served window ahead of pc_reg (e.g. the
    F=W+1 case) to exercise the guard instead of suppressing it.
    """
    phys_mask = (1 << 30) - 1

    async def _tracker() -> None:
        while True:
            pc_word = (int(dut.pc_reg.value) & 0xFFFF_FFFF) >> 2
            _drive_served_word_tags(dut, (pc_word + word_offset) & phys_mask)
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="step")

    cocotb.start_soon(_tracker())


async def _setup_test(dut: Any, *, served_word_offset: int = 0) -> None:
    """Start the clock, reset the IF stage, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    _drive_pipeline_ctrl(dut, {"reset": True})
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    _drive_pipeline_ctrl(dut, {})
    _start_served_addr_tracker(dut, word_offset=served_word_offset)
    await _settle()


async def _redirect_to(dut: Any, target: int) -> None:
    """Redirect both IF PCs to a word-aligned target and consume the stale cycle."""
    _drive_from_ex(dut, {"branch_taken": True, "branch_target_address": target})
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == target

    _drive_from_ex(dut, {})
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == target + 4


@cocotb.test()
async def test_served_window_registered_last_tag_matches_old_guard(dut: Any) -> None:
    """Both provider-local fixed-depth guards match the 30-bit oracle.

    The serve view masks pc_reg to the 32-bit physical seam (Phase 3 M2),
    and providers tag windows in that 30-bit word space. S+1 wraps at the
    physical seam; the guarded S-1 arm rejects S=0 through prev_valid.
    """
    await _setup_test(dut)

    phys_mask = (1 << 30) - 1
    cases = [
        (0, 0),
        (1, 0),
        (0x3FF, 0x3FE),
        (0x400, 0x3FF),
        (0xFFFE, 0xFFFF),  # S=P+1 without carry at the 16-bit split
        (0xFFFF, 0x10000),  # S=P+1 carrying across the 16-bit split
        (0x10000, 0xFFFF),  # S=P-1 across the split, not S=P+1
        (0xFFFFF, 0xFFFFE),
        (0x100000, 0xFFFFF),
        (phys_mask - 1, phys_mask),  # highest S=P+1 inside the physical seam
        (phys_mask, phys_mask - 1),
        (phys_mask, 0),  # guarded S=P+1 wrap is rejected (S=0 has no predecessor)
        (0, phys_mask),  # S=P-1 wraps through the registered last-word tag
        (0x200FFFFF, 0x20100000),
        (0x20100000, 0x200FFFFF),
        (0x20100000, 0x20100002),
    ]

    for served_high, provider in ((0, "low"), (1, "high")):
        _drive_fetch(
            dut,
            current_word=NOP_INSTR,
            next_word=NOP_INSTR,
            served_high=served_high,
        )
        for pc_word, served_word in cases:
            dut.pc_controller_inst.o_pc_reg.value = (pc_word & phys_mask) << 2
            _drive_served_word_tags(dut, served_word, provider=provider)
            await Timer(1, unit="step")

            expected_same = served_word == pc_word
            expected_m1 = ((served_word + 1) & phys_mask) == pc_word
            expected_p1 = (
                served_word != 0 and ((served_word - 1) & phys_mask) == pc_word
            )
            expected_covers = (
                expected_same
                or expected_m1
                or (expected_p1 and bool(dut.use_instr_buffer.value))
            )
            context = f"provider={provider}, pc_word={pc_word:#x}, served_word={served_word:#x}"
            assert bool(dut.served_eq_pc_word.value) == expected_same, context
            assert bool(dut.served_last_eq_pc_word.value) == expected_m1, context
            assert bool(dut.served_eq_pc_word_p1.value) == expected_p1, context
            assert (
                bool(dut.served_window_covers_pc_reg.value) == expected_covers
            ), context


async def _train_btb(
    dut: Any,
    *,
    pc: int,
    target: int,
    compressed: bool = False,
    handoff: bool = False,
) -> None:
    """Install one taken BTB entry while prediction remains test-disabled."""
    _drive_from_ex(
        dut,
        {
            "btb_update": True,
            "btb_update_pc": pc,
            "btb_update_target": target,
            "btb_update_taken": True,
            "btb_update_compressed": compressed,
            "btb_update_requires_pc_reg_handoff": handoff,
        },
    )
    await _advance_cycle(dut)
    _drive_from_ex(dut, {})
    await _settle()


async def _push_ras_call(dut: Any, *, return_target: int) -> None:
    """Present one native call and wait for its pipelined RAS push."""
    bpc = dut.branch_prediction_controller_inst
    ras = bpc.ras_inst
    count_before = int(bpc.o_ras_checkpoint_valid_count.value)
    call_pc = return_target - 4

    await _redirect_to(dut, call_pc)
    assert int(dut.pc_reg.value) == call_pc

    _drive_fetch(
        dut,
        current_word=CALL_RA_INSTR,
        next_word=NOP_INSTR,
        bank_sel=(call_pc >> 2) & 1,
    )
    await _advance_cycle(dut)

    # IF pipelines the RAS detector and link address by one cycle.  The call
    # is now the controller input, and the following edge performs the push.
    assert ras.do_push.value
    assert int(bpc.i_link_address.value) == return_target
    _drive_fetch(
        dut,
        current_word=NOP_INSTR,
        next_word=NOP_INSTR,
        bank_sel=((call_pc + 4) >> 2) & 1,
    )
    await _advance_cycle(dut)

    assert int(bpc.o_ras_checkpoint_valid_count.value) == count_before + 1
    assert int(bpc.o_ras_predicted_target.value) == return_target


@cocotb.test()
async def test_self_targeting_ras_pop_keeps_registered_target_provenance(
    dut: Any,
) -> None:
    """A self-targeting RAS pop cannot retag metadata with the new stack top."""
    await _setup_test(dut)

    target_b = BASE_PC + 0x100
    target_a = BASE_PC + 0x200
    await _push_ras_call(dut, return_target=target_b)
    await _push_ras_call(dut, return_target=target_a)

    bpc = dut.branch_prediction_controller_inst
    ras = bpc.ras_inst
    assert int(bpc.o_ras_checkpoint_valid_count.value) == 2
    assert int(bpc.o_ras_predicted_target.value) == target_a

    # The redirect helper leaves the ordinary one-word fetch lead.  Present a
    # return for one cycle so its pipelined detector reaches BPC exactly when
    # the lookup PC is A and pc_reg is still A-4.
    await _redirect_to(dut, target_a - 8)
    assert int(dut.o_pc.value) == target_a - 4
    assert int(dut.pc_reg.value) == target_a - 8
    _drive_fetch(
        dut,
        current_word=RETURN_RA_INSTR,
        next_word=RETURN_RA_INSTR,
        bank_sel=((target_a - 8) >> 2) & 1,
    )
    await _advance_cycle(dut)

    assert int(dut.o_pc.value) == target_a
    assert int(dut.pc_reg.value) == target_a - 4
    _drive_fetch(
        dut,
        current_word=RETURN_RA_INSTR,
        next_word=RETURN_RA_INSTR,
        bank_sel=((target_a - 4) >> 2) & 1,
    )
    dut.i_disable_branch_prediction.value = 0
    await _settle()

    assert ras.do_pop.value
    assert bpc.o_ras_predicted.value
    assert bpc.o_prediction_used.value
    assert int(bpc.o_predicted_target.value) == target_a

    # The live RAS sideband is the architectural prediction marker on this
    # return packet.  The generic BTB metadata is registered on the consume
    # edge below for the following target/holdoff phase.
    return_packet = _read_if_packet(dut)
    _assert_packet(
        return_packet,
        pc=target_a - 4,
        raw=RETURN_RA_INSTR & 0xFFFF,
        effective=RETURN_RA_INSTR,
        compressed=False,
    )
    assert return_packet["ras_predicted"]
    assert return_packet["ras_predicted_target"] == target_a

    # Consume the self-targeting prediction.  This edge registers target A,
    # pops the stack to B, and makes both live PCs equal A.  The live target
    # dataplane therefore exposes B.  RAS prediction_holdoff intentionally
    # makes this stale-fetch cycle a NOP, but the target-provenance mux itself
    # must still prefer the live registered metadata over the newly exposed
    # stack top.  This is the real cross-module boundary changed by the split.
    await _advance_cycle(dut)
    _drive_fetch(
        dut,
        current_word=RETURN_RA_INSTR,
        next_word=RETURN_RA_INSTR,
        bank_sel=(target_a >> 2) & 1,
    )
    await _settle()

    assert int(dut.o_pc.value) == target_a
    assert int(dut.pc_reg.value) == target_a
    assert dut.lookup_pc_matches_packet_pc.value
    assert bpc.o_prediction_holdoff.value
    assert bpc.o_prediction_used_r.value
    assert int(bpc.o_predicted_target_r.value) == target_a
    assert int(bpc.o_ras_checkpoint_valid_count.value) == 1
    assert int(bpc.o_ras_predicted_target.value) == target_b
    assert int(bpc.o_predicted_target.value) == target_b
    assert not ras.do_pop.value

    packet = _read_if_packet(dut)
    assert packet["sel_nop"]
    assert not packet["btb_hit"]
    assert not packet["btb_predicted_taken"]
    assert packet["btb_predicted_target"] == target_a


@cocotb.test()
async def test_reset_holdoff_creates_initial_fetch_lead(dut: Any) -> None:
    """Reset clears PC, then the reset holdoff creates the initial one-word lead."""
    await _setup_test(dut)

    assert int(dut.o_pc.value) == 0
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]

    await _advance_cycle(dut)

    packet = _read_if_packet(dut)
    assert int(dut.o_pc.value) == 4
    _assert_packet(
        packet,
        pc=0,
        raw=NOP_INSTR & 0xFFFF,
        effective=NOP_INSTR,
        compressed=False,
    )


@cocotb.test()
async def test_disabled_prediction_32bit_fetch_packet_and_slot2_nop(
    dut: Any,
) -> None:
    """A plain 32-bit slot-1 fetch emits one packet and NOPs slot-2."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    _drive_fetch(dut, current_word=ADD_INSTR_A, next_word=ADD_INSTR_B)
    await _settle()

    packet = _read_if_packet(dut)
    _assert_packet(
        packet,
        pc=BASE_PC,
        raw=ADD_INSTR_A & 0xFFFF,
        effective=ADD_INSTR_A,
        compressed=False,
    )
    assert not packet["btb_hit"]
    assert not packet["btb_predicted_taken"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]


@cocotb.test()
async def test_compressed_pair_emits_two_valid_if_packets(dut: Any) -> None:
    """Two compressed parcels in one word produce valid slot-1 and slot-2 packets."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    current_word = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_HINT)
    _drive_fetch(
        dut,
        current_word=current_word,
        next_word=ADD_INSTR_A,
        current_sb=_sideband(
            compressed_lo=True,
            compressed_hi=True,
            rvc_source_hot_lo=3,
            rvc_source_hot_hi=5,
        ),
    )
    await _settle()

    packet1 = _read_if_packet(dut)
    _assert_packet(
        packet1,
        pc=BASE_PC,
        raw=COMPRESSED_NOP,
        effective=current_word,
        compressed=True,
    )
    assert packet1["source_hot_predecoded"] == 3

    packet2 = _read_if_packet(dut, slot2=True)
    _assert_packet(
        packet2,
        pc=BASE_PC + 2,
        raw=COMPRESSED_HINT,
        # Slot-2 carries the XLEN-specific RVC expansion: C.JAL on RV32,
        # C.ADDIW x4, x4, 8 on RV64.
        effective=COMPRESSED_HINT_EXPANDED,
        compressed=True,
    )
    assert packet2["source_hot_predecoded"] == 5
    assert not packet2["btb_hit"]
    assert not packet2["ras_predicted"]


@cocotb.test()
async def test_high_half_rvc_speculates_native_candidate_without_sideband_mux(
    dut: Any,
) -> None:
    """A high-half RVC packet may carry the sideband-free spanning candidate."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC + 2)

    current_word = _word(lo=0xBEEF, hi=COMPRESSED_NOP)
    next_word = _word(lo=0xCAFE, hi=0xD00D)
    _drive_fetch(
        dut,
        current_word=current_word,
        next_word=next_word,
        current_sb=_sideband(compressed_hi=True),
    )
    await _settle()

    packet = _read_if_packet(dut)
    _assert_packet(
        packet,
        pc=BASE_PC + 2,
        raw=COMPRESSED_NOP,
        # PD selects/decompresses raw for RVC. effective_instr is therefore a
        # don't-care and can carry the sideband-free 32-bit spanning candidate.
        effective=_word(lo=COMPRESSED_NOP, hi=0xCAFE),
        compressed=True,
    )


@cocotb.test()
async def test_slot2_collision_holdoff_stays_inside_stretched_redirect_bubble(
    dut: Any,
) -> None:
    """A slot-1/slot-2 BTB collision cannot escape a stretched slot-2 bubble."""
    slot1_pc = BASE_PC + 4
    slot1_target = FENCE_TARGET
    slot2_pc = BASE_PC + 2
    slot2_target = BRANCH_TARGET

    await _setup_test(dut)
    await _train_btb(
        dut,
        pc=slot1_pc,
        target=slot1_target,
        handoff=True,
    )
    await _train_btb(
        dut,
        pc=slot2_pc,
        target=slot2_target,
        compressed=True,
    )
    await _redirect_to(dut, BASE_PC)

    current_word = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_HINT)
    _drive_fetch(
        dut,
        current_word=current_word,
        next_word=ADD_INSTR_A,
        current_sb=_sideband(compressed_lo=True, compressed_hi=True),
    )
    dut.i_disable_branch_prediction.value = 0
    await _settle()

    bpc = dut.branch_prediction_controller_inst
    assert bpc.o_prediction_used.value
    assert bpc.o_slot2_prediction_used.value

    await _advance_cycle(dut)

    # Slot-2 wins both PC muxes immediately.  The younger slot-1 metadata and
    # handoff are gone, while its holdoff load is quarantined by the registered
    # stale-fetch bubble.
    assert int(dut.o_pc.value) == slot2_target
    assert int(dut.pc_reg.value) == slot2_target
    assert not bpc.o_prediction_used_r.value
    assert not bpc.o_sel_prediction_r.value
    assert bpc.o_prediction_holdoff.value
    assert bpc.o_btb_only_prediction_holdoff.value
    assert dut.slot2_redirect_q.value
    assert (
        dut.prediction_reset_c_ext.value
    ), "a consumed slot prediction must arm the registered C-state reset"
    assert dut.control_flow_holdoff.value
    assert dut.any_holdoff_safe.value, (
        "prediction reset must coincide with the registered holdoff that masks "
        "timing-cofactor size outputs"
    )
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]

    # Stretch the mandatory bubble first with a pipeline stall, then with a
    # fetch-invalid cycle.  No wrong-path packet or slot-1 handoff may reappear.
    _drive_pipeline_ctrl(dut, {"stall": True, "stall_registered": True})
    await _advance_cycle(dut)
    assert bpc.o_prediction_holdoff.value
    assert not bpc.o_prediction_used_r.value
    assert dut.slot2_redirect_q.value
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]

    _drive_pipeline_ctrl(dut, {})
    dut.i_instr_valid.value = 0
    await _advance_cycle(dut)
    assert bpc.o_prediction_holdoff.value
    assert not bpc.o_prediction_used_r.value
    assert dut.slot2_redirect_q.value
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]

    # On the first delivered target cycle, the registered bubble and both
    # holdoffs retire together.  This is the existing bubble, not an extra one.
    dut.i_instr_valid.value = 1
    _drive_fetch(dut, current_word=ADD_INSTR_B, next_word=ADD_INSTR_C)
    await _advance_cycle(dut)

    assert not bpc.o_prediction_holdoff.value
    assert not bpc.o_btb_only_prediction_holdoff.value
    assert not bpc.o_prediction_used_r.value
    assert not bpc.o_sel_prediction_r.value
    assert not dut.slot2_redirect_q.value
    _assert_packet(
        _read_if_packet(dut),
        pc=slot2_target,
        raw=ADD_INSTR_B & 0xFFFF,
        effective=ADD_INSTR_B,
        compressed=False,
    )


@cocotb.test()
async def test_stall_registered_replays_captured_if_packet(dut: Any) -> None:
    """Stall entry captures IF outputs and stall_registered replays them."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    _drive_fetch(dut, current_word=ADD_INSTR_A, next_word=ADD_INSTR_B)
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _settle()
    _assert_packet(
        _read_if_packet(dut),
        pc=BASE_PC,
        raw=ADD_INSTR_A & 0xFFFF,
        effective=ADD_INSTR_A,
        compressed=False,
    )
    assert _read_if_packet(dut)["source_hot_predecoded"] == _source_hot(ADD_INSTR_A)

    await _advance_cycle(dut)

    _drive_fetch(dut, current_word=ADD_INSTR_C, next_word=NOP_INSTR)
    _drive_pipeline_ctrl(dut, {"stall_registered": True})
    await _settle()

    packet = _read_if_packet(dut)
    _assert_packet(
        packet,
        pc=BASE_PC,
        raw=ADD_INSTR_A & 0xFFFF,
        effective=ADD_INSTR_A,
        compressed=False,
    )
    assert packet["source_hot_predecoded"] == _source_hot(ADD_INSTR_A)


@cocotb.test()
async def test_stall_registered_replays_compressed_source_hot_metadata(
    dut: Any,
) -> None:
    """Compressed slot metadata is captured with both packets at stall entry."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    # C.ADDI x3, 1 and C.ADDI x6, 2. Their exact decompressions carry
    # distinctive source-hot values (1 and 7), so replaying live replacement
    # data cannot accidentally satisfy this check.
    compressed_addi_x3_1 = 0x0185
    compressed_addi_x6_2 = 0x0309
    expanded_addi_x3_1 = 0x00118193
    expanded_addi_x6_2 = 0x00230313
    source_hot_1 = _source_hot(expanded_addi_x3_1)
    source_hot_2 = _source_hot(expanded_addi_x6_2)
    current_word = _word(lo=compressed_addi_x3_1, hi=compressed_addi_x6_2)

    _drive_fetch(
        dut,
        current_word=current_word,
        next_word=ADD_INSTR_A,
        current_sb=_sideband(
            compressed_lo=True,
            compressed_hi=True,
            rvc_source_hot_lo=source_hot_1,
            rvc_source_hot_hi=source_hot_2,
        ),
    )
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _settle()

    packet1 = _read_if_packet(dut)
    _assert_packet(
        packet1,
        pc=BASE_PC,
        raw=compressed_addi_x3_1,
        effective=current_word,
        compressed=True,
    )
    assert packet1["source_hot_predecoded"] == source_hot_1 == 1

    packet2 = _read_if_packet(dut, slot2=True)
    _assert_packet(
        packet2,
        pc=BASE_PC + 2,
        raw=compressed_addi_x6_2,
        effective=expanded_addi_x6_2,
        compressed=True,
    )
    assert packet2["source_hot_predecoded"] == source_hot_2 == 7

    await _advance_cycle(dut)

    # Replace every live input while the registered-stall replay arm is active.
    # Both source-hot values must remain aligned with the captured parcels.
    _drive_fetch(dut, current_word=ADD_INSTR_C, next_word=NOP_INSTR)
    _drive_pipeline_ctrl(dut, {"stall_registered": True})
    await _settle()

    packet1 = _read_if_packet(dut)
    _assert_packet(
        packet1,
        pc=BASE_PC,
        raw=compressed_addi_x3_1,
        effective=current_word,
        compressed=True,
    )
    assert packet1["source_hot_predecoded"] == source_hot_1

    packet2 = _read_if_packet(dut, slot2=True)
    _assert_packet(
        packet2,
        pc=BASE_PC + 2,
        raw=compressed_addi_x6_2,
        effective=expanded_addi_x6_2,
        compressed=True,
    )
    assert packet2["source_hot_predecoded"] == source_hot_2


@cocotb.test()
async def test_branch_redirect_generates_stale_fetch_bubble(dut: Any) -> None:
    """A landed EX recovery retargets both low and cached fetch providers."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)
    assert not dut.o_fetch_redirect.value
    assert not dut.o_fetch_cached_retarget.value

    _drive_from_ex(dut, {"branch_taken": True, "branch_target_address": BRANCH_TARGET})
    await _advance_cycle(dut)

    assert int(dut.o_pc.value) == BRANCH_TARGET
    assert dut.o_fetch_redirect.value
    assert dut.o_fetch_cached_retarget.value
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]

    _drive_from_ex(dut, {})
    _drive_fetch(dut, current_word=ADD_INSTR_B, next_word=ADD_INSTR_C)
    await _advance_cycle(dut)

    assert int(dut.o_pc.value) == BRANCH_TARGET + 4
    assert not dut.o_fetch_redirect.value
    assert not dut.o_fetch_cached_retarget.value
    packet = _read_if_packet(dut)
    _assert_packet(
        packet,
        pc=BRANCH_TARGET,
        raw=ADD_INSTR_B & 0xFFFF,
        effective=ADD_INSTR_B,
        compressed=False,
    )

    # A visible target does not cancel the provider request until the PC flop
    # can actually land it.
    held_pc = int(dut.o_pc.value)
    _drive_pipeline_ctrl(dut, {"stall": True})
    _drive_from_ex(dut, {"branch_taken": True, "branch_target_address": BASE_PC})
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == held_pc
    assert not dut.o_fetch_redirect.value
    assert not dut.o_fetch_cached_retarget.value


@cocotb.test()
async def test_trap_redirect_pulses_low_and_cached_provider_retargets(
    dut: Any,
) -> None:
    """A trap changes both control flow and the cached provider's PA epoch."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    _drive_trap_ctrl(dut, {"trap_taken": True, "trap_target": FENCE_TARGET})
    await _advance_cycle(dut)

    assert int(dut.o_pc.value) == FENCE_TARGET
    assert dut.o_fetch_redirect.value
    assert dut.o_fetch_cached_retarget.value

    _drive_trap_ctrl(dut, {})
    await _advance_cycle(dut)
    assert not dut.o_fetch_redirect.value
    assert not dut.o_fetch_cached_retarget.value


@cocotb.test()
async def test_leading_slot1_prediction_keeps_cached_branch_ask_owed(
    dut: Any,
) -> None:
    """A normal lookahead prediction must not explicitly retarget the cache."""
    await _setup_test(dut)

    branch_pc = BASE_PC + 4
    target = BASE_PC + 0x1000
    await _train_btb(
        dut,
        pc=branch_pc,
        target=target,
        compressed=False,
        handoff=True,
    )
    await _redirect_to(dut, BASE_PC)

    # Fixed-latency operation looks up branch_pc one request ahead while IF is
    # still presenting BASE_PC. The cached provider must retain branch_pc as
    # its owed ask after fetch moves to target; its own accepted-PC movement
    # classifier provides that distinction.
    _drive_fetch(dut, current_word=ADD_INSTR_A, next_word=ADD_INSTR_B)
    dut.i_disable_branch_prediction.value = 0
    await _settle()
    assert int(dut.o_pc.value) == branch_pc
    assert int(dut.pc_reg.value) == BASE_PC
    assert dut.branch_prediction_controller_inst.o_prediction_used.value
    assert not dut.live_prediction_emits_with_output.value

    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == target
    assert dut.o_fetch_redirect.value
    assert not dut.o_fetch_cached_retarget.value


@cocotb.test()
async def test_native_slot1_uses_plus4_candidate_for_slot2_btb_redirect(
    dut: Any,
) -> None:
    """A native-led pair selects and consumes only the valid +4 BTB replica."""
    slot2_pc = BASE_PC + 4
    slot2_target = BRANCH_TARGET

    await _setup_test(dut)
    await _train_btb(dut, pc=slot2_pc, target=slot2_target)
    await _redirect_to(dut, BASE_PC)

    _drive_fetch(
        dut,
        current_word=ADD_INSTR_A,
        next_word=ADD_INSTR_B,
        current_sb=_sideband(native_pairable_lo=True),
        next_sb=_sideband(),
    )
    dut.i_disable_branch_prediction.value = 0
    await _settle()

    bpc = dut.branch_prediction_controller_inst
    assert not dut.slot2_plus2_candidate_valid.value
    assert dut.slot2_plus4_candidate_valid.value
    assert bpc.o_slot2_btb_hit.value
    assert bpc.o_slot2_prediction_used.value
    assert int(bpc.o_slot2_predicted_target.value) == slot2_target

    packet2 = _read_if_packet(dut, slot2=True)
    assert packet2["program_counter"] == slot2_pc
    assert packet2["btb_hit"]
    assert packet2["btb_predicted_taken"]
    assert packet2["btb_predicted_target"] == slot2_target

    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == slot2_target
    assert int(dut.pc_reg.value) == slot2_target
    assert dut.o_fetch_redirect.value
    assert dut.o_fetch_cached_retarget.value


async def _present_rt2_successor_slot2_candidate(dut: Any) -> tuple[int, int, int]:
    """Create the natural A-to-A+4 phase that selects the rotated T2 image."""
    successor_base = BASE_PC + 8
    slot2_pc = successor_base + 2
    slot2_target = BRANCH_TARGET

    await _train_btb(
        dut,
        pc=slot2_pc,
        target=slot2_target,
        compressed=True,
    )
    await _redirect_to(dut, BASE_PC)

    # Consuming two native instructions advances pc_reg by eight bytes, while
    # the live fetch request is only one word ahead. The BTB read launched here
    # therefore uses A=BASE_PC+4, and the next served base is B=A+4. Only the
    # rotated T2 image can supply B's +2 entry from that request index.
    early_lookup_base = int(dut.o_pc.value)
    assert early_lookup_base == BASE_PC + 4
    _drive_fetch(
        dut,
        current_word=ADD_INSTR_A,
        next_word=ADD_INSTR_B,
        current_sb=_sideband(native_pairable_lo=True),
        next_sb=_sideband(),
    )
    await _advance_cycle(dut)

    assert int(dut.pc_reg.value) == successor_base
    assert successor_base == early_lookup_base + 4

    current_word = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_HINT)
    _drive_fetch(
        dut,
        current_word=current_word,
        next_word=ADD_INSTR_C,
        current_sb=_sideband(compressed_lo=True, compressed_hi=True),
    )
    await _settle()

    return successor_base, slot2_pc, slot2_target


@cocotb.test()
async def test_slot2_rt2_successor_lookup_redirects(dut: Any) -> None:
    """A natural successor-word response redirects through the rotated T2 image."""
    await _setup_test(dut)
    _, slot2_pc, slot2_target = await _present_rt2_successor_slot2_candidate(dut)

    dut.i_disable_branch_prediction.value = 0
    await _settle()

    bpc = dut.branch_prediction_controller_inst
    assert dut.slot2_plus2_candidate_valid.value
    assert not dut.slot2_plus4_candidate_valid.value
    assert bpc.o_slot2_btb_hit.value
    assert bpc.o_slot2_prediction_used.value
    assert bpc.o_slot2_prediction_used_for_pc.value
    assert int(bpc.o_slot2_predicted_target.value) == slot2_target

    packet2 = _read_if_packet(dut, slot2=True)
    assert packet2["program_counter"] == slot2_pc
    assert packet2["btb_hit"]
    assert packet2["btb_predicted_taken"]
    assert packet2["btb_predicted_target"] == slot2_target

    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == slot2_target
    assert int(dut.pc_reg.value) == slot2_target


@cocotb.test()
async def test_slot2_rt2_successor_lookup_stall_replay_is_safe(dut: Any) -> None:
    """A stalled RT2 result is captured without consuming a stale redirect."""
    await _setup_test(dut)
    (
        successor_base,
        slot2_pc,
        slot2_target,
    ) = await _present_rt2_successor_slot2_candidate(dut)

    # The first stall cycle still exposes the RT2 result to the stall-ungated
    # PC selector, but it must not consume the redirect or stamp taken metadata.
    _drive_pipeline_ctrl(dut, {"stall": True})
    dut.i_disable_branch_prediction.value = 0
    await _settle()

    bpc = dut.branch_prediction_controller_inst
    assert dut.slot2_plus2_candidate_valid.value
    assert not dut.slot2_plus4_candidate_valid.value
    assert bpc.o_slot2_btb_hit.value
    assert bpc.o_slot2_prediction_used_for_pc.value
    assert not bpc.o_slot2_prediction_used.value
    assert int(bpc.o_slot2_predicted_target.value) == slot2_target

    packet2 = _read_if_packet(dut, slot2=True)
    assert packet2["program_counter"] == slot2_pc
    assert packet2["btb_hit"]
    assert not packet2["btb_predicted_taken"]
    assert packet2["btb_predicted_target"] == slot2_target

    await _advance_cycle(dut)
    assert int(dut.o_pc.value) != slot2_target
    assert int(dut.pc_reg.value) == successor_base

    # Registered-stall replay preserves the packet captured above and blocks a
    # fresh prediction; the unconsumed RT2 result cannot escape as stale taken
    # metadata while the saved packet is presented.
    _drive_pipeline_ctrl(dut, {"stall_registered": True})
    await _settle()

    replay2 = _read_if_packet(dut, slot2=True)
    assert replay2["program_counter"] == slot2_pc
    assert replay2["btb_hit"]
    assert not replay2["btb_predicted_taken"]
    assert replay2["btb_predicted_target"] == slot2_target
    assert not bpc.o_slot2_prediction_used_for_pc.value
    assert not bpc.o_slot2_prediction_used.value


@cocotb.test()
async def test_fence_i_redirect_uses_target_and_bubbles_fetch(dut: Any) -> None:
    """FENCE-class redirect masks a bad served window and stale response."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    dut.i_fence_i_flush.value = 1
    dut.i_frontend_state_flush.value = 1
    dut.i_fence_i_target.value = FENCE_TARGET
    pc_reg_word = int(dut.pc_reg.value) >> 2
    _drive_served_word_tags(dut, pc_reg_word + 8, provider="low")
    await _settle()

    # Keep the comparator's raw mismatch sensitized while proving the
    # FENCE-class event makes every downstream coverage decision irrelevant.
    assert dut.window_cannot_serve_pc_reg.value
    assert dut.sel_nop_existing.value
    assert dut.sel_nop_existing_wcs0.value
    assert dut.sel_nop_existing_wcs.value
    assert not dut.window_resteer_pc_reg.value
    assert not dut.pc_controller_inst.pending_prediction_effective.value
    assert not dut.pc_controller_inst.pending_imm_pred_emit.value
    assert not dut.pc_controller_inst.hold_pending_prediction_fetch.value
    assert not dut.pc_controller_inst.hold_pending_prediction_fetch_pc_mux.value
    assert not dut.branch_prediction_controller_inst.o_prediction_used_for_pc.value
    assert (
        not dut.branch_prediction_controller_inst.o_slot2_prediction_used_for_pc.value
    )
    assert int(dut.pc_controller_inst.o_next_pc.value) == FENCE_TARGET
    await _advance_cycle(dut)

    assert int(dut.o_pc.value) == FENCE_TARGET
    assert dut.o_fetch_redirect.value
    assert dut.o_fetch_cached_retarget.value
    _drive_served_word_tags(dut, (FENCE_TARGET >> 2) + 8, provider="low")
    await _settle()
    assert dut.window_cannot_serve_pc_reg.value
    assert not dut.window_resteer_pc_reg.value
    assert int(dut.pc_controller_inst.o_next_pc.value) == FENCE_TARGET
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]

    # The deasserting register transition remains fully timed. Exercise its
    # functional post-pulse cycle too: the dedicated registered FENCE holdoff
    # must keep a still-bad served window from resteering or dispatching.
    dut.i_fence_i_flush.value = 0
    dut.i_frontend_state_flush.value = 0
    _drive_served_word_tags(dut, (FENCE_TARGET >> 2) + 8, provider="low")
    await _settle()
    assert dut.window_cannot_serve_pc_reg.value
    assert dut.control_flow_holdoff.value
    assert dut.sel_nop_existing.value
    assert dut.sel_nop_existing_wcs0.value
    assert dut.sel_nop_existing_wcs.value
    assert not dut.window_resteer_pc_reg.value
    assert not dut.pc_controller_inst.pending_prediction_effective.value
    assert not dut.pc_controller_inst.pending_imm_pred_emit.value
    assert not dut.branch_prediction_controller_inst.o_prediction_used_for_pc.value
    assert (
        not dut.branch_prediction_controller_inst.o_slot2_prediction_used_for_pc.value
    )
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]
    await _advance_cycle(dut)


@cocotb.test()
async def test_no_lead_prediction_keeps_first_delayed_target_response_as_bubble(
    dut: Any,
) -> None:
    """A prediction on an already-emitted packet cannot duplicate its target.

    A variable-latency fetch can collapse the usual one-window lead so the BTB
    lookup PC and the instruction PC are equal.  The predicted branch then
    emits on the redirect cycle itself.  If the target response is delayed,
    prediction_holdoff must not exempt that response from the registered
    control-flow bubble while pc_reg is still held on the target; doing so
    presents the same target packet again after the served-window resteer.
    """
    await _setup_test(dut)

    branch_pc = BASE_PC + 0x40
    target = BASE_PC + 0x82
    branch_word = _word(lo=0xFA6D, hi=COMPRESSED_NOP)  # C.BNEZ, then C.NOP
    branch_sb = _sideband(
        compressed_lo=True,
        compressed_hi=True,
        compressed_control_lo=True,
    )

    await _train_btb(
        dut,
        pc=branch_pc,
        target=target,
        compressed=True,
        handoff=True,
    )
    await _redirect_to(dut, branch_pc)

    # Reproduce the variable-latency no-lead state through the architectural
    # served-window guard: a one-cycle bad tag resteers fetch back onto pc_reg.
    # The background tag tracker restores a covering tag after this edge.
    _drive_fetch(
        dut,
        current_word=branch_word,
        current_sb=branch_sb,
        bank_sel=(branch_pc >> 2) & 1,
    )
    _drive_served_word_tags(dut, (branch_pc >> 2) + 8, provider="low")
    await _settle()
    assert dut.window_resteer_pc_reg.value
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == branch_pc
    assert int(dut.pc_reg.value) == branch_pc
    assert dut.o_fetch_cached_retarget.value

    # The BTB prediction consumes while the same packet is already visible at
    # IF.  This is the distinction the held override must remember.
    dut.i_disable_branch_prediction.value = 0
    _drive_fetch(
        dut,
        current_word=branch_word,
        current_sb=branch_sb,
        bank_sel=(branch_pc >> 2) & 1,
    )
    _drive_served_word_tags(dut, branch_pc >> 2, provider="low")
    await _settle()
    bpc = dut.branch_prediction_controller_inst
    assert bpc.o_prediction_used.value
    branch_packet = _read_if_packet(dut)
    assert not branch_packet["sel_nop"]
    assert branch_packet["program_counter"] == branch_pc
    assert branch_packet["btb_hit"]
    assert branch_packet["btb_predicted_taken"]
    assert branch_packet["btb_predicted_target"] == target
    assert branch_packet["bp_dir_idx"] == (
        (branch_pc >> 1) & ((1 << BP_DIR_IDX_BITS) - 1)
    )
    await _advance_cycle(dut)

    assert dut.prediction_already_emitted_q.value
    assert dut.o_fetch_cached_retarget.value
    assert int(dut.o_pc.value) == target
    assert not dut.pc_controller_inst.pending_prediction_valid.value

    # Even an immediately ready target must be the lead-restoring bubble. The
    # registered pc_reg handoff has not landed yet, so consuming or capturing
    # these target bytes would tag them with the branch's sequential PC.
    _drive_fetch(
        dut,
        current_word=ADD_INSTR_A,
        next_word=ADD_INSTR_B,
        bank_sel=(target >> 2) & 1,
    )
    _drive_served_word_tags(dut, target >> 2, provider="low")
    await _settle()
    assert dut.control_flow_holdoff.value
    assert bpc.o_prediction_holdoff.value
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]
    assert not dut.window_resteer_pc_reg.value
    assert not dut.o_fetch_live_claim.value

    # Stretch the target handoff through two no-response cycles, as the slow
    # metadata fallback does while rebuilding its registered predicates.
    dut.i_instr_valid.value = 0
    for _ in range(2):
        await _advance_cycle(dut)
        assert dut.prediction_already_emitted_q.value

    # The first delayed target response consumes the lead-restoring holdoff.
    # It must remain a bubble even though prediction_holdoff is still live.
    # The registered target handoff now lands naturally on this response; an
    # already-emitted branch must never have armed pending state merely because
    # the target is halfword-aligned.
    dut.i_instr_valid.value = 1
    _drive_fetch(
        dut,
        current_word=ADD_INSTR_A,
        next_word=ADD_INSTR_B,
        bank_sel=(target >> 2) & 1,
    )
    _drive_served_word_tags(dut, target >> 2, provider="low")
    await _settle()
    assert int(dut.pc_reg.value) != target
    assert not dut.pc_controller_inst.pending_prediction_valid.value
    assert bpc.o_prediction_holdoff.value
    assert dut.control_flow_holdoff.value
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]

    await _advance_cycle(dut)
    assert int(dut.pc_reg.value) == target
    assert not dut.pc_controller_inst.pending_prediction_valid.value
    assert not dut.prediction_already_emitted_q.value


@cocotb.test()
async def test_no_lead_btb_miss_uses_and_replays_live_direction_metadata(
    dut: Any,
) -> None:
    """Collapsed-lead packets carry their own bimodal result and index."""
    await _setup_test(dut)

    branch_pc = BASE_PC + 0x40
    branch_idx = (branch_pc >> 1) & ((1 << BP_DIR_IDX_BITS) - 1)
    next_idx = ((branch_pc + 4) >> 1) & ((1 << BP_DIR_IDX_BITS) - 1)
    branch_word = _word(lo=0xFA6D, hi=COMPRESSED_NOP)  # C.BNEZ, then C.NOP
    branch_sb = _sideband(
        compressed_lo=True,
        compressed_hi=True,
        compressed_control_lo=True,
    )

    # Train only this direction entry into taken; leave the BTB empty so the
    # packet's direction metadata is what can later trigger the PD redirect.
    dut.i_dir_update_idx.value = branch_idx
    dut.i_dir_update_taken.value = 1
    dut.i_dir_update_valid.value = 1
    await _advance_cycle(dut)
    await _advance_cycle(dut)
    dut.i_dir_update_valid.value = 0

    await _redirect_to(dut, branch_pc)
    _drive_fetch(
        dut,
        current_word=branch_word,
        current_sb=branch_sb,
        bank_sel=(branch_pc >> 2) & 1,
    )
    _drive_served_word_tags(dut, (branch_pc >> 2) + 8, provider="low")
    await _settle()
    assert dut.window_resteer_pc_reg.value
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == branch_pc
    assert int(dut.pc_reg.value) == branch_pc

    _drive_served_word_tags(dut, branch_pc >> 2, provider="low")
    dut.i_disable_branch_prediction.value = 0
    await _settle()
    bpc = dut.branch_prediction_controller_inst
    assert not bpc.o_dir_predicted_taken.value
    assert int(bpc.o_dir_idx.value) == next_idx
    assert bpc.o_dir_predicted_taken_live.value
    assert int(bpc.o_dir_idx_live.value) == branch_idx

    packet = _read_if_packet(dut)
    assert not packet["sel_nop"]
    assert not packet["btb_hit"]
    assert not packet["btb_predicted_taken"]
    assert packet["bp_dir_taken"]
    assert packet["bp_dir_idx"] == branch_idx
    assert dut.o_fetch_live_claim.value

    # A first-cycle backend stall captures the same aligned values; the
    # registered release cycle must replay them rather than the stale lookup.
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _settle()
    packet = _read_if_packet(dut)
    assert packet["bp_dir_taken"]
    assert packet["bp_dir_idx"] == branch_idx
    assert dut.o_fetch_live_claim.value
    await _advance_cycle(dut)

    _drive_pipeline_ctrl(dut, {"stall_registered": True})
    await _settle()
    assert dut.replay_saved_if_outputs.value
    packet = _read_if_packet(dut)
    assert packet["bp_dir_taken"]
    assert packet["bp_dir_idx"] == branch_idx
    assert not dut.o_fetch_live_claim.value

    # direction_predictor's table intentionally survives reset, so restore the
    # shared simulator entry for tests that run after this one.
    _drive_pipeline_ctrl(dut, {})
    dut.i_dir_update_idx.value = branch_idx
    dut.i_dir_update_taken.value = 0
    dut.i_dir_update_valid.value = 1
    await _advance_cycle(dut)
    await _advance_cycle(dut)
    dut.i_dir_update_valid.value = 0


@cocotb.test()
async def test_pd_redirect_with_stall_kills_registered_prediction_handoff(
    dut: Any,
) -> None:
    """A PD+BTB collision must kill the pc_reg handoff even across a stall.

    Repro of the layout-sensitive CoreMark-PRO failures (cjpeg illegal
    instruction / linear_alg hang): a BTB hit arms the registered slot-1
    prediction handoff (o_sel_prediction_r / o_predicted_target_r) in the same
    cycle a PD redirect steals the PC stream.  pc_controller suppresses the
    handoff with a one-cycle redirect_kill pulse, but a stall starting in that
    cycle outlives the pulse while the handoff register is stall-held.  On
    release, the dead prediction's target is applied to pc_reg while fetch
    continues on the PD-redirect path, desyncing pc_reg from the fetched
    bytes (stale words are then served under wrong PCs).
    """
    await _setup_test(dut)
    dut.i_disable_branch_prediction.value = 0

    branch_pc = BASE_PC + 8
    stale_pred_target = 0x80005000
    pd_target = 0x80006000

    # Train the BTB: taken branch at branch_pc needing the pc_reg handoff.
    _drive_from_ex(
        dut,
        {
            "btb_update": True,
            "btb_update_pc": branch_pc,
            "btb_update_target": stale_pred_target,
            "btb_update_taken": True,
            "btb_update_compressed": False,
            "btb_update_requires_pc_reg_handoff": True,
        },
    )
    await _advance_cycle(dut)
    _drive_from_ex(dut, {})

    # Walk the PC stream toward the trained branch until the BTB hit fires.
    await _redirect_to(dut, BASE_PC)
    prediction_cycle_found = False
    for _ in range(20):
        if int(dut.branch_prediction_controller_inst.o_prediction_used.value):
            prediction_cycle_found = True
            break
        await _advance_cycle(dut)
    assert prediction_cycle_found, "BTB prediction never fired; test misconfigured"

    # Collision: a PD redirect in the same cycle the prediction is used.
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = pd_target
    await _advance_cycle(dut)
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0

    # Fetch must follow the PD redirect, not the dead prediction.
    assert int(dut.o_pc.value) == pd_target
    assert dut.o_fetch_cached_retarget.value

    # A stall begins immediately and outlives any one-cycle kill pulse.
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _advance_cycle(dut)
    for _ in range(3):
        _drive_pipeline_ctrl(dut, {"stall": True, "stall_registered": True})
        await _advance_cycle(dut)
    _drive_pipeline_ctrl(dut, {"stall_registered": True})
    await _advance_cycle(dut)
    _drive_pipeline_ctrl(dut, {})

    # After release, every non-NOP slot-1 packet must carry a PD-path PC.
    # On broken RTL the stall-held handoff applies the dead prediction's
    # target to pc_reg at release: packet PCs walk the stale-target region
    # while fetch serves PD-path bytes (the pc/byte desync that executes
    # stale words under wrong PCs).
    for _ in range(7):
        packet = _read_if_packet(dut)
        if not packet["sel_nop"]:
            pkt_pc = packet["program_counter"]
            assert pd_target <= pkt_pc < pd_target + 0x100, (
                f"slot-1 packet pc={pkt_pc:#x} left the PD-redirect path: "
                "a stale registered prediction handoff applied a dead "
                "prediction's target to pc_reg after a PD redirect + stall"
            )
        await _advance_cycle(dut)


@cocotb.test()
async def test_pd_redirect_btb_collision_stall_keeps_wrong_path_bubble(
    dut: Any,
) -> None:
    """A stalled PD-redirect wrong-path bubble must not dispatch on release.

    A PD redirect collapses pc onto pc_reg (both jump to the target), and the
    cycle after it is a lead-restoring bubble: fetch advances while pc_reg
    holds, and pd_redirect_q forces sel_nop because a same-cycle BTB hit sets
    prediction_holdoff, which otherwise defeats the control-flow-holdoff NOP
    term.  pd_redirect_q is a one-cycle pulse; control_flow_holdoff and
    prediction_holdoff are stall-held.  A stall covering the bubble cycle
    outlives the pulse: on release the bubble cycle presents non-NOP (consumed
    by dispatch) and the realigned next cycle presents the SAME pc_reg again
    -- the duplicate ROB allocation seen in the cjpeg tiny sim (646-byte JPEG,
    one-bit-short Huffman code from a skipped coefficient).
    """
    await _setup_test(dut)
    dut.i_disable_branch_prediction.value = 0

    branch_pc = BASE_PC + 8
    stale_pred_target = 0x80005000
    pd_target = 0x80006000

    # Train the BTB so a hit collides with the PD redirect (the collision is
    # what arms prediction_holdoff and defeats the plain control-flow NOP).
    _drive_from_ex(
        dut,
        {
            "btb_update": True,
            "btb_update_pc": branch_pc,
            "btb_update_target": stale_pred_target,
            "btb_update_taken": True,
            "btb_update_compressed": False,
            "btb_update_requires_pc_reg_handoff": True,
        },
    )
    await _advance_cycle(dut)
    _drive_from_ex(dut, {})

    await _redirect_to(dut, BASE_PC)
    prediction_cycle_found = False
    for _ in range(20):
        if int(dut.branch_prediction_controller_inst.o_prediction_used.value):
            prediction_cycle_found = True
            break
        await _advance_cycle(dut)
    assert prediction_cycle_found, "BTB prediction never fired; test misconfigured"

    # Collision cycle E: PD redirect + BTB hit together (unstalled, so the
    # redirect applies and pd_redirect_q arms for the next cycle).
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = pd_target
    await _advance_cycle(dut)
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0
    assert int(dut.o_pc.value) == pd_target

    # Cycle E+1 (the wrong-path bubble): a stall begins and outlives the
    # one-cycle pd_redirect_q pulse.  Keep the target word on the fetch bus,
    # as BRAM would once the frozen fetch address resolves.
    _drive_fetch(dut, current_word=ADD_INSTR_A, next_word=ADD_INSTR_B)
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _advance_cycle(dut)
    for _ in range(3):
        _drive_pipeline_ctrl(dut, {"stall": True, "stall_registered": True})
        await _advance_cycle(dut)

    # Release: stall drops with stall_registered high for one cycle, then
    # both low.  Sample every consumable cycle from the release on.
    presented: list[int] = []
    _drive_pipeline_ctrl(dut, {"stall_registered": True})
    await _settle()
    for _ in range(8):
        packet = _read_if_packet(dut)
        if not packet["sel_nop"]:
            presented.append(packet["program_counter"])
        await _advance_cycle(dut)
        _drive_pipeline_ctrl(dut, {})

    # The PD target bundle must flow exactly once: a repeat of the same
    # slot-1 PC in the consumed stream is the duplicate dispatch.
    dup = [pc for pc in set(presented) if presented.count(pc) > 1]
    assert not dup, (
        f"slot-1 pc(s) {[hex(p) for p in dup]} presented more than once after "
        "stall release: the pd_redirect_q wrong-path bubble expired during "
        "the stall and the bubble cycle dispatched alongside the realigned "
        "repeat (stall-release duplicate dispatch)"
    )
    assert any(pd_target <= pc < pd_target + 0x40 for pc in presented), (
        f"PD-target bundle never presented after release (got "
        f"{[hex(p) for p in presented]}): over-broad squash"
    )


@cocotb.test()
async def test_pd_redirect_kills_pending_saved_prediction_metadata(dut: Any) -> None:
    """A PD redirect must kill the pending-SAVED prediction metadata too.

    Repro of the taken-branch -> jal-at-dword+4 call-skip bug (the rv64 Linux
    of_core_init "interrupt-controller#1..#16" storm; XLEN-independent): a
    predicted-taken instruction's BTB hit consumes while pc_reg is still two
    compressed parcels behind the fetch PC, so the pending pc_reg handoff arms
    and prediction_metadata_tracker captures the metadata into its
    pending-saved side buffer.  A PD redirect for one of those older walked
    instructions (an unpredicted taken branch whose computed target is the
    predicted instruction itself) then kills the pending FETCH state in
    pc_controller -- but the saved metadata used to survive (its clear list
    was reset/flush only) and replayed onto the re-fetched instruction once it
    finally emitted.  The instruction then carried "front-end already
    redirected to <its own target>" while fetch had actually fallen through
    sequentially; for a JAL the ROB trusts that metadata at allocation and
    never recovers, silently skipping the callee.

    The pending walk needs pc_reg strictly behind fetch, which the directed
    jal_target_seam app only reaches on the variable-latency L1I path; here
    the unpairable-compressed walk pins it deterministically.
    """
    await _setup_test(dut)
    dut.i_disable_branch_prediction.value = 0

    jal_pc = BASE_PC + 8
    callee = 0x80005000

    # Train the BTB: taken entry at jal_pc (native width), as commit training
    # would after the first sequential lap through a jal.
    _drive_from_ex(
        dut,
        {
            "btb_update": True,
            "btb_update_pc": jal_pc,
            "btb_update_target": callee,
            "btb_update_taken": True,
            "btb_update_compressed": False,
            "btb_update_requires_pc_reg_handoff": True,
        },
    )
    await _advance_cycle(dut)
    _drive_from_ex(dut, {})

    # pc_reg-following instruction memory: two words of UNPAIRABLE compressed
    # parcels (control-marked, so slot-2 never forms and pc_reg walks +2 per
    # cycle) ahead of the native instruction at jal_pc.  Fetch strides a word
    # per cycle, so by the time the BTB hit at jal_pc consumes, pc_reg is
    # still inside the compressed run and the pending handoff must arm.
    compressed_ctrl_sb = _sideband(
        compressed_lo=True,
        compressed_hi=True,
        compressed_control_lo=True,
        compressed_control_hi=True,
    )
    compressed_word = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_NOP)
    mem: dict[int, tuple[int, int]] = {
        BASE_PC: (compressed_word, compressed_ctrl_sb),
        BASE_PC + 4: (compressed_word, compressed_ctrl_sb),
        jal_pc: (ADD_INSTR_A, 0),
        jal_pc + 4: (ADD_INSTR_B, 0),
        jal_pc + 8: (ADD_INSTR_C, 0),
    }

    def _serve_window() -> None:
        addr_mask = (1 << XLEN) - 1
        word0 = int(dut.pc_reg.value) & addr_mask & ~3
        cur, cur_sb = mem.get(word0, (NOP_INSTR, 0))
        nxt, nxt_sb = mem.get((word0 + 4) & addr_mask, (NOP_INSTR, 0))
        _drive_fetch(
            dut,
            current_word=cur,
            next_word=nxt,
            current_sb=cur_sb,
            next_sb=nxt_sb,
            bank_sel=(word0 >> 2) & 1,
        )

    async def _window_follower() -> None:
        while True:
            _serve_window()
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="step")

    cocotb.start_soon(_window_follower())

    await _redirect_to(dut, BASE_PC)

    # Walk until the jal_pc prediction consumes.
    prediction_cycle_found = False
    for _ in range(20):
        if int(dut.branch_prediction_controller_inst.o_prediction_used.value):
            prediction_cycle_found = True
            break
        await _advance_cycle(dut)
    assert prediction_cycle_found, "BTB prediction never fired; test misconfigured"
    assert int(dut.pc_reg.value) < jal_pc, (
        "pc_reg already reached the predicted PC at consume; the pending "
        "handoff cannot arm and this test no longer covers the saved-metadata "
        "kill (tighten the compressed run)"
    )

    # Consume applied: fetch redirects to the callee while the pending
    # handoff walks pc_reg toward jal_pc.
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == callee, "prediction consume did not redirect fetch"
    assert (
        int(dut.pc_controller_inst.pending_prediction_valid.value) == 1
    ), "pending pc_reg handoff never armed; the capture under test cannot occur"

    # The PD redirect for the older unpredicted taken branch: computed target
    # = the predicted instruction itself.  This cycle is exactly the
    # tracker's pending-save capture cycle (registered metadata + pending
    # fetch holdoff both still read pre-kill values).
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = jal_pc
    await _advance_cycle(dut)
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0
    assert int(dut.o_pc.value) == jal_pc, "PD redirect did not steer fetch"

    # The re-fetched instruction at jal_pc must emit UNPREDICTED: its fetch
    # redirect died with the pending state, so any surviving predicted-taken
    # metadata would be the exact ROB-blinding lie (predicted_target == its
    # own target -> mispredicted=0 -> lost redirect never recovered).
    jal_packets_seen = 0
    for _ in range(10):
        for slot2 in (False, True):
            packet = _read_if_packet(dut, slot2=slot2)
            if packet["sel_nop"] or packet["program_counter"] != jal_pc:
                continue
            jal_packets_seen += 1
            assert not packet["btb_predicted_taken"] and not packet["btb_hit"], (
                "stale pending-saved BTB metadata replayed onto the re-fetched "
                f"instruction at {jal_pc:#x} after a PD redirect killed its "
                "pending fetch state (the jal_target_seam call-skip bug)"
            )
        await _advance_cycle(dut)
    assert jal_packets_seen, (
        "the re-fetched instruction never presented; the metadata check " "was vacuous"
    )


@cocotb.test()
async def test_pending_exact_owner_handoffs_atomically_with_metadata(
    dut: Any,
) -> None:
    """A first-cycle exact owner emits once with its taken metadata.

    A word-aligned branch that predicts a halfword target can put ``pc_reg``
    on the exact branch in the first pending-active cycle. The registered
    prediction holdoff proves that the owner metadata is still aligned, so the
    owner and target handoff must be consumed atomically rather than inserting
    a bubble or dispatching the owner again on a later replay.
    """
    await _setup_test(dut)

    branch_pc = BASE_PC + 4
    target = BASE_PC + 0x82
    await _train_btb(
        dut,
        pc=branch_pc,
        target=target,
        compressed=False,
        handoff=True,
    )
    await _redirect_to(dut, BASE_PC)

    # Fixed-latency lookahead predicts branch_pc while pc_reg still presents
    # BASE_PC.  The halfword target forces a pending pc_reg handoff even though
    # the next sequential pc_reg value lands exactly on the branch.
    _drive_fetch(dut, current_word=NOP_INSTR, next_word=NOP_INSTR)
    dut.i_disable_branch_prediction.value = 0
    await _settle()
    bpc = dut.branch_prediction_controller_inst
    pc_ctrl = dut.pc_controller_inst
    assert int(dut.o_pc.value) == branch_pc
    assert int(dut.pc_reg.value) == BASE_PC
    assert bpc.o_prediction_used.value

    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == target
    assert int(dut.pc_reg.value) == branch_pc
    assert pc_ctrl.pending_prediction_valid.value
    assert bpc.o_prediction_holdoff.value
    assert pc_ctrl.pending_prediction_target_handoff_applies.value
    assert pc_ctrl.o_pending_prediction_target_handoff.value
    assert not pc_ctrl.o_pending_prediction_fetch_holdoff.value

    # This first exact-owner sighting is the real architectural packet. Its
    # registered taken metadata and target are consumed on the same edge that
    # applies the pending target to pc_reg.
    early_packet = _read_if_packet(dut)
    assert early_packet["program_counter"] == branch_pc
    assert not early_packet["sel_nop"]
    assert early_packet["btb_hit"]
    assert early_packet["btb_predicted_taken"]
    assert early_packet["btb_predicted_target"] == target
    assert dut.o_fetch_live_claim.value

    real_owner_packets: list[dict[str, Any]] = [early_packet]
    await _advance_cycle(dut)
    for _ in range(8):
        packet = _read_if_packet(dut)
        if not packet["sel_nop"] and packet["program_counter"] == branch_pc:
            real_owner_packets.append(packet)
            assert packet["btb_hit"]
            assert packet["btb_predicted_taken"]
            assert packet["btb_predicted_target"] == target
        await _advance_cycle(dut)

    assert len(real_owner_packets) == 1, (
        "pending exact owner must dispatch exactly once with its registered "
        f"metadata (saw {len(real_owner_packets)})"
    )


@cocotb.test()
async def test_first_exact_owner_wcs_captures_then_replays_once(
    dut: Any,
) -> None:
    """A bad first owner window defers the atomic handoff without data loss.

    The early prediction-holdoff readiness may coincide with a provider
    response that does not cover the exact owner. Served-window priority must
    keep the pending state live, capture its metadata, and emit one real owner
    only after the covering response returns.
    """
    await _setup_test(dut)

    branch_pc = BASE_PC + 4
    target = BASE_PC + 0x82
    await _train_btb(
        dut,
        pc=branch_pc,
        target=target,
        compressed=False,
        handoff=True,
    )
    await _redirect_to(dut, BASE_PC)

    _drive_fetch(dut, current_word=NOP_INSTR, next_word=ADD_INSTR_A)
    dut.i_disable_branch_prediction.value = 0
    await _settle()
    bpc = dut.branch_prediction_controller_inst
    pc_ctrl = dut.pc_controller_inst
    metadata = dut.prediction_metadata_tracker_inst
    assert bpc.o_prediction_used.value

    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == target
    assert int(dut.pc_reg.value) == branch_pc
    assert pc_ctrl.pending_prediction_valid.value
    assert bpc.o_prediction_holdoff.value

    # Publish a response for the already-requested target, not the branch
    # window. The raw early handoff is ready, but the WCS arm wins both PC
    # muxes and the architectural packet remains a bubble.
    _drive_served_word_tags(dut, target >> 2, provider="low")
    await _settle()
    assert dut.window_cannot_serve_pc_reg.value
    assert pc_ctrl.pending_prediction_target_handoff.value
    assert not pc_ctrl.pending_prediction_target_handoff_applies.value
    assert not pc_ctrl.o_pending_prediction_target_handoff.value
    packet = _read_if_packet(dut)
    assert packet["program_counter"] == branch_pc
    assert packet["sel_nop"]
    assert not packet["btb_hit"]
    assert not packet["btb_predicted_taken"]
    assert not dut.o_fetch_live_claim.value
    assert metadata.pending_prediction_capture.value

    # The mismatch edge captures metadata and resteers fetch to the owner.
    # The background provider model restores a covering tag after the edge;
    # pc_ready_q still needs one complete covering cycle before replay.
    await _advance_cycle(dut)
    assert metadata.prediction_pending_saved_valid.value
    assert pc_ctrl.pending_prediction_valid.value
    assert not pc_ctrl.pending_prediction_pc_ready_q.value
    assert not pc_ctrl.o_pending_prediction_target_handoff.value
    assert not pc_ctrl.o_pending_prediction_target_holdoff.value
    assert _read_if_packet(dut)["sel_nop"]

    await _advance_cycle(dut)
    assert pc_ctrl.pending_prediction_pc_ready_q.value
    assert pc_ctrl.pending_prediction_target_handoff_applies.value
    assert pc_ctrl.o_pending_prediction_target_handoff.value
    owner_packet = _read_if_packet(dut)
    assert owner_packet["program_counter"] == branch_pc
    assert not owner_packet["sel_nop"]
    assert owner_packet["btb_hit"]
    assert owner_packet["btb_predicted_taken"]
    assert owner_packet["btb_predicted_target"] == target

    await _advance_cycle(dut)
    assert not pc_ctrl.pending_prediction_valid.value
    assert not metadata.prediction_pending_saved_valid.value
    assert pc_ctrl.o_pending_prediction_target_holdoff.value

    real_owner_packets = 1
    for _ in range(6):
        packet = _read_if_packet(dut)
        if not packet["sel_nop"] and packet["program_counter"] == branch_pc:
            real_owner_packets += 1
        await _advance_cycle(dut)

    assert real_owner_packets == 1, (
        "served-window retry must emit the saved exact owner once "
        f"(saw {real_owner_packets})"
    )


@cocotb.test()
async def test_atomic_compressed_owner_discards_wrong_path_high_buffer(
    dut: Any,
) -> None:
    """Atomic owner handoff cannot replay its upper sibling at the target."""
    await _setup_test(dut)

    branch_pc = BASE_PC + 4
    target = BASE_PC + 0x82
    owner_high_canary = COMPRESSED_HINT
    owner_word = _word(lo=0xFA6D, hi=owner_high_canary)  # C.BNEZ, then canary
    owner_sb = _sideband(
        compressed_lo=True,
        compressed_hi=True,
        compressed_control_lo=True,
    )
    target_word = _word(lo=0xFA6D, hi=COMPRESSED_NOP)
    target_sb = _sideband(
        compressed_lo=True,
        compressed_hi=True,
        compressed_control_lo=True,
    )

    await _train_btb(
        dut,
        pc=branch_pc,
        target=target,
        compressed=True,
        handoff=True,
    )
    await _redirect_to(dut, BASE_PC)

    _drive_fetch(
        dut,
        current_word=NOP_INSTR,
        next_word=owner_word,
        next_sb=owner_sb,
        bank_sel=(BASE_PC >> 2) & 1,
    )
    dut.i_disable_branch_prediction.value = 0
    await _settle()
    assert dut.branch_prediction_controller_inst.o_prediction_used.value

    await _advance_cycle(dut)
    pc_ctrl = dut.pc_controller_inst
    owner_packet = _read_if_packet(dut)
    assert pc_ctrl.pending_prediction_target_handoff_applies.value
    assert not owner_packet["sel_nop"]
    assert owner_packet["program_counter"] == branch_pc
    assert owner_packet["raw_parcel"] == 0xFA6D
    assert owner_packet["sel_compressed"]
    assert owner_packet["btb_predicted_taken"]
    assert owner_packet["btb_predicted_target"] == target

    # Keep the owner response present through the atomic consume edge. The
    # owner's captured upper sibling is wrong-path and must not become valid
    # C-extension buffer state.
    await _advance_cycle(dut)
    assert not pc_ctrl.pending_prediction_valid.value
    assert not dut.c_ext_state_inst.o_prev_was_compressed_at_lo.value

    _drive_fetch(
        dut,
        current_word=target_word,
        current_sb=target_sb,
        bank_sel=(target >> 2) & 1,
    )
    _drive_served_word_tags(dut, target >> 2, provider="low")

    target_packets: list[dict[str, Any]] = []
    for _ in range(6):
        await _settle()
        packet = _read_if_packet(dut)
        if not packet["sel_nop"] and packet["program_counter"] == target:
            target_packets.append(packet)
            assert packet["raw_parcel"] == COMPRESSED_NOP
            assert packet["raw_parcel"] != owner_high_canary
        assert not dut.use_buffer_after_prediction.value
        await _advance_cycle(dut)

    assert len(target_packets) == 1, (
        "halfword target must emit exactly once from its target word "
        f"(saw {len(target_packets)})"
    )


@cocotb.test()
async def test_pending_prediction_owner_keeps_predict_time_direction_index(
    dut: Any,
) -> None:
    """A delayed predicted branch keeps its own bimodal training index.

    A halfword pending handoff lets pc_reg drain an older compressed branch
    while fetch has already redirected. The prediction-arm edge replaces BPC's
    normal one-cycle direction snapshot with the younger pending branch's row.
    The released predecessor must retain its own direction result/index, and
    the exact owner must recover its predict-time index even after later
    lookups, including through a stall replay. Otherwise the predecessor can
    misredirect and either packet can train an unrelated predictor row.
    """
    await _setup_test(dut)
    dut.i_disable_branch_prediction.value = 0

    branch_pc = BASE_PC + 16
    predecessor_pc = branch_pc - 2
    target = 0x80005000
    branch_idx = (branch_pc >> 1) & ((1 << BP_DIR_IDX_BITS) - 1)
    predecessor_idx = (predecessor_pc >> 1) & ((1 << BP_DIR_IDX_BITS) - 1)

    # Give the immediate predecessor a direction result opposite the younger
    # pending branch's default row. Two increments take its counter from 00 to
    # 10 (taken), making both a stale bit and a stale index observable.
    dut.i_dir_update_idx.value = predecessor_idx
    dut.i_dir_update_taken.value = 1
    dut.i_dir_update_valid.value = 1
    await _advance_cycle(dut)
    await _advance_cycle(dut)
    dut.i_dir_update_valid.value = 0

    await _train_btb(
        dut,
        pc=branch_pc,
        target=target,
        compressed=False,
        handoff=True,
    )

    # Four words of unpairable compressed parcels make pc_reg advance only one
    # halfword per cycle while the lookup PC advances by a word.  The taken hit
    # at branch_pc therefore arms a pending owner before pc_reg reaches it.
    compressed_ctrl_sb = _sideband(
        compressed_lo=True,
        compressed_hi=True,
        compressed_control_lo=True,
        compressed_control_hi=True,
    )
    compressed_word = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_HINT)
    predecessor_word = _word(lo=COMPRESSED_NOP, hi=0xFA6D)  # C.BNEZ
    mem: dict[int, tuple[int, int]] = {
        BASE_PC: (compressed_word, compressed_ctrl_sb),
        BASE_PC + 4: (compressed_word, compressed_ctrl_sb),
        BASE_PC + 8: (compressed_word, compressed_ctrl_sb),
        BASE_PC + 12: (predecessor_word, compressed_ctrl_sb),
        branch_pc: (ADD_INSTR_A, 0),
        branch_pc + 4: (ADD_INSTR_B, 0),
    }

    def _serve_window() -> None:
        addr_mask = (1 << XLEN) - 1
        word0 = int(dut.pc_reg.value) & addr_mask & ~3
        cur, cur_sb = mem.get(word0, (NOP_INSTR, 0))
        nxt, nxt_sb = mem.get((word0 + 4) & addr_mask, (NOP_INSTR, 0))
        _drive_fetch(
            dut,
            current_word=cur,
            next_word=nxt,
            current_sb=cur_sb,
            next_sb=nxt_sb,
            bank_sel=(word0 >> 2) & 1,
        )

    async def _window_follower() -> None:
        while True:
            _serve_window()
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="step")

    cocotb.start_soon(_window_follower())
    await _redirect_to(dut, BASE_PC)

    prediction_cycle_found = False
    for _ in range(20):
        if int(dut.branch_prediction_controller_inst.o_prediction_used.value):
            prediction_cycle_found = True
            break
        await _advance_cycle(dut)
    assert prediction_cycle_found, "BTB prediction never fired; test misconfigured"
    assert int(dut.pc_reg.value) < branch_pc

    await _advance_cycle(dut)
    assert dut.pc_controller_inst.pending_prediction_valid.value

    # Let the real predecessor flow. It must not steal the younger branch's
    # BTB metadata; the pending owner remains live for the following packet.
    predecessor_seen = False
    for _ in range(24):
        packet = _read_if_packet(dut)
        if not packet["sel_nop"] and packet["program_counter"] == predecessor_pc:
            predecessor_seen = True
            assert not packet["btb_hit"]
            assert not packet["btb_predicted_taken"]
            assert packet["bp_dir_taken"]
            assert packet["bp_dir_idx"] == predecessor_idx
            await _advance_cycle(dut)
            break
        await _advance_cycle(dut)
    assert predecessor_seen, "pending immediate predecessor never emitted"

    # The next real packet is the exact owner (raw served-window recovery may
    # insert a bubble first). By now BPC's ordinary snapshot describes the
    # redirected target stream, proving the output cannot pass merely by luck
    # through the old registered index.
    owner_seen = False
    for _ in range(8):
        packet = _read_if_packet(dut)
        if not packet["sel_nop"]:
            assert packet["program_counter"] == branch_pc
            owner_seen = True
            break
        await _advance_cycle(dut)
    assert owner_seen, "pending prediction's exact owner never emitted"
    # Model the intervening target-path lookup explicitly at this integration
    # seam. The BPC unit independently pins that running fetch-progress cycles
    # replace this snapshot; here we make the stale value deterministic so the
    # owner-index mux itself cannot pass by accidental low-bit aliasing.
    stale_idx = (target >> 1) & ((1 << BP_DIR_IDX_BITS) - 1)
    assert stale_idx != branch_idx
    dut.branch_prediction_controller_inst.pred_idx_snapshot_r.value = stale_idx
    await _settle()
    packet = _read_if_packet(dut)
    assert packet["btb_hit"] and packet["btb_predicted_taken"]
    assert packet["btb_predicted_target"] == target
    assert int(dut.branch_prediction_controller_inst.o_dir_idx.value) == stale_idx
    assert packet["bp_dir_idx"] == branch_idx

    # Stall on the owner before its pending target handoff can consume. The
    # release packet must replay the same exact training index.
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _settle()
    packet = _read_if_packet(dut)
    assert packet["program_counter"] == branch_pc
    assert packet["bp_dir_idx"] == branch_idx
    await _advance_cycle(dut)

    _drive_pipeline_ctrl(dut, {"stall_registered": True})
    await _settle()
    assert dut.replay_saved_if_outputs.value
    packet = _read_if_packet(dut)
    assert not packet["sel_nop"]
    assert packet["program_counter"] == branch_pc
    assert packet["btb_hit"] and packet["btb_predicted_taken"]
    assert packet["btb_predicted_target"] == target
    assert packet["bp_dir_idx"] == branch_idx

    # direction_predictor RAM intentionally survives reset between tests.
    # Restore the predecessor row to its initial strongly-not-taken state.
    _drive_pipeline_ctrl(dut, {})
    dut.i_dir_update_idx.value = predecessor_idx
    dut.i_dir_update_taken.value = 0
    dut.i_dir_update_valid.value = 1
    await _advance_cycle(dut)
    await _advance_cycle(dut)
    dut.i_dir_update_valid.value = 0


@cocotb.test()
async def test_fetch_invalid_bubbles_and_holds_pc(dut: Any) -> None:
    """Fetch-invalid cycles emit NOP bubbles, freeze PC, and defer delivery."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    _drive_fetch(dut, current_word=ADD_INSTR_A, next_word=ADD_INSTR_B)
    await _settle()
    _assert_packet(
        _read_if_packet(dut),
        pc=BASE_PC,
        raw=ADD_INSTR_A & 0xFFFF,
        effective=ADD_INSTR_A,
        compressed=False,
    )
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8

    # The provider goes invalid: bubbles on both slots, PC frozen, the
    # undelivered instruction at pc_reg = BASE_PC + 4 stays pending.
    dut.i_instr_valid.value = 0
    await _settle()
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]
    for _ in range(3):
        await _advance_cycle(dut)
        assert int(dut.o_pc.value) == BASE_PC + 8
        packet = _read_if_packet(dut)
        assert packet["sel_nop"]
        assert packet["program_counter"] == BASE_PC + 4

    # Resume: the provider re-serves the owed window (for fetch address
    # BASE_PC + 4 -- an odd word, hence bank_sel=1) and delivery continues
    # exactly where it left off.
    dut.i_instr_valid.value = 1
    _drive_fetch(dut, current_word=ADD_INSTR_B, next_word=ADD_INSTR_C, bank_sel=1)
    await _settle()
    _assert_packet(
        _read_if_packet(dut),
        pc=BASE_PC + 4,
        raw=ADD_INSTR_B & 0xFFFF,
        effective=ADD_INSTR_B,
        compressed=False,
    )
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == BASE_PC + 12


@cocotb.test()
async def test_branch_redirect_lands_during_fetch_invalid(dut: Any) -> None:
    """Branch resolution redirects PC while the fetch window is invalid."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    dut.i_instr_valid.value = 0
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == BASE_PC + 4  # frozen
    assert _read_if_packet(dut)["sel_nop"]

    _drive_from_ex(dut, {"branch_taken": True, "branch_target_address": BRANCH_TARGET})
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET  # redirect landed while invalid

    _drive_from_ex(dut, {})
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET  # held while still invalid
    assert _read_if_packet(dut)["sel_nop"]

    # Resume. The first valid cycle is the (extended-holdoff) stale squash
    # that also restores the one-word fetch lead; the target word delivers
    # on the following cycle.
    dut.i_instr_valid.value = 1
    _drive_fetch(dut, current_word=ADD_INSTR_A, next_word=ADD_INSTR_B)  # stale
    await _settle()
    assert _read_if_packet(dut)["sel_nop"]
    await _advance_cycle(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET + 4

    _drive_fetch(dut, current_word=ADD_INSTR_C, next_word=NOP_INSTR)
    await _settle()
    _assert_packet(
        _read_if_packet(dut),
        pc=BRANCH_TARGET,
        raw=ADD_INSTR_C & 0xFFFF,
        effective=ADD_INSTR_C,
        compressed=False,
    )


@cocotb.test()
async def test_fetch_invalid_compressed_pair_resume(dut: Any) -> None:
    """A 2-wide compressed bundle delivers intact right after an invalid gap."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    dut.i_instr_valid.value = 0
    for _ in range(2):
        await _advance_cycle(dut)
        assert int(dut.o_pc.value) == BASE_PC + 4
        assert _read_if_packet(dut)["sel_nop"]
        assert _read_if_packet(dut, slot2=True)["sel_nop"]

    dut.i_instr_valid.value = 1
    current_word = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_HINT)
    _drive_fetch(
        dut,
        current_word=current_word,
        next_word=ADD_INSTR_A,
        current_sb=_sideband(compressed_lo=True, compressed_hi=True),
    )
    await _settle()
    _assert_packet(
        _read_if_packet(dut),
        pc=BASE_PC,
        raw=COMPRESSED_NOP,
        effective=current_word,
        compressed=True,
    )
    _assert_packet(
        _read_if_packet(dut, slot2=True),
        pc=BASE_PC + 2,
        raw=COMPRESSED_HINT,
        # Slot-2 carries the XLEN-specific RVC expansion: C.JAL on RV32,
        # C.ADDIW x4, x4, 8 on RV64.
        effective=COMPRESSED_HINT_EXPANDED,
        compressed=True,
    )


@cocotb.test()
async def test_pd_redirect_stall_32bit_target_no_plus2_desync(dut: Any) -> None:
    """PD-redirect+BTB-collision+stall must not advance pc_reg by +2 onto a 32-bit instruction.

    Same race as test_pd_redirect_with_stall_kills_registered_prediction_handoff
    but the wrong-ADVANCE (+2) variant rather than wrong-TARGET: on genesys2 the
    HW lands pc_reg 2 bytes into a 32-bit insn (epc=0x8038d7fa, mid sw zero,4(s1))
    at workqueue_init_early -> illegal-instruction Oops. Drive a 32-bit stream at
    the PD target; every dispatched PC must be 4-byte aligned.
    """
    await _setup_test(dut)
    dut.i_disable_branch_prediction.value = 0

    branch_pc = BASE_PC + 8
    stale_pred_target = 0x80005000
    pd_target = 0x80006000

    _drive_from_ex(
        dut,
        {
            "btb_update": True,
            "btb_update_pc": branch_pc,
            "btb_update_target": stale_pred_target,
            "btb_update_taken": True,
            "btb_update_compressed": False,
            "btb_update_requires_pc_reg_handoff": True,
        },
    )
    await _advance_cycle(dut)
    _drive_from_ex(dut, {})

    await _redirect_to(dut, BASE_PC)
    prediction_cycle_found = False
    for _ in range(20):
        if int(dut.branch_prediction_controller_inst.o_prediction_used.value):
            prediction_cycle_found = True
            break
        await _advance_cycle(dut)
    assert prediction_cycle_found, "BTB prediction never fired; test misconfigured"

    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = pd_target
    await _advance_cycle(dut)
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0

    _drive_pipeline_ctrl(dut, {"stall": True})
    await _advance_cycle(dut)
    for _ in range(3):
        _drive_pipeline_ctrl(dut, {"stall": True, "stall_registered": True})
        await _advance_cycle(dut)
    _drive_pipeline_ctrl(dut, {})

    bad: list[int] = []
    for _ in range(8):
        _drive_fetch(dut, current_word=ADD_INSTR_A, next_word=ADD_INSTR_B)
        await _settle()
        packet = _read_if_packet(dut)
        if not packet["sel_nop"]:
            pc = packet["program_counter"]
            if pc & 0x2:
                bad.append(pc)
        await _advance_cycle(dut)
    assert not bad, (
        "pc_reg landed mid-32-bit-instruction (+2 desync) after PD-redirect+stall: "
        f"{[hex(x) for x in bad]}"
    )


@cocotb.test()
async def test_fetch_window_lead_parity_plus2_desync(dut: Any) -> None:
    """Fetch window leading pc_reg by one word (F=W+1) -> is_compressed_fast reads word(W+2)'s size bit.

    If that word's low parcel predecodes compressed, a
    word-aligned 32-bit insn at pc_reg advances +2 (mid-instruction). This is the
    workqueue_init_early HW Oops shape (epc 2 bytes into a word-aligned 32-bit sw).
    The four fetch_word_swapped_* replicas (instruction_aligner.sv:159-166), each
    i_instr_bank_sel_r ^ i_pc_reg[2], are a 1-bit parity that cannot represent
    F=W+1.
    """
    # served_word_offset=1 models the served window leading pc_reg by one word
    # (F=W+1): the case the served-window guard must catch (hold pc_reg, stay
    # 4-aligned) rather than letting the 1-bit aligner parity advance pc_reg +2.
    await _setup_test(dut, served_word_offset=1)
    await _redirect_to(
        dut, BASE_PC
    )  # pc_reg -> 0x80001000 (bit1=0, bit2=0); 32-bit insn here

    _drive_fetch(
        dut,
        current_word=ADD_INSTR_A,  # i_instr[31:0]
        next_word=0x00000004,  # i_instr[63:32] = word(W+2); lo parcel 0x0004 -> "compressed"
        current_sb=_sideband(),  # 32-bit at pc_reg
        next_sb=_sideband(
            compressed_lo=True,
            compressed_hi=False,
            rvc_source_hot_lo=1,
        ),
        bank_sel=1,  # = ~pc_reg[2]; models served window one word AHEAD (F=W+1)
    )
    await _settle()
    assert int(_read_if_packet(dut)["program_counter"]) == BASE_PC

    await _advance_cycle(dut)
    _drive_fetch(dut, current_word=ADD_INSTR_B, next_word=ADD_INSTR_C, bank_sel=1)
    await _settle()
    pc2 = int(_read_if_packet(dut)["program_counter"])
    assert (pc2 & 0x2) == 0, (
        f"pc_reg landed mid-32-bit-instruction at {pc2:#x} "
        "(F=W+1 fetch-window-lead parity hole; is_compressed_fast read the wrong word)"
    )

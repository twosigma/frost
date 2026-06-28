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


CLOCK_PERIOD_NS = 10
XLEN = 32
RAS_PTR_BITS = 3
BP_DIR_IDX_BITS = 10
NOP_INSTR = 0x00000013
ADD_INSTR_A = 0x00B50533
ADD_INSTR_B = 0x00C585B3
ADD_INSTR_C = 0x00D60633
COMPRESSED_NOP = 0x0001
COMPRESSED_HINT = 0x2221
BASE_PC = 0x80001000
BRANCH_TARGET = 0x80002000
FENCE_TARGET = 0x80003000

SB_IS_COMPRESSED_LO = 0
SB_IS_COMPRESSED_HI = 1
SB_COMPRESSED_CONTROL_LO = 2
SB_COMPRESSED_CONTROL_HI = 3
SB_NATIVE_SERIALIZE_LO = 4
SB_NATIVE_SERIALIZE_HI = 5
SB_NATIVE_FP_COMPUTE_LO = 6
SB_NATIVE_FP_COMPUTE_HI = 7
SB_ALLOWS_SLOT2_AFTER_LO = 8
SB_ALLOWS_SLOT2_AFTER_HI = 9
SB_SLOT2_START_VALID_LO = 10
SB_SLOT2_START_VALID_HI = 11
SIDEBAND_WIDTH = 12

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
    ("link_address", XLEN),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_predicted", 1),
    ("ras_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("bp_dir_taken", 1),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
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
) -> int:
    """Build one 32-bit-word instruction-memory sideband value."""
    allows_slot2_after_lo = compressed_lo and not compressed_control_lo
    allows_slot2_after_hi = compressed_hi and not compressed_control_hi
    slot2_start_valid_lo = compressed_lo or not (
        native_serialize_lo or native_fp_compute_lo
    )
    slot2_start_valid_hi = compressed_hi or not (
        native_serialize_hi or native_fp_compute_hi
    )
    return (
        _bit(compressed_lo, SB_IS_COMPRESSED_LO)
        | _bit(compressed_hi, SB_IS_COMPRESSED_HI)
        | _bit(compressed_control_lo, SB_COMPRESSED_CONTROL_LO)
        | _bit(compressed_control_hi, SB_COMPRESSED_CONTROL_HI)
        | _bit(native_serialize_lo, SB_NATIVE_SERIALIZE_LO)
        | _bit(native_serialize_hi, SB_NATIVE_SERIALIZE_HI)
        | _bit(native_fp_compute_lo, SB_NATIVE_FP_COMPUTE_LO)
        | _bit(native_fp_compute_hi, SB_NATIVE_FP_COMPUTE_HI)
        | _bit(allows_slot2_after_lo, SB_ALLOWS_SLOT2_AFTER_LO)
        | _bit(allows_slot2_after_hi, SB_ALLOWS_SLOT2_AFTER_HI)
        | _bit(slot2_start_valid_lo, SB_SLOT2_START_VALID_LO)
        | _bit(slot2_start_valid_hi, SB_SLOT2_START_VALID_HI)
    )


def _fetch_sideband(*, current_sb: int = 0, next_sb: int = 0) -> int:
    """Pack the fetch sideband bus as {next_word_sideband, current_word_sideband}."""
    mask = (1 << SIDEBAND_WIDTH) - 1
    return ((next_sb & mask) << SIDEBAND_WIDTH) | (current_sb & mask)


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
    """Drive packed EX feedback inputs."""
    dut.i_from_ex_comb.value = _pack_from_ex(fields)


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
) -> None:
    """Drive the instruction fetch data and predecode sideband."""
    dut.i_instr.value = _fetch(current_word=current_word, next_word=next_word)
    dut.i_instr_sideband.value = _fetch_sideband(current_sb=current_sb, next_sb=next_sb)
    dut.i_instr_bank_sel_r.value = bank_sel


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


def _clear_inputs(dut: Any) -> None:
    """Drive all IF-stage inputs to safe idle values."""
    _drive_from_ex(dut, {})
    _drive_fetch(dut, current_word=NOP_INSTR, next_word=NOP_INSTR)
    dut.i_instr_valid.value = 1
    _drive_pipeline_ctrl(dut, {})
    _drive_trap_ctrl(dut, {})
    dut.i_frontend_state_flush.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_fence_i_target.value = 0
    dut.i_disable_branch_prediction.value = 1
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the IF stage, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    _drive_pipeline_ctrl(dut, {"reset": True})
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    _drive_pipeline_ctrl(dut, {})
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
    assert packet["link_address"] == 4


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
    assert packet["link_address"] == BASE_PC + 4
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
        current_sb=_sideband(compressed_lo=True, compressed_hi=True),
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
    assert packet1["link_address"] == BASE_PC + 2

    packet2 = _read_if_packet(dut, slot2=True)
    _assert_packet(
        packet2,
        pc=BASE_PC + 2,
        raw=COMPRESSED_HINT,
        effective=COMPRESSED_HINT,
        compressed=True,
    )
    assert packet2["link_address"] == BASE_PC + 4
    assert not packet2["btb_hit"]
    assert not packet2["ras_predicted"]


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
    assert packet["link_address"] == BASE_PC + 4


@cocotb.test()
async def test_branch_redirect_generates_stale_fetch_bubble(dut: Any) -> None:
    """EX branch redirects PC and produces a one-cycle stale-fetch NOP bubble."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    _drive_from_ex(dut, {"branch_taken": True, "branch_target_address": BRANCH_TARGET})
    await _advance_cycle(dut)

    assert int(dut.o_pc.value) == BRANCH_TARGET
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]

    _drive_from_ex(dut, {})
    _drive_fetch(dut, current_word=ADD_INSTR_B, next_word=ADD_INSTR_C)
    await _advance_cycle(dut)

    assert int(dut.o_pc.value) == BRANCH_TARGET + 4
    packet = _read_if_packet(dut)
    _assert_packet(
        packet,
        pc=BRANCH_TARGET,
        raw=ADD_INSTR_B & 0xFFFF,
        effective=ADD_INSTR_B,
        compressed=False,
    )


@cocotb.test()
async def test_fence_i_redirect_uses_target_and_bubbles_fetch(dut: Any) -> None:
    """FENCE.I redirect uses its target port and suppresses the stale response."""
    await _setup_test(dut)
    await _redirect_to(dut, BASE_PC)

    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = FENCE_TARGET
    await _advance_cycle(dut)

    assert int(dut.o_pc.value) == FENCE_TARGET
    assert _read_if_packet(dut)["sel_nop"]
    assert _read_if_packet(dut, slot2=True)["sel_nop"]


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
        effective=COMPRESSED_HINT,
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
    fetch_word_swapped = i_instr_bank_sel_r ^ pc_reg[2] is a 1-bit parity that
    cannot represent F=W+1 (instruction_aligner.sv:141-147,235-240).
    """
    await _setup_test(dut)
    await _redirect_to(
        dut, BASE_PC
    )  # pc_reg -> 0x80001000 (bit1=0, bit2=0); 32-bit insn here

    _drive_fetch(
        dut,
        current_word=ADD_INSTR_A,  # i_instr[31:0]
        next_word=0x00000004,  # i_instr[63:32] = word(W+2); lo parcel 0x0004 -> "compressed"
        current_sb=_sideband(),  # 32-bit at pc_reg
        next_sb=_sideband(compressed_lo=True, compressed_hi=False),
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

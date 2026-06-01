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
    """Build one 32-bit-word instruction-memory sideband byte."""
    return (
        _bit(compressed_lo, SB_IS_COMPRESSED_LO)
        | _bit(compressed_hi, SB_IS_COMPRESSED_HI)
        | _bit(compressed_control_lo, SB_COMPRESSED_CONTROL_LO)
        | _bit(compressed_control_hi, SB_COMPRESSED_CONTROL_HI)
        | _bit(native_serialize_lo, SB_NATIVE_SERIALIZE_LO)
        | _bit(native_serialize_hi, SB_NATIVE_SERIALIZE_HI)
        | _bit(native_fp_compute_lo, SB_NATIVE_FP_COMPUTE_LO)
        | _bit(native_fp_compute_hi, SB_NATIVE_FP_COMPUTE_HI)
    )


def _fetch_sideband(*, current_sb: int = 0, next_sb: int = 0) -> int:
    """Pack the fetch sideband bus as {next_word_sideband, current_word_sideband}."""
    return ((next_sb & 0xFF) << 8) | (current_sb & 0xFF)


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

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

"""Top-level unit tests for the pre-decode stage."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
XLEN = 32
RAS_PTR_BITS = 3

NOP_INSTR = 0x00000013
OPC_BRANCH = 0b1100011
OPC_OP_IMM = 0b0010011
OPC_OP = 0b0110011

BASE_PC = 0x80001000

PIPELINE_CTRL_FIELDS = [
    ("reset", 1),
    ("stall", 1),
    ("stall_registered", 1),
    ("stall_for_trap_check", 1),
    ("flush", 1),
    ("trap_taken_registered", 1),
    ("mret_taken_registered", 1),
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

PD_TO_ID_FIELDS = [
    ("program_counter", XLEN),
    ("instruction", 32),
    ("link_address", XLEN),
    ("source_reg_1_early", 5),
    ("source_reg_2_early", 5),
    ("fp_source_reg_3_early", 5),
    ("illegal_instruction", 1),
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


def _unpack_struct(fields: list[tuple[str, int]], packed: int) -> dict[str, int | bool]:
    """Unpack a SystemVerilog packed struct into named Python values."""
    result: dict[str, int | bool] = {}
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = (packed >> offset) & ((1 << width) - 1)
        result[name] = bool(raw) if width == 1 else raw
    return result


def _pack_pipeline_ctrl(fields: Mapping[str, int | bool]) -> int:
    """Pack a pipeline_ctrl_t value."""
    return _pack_struct(PIPELINE_CTRL_FIELDS, fields)


def _pack_if_to_pd(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_if_to_pd_t value."""
    return _pack_struct(IF_TO_PD_FIELDS, fields)


def _drive_pipeline_ctrl(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the packed pipeline control bundle."""
    dut.i_pipeline_ctrl.value = _pack_pipeline_ctrl(fields)


def _drive_if_packet(
    dut: Any,
    fields: Mapping[str, int | bool],
    *,
    slot2: bool = False,
) -> None:
    """Drive one packed IF-to-PD input packet with idle-safe defaults."""
    packet = {
        "program_counter": 0,
        "raw_parcel": NOP_INSTR & 0xFFFF,
        "sel_nop": True,
        "sel_compressed": False,
        "effective_instr": NOP_INSTR,
        "link_address": 0,
        "btb_hit": False,
        "btb_predicted_taken": False,
        "btb_predicted_target": 0,
        "ras_predicted": False,
        "ras_predicted_target": 0,
        "ras_checkpoint_tos": 0,
        "ras_checkpoint_valid_count": 0,
    }
    packet.update(fields)
    value = _pack_if_to_pd(packet)
    if slot2:
        dut.i_from_if_to_pd_2.value = value
    else:
        dut.i_from_if_to_pd.value = value


def _read_pd_packet(dut: Any, *, slot2: bool = False) -> dict[str, int | bool]:
    """Read and unpack one PD-to-ID output packet."""
    signal = dut.o_from_pd_to_id_2 if slot2 else dut.o_from_pd_to_id
    return _unpack_struct(PD_TO_ID_FIELDS, int(signal.value))


def _pack_i(*, imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    """Pack an I-type instruction."""
    return (
        ((imm & 0xFFF) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def _pack_r(
    *,
    funct7: int,
    rs2: int,
    rs1: int,
    funct3: int,
    rd: int,
    opcode: int,
) -> int:
    """Pack an R-type instruction."""
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def _pack_b(*, imm: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    """Pack a B-type instruction."""
    offset = imm & 0x1FFF
    return (
        (((offset >> 12) & 0x1) << 31)
        | (((offset >> 5) & 0x3F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (((offset >> 1) & 0xF) << 8)
        | (((offset >> 11) & 0x1) << 7)
        | (opcode & 0x7F)
    )


def _pack_compressed(*, funct3: int, quadrant: int, bits12_2: int) -> int:
    """Pack common compressed-instruction fields."""
    return ((funct3 & 0x7) << 13) | ((bits12_2 & 0x7FF) << 2) | (quadrant & 0x3)


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


def _clear_inputs(dut: Any) -> None:
    """Drive all PD-stage inputs to idle values."""
    _drive_pipeline_ctrl(dut, {})
    _drive_if_packet(dut, {})
    _drive_if_packet(dut, {}, slot2=True)


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the PD stage, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    _drive_pipeline_ctrl(dut, {"reset": True})
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    _drive_pipeline_ctrl(dut, {})
    await _settle()


def _assert_nop_slot(packet: Mapping[str, int | bool]) -> None:
    """Assert that a PD output packet contains an idle instruction slot."""
    assert packet["instruction"] == NOP_INSTR
    assert packet["source_reg_1_early"] == 0
    assert packet["source_reg_2_early"] == 0
    assert packet["fp_source_reg_3_early"] == 0
    assert packet["illegal_instruction"] is False
    assert packet["btb_hit"] is False
    assert packet["btb_predicted_taken"] is False
    assert packet["ras_predicted"] is False


@cocotb.test()
async def test_reset_outputs_nops_and_clears_control_metadata(dut: Any) -> None:
    """Reset inserts NOPs and clears valid control metadata in both PD slots."""
    await _setup_test(dut)

    _assert_nop_slot(_read_pd_packet(dut))
    _assert_nop_slot(_read_pd_packet(dut, slot2=True))
    assert bool(dut.o_pd_redirect.value) is False


@cocotb.test()
async def test_native_instruction_registers_sources_and_metadata(dut: Any) -> None:
    """A native 32-bit instruction registers with early sources and metadata."""
    await _setup_test(dut)
    instruction = _pack_r(
        funct7=0,
        rs2=12,
        rs1=11,
        funct3=0,
        rd=10,
        opcode=OPC_OP,
    )

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": instruction & 0xFFFF,
            "sel_nop": False,
            "sel_compressed": False,
            "effective_instr": instruction,
            "link_address": BASE_PC + 4,
            "btb_hit": True,
            "btb_predicted_taken": True,
            "btb_predicted_target": BASE_PC + 0x40,
            "ras_predicted": True,
            "ras_predicted_target": BASE_PC + 0x80,
            "ras_checkpoint_tos": 5,
            "ras_checkpoint_valid_count": 6,
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["program_counter"] == BASE_PC
    assert packet["instruction"] == instruction
    assert packet["link_address"] == BASE_PC + 4
    assert packet["source_reg_1_early"] == 11
    assert packet["source_reg_2_early"] == 12
    assert packet["fp_source_reg_3_early"] == 0
    assert packet["illegal_instruction"] is False
    assert packet["btb_hit"] is True
    assert packet["btb_predicted_taken"] is True
    assert packet["btb_predicted_target"] == BASE_PC + 0x40
    assert packet["ras_predicted"] is True
    assert packet["ras_predicted_target"] == BASE_PC + 0x80
    assert packet["ras_checkpoint_tos"] == 5
    assert packet["ras_checkpoint_valid_count"] == 6


@cocotb.test()
async def test_compressed_instruction_decompresses_from_raw_parcel(dut: Any) -> None:
    """PD derives compressed selection locally and expands the raw parcel."""
    await _setup_test(dut)
    raw = _pack_compressed(
        funct3=0b000,
        quadrant=0b01,
        bits12_2=(3 << 5) | 1,
    )
    expected = _pack_i(imm=1, rs1=3, funct3=0, rd=3, opcode=OPC_OP_IMM)

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": raw,
            "sel_nop": False,
            "sel_compressed": False,
            "effective_instr": 0xDEADBEEF,
            "link_address": BASE_PC + 2,
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["instruction"] == expected
    assert packet["source_reg_1_early"] == 3
    assert packet["source_reg_2_early"] == 1
    assert packet["fp_source_reg_3_early"] == 0
    assert packet["illegal_instruction"] is False


@cocotb.test()
async def test_sel_nop_overrides_instruction_and_sources(dut: Any) -> None:
    """The NOP select overrides native instruction bits and source extraction."""
    await _setup_test(dut)
    instruction = _pack_r(
        funct7=0b0101010,
        rs2=24,
        rs1=23,
        funct3=0,
        rd=22,
        opcode=OPC_OP,
    )

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": instruction & 0xFFFF,
            "sel_nop": True,
            "sel_compressed": False,
            "effective_instr": instruction,
            "link_address": BASE_PC + 4,
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["program_counter"] == BASE_PC
    assert packet["instruction"] == NOP_INSTR
    assert packet["source_reg_1_early"] == 0
    assert packet["source_reg_2_early"] == 0
    assert packet["fp_source_reg_3_early"] == 0
    assert packet["illegal_instruction"] is False


@cocotb.test()
async def test_illegal_compressed_flag_ignores_nop_slots(dut: Any) -> None:
    """Illegal compressed parcels flag only when the IF packet is not a NOP."""
    await _setup_test(dut)
    zero_imm_addi4spn = (1 << 2) | 0b00
    expanded = _pack_i(imm=0, rs1=2, funct3=0, rd=9, opcode=OPC_OP_IMM)

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": zero_imm_addi4spn,
            "sel_nop": False,
            "sel_compressed": False,
            "effective_instr": 0,
            "link_address": BASE_PC + 2,
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["instruction"] == expanded
    assert packet["illegal_instruction"] is True
    assert packet["source_reg_1_early"] == 2
    assert packet["source_reg_2_early"] == 0

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 2,
            "raw_parcel": zero_imm_addi4spn,
            "sel_nop": True,
            "sel_compressed": False,
            "effective_instr": 0,
            "link_address": BASE_PC + 4,
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["instruction"] == NOP_INSTR
    assert packet["illegal_instruction"] is False
    assert packet["source_reg_1_early"] == 0
    assert packet["source_reg_2_early"] == 0


@cocotb.test()
async def test_slot2_registers_independently_and_flush_clears_both_slots(
    dut: Any,
) -> None:
    """Slot 2 registers independently, and flush clears both instruction slots."""
    await _setup_test(dut)
    slot1_instr = _pack_r(
        funct7=0,
        rs2=14,
        rs1=13,
        funct3=0,
        rd=12,
        opcode=OPC_OP,
    )
    slot2_instr = _pack_i(imm=7, rs1=9, funct3=0, rd=10, opcode=OPC_OP_IMM)

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": slot1_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": slot1_instr,
            "link_address": BASE_PC + 4,
        },
    )
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "raw_parcel": slot2_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": slot2_instr,
            "link_address": BASE_PC + 8,
            "btb_hit": True,
            "btb_predicted_taken": True,
            "ras_predicted": True,
        },
        slot2=True,
    )
    await _advance_cycle(dut)

    packet1 = _read_pd_packet(dut)
    packet2 = _read_pd_packet(dut, slot2=True)
    assert packet1["instruction"] == slot1_instr
    assert packet1["source_reg_1_early"] == 13
    assert packet1["source_reg_2_early"] == 14
    assert packet2["program_counter"] == BASE_PC + 4
    assert packet2["instruction"] == slot2_instr
    assert packet2["source_reg_1_early"] == 9
    assert packet2["source_reg_2_early"] == 7
    assert packet2["btb_hit"] is True
    assert packet2["btb_predicted_taken"] is True
    assert packet2["ras_predicted"] is True

    _drive_pipeline_ctrl(dut, {"flush": True})
    _drive_if_packet(
        dut, {"btb_hit": True, "btb_predicted_taken": True, "ras_predicted": True}
    )
    _drive_if_packet(
        dut,
        {"btb_hit": True, "btb_predicted_taken": True, "ras_predicted": True},
        slot2=True,
    )
    await _advance_cycle(dut)

    _assert_nop_slot(_read_pd_packet(dut))
    _assert_nop_slot(_read_pd_packet(dut, slot2=True))


@cocotb.test()
async def test_stall_holds_pd_to_id_outputs(dut: Any) -> None:
    """A pipeline stall holds the registered PD-to-ID output packets."""
    await _setup_test(dut)
    first_instr = _pack_r(
        funct7=0,
        rs2=12,
        rs1=11,
        funct3=0,
        rd=10,
        opcode=OPC_OP,
    )
    second_instr = _pack_i(imm=3, rs1=4, funct3=0, rd=5, opcode=OPC_OP_IMM)

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": first_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": first_instr,
            "link_address": BASE_PC + 4,
        },
    )
    await _advance_cycle(dut)
    held_packet = _read_pd_packet(dut)

    _drive_pipeline_ctrl(dut, {"stall": True})
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "raw_parcel": second_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": second_instr,
            "link_address": BASE_PC + 8,
            "btb_hit": True,
        },
    )
    await _advance_cycle(dut)

    assert _read_pd_packet(dut) == held_packet


@cocotb.test()
async def test_backward_branch_redirect_registers_and_squashes_following_cycle(
    dut: Any,
) -> None:
    """A cold backward branch redirects next cycle and squashes wrong-path PD data."""
    await _setup_test(dut)
    branch_instr = _pack_b(
        imm=-4,
        rs2=2,
        rs1=1,
        funct3=0,
        opcode=OPC_BRANCH,
    )

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": branch_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": branch_instr,
            "link_address": BASE_PC + 4,
        },
    )
    await _settle()
    assert bool(dut.o_pd_redirect.value) is False

    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["instruction"] == branch_instr
    assert packet["source_reg_1_early"] == 1
    assert packet["source_reg_2_early"] == 2
    assert bool(dut.o_pd_redirect.value) is True
    assert int(dut.o_pd_redirect_target.value) == (BASE_PC - 4) & 0xFFFFFFFF

    wrong_path_instr = _pack_r(
        funct7=0,
        rs2=16,
        rs1=15,
        funct3=0,
        rd=14,
        opcode=OPC_OP,
    )
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "raw_parcel": wrong_path_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": wrong_path_instr,
            "link_address": BASE_PC + 8,
            "btb_hit": True,
            "btb_predicted_taken": True,
            "ras_predicted": True,
        },
    )
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 8,
            "raw_parcel": wrong_path_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": wrong_path_instr,
            "link_address": BASE_PC + 12,
            "btb_hit": True,
            "btb_predicted_taken": True,
            "ras_predicted": True,
        },
        slot2=True,
    )
    await _advance_cycle(dut)

    _assert_nop_slot(_read_pd_packet(dut))
    _assert_nop_slot(_read_pd_packet(dut, slot2=True))
    assert bool(dut.o_pd_redirect.value) is False

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
import importlib.util
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from config import MASK_XLEN
from cocotb_tests.cpu_structs import (
    PIPELINE_CTRL_FIELDS,
    IF_TO_PD_FIELDS,
    PD_TO_ID_FIELDS,
)
from utils.packed_structs import (
    pack_struct as _pack_struct,
    unpack_struct as _unpack_struct,
)


CLOCK_PERIOD_NS = 10
RAS_PTR_BITS = 3
BP_DIR_IDX_BITS = 10

NOP_INSTR = 0x00000013
INSTRUCTION_SOURCE_FIELDS_MASK = (0x1F << 20) | (0x1F << 15)
INSTRUCTION_NON_SOURCE_MASK = 0xFFFFFFFF ^ INSTRUCTION_SOURCE_FIELDS_MASK
OPC_BRANCH = 0b1100011
OPC_OP_IMM = 0b0010011
OPC_OP = 0b0110011

BASE_PC = 0x80001000


def _pack_pipeline_ctrl(fields: Mapping[str, int | bool]) -> int:
    """Pack a pipeline_ctrl_t value."""
    return _pack_struct(PIPELINE_CTRL_FIELDS, fields)


def _pack_if_to_pd(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_if_to_pd_t value."""
    return _pack_struct(IF_TO_PD_FIELDS, fields)


def _rvc_rs1_rest(parcel: int, *, extra: bool = False) -> int:
    """Return the offline model's rs1_rest (or, with extra, rvc_extra) for a parcel.

    _drive_if_packet uses it for RVC sideband fields that a test leaves out.
    """
    path = (
        Path(__file__).resolve().parents[3]
        / "sw/common/generate_imem_predecode_init.py"
    )
    spec = importlib.util.spec_from_file_location("pd_predecode_model", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return int(module.rvc_extra(parcel) if extra else module.rvc_rs1_rest(parcel))


def _source_hot(instruction: int) -> int:
    """Return packed {rs2[1], rs1[2:1]} from a 32-bit instruction."""
    return (((instruction >> 21) & 1) << 2) | ((instruction >> 16) & 0x3)


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
        "btb_hit": False,
        "btb_predicted_taken": False,
        "btb_predicted_target": 0,
        "ras_predicted": False,
        "ras_predicted_target": 0,
        "ras_checkpoint_tos": 0,
        "ras_checkpoint_valid_count": 0,
        "bp_dir_taken": False,
        "bp_dir_idx": 0,
    }
    packet.update(fields)
    packet.setdefault(
        "rvc_extra_predecoded", _rvc_rs1_rest(int(packet["raw_parcel"]), extra=True)
    )
    if "source_hot_predecoded" not in fields:
        packet["source_hot_predecoded"] = _source_hot(int(packet["effective_instr"]))
    if "bits24_20_predecoded" not in fields:
        packet["bits24_20_predecoded"] = (int(packet["effective_instr"]) >> 20) & 0x1F
    if "rs1_rest_predecoded" not in fields:
        instr = int(packet["effective_instr"])
        parcel = int(packet["raw_parcel"])
        packet["rs1_rest_predecoded"] = (
            _rvc_rs1_rest(parcel)
            if parcel & 3 != 3 and not slot2
            else ((instr >> 17) & 0x6) | ((instr >> 15) & 1)
        )
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


def _pack_compressed_branch(*, imm: int, funct3: int = 0b110) -> int:
    """Pack a C.BEQZ/C.BNEZ instruction with a signed, even 9-bit offset."""
    assert -256 <= imm <= 254 and imm % 2 == 0
    offset = imm & 0x1FF
    return (
        ((funct3 & 0x7) << 13)
        | (((offset >> 8) & 0x1) << 12)
        | (((offset >> 3) & 0x3) << 10)
        | (((offset >> 6) & 0x3) << 5)
        | (((offset >> 1) & 0x3) << 3)
        | (((offset >> 5) & 0x1) << 2)
        | 0b01
    )


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
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut)
    _drive_pipeline_ctrl(dut, {"reset": True})
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    _drive_pipeline_ctrl(dut, {})
    await _settle()


def _assert_nop_slot(packet: Mapping[str, int | bool]) -> None:
    """Assert that a PD output packet contains an idle instruction slot.

    Both slots mark a bubble with inject_nop=1, and ID applies the NOP from
    that registered marker; except under reset, PD does not rewrite the
    instruction to a NOP.
    """
    assert packet["inject_nop"] == 1
    assert packet["is_compressed"] is False
    assert packet["source_reg_1_early"] == 0
    assert packet["source_reg_2_early"] == 0
    assert packet["fp_source_reg_3_early"] == 0
    assert packet["illegal_instruction"] is False
    assert packet["btb_hit"] is False
    assert packet["btb_predicted_taken"] is False
    assert packet["ras_predicted"] is False
    assert packet["bp_dir_idx"] == 0


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
            "btb_hit": True,
            "btb_predicted_taken": True,
            "btb_predicted_target": BASE_PC + 0x40,
            "ras_predicted": True,
            "ras_predicted_target": BASE_PC + 0x80,
            "ras_checkpoint_tos": 5,
            "ras_checkpoint_valid_count": 6,
            "bp_dir_idx": 0x155,
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["program_counter"] == BASE_PC
    assert packet["instruction"] == instruction
    assert packet["is_compressed"] is False
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
    assert packet["bp_dir_idx"] == 0x155


@cocotb.test()
async def test_compressed_parcel_registers_its_predecoded_expansion(dut: Any) -> None:
    """PD classifies the raw parcel itself and registers its predecoded expansion."""
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
            "source_hot_predecoded": _source_hot(expected),
            "bits24_20_predecoded": (expected >> 20) & 0x1F,
            "rs1_rest_predecoded": ((expected >> 17) & 0x6) | ((expected >> 15) & 1),
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["instruction"] == expected
    assert packet["is_compressed"] is True
    assert packet["source_reg_1_early"] == 3
    assert packet["source_reg_2_early"] == 1
    assert packet["fp_source_reg_3_early"] == 0
    assert packet["illegal_instruction"] is False


@cocotb.test()
async def test_rvc_fields_come_from_predecode_through_packet_lifecycle(
    dut: Any,
) -> None:
    """Slot 1 takes an RVC expansion from its predecoded fields, not effective_instr.

    IF's sel_compressed is ignored in both directions. The test then checks
    stall hold, flush, a sel_nop bubble, and reset under stall on these packets.
    """
    await _setup_test(dut)
    # Expected expansions are written out by hand, independent of the model.
    # They include the bit-20 special cases: 1 for C.EBREAK, 0 for C.ADDI16SP
    # and for the reserved arithmetic encoding.
    compressed_cases = (
        (0x0185, 0x00118193, False),  # C.ADDI x3, 1
        (0x0189, 0x00218193, False),  # C.ADDI x3, 2
        (0x7181, 0xFFFE01B7, False),  # C.LUI x3, -32
        (0x7101, 0xE0010113, False),  # C.ADDI16SP -512 (rd == x2)
        (0x9002, 0x00100073, False),  # C.EBREAK
        (0x9C41, 0x00000000, True),  # Reserved RV64 arithmetic sub-op
        (0xC004, 0x00942023, False),  # C.SW x9, 0(x8)
        (0x8182, 0x00018067, False),  # C.JR x3
        (0x9182, 0x000180E7, False),  # C.JALR x3
    )

    def drive_compressed(raw: int, expected: int, *, bubble: bool = False) -> None:
        native_canary = _pack_r(
            funct7=0x55,
            rs2=6 | (1 ^ ((expected >> 20) & 1)),
            rs1=17,
            funct3=5,
            rd=18,
            opcode=OPC_OP,
        )
        assert ((native_canary ^ expected) >> 20) & 1
        _drive_if_packet(
            dut,
            {
                "raw_parcel": raw,
                "effective_instr": native_canary,
                "sel_nop": bubble,
                "sel_compressed": False,  # PD must use its local raw classifier.
                "source_hot_predecoded": _source_hot(expected),
                "bits24_20_predecoded": (expected >> 20) & 0x1F,
                "rs1_rest_predecoded": ((expected >> 17) & 0x6)
                | ((expected >> 15) & 1),
            },
        )

    for raw, expected, illegal in compressed_cases:
        drive_compressed(raw, expected)
        await _advance_cycle(dut)
        packet = _read_pd_packet(dut)
        assert packet["instruction"] == expected, hex(raw)
        assert packet["source_reg_2_early"] == (expected >> 20) & 0x1F
        assert packet["is_compressed"] is True
        assert packet["illegal_instruction"] is illegal
        assert packet["inject_nop"] is False

    for rs2 in (6, 7):
        native = _pack_r(funct7=0x21, rs2=rs2, rs1=13, funct3=0, rd=11, opcode=OPC_OP)
        _drive_if_packet(
            dut,
            {
                "raw_parcel": native & 0xFFFF,
                "effective_instr": native,
                "sel_nop": False,
                "sel_compressed": True,  # The unused IF sideband cannot select RVC.
            },
        )
        await _advance_cycle(dut)
        packet = _read_pd_packet(dut)
        assert packet["instruction"] == native
        assert packet["source_reg_2_early"] == rs2
        assert packet["is_compressed"] is False

    drive_compressed(0x9002, 0x00100073)
    await _advance_cycle(dut)
    held = _read_pd_packet(dut)
    _drive_pipeline_ctrl(dut, {"stall": True})
    drive_compressed(0x7101, 0xE0010113)
    await _advance_cycle(dut)
    assert _read_pd_packet(dut) == held
    _drive_pipeline_ctrl(dut, {"stall": True, "flush": True})
    await _advance_cycle(dut)
    assert _read_pd_packet(dut) == held

    _drive_pipeline_ctrl(dut, {"flush": True})
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut)
    assert packet["instruction"] == 0xE0010113
    assert packet["source_reg_2_early"] == 0
    assert packet["inject_nop"] is True

    _drive_pipeline_ctrl(dut, {})
    drive_compressed(0x9002, 0x00100073, bubble=True)
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut)
    assert packet["instruction"] == 0x00100073
    assert packet["source_reg_2_early"] == 0
    assert packet["inject_nop"] is True

    drive_compressed(0x9002, 0x00100073)
    await _advance_cycle(dut)
    assert _read_pd_packet(dut)["source_reg_2_early"] == 1
    _drive_pipeline_ctrl(dut, {"reset": True, "stall": True})
    drive_compressed(0x7101, 0xE0010113)
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut)
    assert packet["instruction"] == NOP_INSTR
    assert packet["inject_nop"] is True
    # Slot 1's early source registers have no reset, so a stall holds them even
    # while reset writes the NOP and sets inject_nop. Their value is ignored
    # while inject_nop marks the bubble.
    assert packet["source_reg_2_early"] == 1
    _drive_pipeline_ctrl(dut, {})
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut)
    assert packet["instruction"] == 0xE0010113
    assert packet["source_reg_2_early"] == 0
    assert packet["inject_nop"] is False


@cocotb.test()
async def test_sel_nop_overrides_instruction_and_sources(dut: Any) -> None:
    """The NOP select marks a bubble via inject_nop and zeroes source extraction."""
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
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert packet["program_counter"] == BASE_PC
    assert (
        packet["inject_nop"] == 1
    )  # slot-1 marks a bubble via inject_nop (instruction passes through un-NOP'd)
    assert packet["is_compressed"] is False
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
            "source_hot_predecoded": _source_hot(expanded),
            "bits24_20_predecoded": (expanded >> 20) & 0x1F,
            "rs1_rest_predecoded": ((expanded >> 17) & 0x6) | ((expanded >> 15) & 1),
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
        },
    )
    await _advance_cycle(dut)

    packet = _read_pd_packet(dut)
    assert (
        packet["inject_nop"] == 1
    )  # slot-1 marks a bubble via inject_nop (instruction passes through un-NOP'd)
    assert packet["illegal_instruction"] is False
    assert packet["source_reg_1_early"] == 0
    assert packet["source_reg_2_early"] == 0


@cocotb.test()
async def test_rvc_illegal_flag_comes_from_predecode_through_packet_lifecycle(
    dut: Any,
) -> None:
    """Slot 1's illegal flag comes from the predecoded RVC illegal bit.

    PD's own compressed classifier qualifies it. IF's sel_compressed and the
    decomp_illegal field, which only slot 2 uses, do not affect it, and it
    follows the packet's stall, flush, bubble, and reset rules.
    """
    await _setup_test(dut)

    def drive(raw: int, expected: int, *, bubble: bool = False) -> None:
        _drive_if_packet(
            dut,
            {
                "raw_parcel": raw,
                "effective_instr": expected if raw & 3 == 3 else NOP_INSTR,
                "sel_nop": bubble,
                "sel_compressed": raw & 3 == 3,  # Oppose the local classifier.
                "decomp_illegal": True,  # Slot 1 must not use slot 2's sideband.
                "source_hot_predecoded": _source_hot(expected),
                "bits24_20_predecoded": (expected >> 20) & 0x1F,
                "rs1_rest_predecoded": ((expected >> 17) & 0x6)
                | ((expected >> 15) & 1),
            },
        )

    cases = (
        (0x0004, 0x00010493, True),  # C.ADDI4SPN with reserved zero immediate.
        (0x0185, 0x00118193, False),  # Legal C.ADDI x3, 1.
        (0x9C41, 0x00000000, True),  # Reserved RV64 arithmetic sub-op.
        (0x9002, 0x00100073, False),  # C.EBREAK remains legal here.
        (0x0013, NOP_INSTR, False),  # Native ADDI; ignore compressed sidebands.
    )
    for raw, expected, illegal in cases:
        drive(raw, expected)
        await _advance_cycle(dut)
        packet = _read_pd_packet(dut)
        assert packet["instruction"] == expected
        assert packet["illegal_instruction"] is illegal
        assert packet["is_compressed"] is (raw & 3 != 3)
        assert packet["inject_nop"] is False

    drive(0x9C41, 0)
    await _advance_cycle(dut)
    held = _read_pd_packet(dut)
    assert held["illegal_instruction"] is True
    drive(0x9002, 0x00100073)
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _advance_cycle(dut)
    assert _read_pd_packet(dut) == held
    _drive_pipeline_ctrl(dut, {"stall": True, "flush": True})
    await _advance_cycle(dut)
    assert _read_pd_packet(dut) == held

    # Releasing the stall with flush suppresses even a currently illegal parcel.
    drive(0x9C41, 0)
    _drive_pipeline_ctrl(dut, {"flush": True})
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut)
    assert packet["instruction"] == 0
    assert packet["inject_nop"] is True
    assert packet["illegal_instruction"] is False
    _drive_pipeline_ctrl(dut, {})
    drive(0x0004, 0x00010493, bubble=True)
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut)
    assert packet["instruction"] == 0x00010493
    assert packet["inject_nop"] is True
    assert packet["illegal_instruction"] is False

    drive(0x9C41, 0)
    await _advance_cycle(dut)
    assert _read_pd_packet(dut)["illegal_instruction"] is True
    _drive_pipeline_ctrl(dut, {"reset": True, "stall": True})
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut)
    assert packet["instruction"] == NOP_INSTR
    assert packet["inject_nop"] is True
    assert packet["illegal_instruction"] is False
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _advance_cycle(dut)
    assert _read_pd_packet(dut) == packet
    _drive_pipeline_ctrl(dut, {})
    await _advance_cycle(dut)
    assert _read_pd_packet(dut)["illegal_instruction"] is True


@cocotb.test()
async def test_slot2_registers_independently_and_flush_marks_both_slots(
    dut: Any,
) -> None:
    """Slot 2 registers independently, and flush marks both slots as bubbles."""
    await _setup_test(dut)
    slot1_instr = _pack_r(
        funct7=0,
        rs2=14,
        rs1=13,
        funct3=0,
        rd=12,
        opcode=OPC_OP,
    )
    # Give every field of the reassembled slot-2 instruction a distinct value,
    # including bits [31:27], which also feed fp_source_reg_3_early.
    slot2_instr = _pack_r(
        funct7=0b1011010,
        rs2=7,
        rs1=11,
        funct3=0,
        rd=10,
        opcode=OPC_OP,
    )

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": slot1_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": slot1_instr,
        },
    )
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "raw_parcel": slot2_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": slot2_instr,
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
    assert packet2["inject_nop"] == 0
    assert packet2["source_reg_1_early"] == 11
    assert packet2["source_reg_2_early"] == 7
    assert packet2["fp_source_reg_3_early"] == 0b10110
    assert packet2["btb_hit"] is True
    assert packet2["btb_predicted_taken"] is True
    assert packet2["ras_predicted"] is True

    _drive_pipeline_ctrl(dut, {"flush": True})
    _drive_if_packet(
        dut, {"btb_hit": True, "btb_predicted_taken": True, "ras_predicted": True}
    )
    _drive_if_packet(
        dut,
        {
            "raw_parcel": slot2_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": slot2_instr,
            "btb_hit": True,
            "btb_predicted_taken": True,
            "ras_predicted": True,
        },
        slot2=True,
    )
    await _advance_cycle(dut)

    _assert_nop_slot(_read_pd_packet(dut))
    packet2 = _read_pd_packet(dut, slot2=True)
    _assert_nop_slot(packet2)
    # The flush does not rewrite the instruction to a NOP: its non-source bits
    # keep the payload, and only the separately cleared source fields read x0.
    assert (
        int(packet2["instruction"]) & INSTRUCTION_NON_SOURCE_MASK
        == slot2_instr & INSTRUCTION_NON_SOURCE_MASK
    )


@cocotb.test()
async def test_slot2_early_sources_clear_only_when_bundle_advances(dut: Any) -> None:
    """Slot-2 bubble control and source clears stay aligned across a stall."""
    await _setup_test(dut)
    first_instr = _pack_r(
        funct7=0,
        rs2=19,
        rs1=18,
        funct3=0,
        rd=17,
        opcode=OPC_OP,
    )
    bubble_payload = _pack_r(
        funct7=0,
        rs2=7,
        rs1=6,
        funct3=0,
        rd=5,
        opcode=OPC_OP,
    )

    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "raw_parcel": first_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": first_instr,
            "decomp_illegal": True,
        },
        slot2=True,
    )
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut, slot2=True)
    assert packet["inject_nop"] == 0
    assert packet["source_reg_1_early"] == 18
    assert packet["source_reg_2_early"] == 19
    assert packet["illegal_instruction"] is True

    # A bubble that arrives during a held cycle cannot clear the held source
    # addresses. The same bubble clears them when the bundle advances.
    _drive_pipeline_ctrl(dut, {"stall": True})
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 8,
            "raw_parcel": bubble_payload & 0xFFFF,
            "sel_nop": True,
            "effective_instr": bubble_payload,
            "decomp_illegal": False,
        },
        slot2=True,
    )
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut, slot2=True)
    assert packet["inject_nop"] == 0
    assert packet["source_reg_1_early"] == 18
    assert packet["source_reg_2_early"] == 19
    assert packet["illegal_instruction"] is True

    _drive_pipeline_ctrl(dut, {})
    await _advance_cycle(dut)
    packet = _read_pd_packet(dut, slot2=True)
    assert packet["inject_nop"] == 1
    assert (
        int(packet["instruction"]) & INSTRUCTION_NON_SOURCE_MASK
        == bubble_payload & INSTRUCTION_NON_SOURCE_MASK
    )
    assert packet["source_reg_1_early"] == 0
    assert packet["source_reg_2_early"] == 0
    assert packet["fp_source_reg_3_early"] == 0
    assert packet["illegal_instruction"] is False


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
            "btb_hit": True,
        },
    )
    await _advance_cycle(dut)

    assert _read_pd_packet(dut) == held_packet


@cocotb.test()
async def test_direction_predicted_branch_masks_wrong_path_candidate_across_stall(
    dut: Any,
) -> None:
    """The redirect's bubble masks a wrong-path branch candidate, even under stall."""
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
            "bp_dir_taken": True,
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
    assert int(dut.o_pd_redirect_target.value) == (BASE_PC - 4) & MASK_XLEN

    # Make the wrong-path payload another predicted-taken branch. The candidate
    # register captures its branch && direction with no vetoes, and the same
    # edge records the older redirect in inject_nop. That registered bubble
    # must mask the candidate, including while a stall holds both.
    wrong_path_instr = _pack_b(
        imm=8,
        rs2=16,
        rs1=15,
        funct3=1,
        opcode=OPC_BRANCH,
    )
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "raw_parcel": wrong_path_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": wrong_path_instr,
            "bp_dir_taken": True,
        },
    )
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC + 8,
            "raw_parcel": wrong_path_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": wrong_path_instr,
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

    target_pc = BASE_PC - 4
    target_offset = -2
    target_instr = _pack_compressed_branch(imm=target_offset)
    _drive_pipeline_ctrl(dut, {"stall": True})
    _drive_if_packet(
        dut,
        {
            "program_counter": target_pc,
            "raw_parcel": target_instr,
            "sel_nop": False,
            "effective_instr": target_instr,
            "bp_dir_taken": True,
        },
    )
    await _advance_cycle(dut)

    _assert_nop_slot(_read_pd_packet(dut))
    _assert_nop_slot(_read_pd_packet(dut, slot2=True))
    assert bool(dut.o_pd_redirect.value) is False

    # Releasing the stall replaces the candidate and the mask on the same edge,
    # so the predicted-taken branch at the redirect target redirects at once.
    _drive_pipeline_ctrl(dut, {})
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) is True
    assert (
        int(dut.o_pd_redirect_target.value) == (target_pc + target_offset) & MASK_XLEN
    )


@cocotb.test()
async def test_unqualified_redirect_candidate_keeps_all_visible_vetoes(
    dut: Any,
) -> None:
    """Each registered packet veto, flush, and reset suppresses the PD redirect."""
    await _setup_test(dut)
    branch_instr = _pack_b(
        imm=8,
        rs2=2,
        rs1=1,
        funct3=0,
        opcode=OPC_BRANCH,
    )
    valid_nonbranch = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)

    # Each veto arrives with a predicted-taken branch, so only the veto's
    # registered copy in the packet can suppress the redirect.
    vetoes = [
        {"btb_hit": True, "btb_predicted_taken": True},
        {"ras_predicted": True},
        {"sel_nop": True},
        {"fetch_fault": True},
    ]
    for veto in vetoes:
        packet = {
            "program_counter": BASE_PC,
            "raw_parcel": branch_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": branch_instr,
            "bp_dir_taken": True,
        }
        packet.update(veto)
        _drive_if_packet(dut, packet)
        await _advance_cycle(dut)
        assert bool(dut.o_pd_redirect.value) is False

        # Clear candidate and packet veto together before the next case.
        _drive_if_packet(
            dut,
            {
                "program_counter": BASE_PC + 4,
                "raw_parcel": valid_nonbranch & 0xFFFF,
                "sel_nop": False,
                "effective_instr": valid_nonbranch,
            },
        )
        await _advance_cycle(dut)
        assert bool(dut.o_pd_redirect.value) is False

    # Flush and reset clear the candidate even during a stall. Keep a
    # predicted-taken branch on the input in both cases so an idle input cannot
    # hide stale state.
    _drive_pipeline_ctrl(dut, {"flush": True, "stall": True})
    _drive_if_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "raw_parcel": branch_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": branch_instr,
            "bp_dir_taken": True,
        },
    )
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) is False

    _drive_pipeline_ctrl(dut, {"reset": True, "stall": True})
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) is False

    # With reset removed, stall still holds the cleared candidate and reset
    # packet. The waiting branch becomes visible only on the released edge.
    _drive_pipeline_ctrl(dut, {"stall": True})
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) is False

    _drive_pipeline_ctrl(dut, {})
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) is True


@cocotb.test()
async def test_direction_redirect_target_split_boundary_cases(dut: Any) -> None:
    """The split redirect target stays exact across carry, sign, format, and stall."""
    await _setup_test(dut)

    pc_chunk_base = 0x123456789ABC0000 & MASK_XLEN
    native_cases = [
        (pc_chunk_base, 2),  # sign=0, carry=0
        (pc_chunk_base + 0x1FFE, 2),  # sign=0, carry=1
        (pc_chunk_base, -2),  # sign=1, carry=0
        (pc_chunk_base + 2, -2),  # sign=1, carry=1
        (pc_chunk_base, 4094),
        (pc_chunk_base + 0x1000, -4096),
        (MASK_XLEN - 1, 2),  # modulo-XLEN positive wrap
        (0, -2),  # modulo-XLEN negative wrap
    ]
    compressed_cases = [
        (pc_chunk_base, 2),
        (pc_chunk_base + 0x1FFE, 2),
        (pc_chunk_base, -2),
        (pc_chunk_base + 2, -2),
        (pc_chunk_base, 254),
        (pc_chunk_base, -256),
        (MASK_XLEN - 1, 2),  # modulo-XLEN positive wrap
        (0, -2),  # modulo-XLEN negative wrap
    ]

    for pc, offset in native_cases:
        instruction = _pack_b(
            imm=offset,
            rs2=2,
            rs1=1,
            funct3=0,
            opcode=OPC_BRANCH,
        )
        _drive_if_packet(
            dut,
            {
                "program_counter": pc,
                "raw_parcel": instruction & 0xFFFF,
                "sel_nop": False,
                "effective_instr": instruction,
                "bp_dir_taken": True,
            },
        )
        await _advance_cycle(dut)
        assert bool(dut.o_pd_redirect.value) is True
        assert int(dut.o_pd_redirect_target.value) == (pc + offset) & MASK_XLEN

        _drive_if_packet(dut, {})
        await _advance_cycle(dut)
        assert bool(dut.o_pd_redirect.value) is False

    for pc, offset in compressed_cases:
        instruction = _pack_compressed_branch(imm=offset)
        _drive_if_packet(
            dut,
            {
                "program_counter": pc,
                "raw_parcel": instruction,
                "sel_nop": False,
                "effective_instr": instruction,
                "bp_dir_taken": True,
            },
        )
        await _advance_cycle(dut)
        assert bool(dut.o_pd_redirect.value) is True
        assert int(dut.o_pd_redirect_target.value) == (pc + offset) & MASK_XLEN

        _drive_if_packet(dut, {})
        await _advance_cycle(dut)
        assert bool(dut.o_pd_redirect.value) is False

    # Switch formats on consecutive edges, with no bubble between them: a native
    # branch computes a target without redirecting, then a compressed branch
    # redirects. This catches the low-result and {sign, carry} registers
    # capturing on different edges.
    native_pc = pc_chunk_base + 0x1FFE
    native_offset = 2
    native_instruction = _pack_b(
        imm=native_offset,
        rs2=2,
        rs1=1,
        funct3=0,
        opcode=OPC_BRANCH,
    )
    _drive_if_packet(
        dut,
        {
            "program_counter": native_pc,
            "raw_parcel": native_instruction & 0xFFFF,
            "sel_nop": False,
            "effective_instr": native_instruction,
            "bp_dir_taken": False,
        },
    )
    await _advance_cycle(dut)
    assert not dut.o_pd_redirect.value
    assert (
        int(dut.o_pd_redirect_target.value) == (native_pc + native_offset) & MASK_XLEN
    )

    compressed_pc = pc_chunk_base
    compressed_offset = -2
    compressed_instruction = _pack_compressed_branch(imm=compressed_offset)
    _drive_if_packet(
        dut,
        {
            "program_counter": compressed_pc,
            "raw_parcel": compressed_instruction,
            "sel_nop": False,
            "effective_instr": compressed_instruction,
            "bp_dir_taken": True,
        },
    )
    await _advance_cycle(dut)
    assert dut.o_pd_redirect.value
    assert (
        int(dut.o_pd_redirect_target.value)
        == (compressed_pc + compressed_offset) & MASK_XLEN
    )

    _drive_if_packet(dut, {})
    await _advance_cycle(dut)
    assert not dut.o_pd_redirect.value

    # The redirect and target registers share the !stall enable: a predicted
    # branch presented during a stall changes neither output, and both capture
    # it on the first edge after the stall.
    held_pc = pc_chunk_base + 0x1FFE
    held_offset = 2
    held_instruction = _pack_b(
        imm=held_offset,
        rs2=4,
        rs1=3,
        funct3=1,
        opcode=OPC_BRANCH,
    )
    _drive_if_packet(
        dut,
        {
            "program_counter": held_pc,
            "raw_parcel": held_instruction & 0xFFFF,
            "sel_nop": False,
            "effective_instr": held_instruction,
        },
    )
    await _advance_cycle(dut)
    held_target = (held_pc + held_offset) & MASK_XLEN
    assert bool(dut.o_pd_redirect.value) is False
    assert int(dut.o_pd_redirect_target.value) == held_target

    released_pc = pc_chunk_base
    released_offset = -2
    released_instruction = _pack_compressed_branch(
        imm=released_offset,
        funct3=0b111,
    )
    _drive_pipeline_ctrl(dut, {"stall": True})
    _drive_if_packet(
        dut,
        {
            "program_counter": released_pc,
            "raw_parcel": released_instruction,
            "sel_nop": False,
            "effective_instr": released_instruction,
            "bp_dir_taken": True,
        },
    )
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) is False
    assert int(dut.o_pd_redirect_target.value) == held_target

    _drive_pipeline_ctrl(dut, {})
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) is True
    assert (
        int(dut.o_pd_redirect_target.value)
        == (released_pc + released_offset) & MASK_XLEN
    )

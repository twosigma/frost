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
    IF_TO_PD_FIELDS,
    PD_TARGET_SPLIT,
    PD_TO_ID_FIELDS,
    PIPELINE_CTRL_FIELDS,
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


def _native_branch_imm_low(instruction: int) -> int:
    """Return the low PD_TARGET_SPLIT bits of a B-type offset."""
    return (
        (((instruction >> 31) & 1) << 12)
        | (((instruction >> 7) & 1) << 11)
        | (((instruction >> 25) & 0x3F) << 5)
        | (((instruction >> 8) & 0xF) << 1)
    )


def _compressed_branch_imm_low(parcel: int) -> int:
    """Return the low PD_TARGET_SPLIT bits of a sign-extended C.BEQZ/C.BNEZ offset."""
    sign = (parcel >> 12) & 1
    return (
        (sign * 0x1F) << 8
        | (((parcel >> 5) & 0x3) << 6)
        | (((parcel >> 2) & 1) << 5)
        | (((parcel >> 10) & 0x3) << 3)
        | (((parcel >> 3) & 0x3) << 1)
    )


def _target_candidate(pc: int, imm_low: int) -> tuple[int, int]:
    """Return IF's (low sum, {sign, carry} select) target candidate for pc + offset."""
    low_sum = (pc & ((1 << PD_TARGET_SPLIT) - 1)) + imm_low
    high_select = (((imm_low >> (PD_TARGET_SPLIT - 1)) & 1) << 1) | (
        (low_sum >> PD_TARGET_SPLIT) & 1
    )
    return low_sum & ((1 << PD_TARGET_SPLIT) - 1), high_select


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
        "program_counter": 4 if slot2 else 0,
        "raw_parcel": NOP_INSTR & 0xFFFF,
        "sel_nop": True,
        "sel_compressed": False,
        "effective_instr": NOP_INSTR,
        "btb_predicted_taken": False,
        "btb_predicted_target": 0,
        "ras_checkpoint_tos": 0,
        "ras_checkpoint_valid_count": 0,
        "ras_checkpoint_top": 0,
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
    if "is_cond_branch" not in fields:
        packet["is_cond_branch"] = (
            (int(packet["effective_instr"]) & 0x7F) == OPC_BRANCH if slot2 else False
        )
    # IF carries the PD redirect's target candidates for both slots.
    pc = int(packet["program_counter"])
    if "pd_target_native_low" not in fields:
        low, select = _target_candidate(
            pc, _native_branch_imm_low(int(packet["effective_instr"]))
        )
        packet["pd_target_native_low"] = low
        packet["pd_target_native_high_select"] = select
    if "pd_target_compressed_low" not in fields:
        low, select = _target_candidate(
            pc, _compressed_branch_imm_low(int(packet["raw_parcel"]))
        )
        packet["pd_target_compressed_low"] = low
        packet["pd_target_compressed_high_select"] = select
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


def _drive_backing(
    dut: Any,
    slot: int | None = None,
    *,
    target: int = 0,
    compressed: bool = False,
    is_return: bool = False,
    size_select: bool | None = None,
) -> None:
    """Drive IF's backing BTB result: a hit in one slot, or none.

    Slot 2's return type and target also drive the per-size inputs: at both
    sizes of slot 1, or, with size_select, at that size only, with a different
    entry at the other size.
    """
    width = len(dut.i_backing_target) // 2
    mask = (1 << width) - 1
    dut.i_backing_hit.value = 0 if slot is None else 1 << slot
    dut.i_backing_compressed.value = int(compressed) << (slot or 0)
    dut.i_backing_return.value = int(is_return and slot is not None) << (slot or 0)
    value = ((target >> 1) & mask) << (width * (slot or 0))
    dut.i_backing_target.value = value if slot is not None else 0
    returns = [int(is_return and slot == 1)] * 2
    targets = [(target >> 1) & mask if slot == 1 else 0] * 2
    if size_select is not None:
        other = int(not size_select)
        returns[other] ^= 1
        targets[other] ^= mask
    dut.i_backing_slot2_return_by_size.value = returns[0] | (returns[1] << 1)
    dut.i_backing_slot2_target_by_size.value = targets[0] | (targets[1] << width)


def _clear_inputs(dut: Any) -> None:
    """Drive all PD-stage inputs to idle values."""
    _drive_pipeline_ctrl(dut, {})
    _drive_if_packet(dut, {})
    _drive_if_packet(dut, {}, slot2=True)
    _drive_backing(dut)
    dut.i_itt_hit.value = 0
    dut.i_itt_target.value = 0


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
    assert packet["illegal_instruction"] is False
    assert packet["btb_predicted_taken"] is False
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
            "btb_predicted_taken": True,
            "btb_predicted_target": BASE_PC + 0x40,
            "ras_checkpoint_tos": 5,
            "ras_checkpoint_valid_count": 6,
            "ras_checkpoint_top": BASE_PC + 0x104,
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
    assert packet["illegal_instruction"] is False
    assert packet["btb_predicted_taken"] is True
    assert packet["btb_predicted_target"] == BASE_PC + 0x40
    assert packet["ras_checkpoint_tos"] == 5
    assert packet["ras_checkpoint_valid_count"] == 6
    assert packet["ras_checkpoint_top"] == BASE_PC + 0x104
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
        (0x9C41, 0x02840433, False),  # Zcb C.MUL x8, x8, x8
        (0x9C79, 0x00000000, True),  # Reserved Zcb unary selector 110
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
    )  # inject_nop marks the bubble; the instruction passes through
    assert packet["is_compressed"] is False
    assert packet["source_reg_1_early"] == 0
    assert packet["source_reg_2_early"] == 0
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
    )  # inject_nop marks the bubble; the instruction passes through
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
        (0x9C79, 0x00000000, True),  # Reserved Zcb unary selector 110.
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

    drive(0x9C79, 0)
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
    drive(0x9C79, 0)
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

    drive(0x9C79, 0)
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
    # Give every field of the reassembled slot-2 instruction a distinct value.
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
            "btb_predicted_taken": True,
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
    assert packet2["btb_predicted_taken"] is True

    _drive_pipeline_ctrl(dut, {"flush": True})
    _drive_if_packet(dut, {"btb_predicted_taken": True})
    _drive_if_packet(
        dut,
        {
            "raw_parcel": slot2_instr & 0xFFFF,
            "sel_nop": False,
            "effective_instr": slot2_instr,
            "btb_predicted_taken": True,
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

    _drive_if_packet(dut, _packet(BASE_PC, NOP_INSTR))
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
            "btb_predicted_taken": True,
        },
        slot2=True,
    )
    await _advance_cycle(dut)

    _assert_nop_slot(_read_pd_packet(dut))
    _assert_nop_slot(_read_pd_packet(dut, slot2=True))
    assert bool(dut.o_pd_redirect.value) is False

    _drive_if_packet(dut, {}, slot2=True)
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
async def test_tagged_direction_overrides_btb_both_ways(dut: Any) -> None:
    """The tagged direction replaces the BTB and bimodal directions.

    Not taken after a taken BTB prediction redirects to the fall-through,
    native and compressed; taken without a taken BTB prediction redirects to
    the branch target even when the bimodal says not taken. Agreement with the
    BTB never redirects.
    """
    await _setup_test(dut)
    native = _pack_b(imm=-16, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    compressed = _pack_compressed_branch(imm=-6)

    cases = [
        # (instr, raw parcel, compressed, btb taken, tage taken, bimodal, redirect,
        #  taken, target)
        (native, native & 0xFFFF, False, True, False, True, True, False, BASE_PC + 4),
        (compressed, compressed, True, True, False, True, True, False, BASE_PC + 2),
        (native, native & 0xFFFF, False, False, True, False, True, True, BASE_PC - 16),
        (native, native & 0xFFFF, False, True, True, False, False, None, None),
        (native, native & 0xFFFF, False, False, False, True, False, None, None),
    ]
    for (
        instr,
        parcel,
        is_compressed,
        btb_taken,
        tage_taken,
        bimodal,
        redirect,
        taken,
        target,
    ) in cases:
        _drive_pipeline_ctrl(dut, {"flush": True})
        await _advance_cycle(dut)
        _drive_pipeline_ctrl(dut, {})
        _drive_if_packet(
            dut,
            {
                "program_counter": BASE_PC,
                "raw_parcel": parcel,
                "sel_nop": False,
                "sel_compressed": is_compressed,
                "effective_instr": instr,
                "btb_predicted_taken": btb_taken,
                "btb_predicted_target": BASE_PC - 16 if btb_taken else 0,
                "bp_dir_taken": bimodal,
                "tage_valid": True,
                "tage_taken": tage_taken,
            },
        )
        await _advance_cycle(dut)

        assert bool(dut.o_pd_redirect.value) is redirect
        if redirect:
            assert target is not None
            assert bool(dut.o_pd_redirect_taken.value) is taken
            assert int(dut.o_pd_redirect_target.value) == target & MASK_XLEN


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
        {"btb_predicted_taken": True},
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

    # Flush and reset clear the candidate even under stall. Keep a branch
    # predicted taken on the input so idle data cannot hide stale state.
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


OPC_JAL = 0b1101111
OPC_JALR = 0b1100111


def _pack_jal(*, imm: int, rd: int) -> int:
    """Pack a JAL instruction with a signed, even offset."""
    offset = imm & 0x1FFFFF
    return (
        (((offset >> 20) & 1) << 31)
        | (((offset >> 1) & 0x3FF) << 21)
        | (((offset >> 11) & 1) << 20)
        | (((offset >> 12) & 0xFF) << 12)
        | ((rd & 0x1F) << 7)
        | OPC_JAL
    )


def _packet(pc: int, instruction: int, **fields: int | bool) -> dict[str, int | bool]:
    """Return a valid native slot packet."""
    packet: dict[str, int | bool] = {
        "program_counter": pc,
        "raw_parcel": instruction & 0xFFFF,
        "sel_nop": False,
        "effective_instr": instruction,
    }
    packet.update(fields)
    return packet


async def _backing_redirect(dut: Any) -> tuple[bool, bool, int, bool]:
    """Register the driven packet, then read the redirect and idle the inputs."""
    await _advance_cycle(dut)
    result = (
        bool(dut.o_pd_redirect.value),
        bool(dut.o_pd_redirect_taken.value),
        int(dut.o_pd_redirect_target.value),
        bool(dut.o_pd_redirect_slot2.value),
    )
    _clear_inputs(dut)
    await _advance_cycle(dut)
    return result


@cocotb.test()
async def test_backing_btb_redirects_unpredicted_jumps(dut: Any) -> None:
    """A slot-1 JAL or JALR with a backing hit redirects to its target."""
    await _setup_test(dut)
    pc = 0x8000_0200
    target = 0x8000_0F40
    jalr = _pack_i(imm=0, rs1=5, funct3=0, rd=0, opcode=OPC_JALR)
    for instruction in (_pack_jal(imm=0x40, rd=0), jalr):
        _drive_if_packet(dut, _packet(pc, instruction))
        _drive_backing(dut, 0, target=target)
        redirect, taken, redirect_target, slot2 = await _backing_redirect(dut)
        assert redirect and taken and not slot2
        assert redirect_target == target

    # The target's upper bits come from the branch's 4 GiB region.
    high_pc = 0x1_8000_0200
    _drive_if_packet(dut, _packet(high_pc, _pack_jal(imm=0x40, rd=0)))
    _drive_backing(dut, 0, target=target)
    redirect, _, redirect_target, _ = await _backing_redirect(dut)
    assert redirect and redirect_target == (0x1_0000_0000 | target) & MASK_XLEN


@cocotb.test()
async def test_backing_btb_redirect_vetoes(dut: Any) -> None:
    """Fast-taken, size mismatch, non-jumps, bubbles and faults never redirect."""
    await _setup_test(dut)
    pc = 0x8000_0200
    target = 0x8000_0F40
    jal = _pack_jal(imm=0x40, rd=0)
    branch = _pack_b(imm=8, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    cases = [
        (
            _packet(pc, jal, btb_predicted_taken=True, btb_predicted_target=target),
            False,
        ),
        (_packet(pc, jal), True),
        (_packet(pc, branch), False),
        (_packet(pc, addi), False),
        (_packet(pc, jal, sel_nop=True), False),
        (_packet(pc, jal, fetch_fault=True), False),
    ]
    for packet, size_compressed in cases:
        _drive_if_packet(dut, packet)
        _drive_backing(dut, 0, target=target, compressed=size_compressed)
        redirect, _, _, _ = await _backing_redirect(dut)
        assert not redirect, packet


@cocotb.test()
async def test_backing_btb_calls_and_returns_operate_the_stack(dut: Any) -> None:
    """A call pushes its link, a return pops and targets the stack's top."""
    await _setup_test(dut)
    pc = 0x8000_0200
    target = 0x8000_0F40
    top = 0x8000_1234
    jal_ra = _pack_jal(imm=0x40, rd=1)
    ret = _pack_i(imm=0, rs1=1, funct3=0, rd=0, opcode=OPC_JALR)
    swap = _pack_i(imm=0, rs1=1, funct3=0, rd=5, opcode=OPC_JALR)
    jalr_ra_offset = _pack_i(imm=8, rs1=1, funct3=0, rd=0, opcode=OPC_JALR)
    jal = _pack_jal(imm=0x40, rd=0)
    cases = [
        # instruction, entry is a return, stack entries, expected target,
        # push, pop
        (jal_ra, False, 2, target, True, False),
        (ret, True, 2, top, False, True),
        (ret, True, 0, target, False, True),
        (swap, True, 1, top, True, True),
        (jalr_ra_offset, False, 2, target, False, False),
        # An entry whose type does not match its instruction picks the
        # target by its type; the stack operation follows the instruction.
        (jal, True, 2, top, False, False),
        (ret, False, 2, target, False, True),
    ]
    # A return-shaped JALR with a nonzero funct3 is not a jump at all.
    for funct3 in (1, 4):
        illegal = _pack_i(imm=0, rs1=1, funct3=funct3, rd=0, opcode=OPC_JALR)
        _drive_if_packet(dut, _packet(pc, illegal, ras_checkpoint_valid_count=2))
        _drive_backing(dut, 0, target=target)
        redirect, _, _, _ = await _backing_redirect(dut)
        assert not redirect
        assert not bool(dut.o_pd_redirect_ras_pop.value)
    for instruction, entry_return, entries, expected, push, pop in cases:
        _drive_if_packet(
            dut,
            _packet(
                pc,
                instruction,
                ras_checkpoint_valid_count=entries,
                ras_checkpoint_top=top,
            ),
        )
        _drive_backing(dut, 0, target=target, is_return=entry_return)
        await _advance_cycle(dut)
        assert bool(dut.o_pd_redirect.value), hex(instruction)
        assert int(dut.o_pd_redirect_target.value) == expected, hex(instruction)
        assert bool(dut.o_pd_redirect_ras_push.value) is push, hex(instruction)
        assert bool(dut.o_pd_redirect_ras_pop.value) is pop, hex(instruction)
        if push:
            assert int(dut.o_pd_redirect_ras_link.value) == pc + 4
        _clear_inputs(dut)
        await _advance_cycle(dut)
        assert not bool(dut.o_pd_redirect_ras_push.value)
        assert not bool(dut.o_pd_redirect_ras_pop.value)


@cocotb.test()
async def test_backing_btb_slot2_call_links_after_slot2(dut: Any) -> None:
    """A slot-2 call pushes the address after slot 2; a slot-2 return pops."""
    await _setup_test(dut)
    pc = 0x8000_0200
    target = 0x8000_0F40
    top = 0x8000_1234
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    _drive_if_packet(dut, _packet(pc, addi))
    _drive_if_packet(dut, _packet(pc + 4, _pack_jal(imm=0x40, rd=1)), slot2=True)
    _drive_backing(dut, 1, target=target)
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) and bool(dut.o_pd_redirect_slot2.value)
    assert bool(dut.o_pd_redirect_ras_push.value)
    assert not bool(dut.o_pd_redirect_ras_pop.value)
    assert int(dut.o_pd_redirect_ras_link.value) == pc + 8
    _clear_inputs(dut)
    await _advance_cycle(dut)

    ret = _pack_i(imm=0, rs1=1, funct3=0, rd=0, opcode=OPC_JALR)
    _drive_if_packet(
        dut, _packet(pc, addi, ras_checkpoint_valid_count=1, ras_checkpoint_top=top)
    )
    _drive_if_packet(dut, _packet(pc + 4, ret), slot2=True)
    _drive_backing(dut, 1, target=target, is_return=True)
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) and bool(dut.o_pd_redirect_slot2.value)
    assert int(dut.o_pd_redirect_target.value) == top
    assert bool(dut.o_pd_redirect_ras_pop.value)
    assert not bool(dut.o_pd_redirect_ras_push.value)
    _clear_inputs(dut)
    await _advance_cycle(dut)

    # Nor is a slot-2 JALR with a nonzero funct3.
    illegal = _pack_i(imm=0, rs1=6, funct3=2, rd=0, opcode=OPC_JALR)
    _drive_if_packet(dut, _packet(pc, addi))
    _drive_if_packet(dut, _packet(pc + 4, illegal), slot2=True)
    _drive_backing(dut, 1, target=target)
    redirect, _, _, _ = await _backing_redirect(dut)
    assert not redirect


@cocotb.test()
async def test_backing_btb_slot2_entry_follows_slot1_size(dut: Any) -> None:
    """A slot-2 backing redirect takes slot 2's entry for slot 1's size.

    IF passes slot 2's return type and target for both sizes of slot 1. The
    entry for the other size differs in both here, so the redirect shows
    which one PD took.
    """
    await _setup_test(dut)
    pc = 0x8000_0200
    target = 0x8000_0F40
    top = 0x8000_1234
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    c_addi = 0x0505  # c.addi a0, 1
    c_addi_expansion = _pack_i(imm=1, rs1=10, funct3=0, rd=10, opcode=OPC_OP_IMM)
    jal = _pack_jal(imm=0x40, rd=0)
    ret = _pack_i(imm=0, rs1=1, funct3=0, rd=0, opcode=OPC_JALR)
    for compressed in (False, True):
        slot1 = (
            _packet(pc, c_addi_expansion, raw_parcel=c_addi, sel_compressed=True)
            if compressed
            else _packet(pc, addi)
        )
        slot2_pc = pc + (2 if compressed else 4)
        _drive_if_packet(dut, slot1)
        _drive_if_packet(dut, _packet(slot2_pc, jal), slot2=True)
        _drive_backing(dut, 1, target=target, size_select=compressed)
        redirect, taken, redirect_target, slot2 = await _backing_redirect(dut)
        assert redirect and taken and slot2
        assert redirect_target == target

        _drive_if_packet(
            dut, {**slot1, "ras_checkpoint_valid_count": 1, "ras_checkpoint_top": top}
        )
        _drive_if_packet(dut, _packet(slot2_pc, ret), slot2=True)
        _drive_backing(dut, 1, target=target, is_return=True, size_select=compressed)
        redirect, _, redirect_target, slot2 = await _backing_redirect(dut)
        assert redirect and slot2
        assert redirect_target == top


@cocotb.test()
async def test_backing_btb_compressed_jump_needs_a_compressed_entry(dut: Any) -> None:
    """A compressed C.J redirects only with an entry trained at its size."""
    await _setup_test(dut)
    pc = 0x8000_0202
    target = 0x8000_0400
    c_j = 0xA001  # c.j +0
    for compressed, expected in ((True, True), (False, False)):
        _drive_if_packet(
            dut,
            {
                "program_counter": pc,
                "raw_parcel": c_j,
                "sel_nop": False,
                "sel_compressed": True,
                "effective_instr": c_j,
            },
        )
        _drive_backing(dut, 0, target=target, compressed=compressed)
        redirect, _, redirect_target, _ = await _backing_redirect(dut)
        assert redirect is expected
        if expected:
            assert redirect_target == target


@cocotb.test()
async def test_backing_btb_redirects_a_slot2_jump(dut: Any) -> None:
    """A slot-2 jump redirects with the slot-2 flag; a bubble slot 2 never does."""
    await _setup_test(dut)
    pc = 0x8000_0200
    target = 0x8000_0F40
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    jal = _pack_jal(imm=0x40, rd=0)
    for slot2_valid in (True, False):
        _drive_if_packet(dut, _packet(pc, addi))
        _drive_if_packet(dut, _packet(pc + 4, jal, sel_nop=not slot2_valid), slot2=True)
        _drive_backing(dut, 1, target=target)
        redirect, taken, redirect_target, slot2 = await _backing_redirect(dut)
        assert redirect is slot2_valid
        if slot2_valid:
            assert taken and slot2 and redirect_target == target

    # A slot 2 behind a faulting slot 1 faults too and never redirects, even
    # when slot 1's bytes decode as a conditional branch.
    branch = _pack_b(imm=8, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    for slot1 in (addi, branch):
        _drive_if_packet(dut, _packet(pc, slot1, fetch_fault=True, tage_valid=True))
        _drive_if_packet(dut, _packet(pc + 4, jal, fetch_fault=True), slot2=True)
        _drive_backing(dut, 1, target=target)
        redirect, _, _, _ = await _backing_redirect(dut)
        assert not redirect, hex(slot1)


@cocotb.test()
async def test_reserved_compressed_jump_preserves_only_its_trap(dut: Any) -> None:
    """Reserved C.JR x0 traps in either slot and cannot steer or own history."""
    await _setup_test(dut)
    pc = 0x8000_0200
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    jalr = _pack_i(imm=8, rs1=12, funct3=0, rd=1, opcode=OPC_JALR)
    branch = _pack_b(imm=8, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    reserved = {
        "program_counter": pc,
        "raw_parcel": 0x8002,
        "sel_nop": False,
        "sel_compressed": True,
        "effective_instr": OPC_JALR,
    }
    width = len(dut.i_itt_target) // 2
    targets = ((0x8000_0F44 >> 1) << width) | (0x8000_0C40 >> 1)
    for younger in (_pack_jal(imm=0x40, rd=1), jalr, branch):
        for hits in (1, 2, 3):
            _drive_if_packet(dut, reserved)
            _drive_if_packet(
                dut,
                _packet(pc + 2, younger, tage_valid=True, tage_taken=True),
                slot2=True,
            )
            _drive_backing(dut, 1, target=0x8000_0F44)
            dut.i_itt_hit.value = hits
            dut.i_itt_target.value = targets
            await _advance_cycle(dut)
            assert _read_pd_packet(dut)["illegal_instruction"]
            assert _read_pd_packet(dut, slot2=True)["inject_nop"]
            assert not bool(dut.o_pd_redirect.value)
            assert not bool(dut.o_pd_redirect_ras_push.value)
            assert not bool(dut.o_pd_redirect_ras_pop.value)
            assert (
                int(dut.o_jump.value)
                == int(dut.o_jalr.value)
                == int(dut.o_cond_branch.value)
                == 0
            )
            _clear_inputs(dut)
            await _advance_cycle(dut)

    _drive_if_packet(dut, _packet(pc, addi))
    _drive_if_packet(
        dut, {**reserved, "program_counter": pc + 4, "decomp_illegal": True}, slot2=True
    )
    _drive_backing(dut, 1, target=0x8000_0F44, compressed=True)
    dut.i_itt_hit.value = 2
    dut.i_itt_target.value = targets
    await _advance_cycle(dut)
    second = _read_pd_packet(dut, slot2=True)
    assert second["illegal_instruction"] and not second["inject_nop"]
    assert not bool(dut.o_pd_redirect.value)
    assert int(dut.o_jump.value) == int(dut.o_jalr.value) == 0


@cocotb.test()
async def test_backing_btb_redirect_refreshes_its_entry(dut: Any) -> None:
    """A firing backing redirect names its slot's PC for a refresh; others do not."""
    await _setup_test(dut)
    pc = 0x8000_0200
    target = 0x8000_0F40
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    jal = _pack_jal(imm=0x40, rd=0)
    cases = [
        # slot-1 instruction, slot-2 instruction, hit slot, fast-taken, PC
        (jal, None, 0, False, pc),
        (addi, jal, 1, False, pc + 4),
        (jal, None, 0, True, None),
        (addi, None, None, False, None),
    ]
    for slot1, slot2, slot, fast_taken, refresh_pc in cases:
        _drive_if_packet(
            dut,
            _packet(
                pc,
                slot1,
                btb_predicted_taken=fast_taken,
                btb_predicted_target=target,
            ),
        )
        if slot2 is not None:
            _drive_if_packet(dut, _packet(pc + 4, slot2), slot2=True)
        _drive_backing(dut, slot, target=target)
        await _advance_cycle(dut)
        assert bool(dut.o_pd_backing_refresh.value) is (refresh_pc is not None)
        if refresh_pc is not None:
            assert int(dut.o_pd_backing_refresh_pc.value) == refresh_pc
        _clear_inputs(dut)
        await _advance_cycle(dut)
        assert not bool(dut.o_pd_backing_refresh.value)


@cocotb.test()
async def test_slot2_tage_redirect_taken_and_veto_native_and_compressed(
    dut: Any,
) -> None:
    """Slot-2 tagged direction predictions upgrade not-taken and veto taken branches."""
    await _setup_test(dut)
    pc = 0x8000_0400
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    native_br = _pack_b(imm=48, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    c_beqz = _pack_compressed_branch(imm=-32, funct3=0b110)
    c_beqz_exp = _pack_b(imm=-32, rs2=0, rs1=8, funct3=0, opcode=OPC_BRANCH)

    cases = [
        # (slot2_pc, raw, eff, compressed, btb_taken, tage_valid, tage_taken, bp_dir, exp_redir, exp_taken, exp_target)
        # Native taken upgrade
        (
            pc + 4,
            native_br & 0xFFFF,
            native_br,
            False,
            False,
            True,
            True,
            False,
            True,
            True,
            pc + 4 + 48,
        ),
        # Native not-taken veto (fall-through = pc2 + 4)
        (
            pc + 4,
            native_br & 0xFFFF,
            native_br,
            False,
            True,
            True,
            False,
            True,
            True,
            False,
            pc + 4 + 4,
        ),
        # Compressed taken upgrade
        (
            pc + 4,
            c_beqz,
            c_beqz_exp,
            True,
            False,
            True,
            True,
            False,
            True,
            True,
            pc + 4 - 32,
        ),
        # Compressed not-taken veto (halfword fall-through = pc2 + 2)
        (
            pc + 4,
            c_beqz,
            c_beqz_exp,
            True,
            True,
            True,
            False,
            True,
            True,
            False,
            pc + 4 + 2,
        ),
        # Agreement with BTB (both taken or both not-taken): no redirect
        (
            pc + 4,
            native_br & 0xFFFF,
            native_br,
            False,
            True,
            True,
            True,
            False,
            False,
            False,
            0,
        ),
        (
            pc + 4,
            c_beqz,
            c_beqz_exp,
            True,
            False,
            True,
            False,
            True,
            False,
            False,
            0,
        ),
        # No TAGE hit (tage_valid=False): bimodal bp_dir_taken=True must NOT redirect slot 2
        (
            pc + 4,
            native_br & 0xFFFF,
            native_br,
            False,
            False,
            False,
            True,
            True,
            False,
            False,
            0,
        ),
    ]

    for (
        pc2,
        raw,
        eff,
        compressed,
        btb_taken,
        tage_valid,
        tage_taken,
        bp_dir,
        exp_redir,
        exp_taken,
        exp_target,
    ) in cases:
        _drive_if_packet(dut, _packet(pc, addi))
        _drive_if_packet(
            dut,
            {
                "program_counter": pc2,
                "raw_parcel": raw,
                "sel_nop": False,
                "sel_compressed": compressed,
                "effective_instr": eff,
                "btb_predicted_taken": btb_taken,
                "btb_predicted_target": (pc2 + 64) if btb_taken else 0,
                "bp_dir_taken": bp_dir,
                "tage_valid": tage_valid,
                "tage_taken": tage_taken,
            },
            slot2=True,
        )
        await _settle()
        assert int(dut.o_cond_branch.value) == 0b10
        redirect, taken, target, slot2 = await _backing_redirect(dut)
        assert redirect is exp_redir
        if exp_redir:
            assert slot2 is True
            assert taken is exp_taken
            assert target == (exp_target & MASK_XLEN)
            assert not bool(dut.o_pd_redirect_ras_push.value)
            assert not bool(dut.o_pd_redirect_ras_pop.value)
            assert not bool(dut.o_pd_backing_refresh.value)


@cocotb.test()
async def test_slot2_tage_target_and_fallthrough_carry_and_borrow_across_bit13(
    dut: Any,
) -> None:
    """Slot-2 taken targets and veto fall-throughs carry and borrow across bit 13."""
    await _setup_test(dut)
    chunk_boundary = 0x8000_2000
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    c_nop = 0x0001

    # (pc1, slot1_comp, pc2, slot2_comp, imm, is_veto)
    cases = [
        # Same chunk, +imm carry across bit 13
        (chunk_boundary - 8, False, chunk_boundary - 4, False, +64, False),
        # Same chunk, -imm borrow across bit 13
        (chunk_boundary, False, chunk_boundary + 4, False, -64, False),
        # pc2 itself crosses bit 13 from pc1 + 4 (native slot 1 at 0x1FFC -> pc2 = 0x2000)
        (chunk_boundary - 4, False, chunk_boundary, False, +32, False),
        (chunk_boundary - 4, False, chunk_boundary, False, -32, False),
        (chunk_boundary - 4, False, chunk_boundary, True, -4, False),
        (chunk_boundary - 4, False, chunk_boundary, True, +4, True),  # veto -> 0x2002
        # pc2 crosses bit 13 from pc1 + 2 (compressed slot 1 at 0x1FFE -> pc2 = 0x2000)
        (chunk_boundary - 2, True, chunk_boundary, True, -16, False),
        (chunk_boundary - 2, True, chunk_boundary, False, +16, True),  # veto -> 0x2004
        # Spanning native branch at 0x1FFE: veto halfword fall-through crosses bit 13 to 0x2002
        (chunk_boundary - 4, True, chunk_boundary - 2, False, +12, True),
        # Compressed branch at 0x1FFE: veto fall-through crosses bit 13 to 0x2000
        (chunk_boundary - 4, True, chunk_boundary - 2, True, -12, True),
    ]

    for pc1, s1_comp, pc2, s2_comp, imm, is_veto in cases:
        _drive_if_packet(
            dut,
            {
                "program_counter": pc1,
                "raw_parcel": c_nop if s1_comp else (addi & 0xFFFF),
                "sel_nop": False,
                "sel_compressed": s1_comp,
                "effective_instr": NOP_INSTR if s1_comp else addi,
            },
        )
        if s2_comp:
            raw2 = _pack_compressed_branch(imm=imm, funct3=0b110)
            eff2 = _pack_b(imm=imm, rs2=0, rs1=8, funct3=0, opcode=OPC_BRANCH)
            fallthrough = pc2 + 2
        else:
            eff2 = _pack_b(imm=imm, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
            raw2 = eff2 & 0xFFFF
            fallthrough = pc2 + 4
        expected_target = (fallthrough if is_veto else (pc2 + imm)) & MASK_XLEN

        _drive_if_packet(
            dut,
            {
                "program_counter": pc2,
                "raw_parcel": raw2,
                "sel_nop": False,
                "sel_compressed": s2_comp,
                "effective_instr": eff2,
                "btb_predicted_taken": is_veto,
                "btb_predicted_target": (pc2 + imm) & MASK_XLEN if is_veto else 0,
                "tage_valid": True,
                "tage_taken": not is_veto,
            },
            slot2=True,
        )
        redirect, taken, target, slot2 = await _backing_redirect(dut)
        assert redirect and slot2, (hex(pc1), hex(pc2), imm, is_veto)
        assert taken is (not is_veto)
        assert target == expected_target, (hex(target), hex(expected_target))


@cocotb.test()
async def test_slot2_tage_redirect_multi_cycle_stall_and_flush(dut: Any) -> None:
    """Slot-2 redirect holds across a multi-cycle stall and clears on flush."""
    await _setup_test(dut)
    pc = 0x8000_0800
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    br_taken = _pack_b(imm=40, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    br_other = _pack_b(imm=-20, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)

    for taken in (True, False):
        # Hold each direction across three stalled cycles while IF presents an
        # opposite-direction packet. Release consumes the redirect once.
        _drive_if_packet(dut, _packet(pc, addi))
        _drive_if_packet(
            dut,
            _packet(
                pc + 4,
                br_taken,
                btb_predicted_taken=not taken,
                tage_valid=True,
                tage_taken=taken,
            ),
            slot2=True,
        )
        await _advance_cycle(dut)
        expected_target = (pc + 4 + (40 if taken else 4)) & MASK_XLEN
        assert bool(dut.o_pd_redirect.value) and bool(dut.o_pd_redirect_slot2.value)
        assert bool(dut.o_pd_redirect_taken.value) is taken
        assert int(dut.o_pd_redirect_target.value) == expected_target

        _drive_pipeline_ctrl(dut, {"stall": True})
        _drive_if_packet(dut, _packet(pc + 8, addi))
        _drive_if_packet(
            dut,
            _packet(
                pc + 12,
                br_other,
                btb_predicted_taken=taken,
                tage_valid=True,
                tage_taken=not taken,
            ),
            slot2=True,
        )
        for _ in range(3):
            await _advance_cycle(dut)
            assert bool(dut.o_pd_redirect.value) and bool(dut.o_pd_redirect_slot2.value)
            assert bool(dut.o_pd_redirect_taken.value) is taken
            assert int(dut.o_pd_redirect_target.value) == expected_target

        # Release the stall: the redirect suppresses the younger IF packet into
        # bubbles and does NOT chain a second redirect on the next cycle.
        _drive_pipeline_ctrl(dut, {})
        await _advance_cycle(dut)
        assert not bool(dut.o_pd_redirect.value)
        _assert_nop_slot(_read_pd_packet(dut))
        _assert_nop_slot(_read_pd_packet(dut, slot2=True))

        # A flush on the capture edge clears the slot-2 candidate so no redirect
        # fires on the following cycle.
        _drive_pipeline_ctrl(dut, {"flush": True})
        _drive_if_packet(dut, _packet(pc, addi))
        _drive_if_packet(
            dut,
            _packet(
                pc + 4,
                br_taken,
                btb_predicted_taken=not taken,
                tage_valid=True,
                tage_taken=taken,
            ),
            slot2=True,
        )
        await _advance_cycle(dut)
        assert not bool(dut.o_pd_redirect.value)
        _drive_pipeline_ctrl(dut, {})
        _clear_inputs(dut)
        await _advance_cycle(dut)
        assert not bool(dut.o_pd_redirect.value)


@cocotb.test()
async def test_slot2_tage_bubble_fault_and_slot1_jal_priority(dut: Any) -> None:
    """Bubble and fault veto slot-2 TAGE redirects, and slot-1 redirects take priority."""
    await _setup_test(dut)
    pc = 0x8000_0C00
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    jal = _pack_jal(imm=0x80, rd=1)
    slot1_br = _pack_b(imm=24, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    slot2_br = _pack_b(imm=64, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)

    # Slot-2 bubble (sel_nop) and fetch_fault each veto a slot-2 TAGE override.
    for sel_nop, fault in ((True, False), (False, True)):
        _drive_if_packet(dut, _packet(pc, addi))
        _drive_if_packet(
            dut,
            _packet(
                pc + 4,
                slot2_br,
                sel_nop=sel_nop,
                fetch_fault=fault,
                btb_predicted_taken=False,
                tage_valid=True,
                tage_taken=True,
            ),
            slot2=True,
        )
        redirect, _, _, _ = await _backing_redirect(dut)
        assert not redirect, (sel_nop, fault)

    # Slot-1 JAL with a backing hit paired with a slot-2 TAGE branch: slot 1
    # wins, o_pd_redirect_slot2 stays low, and slot 1's link/refresh fire.
    backing_target = 0x8000_0C80
    _drive_if_packet(dut, _packet(pc, jal))
    _drive_if_packet(
        dut,
        _packet(
            pc + 4,
            slot2_br,
            btb_predicted_taken=False,
            tage_valid=True,
            tage_taken=True,
        ),
        slot2=True,
    )
    _drive_backing(dut, 0, target=backing_target)
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value)
    assert not bool(dut.o_pd_redirect_slot2.value)
    assert bool(dut.o_pd_redirect_taken.value)
    assert int(dut.o_pd_redirect_target.value) == backing_target
    assert bool(dut.o_pd_redirect_ras_push.value)
    assert int(dut.o_pd_redirect_ras_link.value) == pc + 4
    assert bool(dut.o_pd_backing_refresh.value)
    assert int(dut.o_pd_backing_refresh_pc.value) == pc
    _clear_inputs(dut)
    await _advance_cycle(dut)

    # Slot-1 direction redirect paired with a slot-2 TAGE veto: slot 1 wins.
    _drive_if_packet(
        dut,
        _packet(
            pc,
            slot1_br,
            btb_predicted_taken=False,
            tage_valid=True,
            tage_taken=True,
        ),
    )
    _drive_if_packet(
        dut,
        _packet(
            pc + 4,
            slot2_br,
            btb_predicted_taken=True,
            tage_valid=True,
            tage_taken=False,
        ),
        slot2=True,
    )
    redirect, taken, target, slot2 = await _backing_redirect(dut)
    assert redirect and not slot2 and taken
    assert target == (pc + 24) & MASK_XLEN


@cocotb.test()
async def test_slot2_backing_target_owns_a_two_hit_packet(dut: Any) -> None:
    """A stale slot-1 hit on ADDI cannot supply the target of a live slot-2 jump."""
    await _setup_test(dut)
    pc = 0x8000_0200
    stale = 0x8000_0C40
    target = 0x8000_0F44
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    _drive_if_packet(dut, _packet(pc, addi))
    _drive_if_packet(dut, _packet(pc + 4, _pack_jal(imm=0x40, rd=0)), slot2=True)
    _drive_backing(dut, 1, target=target)
    width = len(dut.i_backing_target) // 2
    dut.i_backing_target.value = ((target >> 1) << width) | (stale >> 1)
    dut.i_backing_hit.value = 3
    await _advance_cycle(dut)
    assert bool(dut.o_pd_redirect.value) and bool(dut.o_pd_redirect_slot2.value)
    assert int(dut.o_pd_redirect_target.value) == target
    assert int(dut.o_pd_backing_refresh_pc.value) == pc + 4


@cocotb.test()
async def test_itt_hit_requires_a_live_nonreturn_jalr_in_its_slot(dut: Any) -> None:
    """In either slot a stale ITT target for replaced, faulting or killed bytes is ignored."""
    await _setup_test(dut)
    pc = 0x8000_0200
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    jalr = _pack_i(imm=0, rs1=6, funct3=0, rd=0, opcode=OPC_JALR)
    ret = _pack_i(imm=0, rs1=1, funct3=0, rd=0, opcode=OPC_JALR)
    targets = [0x8000_0624, 0x8000_0788]
    width = len(dut.i_itt_target) // 2
    for slot in range(2):
        for insn, bubble, fault, redirects in (
            (addi, False, False, False),
            (ret, False, False, False),
            (jalr, True, False, False),
            (jalr, False, True, False),
            (jalr, False, False, True),
        ):
            first = _packet(pc, addi)
            second = _packet(pc + 4, addi, sel_nop=True)
            candidate = _packet(pc + slot * 4, insn, sel_nop=bubble, fetch_fault=fault)
            _drive_if_packet(dut, first if slot else candidate)
            _drive_if_packet(dut, candidate if slot else second, slot2=True)
            dut.i_itt_hit.value = 3
            dut.i_itt_target.value = (targets[0] >> 1) | (targets[1] >> 1) << width
            if redirects:
                _drive_backing(dut, slot, target=0x8000_0350)
            fire, taken, target, second_slot = await _backing_redirect(dut)
            assert fire == redirects
            if fire:
                assert taken and second_slot == bool(slot) and target == targets[slot]


@cocotb.test()
async def test_slot2_indirect_target_uses_its_own_pc_region(dut: Any) -> None:
    """A slot-2 JALR can begin just beyond the range stored in an ITT entry."""
    await _setup_test(dut)
    target_bits = len(dut.i_itt_target) // 2
    region = 1 << (target_bits + 1)
    low_target = 0x1000
    addi = _pack_i(imm=1, rs1=1, funct3=0, rd=1, opcode=OPC_OP_IMM)
    jalr = _pack_i(imm=0, rs1=12, funct3=0, rd=1, opcode=OPC_JALR)
    for first in (
        _packet(region - 4, addi),
        {
            "program_counter": region - 2,
            "raw_parcel": 0x0001,
            "sel_compressed": True,
            "sel_nop": False,
            "effective_instr": OPC_OP_IMM,
        },
    ):
        _drive_if_packet(dut, first)
        _drive_if_packet(dut, _packet(region, jalr), slot2=True)
        dut.i_itt_hit.value = 2
        dut.i_itt_target.value = (low_target >> 1) << target_bits
        redirect, taken, target, second = await _backing_redirect(dut)
        assert redirect and taken and second
        assert target == region + low_target

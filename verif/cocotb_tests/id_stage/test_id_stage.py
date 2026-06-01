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

"""Top-level unit tests for the instruction-decode stage."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
XLEN = 32
FLEN = 64
RAS_PTR_BITS = 3
BP_DIR_IDX_BITS = 10
INSTR_OP_WIDTH = 32
BRANCH_OP_WIDTH = 3
STORE_OP_WIDTH = 2

NOP_INSTR = 0x00000013
BASE_PC = 0x80001000

OPC_JAL = 0b1101111
OPC_JALR = 0b1100111
OPC_BRANCH = 0b1100011
OPC_LOAD = 0b0000011
OPC_STORE = 0b0100011
OPC_OP_IMM = 0b0010011
OPC_OP = 0b0110011
OPC_FMADD = 0b1000011

ADD = 0
ADDI = 10
JAL = 21
JALR = 22
BEQ = 23
LW = 31
SW = 36
FMADD_S = 111

BREQ = 0
JUMP = 6
BR_NULL = 7

STN = 0
STW = 3

RS_INT = 0
RS_MEM = 2
RS_FMUL = 4
RS_NONE = 6

PIPELINE_CTRL_FIELDS = [
    ("reset", 1),
    ("stall", 1),
    ("stall_registered", 1),
    ("stall_for_trap_check", 1),
    ("flush", 1),
    ("trap_taken_registered", 1),
    ("mret_taken_registered", 1),
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
    ("bp_dir_idx", BP_DIR_IDX_BITS),
]

RF_TO_FWD_FIELDS = [
    ("source_reg_1_data", XLEN),
    ("source_reg_2_data", XLEN),
]

FP_RF_TO_FWD_FIELDS = [
    ("fp_source_reg_1_data", FLEN),
    ("fp_source_reg_2_data", FLEN),
    ("fp_source_reg_3_data", FLEN),
]

FROM_MA_TO_WB_FIELDS = [
    ("regfile_write_enable", 1),
    ("regfile_write_data", XLEN),
    ("instruction", 32),
    ("fp_regfile_write_enable", 1),
    ("fp_dest_reg", 5),
    ("fp_regfile_write_data", FLEN),
    ("fp_flags", 5),
]

ID_TO_EX_FIELDS = [
    ("program_counter", XLEN),
    ("immediate_i_type", 32),
    ("immediate_s_type", 32),
    ("immediate_b_type", 32),
    ("immediate_u_type", 32),
    ("immediate_j_type", 32),
    ("source_reg_1_data", XLEN),
    ("source_reg_2_data", XLEN),
    ("source_reg_1_is_x0", 1),
    ("source_reg_2_is_x0", 1),
    ("is_load_instruction", 1),
    ("is_load_byte", 1),
    ("is_load_halfword", 1),
    ("is_load_unsigned", 1),
    ("instruction_operation", INSTR_OP_WIDTH),
    ("branch_operation", BRANCH_OP_WIDTH),
    ("store_operation", STORE_OP_WIDTH),
    ("rs_type", 3),
    ("is_int_store", 1),
    ("is_branch_or_jump", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_csr_imm", 1),
    ("has_fp_flags", 1),
    ("is_jump_and_link", 1),
    ("is_jump_and_link_register", 1),
    ("is_multiply", 1),
    ("is_divide", 1),
    ("is_csr_instruction", 1),
    ("csr_address", 12),
    ("csr_imm", 5),
    ("is_amo_instruction", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_mret", 1),
    ("is_wfi", 1),
    ("is_ecall", 1),
    ("is_ebreak", 1),
    ("is_illegal_instruction", 1),
    ("is_fp_instruction", 1),
    ("is_fp_load", 1),
    ("is_fp_store", 1),
    ("is_fp_load_double", 1),
    ("is_fp_store_double", 1),
    ("is_fp_compute", 1),
    ("is_pipelined_fp_op", 1),
    ("fp_rm", 3),
    ("is_fp_to_int", 1),
    ("is_int_to_fp", 1),
    ("fp_source_reg_1_data", FLEN),
    ("fp_source_reg_2_data", FLEN),
    ("fp_source_reg_3_data", FLEN),
    ("link_address", XLEN),
    ("branch_target_precomputed", XLEN),
    ("jal_target_precomputed", XLEN),
    ("instruction", 32),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_predicted", 1),
    ("ras_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
    ("is_ras_return", 1),
    ("is_ras_call", 1),
    ("ras_predicted_target_nonzero", 1),
    ("ras_expected_rs1", XLEN),
    ("btb_correct_non_jalr", 1),
    ("btb_expected_rs1", XLEN),
    ("has_int_dest", 1),
    ("has_fp_dest", 1),
    ("uses_int_rs1", 1),
    ("uses_int_rs2", 1),
    ("uses_fp_rs1", 1),
    ("uses_fp_rs2", 1),
    ("uses_fp_rs3", 1),
    ("is_not_nop", 1),
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


def _sign_extend(value: int, width: int) -> int:
    """Sign-extend a value and return it as an XLEN-masked integer."""
    sign_bit = 1 << (width - 1)
    mask = (1 << width) - 1
    value &= mask
    if value & sign_bit:
        value -= 1 << width
    return value & 0xFFFFFFFF


def _pack_pipeline_ctrl(fields: Mapping[str, int | bool]) -> int:
    """Pack a pipeline_ctrl_t value."""
    return _pack_struct(PIPELINE_CTRL_FIELDS, fields)


def _pack_pd_to_id(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_pd_to_id_t value."""
    return _pack_struct(PD_TO_ID_FIELDS, fields)


def _pack_rf_to_fwd(fields: Mapping[str, int | bool]) -> int:
    """Pack an rf_to_fwd_t value."""
    return _pack_struct(RF_TO_FWD_FIELDS, fields)


def _pack_fp_rf_to_fwd(fields: Mapping[str, int | bool]) -> int:
    """Pack an fp_rf_to_fwd_t value."""
    return _pack_struct(FP_RF_TO_FWD_FIELDS, fields)


def _pack_from_ma_to_wb(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_ma_to_wb_t value."""
    return _pack_struct(FROM_MA_TO_WB_FIELDS, fields)


def _drive_pipeline_ctrl(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive packed pipeline control inputs."""
    dut.i_pipeline_ctrl.value = _pack_pipeline_ctrl(fields)


def _drive_pd_packet(
    dut: Any,
    fields: Mapping[str, int | bool],
    *,
    slot2: bool = False,
) -> None:
    """Drive one packed PD-to-ID input packet with idle-safe defaults."""
    instruction = int(fields.get("instruction", NOP_INSTR))
    packet = {
        "program_counter": 0,
        "instruction": instruction,
        "link_address": 0,
        "source_reg_1_early": (instruction >> 15) & 0x1F,
        "source_reg_2_early": (instruction >> 20) & 0x1F,
        "fp_source_reg_3_early": (instruction >> 27) & 0x1F,
        "illegal_instruction": False,
        "btb_hit": False,
        "btb_predicted_taken": False,
        "btb_predicted_target": 0,
        "ras_predicted": False,
        "ras_predicted_target": 0,
        "ras_checkpoint_tos": 0,
        "ras_checkpoint_valid_count": 0,
        "bp_dir_idx": 0,
    }
    packet.update(fields)
    value = _pack_pd_to_id(packet)
    if slot2:
        dut.i_from_pd_to_id_2.value = value
    else:
        dut.i_from_pd_to_id.value = value


def _drive_rf(
    dut: Any,
    fields: Mapping[str, int | bool],
    *,
    slot2: bool = False,
) -> None:
    """Drive one integer register-file read-data input bundle."""
    value = _pack_rf_to_fwd(fields)
    if slot2:
        dut.i_rf_to_id_2.value = value
    else:
        dut.i_rf_to_id.value = value


def _drive_fp_rf(
    dut: Any,
    fields: Mapping[str, int | bool],
    *,
    slot2: bool = False,
) -> None:
    """Drive one FP register-file read-data input bundle."""
    value = _pack_fp_rf_to_fwd(fields)
    if slot2:
        dut.i_fp_rf_to_id_2.value = value
    else:
        dut.i_fp_rf_to_id.value = value


def _drive_wb(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the packed MA-to-WB bypass input bundle."""
    packet = {
        "regfile_write_enable": False,
        "regfile_write_data": 0,
        "instruction": NOP_INSTR,
        "fp_regfile_write_enable": False,
        "fp_dest_reg": 0,
        "fp_regfile_write_data": 0,
        "fp_flags": 0,
    }
    packet.update(fields)
    dut.i_from_ma_to_wb.value = _pack_from_ma_to_wb(packet)


def _read_id_packet(dut: Any, *, slot2: bool = False) -> dict[str, int | bool]:
    """Read and unpack one ID-to-EX output packet."""
    signal = dut.o_from_id_to_ex_2 if slot2 else dut.o_from_id_to_ex
    return _unpack_struct(ID_TO_EX_FIELDS, int(signal.value))


def _pack_i(*, imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    """Pack an I-type instruction."""
    return (
        ((imm & 0xFFF) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def _pack_s(*, imm: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    """Pack an S-type instruction."""
    return (
        (((imm >> 5) & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((imm & 0x1F) << 7)
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


def _pack_j(*, imm: int, rd: int, opcode: int) -> int:
    """Pack a J-type instruction."""
    offset = imm & 0x1FFFFF
    return (
        (((offset >> 20) & 0x1) << 31)
        | (((offset >> 1) & 0x3FF) << 21)
        | (((offset >> 11) & 0x1) << 20)
        | (((offset >> 12) & 0xFF) << 12)
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


def _pack_r4(
    *,
    rs3: int,
    fmt: int,
    rs2: int,
    rs1: int,
    rm: int,
    rd: int,
    opcode: int,
) -> int:
    """Pack an R4-type floating-point fused-operation instruction."""
    return (
        ((rs3 & 0x1F) << 27)
        | ((fmt & 0x3) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((rm & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


def _clear_inputs(dut: Any) -> None:
    """Drive all ID-stage inputs to safe idle values."""
    _drive_pipeline_ctrl(dut, {})
    _drive_pd_packet(dut, {})
    _drive_pd_packet(dut, {}, slot2=True)
    _drive_rf(dut, {})
    _drive_rf(dut, {}, slot2=True)
    _drive_fp_rf(dut, {})
    _drive_fp_rf(dut, {}, slot2=True)
    _drive_wb(dut, {})
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the ID stage, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    _drive_pipeline_ctrl(dut, {"reset": True})
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    _drive_pipeline_ctrl(dut, {})
    await _settle()


def _assert_control_nop(packet: Mapping[str, int | bool]) -> None:
    """Assert that an ID output packet has an idle decoded instruction."""
    assert packet["instruction"] == NOP_INSTR
    assert packet["instruction_operation"] == ADDI
    assert packet["branch_operation"] == BR_NULL
    assert packet["store_operation"] == STN
    assert packet["is_load_instruction"] is False
    assert packet["is_branch_or_jump"] is False
    assert packet["is_jump_and_link"] is False
    assert packet["is_jump_and_link_register"] is False
    assert packet["is_illegal_instruction"] is False
    assert packet["btb_hit"] is False
    assert packet["btb_predicted_taken"] is False
    assert packet["ras_predicted"] is False
    assert packet["has_int_dest"] is False
    assert packet["has_fp_dest"] is False
    assert packet["uses_int_rs1"] is False
    assert packet["uses_int_rs2"] is False
    assert packet["uses_fp_rs1"] is False
    assert packet["uses_fp_rs2"] is False
    assert packet["uses_fp_rs3"] is False
    assert packet["is_not_nop"] is False


@cocotb.test()
async def test_reset_outputs_nops_and_clears_control_metadata(dut: Any) -> None:
    """Reset inserts decoded NOPs and clears valid control metadata in both slots."""
    await _setup_test(dut)

    _assert_control_nop(_read_id_packet(dut))
    _assert_control_nop(_read_id_packet(dut, slot2=True))


@cocotb.test()
async def test_add_decodes_int_sources_and_wb_bypass(dut: Any) -> None:
    """ADD decodes as an integer op and uses same-cycle WB bypass on rs2."""
    await _setup_test(dut)
    instruction = _pack_r(funct7=0, rs2=12, rs1=11, funct3=0, rd=10, opcode=OPC_OP)

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": instruction,
            "link_address": BASE_PC + 4,
        },
    )
    _drive_rf(
        dut,
        {
            "source_reg_1_data": 0x11112222,
            "source_reg_2_data": 0x33334444,
        },
    )
    _drive_wb(
        dut,
        {
            "regfile_write_enable": True,
            "regfile_write_data": 0xA5A55A5A,
            "instruction": _pack_i(imm=0, rs1=0, funct3=0, rd=12, opcode=OPC_OP_IMM),
        },
    )
    await _advance_cycle(dut)

    packet = _read_id_packet(dut)
    assert packet["program_counter"] == BASE_PC
    assert packet["instruction"] == instruction
    assert packet["instruction_operation"] == ADD
    assert packet["rs_type"] == RS_INT
    assert packet["source_reg_1_data"] == 0x11112222
    assert packet["source_reg_2_data"] == 0xA5A55A5A
    assert packet["source_reg_1_is_x0"] is False
    assert packet["source_reg_2_is_x0"] is False
    assert packet["has_int_dest"] is True
    assert packet["has_fp_dest"] is False
    assert packet["uses_int_rs1"] is True
    assert packet["uses_int_rs2"] is True
    assert packet["is_not_nop"] is True


@cocotb.test()
async def test_load_and_slot2_store_decode_independently(dut: Any) -> None:
    """Slot 1 can decode a load while slot 2 independently decodes a store."""
    await _setup_test(dut)
    load = _pack_i(imm=-16, rs1=8, funct3=0b010, rd=9, opcode=OPC_LOAD)
    store = _pack_s(imm=20, rs2=6, rs1=5, funct3=0b010, opcode=OPC_STORE)

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": load,
            "link_address": BASE_PC + 4,
        },
    )
    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "instruction": store,
            "link_address": BASE_PC + 8,
        },
        slot2=True,
    )
    await _advance_cycle(dut)

    load_packet = _read_id_packet(dut)
    assert load_packet["instruction_operation"] == LW
    assert load_packet["immediate_i_type"] == _sign_extend(-16, 12)
    assert load_packet["is_load_instruction"] is True
    assert load_packet["is_load_byte"] is False
    assert load_packet["is_load_halfword"] is False
    assert load_packet["is_load_unsigned"] is False
    assert load_packet["rs_type"] == RS_MEM
    assert load_packet["has_int_dest"] is True
    assert load_packet["uses_int_rs1"] is True
    assert load_packet["uses_int_rs2"] is False

    store_packet = _read_id_packet(dut, slot2=True)
    assert store_packet["program_counter"] == BASE_PC + 4
    assert store_packet["instruction_operation"] == SW
    assert store_packet["store_operation"] == STW
    assert store_packet["immediate_s_type"] == 20
    assert store_packet["rs_type"] == RS_MEM
    assert store_packet["is_int_store"] is True
    assert store_packet["has_int_dest"] is False
    assert store_packet["uses_int_rs1"] is True
    assert store_packet["uses_int_rs2"] is True


@cocotb.test()
async def test_pd_redirect_overrides_slot1_btb_metadata_only(dut: Any) -> None:
    """The PD redirect BTB override applies to slot 1 and not slot 2."""
    await _setup_test(dut)
    branch = _pack_b(imm=-8, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    slot2_branch = _pack_b(imm=12, rs2=4, rs1=3, funct3=0, opcode=OPC_BRANCH)
    redirect_target = (BASE_PC - 8) & 0xFFFFFFFF

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": branch,
            "link_address": BASE_PC + 4,
            "btb_hit": False,
            "btb_predicted_taken": False,
            "btb_predicted_target": 0,
        },
    )
    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "instruction": slot2_branch,
            "link_address": BASE_PC + 8,
            "btb_hit": False,
            "btb_predicted_taken": False,
            "btb_predicted_target": 0x12345678,
        },
        slot2=True,
    )
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = redirect_target
    await _advance_cycle(dut)

    packet = _read_id_packet(dut)
    assert packet["instruction_operation"] == BEQ
    assert packet["branch_operation"] == BREQ
    assert packet["is_branch_or_jump"] is True
    assert packet["immediate_b_type"] == _sign_extend(-8, 13)
    assert packet["branch_target_precomputed"] == redirect_target
    assert packet["btb_hit"] is True
    assert packet["btb_predicted_taken"] is True
    assert packet["btb_predicted_target"] == redirect_target
    assert packet["btb_correct_non_jalr"] is True

    slot2_packet = _read_id_packet(dut, slot2=True)
    assert slot2_packet["instruction_operation"] == BEQ
    assert slot2_packet["branch_target_precomputed"] == BASE_PC + 16
    assert slot2_packet["btb_hit"] is False
    assert slot2_packet["btb_predicted_taken"] is False
    assert slot2_packet["btb_predicted_target"] == 0x12345678


@cocotb.test()
async def test_jal_and_slot2_jalr_ras_precompute(dut: Any) -> None:
    """JAL/JALR decode precomputes branch-prediction and RAS metadata."""
    await _setup_test(dut)
    jal = _pack_j(imm=0x100, rd=1, opcode=OPC_JAL)
    jalr_return = _pack_i(imm=0, rs1=1, funct3=0, rd=0, opcode=OPC_JALR)
    jal_target = BASE_PC + 0x100
    ras_target = 0x80002000
    btb_target = 0x80003000

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": jal,
            "link_address": BASE_PC + 4,
            "btb_hit": True,
            "btb_predicted_taken": True,
            "btb_predicted_target": jal_target,
            "ras_checkpoint_tos": 3,
            "ras_checkpoint_valid_count": 4,
        },
    )
    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "instruction": jalr_return,
            "link_address": BASE_PC + 8,
            "ras_predicted": True,
            "ras_predicted_target": ras_target,
            "btb_hit": True,
            "btb_predicted_taken": True,
            "btb_predicted_target": btb_target,
            "ras_checkpoint_tos": 5,
            "ras_checkpoint_valid_count": 6,
        },
        slot2=True,
    )
    await _advance_cycle(dut)

    packet = _read_id_packet(dut)
    assert packet["instruction_operation"] == JAL
    assert packet["branch_operation"] == JUMP
    assert packet["rs_type"] == RS_NONE
    assert packet["is_jump_and_link"] is True
    assert packet["is_ras_call"] is True
    assert packet["jal_target_precomputed"] == jal_target
    assert packet["btb_correct_non_jalr"] is True
    assert packet["ras_checkpoint_tos"] == 3
    assert packet["ras_checkpoint_valid_count"] == 4

    slot2_packet = _read_id_packet(dut, slot2=True)
    assert slot2_packet["instruction_operation"] == JALR
    assert slot2_packet["branch_operation"] == JUMP
    assert slot2_packet["is_jump_and_link_register"] is True
    assert slot2_packet["is_ras_return"] is True
    assert slot2_packet["is_ras_call"] is False
    assert slot2_packet["ras_predicted"] is True
    assert slot2_packet["ras_predicted_target_nonzero"] is True
    assert slot2_packet["ras_expected_rs1"] == ras_target
    assert slot2_packet["btb_expected_rs1"] == btb_target
    assert slot2_packet["ras_checkpoint_tos"] == 5
    assert slot2_packet["ras_checkpoint_valid_count"] == 6


@cocotb.test()
async def test_illegal_pd_input_clears_operand_classification(dut: Any) -> None:
    """PD illegal indication is merged into ID illegal and clears operand flags."""
    await _setup_test(dut)
    instruction = _pack_r(funct7=0, rs2=12, rs1=11, funct3=0, rd=10, opcode=OPC_OP)

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": instruction,
            "illegal_instruction": True,
        },
    )
    await _advance_cycle(dut)

    packet = _read_id_packet(dut)
    assert packet["instruction"] == instruction
    assert packet["is_illegal_instruction"] is True
    assert packet["rs_type"] == RS_INT
    assert packet["has_int_dest"] is False
    assert packet["has_fp_dest"] is False
    assert packet["uses_int_rs1"] is False
    assert packet["uses_int_rs2"] is False
    assert packet["uses_fp_rs1"] is False
    assert packet["uses_fp_rs2"] is False
    assert packet["uses_fp_rs3"] is False
    assert packet["is_not_nop"] is True


@cocotb.test()
async def test_flush_clears_control_and_stall_holds_outputs(dut: Any) -> None:
    """Flush clears decoded control fields, and stall holds registered outputs."""
    await _setup_test(dut)
    add = _pack_r(funct7=0, rs2=12, rs1=11, funct3=0, rd=10, opcode=OPC_OP)
    load = _pack_i(imm=4, rs1=8, funct3=0b010, rd=9, opcode=OPC_LOAD)

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": add,
            "link_address": BASE_PC + 4,
        },
    )
    await _advance_cycle(dut)
    held_packet = _read_id_packet(dut)

    _drive_pipeline_ctrl(dut, {"stall": True})
    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "instruction": load,
            "link_address": BASE_PC + 8,
        },
    )
    await _advance_cycle(dut)
    assert _read_id_packet(dut) == held_packet

    _drive_pipeline_ctrl(dut, {"flush": True})
    await _advance_cycle(dut)

    _assert_control_nop(_read_id_packet(dut))
    _assert_control_nop(_read_id_packet(dut, slot2=True))


@cocotb.test()
async def test_fp_fma_decodes_sources_and_fp_wb_bypass(dut: Any) -> None:
    """FMADD.S decodes FP routing and bypasses FP WB data to rs3."""
    await _setup_test(dut)
    instruction = _pack_r4(
        rs3=7,
        fmt=0,
        rs2=6,
        rs1=5,
        rm=1,
        rd=4,
        opcode=OPC_FMADD,
    )

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": instruction,
            "link_address": BASE_PC + 4,
        },
    )
    _drive_fp_rf(
        dut,
        {
            "fp_source_reg_1_data": 0x1111222233334444,
            "fp_source_reg_2_data": 0x5555666677778888,
            "fp_source_reg_3_data": 0x9999AAAABBBBCCCC,
        },
    )
    _drive_wb(
        dut,
        {
            "fp_regfile_write_enable": True,
            "fp_dest_reg": 7,
            "fp_regfile_write_data": 0xD0D1D2D3D4D5D6D7,
        },
    )
    await _advance_cycle(dut)

    packet = _read_id_packet(dut)
    assert packet["instruction_operation"] == FMADD_S
    assert packet["rs_type"] == RS_FMUL
    assert packet["is_fp_instruction"] is True
    assert packet["is_fp_compute"] is True
    assert packet["is_pipelined_fp_op"] is True
    assert packet["fp_rm"] == 1
    assert packet["has_fp_dest"] is True
    assert packet["has_fp_flags"] is True
    assert packet["uses_fp_rs1"] is True
    assert packet["uses_fp_rs2"] is True
    assert packet["uses_fp_rs3"] is True
    assert packet["fp_source_reg_1_data"] == 0x1111222233334444
    assert packet["fp_source_reg_2_data"] == 0x5555666677778888
    assert packet["fp_source_reg_3_data"] == 0xD0D1D2D3D4D5D6D7

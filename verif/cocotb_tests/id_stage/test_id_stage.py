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
from config import MASK_XLEN, XLEN


from ..tomasulo.fu_shims.fp_add_shim_interface import _parse_instr_op_enum
from cocotb_tests.cpu_structs import (
    PIPELINE_CTRL_FIELDS,
    PD_TO_ID_FIELDS,
    ID_TO_EX_FIELDS,
)
from utils.packed_structs import (
    pack_struct as _pack_struct,
    unpack_struct as _unpack_struct,
)

CLOCK_PERIOD_NS = 10

NOP_INSTR = 0x00000013
BASE_PC = 0x80001000

OPC_JAL = 0b1101111
OPC_JALR = 0b1100111
OPC_BRANCH = 0b1100011
OPC_AUIPC = 0b0010111
OPC_LOAD = 0b0000011
OPC_STORE = 0b0100011
OPC_OP = 0b0110011
OPC_FMADD = 0b1000011
OPC_AMO = 0b0101111
OPC_LOAD_FP = 0b0000111
OPC_OP_FP = 0b1010011

# Parsed from riscv_pkg.sv so the values track instr_op_e. Hardcoded values
# would go stale whenever a member is inserted earlier in the enum.
_INSTR_OPS = _parse_instr_op_enum()
ADD = _INSTR_OPS["ADD"]
ADDI = _INSTR_OPS["ADDI"]
JAL = _INSTR_OPS["JAL"]
JALR = _INSTR_OPS["JALR"]
BEQ = _INSTR_OPS["BEQ"]
AUIPC = _INSTR_OPS["AUIPC"]
LW = _INSTR_OPS["LW"]
SW = _INSTR_OPS["SW"]
FMADD_S = _INSTR_OPS["FMADD_S"]
FENCE = _INSTR_OPS["FENCE"]
FLW = _INSTR_OPS["FLW"]
FADD_S = _INSTR_OPS["FADD_S"]
PAUSE = _INSTR_OPS["PAUSE"]

RS_INT = 0
RS_MEM = 2
RS_FP = 3
RS_FMUL = 4
RS_NONE = 6


def _sign_extend(value: int, width: int) -> int:
    """Sign-extend a value and return it as an XLEN-masked integer."""
    sign_bit = 1 << (width - 1)
    mask = (1 << width) - 1
    value &= mask
    if value & sign_bit:
        value -= 1 << width
    return value & MASK_XLEN


def _pack_pipeline_ctrl(fields: Mapping[str, int | bool]) -> int:
    """Pack a pipeline_ctrl_t value."""
    return _pack_struct(PIPELINE_CTRL_FIELDS, fields)


def _pack_pd_to_id(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_pd_to_id_t value."""
    return _pack_struct(PD_TO_ID_FIELDS, fields)


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
        "source_reg_1_early": (instruction >> 15) & 0x1F,
        "source_reg_2_early": (instruction >> 20) & 0x1F,
        "illegal_instruction": False,
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
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0
    dut.i_mstatus_fs_off.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the ID stage, and clear inputs."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
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
    assert packet["is_load_instruction"] is False
    assert packet["is_branch_or_jump"] is False
    assert packet["is_jump_and_link"] is False
    assert packet["is_jump_and_link_register"] is False
    assert packet["is_illegal_instruction"] is False
    assert packet["btb_predicted_taken"] is False
    assert packet["ras_predicted"] is False
    assert packet["has_int_dest"] is False
    assert packet["has_fp_dest"] is False
    assert packet["uses_int_rs1"] is False
    assert packet["uses_int_rs2"] is False
    assert packet["uses_fp_rs1"] is False
    assert packet["uses_fp_rs2"] is False
    assert packet["uses_fp_rs3"] is False
    assert packet["is_real"] is False


@cocotb.test()
async def test_reset_outputs_nops_and_clears_control_metadata(dut: Any) -> None:
    """Reset inserts decoded NOPs and clears valid control metadata in both slots."""
    await _setup_test(dut)

    _assert_control_nop(_read_id_packet(dut))
    _assert_control_nop(_read_id_packet(dut, slot2=True))


@cocotb.test()
async def test_add_decodes_int_sources(dut: Any) -> None:
    """ADD decodes as an integer op that reads rs1 and rs2."""
    await _setup_test(dut)
    instruction = _pack_r(funct7=0, rs2=12, rs1=11, funct3=0, rd=10, opcode=OPC_OP)

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": instruction,
        },
    )
    await _advance_cycle(dut)

    packet = _read_id_packet(dut)
    assert packet["program_counter"] == BASE_PC
    assert packet["instruction"] == instruction
    assert packet["instruction_operation"] == ADD
    assert packet["rs_type"] == RS_INT
    assert packet["has_int_dest"] is True
    assert packet["has_fp_dest"] is False
    assert packet["uses_int_rs1"] is True
    assert packet["uses_int_rs2"] is True
    assert packet["is_real"] is True


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
        },
    )
    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "instruction": store,
        },
        slot2=True,
    )
    await _advance_cycle(dut)

    load_packet = _read_id_packet(dut)
    assert load_packet["instruction_operation"] == LW
    assert load_packet["immediate_i_type"] == _sign_extend(-16, 12)
    assert load_packet["is_load_instruction"] is True
    assert load_packet["is_load_unsigned"] is False
    assert load_packet["rs_type"] == RS_MEM
    assert load_packet["has_int_dest"] is True
    assert load_packet["uses_int_rs1"] is True
    assert load_packet["uses_int_rs2"] is False

    store_packet = _read_id_packet(dut, slot2=True)
    assert store_packet["program_counter"] == BASE_PC + 4
    assert store_packet["instruction_operation"] == SW
    assert store_packet["immediate_s_type"] == 20
    assert store_packet["rs_type"] == RS_MEM
    assert store_packet["is_int_store"] is True
    assert store_packet["has_int_dest"] is False
    assert store_packet["uses_int_rs1"] is True
    assert store_packet["uses_int_rs2"] is True


@cocotb.test()
async def test_program_nop_is_real_and_bubble_is_not(dut: Any) -> None:
    """A NOP in the program is a real instruction in both slots; a bubble is not.

    is_real decides dispatch, so a real NOP dispatches, retires, and counts in
    instret, while an inject_nop bubble never reaches the ROB.
    """
    await _setup_test(dut)
    _drive_pd_packet(dut, {"program_counter": BASE_PC, "instruction": NOP_INSTR})
    _drive_pd_packet(
        dut, {"program_counter": BASE_PC + 4, "instruction": NOP_INSTR}, slot2=True
    )
    await _advance_cycle(dut)
    for slot2 in (False, True):
        packet = _read_id_packet(dut, slot2=slot2)
        assert packet["instruction"] == NOP_INSTR
        assert packet["is_real"] is True

    for slot2 in (False, True):
        _drive_pd_packet(
            dut,
            {
                "program_counter": BASE_PC + 8,
                "instruction": NOP_INSTR,
                "inject_nop": True,
            },
            slot2=slot2,
        )
    await _advance_cycle(dut)
    for slot2 in (False, True):
        assert _read_id_packet(dut, slot2=slot2)["is_real"] is False


@cocotb.test()
async def test_inject_nop_masks_non_nop_payload_identically_in_both_slots(
    dut: Any,
) -> None:
    """Both registered bubble markers substitute the same architectural NOP."""
    await _setup_test(dut)
    poison = _pack_s(imm=20, rs2=6, rs1=5, funct3=0b010, opcode=OPC_STORE)

    bubble = {
        "program_counter": BASE_PC + 4,
        "instruction": poison,
        "inject_nop": True,
        "source_reg_1_early": 0,
        "source_reg_2_early": 0,
    }
    _drive_pd_packet(dut, bubble)
    _drive_pd_packet(dut, bubble, slot2=True)
    await _advance_cycle(dut)

    slot1_packet = _read_id_packet(dut)
    slot2_packet = _read_id_packet(dut, slot2=True)
    assert slot2_packet == slot1_packet
    assert slot2_packet["program_counter"] == BASE_PC + 4
    assert slot2_packet["instruction"] == NOP_INSTR
    assert slot2_packet["instruction_operation"] == ADDI
    assert slot2_packet["is_int_store"] is False
    assert slot2_packet["is_real"] is False


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
            "btb_predicted_taken": False,
            "btb_predicted_target": 0,
        },
    )
    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC + 4,
            "instruction": slot2_branch,
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
    assert packet["is_branch_or_jump"] is True
    assert packet["branch_target_precomputed"] == redirect_target
    assert packet["btb_predicted_taken"] is True
    assert packet["btb_predicted_target"] == redirect_target
    assert packet["btb_correct_non_jalr"] is True

    slot2_packet = _read_id_packet(dut, slot2=True)
    assert slot2_packet["instruction_operation"] == BEQ
    assert slot2_packet["branch_target_precomputed"] == BASE_PC + 16
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
            "ras_predicted": True,
            "ras_predicted_target": ras_target,
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
    assert packet["rs_type"] == RS_NONE
    assert packet["is_jump_and_link"] is True
    assert packet["is_ras_call"] is True
    assert packet["jal_target_precomputed"] == jal_target
    assert packet["btb_correct_non_jalr"] is True
    assert packet["ras_checkpoint_tos"] == 3
    assert packet["ras_checkpoint_valid_count"] == 4

    slot2_packet = _read_id_packet(dut, slot2=True)
    assert slot2_packet["instruction_operation"] == JALR
    assert slot2_packet["is_jump_and_link_register"] is True
    assert slot2_packet["is_ras_return"] is True
    assert slot2_packet["is_ras_call"] is False
    assert slot2_packet["ras_predicted"] is True
    assert slot2_packet["ras_predicted_target"] == ras_target
    assert slot2_packet["btb_predicted_target"] == btb_target
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
    assert packet["is_real"] is True


# PAUSE is exactly 0x0100000F. The other words are FENCE encodings: four that
# differ from it in one field (fence r,0 = 0x0200000F with pred=R, fence 0,0,
# and pred=W with rd or rs1 nonzero), plus fence rw,rw and fence.tso.
PAUSE_INSTR = 0x0100000F
FENCE_LOOKALIKES = (
    0x0200000F,
    0x0330000F,
    0x8330000F,
    0x0000000F,
    0x0100008F,
    0x0100800F,
)


@cocotb.test()
async def test_only_exact_pause_decodes_as_pause(dut: Any) -> None:
    """0x0100000F is PAUSE, a no-operand INT_RS op; every other FENCE word is a FENCE."""
    await _setup_test(dut)

    for fence_word in FENCE_LOOKALIKES:
        for pause_slot2 in (False, True):
            _drive_pd_packet(
                dut,
                {"program_counter": BASE_PC, "instruction": PAUSE_INSTR},
                slot2=pause_slot2,
            )
            _drive_pd_packet(
                dut,
                {"program_counter": BASE_PC + 4, "instruction": fence_word},
                slot2=not pause_slot2,
            )
            await _advance_cycle(dut)

            pause = _read_id_packet(dut, slot2=pause_slot2)
            assert pause["instruction_operation"] == PAUSE
            assert pause["rs_type"] == RS_INT
            assert pause["is_fence"] is False
            assert pause["is_fence_i"] is False
            assert pause["is_illegal_instruction"] is False
            assert pause["has_int_dest"] is False
            assert pause["uses_int_rs1"] is False
            assert pause["uses_int_rs2"] is False
            assert pause["is_real"] is True

            fence = _read_id_packet(dut, slot2=not pause_slot2)
            assert fence["instruction_operation"] == FENCE, hex(fence_word)
            assert fence["rs_type"] == RS_MEM, hex(fence_word)
            assert fence["is_fence"] is True, hex(fence_word)
            assert fence["is_illegal_instruction"] is False, hex(fence_word)


@cocotb.test()
async def test_fetch_fault_with_nop_bytes_is_dispatched_in_either_slot(
    dut: Any,
) -> None:
    """A fetch fault reaches dispatch even when its bytes decode as a NOP, in either slot."""
    await _setup_test(dut)

    for fault_slot2 in (False, True):
        _drive_pd_packet(dut, {"program_counter": BASE_PC, "instruction": NOP_INSTR})
        _drive_pd_packet(
            dut,
            {"program_counter": BASE_PC + 4, "instruction": NOP_INSTR},
            slot2=True,
        )
        _drive_pd_packet(
            dut,
            {
                "program_counter": BASE_PC + (4 if fault_slot2 else 0),
                "instruction": NOP_INSTR,
                "fetch_fault": True,
            },
            slot2=fault_slot2,
        )
        await _advance_cycle(dut)

        fault = _read_id_packet(dut, slot2=fault_slot2)
        assert fault["is_fetch_fault"] is True
        assert fault["is_real"] is True
        other = _read_id_packet(dut, slot2=not fault_slot2)
        assert other["is_fetch_fault"] is False
        assert other["is_real"] is True  # a NOP in the program is real


@cocotb.test()
async def test_fetch_fault_reads_no_source_register(dut: Any) -> None:
    """A fetch fault's garbage rs1 field creates no INT_RS source dependency."""
    await _setup_test(dut)
    add = _pack_r(funct7=0, rs2=12, rs1=11, funct3=0, rd=10, opcode=OPC_OP)

    for page_fault in (False, True):
        for slot2 in (False, True):
            _drive_pd_packet(
                dut,
                {
                    "program_counter": BASE_PC,
                    "instruction": add,
                    "fetch_fault": True,
                    "fetch_fault_page": page_fault,
                },
                slot2=slot2,
            )
            await _advance_cycle(dut)

            packet = _read_id_packet(dut, slot2=slot2)
            assert packet["is_fetch_fault"] is True
            assert packet["rs_type"] == RS_INT
            assert packet["has_int_dest"] is False
            assert packet["uses_int_rs1"] is False
            assert packet["uses_int_rs2"] is False
            assert packet["uses_fp_rs1"] is False
            _drive_pd_packet(dut, {}, slot2=slot2)


@cocotb.test()
async def test_fs_off_decodes_fp_instructions_as_illegal(dut: Any) -> None:
    """While mstatus.FS is Off, F/D instructions in either slot take the illegal class."""
    await _setup_test(dut)
    flw = _pack_i(imm=8, rs1=10, funct3=0b010, rd=3, opcode=OPC_LOAD_FP)
    fadd = _pack_r(funct7=0, rs2=2, rs1=1, funct3=0, rd=4, opcode=OPC_OP_FP)
    fmadd = _pack_r4(rs3=7, fmt=0, rs2=6, rs1=5, rm=0, rd=4, opcode=OPC_FMADD)
    add = _pack_r(funct7=0, rs2=12, rs1=11, funct3=0, rd=10, opcode=OPC_OP)

    for fp_instr in (flw, fadd, fmadd):
        for fp_slot2 in (False, True):
            _drive_pd_packet(
                dut,
                {"program_counter": BASE_PC, "instruction": fp_instr},
                slot2=fp_slot2,
            )
            _drive_pd_packet(
                dut,
                {"program_counter": BASE_PC + 4, "instruction": add},
                slot2=not fp_slot2,
            )
            dut.i_mstatus_fs_off.value = 1
            await _advance_cycle(dut)

            packet = _read_id_packet(dut, slot2=fp_slot2)
            assert packet["is_illegal_instruction"] is True, hex(fp_instr)
            assert packet["is_fp_instruction"] is True
            assert packet["rs_type"] == RS_INT
            assert packet["has_int_dest"] is False
            assert packet["has_fp_dest"] is False
            assert packet["has_fp_flags"] is False
            assert packet["uses_int_rs1"] is False
            assert packet["uses_fp_rs1"] is False
            assert packet["uses_fp_rs2"] is False
            assert packet["uses_fp_rs3"] is False
            assert packet["is_real"] is True
            # The FS=Off FLW takes no load-queue entry, so dispatch never
            # waits for one.
            assert packet["needs_lq"] is False and packet["needs_sq"] is False
            other = _read_id_packet(dut, slot2=not fp_slot2)
            assert other["is_illegal_instruction"] is False
            assert other["instruction_operation"] == ADD
            assert other["uses_int_rs1"] is True

    # FS on again: the same instructions decode normally.
    dut.i_mstatus_fs_off.value = 0
    _drive_pd_packet(dut, {"program_counter": BASE_PC, "instruction": flw})
    _drive_pd_packet(
        dut, {"program_counter": BASE_PC + 4, "instruction": fadd}, slot2=True
    )
    await _advance_cycle(dut)
    load = _read_id_packet(dut)
    assert load["is_illegal_instruction"] is False
    assert load["instruction_operation"] == FLW
    assert load["rs_type"] == RS_MEM
    assert load["has_fp_dest"] is True
    assert load["uses_int_rs1"] is True
    assert load["needs_lq"] is True and load["needs_sq"] is False
    compute = _read_id_packet(dut, slot2=True)
    assert compute["is_illegal_instruction"] is False
    assert compute["instruction_operation"] == FADD_S
    assert compute["rs_type"] == RS_FP
    assert compute["has_fp_flags"] is True


@cocotb.test()
async def test_memory_queue_needs_follow_the_operand_class(dut: Any) -> None:
    """Loads, LR and AMOs need a load-queue entry, stores and SC a store-queue one.

    An illegal instruction, a fetch fault and a bubble take no entry,
    whatever their bytes decode as.
    """
    await _setup_test(dut)
    load = _pack_i(imm=-16, rs1=8, funct3=0b011, rd=9, opcode=OPC_LOAD)
    store = _pack_s(imm=20, rs2=6, rs1=5, funct3=0b011, opcode=OPC_STORE)
    lr_w = _pack_r(funct7=0b0001000, rs2=0, rs1=5, funct3=0b010, rd=6, opcode=OPC_AMO)
    sc_w = _pack_r(funct7=0b0001100, rs2=7, rs1=5, funct3=0b010, rd=6, opcode=OPC_AMO)
    amoadd_d = _pack_r(
        funct7=0b0000000, rs2=7, rs1=5, funct3=0b011, rd=6, opcode=OPC_AMO
    )
    cases: tuple[tuple[str, int, dict[str, bool], tuple[bool, bool]], ...] = (
        ("ld", load, {}, (True, False)),
        ("sd", store, {}, (False, True)),
        ("lr.w", lr_w, {}, (True, False)),
        ("sc.w", sc_w, {}, (False, True)),
        ("amoadd.d", amoadd_d, {}, (True, False)),
        ("illegal ld", load, {"illegal_instruction": True}, (False, False)),
        ("faulting sd", store, {"fetch_fault": True}, (False, False)),
        ("faulting sc.w", sc_w, {"fetch_fault": True}, (False, False)),
        ("bubble ld", load, {"inject_nop": True}, (False, False)),
    )
    for name, instruction, extra, (needs_lq, needs_sq) in cases:
        for slot2 in (False, True):
            _drive_pd_packet(
                dut,
                {"program_counter": BASE_PC, "instruction": instruction, **extra},
                slot2=slot2,
            )
            _drive_pd_packet(dut, {"program_counter": BASE_PC + 4}, slot2=not slot2)
            await _advance_cycle(dut)
            packet = _read_id_packet(dut, slot2=slot2)
            assert packet["needs_lq"] is needs_lq, f"{name} slot2={slot2}: needs_lq"
            assert packet["needs_sq"] is needs_sq, f"{name} slot2={slot2}: needs_sq"


@cocotb.test()
async def test_fs_off_leaves_bubbles_legal(dut: Any) -> None:
    """A bubble whose raw bits are an F/D instruction decodes as the same NOP whatever FS is."""
    await _setup_test(dut)
    flw = _pack_i(imm=8, rs1=10, funct3=0b010, rd=3, opcode=OPC_LOAD_FP)
    fmadd = _pack_r4(rs3=7, fmt=0, rs2=6, rs1=5, rm=0, rd=4, opcode=OPC_FMADD)

    for raw in (flw, fmadd):
        packets = {}
        for fs_off in (1, 0):
            bubble = {
                "program_counter": BASE_PC,
                "instruction": raw,
                "inject_nop": True,
            }
            _drive_pd_packet(dut, bubble)
            _drive_pd_packet(
                dut, {**bubble, "program_counter": BASE_PC + 4}, slot2=True
            )
            dut.i_mstatus_fs_off.value = fs_off
            await _advance_cycle(dut)
            packets[fs_off] = (_read_id_packet(dut), _read_id_packet(dut, slot2=True))

        for packet in packets[1]:
            assert packet["instruction"] == NOP_INSTR, hex(raw)
            assert packet["instruction_operation"] == ADDI
            assert packet["is_illegal_instruction"] is False, hex(raw)
            assert packet["is_fp_instruction"] is False
            assert packet["is_fp_load"] is False
            assert packet["rs_type"] == RS_INT
            assert packet["has_int_dest"] is True
            assert packet["has_fp_dest"] is False
            assert packet["uses_int_rs1"] is True
            assert packet["uses_fp_rs1"] is False
            assert packet["is_real"] is False
        assert packets[1] == packets[0], hex(raw)
    dut.i_mstatus_fs_off.value = 0


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
        },
    )
    await _advance_cycle(dut)
    assert _read_id_packet(dut) == held_packet

    _drive_pipeline_ctrl(dut, {"flush": True})
    await _advance_cycle(dut)

    _assert_control_nop(_read_id_packet(dut))
    _assert_control_nop(_read_id_packet(dut, slot2=True))


@cocotb.test()
async def test_fp_fma_decodes_fp_sources(dut: Any) -> None:
    """FMADD.S decodes FP routing and reads three FP sources."""
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
        },
    )
    await _advance_cycle(dut)

    packet = _read_id_packet(dut)
    assert packet["instruction_operation"] == FMADD_S
    assert packet["rs_type"] == RS_FMUL
    assert packet["is_fp_instruction"] is True
    assert packet["fp_rm"] == 1
    assert packet["has_fp_dest"] is True
    assert packet["has_fp_flags"] is True
    assert packet["uses_fp_rs1"] is True
    assert packet["uses_fp_rs2"] is True
    assert packet["uses_fp_rs3"] is True


@cocotb.test()
async def test_pc_relative_precompute_for_auipc_and_fetch_faults(dut: Any) -> None:
    """ID precomputes AUIPC's PC + imm_u and a fetch fault's xtval for the RS immediate."""
    await _setup_test(dut)
    xlen_mask = (1 << XLEN) - 1
    auipc = ((0xFFFFF & 0xFFFFF) << 12) | (3 << 7) | OPC_AUIPC  # imm_u = -4096
    _drive_pd_packet(dut, {"program_counter": BASE_PC, "instruction": auipc})
    await _advance_cycle(dut)

    packet = _read_id_packet(dut)
    assert packet["instruction_operation"] == AUIPC
    assert packet["pc_relative_precomputed"] == (BASE_PC - 0x1000) & xlen_mask

    # Fetch-fault pseudo-op: the xtval is the PC, or PC + 2 when only the
    # second halfword of a page-straddling instruction faulted.
    for hi, expected in ((False, BASE_PC), (True, BASE_PC + 2)):
        _drive_pd_packet(
            dut,
            {
                "program_counter": BASE_PC,
                "instruction": auipc,
                "fetch_fault": True,
                "fetch_fault_hi": hi,
            },
        )
        await _advance_cycle(dut)
        packet = _read_id_packet(dut)
        assert packet["is_fetch_fault"] is True
        assert packet["pc_relative_precomputed"] == expected & xlen_mask


@cocotb.test()
async def test_ras_and_btb_target_checks_for_direct_branches(dut: Any) -> None:
    """Both prediction sources are compared against the precomputed direct target."""
    await _setup_test(dut)
    branch = _pack_b(imm=16, rs2=2, rs1=1, funct3=0, opcode=OPC_BRANCH)
    target = BASE_PC + 16

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": branch,
            "btb_predicted_taken": True,
            "btb_predicted_target": target,
            "ras_predicted": False,
            "ras_predicted_target": target + 4,
        },
    )
    await _advance_cycle(dut)
    packet = _read_id_packet(dut)
    assert packet["branch_target_precomputed"] == target
    assert packet["btb_correct_non_jalr"] is True
    assert packet["ras_correct_non_jalr"] is False

    _drive_pd_packet(
        dut,
        {
            "program_counter": BASE_PC,
            "instruction": branch,
            "btb_predicted_taken": True,
            "btb_predicted_target": target + 8,
            "ras_predicted": True,
            "ras_predicted_target": target,
        },
    )
    await _advance_cycle(dut)
    packet = _read_id_packet(dut)
    assert packet["btb_correct_non_jalr"] is False
    assert packet["ras_correct_non_jalr"] is True

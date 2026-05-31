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

"""Unit tests for the CPU OOO frontend validity/control-flow tracker."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
XLEN = 32
FLEN = 64
INSTR_OP_WIDTH = 32
BRANCH_OP_WIDTH = 3
STORE_OP_WIDTH = 2
RAS_PTR_BITS = 3
NOP_INSTR = 0x00000013
BRANCH_INSTR = 0x00000063
JALR_INSTR = 0x00000067
JAL_INSTR = 0x0000006F

OP_JAL = 21
OP_JALR = 22
OP_BEQ = 23

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


def _pack_pipeline_ctrl(fields: Mapping[str, int | bool]) -> int:
    """Pack a pipeline_ctrl_t value."""
    return _pack_struct(PIPELINE_CTRL_FIELDS, fields)


def _pack_if_to_pd(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_if_to_pd_t value."""
    return _pack_struct(IF_TO_PD_FIELDS, fields)


def _pack_pd_to_id(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_pd_to_id_t value."""
    return _pack_struct(PD_TO_ID_FIELDS, fields)


def _pack_id_to_ex(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_id_to_ex_t value."""
    return _pack_struct(ID_TO_EX_FIELDS, fields)


def _drive_pipeline_ctrl(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive pipeline control inputs."""
    dut.i_pipeline_ctrl.value = _pack_pipeline_ctrl(fields)


def _drive_if(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive IF-to-PD input with safe defaults."""
    packet = {
        "sel_nop": True,
        "effective_instr": NOP_INSTR,
        "raw_parcel": NOP_INSTR & 0xFFFF,
    }
    packet.update(fields)
    dut.i_from_if_to_pd.value = _pack_if_to_pd(packet)


def _drive_pd(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive PD-to-ID input with safe defaults."""
    packet = {"instruction": NOP_INSTR}
    packet.update(fields)
    dut.i_from_pd_to_id.value = _pack_pd_to_id(packet)


def _drive_id_slot(
    dut: Any,
    fields: Mapping[str, int | bool],
    *,
    slot2: bool = False,
) -> None:
    """Drive one ID-to-EX slot with safe defaults."""
    packet = {"instruction": NOP_INSTR}
    packet.update(fields)
    value = _pack_id_to_ex(packet)
    if slot2:
        dut.i_from_id_to_ex_2.value = value
    else:
        dut.i_from_id_to_ex.value = value


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    _drive_pipeline_ctrl(dut, {})
    _drive_if(dut, {})
    _drive_pd(dut, {})
    _drive_id_slot(dut, {})
    _drive_id_slot(dut, {}, slot2=True)
    dut.i_post_flush_holdoff_q.value = 0
    dut.i_dispatch_flush.value = 0
    dut.i_csr_in_flight.value = 0
    dut.i_id_stall_q.value = 0
    dut.i_replay_after_dispatch_stall_q.value = 0
    dut.i_flush_pipeline.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset tracker state, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await Timer(1, unit="ns")


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _prime_if_valid(dut: Any) -> None:
    """Advance one real IF instruction into the IF valid tracker."""
    _drive_if(dut, {"sel_nop": False, "effective_instr": NOP_INSTR})
    await _advance_cycle(dut)


async def _prime_pd_valid(dut: Any) -> None:
    """Advance one real IF instruction through the two-stage valid chain."""
    await _prime_if_valid(dut)
    await _advance_cycle(dut)


@cocotb.test()
async def test_valid_chain_and_two_slot_nop_filter(dut: Any) -> None:
    """IF/PD validity advances and slot-2 can make the bundle valid."""
    await _setup_test(dut)

    _drive_if(dut, {"sel_nop": False, "effective_instr": NOP_INSTR})
    _drive_id_slot(dut, {"is_not_nop": False})
    _drive_id_slot(dut, {"is_not_nop": True}, slot2=True)

    await _advance_cycle(dut)

    assert dut.o_if_valid_q.value
    assert not dut.o_pd_valid_q.value
    assert not dut.o_id_valid.value

    await _advance_cycle(dut)

    assert dut.o_pd_valid_q.value
    assert dut.o_id_valid.value
    assert dut.o_id_valid_2.value

    _drive_id_slot(dut, {"is_not_nop": True})
    _drive_id_slot(dut, {"is_not_nop": False}, slot2=True)
    await _settle()

    assert dut.o_id_valid.value
    assert not dut.o_id_valid_2.value


@cocotb.test()
async def test_flush_stall_and_holdoff_control_valid_chain(dut: Any) -> None:
    """Post-flush holdoff, stalls, and flushes control the valid chain."""
    await _setup_test(dut)

    dut.i_post_flush_holdoff_q.value = 1
    _drive_if(dut, {"sel_nop": False, "effective_instr": NOP_INSTR})
    await _advance_cycle(dut)

    assert not dut.o_if_valid_q.value
    assert not dut.o_pd_valid_q.value

    dut.i_post_flush_holdoff_q.value = 0
    await _advance_cycle(dut)

    assert dut.o_if_valid_q.value
    assert not dut.o_pd_valid_q.value

    _drive_pipeline_ctrl(dut, {"stall": True})
    _drive_if(dut, {"sel_nop": True, "effective_instr": NOP_INSTR})
    await _advance_cycle(dut)

    assert dut.o_if_valid_q.value
    assert not dut.o_pd_valid_q.value

    _drive_pipeline_ctrl(dut, {"flush": True})
    await _advance_cycle(dut)

    assert not dut.o_if_valid_q.value
    assert not dut.o_pd_valid_q.value


@cocotb.test()
async def test_id_valid_dispatch_csr_stall_and_replay_gates(dut: Any) -> None:
    """Dispatch flush, CSR in-flight, ID stall, and replay gate id_valid."""
    await _setup_test(dut)
    await _prime_pd_valid(dut)

    _drive_id_slot(dut, {"is_not_nop": True})
    await _settle()

    assert dut.o_id_valid.value

    dut.i_dispatch_flush.value = 1
    await _settle()
    assert not dut.o_id_valid.value
    dut.i_dispatch_flush.value = 0

    dut.i_csr_in_flight.value = 1
    await _settle()
    assert not dut.o_id_valid.value
    dut.i_csr_in_flight.value = 0

    dut.i_id_stall_q.value = 1
    await _settle()
    assert not dut.o_id_valid.value

    dut.i_replay_after_dispatch_stall_q.value = 1
    await _settle()
    assert dut.o_id_valid.value


@cocotb.test()
async def test_if_unpredicted_jalr_sets_indirect_pending(dut: Any) -> None:
    """An unpredicted IF-stage JALR raises indirect-control-flow pending."""
    await _setup_test(dut)

    _drive_if(
        dut,
        {
            "sel_nop": False,
            "effective_instr": JALR_INSTR,
            "btb_predicted_taken": True,
        },
    )
    await _advance_cycle(dut)

    assert not dut.o_front_end_indirect_control_flow_pending.value

    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)
    dut.i_flush_pipeline.value = 0
    _drive_if(dut, {"sel_nop": False, "effective_instr": JALR_INSTR})
    await _advance_cycle(dut)

    assert dut.o_front_end_indirect_control_flow_pending.value


@cocotb.test()
async def test_pd_prediction_fence_classification(dut: Any) -> None:
    """PD-stage unpredicted control flow selects branch/JAL/indirect fences."""
    await _setup_test(dut)
    await _prime_if_valid(dut)

    _drive_pd(dut, {"instruction": BRANCH_INSTR})
    await _settle()

    assert dut.o_pd_unpredicted_control_flow.value
    assert dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_jal.value
    assert not dut.o_prediction_fence_indirect.value

    _drive_pd(dut, {"instruction": JAL_INSTR})
    await _settle()

    assert dut.o_prediction_fence_jal.value
    assert not dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_indirect.value

    _drive_pd(dut, {"instruction": JALR_INSTR})
    await _settle()

    assert dut.o_prediction_fence_indirect.value
    assert dut.o_front_end_indirect_control_flow_pending.value
    assert not dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_jal.value

    _drive_pd(dut, {"instruction": BRANCH_INSTR, "btb_predicted_taken": True})
    await _settle()

    assert not dut.o_pd_unpredicted_control_flow.value
    assert not dut.o_prediction_fence_branch.value


@cocotb.test()
async def test_id_prediction_fence_priority_and_prediction_suppression(
    dut: Any,
) -> None:
    """ID-stage unpredicted control flow has priority and honors prediction."""
    await _setup_test(dut)
    await _prime_pd_valid(dut)

    _drive_pd(dut, {"instruction": BRANCH_INSTR})
    _drive_id_slot(dut, {"instruction_operation": OP_JALR, "is_not_nop": True})
    await _settle()

    assert dut.o_id_unpredicted_control_flow.value
    assert dut.o_prediction_fence_indirect.value
    assert not dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_jal.value

    _drive_pd(dut, {})
    _drive_id_slot(dut, {"instruction_operation": OP_JAL, "is_not_nop": True})
    await _settle()

    assert dut.o_prediction_fence_jal.value
    assert not dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_indirect.value

    _drive_id_slot(dut, {"instruction_operation": OP_BEQ, "is_not_nop": True})
    await _settle()

    assert dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_jal.value
    assert not dut.o_prediction_fence_indirect.value

    _drive_id_slot(
        dut,
        {
            "instruction_operation": OP_JALR,
            "is_not_nop": True,
            "ras_predicted": True,
        },
    )
    await _settle()

    assert not dut.o_id_unpredicted_control_flow.value
    assert not dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_jal.value
    assert not dut.o_prediction_fence_indirect.value

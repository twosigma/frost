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
from cocotb_tests.cpu_structs import (
    PIPELINE_CTRL_FIELDS,
    IF_TO_PD_FIELDS,
    PD_TO_ID_FIELDS,
    ID_TO_EX_FIELDS,
)
from utils.packed_structs import (
    pack_struct as _pack_struct,
)


CLOCK_PERIOD_NS = 10
NOP_INSTR = 0x00000013
BRANCH_INSTR = 0x00000063
JALR_INSTR = 0x00000067
RETURN_INSTR = 0x00008067  # jalr x0, 0(ra)
JAL_INSTR = 0x0000006F

OP_JAL = 21
OP_JALR = 22
OP_BEQ = 23


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
    packet_fields = dict(fields)
    has_control_flow = bool(packet_fields.pop("has_control_flow", False))
    packet = {
        "sel_nop": True,
        "effective_instr": NOP_INSTR,
        "raw_parcel": NOP_INSTR & 0xFFFF,
    }
    packet.update(packet_fields)
    if "effective_instr" in packet_fields and "raw_parcel" not in packet_fields:
        packet["raw_parcel"] = int(packet_fields["effective_instr"]) & 0xFFFF
    dut.i_from_if_to_pd.value = _pack_if_to_pd(packet)
    dut.i_if_has_control_flow.value = has_control_flow


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
    dut.i_id_stall_q.value = 0
    dut.i_replay_after_dispatch_stall_q.value = 0
    dut.i_flush_pipeline.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset tracker state, and clear inputs."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
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
async def test_valid_chain_and_two_slot_bubble_filter(dut: Any) -> None:
    """IF/PD validity advances, slot 2 can make the bundle valid, and two bubbles cannot."""
    await _setup_test(dut)

    _drive_if(dut, {"sel_nop": False, "effective_instr": NOP_INSTR})
    _drive_id_slot(dut, {"is_real": False})
    _drive_id_slot(dut, {"is_real": True}, slot2=True)

    await _advance_cycle(dut)

    assert dut.o_if_valid_q.value
    assert not dut.o_pd_valid_q.value
    assert not dut.o_id_valid.value

    await _advance_cycle(dut)

    assert dut.o_pd_valid_q.value
    assert dut.o_id_valid_preflush.value
    assert dut.o_id_valid_2_preflush.value
    assert dut.o_id_valid.value
    assert dut.o_id_valid_2.value

    _drive_id_slot(dut, {"is_real": True})
    _drive_id_slot(dut, {"is_real": False}, slot2=True)
    await _settle()

    assert dut.o_id_valid_preflush.value
    assert not dut.o_id_valid_2_preflush.value
    assert dut.o_id_valid.value
    assert not dut.o_id_valid_2.value

    # A PD-redirect bubble reaches ID with a valid chain but clears is_real in
    # both slots, so the bundle is no candidate.
    _drive_id_slot(dut, {"is_real": False})
    _drive_id_slot(dut, {"is_real": False}, slot2=True)
    await _settle()

    assert dut.o_pd_valid_q.value
    assert not dut.o_id_valid_preflush.value
    assert not dut.o_id_valid_2_preflush.value


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
async def test_id_valid_dispatch_stall_and_replay_gates(dut: Any) -> None:
    """A dispatch flush clears only the qualified ID valids; id_stall_q clears all four.

    A dispatch-stall replay (i_replay_after_dispatch_stall_q) overrides id_stall_q.
    """
    await _setup_test(dut)
    await _prime_pd_valid(dut)

    _drive_id_slot(dut, {"is_real": True})
    _drive_id_slot(dut, {"is_real": True}, slot2=True)
    await _settle()

    assert dut.o_id_valid_preflush.value
    assert dut.o_id_valid_2_preflush.value
    assert dut.o_id_valid.value
    assert dut.o_id_valid_2.value

    dut.i_dispatch_flush.value = 1
    await _settle()
    assert dut.o_id_valid_preflush.value
    assert dut.o_id_valid_2_preflush.value
    assert not dut.o_id_valid.value
    assert not dut.o_id_valid_2.value
    dut.i_dispatch_flush.value = 0

    dut.i_id_stall_q.value = 1
    await _settle()
    assert not dut.o_id_valid_preflush.value
    assert not dut.o_id_valid_2_preflush.value
    assert not dut.o_id_valid.value
    assert not dut.o_id_valid_2.value

    dut.i_replay_after_dispatch_stall_q.value = 1
    await _settle()
    assert dut.o_id_valid_preflush.value
    assert dut.o_id_valid_2_preflush.value
    assert dut.o_id_valid.value
    assert dut.o_id_valid_2.value


@cocotb.test()
async def test_if_unpredicted_jalr_held_by_stall_sets_indirect_pending(
    dut: Any,
) -> None:
    """An unpredicted JALR that a stall holds in IF raises indirect pending.

    The IF term is registered, so it describes the packet IF presented in the
    previous cycle, and it counts only while a stall has kept that packet in
    IF. A predicted JALR never raises it, and a flush clears it. Once an
    unstalled edge hands the JALR to PD, the PD term flags it instead.
    """
    await _setup_test(dut)
    held = {"stall": True, "stall_registered": True}
    jalr = {"sel_nop": False, "effective_instr": JALR_INSTR, "has_control_flow": True}

    _drive_pipeline_ctrl(dut, held)
    _drive_if(dut, {**jalr, "btb_predicted_taken": True})
    await _advance_cycle(dut)
    assert not dut.o_front_end_indirect_control_flow_pending.value

    _drive_if(dut, jalr)
    await _advance_cycle(dut)
    assert dut.o_front_end_indirect_control_flow_pending.value

    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)
    assert not dut.o_front_end_indirect_control_flow_pending.value
    dut.i_flush_pipeline.value = 0
    await _advance_cycle(dut)
    assert dut.o_front_end_indirect_control_flow_pending.value

    # Release cycle: the stall drops, and IF still presents the held JALR.
    _drive_pipeline_ctrl(dut, {"stall_registered": True})
    await _settle()
    assert dut.o_front_end_indirect_control_flow_pending.value

    # The unstalled edge hands the JALR to PD. The PD term flags it there; the
    # IF term still holds its class, but stall_registered is low, so it is
    # masked.
    await _advance_cycle(dut)
    _drive_pipeline_ctrl(dut, {})
    _drive_if(dut, {})
    _drive_pd(dut, {"instruction": JALR_INSTR})
    await _settle()
    assert dut.o_front_end_indirect_control_flow_pending.value
    _drive_pd(dut, {})
    await _settle()
    assert not dut.o_front_end_indirect_control_flow_pending.value


@cocotb.test()
async def test_if_term_takes_class_and_prediction_from_one_packet(dut: Any) -> None:
    """A BTB-missed branch followed by a predicted return raises nothing.

    The IF term samples the indirect class and the prediction bit from the
    same IF packet. Pairing the branch's missing prediction with the next
    packet's indirect class would flag the predicted return. The sequence runs
    once with IF advancing and once with both stall inputs held high, so the
    sampled registers are also checked with the stall gate open.
    """
    await _setup_test(dut)
    held = {"stall": True, "stall_registered": True}

    for ctrl in ({}, held):
        _drive_pipeline_ctrl(dut, ctrl)
        _drive_if(
            dut,
            {
                "sel_nop": False,
                "effective_instr": BRANCH_INSTR,
                "has_control_flow": True,
            },
        )
        await _advance_cycle(dut)
        _drive_if(
            dut,
            {
                "sel_nop": False,
                "effective_instr": RETURN_INSTR,
                "has_control_flow": True,
                "btb_predicted_taken": True,
            },
        )
        await _settle()
        assert not dut.o_front_end_indirect_control_flow_pending.value, ctrl
        await _advance_cycle(dut)
        assert not dut.o_front_end_indirect_control_flow_pending.value, ctrl

    # An unpredicted JALR that leaves IF on an unstalled edge is PD's to flag.
    _drive_pipeline_ctrl(dut, {})
    _drive_if(
        dut, {"sel_nop": False, "effective_instr": JALR_INSTR, "has_control_flow": True}
    )
    await _advance_cycle(dut)
    _drive_if(
        dut, {"sel_nop": False, "effective_instr": JALR_INSTR, "has_control_flow": True}
    )
    await _settle()
    assert not dut.o_front_end_indirect_control_flow_pending.value


@cocotb.test()
async def test_pd_prediction_fence_classification(dut: Any) -> None:
    """PD-stage unpredicted control flow selects branch/JAL/indirect fences."""
    await _setup_test(dut)
    await _prime_if_valid(dut)

    _drive_pd(dut, {"instruction": BRANCH_INSTR})
    await _settle()

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

    assert not dut.o_prediction_fence_branch.value


@cocotb.test()
async def test_id_prediction_fence_priority_and_prediction_suppression(
    dut: Any,
) -> None:
    """ID-stage unpredicted control flow has priority and honors prediction."""
    await _setup_test(dut)
    await _prime_pd_valid(dut)

    _drive_pd(dut, {"instruction": BRANCH_INSTR})
    _drive_id_slot(dut, {"instruction_operation": OP_JALR, "is_real": True})
    await _settle()

    assert dut.o_front_end_indirect_control_flow_pending.value
    assert dut.o_prediction_fence_indirect.value
    assert not dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_jal.value

    _drive_pd(dut, {})
    _drive_id_slot(dut, {"instruction_operation": OP_JAL, "is_real": True})
    await _settle()

    assert dut.o_prediction_fence_jal.value
    assert not dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_indirect.value

    _drive_id_slot(dut, {"instruction_operation": OP_BEQ, "is_real": True})
    await _settle()

    assert dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_jal.value
    assert not dut.o_prediction_fence_indirect.value

    _drive_id_slot(
        dut,
        {
            "instruction_operation": OP_JALR,
            "is_real": True,
            "btb_predicted_taken": True,
        },
    )
    await _settle()

    assert not dut.o_front_end_indirect_control_flow_pending.value
    assert not dut.o_prediction_fence_branch.value
    assert not dut.o_prediction_fence_jal.value
    assert not dut.o_prediction_fence_indirect.value

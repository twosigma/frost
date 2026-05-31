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

"""Unit tests for the CPU OOO pipeline-control block."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
XLEN = 32
FLEN = 64
ROB_TAG_WIDTH = 5
CHECKPOINT_ID_WIDTH = 3
REG_ADDR_WIDTH = 5
EXC_CAUSE_WIDTH = 5
FP_FLAGS_WIDTH = 5
RS_TYPE_WIDTH = 3

PIPELINE_CTRL_FIELDS = [
    ("reset", 1),
    ("stall", 1),
    ("stall_registered", 1),
    ("stall_for_trap_check", 1),
    ("flush", 1),
    ("trap_taken_registered", 1),
    ("mret_taken_registered", 1),
]

ALLOC_REQ_FIELDS = [
    ("alloc_valid", 1),
    ("pc", XLEN),
    ("rs_type", RS_TYPE_WIDTH),
    ("dest_rf", 1),
    ("dest_reg", REG_ADDR_WIDTH),
    ("dest_valid", 1),
    ("is_store", 1),
    ("is_fp_store", 1),
    ("is_branch", 1),
    ("predicted_taken", 1),
    ("predicted_target", XLEN),
    ("branch_target", XLEN),
    ("is_call", 1),
    ("is_return", 1),
    ("link_addr", XLEN),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_csr", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_wfi", 1),
    ("is_mret", 1),
    ("is_amo", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_compressed", 1),
    ("csr_addr", 12),
    ("csr_op", 3),
    ("csr_write_data", XLEN),
    ("has_fp_flags", 1),
]

COMMIT_FIELDS = [
    ("valid", 1),
    ("tag", ROB_TAG_WIDTH),
    ("dest_rf", 1),
    ("dest_reg", REG_ADDR_WIDTH),
    ("dest_valid", 1),
    ("value", FLEN),
    ("is_store", 1),
    ("is_fp_store", 1),
    ("exception", 1),
    ("pc", XLEN),
    ("exc_cause", EXC_CAUSE_WIDTH),
    ("fp_flags", FP_FLAGS_WIDTH),
    ("has_fp_flags", 1),
    ("misprediction", 1),
    ("early_recovered", 1),
    ("has_checkpoint", 1),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("redirect_pc", XLEN),
    ("predicted_taken", 1),
    ("branch_taken", 1),
    ("branch_target", XLEN),
    ("is_branch", 1),
    ("is_call", 1),
    ("is_return", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("csr_addr", 12),
    ("csr_op", 3),
    ("csr_write_data", XLEN),
    ("is_csr", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_wfi", 1),
    ("is_mret", 1),
    ("is_amo", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_compressed", 1),
]

MISPREDICT_COMMIT_FIELDS = [
    ("tag", ROB_TAG_WIDTH),
    ("has_checkpoint", 1),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("redirect_pc", XLEN),
    ("pc", XLEN),
    ("branch_target", XLEN),
    ("branch_taken", 1),
    ("is_branch", 1),
    ("is_call", 1),
    ("is_return", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_compressed", 1),
]

QUIESCENT_COMMIT: dict[str, int | bool] = {"valid": True, "dest_valid": True}


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


def _unpack_struct(
    fields: list[tuple[str, int]],
    packed: int,
) -> dict[str, int | bool]:
    """Unpack a SystemVerilog packed struct into named Python values."""
    result: dict[str, int | bool] = {}
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = (packed >> offset) & ((1 << width) - 1)
        result[name] = bool(raw) if width == 1 else raw
    return result


def _pack_alloc_req(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_alloc_req_t value."""
    return _pack_struct(ALLOC_REQ_FIELDS, fields)


def _pack_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_commit_t value."""
    return _pack_struct(COMMIT_FIELDS, fields)


def _pack_mispredict_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a mispredict_commit_capture_t value."""
    return _pack_struct(MISPREDICT_COMMIT_FIELDS, fields)


def _read_pipeline_ctrl(dut: Any) -> dict[str, int | bool]:
    """Read and unpack the pipeline_ctrl_t output."""
    return _unpack_struct(PIPELINE_CTRL_FIELDS, int(dut.o_pipeline_ctrl.value))


def _drive_alloc_req(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the ROB allocation request struct."""
    dut.i_rob_alloc_req.value = _pack_alloc_req(fields)


def _drive_commit(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the ROB commit struct."""
    packet = dict(QUIESCENT_COMMIT)
    packet.update(fields)
    dut.i_rob_commit.value = _pack_commit(packet)


def _drive_mispredict_commit(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the captured commit-time misprediction payload."""
    dut.i_mispredict_commit_q.value = _pack_mispredict_commit(fields)


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    _drive_alloc_req(dut, {})
    _drive_commit(dut, QUIESCENT_COMMIT)
    _drive_mispredict_commit(dut, {})
    dut.i_rob_checkpoint_valid.value = 0
    dut.i_csr_commit_fire.value = 0
    dut.i_correct_branch_commit_pending.value = 0
    dut.i_mispredict_recovery_pending.value = 0
    dut.i_trap_taken.value = 0
    dut.i_mret_taken.value = 0
    dut.i_trap_target.value = 0
    dut.i_dispatch_stall.value = 0
    dut.i_csr_wb_pending.value = 0
    dut.i_branch_unresolved_decrement.value = 0
    dut.i_front_end_indirect_control_flow_pending.value = 0
    dut.i_pd_unpredicted_control_flow.value = 0
    dut.i_id_unpredicted_control_flow.value = 0
    dut.i_disable_branch_prediction.value = 0
    dut.i_flush_pipeline.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset pipeline-control state, and clear inputs."""
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


@cocotb.test()
async def test_idle_outputs_and_global_prediction_disable(dut: Any) -> None:
    """Idle state has no stalls, and the global prediction-disable gate passes through."""
    await _setup_test(dut)

    ctrl = _read_pipeline_ctrl(dut)
    assert not ctrl["reset"]
    assert not ctrl["stall"]
    assert not ctrl["stall_registered"]
    assert not ctrl["flush"]
    assert int(dut.o_branch_in_flight_count.value) == 0
    assert not dut.o_serializing_alloc_fire.value
    assert not dut.o_csr_in_flight.value
    assert not dut.o_disable_branch_prediction_ooo.value

    dut.i_disable_branch_prediction.value = 1
    await _settle()

    assert dut.o_disable_branch_prediction_ooo.value


@cocotb.test()
async def test_dispatch_stall_drives_pipeline_ctrl_and_replay(dut: Any) -> None:
    """Dispatch stalls assert frontend stall fields and the dispatch replay pulse."""
    await _setup_test(dut)

    dut.i_dispatch_stall.value = 1
    await _settle()

    ctrl = _read_pipeline_ctrl(dut)
    assert ctrl["stall"]
    assert ctrl["stall_for_trap_check"]
    assert not ctrl["flush"]

    await _advance_cycle(dut)

    ctrl = _read_pipeline_ctrl(dut)
    assert ctrl["stall_registered"]
    assert dut.o_stall_q.value
    assert dut.o_id_stall_q.value
    assert dut.o_replay_after_dispatch_stall_q.value

    dut.i_flush_pipeline.value = 1
    await _settle()

    ctrl = _read_pipeline_ctrl(dut)
    assert not ctrl["stall"]
    assert ctrl["stall_for_trap_check"]
    assert ctrl["flush"]

    await _advance_cycle(dut)

    assert not dut.o_id_stall_q.value
    assert not dut.o_replay_after_dispatch_stall_q.value


@cocotb.test()
async def test_csr_allocation_stalls_until_commit_and_replays(dut: Any) -> None:
    """CSR allocation tracks in-flight serialization until commit releases it."""
    await _setup_test(dut)

    _drive_alloc_req(dut, {"alloc_valid": True, "is_csr": True})
    await _advance_cycle(dut)

    assert dut.o_serializing_alloc_fire.value
    assert dut.o_csr_in_flight.value
    assert dut.o_disable_branch_prediction_ooo.value
    assert _read_pipeline_ctrl(dut)["stall"]

    _drive_alloc_req(dut, {})
    await _advance_cycle(dut)

    assert not dut.o_serializing_alloc_fire.value
    assert dut.o_csr_in_flight.value
    assert dut.o_stall_q.value
    assert dut.o_id_stall_q.value

    _drive_commit(dut, {"valid": True, "dest_valid": False})
    dut.i_csr_commit_fire.value = 1
    await _advance_cycle(dut)

    assert not dut.o_csr_in_flight.value
    assert not _read_pipeline_ctrl(dut)["stall"]
    assert dut.o_replay_after_serialize_stall_q.value
    assert not dut.o_id_stall_q.value

    dut.i_csr_commit_fire.value = 0
    await _advance_cycle(dut)

    assert not dut.o_replay_after_serialize_stall_q.value


@cocotb.test()
async def test_csr_wb_pending_generates_serialize_replay(dut: Any) -> None:
    """A pending CSR writeback stalls and produces the serialize replay pulse."""
    await _setup_test(dut)

    dut.i_csr_wb_pending.value = 1
    await _settle()

    assert _read_pipeline_ctrl(dut)["stall"]

    await _advance_cycle(dut)

    assert dut.o_stall_q.value
    assert not dut.o_id_stall_q.value
    assert dut.o_replay_after_serialize_stall_q.value

    dut.i_csr_wb_pending.value = 0
    await _advance_cycle(dut)

    assert not dut.o_replay_after_serialize_stall_q.value


@cocotb.test()
async def test_branch_in_flight_counter_balances_alloc_and_commit(dut: Any) -> None:
    """Branch checkpoint allocations and commit/recovery releases balance the count."""
    await _setup_test(dut)

    dut.i_rob_checkpoint_valid.value = 1
    await _advance_cycle(dut)

    assert int(dut.o_branch_in_flight_count.value) == 1

    dut.i_correct_branch_commit_pending.value = 1
    await _advance_cycle(dut)

    assert int(dut.o_branch_in_flight_count.value) == 1

    dut.i_rob_checkpoint_valid.value = 0
    await _advance_cycle(dut)

    assert int(dut.o_branch_in_flight_count.value) == 0

    await _advance_cycle(dut)

    assert int(dut.o_branch_in_flight_count.value) == 0

    dut.i_rob_checkpoint_valid.value = 1
    dut.i_correct_branch_commit_pending.value = 0
    await _advance_cycle(dut)

    assert int(dut.o_branch_in_flight_count.value) == 1

    dut.i_rob_checkpoint_valid.value = 0
    dut.i_mispredict_recovery_pending.value = 1
    _drive_mispredict_commit(dut, {"has_checkpoint": False})
    await _advance_cycle(dut)

    assert int(dut.o_branch_in_flight_count.value) == 1

    _drive_mispredict_commit(dut, {"has_checkpoint": True})
    await _advance_cycle(dut)

    assert int(dut.o_branch_in_flight_count.value) == 0


@cocotb.test()
async def test_unresolved_branch_serializes_younger_indirect_control_flow(
    dut: Any,
) -> None:
    """An unresolved non-JAL branch serializes younger indirect control flow."""
    await _setup_test(dut)

    _drive_alloc_req(dut, {"alloc_valid": True, "is_branch": True})
    await _advance_cycle(dut)

    _drive_alloc_req(dut, {})
    dut.i_front_end_indirect_control_flow_pending.value = 1
    await _advance_cycle(dut)

    assert dut.o_front_end_cf_serialize_stall.value
    assert _read_pipeline_ctrl(dut)["stall"]

    dut.i_branch_unresolved_decrement.value = 1
    await _advance_cycle(dut)

    assert dut.o_front_end_cf_serialize_stall.value

    dut.i_branch_unresolved_decrement.value = 0
    await _advance_cycle(dut)

    assert not dut.o_front_end_cf_serialize_stall.value


@cocotb.test()
async def test_jal_alloc_does_not_create_unresolved_branch_stall(dut: Any) -> None:
    """JAL checkpoint allocation is not tracked as unresolved branch work."""
    await _setup_test(dut)

    _drive_alloc_req(dut, {"alloc_valid": True, "is_branch": True, "is_jal": True})
    await _advance_cycle(dut)

    _drive_alloc_req(dut, {})
    dut.i_front_end_indirect_control_flow_pending.value = 1
    await _advance_cycle(dut)

    assert not dut.o_front_end_cf_serialize_stall.value
    assert not _read_pipeline_ctrl(dut)["stall"]


@cocotb.test()
async def test_flush_clears_serialization_and_starts_holdoff(dut: Any) -> None:
    """Flush clears serialization state and starts a stall-sensitive holdoff."""
    await _setup_test(dut)

    _drive_alloc_req(dut, {"alloc_valid": True, "is_csr": True})
    dut.i_rob_checkpoint_valid.value = 1
    await _advance_cycle(dut)

    assert dut.o_csr_in_flight.value
    assert int(dut.o_branch_in_flight_count.value) == 1

    _drive_alloc_req(dut, {})
    dut.i_rob_checkpoint_valid.value = 0
    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)

    assert not dut.o_csr_in_flight.value
    assert not dut.o_serializing_alloc_fire.value
    assert int(dut.o_branch_in_flight_count.value) == 0
    assert int(dut.o_post_flush_holdoff_q.value) == 1

    dut.i_flush_pipeline.value = 0
    dut.i_dispatch_stall.value = 1
    await _advance_cycle(dut)

    assert int(dut.o_post_flush_holdoff_q.value) == 1

    dut.i_dispatch_stall.value = 0
    await _advance_cycle(dut)

    assert int(dut.o_post_flush_holdoff_q.value) == 0


@cocotb.test()
async def test_trap_and_mret_are_registered_with_target(dut: Any) -> None:
    """Trap and MRET pulses are delayed one cycle with their target."""
    await _setup_test(dut)

    dut.i_trap_taken.value = 1
    dut.i_trap_target.value = 0x80000100
    await _advance_cycle(dut)

    ctrl = _read_pipeline_ctrl(dut)
    assert dut.o_trap_taken_reg.value
    assert ctrl["trap_taken_registered"]
    assert not ctrl["mret_taken_registered"]
    assert int(dut.o_trap_target_reg.value) == 0x80000100

    dut.i_trap_taken.value = 0
    dut.i_mret_taken.value = 1
    dut.i_trap_target.value = 0x80000200
    await _advance_cycle(dut)

    ctrl = _read_pipeline_ctrl(dut)
    assert not dut.o_trap_taken_reg.value
    assert dut.o_mret_taken_reg.value
    assert not ctrl["trap_taken_registered"]
    assert ctrl["mret_taken_registered"]
    assert int(dut.o_trap_target_reg.value) == 0x80000200

    dut.i_mret_taken.value = 0
    await _advance_cycle(dut)

    assert not dut.o_trap_taken_reg.value
    assert not dut.o_mret_taken_reg.value

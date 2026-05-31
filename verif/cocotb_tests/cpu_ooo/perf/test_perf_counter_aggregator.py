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

"""Unit tests for the CPU OOO performance-counter aggregator."""

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

PERF_TOP_COUNTER_COUNT = 23
PERF_COUNTER_COUNT = 83
PERF_WRAPPER_BASE = PERF_TOP_COUNTER_COUNT

PERF_DISPATCH_FIRE = 0
PERF_DISPATCH_STALL = 1
PERF_FRONTEND_BUBBLE = 2
PERF_FLUSH_RECOVERY = 3
PERF_POST_FLUSH_HOLDOFF = 4
PERF_CSR_SERIALIZE = 5
PERF_CONTROL_FLOW_SERIALIZE = 6
PERF_DISPATCH_STALL_ROB_FULL = 7
PERF_DISPATCH_STALL_INT_RS_FULL = 8
PERF_DISPATCH_STALL_MUL_RS_FULL = 9
PERF_DISPATCH_STALL_MEM_RS_FULL = 10
PERF_DISPATCH_STALL_FP_RS_FULL = 11
PERF_DISPATCH_STALL_FMUL_RS_FULL = 12
PERF_DISPATCH_STALL_FDIV_RS_FULL = 13
PERF_DISPATCH_STALL_LQ_FULL = 14
PERF_DISPATCH_STALL_SQ_FULL = 15
PERF_DISPATCH_STALL_CHECKPOINT_FULL = 16
PERF_NO_RETIRE_NOT_EMPTY = 17
PERF_ROB_EMPTY = 18
PERF_PREDICTION_DISABLED = 19
PERF_PREDICTION_FENCE_BRANCH = 20
PERF_PREDICTION_FENCE_JAL = 21
PERF_PREDICTION_FENCE_INDIRECT = 22

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

DISPATCH_STATUS_FIELDS = [
    ("dispatch_valid", 1),
    ("stall", 1),
    ("reorder_buffer_full", 1),
    ("int_rs_full", 1),
    ("mul_rs_full", 1),
    ("mem_rs_full", 1),
    ("fp_rs_full", 1),
    ("fmul_rs_full", 1),
    ("fdiv_rs_full", 1),
    ("lq_full", 1),
    ("sq_full", 1),
    ("checkpoint_full", 1),
]

QUIESCENT_DISPATCH_STATUS: dict[str, int | bool] = {"dispatch_valid": True}
QUIESCENT_COMMIT: dict[str, int | bool] = {"valid": True}


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


def _pack_alloc_req(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_alloc_req_t value."""
    return _pack_struct(ALLOC_REQ_FIELDS, fields)


def _pack_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_commit_t value."""
    return _pack_struct(COMMIT_FIELDS, fields)


def _pack_dispatch_status(fields: Mapping[str, int | bool]) -> int:
    """Pack a dispatch_status_t value."""
    return _pack_struct(DISPATCH_STATUS_FIELDS, fields)


def _drive_alloc_req(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the ROB allocation request struct."""
    dut.i_rob_alloc_req.value = _pack_alloc_req(fields)


def _drive_commit(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the ROB commit struct."""
    packet = dict(QUIESCENT_COMMIT)
    packet.update(fields)
    dut.i_rob_commit_comb.value = _pack_commit(packet)


def _drive_dispatch_status(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the dispatch status struct."""
    packet = dict(QUIESCENT_DISPATCH_STATUS)
    packet.update(fields)
    dut.i_dispatch_status.value = _pack_dispatch_status(packet)


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to a quiescent no-increment state."""
    _drive_alloc_req(dut, {})
    _drive_dispatch_status(dut, QUIESCENT_DISPATCH_STATUS)
    _drive_commit(dut, QUIESCENT_COMMIT)
    dut.i_flush_pipeline.value = 0
    dut.i_post_flush_holdoff_q.value = 0
    dut.i_csr_in_flight.value = 0
    dut.i_csr_wb_pending.value = 0
    dut.i_serializing_alloc_fire.value = 0
    dut.i_front_end_cf_serialize_stall.value = 0
    dut.i_rob_empty.value = 0
    dut.i_disable_branch_prediction_ooo.value = 0
    dut.i_disable_branch_prediction.value = 0
    dut.i_prediction_fence_branch.value = 0
    dut.i_prediction_fence_jal.value = 0
    dut.i_prediction_fence_indirect.value = 0
    dut.i_perf_counter_select.value = 0
    dut.i_perf_snapshot_capture.value = 0
    dut.i_wrapper_perf_counter_data.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the aggregator, and clear inputs."""
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


async def _capture_snapshot(dut: Any) -> None:
    """Capture the live top-counter bank into the CSR-visible snapshot bank."""
    dut.i_perf_snapshot_capture.value = 1
    await _advance_cycle(dut)
    dut.i_perf_snapshot_capture.value = 0
    await _settle()


async def _read_counter(dut: Any, index: int) -> int:
    """Read a selected counter through the two-stage registered CSR path."""
    dut.i_perf_counter_select.value = index
    await _advance_cycle(dut)
    await _advance_cycle(dut)
    return int(dut.o_perf_counter_data_q.value)


async def _finish_event_pipeline(dut: Any) -> None:
    """Clear event inputs and advance once so the delayed increment is live."""
    _clear_inputs(dut)
    await _advance_cycle(dut)


@cocotb.test()
async def test_counter_count_and_idle_snapshot_are_zero(dut: Any) -> None:
    """The aggregate exposes all counters and an idle snapshot reads as zero."""
    await _setup_test(dut)

    await _capture_snapshot(dut)

    assert int(dut.o_perf_counter_count.value) == PERF_COUNTER_COUNT
    assert await _read_counter(dut, PERF_DISPATCH_FIRE) == 0
    assert await _read_counter(dut, PERF_FRONTEND_BUBBLE) == 0
    assert await _read_counter(dut, PERF_ROB_EMPTY) == 0


@cocotb.test()
async def test_dispatch_activity_and_resource_stall_counters(dut: Any) -> None:
    """Dispatch fire, stall, and per-resource stall reasons accumulate."""
    await _setup_test(dut)

    _drive_alloc_req(dut, {"alloc_valid": True})
    _drive_dispatch_status(
        dut,
        {
            "dispatch_valid": False,
            "stall": True,
            "reorder_buffer_full": True,
            "int_rs_full": True,
        },
    )
    await _advance_cycle(dut)

    _drive_alloc_req(dut, {"alloc_valid": True})
    _drive_dispatch_status(
        dut,
        {
            "dispatch_valid": False,
            "stall": True,
            "mem_rs_full": True,
            "fp_rs_full": True,
            "fmul_rs_full": True,
            "fdiv_rs_full": True,
            "lq_full": True,
            "sq_full": True,
            "checkpoint_full": True,
        },
    )
    await _advance_cycle(dut)

    await _finish_event_pipeline(dut)
    await _capture_snapshot(dut)

    expected = {
        PERF_DISPATCH_FIRE: 2,
        PERF_DISPATCH_STALL: 2,
        PERF_DISPATCH_STALL_ROB_FULL: 1,
        PERF_DISPATCH_STALL_INT_RS_FULL: 1,
        PERF_DISPATCH_STALL_MUL_RS_FULL: 0,
        PERF_DISPATCH_STALL_MEM_RS_FULL: 1,
        PERF_DISPATCH_STALL_FP_RS_FULL: 1,
        PERF_DISPATCH_STALL_FMUL_RS_FULL: 1,
        PERF_DISPATCH_STALL_FDIV_RS_FULL: 1,
        PERF_DISPATCH_STALL_LQ_FULL: 1,
        PERF_DISPATCH_STALL_SQ_FULL: 1,
        PERF_DISPATCH_STALL_CHECKPOINT_FULL: 1,
    }
    for counter, value in expected.items():
        assert await _read_counter(dut, counter) == value


@cocotb.test()
async def test_frontend_bubble_and_serialization_counters(dut: Any) -> None:
    """Frontend bubbles count only when no stall, flush, or serializer blocks."""
    await _setup_test(dut)

    _drive_dispatch_status(dut, {"dispatch_valid": False})
    await _advance_cycle(dut)

    _drive_dispatch_status(dut, {"dispatch_valid": False})
    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)
    dut.i_flush_pipeline.value = 0

    _drive_dispatch_status(dut, {"dispatch_valid": False})
    dut.i_post_flush_holdoff_q.value = 2
    await _advance_cycle(dut)
    dut.i_post_flush_holdoff_q.value = 0

    _drive_dispatch_status(dut, {"dispatch_valid": False, "stall": True})
    await _advance_cycle(dut)

    _drive_dispatch_status(dut, {"dispatch_valid": False})
    dut.i_csr_in_flight.value = 1
    await _advance_cycle(dut)
    dut.i_csr_in_flight.value = 0

    dut.i_csr_wb_pending.value = 1
    await _advance_cycle(dut)
    dut.i_csr_wb_pending.value = 0

    dut.i_serializing_alloc_fire.value = 1
    await _advance_cycle(dut)
    dut.i_serializing_alloc_fire.value = 0

    dut.i_front_end_cf_serialize_stall.value = 1
    await _advance_cycle(dut)

    await _finish_event_pipeline(dut)
    await _capture_snapshot(dut)

    assert await _read_counter(dut, PERF_FRONTEND_BUBBLE) == 1
    assert await _read_counter(dut, PERF_FLUSH_RECOVERY) == 1
    assert await _read_counter(dut, PERF_POST_FLUSH_HOLDOFF) == 1
    assert await _read_counter(dut, PERF_DISPATCH_STALL) == 1
    assert await _read_counter(dut, PERF_CSR_SERIALIZE) == 3
    assert await _read_counter(dut, PERF_CONTROL_FLOW_SERIALIZE) == 1


@cocotb.test()
async def test_retire_and_empty_rob_counters_ignore_flush(dut: Any) -> None:
    """ROB-empty and no-retire-not-empty counters increment only outside flush."""
    await _setup_test(dut)

    _drive_commit(dut, {"valid": False})
    dut.i_rob_empty.value = 0
    await _advance_cycle(dut)

    _drive_commit(dut, {"valid": False})
    dut.i_rob_empty.value = 1
    await _advance_cycle(dut)

    _drive_commit(dut, {"valid": False})
    dut.i_rob_empty.value = 0
    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)

    _drive_commit(dut, {"valid": False})
    dut.i_rob_empty.value = 1
    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)

    await _finish_event_pipeline(dut)
    await _capture_snapshot(dut)

    assert await _read_counter(dut, PERF_NO_RETIRE_NOT_EMPTY) == 1
    assert await _read_counter(dut, PERF_ROB_EMPTY) == 1


@cocotb.test()
async def test_prediction_disable_and_fence_counters(dut: Any) -> None:
    """Prediction-disabled and prediction-fence counters use their gates."""
    await _setup_test(dut)

    dut.i_disable_branch_prediction_ooo.value = 1
    dut.i_disable_branch_prediction.value = 0
    await _advance_cycle(dut)

    dut.i_disable_branch_prediction_ooo.value = 1
    dut.i_disable_branch_prediction.value = 1
    await _advance_cycle(dut)

    dut.i_disable_branch_prediction_ooo.value = 0
    dut.i_disable_branch_prediction.value = 0
    dut.i_prediction_fence_branch.value = 1
    await _advance_cycle(dut)

    dut.i_prediction_fence_branch.value = 0
    dut.i_prediction_fence_jal.value = 1
    await _advance_cycle(dut)

    dut.i_prediction_fence_jal.value = 0
    dut.i_prediction_fence_indirect.value = 1
    await _advance_cycle(dut)

    await _finish_event_pipeline(dut)
    await _capture_snapshot(dut)

    assert await _read_counter(dut, PERF_PREDICTION_DISABLED) == 1
    assert await _read_counter(dut, PERF_PREDICTION_FENCE_BRANCH) == 1
    assert await _read_counter(dut, PERF_PREDICTION_FENCE_JAL) == 1
    assert await _read_counter(dut, PERF_PREDICTION_FENCE_INDIRECT) == 1


@cocotb.test()
async def test_snapshot_freezes_until_next_capture(dut: Any) -> None:
    """Snapshot readback remains stable until another capture is requested."""
    await _setup_test(dut)

    _drive_alloc_req(dut, {"alloc_valid": True})
    await _advance_cycle(dut)
    await _finish_event_pipeline(dut)
    await _capture_snapshot(dut)

    assert await _read_counter(dut, PERF_DISPATCH_FIRE) == 1

    for _ in range(2):
        _drive_alloc_req(dut, {"alloc_valid": True})
        await _advance_cycle(dut)
    await _finish_event_pipeline(dut)

    assert await _read_counter(dut, PERF_DISPATCH_FIRE) == 1

    await _capture_snapshot(dut)

    assert await _read_counter(dut, PERF_DISPATCH_FIRE) == 3


@cocotb.test()
async def test_wrapper_counter_select_and_data_path(dut: Any) -> None:
    """Wrapper-range selects are rebased and return wrapper counter data."""
    await _setup_test(dut)

    dut.i_wrapper_perf_counter_data.value = 0x123456789ABCDEF0
    dut.i_perf_counter_select.value = PERF_WRAPPER_BASE + 7

    await _advance_cycle(dut)

    assert int(dut.o_wrapper_perf_counter_select.value) == 7

    await _advance_cycle(dut)

    assert int(dut.o_perf_counter_data_q.value) == 0x123456789ABCDEF0

    dut.i_perf_counter_select.value = PERF_COUNTER_COUNT
    await _advance_cycle(dut)

    assert int(dut.o_wrapper_perf_counter_select.value) == 0

    await _advance_cycle(dut)

    assert int(dut.o_perf_counter_data_q.value) == 0

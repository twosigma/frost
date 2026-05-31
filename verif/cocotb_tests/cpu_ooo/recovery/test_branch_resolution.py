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

"""Unit tests for the CPU OOO branch resolution block."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.triggers import Timer


XLEN = 32
FLEN = 64
INSTR_OP_WIDTH = 32
ROB_TAG_WIDTH = 5
CHECKPOINT_ID_WIDTH = 3
MEM_SIZE_WIDTH = 2
NUM_CHECKPOINTS = 8

OP_JAL = 21
OP_JALR = 22
OP_BEQ = 23
OP_BNE = 24

RS_ISSUE_FIELDS = [
    ("valid", 1),
    ("rob_tag", ROB_TAG_WIDTH),
    ("op", INSTR_OP_WIDTH),
    ("src1_value", FLEN),
    ("src2_value", FLEN),
    ("src3_value", FLEN),
    ("imm", XLEN),
    ("use_imm", 1),
    ("rm", 3),
    ("branch_target", XLEN),
    ("predicted_taken", 1),
    ("predicted_target", XLEN),
    ("is_fp_mem", 1),
    ("mem_needs_lq", 1),
    ("mem_needs_sq", 1),
    ("mem_size", MEM_SIZE_WIDTH),
    ("mem_signed", 1),
    ("csr_addr", 12),
    ("csr_imm", 5),
    ("pc", XLEN),
    ("link_addr", XLEN),
    ("has_checkpoint", 1),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("is_call", 1),
    ("is_return", 1),
]

BRANCH_UPDATE_FIELDS = [
    ("valid", 1),
    ("tag", ROB_TAG_WIDTH),
    ("taken", 1),
    ("target", XLEN),
    ("mispredicted", 1),
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


def _pack_rs_issue(fields: Mapping[str, int | bool]) -> int:
    """Pack an rs_issue_t value."""
    return _pack_struct(RS_ISSUE_FIELDS, fields)


def _pack_mispredict_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a mispredict_commit_capture_t value."""
    return _pack_struct(MISPREDICT_COMMIT_FIELDS, fields)


def _read_branch_update(dut: Any) -> dict[str, Any]:
    """Read and unpack the branch update output."""
    return _unpack_struct(BRANCH_UPDATE_FIELDS, int(dut.o_branch_update.value))


def _pack_checkpoint_owner_tags(owner_tags: Mapping[int, int]) -> int:
    """Pack checkpoint owner tags for a packed [NumCheckpoints-1:0][tag] port."""
    packed = 0
    for checkpoint_id, tag in owner_tags.items():
        assert 0 <= checkpoint_id < NUM_CHECKPOINTS
        packed |= (tag & ((1 << ROB_TAG_WIDTH) - 1)) << (checkpoint_id * ROB_TAG_WIDTH)
    return packed


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_rs_issue_int.value = 0
    dut.i_head_tag.value = 0
    dut.i_early_mispredict_tag.value = 0
    dut.i_early_mispredict_active.value = 0
    dut.i_early_backend_recovery_pending.value = 0
    dut.i_mispredict_recovery_pending.value = 0
    dut.i_mispredict_commit_q.value = 0
    dut.i_flush_for_trap.value = 0
    dut.i_flush_for_mret.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_checkpoint_in_use.value = 0
    dut.i_checkpoint_owner_tag.value = 0


async def _setup_test(dut: Any) -> None:
    """Initialize combinational inputs."""
    _clear_inputs(dut)
    await _settle()


def _drive_issue(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive an INT reservation-station issue payload."""
    issue = {
        "valid": True,
        "rob_tag": 5,
        "op": OP_BEQ,
        "src1_value": 1,
        "src2_value": 1,
        "branch_target": 0x200,
        "predicted_taken": True,
        "predicted_target": 0x200,
    }
    issue.update(fields)
    dut.i_rs_issue_int.value = _pack_rs_issue(issue)


def _assert_no_branch_update(dut: Any) -> None:
    """Assert that branch resolution is suppressed."""
    update = _read_branch_update(dut)
    assert not update["valid"]
    assert not update["mispredicted"]
    assert not dut.o_branch_resolved_correct.value
    assert not dut.o_branch_unresolved_decrement.value


@cocotb.test()
async def test_correct_beq_branch_updates_rob_and_decrements(dut: Any) -> None:
    """A correctly predicted BEQ writes a resolved branch update."""
    await _setup_test(dut)

    _drive_issue(
        dut,
        {
            "rob_tag": 7,
            "op": OP_BEQ,
            "src1_value": 0x55,
            "src2_value": 0x55,
            "branch_target": 0x80000180,
            "predicted_taken": True,
            "predicted_target": 0x80000180,
        },
    )
    await _settle()

    update = _read_branch_update(dut)
    assert update["valid"]
    assert update["tag"] == 7
    assert update["taken"]
    assert update["target"] == 0x80000180
    assert not update["mispredicted"]
    assert dut.o_branch_resolved_correct.value
    assert dut.o_branch_unresolved_decrement.value
    assert not dut.o_is_jalr_issue.value
    assert dut.o_branch_taken_resolved.value
    assert int(dut.o_branch_target_resolved.value) == 0x80000180


@cocotb.test()
async def test_direction_and_target_mispredictions_are_flagged(dut: Any) -> None:
    """Direction and taken-target mismatches set the authoritative flag."""
    await _setup_test(dut)

    cases = [
        {
            "op": OP_BNE,
            "src1_value": 0x10,
            "src2_value": 0x10,
            "branch_target": 0x300,
            "predicted_taken": True,
            "predicted_target": 0x300,
            "expected_taken": False,
            "expected_target": 0x300,
        },
        {
            "op": OP_BEQ,
            "src1_value": 0x20,
            "src2_value": 0x20,
            "branch_target": 0x500,
            "predicted_taken": True,
            "predicted_target": 0x504,
            "expected_taken": True,
            "expected_target": 0x500,
        },
    ]

    for index, case in enumerate(cases):
        _clear_inputs(dut)
        _drive_issue(dut, {"rob_tag": index + 1, **case})
        await _settle()

        update = _read_branch_update(dut)
        assert update["valid"]
        assert update["tag"] == index + 1
        assert update["taken"] is case["expected_taken"]
        assert update["target"] == case["expected_target"]
        assert update["mispredicted"]
        assert not dut.o_branch_resolved_correct.value
        assert not dut.o_branch_unresolved_decrement.value


@cocotb.test()
async def test_jalr_resolves_computed_target_and_reports_issue(dut: Any) -> None:
    """JALR resolves with rs1+imm masked even and still updates the ROB."""
    await _setup_test(dut)

    _drive_issue(
        dut,
        {
            "rob_tag": 9,
            "op": OP_JALR,
            "src1_value": 0x80000011,
            "imm": 0x13,
            "branch_target": 0xDEADBEEF,
            "predicted_taken": True,
            "predicted_target": 0x80000024,
        },
    )
    await _settle()

    update = _read_branch_update(dut)
    assert dut.o_is_jalr_issue.value
    assert dut.o_branch_taken_resolved.value
    assert int(dut.o_branch_target_resolved.value) == 0x80000024
    assert update["valid"]
    assert update["tag"] == 9
    assert update["taken"]
    assert update["target"] == 0x80000024
    assert not update["mispredicted"]
    assert dut.o_branch_resolved_correct.value


@cocotb.test()
async def test_jal_resolves_target_without_branch_update(dut: Any) -> None:
    """Direct JAL is resolved but excluded from branch_update writes."""
    await _setup_test(dut)

    _drive_issue(
        dut,
        {
            "rob_tag": 10,
            "op": OP_JAL,
            "branch_target": 0x900,
            "predicted_taken": True,
            "predicted_target": 0x900,
        },
    )
    await _settle()

    _assert_no_branch_update(dut)
    assert dut.o_branch_taken_resolved.value
    assert int(dut.o_branch_target_resolved.value) == 0x900
    assert not dut.o_is_jalr_issue.value


@cocotb.test()
async def test_checkpoint_owner_validation_filters_stale_branches(dut: Any) -> None:
    """Checkpointed issues resolve only when the checkpoint owner still matches."""
    await _setup_test(dut)

    _drive_issue(dut, {"rob_tag": 11, "has_checkpoint": True, "checkpoint_id": 3})
    await _settle()

    _assert_no_branch_update(dut)

    dut.i_checkpoint_in_use.value = 1 << 3
    dut.i_checkpoint_owner_tag.value = _pack_checkpoint_owner_tags({3: 10})
    await _settle()

    _assert_no_branch_update(dut)

    dut.i_checkpoint_owner_tag.value = _pack_checkpoint_owner_tags({3: 11})
    await _settle()

    update = _read_branch_update(dut)
    assert update["valid"]
    assert update["tag"] == 11
    assert not update["mispredicted"]
    assert dut.o_branch_resolved_correct.value


@cocotb.test()
async def test_full_flush_sources_suppress_resolution(dut: Any) -> None:
    """Trap, MRET, and FENCE.I flushes suppress branch resolution."""
    await _setup_test(dut)

    for signal_name in ["i_flush_for_trap", "i_flush_for_mret", "i_fence_i_flush"]:
        _clear_inputs(dut)
        _drive_issue(dut, {"rob_tag": 12})
        getattr(dut, signal_name).value = 1
        await _settle()

        _assert_no_branch_update(dut)


@cocotb.test()
async def test_partial_recovery_suppresses_only_flushed_entries(dut: Any) -> None:
    """Early recovery keeps older branches but suppresses flushed entries."""
    await _setup_test(dut)

    recovery_signals = [
        "i_early_mispredict_active",
        "i_early_backend_recovery_pending",
    ]
    for signal_name in recovery_signals:
        _clear_inputs(dut)
        dut.i_head_tag.value = 10
        dut.i_early_mispredict_tag.value = 14
        getattr(dut, signal_name).value = 1
        _drive_issue(dut, {"rob_tag": 13})
        await _settle()

        assert _read_branch_update(dut)["valid"]

        _drive_issue(dut, {"rob_tag": 14})
        await _settle()

        _assert_no_branch_update(dut)

        _drive_issue(dut, {"rob_tag": 15})
        await _settle()

        _assert_no_branch_update(dut)


@cocotb.test()
async def test_commit_recovery_suppresses_all_branch_resolution(dut: Any) -> None:
    """Commit-time recovery suppresses all one-cycle stale branch issues."""
    await _setup_test(dut)

    _drive_issue(dut, {"rob_tag": 3})
    dut.i_mispredict_recovery_pending.value = 1
    dut.i_mispredict_commit_q.value = _pack_mispredict_commit({"tag": 2})
    await _settle()

    _assert_no_branch_update(dut)

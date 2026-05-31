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

"""Unit tests for the CPU OOO misprediction flush controller."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_interface import COMMIT_FIELDS


CLOCK_PERIOD_NS = 10
XLEN = 32
ROB_TAG_WIDTH = 5
CHECKPOINT_ID_WIDTH = 3
NUM_CHECKPOINTS = 8

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

CORRECT_BRANCH_COMMIT_FIELDS = [
    ("tag", ROB_TAG_WIDTH),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("pc", XLEN),
    ("branch_target", XLEN),
    ("branch_taken", 1),
    ("is_branch", 1),
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


def _pack_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_commit_t value."""
    return _pack_struct(COMMIT_FIELDS, fields)


def _read_mispredict_commit_q(dut: Any) -> dict[str, Any]:
    """Read and unpack the captured commit-time misprediction payload."""
    return _unpack_struct(
        MISPREDICT_COMMIT_FIELDS,
        int(dut.o_mispredict_commit_q.value),
    )


def _read_correct_branch_commit_q(dut: Any) -> dict[str, Any]:
    """Read and unpack the captured correct branch commit payload."""
    return _unpack_struct(
        CORRECT_BRANCH_COMMIT_FIELDS,
        int(dut.o_correct_branch_commit_q.value),
    )


def _pack_checkpoint_owner_tags(owner_tags: Mapping[int, int]) -> int:
    """Pack checkpoint owner tags for a packed [NumCheckpoints-1:0][tag] port."""
    packed = 0
    for checkpoint_id, tag in owner_tags.items():
        assert 0 <= checkpoint_id < NUM_CHECKPOINTS
        packed |= (tag & ((1 << ROB_TAG_WIDTH) - 1)) << (checkpoint_id * ROB_TAG_WIDTH)
    return packed


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to their idle values."""
    dut.i_rob_commit_misprediction_raw.value = 0
    dut.i_rob_commit_correct_branch_raw.value = 0
    dut.i_rob_commit_comb.value = 0
    dut.i_early_mispredict_active.value = 0
    dut.i_early_backend_recovery_pending.value = 0
    dut.i_head_tag.value = 0
    dut.i_early_mispredict_tag.value = 0
    dut.i_early_backend_flush_tag.value = 0
    dut.i_early_mispredict_checkpoint_id.value = 0
    dut.i_trap_taken_reg.value = 0
    dut.i_mret_taken_reg.value = 0
    dut.i_flush_for_trap.value = 0
    dut.i_flush_for_mret.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_checkpoint_in_use.value = 0
    dut.i_checkpoint_younger_than_flush.value = 0
    dut.i_checkpoint_owner_tag.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the controller, and clear all inputs."""
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


def _drive_commit(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the ROB commit input struct."""
    dut.i_rob_commit_comb.value = _pack_commit(fields)


@cocotb.test()
async def test_commit_mispredict_captures_and_flushes_after_head(dut: Any) -> None:
    """Commit-time misprediction captures payload and flushes after the head."""
    await _setup_test(dut)

    checkpoint_mask = 0b10110110
    dut.i_checkpoint_in_use.value = checkpoint_mask
    _drive_commit(
        dut,
        {
            "valid": True,
            "tag": 6,
            "has_checkpoint": True,
            "checkpoint_id": 3,
            "redirect_pc": 0x80000100,
            "pc": 0x80000080,
            "branch_taken": True,
            "branch_target": 0x80000200,
            "is_branch": True,
            "is_call": True,
            "is_compressed": True,
        },
    )
    dut.i_rob_commit_misprediction_raw.value = 1

    await _advance_cycle(dut)

    capture = _read_mispredict_commit_q(dut)
    assert dut.o_mispredict_recovery_pending.value
    assert capture["tag"] == 6
    assert capture["has_checkpoint"]
    assert capture["checkpoint_id"] == 3
    assert capture["redirect_pc"] == 0x80000100
    assert capture["pc"] == 0x80000080
    assert capture["branch_target"] == 0x80000200
    assert capture["branch_taken"]
    assert capture["is_branch"]
    assert capture["is_call"]
    assert capture["is_compressed"]
    assert dut.o_flush_pipeline.value
    assert dut.o_dispatch_flush.value
    assert dut.o_frontend_state_flush.value
    assert dut.o_flush_en.value
    assert int(dut.o_flush_tag.value) == 6
    assert dut.o_commit_recovery_flush_after_head.value
    assert dut.o_flush_after_head.value
    assert dut.o_checkpoint_restore.value
    assert int(dut.o_checkpoint_restore_id.value) == 3
    assert dut.o_checkpoint_free.value
    assert int(dut.o_checkpoint_free_id.value) == 3
    assert int(dut.o_checkpoint_flush_free_mask.value) == 0

    dut.i_rob_commit_misprediction_raw.value = 0
    await _advance_cycle(dut)

    assert not dut.o_mispredict_recovery_pending.value
    assert not dut.o_flush_en.value
    assert int(dut.o_checkpoint_flush_free_mask.value) == checkpoint_mask

    await _advance_cycle(dut)

    assert int(dut.o_checkpoint_flush_free_mask.value) == 0


@cocotb.test()
async def test_same_branch_early_recovery_suppresses_commit_mispredict(
    dut: Any,
) -> None:
    """Early recovery suppresses only the matching commit-time mispredict."""
    await _setup_test(dut)

    _drive_commit(dut, {"valid": True, "tag": 4, "has_checkpoint": True})
    dut.i_rob_commit_misprediction_raw.value = 1
    dut.i_early_mispredict_active.value = 1
    dut.i_head_tag.value = 4
    dut.i_early_mispredict_tag.value = 4

    await _advance_cycle(dut)

    assert not dut.o_mispredict_recovery_pending.value

    _clear_inputs(dut)
    await _advance_cycle(dut)

    _drive_commit(dut, {"valid": True, "tag": 5, "has_checkpoint": True})
    dut.i_rob_commit_misprediction_raw.value = 1
    dut.i_early_mispredict_active.value = 1
    dut.i_head_tag.value = 5
    dut.i_early_mispredict_tag.value = 4

    await _advance_cycle(dut)

    assert dut.o_mispredict_recovery_pending.value
    assert _read_mispredict_commit_q(dut)["tag"] == 5


@cocotb.test()
async def test_early_recovery_priority_and_checkpoint_free(dut: Any) -> None:
    """Early frontend/backend phases drive the expected flush/checkpoint policy."""
    await _setup_test(dut)

    dut.i_early_mispredict_active.value = 1
    dut.i_early_mispredict_checkpoint_id.value = 6
    await _settle()

    assert dut.o_flush_pipeline.value
    assert dut.o_frontend_state_flush.value
    assert not dut.o_flush_en.value
    assert dut.o_checkpoint_restore.value
    assert int(dut.o_checkpoint_restore_id.value) == 6
    assert not dut.o_checkpoint_free.value

    dut.i_early_mispredict_active.value = 0
    dut.i_early_backend_recovery_pending.value = 1
    dut.i_early_backend_flush_tag.value = 12
    dut.i_checkpoint_younger_than_flush.value = 0b01010010
    await _settle()

    assert not dut.o_flush_pipeline.value
    assert dut.o_flush_en.value
    assert int(dut.o_flush_tag.value) == 12
    assert dut.o_checkpoint_free.value
    assert int(dut.o_checkpoint_free_id.value) == 6
    assert not dut.o_checkpoint_restore.value

    await _advance_cycle(dut)

    assert int(dut.o_checkpoint_flush_free_mask.value) == 0b01010010


@cocotb.test()
async def test_full_flush_sources_override_partial_recovery(dut: Any) -> None:
    """Trap and MRET full flushes override partial recovery side effects."""
    await _setup_test(dut)

    for is_mret in [False, True]:
        _clear_inputs(dut)
        dut.i_early_backend_recovery_pending.value = 1
        dut.i_early_backend_flush_tag.value = 8
        dut.i_early_mispredict_checkpoint_id.value = 2
        dut.i_trap_taken_reg.value = 0 if is_mret else 1
        dut.i_mret_taken_reg.value = 1 if is_mret else 0
        dut.i_flush_for_trap.value = 0 if is_mret else 1
        dut.i_flush_for_mret.value = 1 if is_mret else 0
        await _settle()

        assert dut.o_flush_pipeline.value
        assert dut.o_frontend_state_flush.value
        assert dut.o_full_flush_side_effect_kill.value
        assert dut.o_flush_all.value
        assert not dut.o_flush_en.value
        assert not dut.o_checkpoint_restore.value
        assert not dut.o_checkpoint_free.value


@cocotb.test()
async def test_fence_i_captures_fallthrough_and_flushes_frontend(dut: Any) -> None:
    """FENCE.I captures architectural fallthrough and later requests full flush."""
    await _setup_test(dut)

    _drive_commit(
        dut,
        {
            "valid": True,
            "pc": 0x4000,
            "is_fence_i": True,
            "is_compressed": False,
        },
    )
    await _advance_cycle(dut)

    assert int(dut.o_fence_i_target_pc.value) == 0x4004

    _drive_commit(
        dut,
        {
            "valid": True,
            "pc": 0x5000,
            "is_fence_i": True,
            "is_compressed": True,
        },
    )
    await _advance_cycle(dut)

    assert int(dut.o_fence_i_target_pc.value) == 0x5002

    _clear_inputs(dut)
    dut.i_fence_i_flush.value = 1
    await _settle()

    assert dut.o_flush_pipeline.value
    assert dut.o_full_flush_side_effect_kill.value
    assert dut.o_frontend_state_flush.value
    assert dut.o_flush_all.value
    assert not dut.o_flush_en.value


@cocotb.test()
async def test_correct_branch_commit_frees_only_live_owned_checkpoint(
    dut: Any,
) -> None:
    """Correct branch commits free checkpoints only when owner validation passes."""
    await _setup_test(dut)

    dut.i_checkpoint_in_use.value = 1 << 4
    dut.i_checkpoint_owner_tag.value = _pack_checkpoint_owner_tags({4: 7})
    _drive_commit(
        dut,
        {
            "valid": True,
            "tag": 7,
            "checkpoint_id": 4,
            "pc": 0x7000,
            "branch_target": 0x7100,
            "branch_taken": False,
            "is_branch": True,
            "is_compressed": True,
        },
    )
    dut.i_rob_commit_correct_branch_raw.value = 1

    await _advance_cycle(dut)

    capture = _read_correct_branch_commit_q(dut)
    assert dut.o_correct_branch_commit_pending.value
    assert capture["tag"] == 7
    assert capture["checkpoint_id"] == 4
    assert capture["pc"] == 0x7000
    assert capture["branch_target"] == 0x7100
    assert not capture["branch_taken"]
    assert capture["is_branch"]
    assert capture["is_compressed"]
    assert dut.o_checkpoint_free.value
    assert int(dut.o_checkpoint_free_id.value) == 4
    assert not dut.o_flush_pipeline.value
    assert not dut.o_flush_en.value

    _clear_inputs(dut)
    await _advance_cycle(dut)

    assert not dut.o_correct_branch_commit_pending.value
    assert not dut.o_checkpoint_free.value

    dut.i_checkpoint_in_use.value = 1 << 2
    dut.i_checkpoint_owner_tag.value = _pack_checkpoint_owner_tags({2: 8})
    _drive_commit(
        dut,
        {
            "valid": True,
            "tag": 9,
            "checkpoint_id": 2,
            "pc": 0x7200,
            "branch_target": 0x7300,
            "branch_taken": True,
            "is_branch": True,
        },
    )
    dut.i_rob_commit_correct_branch_raw.value = 1

    await _advance_cycle(dut)

    assert dut.o_correct_branch_commit_pending.value
    assert _read_correct_branch_commit_q(dut)["tag"] == 9
    assert not dut.o_checkpoint_free.value

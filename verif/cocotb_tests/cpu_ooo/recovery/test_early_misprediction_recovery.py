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

"""Unit tests for the CPU OOO early misprediction recovery FSM."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
XLEN = 32
FLEN = 64
INSTR_OP_WIDTH = 32
ROB_TAG_WIDTH = 5
CHECKPOINT_ID_WIDTH = 3
MEM_SIZE_WIDTH = 2

OP_BEQ = 23

BRANCH_UPDATE_FIELDS = [
    ("valid", 1),
    ("tag", ROB_TAG_WIDTH),
    ("taken", 1),
    ("target", XLEN),
    ("mispredicted", 1),
]

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


def _pack_branch_update(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_branch_update_t value."""
    return _pack_struct(BRANCH_UPDATE_FIELDS, fields)


def _pack_rs_issue(fields: Mapping[str, int | bool]) -> int:
    """Pack an rs_issue_t value."""
    return _pack_struct(RS_ISSUE_FIELDS, fields)


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to their idle values."""
    dut.i_branch_update.value = 0
    dut.i_rs_issue_int.value = 0
    dut.i_head_tag.value = 0
    dut.i_is_jalr_issue.value = 0
    dut.i_branch_taken_resolved.value = 0
    dut.i_branch_target_resolved.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_mispredict_recovery_pending.value = 0
    dut.i_flush_all.value = 0
    dut.i_flush_for_trap.value = 0
    dut.i_flush_for_mret.value = 0
    dut.i_trap_taken_reg.value = 0
    dut.i_mret_taken_reg.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the FSM, and clear all inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await Timer(1, unit="ns")


async def _settle_after_edge(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")


def _drive_mispredict(
    dut: Any,
    *,
    tag: int = 7,
    has_checkpoint: bool = True,
    checkpoint_id: int = 3,
    pc: int = 0x1000,
    link_addr: int = 0x1004,
    branch_target: int = 0x2000,
    branch_taken: bool = True,
) -> None:
    """Drive a checkpointed conditional branch misprediction."""
    dut.i_branch_update.value = _pack_branch_update(
        {
            "valid": True,
            "tag": tag,
            "taken": branch_taken,
            "target": branch_target,
            "mispredicted": True,
        },
    )
    dut.i_rs_issue_int.value = _pack_rs_issue(
        {
            "valid": True,
            "rob_tag": tag,
            "op": OP_BEQ,
            "branch_target": branch_target,
            "pc": pc,
            "link_addr": link_addr,
            "has_checkpoint": has_checkpoint,
            "checkpoint_id": checkpoint_id,
        },
    )
    dut.i_branch_taken_resolved.value = 1 if branch_taken else 0
    dut.i_branch_target_resolved.value = branch_target


def _assert_idle(dut: Any) -> None:
    """Assert that no recovery phase is active."""
    assert not dut.o_early_mispredict_active.value
    assert not dut.o_early_backend_recovery_pending.value
    assert not dut.o_early_recovery_en.value
    assert not dut.o_early_backend_recovery_hold.value


@cocotb.test()
async def test_taken_mispredict_redirects_then_flushes_backend(dut: Any) -> None:
    """A taken execute-time misprediction produces frontend then backend phases."""
    await _setup_test(dut)

    _drive_mispredict(
        dut,
        tag=9,
        checkpoint_id=5,
        pc=0x80000100,
        link_addr=0x80000104,
        branch_target=0x80000200,
        branch_taken=True,
    )
    await _settle_after_edge(dut)

    assert dut.o_early_mispredict_active.value
    assert dut.o_early_recovery_en.value
    assert dut.o_early_backend_recovery_hold.value
    assert not dut.o_early_backend_recovery_pending.value
    assert int(dut.o_early_mispredict_tag.value) == 9
    assert int(dut.o_early_mispredict_redirect_pc.value) == 0x80000200
    assert int(dut.o_early_mispredict_checkpoint_id.value) == 5
    assert int(dut.o_early_mispredict_pc.value) == 0x80000100
    assert int(dut.o_early_mispredict_branch_target.value) == 0x80000200
    assert dut.o_early_mispredict_branch_taken.value
    assert not dut.o_early_mispredict_is_compressed.value

    _clear_inputs(dut)
    await _settle_after_edge(dut)

    assert not dut.o_early_mispredict_active.value
    assert not dut.o_early_recovery_en.value
    assert dut.o_early_backend_recovery_pending.value
    assert not dut.o_early_backend_recovery_hold.value
    assert int(dut.o_early_backend_flush_tag.value) == 9

    await _settle_after_edge(dut)

    _assert_idle(dut)


@cocotb.test()
async def test_not_taken_mispredict_redirects_to_link_address(dut: Any) -> None:
    """A not-taken misprediction redirects to fallthrough and records compression."""
    await _setup_test(dut)

    _drive_mispredict(
        dut,
        tag=4,
        checkpoint_id=2,
        pc=0x300,
        link_addr=0x302,
        branch_target=0x480,
        branch_taken=False,
    )
    await _settle_after_edge(dut)

    assert dut.o_early_mispredict_active.value
    assert int(dut.o_early_mispredict_tag.value) == 4
    assert int(dut.o_early_mispredict_redirect_pc.value) == 0x302
    assert int(dut.o_early_mispredict_checkpoint_id.value) == 2
    assert int(dut.o_early_mispredict_branch_target.value) == 0x480
    assert not dut.o_early_mispredict_branch_taken.value
    assert dut.o_early_mispredict_is_compressed.value


@cocotb.test()
async def test_unqualified_mispredictions_do_not_fire(dut: Any) -> None:
    """JALR, uncheckpointed, fence, and commit-recovery cases are gated off."""
    await _setup_test(dut)

    cases = [
        {"has_checkpoint": False},
        {"is_jalr_issue": True},
        {"fence_i_flush": True},
        {"mispredict_recovery_pending": True},
    ]

    for index, case in enumerate(cases):
        _clear_inputs(dut)
        _drive_mispredict(
            dut,
            tag=index + 1,
            has_checkpoint=case.get("has_checkpoint", True),
        )
        dut.i_is_jalr_issue.value = 1 if case.get("is_jalr_issue", False) else 0
        dut.i_fence_i_flush.value = 1 if case.get("fence_i_flush", False) else 0
        dut.i_mispredict_recovery_pending.value = (
            1 if case.get("mispredict_recovery_pending", False) else 0
        )

        await _settle_after_edge(dut)

        _assert_idle(dut)

        _clear_inputs(dut)
        await _settle_after_edge(dut)

        _assert_idle(dut)


@cocotb.test()
async def test_commit_recovery_next_cycle_drops_coincident_fire(dut: Any) -> None:
    """A fire coinciding with a head-mispredict commit is dropped one cycle later.

    The one-cycle collision the fire-time gates cannot see: a younger branch
    fires (capture succeeds, i_mispredict_recovery_pending still 0) in the same
    cycle an older head-mispredict commits.  The commit-time launch registers
    into mispredict_recovery_pending on the NEXT cycle, and the
    !i_mispredict_recovery_pending term in early_mispredict_active must drop
    the early pulse there -- before any redirect / RAT restore /
    rob_early_recovered write / backend flush.  This is the load-bearing guard
    that replaced the removed fire-time candidate gate (see the NOTE in
    branch_resolution.sv); no other test or formal property pins it.
    """
    await _setup_test(dut)

    # Cycle N: qualified fire with no recovery pending -- capture succeeds.
    _drive_mispredict(dut, tag=6, checkpoint_id=1)
    await _settle_after_edge(dut)

    # Cycle N+1: the coincident commit-time recovery launch is now registered.
    _clear_inputs(dut)
    dut.i_mispredict_recovery_pending.value = 1
    await Timer(1, unit="ns")

    # The pulse is dropped: no active phase, no RAT restore enable.  Only the
    # benign one-cycle dispatch hold remains (dispatch is being flushed by the
    # commit-time recovery in this cycle anyway).
    assert not dut.o_early_mispredict_active.value
    assert not dut.o_early_recovery_en.value
    assert dut.o_early_backend_recovery_hold.value

    await _settle_after_edge(dut)

    # Cycle N+2: recovery_pending was a one-cycle pulse; the dropped fire must
    # leave no residue -- in particular no phantom backend flush.
    _clear_inputs(dut)
    await Timer(1, unit="ns")

    assert not dut.o_early_backend_recovery_pending.value
    _assert_idle(dut)

    await _settle_after_edge(dut)

    _assert_idle(dut)


@cocotb.test()
async def test_backend_phase_blocks_new_capture(dut: Any) -> None:
    """A second misprediction cannot start while the backend phase is pending."""
    await _setup_test(dut)

    _drive_mispredict(dut, tag=3, checkpoint_id=1, branch_target=0x700)
    await _settle_after_edge(dut)

    assert dut.o_early_mispredict_active.value

    _drive_mispredict(dut, tag=8, checkpoint_id=6, pc=0x900, branch_target=0xA00)
    await _settle_after_edge(dut)

    assert dut.o_early_backend_recovery_pending.value
    assert int(dut.o_early_backend_flush_tag.value) == 3
    assert not dut.o_early_mispredict_active.value

    _clear_inputs(dut)
    await _settle_after_edge(dut)

    _assert_idle(dut)


@cocotb.test()
async def test_trap_and_mret_cancel_pending_recovery(dut: Any) -> None:
    """Trap and MRET flushes cancel a pending early recovery."""
    await _setup_test(dut)

    for is_mret in [False, True]:
        _clear_inputs(dut)
        _drive_mispredict(dut, tag=11 if is_mret else 10)
        await _settle_after_edge(dut)

        assert dut.o_early_mispredict_active.value

        _clear_inputs(dut)
        dut.i_flush_all.value = 1
        if is_mret:
            dut.i_flush_for_mret.value = 1
            dut.i_mret_taken_reg.value = 1
        else:
            dut.i_flush_for_trap.value = 1
            dut.i_trap_taken_reg.value = 1
        await _settle_after_edge(dut)

        _assert_idle(dut)

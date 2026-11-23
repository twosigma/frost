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
from random import Random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from config import XLEN
from cocotb_tests.cpu_structs import (
    BRANCH_UPDATE_FIELDS,
    RS_ISSUE_FIELDS,
)
from utils.packed_structs import (
    pack_struct as _pack_struct,
)


CLOCK_PERIOD_NS = 10
ROB_TAG_WIDTH = 5
CHECKPOINT_ID_WIDTH = 4
MEM_SIZE_WIDTH = 2

OP_BEQ = 23


def _pack_branch_update(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_branch_update_t value."""
    return _pack_struct(BRANCH_UPDATE_FIELDS, fields)


def _pack_rs_issue(fields: Mapping[str, int | bool]) -> int:
    """Pack an rs_issue_t value."""
    return _pack_struct(RS_ISSUE_FIELDS, fields)


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to their idle values."""
    dut.i_fatal_stop.value = 0
    dut.i_branch_update.value = 0
    dut.i_rs_issue_int.value = 0
    dut.i_is_jalr_issue.value = 0
    dut.i_branch_taken_resolved.value = 0
    dut.i_branch_target_resolved.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_active_fence_i_flush.value = 0
    dut.i_mispredict_recovery_pending.value = 0
    dut.i_flush_all.value = 0
    dut.i_flush_for_trap.value = 0
    dut.i_flush_for_mret.value = 0
    dut.i_trap_taken_reg.value = 0
    dut.i_mret_taken_reg.value = 0
    dut.i_jal_launch.value = 0
    dut.i_checkpoint_unresolved.value = 0
    dut.i_head_tag.value = 0
    dut.i_jal_capture.value = 0
    dut.i_jal_tag.value = 0
    dut.i_jal_checkpoint_id.value = 0
    dut.i_jal_pc.value = 0
    dut.i_jal_target.value = 0
    dut.i_jal_is_compressed.value = 0
    dut.i_jal_is_call.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the FSM, and clear all inputs."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
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
    mispredicted: bool = True,
    is_jalr: bool = False,
    is_call: bool = False,
    is_return: bool = False,
    is_compressed: bool | None = None,
) -> None:
    """Drive a coherent branch-resolution transaction.

    The RS packet carries is_compressed as a dispatch-time bit; by default it
    is derived from the link/pc pair the way the front end would set it. Its
    prediction agrees with ``mispredicted``: a misprediction predicted the
    other direction, a correct prediction the resolved direction and target.
    The fire reads the prediction for conditional branches, and a simulation
    check compares that form with the update's flag.
    """
    dut.i_branch_update.value = _pack_branch_update(
        {
            "valid": True,
            "tag": tag,
            "taken": branch_taken,
            "target": branch_target,
            "mispredicted": mispredicted,
        },
    )
    dut.i_rs_issue_int.value = _pack_rs_issue(
        {
            "valid": True,
            "rob_tag": tag,
            "op": OP_BEQ,
            "imm": branch_target,
            "pc": pc,
            "link_addr": link_addr,
            "is_compressed": (
                (link_addr == ((pc + 2) & ((1 << XLEN) - 1)))
                if is_compressed is None
                else is_compressed
            ),
            "has_checkpoint": has_checkpoint,
            "checkpoint_id": checkpoint_id,
            "predicted_taken": branch_taken != mispredicted,
            "predicted_target_ok": True,
            "is_branch_class": True,
            "is_jal": False,
            "is_jalr": is_jalr,
            "is_call": is_call,
            "is_return": is_return,
        },
    )
    # branch_resolution qualifies i_is_jalr_issue. A mispredicted transaction
    # is always valid there, so the qualified bit equals the raw registered
    # JALR bit.
    dut.i_is_jalr_issue.value = 1 if is_jalr else 0
    dut.i_branch_taken_resolved.value = 1 if branch_taken else 0
    dut.i_branch_target_resolved.value = branch_target


def _assert_idle(dut: Any) -> None:
    """Assert that no recovery phase is active."""
    assert not dut.o_early_mispredict_active.value
    assert not dut.o_early_backend_recovery_pending.value
    assert not dut.o_early_backend_recovery_pending_next.value
    assert not dut.o_early_recovery_en.value
    assert not dut.o_early_backend_recovery_hold.value
    assert not dut.o_backend_recovery_hold.value


@cocotb.test()
async def test_backend_hold_preserves_fatal_recovery_reset_priority(dut: Any) -> None:
    """The sampled fatal hold and early hold combine on the same edge."""
    await _setup_test(dut)
    # (branch resolution, fatal request, full flush, reset)
    cases = [
        (False, True, False, False),
        (False, False, False, False),
        (True, False, False, False),
        (False, True, True, False),
        (False, True, True, False),
        (True, True, False, True),
        (True, True, False, False),
        (False, False, False, True),
        (False, False, False, False),
    ]
    rng = Random(0xBA_CE)
    cases += [
        (
            bool(rng.getrandbits(1)),
            bool(rng.getrandbits(1)),
            bool(rng.getrandbits(1)),
            bool(rng.getrandbits(1)),
        )
        for _ in range(256)
    ]
    sampled_fatal = False
    previous_hold = False
    for branch, fatal, flush, reset in cases:
        await FallingEdge(dut.i_clk)
        _clear_inputs(dut)
        if branch:
            _drive_mispredict(dut)
        dut.i_fatal_stop.value = fatal
        dut.i_flush_all.value = flush
        dut.i_rst.value = reset
        await Timer(1, unit="ns")
        # Changing requests between edges must not change the sampled hold.
        assert bool(dut.o_backend_recovery_hold.value) == previous_hold
        await _settle_after_edge(dut)
        sampled_fatal = fatal and not reset
        early_hold = bool(dut.o_early_backend_recovery_hold.value)
        if reset or flush:
            assert not early_hold
        previous_hold = early_hold or sampled_fatal
        assert bool(dut.o_backend_recovery_hold.value) == previous_hold


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
    assert dut.o_early_backend_recovery_pending_next.value
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
async def test_jalr_mispredict_redirects_to_its_target(dut: Any) -> None:
    """A mispredicted JALR recovers at execute with its target and stack class."""
    await _setup_test(dut)

    for index, (is_call, is_return) in enumerate(
        ((False, False), (True, False), (False, True), (True, True))
    ):
        _drive_mispredict(
            dut,
            tag=10 + index,
            checkpoint_id=index,
            pc=0x80000300,
            link_addr=0x80000302,
            branch_target=0x80000480 + 8 * index,
            branch_taken=True,
            is_jalr=True,
            is_call=is_call,
            is_return=is_return,
        )
        await _settle_after_edge(dut)

        assert dut.o_early_mispredict_active.value
        assert int(dut.o_early_mispredict_tag.value) == 10 + index
        assert int(dut.o_early_mispredict_redirect_pc.value) == 0x80000480 + 8 * index
        assert int(dut.o_early_mispredict_checkpoint_id.value) == index
        assert dut.o_early_mispredict_branch_taken.value
        assert dut.o_early_mispredict_is_compressed.value
        assert dut.o_early_mispredict_is_jalr.value
        assert bool(dut.o_early_mispredict_is_call.value) == is_call
        assert bool(dut.o_early_mispredict_is_return.value) == is_return

        _clear_inputs(dut)
        await _settle_after_edge(dut)
        assert dut.o_early_mispredict_branch_taken.value
        await _settle_after_edge(dut)
        _assert_idle(dut)

    # A correctly predicted JALR does not start a recovery.
    _drive_mispredict(dut, tag=20, is_jalr=True, mispredicted=False)
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
    """Uncheckpointed, fence, and commit-recovery cases are gated off."""
    await _setup_test(dut)

    cases = [
        {"has_checkpoint": False},
        {"has_checkpoint": False, "is_jalr": True},
        {"fence_i_flush": True},
        {"mispredict_recovery_pending": True},
    ]

    for index, case in enumerate(cases):
        _clear_inputs(dut)
        _drive_mispredict(
            dut,
            tag=index + 1,
            has_checkpoint=case.get("has_checkpoint", True),
            is_jalr=case.get("is_jalr", False),
        )
        dut.i_fence_i_flush.value = 1 if case.get("fence_i_flush", False) else 0
        dut.i_active_fence_i_flush.value = 1 if case.get("fence_i_flush", False) else 0
        dut.i_mispredict_recovery_pending.value = (
            1 if case.get("mispredict_recovery_pending", False) else 0
        )

        await _settle_after_edge(dut)

        _assert_idle(dut)

        _clear_inputs(dut)
        await _settle_after_edge(dut)

        _assert_idle(dut)


@cocotb.test()
async def test_issue_local_payload_capture_is_inert_without_fire(dut: Any) -> None:
    """Payload registers may capture without a fire; only a qualified fire starts recovery."""
    await _setup_test(dut)

    # A correctly predicted checkpointed conditional branch updates the payload
    # registers but must not start any recovery phase.
    _drive_mispredict(
        dut,
        tag=12,
        checkpoint_id=4,
        pc=0x1200,
        link_addr=0x1204,
        branch_target=0x1800,
        mispredicted=False,
    )
    await _settle_after_edge(dut)

    _assert_idle(dut)
    assert int(dut.o_early_mispredict_tag.value) == 12
    assert int(dut.o_early_mispredict_pc.value) == 0x1200
    assert int(dut.o_early_mispredict_branch_target.value) == 0x1800

    # A FENCE.I flush at fire time still blocks the fire. The payload may
    # update on this edge, but no pending, active, or backend phase observes
    # it.
    _drive_mispredict(
        dut,
        tag=13,
        checkpoint_id=5,
        pc=0x1300,
        link_addr=0x1302,
        branch_target=0x1900,
    )
    dut.i_fence_i_flush.value = 1
    dut.i_active_fence_i_flush.value = 1
    await _settle_after_edge(dut)

    _assert_idle(dut)
    assert int(dut.o_early_mispredict_tag.value) == 13
    assert int(dut.o_early_mispredict_pc.value) == 0x1300
    assert int(dut.o_early_mispredict_branch_target.value) == 0x1900

    _clear_inputs(dut)
    await _settle_after_edge(dut)
    _assert_idle(dut)


@cocotb.test()
async def test_local_fence_copy_only_gates_active_pulse(dut: Any) -> None:
    """The local FENCE.I copy gates active; pending and hold use the shared pulse.

    The core's rob_commit.is_fence_i implies fence_i_flush, as asserted in
    tomasulo_wrapper. A translation-CSR flush raises only the shared pulse.
    Drive the copies independently to check that only the active gate uses
    the local copy; the fire-time gate must still use the shared pulse.
    """
    await _setup_test(dut)

    _drive_mispredict(dut, tag=12, checkpoint_id=4)
    await _settle_after_edge(dut)

    assert dut.o_early_mispredict_active.value
    assert dut.o_early_backend_recovery_hold.value

    _clear_inputs(dut)
    dut.i_active_fence_i_flush.value = 1
    await Timer(1, unit="ns")

    assert not dut.o_early_mispredict_active.value
    assert not dut.o_early_recovery_en.value
    assert dut.o_early_backend_recovery_hold.value
    assert not dut.o_early_backend_recovery_pending.value

    await _settle_after_edge(dut)

    _assert_idle(dut)


@cocotb.test()
async def test_commit_recovery_next_cycle_drops_coincident_fire(dut: Any) -> None:
    """A head-mispredict commit cancels a coincident early fire one cycle later.

    The younger branch can fire before i_mispredict_recovery_pending rises.
    When that registered flag arrives, early_mispredict_active must drop
    before a redirect, RAT restore, rob_early_recovered write, or backend flush.
    """
    await _setup_test(dut)

    # Cycle N: qualified fire with no recovery pending, so capture succeeds.
    _drive_mispredict(dut, tag=6, checkpoint_id=1)
    await _settle_after_edge(dut)

    # Cycle N+1: the coincident commit-time recovery launch is now registered.
    _clear_inputs(dut)
    dut.i_mispredict_recovery_pending.value = 1
    await Timer(1, unit="ns")

    # Only the one-cycle dispatch hold remains; commit-time recovery flushes
    # dispatch in this cycle, so the hold is harmless.
    assert not dut.o_early_mispredict_active.value
    assert not dut.o_early_recovery_en.value
    assert dut.o_early_backend_recovery_hold.value

    await _settle_after_edge(dut)

    # Cycle N+2: after recovery_pending drops, no backend flush may remain.
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
    # The pending/active guards hold the first branch's recovery payload while
    # the second branch appears at issue. A capture that cannot fire never
    # replaces data the active recovery still uses.
    assert int(dut.o_early_mispredict_tag.value) == 3
    assert int(dut.o_early_mispredict_pc.value) == 0x1000
    assert int(dut.o_early_mispredict_branch_target.value) == 0x700

    _clear_inputs(dut)
    await _settle_after_edge(dut)

    _assert_idle(dut)


@cocotb.test()
async def test_backend_pending_next_state_matches_register(dut: Any) -> None:
    """The exported next state is what the backend-pending register loads.

    The flush controller registers flush_en from it, so it must drop with a
    trap cancellation and with reset, and the register must follow it.
    """
    await _setup_test(dut)

    _drive_mispredict(dut, tag=7)
    await _settle_after_edge(dut)
    assert dut.o_early_mispredict_active.value
    assert dut.o_early_backend_recovery_pending_next.value

    dut.i_flush_for_trap.value = 1
    await Timer(1, unit="ns")
    assert not dut.o_early_backend_recovery_pending_next.value
    await _settle_after_edge(dut)
    assert not dut.o_early_backend_recovery_pending.value

    _clear_inputs(dut)
    _drive_mispredict(dut, tag=8)
    await _settle_after_edge(dut)
    assert dut.o_early_backend_recovery_pending_next.value
    dut.i_rst.value = 1
    await _settle_after_edge(dut)
    assert not dut.o_early_backend_recovery_pending.value
    dut.i_rst.value = 0
    _clear_inputs(dut)


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


def _drive_jal_stage(
    dut: Any,
    *,
    launch: bool = True,
    capture: bool = True,
    tag: int = 10,
    checkpoint_id: int = 9,
    pc: int = 0x8000_0500,
    target: int = 0x8000_0700,
    is_compressed: bool = False,
    is_call: bool = False,
    checkpoint_unresolved: int = 0,
    head_tag: int = 0,
) -> None:
    """Drive the allocation-time JAL staging inputs."""
    dut.i_jal_launch.value = 1 if launch else 0
    dut.i_jal_capture.value = 1 if capture else 0
    dut.i_jal_tag.value = tag
    dut.i_jal_checkpoint_id.value = checkpoint_id
    dut.i_jal_pc.value = pc
    dut.i_jal_target.value = target
    dut.i_jal_is_compressed.value = 1 if is_compressed else 0
    dut.i_jal_is_call.value = 1 if is_call else 0
    dut.i_checkpoint_unresolved.value = checkpoint_unresolved
    dut.i_head_tag.value = head_tag


@cocotb.test()
async def test_early_jal_stage_launches_frontend_then_backend(dut: Any) -> None:
    """A staged mispredicted JAL launches next cycle and runs both recovery phases."""
    await _setup_test(dut)

    # Capture without dispatch launch loads the staging payload inertly.
    _drive_jal_stage(dut, launch=False, capture=True, tag=15, checkpoint_id=10)
    await _settle_after_edge(dut)
    _clear_inputs(dut)
    await Timer(1, unit="ns")
    assert not dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    _assert_idle(dut)

    cases = (
        (False, False, 10, 8, 0x8000_0500, 0x8000_0700),
        (False, True, 11, 9, 0x8000_0520, 0x8000_0740),
        (True, False, 12, 10, 0x8000_0542, 0x8000_0782),
        (True, True, 13, 11, 0x8000_0562, 0x8000_07C0),
    )
    for is_compressed, is_call, tag, checkpoint_id, pc, target in cases:
        _clear_inputs(dut)
        _drive_jal_stage(
            dut,
            tag=tag,
            checkpoint_id=checkpoint_id,
            pc=pc,
            target=target,
            is_compressed=is_compressed,
            is_call=is_call,
            head_tag=(tag + 1) & 0x1F,
        )
        # Cycle D: stage the JAL; no recovery starts yet.
        await _settle_after_edge(dut)
        _assert_idle(dut)

        # Cycle D+1: no older unresolved checkpoints and not at ROB head -> launch.
        _clear_inputs(dut)
        dut.i_head_tag.value = (tag + 1) & 0x1F
        await Timer(1, unit="ns")
        assert dut.o_early_mispredict_fire.value
        await _settle_after_edge(dut)

        assert dut.o_early_mispredict_active.value
        assert dut.o_early_recovery_en.value
        assert dut.o_early_backend_recovery_hold.value
        assert dut.o_backend_recovery_hold.value
        assert not dut.o_early_backend_recovery_pending.value
        assert dut.o_early_backend_recovery_pending_next.value
        assert int(dut.o_early_mispredict_tag.value) == tag
        assert int(dut.o_early_recovery_tag.value) == tag
        assert int(dut.o_early_mispredict_checkpoint_id.value) == checkpoint_id
        assert int(dut.o_early_mispredict_pc.value) == pc
        assert int(dut.o_early_mispredict_branch_target.value) == target
        assert int(dut.o_early_mispredict_redirect_pc.value) == target
        assert dut.o_early_mispredict_branch_taken.value
        assert bool(dut.o_early_mispredict_is_compressed.value) is is_compressed
        assert bool(dut.o_early_mispredict_is_call.value) is is_call
        assert dut.o_early_mispredict_is_jal.value
        assert not dut.o_early_mispredict_is_jalr.value
        assert not dut.o_early_mispredict_is_return.value

        # Cycle D+2: backend partial flush carries the JAL's ROB tag.
        _clear_inputs(dut)
        await _settle_after_edge(dut)
        assert not dut.o_early_mispredict_active.value
        assert dut.o_early_backend_recovery_pending.value
        assert int(dut.o_early_backend_flush_tag.value) == tag

        # Cycle D+3: idle again.
        await _settle_after_edge(dut)
        _assert_idle(dut)

    # A subsequent branch recovery clears o_early_mispredict_is_jal.
    _drive_mispredict(dut, tag=4, checkpoint_id=2)
    await _settle_after_edge(dut)
    assert dut.o_early_mispredict_active.value
    assert not dut.o_early_mispredict_is_jal.value
    _clear_inputs(dut)
    await _settle_after_edge(dut)
    await _settle_after_edge(dut)
    _assert_idle(dut)


@cocotb.test()
async def test_early_jal_waits_for_older_checkpoints_and_ignores_younger_jal(
    dut: Any,
) -> None:
    """A staged JAL waits for sampled older checkpoints and ignores younger JALs."""
    await _setup_test(dut)

    # Stage older JAL while checkpoints 2 and 9 are unresolved.
    _drive_jal_stage(
        dut,
        tag=10,
        checkpoint_id=11,
        pc=0x8000_1000,
        target=0x8000_1200,
        is_call=True,
        checkpoint_unresolved=(1 << 2) | (1 << 9),
        head_tag=3,
    )
    await _settle_after_edge(dut)
    _assert_idle(dut)

    # Both bits unresolved: JAL waits.
    _clear_inputs(dut)
    dut.i_checkpoint_unresolved.value = (1 << 2) | (1 << 9)
    dut.i_head_tag.value = 3
    await Timer(1, unit="ns")
    assert not dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    _assert_idle(dut)

    # Checkpoint 2 resolves; checkpoint 9 remains unresolved.
    # A younger mispredicted JAL arrives while the older one is staged and must
    # be ignored without replacing payload or wait bits.
    _clear_inputs(dut)
    _drive_jal_stage(
        dut,
        tag=14,
        checkpoint_id=6,
        pc=0x8000_9000,
        target=0x8000_9400,
        is_compressed=True,
        is_call=False,
        checkpoint_unresolved=(1 << 9),
        head_tag=3,
    )
    await Timer(1, unit="ns")
    assert not dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    _assert_idle(dut)

    # Checkpoint 9 resolves, and checkpoint 2 is reallocated to a younger branch
    # (bit 2 set again). Because bit 2 was cleared from jal_q_wait on the prior
    # edge, the reallocated bit does not block the staged JAL.
    _clear_inputs(dut)
    dut.i_checkpoint_unresolved.value = 1 << 2
    dut.i_head_tag.value = 3
    await Timer(1, unit="ns")
    assert dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)

    assert dut.o_early_mispredict_active.value
    assert dut.o_early_mispredict_is_jal.value
    assert int(dut.o_early_mispredict_tag.value) == 10
    assert int(dut.o_early_mispredict_checkpoint_id.value) == 11
    assert int(dut.o_early_mispredict_pc.value) == 0x8000_1000
    assert int(dut.o_early_mispredict_redirect_pc.value) == 0x8000_1200
    assert not dut.o_early_mispredict_is_compressed.value
    assert dut.o_early_mispredict_is_call.value

    _clear_inputs(dut)
    await _settle_after_edge(dut)
    assert dut.o_early_backend_recovery_pending.value
    assert int(dut.o_early_backend_flush_tag.value) == 10
    await _settle_after_edge(dut)
    _assert_idle(dut)


@cocotb.test()
async def test_early_jal_defers_to_branch_payload_ownership(dut: Any) -> None:
    """An issuing checkpointed branch owns the payload registers before a staged JAL."""
    await _setup_test(dut)

    # Case 1: a correctly predicted branch defers the JAL by one cycle without dropping it.
    _drive_jal_stage(
        dut,
        tag=12,
        checkpoint_id=7,
        pc=0x8000_2000,
        target=0x8000_2100,
        is_call=True,
        head_tag=1,
    )
    await _settle_after_edge(dut)
    _assert_idle(dut)

    _clear_inputs(dut)
    dut.i_head_tag.value = 1
    _drive_mispredict(
        dut,
        tag=5,
        checkpoint_id=2,
        pc=0x8000_1800,
        branch_target=0x8000_1900,
        mispredicted=False,
    )
    await Timer(1, unit="ns")
    assert not dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    _assert_idle(dut)

    # Next cycle without branch issue: the staged JAL launches with its own payload.
    _clear_inputs(dut)
    dut.i_head_tag.value = 1
    await Timer(1, unit="ns")
    assert dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    assert dut.o_early_mispredict_active.value
    assert dut.o_early_mispredict_is_jal.value
    assert int(dut.o_early_mispredict_tag.value) == 12
    assert int(dut.o_early_mispredict_redirect_pc.value) == 0x8000_2100

    _clear_inputs(dut)
    await _settle_after_edge(dut)
    await _settle_after_edge(dut)
    _assert_idle(dut)

    # Case 2: a mispredicted branch issue launches instead, and its pending phase
    # drops the staged JAL to commit-time recovery.
    _drive_jal_stage(
        dut,
        tag=16,
        checkpoint_id=8,
        pc=0x8000_2400,
        target=0x8000_2500,
        head_tag=2,
    )
    await _settle_after_edge(dut)

    _clear_inputs(dut)
    dut.i_head_tag.value = 2
    _drive_mispredict(
        dut,
        tag=6,
        checkpoint_id=3,
        pc=0x8000_1A00,
        branch_target=0x8000_1B00,
        mispredicted=True,
    )
    await Timer(1, unit="ns")
    assert dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    assert dut.o_early_mispredict_active.value
    assert not dut.o_early_mispredict_is_jal.value
    assert int(dut.o_early_mispredict_tag.value) == 6

    # During pending, jal_stage_kill clears jal_q_valid.
    _clear_inputs(dut)
    dut.i_head_tag.value = 2
    await _settle_after_edge(dut)
    assert dut.o_early_backend_recovery_pending.value
    assert int(dut.o_early_backend_flush_tag.value) == 6

    await _settle_after_edge(dut)
    _assert_idle(dut)
    await _settle_after_edge(dut)
    _assert_idle(dut)


@cocotb.test()
async def test_early_jal_suppressed_at_rob_head_and_dropped_on_own_commit(
    dut: Any,
) -> None:
    """A staged JAL at the ROB head does not launch and drops on commit recovery."""
    await _setup_test(dut)

    # Already at head when staged.
    _drive_jal_stage(
        dut,
        tag=9,
        checkpoint_id=4,
        pc=0x8000_3000,
        target=0x8000_3100,
        head_tag=9,
    )
    await _settle_after_edge(dut)
    _assert_idle(dut)

    _clear_inputs(dut)
    dut.i_head_tag.value = 9
    await Timer(1, unit="ns")
    assert not dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    _assert_idle(dut)

    # Commit-time recovery of the JAL clears the stage permanently.
    dut.i_mispredict_recovery_pending.value = 1
    await _settle_after_edge(dut)
    _assert_idle(dut)

    _clear_inputs(dut)
    dut.i_head_tag.value = 10
    await Timer(1, unit="ns")
    assert not dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    _assert_idle(dut)

    # Reaching head on the same cycle the last older checkpoint resolves
    # suppresses early launch so commit-time recovery takes over without racing.
    _drive_jal_stage(
        dut,
        tag=11,
        checkpoint_id=5,
        pc=0x8000_3200,
        target=0x8000_3300,
        checkpoint_unresolved=(1 << 1),
        head_tag=10,
    )
    await _settle_after_edge(dut)

    _clear_inputs(dut)
    dut.i_checkpoint_unresolved.value = 0
    dut.i_head_tag.value = 11
    await Timer(1, unit="ns")
    assert not dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    _assert_idle(dut)

    dut.i_mispredict_recovery_pending.value = 1
    await _settle_after_edge(dut)
    _clear_inputs(dut)
    dut.i_head_tag.value = 12
    await _settle_after_edge(dut)
    _assert_idle(dut)


@cocotb.test()
async def test_early_jal_drops_on_flushes_and_blocks_staging_during_recovery(
    dut: Any,
) -> None:
    """Flushes and other recoveries drop staged JALs and block further staging."""
    await _setup_test(dut)

    # Drop an already-staged waiting JAL on every flush or recovery kill cause.
    kill_signals = (
        "i_flush_all",
        "i_mispredict_recovery_pending",
        "i_fence_i_flush",
        "i_trap_taken_reg",
        "i_mret_taken_reg",
        "i_rst",
    )
    for index, signal in enumerate(kill_signals):
        _clear_inputs(dut)
        _drive_jal_stage(
            dut,
            tag=5 + index,
            checkpoint_id=index,
            checkpoint_unresolved=(1 << 0),
            head_tag=0,
        )
        await _settle_after_edge(dut)
        _assert_idle(dut)

        _clear_inputs(dut)
        dut.i_checkpoint_unresolved.value = 1 << 0
        getattr(dut, signal).value = 1
        await _settle_after_edge(dut)

        _clear_inputs(dut)
        dut.i_rst.value = 0
        dut.i_checkpoint_unresolved.value = 0
        dut.i_head_tag.value = 0
        await Timer(1, unit="ns")
        assert not dut.o_early_mispredict_fire.value, signal
        await _settle_after_edge(dut)
        _assert_idle(dut)

    # Block staging during flush_all and commit-time recovery.
    for signal in ("i_flush_all", "i_mispredict_recovery_pending"):
        _clear_inputs(dut)
        _drive_jal_stage(dut, tag=20, checkpoint_id=9, head_tag=1)
        getattr(dut, signal).value = 1
        await _settle_after_edge(dut)
        _clear_inputs(dut)
        dut.i_head_tag.value = 1
        await Timer(1, unit="ns")
        assert not dut.o_early_mispredict_fire.value, signal
        await _settle_after_edge(dut)
        _assert_idle(dut)

    # Block staging during both phases of another early recovery.
    _clear_inputs(dut)
    _drive_mispredict(dut, tag=3, checkpoint_id=1)
    await _settle_after_edge(dut)
    assert dut.o_early_mispredict_active.value

    # Phase 1 (early_mispredict_pending): staging must be blocked.
    _clear_inputs(dut)
    _drive_jal_stage(dut, tag=21, checkpoint_id=10, head_tag=1)
    await _settle_after_edge(dut)
    assert dut.o_early_backend_recovery_pending.value

    # Phase 2 (early_backend_recovery_pending): staging must also be blocked.
    _clear_inputs(dut)
    _drive_jal_stage(dut, tag=22, checkpoint_id=11, head_tag=1)
    await _settle_after_edge(dut)
    _assert_idle(dut)

    # Idle afterwards: neither JAL staged.
    _clear_inputs(dut)
    dut.i_head_tag.value = 1
    await Timer(1, unit="ns")
    assert not dut.o_early_mispredict_fire.value
    await _settle_after_edge(dut)
    _assert_idle(dut)

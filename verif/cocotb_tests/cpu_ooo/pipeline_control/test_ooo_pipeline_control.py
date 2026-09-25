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
from cocotb_tests.cpu_structs import (
    PIPELINE_CTRL_FIELDS,
    COMMIT_FIELDS,
    ROB_ALLOC_REQ_FIELDS as ALLOC_REQ_FIELDS,
)
from utils.packed_structs import (
    pack_struct as _pack_struct,
    unpack_struct as _unpack_struct,
)


CLOCK_PERIOD_NS = 10
ROB_TAG_WIDTH = 5
CHECKPOINT_ID_WIDTH = 3
REG_ADDR_WIDTH = 5
EXC_CAUSE_WIDTH = 5
FP_FLAGS_WIDTH = 5
RS_TYPE_WIDTH = 3


QUIESCENT_COMMIT: dict[str, int | bool] = {"valid": True, "dest_valid": True}


def _pack_alloc_req(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_alloc_req_t value."""
    return _pack_struct(ALLOC_REQ_FIELDS, fields)


def _pack_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a reorder_buffer_commit_t value."""
    return _pack_struct(COMMIT_FIELDS, fields)


def _read_pipeline_ctrl(dut: Any) -> dict[str, int | bool]:
    """Read and unpack the pipeline_ctrl_t output."""
    return _unpack_struct(PIPELINE_CTRL_FIELDS, int(dut.o_pipeline_ctrl.value))


def _drive_alloc_req(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the ROB allocation request struct."""
    dut.i_rob_alloc_req.value = _pack_alloc_req(fields)


def _drive_alloc_req_2(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive slot 2's ROB allocation request struct."""
    dut.i_rob_alloc_req_2.value = _pack_alloc_req(fields)


def _drive_checkpoint_save(dut: Any, checkpoint_id: int | None) -> None:
    """Drive dispatch's checkpoint save for this cycle (None: no save)."""
    dut.i_rob_checkpoint_valid.value = int(checkpoint_id is not None)
    dut.i_rob_checkpoint_id.value = checkpoint_id or 0


def _drive_resolve(dut: Any, checkpoint_id: int | None) -> None:
    """Drive a correct branch resolution for this cycle (None: no resolution)."""
    dut.i_branch_unresolved_decrement.value = int(checkpoint_id is not None)
    dut.i_branch_unresolved_checkpoint_id.value = checkpoint_id or 0


def _drive_commit(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the ROB commit struct."""
    packet = dict(QUIESCENT_COMMIT)
    packet.update(fields)
    dut.i_rob_commit.value = _pack_commit(packet)


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    _drive_alloc_req(dut, {})
    _drive_alloc_req_2(dut, {})
    _drive_commit(dut, QUIESCENT_COMMIT)
    _drive_checkpoint_save(dut, None)
    _drive_resolve(dut, None)
    dut.i_checkpoint_in_use.value = 0
    dut.i_csr_commit_fire.value = 0
    dut.i_trap_taken.value = 0
    dut.i_mret_taken.value = 0
    dut.i_trap_target.value = 0
    dut.i_dispatch_stall.value = 0
    dut.i_csr_wb_pending.value = 0
    dut.i_front_end_indirect_control_flow_pending.value = 0
    dut.i_disable_branch_prediction.value = 0
    dut.i_flush_pipeline.value = 0
    dut.i_fetch_pa_hold.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset pipeline-control state, and clear inputs."""
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


async def _dispatch_branch(
    dut: Any,
    in_use: int,
    checkpoint_id: int,
    *,
    slot2: bool = False,
    jal: bool = False,
) -> int:
    """Dispatch one branch that saves checkpoint_id and return the new in-use mask.

    A slot-2 branch dispatches behind a non-branch slot 1. The bench stands in
    for cpu_ooo's checkpoint_in_use, which sets the saved bit on the same edge.
    """
    branch = {"alloc_valid": True, "is_branch": True, "is_jal": jal}
    if slot2:
        _drive_alloc_req(dut, {"alloc_valid": True})
        _drive_alloc_req_2(dut, branch)
    else:
        _drive_alloc_req(dut, branch)
    _drive_checkpoint_save(dut, checkpoint_id)
    await _advance_cycle(dut)
    _drive_alloc_req(dut, {})
    _drive_alloc_req_2(dut, {})
    _drive_checkpoint_save(dut, None)
    in_use |= 1 << checkpoint_id
    dut.i_checkpoint_in_use.value = in_use
    return in_use


@cocotb.test()
async def test_idle_outputs_and_global_prediction_disable(dut: Any) -> None:
    """Idle state has no stalls, and the global prediction-disable gate passes through."""
    await _setup_test(dut)

    ctrl = _read_pipeline_ctrl(dut)
    assert not ctrl["reset"]
    assert not ctrl["stall"]
    assert not ctrl["stall_registered"]
    assert not ctrl["flush"]
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
    assert dut.o_id_stall_q.value
    assert not dut.o_replay_after_dispatch_stall_q.value

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
async def test_dispatch_replay_into_csr_allocation_keeps_local_owner(dut: Any) -> None:
    """A CSR that allocates in the dispatch-stall replay cycle keeps id_stall_q set."""
    await _setup_test(dut)

    dut.i_dispatch_stall.value = 1
    await _advance_cycle(dut)

    assert dut.o_id_stall_q.value
    assert dut.o_replay_after_dispatch_stall_q.value
    assert not dut.o_csr_in_flight.value

    dut.i_dispatch_stall.value = 0
    _drive_alloc_req(dut, {"alloc_valid": True, "is_csr": True})
    await _advance_cycle(dut)

    assert dut.o_serializing_alloc_fire.value
    assert dut.o_csr_in_flight.value
    assert dut.o_id_stall_q.value
    assert not dut.o_replay_after_dispatch_stall_q.value

    _drive_alloc_req(dut, {})
    await _advance_cycle(dut)

    assert dut.o_csr_in_flight.value
    assert dut.o_id_stall_q.value


@cocotb.test()
async def test_csr_allocated_during_fetch_hold_is_not_replayed(dut: Any) -> None:
    """A pre-existing fetch hold leaves the CSR in ID, so release only advances it."""
    await _setup_test(dut)

    # A fetch translation hold (i_fetch_pa_hold) already stalls the front end,
    # but the registered dispatch-valid path may still allocate the CSR in ID.
    dut.i_fetch_pa_hold.value = 1
    _drive_alloc_req(dut, {"alloc_valid": True, "is_csr": True})
    await _advance_cycle(dut)

    assert dut.o_csr_in_flight.value
    assert dut.o_id_stall_q.value

    dut.i_fetch_pa_hold.value = 0
    _drive_alloc_req(dut, {})
    await _advance_cycle(dut)

    # A CSR with an integer destination releases after its delayed writeback.
    _drive_commit(dut, {"valid": True, "dest_valid": True})
    dut.i_csr_commit_fire.value = 1
    await _advance_cycle(dut)
    assert not dut.o_csr_in_flight.value
    assert dut.o_id_stall_q.value

    dut.i_csr_commit_fire.value = 0
    dut.i_csr_wb_pending.value = 1
    await _advance_cycle(dut)

    # The serialize-release pulse still marks the writeback boundary, but ID
    # stays invalid this cycle because the instruction it holds is the CSR.
    assert dut.o_replay_after_serialize_stall_q.value
    assert dut.o_id_stall_q.value

    dut.i_csr_wb_pending.value = 0
    await _advance_cycle(dut)

    assert not dut.o_replay_after_serialize_stall_q.value
    assert not dut.o_id_stall_q.value


@cocotb.test()
async def test_csr_allocation_wins_release_collisions(dut: Any) -> None:
    """A CSR allocated in the cycle of a CSR writeback or commit release stays in flight."""
    await _setup_test(dut)

    dut.i_csr_wb_pending.value = 1
    _drive_alloc_req(dut, {"alloc_valid": True, "is_csr": True})
    await _advance_cycle(dut)

    assert dut.o_csr_in_flight.value
    assert dut.o_id_stall_q.value
    assert dut.o_replay_after_serialize_stall_q.value

    dut.i_csr_wb_pending.value = 0
    _drive_alloc_req(dut, {})
    await _advance_cycle(dut)

    assert dut.o_csr_in_flight.value
    assert dut.o_id_stall_q.value
    assert not dut.o_replay_after_serialize_stall_q.value

    dut.i_csr_commit_fire.value = 1
    _drive_commit(dut, {"valid": True, "dest_valid": False})
    _drive_alloc_req(dut, {"alloc_valid": True, "is_csr": True})
    await _advance_cycle(dut)

    assert dut.o_csr_in_flight.value
    assert dut.o_id_stall_q.value
    assert dut.o_replay_after_serialize_stall_q.value


@cocotb.test()
async def test_flush_wins_csr_allocation_without_ghost_owner(dut: Any) -> None:
    """A flushed CSR allocation leaves no serialization or replay state behind."""
    await _setup_test(dut)

    _drive_alloc_req(dut, {"alloc_valid": True, "is_csr": True})
    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)

    assert not dut.o_serializing_alloc_fire.value
    assert not dut.o_csr_in_flight.value
    assert not dut.o_id_stall_q.value
    assert not dut.o_replay_after_dispatch_stall_q.value
    assert not dut.o_replay_after_serialize_stall_q.value
    assert not _read_pipeline_ctrl(dut)["stall"]

    _drive_alloc_req(dut, {})
    dut.i_flush_pipeline.value = 0
    await _advance_cycle(dut)

    assert not dut.o_csr_in_flight.value
    assert not dut.o_id_stall_q.value
    assert not _read_pipeline_ctrl(dut)["stall"]


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
async def test_unresolved_branch_serializes_younger_indirect_control_flow(
    dut: Any,
) -> None:
    """An unresolved non-JAL branch serializes younger indirect control flow."""
    await _setup_test(dut)

    await _dispatch_branch(dut, 0, 2)
    dut.i_front_end_indirect_control_flow_pending.value = 1
    await _advance_cycle(dut)

    assert dut.o_front_end_cf_serialize_stall.value
    assert _read_pipeline_ctrl(dut)["stall"]

    _drive_resolve(dut, 2)
    await _advance_cycle(dut)

    assert dut.o_front_end_cf_serialize_stall.value

    _drive_resolve(dut, None)
    await _advance_cycle(dut)

    assert not dut.o_front_end_cf_serialize_stall.value


@cocotb.test()
async def test_jal_alloc_does_not_create_unresolved_branch_stall(dut: Any) -> None:
    """JAL checkpoint allocation is not tracked as unresolved branch work."""
    await _setup_test(dut)

    await _dispatch_branch(dut, 0, 0, jal=True)
    dut.i_front_end_indirect_control_flow_pending.value = 1
    await _advance_cycle(dut)

    assert not dut.o_front_end_cf_serialize_stall.value
    assert not _read_pipeline_ctrl(dut)["stall"]


@cocotb.test()
async def test_slot2_branch_stays_unresolved_after_older_resolves(dut: Any) -> None:
    """A branch dispatched from slot 2 counts until it resolves itself.

    An older slot-1 branch resolving must not retire the slot-2 branch.
    """
    await _setup_test(dut)

    in_use = await _dispatch_branch(dut, 0, 0)
    await _dispatch_branch(dut, in_use, 1, slot2=True)
    _drive_resolve(dut, 0)
    await _advance_cycle(dut)
    _drive_resolve(dut, None)
    dut.i_front_end_indirect_control_flow_pending.value = 1
    await _advance_cycle(dut)

    assert dut.o_front_end_cf_serialize_stall.value, "the slot-2 branch is unresolved"

    _drive_resolve(dut, 1)
    await _advance_cycle(dut)
    _drive_resolve(dut, None)
    await _advance_cycle(dut)

    assert not dut.o_front_end_cf_serialize_stall.value


@cocotb.test()
async def test_early_recovery_keeps_older_unresolved_branch(dut: Any) -> None:
    """A partial flush forgets only the branches it kills.

    The younger branch's early recovery flushes the front end and frees its
    checkpoint; the older branch is still unresolved and still serializes.
    """
    await _setup_test(dut)

    in_use = await _dispatch_branch(dut, 0, 0)
    in_use = await _dispatch_branch(dut, in_use, 1)
    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)
    dut.i_flush_pipeline.value = 0
    dut.i_checkpoint_in_use.value = in_use & ~(1 << 1)
    dut.i_front_end_indirect_control_flow_pending.value = 1
    await _advance_cycle(dut)

    assert dut.o_front_end_cf_serialize_stall.value, "the older branch is unresolved"

    _drive_resolve(dut, 0)
    await _advance_cycle(dut)
    _drive_resolve(dut, None)
    await _advance_cycle(dut)

    assert not dut.o_front_end_cf_serialize_stall.value


@cocotb.test()
async def test_flushed_branch_and_reused_checkpoint_are_not_unresolved(
    dut: Any,
) -> None:
    """A branch flushed before it resolves stops counting with its checkpoint.

    A JAL that later reuses the checkpoint does not revive the stale bit.
    """
    await _setup_test(dut)

    await _dispatch_branch(dut, 0, 3)
    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)
    dut.i_flush_pipeline.value = 0
    dut.i_checkpoint_in_use.value = 0
    dut.i_front_end_indirect_control_flow_pending.value = 1
    await _advance_cycle(dut)
    await _advance_cycle(dut)

    assert not dut.o_front_end_cf_serialize_stall.value

    await _dispatch_branch(dut, 0, 3, jal=True)
    await _advance_cycle(dut)

    assert not dut.o_front_end_cf_serialize_stall.value


@cocotb.test()
async def test_flush_clears_serialization_and_starts_holdoff(dut: Any) -> None:
    """Flush clears serialization state and starts a stall-sensitive holdoff."""
    await _setup_test(dut)

    _drive_alloc_req(dut, {"alloc_valid": True, "is_csr": True})
    await _advance_cycle(dut)

    assert dut.o_csr_in_flight.value

    _drive_alloc_req(dut, {})
    dut.i_flush_pipeline.value = 1
    await _advance_cycle(dut)

    assert not dut.o_csr_in_flight.value
    assert not dut.o_serializing_alloc_fire.value
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

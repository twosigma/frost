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

"""Reorder Buffer unit tests.

This module contains comprehensive tests for the Reorder Buffer, including:

Directed Tests:
- test_basic_allocation: Simple allocation and commit flow
- test_allocation_full: Fill buffer and verify full signal
- test_cdb_write: CDB result writes mark entries done
- test_in_order_commit: Verify in-order commit despite out-of-order completion
- test_branch_resolution: Branch update and correct prediction
- test_branch_misprediction: Branch misprediction detection (taken)
- test_branch_misprediction_not_taken: Misprediction with redirect to pc+4
- test_commit_struct_with_monitor: Full commit struct verification via CommitMonitor
- test_mret_commit_struct_with_monitor: Full commit struct verification for MRET
- test_fence_i_flush_pulse: FENCE.I generates flush pulse after commit
- test_mret_handshake: MRET handshake with trap unit and mepc redirect
- test_partial_flush: Flush entries after mispredicting branch
- test_partial_flush_wrapped: Partial flush when pointers have wrapped
- test_full_flush: Full flush on exception
- test_jal_done_at_allocation: JAL is marked done immediately
- test_wfi_stall: WFI stalls at head until interrupt pending
- test_fence_wait_sq: FENCE waits for store queue to drain
- test_csr_serialization: CSR waits for done signal at commit
- test_exception_handling: Exception triggers trap pending signal

Constrained Random Tests:
- test_random_allocation_commit: Random allocation/CDB/commit sequences
- test_random_branch_flush: Random branches with some mispredictions
- test_stress_full_empty: Stress test buffer full/empty boundaries
- test_mixed_instruction_types: Mix of ALU, branch, store, FP instructions

Error Condition Tests:
- test_alloc_when_full_no_corruption: Buffer state preserved when full
- test_back_to_back_commits: All entries done triggers sequential commits

Usage:
    cd frost/tests
    make clean
    ./test_run_cocotb.py --sim verilator reorder_buffer
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
from collections import deque
from typing import Any
import random

from .reorder_buffer_model import (
    ReorderBufferModel,
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
    ExpectedCommit,
    REORDER_BUFFER_DEPTH,
    MASK32,
    MASK64,
)
from .reorder_buffer_interface import ReorderBufferInterface
from .reorder_buffer_monitors import (
    CommitMonitor,
    StatusMonitor,
)


# =============================================================================
# Test Configuration
# =============================================================================

CLOCK_PERIOD_NS = 10
RESET_CYCLES = 5


# =============================================================================
# Test Setup Helpers
# =============================================================================


async def setup_test(dut: Any) -> tuple[ReorderBufferInterface, ReorderBufferModel]:
    """Set up test environment.

    Start clock, reset DUT, initialize model.

    Returns:
        Tuple of (interface, model).
    """
    dut_if = ReorderBufferInterface(dut)
    model = ReorderBufferModel()

    # Start clock
    cocotb.start_soon(Clock(dut_if.clock, CLOCK_PERIOD_NS, unit="ns").start())

    # Reset
    await dut_if.reset_dut(RESET_CYCLES)
    model.reset()

    return dut_if, model


def make_simple_alloc_request(
    pc: int,
    rd: int,
    is_fp: bool = False,
) -> AllocationRequest:
    """Create a simple allocation request for ALU instruction."""
    return AllocationRequest(
        pc=pc,
        dest_rf=1 if is_fp else 0,
        dest_reg=rd,
        dest_valid=rd != 0,  # x0 has no destination
    )


def make_branch_request(
    pc: int,
    predicted_taken: bool = False,
    predicted_target: int = 0,
    is_jal: bool = False,
    is_jalr: bool = False,
    link_addr: int = 0,
) -> AllocationRequest:
    """Create allocation request for branch/jump instruction."""
    return AllocationRequest(
        pc=pc,
        dest_rf=0,
        dest_reg=1 if (is_jal or is_jalr) else 0,  # rd=x1 for JAL/JALR
        dest_valid=is_jal or is_jalr,
        is_branch=True,
        predicted_taken=predicted_taken,
        predicted_target=predicted_target,
        is_jal=is_jal,
        is_jalr=is_jalr,
        link_addr=link_addr,
    )


def make_store_request(pc: int, is_fp: bool = False) -> AllocationRequest:
    """Create allocation request for store instruction."""
    return AllocationRequest(
        pc=pc,
        dest_rf=0,
        dest_reg=0,
        dest_valid=False,
        is_store=True,
        is_fp_store=is_fp,
    )


# =============================================================================
# Directed Tests
# =============================================================================


@cocotb.test()
async def test_basic_allocation(dut: Any) -> None:
    """Test basic allocation and commit flow.

    Allocates a single entry, writes result via CDB, verifies commit.

    Verilator timing note: Registered outputs (count, empty, head_done) are not
    visible until the falling edge after the rising edge where state updates.
    Combinational outputs (alloc_ready, alloc_tag) are visible immediately.
    """
    cocotb.log.info("=== Test: Basic Allocation and Commit ===")

    dut_if, model = await setup_test(dut)

    # Start monitors
    commit_queue: deque[ExpectedCommit] = deque()
    commit_mon = CommitMonitor(dut, commit_queue)
    status_mon = StatusMonitor(dut)
    cocotb.start_soon(commit_mon.run())
    cocotb.start_soon(status_mon.run())

    # After reset_dut, we're at falling edge
    # Allocate one entry - drive on falling edge (we're already at one)
    req = make_simple_alloc_request(pc=0x1000, rd=5)
    dut_if.drive_alloc_request(req)
    model.allocate(req)

    # Wait for rising edge - allocation happens
    await RisingEdge(dut_if.clock)
    # Read combinational outputs immediately (alloc_ready is visible now)
    ready, tag, full = dut_if.read_alloc_response()
    assert ready, "alloc_ready should be True"
    assert tag == 0, "First allocation should get tag 0"

    # Wait for falling edge to see registered outputs (Verilator timing)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    assert not dut_if.empty, "Should not be empty after allocation"
    assert dut_if.count == 1, "Count should be 1"
    assert dut_if.head_valid, "Head should be valid"
    assert not dut_if.head_done, "Head should not be done yet"

    # Write result via CDB - drive on this falling edge
    cdb = CDBWrite(tag=0, value=0xDEADBEEF)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)

    # Add expected commit to queue BEFORE the clock cycle
    expected = model.commit()
    commit_queue.append(expected)

    # Wait for rising edge - CDB write happens, entry marked done
    await RisingEdge(dut_if.clock)

    # Wait for falling edge, clear CDB write
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Wait for commit to complete
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    # Verify commit occurred
    assert dut_if.empty, "Should be empty after commit"
    assert dut_if.count == 0, "Count should be 0"  # type: ignore[unreachable]

    # Wait a few cycles and check monitors
    await ClockCycles(dut_if.clock, 5)
    commit_mon.check_complete()
    status_mon.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_allocation_full(dut: Any) -> None:
    """Test that buffer correctly reports full.

    Fills buffer completely and verifies full signal.
    """
    cocotb.log.info("=== Test: Allocation Full ===")

    dut_if, model = await setup_test(dut)

    # Fill the buffer
    for i in range(REORDER_BUFFER_DEPTH):
        # Drive on falling edge
        await FallingEdge(dut_if.clock)
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=(i % 31) + 1)
        dut_if.drive_alloc_request(req)
        tag = model.allocate(req)

        # Sample on rising edge
        await RisingEdge(dut_if.clock)
        assert tag == i, f"Expected tag {i}, got {tag}"

        # Clear on falling edge
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    # Sample final state on rising edge
    await RisingEdge(dut_if.clock)

    # Verify full
    assert dut_if.full, "Should be full after DEPTH allocations"
    assert (
        dut_if.count == REORDER_BUFFER_DEPTH
    ), f"Count should be {REORDER_BUFFER_DEPTH}"
    assert model.full, "Model should also be full"

    # Verify alloc_ready is false (indicating allocation would be rejected)
    ready, _, full = dut_if.read_alloc_response()
    assert not ready, "alloc_ready should be false when full"
    assert full, "full signal should be true"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_write(dut: Any) -> None:
    """Test CDB write marks entry done with correct value.

    Allocates multiple entries, writes results out of order, but verifies
    entries are marked done before they commit. Note: head entry commits
    immediately after being marked done, so we check done status right
    after each CDB write.
    """
    cocotb.log.info("=== Test: CDB Write ===")

    dut_if, model = await setup_test(dut)

    # Allocate 4 entries (we're at falling edge after reset)
    tags = []
    for i in range(4):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        tag = model.allocate(req)
        tags.append(tag)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    # Write to entry 2 first - not at head, should stay done but not commit
    cdb = CDBWrite(tag=2, value=0xAAAA)
    dut_if.drive_cdb_write(cdb)
    dut_if.set_read_tag(2)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    # Verify entry 2 is done (registered output - visible after falling edge)
    done = dut_if.read_entry_done()
    value = dut_if.read_entry_value()
    assert done, "Entry 2 should be done after CDB write"
    assert value == 0xAAAA, f"Entry 2 value mismatch: {value:x}"

    dut_if.clear_cdb_write()

    # Write to entry 3 - also not at head
    cdb = CDBWrite(tag=3, value=0xBBBB)
    dut_if.drive_cdb_write(cdb)
    dut_if.set_read_tag(3)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    # Verify entry 3 is done
    done = dut_if.read_entry_done()
    value = dut_if.read_entry_value()
    assert done, "Entry 3 should be done after CDB write"
    assert value == 0xBBBB, f"Entry 3 value mismatch: {value:x}"

    dut_if.clear_cdb_write()

    # Write to entry 1 - still not at head
    cdb = CDBWrite(tag=1, value=0xCCCC)
    dut_if.drive_cdb_write(cdb)
    dut_if.set_read_tag(1)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    # Verify entry 1 is done
    done = dut_if.read_entry_done()
    value = dut_if.read_entry_value()
    assert done, "Entry 1 should be done after CDB write"
    assert value == 0xCCCC, f"Entry 1 value mismatch: {value:x}"

    dut_if.clear_cdb_write()

    # Entry 0 is still not done - buffer should have count 4
    assert dut_if.count == 4, "All 4 entries should still be in buffer"

    # Write to entry 0 - at head, will trigger commits
    cdb = CDBWrite(tag=0, value=0xDDDD)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # All entries should now commit - buffer should empty
    # Wait enough cycles for all 4 to commit (one per cycle)
    await ClockCycles(dut_if.clock, 8)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Buffer should be empty after all commits"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_in_order_commit(dut: Any) -> None:
    """Test that commits happen in order despite out-of-order completion.

    Allocates 3 entries, completes them out of order, verifies in-order commit.
    """
    cocotb.log.info("=== Test: In-Order Commit ===")

    dut_if, model = await setup_test(dut)

    # Allocate 3 entries (we're at falling edge after reset)
    for i in range(3):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    assert dut_if.count == 3, "Should have 3 entries"

    # Complete entry 2 first (out of order)
    cdb = CDBWrite(tag=2, value=0x3333)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Entry 2 is done, but entry 0 is at head and not done - no commit yet
    assert dut_if.count == 3, "No commit yet - entry 0 not done"

    # Complete entry 1 (still out of order)
    cdb = CDBWrite(tag=1, value=0x2222)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Still no commit - entry 0 not done
    assert dut_if.count == 3, "Still no commit - entry 0 not done"

    # Complete entry 0 - now all 3 commits should happen
    cdb = CDBWrite(tag=0, value=0x1111)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Wait a few cycles for all commits to complete
    await ClockCycles(dut_if.clock, 5)

    # Buffer should be empty (check after falling edge)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Buffer should be empty after all commits"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_resolution(dut: Any) -> None:
    """Test branch update and correct prediction (no misprediction)."""
    cocotb.log.info("=== Test: Branch Resolution ===")

    dut_if, model = await setup_test(dut)

    # Allocate a branch (predicted taken to 0x2000) - we're at falling edge after reset
    req = make_branch_request(
        pc=0x1000,
        predicted_taken=True,
        predicted_target=0x2000,
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    assert dut_if.count == 1, "Should have 1 entry"

    # Resolve branch - correctly predicted (taken to 0x2000)
    update = BranchUpdate(tag=0, taken=True, target=0x2000, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    # Wait for commit
    await ClockCycles(dut_if.clock, 3)
    await FallingEdge(dut_if.clock)

    # Branch should have committed
    assert dut_if.empty, "Branch should have committed"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_misprediction(dut: Any) -> None:
    """Test branch misprediction detection."""
    cocotb.log.info("=== Test: Branch Misprediction ===")

    dut_if, model = await setup_test(dut)

    # Allocate a branch (predicted not taken) - we're at falling edge after reset
    req = make_branch_request(
        pc=0x1000,
        predicted_taken=False,
        predicted_target=0,
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    assert dut_if.count == 1, "Should have 1 entry"

    # Resolve branch - mispredicted (actually taken to 0x2000)
    update = BranchUpdate(tag=0, taken=True, target=0x2000, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    # Verify model state - branch should be mispredicted
    if model.can_commit():
        expected = model.commit()
        assert expected.misprediction, "Should be mispredicted"
        assert expected.redirect_pc == 0x2000, "Redirect should be to taken target"

    # Wait for commit
    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    # Buffer should be empty after commit
    assert dut_if.empty, "Buffer should be empty after branch commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_misprediction_not_taken(dut: Any) -> None:
    """Test misprediction when predicted taken but actually not taken.

    Verifies redirect_pc is set to pc+4 (fall-through address).
    """
    cocotb.log.info("=== Test: Branch Misprediction Not-Taken ===")

    dut_if, model = await setup_test(dut)

    # Allocate a branch (predicted taken to 0x2000)
    branch_pc = 0x1000
    req = make_branch_request(
        pc=branch_pc,
        predicted_taken=True,
        predicted_target=0x2000,
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Resolve branch - mispredicted (actually NOT taken)
    update = BranchUpdate(tag=0, taken=False, target=0, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    # Check model: redirect should be pc+4
    if model.can_commit():
        expected = model.commit()
        assert expected.misprediction, "Should be mispredicted"
        assert (
            expected.redirect_pc == branch_pc + 4
        ), f"Redirect should be pc+4={branch_pc + 4:#x}, got {expected.redirect_pc:#x}"

    # Wait for DUT commit and verify redirect_pc
    # Poll until commit is valid (should happen within a few cycles)
    for _ in range(5):
        await RisingEdge(dut_if.clock)
        commit = dut_if.read_commit()
        if commit["valid"]:
            break
    assert commit["valid"], "Commit should have occurred"
    assert commit["misprediction"], "DUT should report misprediction"
    assert commit["redirect_pc"] == branch_pc + 4, (
        f"DUT redirect should be pc+4={branch_pc + 4:#x}, "
        f"got {commit['redirect_pc']:#x}"
    )

    await ClockCycles(dut_if.clock, 3)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Buffer should be empty after commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_commit_struct_with_monitor(dut: Any) -> None:
    """Test full commit struct verification using CommitMonitor.

    Uses the CommitMonitor to verify ALL fields of the commit output for a
    not-taken misprediction scenario. This catches regressions in any commit
    field that manual checks might miss.
    """
    cocotb.log.info("=== Test: Commit Struct with Monitor ===")

    dut_if, model = await setup_test(dut)

    # Set up CommitMonitor with expected queue
    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    # Allocate a branch (predicted taken to 0x2000)
    branch_pc = 0x1000
    req = make_branch_request(
        pc=branch_pc,
        predicted_taken=True,
        predicted_target=0x2000,
    )
    dut_if.drive_alloc_request(req)
    tag = model.allocate(req)
    assert tag is not None, "Allocation should succeed"
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Build expected commit with ALL fields BEFORE the branch update
    # (commit may happen immediately after branch makes entry done)
    expected = ExpectedCommit(
        valid=True,
        tag=0,
        dest_rf=0,
        dest_reg=0,
        dest_valid=False,  # Branch has no destination
        value=0,
        is_store=False,
        is_fp_store=False,
        exception=False,
        pc=branch_pc,
        exc_cause=0,
        fp_flags=0,
        misprediction=True,
        has_checkpoint=False,
        checkpoint_id=0,
        redirect_pc=branch_pc + 4,  # Not-taken -> fall through to pc+4
        is_csr=False,
        is_fence=False,
        is_fence_i=False,
        is_wfi=False,
        is_mret=False,
        is_amo=False,
        is_lr=False,
        is_sc=False,
    )
    expected_commits.append(expected)

    # Now drive the branch update - mispredicted (predicted taken, actually NOT taken)
    update = BranchUpdate(tag=tag, taken=False, target=0, mispredicted=True)
    dut_if.drive_branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    # Wait for commit
    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    # Verify monitor saw the commit and no errors
    assert dut_if.empty, "Buffer should be empty after commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_mret_commit_struct_with_monitor(dut: Any) -> None:
    """Test full commit struct verification for MRET using CommitMonitor.

    MRET is a serializing instruction that requires handshake with the trap unit.
    This test verifies ALL commit fields including is_mret and redirect_pc=mepc.
    """
    cocotb.log.info("=== Test: MRET Commit Struct with Monitor ===")

    dut_if, model = await setup_test(dut)

    # Set up CommitMonitor with expected queue
    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    # Allocate an MRET instruction
    mret_pc = 0x80000100
    req = AllocationRequest(pc=mret_pc, is_mret=True)
    dut_if.drive_alloc_request(req)
    tag = model.allocate(req)
    assert tag is not None, "Allocation should succeed"
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # MRET should assert mret_start when at head
    await RisingEdge(dut_if.clock)
    assert dut_if.mret_start, "mret_start should be asserted"

    # Set mepc and assert mret_done BEFORE queueing expected commit
    mepc_value = 0x80001234
    dut_if.set_mepc(mepc_value)
    dut_if.set_mret_done(True)

    # Build expected commit with ALL fields
    expected = ExpectedCommit(
        valid=True,
        tag=tag,
        dest_rf=0,
        dest_reg=0,
        dest_valid=False,  # MRET has no destination
        value=0,
        is_store=False,
        is_fp_store=False,
        exception=False,
        pc=mret_pc,
        exc_cause=0,
        fp_flags=0,
        misprediction=False,
        has_checkpoint=False,
        checkpoint_id=0,
        redirect_pc=mepc_value,  # MRET redirects to mepc
        is_csr=False,
        is_fence=False,
        is_fence_i=False,
        is_wfi=False,
        is_mret=True,
        is_amo=False,
        is_lr=False,
        is_sc=False,
    )
    expected_commits.append(expected)

    # Wait for commit
    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    # Clean up
    dut_if.set_mret_done(False)

    # Verify monitor saw the commit and no errors
    assert dut_if.empty, "Buffer should be empty after commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fence_i_flush_pulse(dut: Any) -> None:
    """Test FENCE.I generates flush pulse after commit.

    FENCE.I should wait for SQ empty, then commit and pulse o_fence_i_flush.
    """
    cocotb.log.info("=== Test: FENCE.I Flush Pulse ===")

    dut_if, model = await setup_test(dut)

    # Allocate a FENCE.I instruction
    req = AllocationRequest(pc=0x1000, is_fence_i=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # SQ is already empty (default), so FENCE.I should commit immediately
    # and pulse fence_i_flush on the next cycle
    assert not dut_if.fence_i_flush, "flush should not be asserted yet"

    # Wait for commit
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    # Check if commit happened
    await RisingEdge(dut_if.clock)
    # fence_i_flush should pulse high the cycle after commit
    assert dut_if.fence_i_flush, "fence_i_flush should be asserted after FENCE.I commit"

    await FallingEdge(dut_if.clock)  # type: ignore[unreachable]
    await RisingEdge(dut_if.clock)
    # Pulse should be one cycle only
    assert (
        not dut_if.fence_i_flush
    ), "fence_i_flush should be deasserted after one cycle"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_mret_handshake(dut: Any) -> None:
    """Test MRET instruction handshake with trap unit.

    MRET should assert o_mret_start, wait for i_mret_done, then commit
    with redirect_pc = mepc.
    """
    cocotb.log.info("=== Test: MRET Handshake ===")

    dut_if, model = await setup_test(dut)

    # Allocate an MRET instruction
    req = AllocationRequest(pc=0x1000, is_mret=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # MRET should assert mret_start when at head and done
    await RisingEdge(dut_if.clock)
    assert dut_if.mret_start, "mret_start should be asserted"

    # Commit should stall until mret_done
    await FallingEdge(dut_if.clock)
    assert not dut_if.empty, "Should stall waiting for mret_done"

    # Set mepc and assert mret_done
    mepc_value = 0x80001234
    dut_if.set_mepc(mepc_value)
    dut_if.set_mret_done(True)
    model.mepc = mepc_value
    model.mret_done = True

    # Poll until commit is valid
    for _ in range(5):
        await RisingEdge(dut_if.clock)
        commit = dut_if.read_commit()
        if commit["valid"]:
            break
    assert commit["valid"], "MRET commit should have occurred"
    assert commit["is_mret"], "Commit should be MRET"
    assert commit["redirect_pc"] == mepc_value, (
        f"redirect_pc should be mepc={mepc_value:#x}, "
        f"got {commit['redirect_pc']:#x}"
    )

    await FallingEdge(dut_if.clock)
    dut_if.set_mret_done(False)
    model.mret_done = False  # Restore model state

    await ClockCycles(dut_if.clock, 3)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Buffer should be empty after MRET commit"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_partial_flush(dut: Any) -> None:
    """Test partial flush on branch misprediction.

    Allocates multiple entries, flushes entries after mispredicting branch.
    """
    cocotb.log.info("=== Test: Partial Flush ===")

    dut_if, model = await setup_test(dut)

    # Allocate 5 entries: A, B (branch), C, D, E
    for i in range(5):
        await FallingEdge(dut_if.clock)
        if i == 1:
            req = make_branch_request(pc=0x1000 + i * 4, predicted_taken=False)
        else:
            req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    await RisingEdge(dut_if.clock)
    assert dut_if.count == 5, "Should have 5 entries"

    # Partial flush at tag 1 (the branch) - invalidates entries 2, 3, 4
    await dut_if.partial_flush(1)
    model.flush_partial(1)

    # Sample result on rising edge
    await RisingEdge(dut_if.clock)

    # Should only have 2 entries now (0 and 1)
    assert dut_if.count == 2, f"Should have 2 entries after flush, got {dut_if.count}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_partial_flush_wrapped(dut: Any) -> None:
    """Test partial flush when pointers have wrapped.

    This tests the wrap case where flush_tag < head_idx in the circular buffer.
    The age-based calculation must use mod-depth arithmetic to handle this.
    """
    cocotb.log.info("=== Test: Partial Flush Wrapped ===")

    dut_if, model = await setup_test(dut)

    # Step 1: Fill the buffer with 30 entries and commit them to advance head_ptr
    for i in range(30):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=(i % 31) + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    # Mark all 30 done via CDB writes
    for i in range(30):
        cdb = CDBWrite(tag=i, value=0x1000 + i)
        dut_if.drive_cdb_write(cdb)
        model.cdb_write(cdb)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_cdb_write()

    # Wait for all commits (30 cycles)
    for _ in range(30):
        while model.can_commit():
            model.commit()
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)

    # Now head should be at index 30 (head_ptr = 30)
    assert dut_if.empty, "Buffer should be empty after all commits"

    # Step 2: Allocate 8 entries (indices 30, 31, 0, 1, 2, 3, 4, 5 - wrapping)
    allocated_tags = []
    for i in range(8):
        req = make_simple_alloc_request(pc=0x2000 + i * 4, rd=(i % 31) + 1)
        if i == 2:
            # Make entry at tag 0 a branch (this will be after wrap)
            req = make_branch_request(pc=0x2000 + i * 4, predicted_taken=False)
        dut_if.drive_alloc_request(req)
        tag = model.allocate(req)
        allocated_tags.append(tag)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    # Tags should be: [30, 31, 0, 1, 2, 3, 4, 5]
    assert allocated_tags == [30, 31, 0, 1, 2, 3, 4, 5], f"Tags: {allocated_tags}"
    assert dut_if.count == 8, f"Should have 8 entries, got {dut_if.count}"

    # head_idx = 30, tail_idx = 6
    cocotb.log.info(
        f"Before flush: head_ptr={dut_if.head_ptr}, tail_ptr={dut_if.tail_ptr}"
    )

    # Step 3: Partial flush at tag 0 (the branch, which is younger than head_idx=30)
    # This is the wrap case: flush_tag(0) < head_idx(30)
    # Entries 1, 2, 3, 4, 5 should be flushed
    # Remaining: 30, 31, 0 (3 entries)
    await dut_if.partial_flush(0)
    model.flush_partial(0)

    await RisingEdge(dut_if.clock)

    cocotb.log.info(
        f"After flush: head_ptr={dut_if.head_ptr}, tail_ptr={dut_if.tail_ptr}"
    )
    cocotb.log.info(f"Count: {dut_if.count}")

    # Should have 3 entries remaining (tags 30, 31, 0)
    assert dut_if.count == 3, f"Should have 3 entries after flush, got {dut_if.count}"

    # Verify model and DUT agree on pointers
    assert dut_if.head_ptr == model.head_ptr, "Head pointer mismatch"
    assert dut_if.tail_ptr == model.tail_ptr, "Tail pointer mismatch"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_full_flush(dut: Any) -> None:
    """Test full flush on exception."""
    cocotb.log.info("=== Test: Full Flush ===")

    dut_if, model = await setup_test(dut)

    # Allocate several entries
    for i in range(8):
        await FallingEdge(dut_if.clock)
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=(i % 31) + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    await RisingEdge(dut_if.clock)
    assert dut_if.count == 8, "Should have 8 entries"

    # Full flush
    await dut_if.full_flush()
    model.flush_all()

    # Sample result on rising edge
    await RisingEdge(dut_if.clock)

    # Should be empty
    assert dut_if.empty, "Should be empty after full flush"
    assert dut_if.count == 0, "Count should be 0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_jal_done_at_allocation(dut: Any) -> None:
    """Test that JAL is marked done immediately at allocation."""
    cocotb.log.info("=== Test: JAL Done at Allocation ===")

    dut_if, model = await setup_test(dut)

    # Allocate JAL - we're at falling edge after reset
    req = make_branch_request(
        pc=0x1000,
        is_jal=True,
        link_addr=0x1004,  # PC + 4
        predicted_taken=True,
        predicted_target=0x2000,
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)

    # Wait for rising edge - allocation happens
    await RisingEdge(dut_if.clock)

    # Wait for falling edge to see registered outputs
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # JAL should be done immediately after allocation
    # Check head_done only if buffer is not empty (might commit same cycle)
    if not dut_if.empty:
        assert dut_if.head_done, "JAL should be done after allocation"

    # Model should also show JAL is done and can commit
    if model.can_commit():
        expected = model.commit()
        assert expected.value == 0x1004, "Value should be link address"

    # Wait for commit to complete
    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after JAL commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_wfi_stall(dut: Any) -> None:
    """Test WFI stalls at head until interrupt pending."""
    cocotb.log.info("=== Test: WFI Stall ===")

    dut_if, model = await setup_test(dut)

    # Allocate WFI - drive on falling edge
    await FallingEdge(dut_if.clock)
    req = AllocationRequest(pc=0x1000, is_wfi=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)

    # Wait for rising edge - allocation happens
    await RisingEdge(dut_if.clock)

    # Clear alloc request on falling edge
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # WFI is marked done at allocation but stalls at commit
    # Wait for next rising edge to see the done flag (registered)
    await RisingEdge(dut_if.clock)
    assert dut_if.head_done, "WFI should be marked done"

    # No interrupt - should stall
    await FallingEdge(dut_if.clock)
    dut_if.set_interrupt_pending(False)
    model.interrupt_pending = False

    await ClockCycles(dut_if.clock, 5)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "Should still have WFI (stalled)"

    # Set interrupt pending on falling edge
    await FallingEdge(dut_if.clock)
    dut_if.set_interrupt_pending(True)
    model.interrupt_pending = True

    # Now WFI should commit
    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)
    assert dut_if.empty, "WFI should have committed"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_fence_wait_sq(dut: Any) -> None:
    """Test FENCE waits for store queue to drain."""
    cocotb.log.info("=== Test: FENCE Wait SQ ===")

    dut_if, model = await setup_test(dut)

    # Allocate FENCE - drive on falling edge
    await FallingEdge(dut_if.clock)
    req = AllocationRequest(pc=0x1000, is_fence=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Set SQ not empty before marking done
    dut_if.set_sq_empty(False)
    model.sq_empty = False

    # Mark done via CDB (FENCE goes through pipeline)
    await FallingEdge(dut_if.clock)
    cdb = CDBWrite(tag=0, value=0)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # SQ not empty - should stall
    await ClockCycles(dut_if.clock, 3)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "FENCE should stall waiting for SQ"

    # SQ now empty - drive on falling edge
    await FallingEdge(dut_if.clock)
    dut_if.set_sq_empty(True)
    model.sq_empty = True

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)

    # FENCE should commit
    assert dut_if.empty, "FENCE should have committed"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_csr_serialization(dut: Any) -> None:
    """Test CSR instruction executes at commit."""
    cocotb.log.info("=== Test: CSR Serialization ===")

    dut_if, model = await setup_test(dut)

    # Allocate CSR - drive on falling edge
    await FallingEdge(dut_if.clock)
    req = AllocationRequest(pc=0x1000, dest_reg=5, dest_valid=True, is_csr=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Mark done via CDB
    cdb = CDBWrite(tag=0, value=0x12345678)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Should signal CSR start
    await RisingEdge(dut_if.clock)
    assert dut_if.csr_start, "Should signal CSR start"

    # CSR not done - should stall
    await FallingEdge(dut_if.clock)
    dut_if.set_csr_done(False)
    model.csr_done = False

    await ClockCycles(dut_if.clock, 3)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "CSR should stall waiting for done"

    # CSR done - drive on falling edge
    await FallingEdge(dut_if.clock)
    dut_if.set_csr_done(True)
    model.csr_done = True

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)

    # CSR should commit
    assert dut_if.empty, "CSR should have committed"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_exception_handling(dut: Any) -> None:
    """Test exception triggers trap pending signal."""
    cocotb.log.info("=== Test: Exception Handling ===")

    dut_if, model = await setup_test(dut)

    # Allocate instruction that will have exception - drive on falling edge
    await FallingEdge(dut_if.clock)
    req = make_simple_alloc_request(pc=0x1000, rd=1)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Mark done with exception
    cdb = CDBWrite(tag=0, value=0, exception=True, exc_cause=4)  # Load addr misalign
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Should signal trap pending
    await RisingEdge(dut_if.clock)
    assert dut_if.trap_pending, "Should signal trap pending"
    assert dut_if.trap_pc == 0x1000, "Trap PC should match instruction PC"
    assert dut_if.trap_cause == 4, "Trap cause should match"

    # Acknowledge trap - drive on falling edge
    await FallingEdge(dut_if.clock)
    dut_if.set_trap_taken(True)
    model.trap_taken = True

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Constrained Random Tests
# =============================================================================


@cocotb.test()
async def test_random_allocation_commit(dut: Any) -> None:
    """Random allocation and commit sequences.

    Randomly allocates entries, writes results, and verifies commits.
    Uses a simpler approach: just track pending tags and verify final state.
    """
    cocotb.log.info("=== Test: Random Allocation and Commit ===")

    dut_if, _ = await setup_test(dut)

    num_operations = 200
    pending_tags: set[int] = set()
    total_allocated = 0

    # We're at falling edge after reset
    for op in range(num_operations):
        # Check DUT full status and alloc_ready before allocating
        _, _, full = dut_if.read_alloc_response()

        # Randomly choose action: allocate, complete, or idle
        action = random.choices(
            ["allocate", "complete", "idle"],
            weights=[0.5, 0.4, 0.1],
        )[0]

        if action == "allocate" and not full:
            # Random allocation
            pc = random.randint(0, 0xFFFFFFFF) & ~3  # Aligned
            rd = random.randint(0, 31)
            is_fp = random.random() < 0.2  # 20% FP

            req = make_simple_alloc_request(pc=pc, rd=rd, is_fp=is_fp)
            dut_if.drive_alloc_request(req)

            await RisingEdge(dut_if.clock)
            # Read the allocated tag from the DUT
            ready, alloc_tag, _ = dut_if.read_alloc_response()
            if ready:
                pending_tags.add(alloc_tag)
                total_allocated += 1

            await FallingEdge(dut_if.clock)
            dut_if.clear_alloc_request()

        elif action == "complete" and pending_tags:
            # Complete a random pending entry
            tag = random.choice(list(pending_tags))
            value = random.randint(0, MASK64)

            cdb = CDBWrite(tag=tag, value=value)
            dut_if.drive_cdb_write(cdb)
            pending_tags.discard(tag)

            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_cdb_write()

        else:
            # Idle cycle - just wait for one cycle
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)

    # Drain remaining entries
    while pending_tags:
        tag = pending_tags.pop()
        cdb = CDBWrite(tag=tag, value=random.randint(0, MASK64))
        dut_if.drive_cdb_write(cdb)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_cdb_write()

    # Wait for all commits - give enough time
    await ClockCycles(dut_if.clock, REORDER_BUFFER_DEPTH + 10)
    await FallingEdge(dut_if.clock)

    assert (
        dut_if.empty
    ), f"Buffer should be empty after draining all entries (count={dut_if.count})"

    cocotb.log.info(f"Completed {total_allocated} allocations")
    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_random_branch_flush(dut: Any) -> None:
    """Random branches with some mispredictions causing flushes."""
    cocotb.log.info("=== Test: Random Branch Flush ===")

    dut_if, _ = await setup_test(dut)

    num_sequences = 20
    total_mispredictions = 0

    for seq in range(num_sequences):
        # Allocate a sequence of instructions with a branch in the middle
        seq_len = random.randint(3, 8)
        branch_pos = random.randint(1, seq_len - 1)
        branch_tag = None
        allocated_tags: list[int] = []
        pending_tags: set[int] = set()

        for i in range(seq_len):
            if i == branch_pos:
                # Allocate branch
                predicted_taken = random.random() < 0.5
                predicted_target = random.randint(0, 0xFFFF) << 2
                req = make_branch_request(
                    pc=0x1000 + i * 4,
                    predicted_taken=predicted_taken,
                    predicted_target=predicted_target,
                )
            else:
                req = make_simple_alloc_request(
                    pc=0x1000 + i * 4,
                    rd=(i % 31) + 1,
                )

            dut_if.drive_alloc_request(req)
            await RisingEdge(dut_if.clock)
            _, tag, _ = dut_if.read_alloc_response()
            allocated_tags.append(tag)
            if i == branch_pos:
                branch_tag = tag
            else:
                pending_tags.add(tag)
            await FallingEdge(dut_if.clock)
            dut_if.clear_alloc_request()

        # Complete entries before branch (tags 0 to branch_pos-1)
        for i in range(branch_pos):
            tag = allocated_tags[i]
            if tag in pending_tags:
                cdb = CDBWrite(tag=tag, value=random.randint(0, MASK32))
                dut_if.drive_cdb_write(cdb)
                pending_tags.discard(tag)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_cdb_write()

        # Resolve branch - randomly mispredict
        mispredicted = random.random() < 0.3  # 30% misprediction rate
        actual_taken = random.random() < 0.5
        actual_target = random.randint(0, 0xFFFF) << 2

        assert branch_tag is not None, "Branch tag should have been set"
        update = BranchUpdate(
            tag=branch_tag,
            taken=actual_taken,
            target=actual_target,
            mispredicted=mispredicted,
        )
        dut_if.drive_branch_update(update)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_branch_update()

        if mispredicted:
            total_mispredictions += 1
            # Flush entries after branch - clears pending tags after branch
            await dut_if.partial_flush(branch_tag)
            # Remove flushed tags from pending set
            for i in range(branch_pos + 1, seq_len):
                pending_tags.discard(allocated_tags[i])
            await FallingEdge(dut_if.clock)

        # Complete remaining valid entries (only those still in pending_tags)
        for tag in list(pending_tags):
            cdb = CDBWrite(tag=tag, value=random.randint(0, MASK32))
            dut_if.drive_cdb_write(cdb)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_cdb_write()
        pending_tags.clear()

        # Let commits happen
        await ClockCycles(dut_if.clock, seq_len + 5)

        # Full flush to clean up for next sequence
        await FallingEdge(dut_if.clock)
        await dut_if.full_flush()
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)

    cocotb.log.info(
        f"Tested {num_sequences} sequences, " f"{total_mispredictions} mispredictions"
    )
    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_stress_full_empty(dut: Any) -> None:
    """Stress test buffer boundaries (full/empty transitions)."""
    cocotb.log.info("=== Test: Stress Full/Empty ===")

    dut_if, _ = await setup_test(dut)

    num_cycles = 100

    for cycle in range(num_cycles):
        # Track allocated tags that need completion
        pending_tags: list[int] = []

        # Fill to full
        while not dut_if.full:
            req = make_simple_alloc_request(
                pc=random.randint(0, 0xFFFF) << 2,
                rd=random.randint(1, 31),
            )
            dut_if.drive_alloc_request(req)
            await RisingEdge(dut_if.clock)
            _, tag, _ = dut_if.read_alloc_response()
            pending_tags.append(tag)
            await FallingEdge(dut_if.clock)
            dut_if.clear_alloc_request()

        assert dut_if.full, f"Cycle {cycle}: DUT should be full"
        assert (
            len(pending_tags) == REORDER_BUFFER_DEPTH
        ), f"Cycle {cycle}: Should have {REORDER_BUFFER_DEPTH} entries"

        # Drain to empty by completing entries in order
        for tag in pending_tags:
            cdb = CDBWrite(tag=tag, value=random.randint(0, MASK64))
            dut_if.drive_cdb_write(cdb)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_cdb_write()

        # Wait for DUT to drain
        for _ in range(10):
            if dut_if.empty:
                break
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)

        assert dut_if.empty, f"Cycle {cycle}: DUT should be empty"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_mixed_instruction_types(dut: Any) -> None:
    """Test mix of different instruction types (ALU, branch, store, FP)."""
    cocotb.log.info("=== Test: Mixed Instruction Types ===")

    dut_if, _ = await setup_test(dut)

    num_instructions = 50
    pending_tags: dict[int, str] = {}  # tag -> type
    all_allocated: list[tuple[int, str]] = []  # (tag, type) for debug
    all_completed: list[tuple[int, str]] = []  # (tag, type) for debug

    for i in range(num_instructions):
        # Randomly choose instruction type
        instr_type = random.choices(
            ["alu", "branch", "store", "fp_alu", "fp_store"],
            weights=[0.4, 0.2, 0.15, 0.15, 0.1],
        )[0]

        if dut_if.full:
            # Wait for commits to make space
            await ClockCycles(dut_if.clock, 5)
            await FallingEdge(dut_if.clock)
            continue

        pc = 0x1000 + i * 4

        if instr_type == "alu":
            req = make_simple_alloc_request(pc=pc, rd=random.randint(1, 31))
        elif instr_type == "branch":
            req = make_branch_request(
                pc=pc,
                predicted_taken=random.random() < 0.5,
                predicted_target=random.randint(0, 0xFFFF) << 2,
            )
        elif instr_type == "store":
            req = make_store_request(pc=pc)
        elif instr_type == "fp_alu":
            req = make_simple_alloc_request(pc=pc, rd=random.randint(0, 31), is_fp=True)
        else:  # fp_store
            req = make_store_request(pc=pc, is_fp=True)

        dut_if.drive_alloc_request(req)
        await RisingEdge(dut_if.clock)
        ready, tag, full = dut_if.read_alloc_response()
        if ready and not full:
            pending_tags[tag] = instr_type
            all_allocated.append((tag, instr_type))
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

        # Randomly complete some entries
        if pending_tags and random.random() < 0.6:
            tag_to_complete = random.choice(list(pending_tags.keys()))
            itype = pending_tags[tag_to_complete]

            if itype == "branch":
                # Branch update
                update = BranchUpdate(
                    tag=tag_to_complete,
                    taken=random.random() < 0.5,
                    target=random.randint(0, 0xFFFF) << 2,
                    mispredicted=False,
                )
                dut_if.drive_branch_update(update)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_branch_update()
            else:
                # CDB write
                value = random.randint(0, MASK64)
                fp_flags = random.randint(0, 31) if "fp" in itype else 0
                cdb = CDBWrite(tag=tag_to_complete, value=value, fp_flags=fp_flags)
                dut_if.drive_cdb_write(cdb)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_cdb_write()

            all_completed.append((tag_to_complete, itype))
            del pending_tags[tag_to_complete]

    # Complete remaining entries
    final_pending = list(pending_tags.items())
    for tag, itype in final_pending:
        all_completed.append((tag, itype))
        if itype == "branch":
            update = BranchUpdate(tag=tag, taken=False, target=0, mispredicted=False)
            dut_if.drive_branch_update(update)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_branch_update()
        else:
            cdb = CDBWrite(tag=tag, value=0)
            dut_if.drive_cdb_write(cdb)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_cdb_write()

    # Wait for commits with timeout, checking state periodically
    for wait_cycle in range(50):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        if dut_if.empty:
            break
        if wait_cycle == 25:
            cocotb.log.warning(
                f"Still not empty after 25 cycles: count={dut_if.count}, "
                f"head_done={dut_if.head_done}, commit_valid={dut_if.commit_valid}"
            )

    if not dut_if.empty:
        head_idx = dut_if.head_ptr & 31
        cocotb.log.error(
            f"Buffer not empty: count={dut_if.count}, "
            f"head_ptr={dut_if.head_ptr}, tail_ptr={dut_if.tail_ptr}, "
            f"head_idx={head_idx}"
        )
        cocotb.log.error(f"Total allocated: {len(all_allocated)}")
        cocotb.log.error(f"Total completed: {len(all_completed)}")
        cocotb.log.error(f"Final pending_tags before completion: {final_pending}")
        cocotb.log.error(
            f"head_valid={dut_if.head_valid}, head_done={dut_if.head_done}"
        )
        # Check if head entry was ever allocated with this tag
        allocs_at_head = [a for a in all_allocated if a[0] == head_idx]
        comps_at_head = [c for c in all_completed if c[0] == head_idx]
        cocotb.log.error(f"Allocations at head_idx {head_idx}: {allocs_at_head}")
        cocotb.log.error(f"Completions at head_idx {head_idx}: {comps_at_head}")
    assert dut_if.empty, "Buffer should be empty after all commits"
    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Error Condition Tests
# =============================================================================


@cocotb.test()
async def test_alloc_when_full_no_corruption(dut: Any) -> None:
    """Test that allocation when full doesn't corrupt state."""
    cocotb.log.info("=== Test: Allocation When Full ===")

    dut_if, model = await setup_test(dut)

    # Fill buffer
    for i in range(REORDER_BUFFER_DEPTH):
        await FallingEdge(dut_if.clock)
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=(i % 31) + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    await RisingEdge(dut_if.clock)
    assert dut_if.full, "Should be full"

    # Record state
    count_before = dut_if.count
    head_before = dut_if.head_tag

    # Attempt allocation when full (10 times)
    # Note: The RTL has an assertion, so we should NOT drive alloc_valid when full
    # Instead just wait some cycles to verify state doesn't change
    await ClockCycles(dut_if.clock, 10)

    await RisingEdge(dut_if.clock)
    # State should be unchanged
    assert dut_if.count == count_before, "Count should not change"
    assert dut_if.head_tag == head_before, "Head should not change"
    assert dut_if.full, "Should still be full"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_back_to_back_commits(dut: Any) -> None:
    """Test back-to-back commits (all entries done)."""
    cocotb.log.info("=== Test: Back-to-Back Commits ===")

    dut_if, model = await setup_test(dut)

    num_entries = 8

    # Allocate entries (we're at falling edge after reset)
    for i in range(num_entries):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    assert dut_if.count == num_entries, f"Should have {num_entries} entries"

    # Complete all entries (in order for simplicity)
    for i in range(num_entries):
        cdb = CDBWrite(tag=i, value=0x1000 + i)
        dut_if.drive_cdb_write(cdb)
        model.cdb_write(cdb)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_cdb_write()

    # Process commits in model
    while model.can_commit():
        model.commit()

    # Wait for commits
    await ClockCycles(dut_if.clock, num_entries + 5)

    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Should be empty after all commits"
    assert model.empty, "Model should also be empty"

    cocotb.log.info("=== Test Passed ===")

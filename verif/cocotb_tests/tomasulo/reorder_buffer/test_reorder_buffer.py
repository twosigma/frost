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

"""Reorder buffer unit tests.

The tests drive the standalone reorder_buffer module through
ReorderBufferInterface and, where a reference is useful, compare against
ReorderBufferModel. They are grouped by the section banners below: directed
tests (allocation in one and two lanes, CDB completion, in-order and 2-wide
commit, branches and checkpoints, the serializing classes FENCE, FENCE.I,
SFENCE.VMA, CSR, WFI and MRET, flushes, and allocation-time legality faults),
constrained random tests, error-condition tests, coverage-gap tests,
non-interference tests, and atomics.

Inputs are driven at a falling edge and take effect on the next rising edge.
Under Verilator a registered output (count, empty, head_done) is not visible
until the falling edge after that rising edge, while combinational outputs
(alloc_ready, alloc_tag, and the o_commit_comb mirror that read_commit
returns) can be read right after the edge. reset_dut returns at a falling
edge, so a test can drive its first request immediately.

Usage:
    cd frost/tests
    make clean
    ./test_run_cocotb.py reorder_buffer
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer
from collections import deque
from typing import Any
import random

from config import MASK_XLEN

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
RS_INT = 0
RS_MEM = 2
RS_FP = 3
PRIV_U = 0
PRIV_M = 3
EXC_ILLEGAL_INSTR = 2
CSR_MSTATUS = 0x300
CSR_SSTATUS = 0x100
CSR_SATP = 0x180
CSR_MIE = 0x304


def log_random_seed() -> int:
    """Generate, log, and apply a random seed for reproducibility."""
    seed = random.getrandbits(32)
    random.seed(seed)
    cocotb.log.info(f"Random seed: {seed}")
    return seed


def sample_flush_phase(
    dut_if: ReorderBufferInterface,
) -> tuple[bool, bool, bool, bool]:
    """Snapshot the cycle-varying retirement and flush outputs."""
    return (
        dut_if.empty,
        dut_if.fence_class_flush_event,
        dut_if.translation_csr_commit_shadow,
        dut_if.fence_i_flush,
    )


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

    cocotb.start_soon(Clock(dut_if.clock, CLOCK_PERIOD_NS, unit="ns").start())

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
    branch_target: int | None = None,
    is_jal: bool = False,
    is_jalr: bool = False,
    link_addr: int = 0,
    is_call: bool = False,
    is_return: bool = False,
) -> AllocationRequest:
    """Create allocation request for branch/jump instruction."""
    actual_target = (
        predicted_target if (branch_target is None and is_jal) else (branch_target or 0)
    )
    return AllocationRequest(
        pc=pc,
        dest_rf=0,
        dest_reg=1 if (is_jal or is_jalr) else 0,  # rd=x1 for JAL/JALR
        dest_valid=is_jal or is_jalr,
        is_branch=True,
        predicted_taken=predicted_taken,
        predicted_target=predicted_target,
        branch_target=actual_target,
        is_call=is_call,
        is_return=is_return,
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


async def drive_dual_alloc(
    dut_if: ReorderBufferInterface,
    req_1: AllocationRequest,
    req_2: AllocationRequest,
) -> tuple[tuple[bool, int, bool], tuple[bool, int, bool]]:
    """Drive a slot-1/slot-2 allocation bundle and return both responses."""
    dut_if.drive_alloc_request(req_1)
    dut_if.drive_alloc_request_2(req_2)
    await RisingEdge(dut_if.clock)
    resp_1 = dut_if.read_alloc_response()
    resp_2 = dut_if.read_alloc_response_2()
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_requests()
    return resp_1, resp_2


async def drive_single_alloc(
    dut_if: ReorderBufferInterface,
    req: AllocationRequest,
) -> int:
    """Drive one accepted allocation and return its ROB tag."""
    dut_if.drive_alloc_request(req)
    await RisingEdge(dut_if.clock)
    ready, tag, full = dut_if.read_alloc_response()
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    assert ready and not full, "Directed allocation was unexpectedly rejected"
    return tag


# =============================================================================
# Directed Tests
# =============================================================================


@cocotb.test()
async def test_basic_allocation(dut: Any) -> None:
    """Allocate one entry, complete it over the CDB, and check the commit.

    The sampling convention from the module docstring shows up here:
    alloc_ready and alloc_tag are read right after the rising edge, count,
    empty and head_done at the following falling edge.
    """
    cocotb.log.info("=== Test: Basic Allocation and Commit ===")

    dut_if, model = await setup_test(dut)

    # Start monitors
    commit_queue: deque[ExpectedCommit] = deque()
    commit_mon = CommitMonitor(dut, commit_queue)
    status_mon = StatusMonitor(dut)
    cocotb.start_soon(commit_mon.run())
    cocotb.start_soon(status_mon.run())

    # reset_dut returns at a falling edge, so the request can be driven now.
    req = make_simple_alloc_request(pc=0x1000, rd=5)
    dut_if.drive_alloc_request(req)
    model.allocate(req)

    await RisingEdge(dut_if.clock)
    # Combinational outputs are valid now.
    ready, tag, full = dut_if.read_alloc_response()
    assert ready, "alloc_ready should be True"
    assert tag == 0, "First allocation should get tag 0"

    # Registered outputs are read at the falling edge.
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    assert not dut_if.empty, "Should not be empty after allocation"
    assert dut_if.count == 1, "Count should be 1"
    assert dut_if.head_valid, "Head should be valid"
    assert not dut_if.head_done, "Head should not be done yet"

    cdb = CDBWrite(tag=0, value=0xDEADBEEF)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)

    # Queue the expected commit before the edge: the head CDB bypass lets the
    # entry commit on the same rising edge that registers done.
    expected = model.commit()
    commit_queue.append(expected)

    await RisingEdge(dut_if.clock)

    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Should be empty after commit"
    assert dut_if.count == 0, "Count should be 0"  # type: ignore[unreachable]
    # Wait a few cycles and check monitors
    await ClockCycles(dut_if.clock, 5)
    commit_mon.check_complete()
    status_mon.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_allocation_full(dut: Any) -> None:
    """Fill the buffer and check the full signal and alloc_ready."""
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

    ready, _, full = dut_if.read_alloc_response()
    assert not ready, "alloc_ready should be false when full"
    assert full, "full signal should be true"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_slot2_dual_allocation_adjacent_tags(dut: Any) -> None:
    """Slot-1/slot-2 allocation writes adjacent entries and advances by 2."""
    cocotb.log.info("=== Test: Slot-2 Dual Allocation Adjacent Tags ===")

    dut_if, _ = await setup_test(dut)

    req_1 = make_simple_alloc_request(pc=0x1000, rd=5)
    req_2 = make_simple_alloc_request(pc=0x1004, rd=6)
    resp_1, resp_2 = await drive_dual_alloc(dut_if, req_1, req_2)

    ready_1, tag_1, full_1 = resp_1
    ready_2, tag_2, full_2 = resp_2
    assert ready_1 and not full_1, "Slot 1 should be ready"
    assert ready_2 and not full_2, "Slot 2 should be ready"
    assert tag_1 == 0, f"Slot 1 should allocate tag 0, got {tag_1}"
    assert tag_2 == 1, f"Slot 2 should allocate tag 1, got {tag_2}"
    assert (
        dut_if.count == 2
    ), f"Dual allocation should leave count=2, got {dut_if.count}"
    assert dut_if.head_tag == 0
    assert dut_if.tail_ptr & (REORDER_BUFFER_DEPTH - 1) == 2

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_head_wait_fast_perf_classes_dual_lane(dut: Any) -> None:
    """Keep fast INT/load perf classes cycle-exact across both alloc lanes."""
    cocotb.log.info("=== Test: Head-Wait Fast Perf Classes Dual Lane ===")

    dut_if, _ = await setup_test(dut)
    wait_partitions = (
        "head_wait_int",
        "head_wait_branch",
        "head_wait_mul",
        "head_wait_mem_load",
        "head_wait_mem_store",
        "head_wait_mem_amo",
        "head_wait_fp",
        "head_wait_fmul",
        "head_wait_fdiv",
    )

    # Positive classes: INT enters through slot 1 and MEM-load through slot 2.
    int_req = AllocationRequest(pc=0x1100, rs_type=RS_INT, dest_reg=3, dest_valid=True)
    load_req = AllocationRequest(pc=0x1104, rs_type=RS_MEM, dest_reg=4, dest_valid=True)
    (int_resp, load_resp) = await drive_dual_alloc(dut_if, int_req, load_req)
    int_ready, int_tag, _ = int_resp
    load_ready, _, _ = load_resp
    assert int_ready and load_ready

    events = dut_if.read_perf_events()
    assert events["head_wait_total"]
    assert events["head_wait_int"]
    assert sum(events[name] for name in wait_partitions) == 1

    # The same-cycle head CDB bypass suppresses the wait event before the
    # committing edge; the fast class must not add a register of latency.
    # Leave the staged-LVT drain window before injecting the synthetic result.
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=int_tag, value=0x1234))
    await Timer(1, unit="ns")
    events = dut_if.read_perf_events()
    assert not events["head_wait_total"]
    assert not any(events[name] for name in wait_partitions)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    events = dut_if.read_perf_events()
    assert events["head_wait_total"]
    assert events["head_wait_mem_load"]
    assert sum(events[name] for name in wait_partitions) == 1

    # Full-flush suppression is combinational too, and creates an empty ROB
    # for the priority-exclusion half of the test.
    dut_if.drive_full_flush()
    await Timer(1, unit="ns")
    events = dut_if.read_perf_events()
    assert not events["head_wait_total"]
    assert not events["head_wait_mem_load"]
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_full_flush()
    assert dut_if.empty

    # The stored bits are final priority-resolved classes, not raw RS types:
    # a branch routed through RS_INT is Branch, and a store routed through
    # RS_MEM is MemStore. This also exercises both alloc lanes with exclusions.
    branch_req = AllocationRequest(pc=0x1200, rs_type=RS_INT, is_branch=True)
    store_req = AllocationRequest(pc=0x1204, rs_type=RS_MEM, is_store=True)
    (branch_resp, store_resp) = await drive_dual_alloc(dut_if, branch_req, store_req)
    branch_ready, branch_tag, _ = branch_resp
    store_ready, _, _ = store_resp
    assert branch_ready and store_ready

    events = dut_if.read_perf_events()
    assert events["head_wait_branch"]
    assert not events["head_wait_int"]
    assert sum(events[name] for name in wait_partitions) == 1

    dut_if.drive_branch_update(BranchUpdate(tag=branch_tag, taken=False, target=0))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    events = dut_if.read_perf_events()
    assert events["head_wait_mem_store"]
    assert not events["head_wait_mem_load"]
    assert sum(events[name] for name in wait_partitions) == 1

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_slot2_allocation_blocked_by_full_for_2(dut: Any) -> None:
    """With one free ROB entry, slot 1 can allocate but slot 2 is blocked."""
    cocotb.log.info("=== Test: Slot-2 Allocation Blocked by full_for_2 ===")

    dut_if, _ = await setup_test(dut)

    for i in range(REORDER_BUFFER_DEPTH - 1):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=(i % 31) + 1)
        dut_if.drive_alloc_request(req)
        await RisingEdge(dut_if.clock)
        ready, tag, _ = dut_if.read_alloc_response()
        assert ready, f"Allocation {i} should be ready"
        assert tag == i, f"Allocation {i} expected tag {i}, got {tag}"
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    assert dut_if.count == REORDER_BUFFER_DEPTH - 1
    assert dut_if.full_for_2, "ROB should report no room for a 2-wide bundle"
    assert not dut_if.full, "ROB should still have room for one slot"

    ready_2, _, full_2 = dut_if.read_alloc_response_2()
    assert not ready_2, "Slot 2 should report not-ready when full_for_2 is set"
    assert full_2, "Slot-2 full flag should be set"

    req_1 = make_simple_alloc_request(pc=0x2000, rd=3)
    dut_if.drive_alloc_request(req_1)
    await RisingEdge(dut_if.clock)
    ready_1, tag_1, full_1 = dut_if.read_alloc_response()
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    assert ready_1 and not full_1, "Slot 1 should still allocate the last entry"
    assert tag_1 == REORDER_BUFFER_DEPTH - 1
    assert dut_if.count == REORDER_BUFFER_DEPTH
    assert dut_if.full

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_widen_commit_emits_slot2_commit(dut: Any) -> None:
    """Two completed ordinary head entries should retire together."""
    cocotb.log.info("=== Test: Widen Commit Emits Slot 2 Commit ===")

    dut_if, _ = await setup_test(dut)

    req_1 = make_simple_alloc_request(pc=0x1000, rd=5)
    req_2 = make_simple_alloc_request(pc=0x1004, rd=6)
    (_, tag_1, _), (_, tag_2, _) = await drive_dual_alloc(dut_if, req_1, req_2)

    dut_if.drive_cdb_write(CDBWrite(tag=tag_2, value=0x2222))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()
    assert dut_if.count == 2, "Younger done entry should not commit before head"

    dut_if.drive_cdb_write(CDBWrite(tag=tag_1, value=0x1111))
    await RisingEdge(dut_if.clock)
    commit_1 = dut_if.read_commit()
    commit_2 = dut_if.read_commit_2()
    assert commit_1["valid"], "Slot 1 commit should fire"
    assert commit_2["valid"], "Slot 2 commit should fire"
    assert dut_if.commit_2_valid_raw, "Raw slot-2 commit valid should assert"
    assert commit_1["tag"] == tag_1
    assert commit_1["value"] == 0x1111
    assert commit_2["tag"] == tag_2
    assert commit_2["value"] == 0x2222
    assert commit_2["dest_valid"]
    assert commit_2["dest_reg"] == 6
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert dut_if.empty, "Both entries should retire in one cycle"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_widen_commit_ok_blocks_slot2_commit(dut: Any) -> None:
    """Back-pressure can retire slot 1 while holding slot 2 for the next cycle."""
    cocotb.log.info("=== Test: Widen Commit OK Blocks Slot 2 Commit ===")

    dut_if, _ = await setup_test(dut)

    req_1 = make_simple_alloc_request(pc=0x1000, rd=5)
    req_2 = make_simple_alloc_request(pc=0x1004, rd=6)
    (_, tag_1, _), (_, tag_2, _) = await drive_dual_alloc(dut_if, req_1, req_2)

    dut_if.drive_cdb_write(CDBWrite(tag=tag_2, value=0xBBBB))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    dut_if.set_widen_commit_ok(False)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_1, value=0xAAAA))
    await RisingEdge(dut_if.clock)
    commit_1 = dut_if.read_commit()
    commit_2 = dut_if.read_commit_2()
    assert commit_1["valid"], "Slot 1 should still commit"
    assert commit_1["tag"] == tag_1
    assert not commit_2["valid"], "Slot 2 should be held by widen back-pressure"
    assert not dut_if.commit_2_valid_raw
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()
    dut_if.set_widen_commit_ok(True)

    assert dut_if.count == 1
    assert dut_if.head_tag == tag_2

    await RisingEdge(dut_if.clock)
    commit = dut_if.read_commit()
    assert commit["valid"], "Held slot-2 entry should commit next"
    assert commit["tag"] == tag_2
    assert commit["value"] == 0xBBBB
    await FallingEdge(dut_if.clock)

    assert dut_if.empty

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_slot2_branch_checkpoint_metadata_and_no_widen_commit(dut: Any) -> None:
    """Slot-2 correct branch widen-commits; mispredicted still blocks.

    A correctly-predicted branch at head+1 retires as commit_2 with real
    branch/checkpoint metadata; a mispredicted branch at head+1 must still
    block widen commit and retire 1-wide at the head.
    """
    cocotb.log.info("=== Test: Slot-2 Branch Widen Commit / Metadata ===")

    dut_if, _ = await setup_test(dut)

    # --- Phase 1: correctly-predicted branch at head+1 dual-commits ---
    req_1 = make_simple_alloc_request(pc=0x1000, rd=5)
    req_2 = make_branch_request(
        pc=0x1004,
        predicted_taken=True,
        predicted_target=0x2400,
    )
    dut_if.drive_checkpoint(6)
    (_, tag_1, _), (_, tag_2, _) = await drive_dual_alloc(dut_if, req_1, req_2)
    dut_if.clear_checkpoint()

    update = BranchUpdate(tag=tag_2, taken=True, target=0x2400, mispredicted=False)
    dut_if.drive_branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    dut_if.drive_cdb_write(CDBWrite(tag=tag_1, value=0x1234))
    await RisingEdge(dut_if.clock)
    commit_1 = dut_if.read_commit()
    commit_2 = dut_if.read_commit_2()
    assert commit_1["valid"] and commit_1["tag"] == tag_1
    assert commit_2["valid"], "Correct branch at head+1 should widen commit"
    assert commit_2["tag"] == tag_2
    assert commit_2["is_branch"]
    assert commit_2["has_checkpoint"]
    assert commit_2["checkpoint_id"] == 6
    assert commit_2["branch_taken"]
    assert commit_2["branch_target"] == 0x2400
    assert not commit_2["misprediction"]
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert dut_if.empty, "Both slots should have retired together"

    # --- Phase 2: mispredicted branch at head+1 still blocks widen commit ---
    req_3 = make_simple_alloc_request(pc=0x2000, rd=6)
    req_4 = make_branch_request(
        pc=0x2004,
        predicted_taken=True,
        predicted_target=0x3400,
    )
    dut_if.drive_checkpoint(3)
    (_, tag_3, _), (_, tag_4, _) = await drive_dual_alloc(dut_if, req_3, req_4)
    dut_if.clear_checkpoint()

    update = BranchUpdate(tag=tag_4, taken=False, target=0x3400, mispredicted=True)
    dut_if.drive_branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    dut_if.drive_cdb_write(CDBWrite(tag=tag_3, value=0x5678))
    await RisingEdge(dut_if.clock)
    commit_1 = dut_if.read_commit()
    commit_2 = dut_if.read_commit_2()
    assert commit_1["valid"] and commit_1["tag"] == tag_3
    assert not commit_2[
        "valid"
    ], "Mispredicted branch at head+1 must block widen commit"
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert dut_if.count == 1
    assert dut_if.head_tag == tag_4

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_head_serial_instruction_blocks_widen_commit(dut: Any) -> None:
    """Serializing slot 1 can retire while a done slot 2 remains queued."""
    cocotb.log.info("=== Test: Head Serial Instruction Blocks Widen Commit ===")

    dut_if, _ = await setup_test(dut)

    req_1 = AllocationRequest(pc=0x1000, is_fence=True)
    req_2 = make_simple_alloc_request(pc=0x1004, rd=7)
    (_, tag_1, _), (_, tag_2, _) = await drive_dual_alloc(dut_if, req_1, req_2)

    dut_if.drive_cdb_write(CDBWrite(tag=tag_2, value=0x7777))
    await RisingEdge(dut_if.clock)
    commit_1 = dut_if.read_commit()
    commit_2 = dut_if.read_commit_2()
    assert commit_1["valid"], "FENCE should commit with SQ empty"
    assert commit_1["tag"] == tag_1
    assert commit_1["is_fence"]
    assert not commit_2["valid"], "Serial head should block widen commit"
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert dut_if.count == 1
    assert dut_if.head_tag == tag_2

    await RisingEdge(dut_if.clock)
    commit = dut_if.read_commit()
    assert commit["valid"]
    assert commit["tag"] == tag_2
    assert commit["value"] == 0x7777
    await FallingEdge(dut_if.clock)

    assert dut_if.empty

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_write(dut: Any) -> None:
    """Check that a CDB write marks the entry done with its value.

    Four entries are completed out of order and each is checked for done and
    value right after its CDB write, while it is still behind the head. The
    head entry commits as soon as it is marked done, so it is completed last.
    """
    cocotb.log.info("=== Test: CDB Write ===")

    dut_if, model = await setup_test(dut)

    tags = []
    for i in range(4):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        tag = model.allocate(req)
        tags.append(tag)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    # Entry 2 is not at the head: it becomes done but does not commit.
    cdb = CDBWrite(tag=2, value=0xAAAA)
    dut_if.drive_cdb_write(cdb)
    dut_if.set_read_tag(2)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    done = dut_if.read_entry_done()
    value = dut_if.read_entry_value()
    assert done, "Entry 2 should be done after CDB write"
    assert value == 0xAAAA, f"Entry 2 value mismatch: {value:x}"

    dut_if.clear_cdb_write()

    cdb = CDBWrite(tag=3, value=0xBBBB)
    dut_if.drive_cdb_write(cdb)
    dut_if.set_read_tag(3)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    done = dut_if.read_entry_done()
    value = dut_if.read_entry_value()
    assert done, "Entry 3 should be done after CDB write"
    assert value == 0xBBBB, f"Entry 3 value mismatch: {value:x}"

    dut_if.clear_cdb_write()

    cdb = CDBWrite(tag=1, value=0xCCCC)
    dut_if.drive_cdb_write(cdb)
    dut_if.set_read_tag(1)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    done = dut_if.read_entry_done()
    value = dut_if.read_entry_value()
    assert done, "Entry 1 should be done after CDB write"
    assert value == 0xCCCC, f"Entry 1 value mismatch: {value:x}"

    dut_if.clear_cdb_write()

    assert dut_if.count == 4, "All 4 entries should still be in buffer"

    # Completing the head releases all four commits.
    cdb = CDBWrite(tag=0, value=0xDDDD)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 8)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Buffer should be empty after all commits"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_store_complete_marks_done(dut: Any) -> None:
    """Plain stores mark the ROB done directly without going through the CDB."""
    cocotb.log.info("=== Test: Direct Store Completion ===")

    dut_if, model = await setup_test(dut)

    req = make_store_request(pc=0x1800)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    assert dut_if.count == 1, "Should have 1 entry"
    assert (
        int(dut.o_head_done.value) == 0
    ), "Store should not be done immediately after allocation"

    dut_if.drive_store_complete(0)
    model.store_complete(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_store_complete()

    assert (
        int(dut.o_head_done.value) == 1
    ), "Direct store completion should mark the head entry done"

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    assert int(dut.o_empty.value) == 1, "Store should commit once marked done"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_in_order_commit(dut: Any) -> None:
    """Complete three entries out of order and check that none commits early."""
    cocotb.log.info("=== Test: In-Order Commit ===")

    dut_if, model = await setup_test(dut)

    for i in range(3):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    assert dut_if.count == 3, "Should have 3 entries"

    cdb = CDBWrite(tag=2, value=0x3333)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert dut_if.count == 3, "No commit yet - entry 0 not done"

    cdb = CDBWrite(tag=1, value=0x2222)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert dut_if.count == 3, "Still no commit - entry 0 not done"

    cdb = CDBWrite(tag=0, value=0x1111)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)

    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Buffer should be empty after all commits"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_resolution(dut: Any) -> None:
    """Resolve a branch as predicted and check that it commits."""
    cocotb.log.info("=== Test: Branch Resolution ===")

    dut_if, model = await setup_test(dut)

    # Branch predicted taken to 0x2000.
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

    # Resolve as predicted: taken to 0x2000.
    update = BranchUpdate(tag=0, taken=True, target=0x2000, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    await ClockCycles(dut_if.clock, 3)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Branch should have committed"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_misprediction(dut: Any) -> None:
    """Resolve a predicted-not-taken branch as taken and check the redirect."""
    cocotb.log.info("=== Test: Branch Misprediction ===")

    dut_if, model = await setup_test(dut)

    # Branch predicted not taken.
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

    # Resolve as taken to 0x2000: a misprediction.
    update = BranchUpdate(tag=0, taken=True, target=0x2000, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    if model.can_commit():
        expected = model.commit()
        assert expected.misprediction, "Should be mispredicted"
        assert expected.redirect_pc == 0x2000, "Redirect should be to taken target"

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after branch commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_misprediction_not_taken(dut: Any) -> None:
    """Resolve a predicted-taken branch as not taken.

    The redirect_pc must be the fall-through address pc+4.
    """
    cocotb.log.info("=== Test: Branch Misprediction Not-Taken ===")

    dut_if, model = await setup_test(dut)

    # Branch predicted taken to 0x2000.
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

    # Resolve as not taken: a misprediction.
    update = BranchUpdate(tag=0, taken=False, target=0, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    if model.can_commit():
        expected = model.commit()
        assert expected.misprediction, "Should be mispredicted"
        assert (
            expected.redirect_pc == branch_pc + 4
        ), f"Redirect should be pc+4={branch_pc + 4:#x}, got {expected.redirect_pc:#x}"

    # Poll for the DUT commit; it arrives within a few cycles.
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
async def test_xlen_wide_branch_metadata(dut: Any) -> None:
    """Preserve XLEN-wide PCs and branch targets through update and commit."""
    cocotb.log.info("=== Test: XLEN-Wide Branch Metadata ===")

    dut_if, model = await setup_test(dut)
    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    branch_pc = 0x1234_5678_8000_1000
    predicted_target = 0x2345_6789_8000_2000
    resolved_target = 0x3456_789A_8000_3000
    req = make_branch_request(
        pc=branch_pc,
        predicted_taken=False,
        predicted_target=predicted_target,
    )
    dut_if.drive_alloc_request(req)
    tag = model.allocate(req)
    assert tag is not None

    entry = model.entries[tag]
    assert entry.pc == (branch_pc & MASK_XLEN)
    assert entry.predicted_target == (predicted_target & MASK_XLEN)
    assert entry.pc >> 32, "RV64 model discarded the PC upper half"
    assert (
        entry.predicted_target >> 32
    ), "RV64 model discarded the predicted-target upper half"

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    update = BranchUpdate(
        tag=tag,
        taken=True,
        target=resolved_target,
        mispredicted=True,
    )
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    assert entry.branch_target == (resolved_target & MASK_XLEN)

    expected = model.commit()
    expected_commits.append(expected)
    assert expected.pc == (branch_pc & MASK_XLEN)
    assert expected.branch_target == (resolved_target & MASK_XLEN)
    assert expected.redirect_pc == (resolved_target & MASK_XLEN)
    assert (
        expected.branch_target >> 32
    ), "RV64 model discarded the resolved-target upper half"
    assert expected.redirect_pc >> 32, "RV64 model discarded the redirect-PC upper half"

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Buffer should be empty after branch commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_commit_struct_with_monitor(dut: Any) -> None:
    """Check every commit field for a predicted-taken branch resolved not taken.

    The CommitMonitor compares the whole commit struct against an explicit
    ExpectedCommit, so a regression in a field no directed assert names is
    still caught.
    """
    cocotb.log.info("=== Test: Commit Struct with Monitor ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    # Branch predicted taken to 0x2000.
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

    # Queue the expected commit before the branch update: the entry can
    # commit on the edge that resolves it.
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
        predicted_taken=True,
        branch_taken=False,
        branch_target=0,
        is_branch=True,
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

    # Resolve as not taken: a misprediction.
    update = BranchUpdate(tag=tag, taken=False, target=0, mispredicted=True)
    dut_if.drive_branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_mret_commit_struct_with_monitor(dut: Any) -> None:
    """Check every commit field for an MRET, including redirect_pc = mepc.

    MRET serializes through a handshake with the trap unit.
    """
    cocotb.log.info("=== Test: MRET Commit Struct with Monitor ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    mret_pc = 0x80000100
    req = AllocationRequest(pc=mret_pc, is_mret=True)
    dut_if.drive_alloc_request(req)
    tag = model.allocate(req)
    assert tag is not None, "Allocation should succeed"
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    await RisingEdge(dut_if.clock)
    assert dut_if.mret_start, "mret_start should be asserted"

    mepc_value = 0x80001234
    dut_if.set_mepc(mepc_value)
    dut_if.set_mret_done(True)

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

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    dut_if.set_mret_done(False)

    assert dut_if.empty, "Buffer should be empty after commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fence_i_flush_pulse(dut: Any) -> None:
    """Check that FENCE.I commits and then pulses o_fence_i_flush for one cycle.

    FENCE.I waits for the SQ to drain and for the cache sync, then commits.
    """
    cocotb.log.info("=== Test: FENCE.I Flush Pulse ===")

    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x1000, is_fence_i=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # The SQ is empty by default, so nothing but the cache sync delays commit.
    assert not dut_if.fence_i_flush, "flush should not be asserted yet"

    # One cycle in SERIAL_FENCE_I_SYNC: the bench holds i_fence_i_sync_done
    # high, so the cache sync costs exactly one stall cycle.
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    assert not dut_if.fence_i_flush, "flush must wait for the cache sync"

    # Commit edge.
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    # fence_i_flush is registered and pulses the cycle after commit.
    await RisingEdge(dut_if.clock)
    assert dut_if.fence_i_flush, "fence_i_flush should be asserted after FENCE.I commit"

    await FallingEdge(dut_if.clock)  # type: ignore[unreachable]
    await RisingEdge(dut_if.clock)
    assert (
        not dut_if.fence_i_flush
    ), "fence_i_flush should be deasserted after one cycle"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fence_i_sync_handshake(dut: Any) -> None:
    """FENCE.I holds commit in SERIAL_FENCE_I_SYNC until the cache sync.

    With i_fence_i_sync_done low, the serializer must raise
    o_fence_i_sync_req and stall commit indefinitely; raising done releases
    the commit and the flush pulse follows.
    """
    cocotb.log.info("=== Test: FENCE.I Sync Handshake ===")

    dut_if, model = await setup_test(dut)
    dut_if.set_fence_i_sync_done(False)

    req = AllocationRequest(pc=0x1000, is_fence_i=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # The serializer enters the sync state and parks there: sync_req high,
    # no commit, no flush.
    seen_req = False
    for _ in range(5):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        if dut_if.fence_i_sync_req:
            seen_req = True
            break
    assert seen_req, "o_fence_i_sync_req should rise for FENCE.I at head"

    for _ in range(8):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        assert dut_if.fence_i_sync_req, "sync_req must hold while done is low"
        assert not dut_if.empty, "FENCE.I must not commit before the sync"
        assert not dut_if.fence_i_flush, "no flush before the sync completes"

    # Complete the sync: commit proceeds and the flush pulse follows.
    dut_if.set_fence_i_sync_done(True)
    for _ in range(5):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        if dut_if.empty:
            break
    assert dut_if.empty, "FENCE.I should commit once the sync is done"
    assert not dut_if.fence_i_sync_req, "sync_req must drop after the sync"

    seen_flush = dut_if.fence_i_flush
    for _ in range(3):
        if seen_flush:
            break
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        seen_flush = dut_if.fence_i_flush
    assert seen_flush, "fence_i_flush should pulse after the synced commit"

    dut_if.set_fence_i_sync_done(True)  # restore the bench default

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_sfence_window_matches_sync_edges(dut: Any) -> None:
    """Registered SFENCE window has the original sync-state phase exactly."""
    dut_if, model = await setup_test(dut)
    dut_if.set_fence_i_sync_done(False)

    sfence = AllocationRequest(pc=0x1800, is_fence_i=True, is_sfence_vma=True)
    dut_if.drive_alloc_request(sfence)
    model.allocate(sfence)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    for _ in range(5):
        if dut_if.fence_i_sync_req:
            break
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
    sync_req = dut_if.fence_i_sync_req
    sfence_window = dut_if.sfence_window
    assert sync_req, "SFENCE.VMA did not enter the sync state"
    assert sfence_window, "SFENCE window must rise with the sync request"

    for _ in range(3):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        sync_req = dut_if.fence_i_sync_req
        sfence_window = dut_if.sfence_window
        assert sync_req
        assert sfence_window

    dut_if.set_fence_i_sync_done(True)
    for _ in range(5):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        sync_req = dut_if.fence_i_sync_req
        sfence_window = dut_if.sfence_window
        if not sync_req:
            break
    assert not sync_req, "sync request did not fall on completion"
    assert not sfence_window, "SFENCE window must fall on the same edge"

    # A plain FENCE.I uses the same serializer state but never invalidates TLBs.
    dut_if.set_fence_i_sync_done(False)
    fence_i = AllocationRequest(pc=0x1804, is_fence_i=True)
    dut_if.drive_alloc_request(fence_i)
    model.allocate(fence_i)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    for _ in range(5):
        if dut_if.fence_i_sync_req:
            break
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
    sync_req = dut_if.fence_i_sync_req
    sfence_window = dut_if.sfence_window
    assert sync_req, "plain FENCE.I did not enter the sync state"
    assert not sfence_window, "plain FENCE.I must not open the SFENCE window"

    dut_if.set_fence_i_sync_done(True)


@cocotb.test()
async def test_mret_handshake(dut: Any) -> None:
    """Check the MRET handshake with the trap unit.

    MRET asserts o_mret_start, waits for i_mret_done, then commits with
    redirect_pc = mepc.
    """
    cocotb.log.info("=== Test: MRET Handshake ===")

    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x1000, is_mret=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    await RisingEdge(dut_if.clock)
    assert dut_if.mret_start, "mret_start should be asserted"

    await FallingEdge(dut_if.clock)
    assert not dut_if.empty, "Should stall waiting for mret_done"

    mepc_value = 0x80001234
    dut_if.set_mepc(mepc_value)
    dut_if.set_mret_done(True)
    model.mepc = mepc_value
    model.mret_done = True

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
    model.mret_done = False

    await ClockCycles(dut_if.clock, 3)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Buffer should be empty after MRET commit"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_partial_flush(dut: Any) -> None:
    """Flush the entries younger than a branch and check the count."""
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

    # Partial flush at tag 1 (the branch) invalidates entries 2, 3, 4.
    await dut_if.partial_flush(1)
    model.flush_partial(1)

    await RisingEdge(dut_if.clock)

    assert dut_if.count == 2, f"Should have 2 entries after flush, got {dut_if.count}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_partial_flush_wrapped(dut: Any) -> None:
    """Partial flush with wrapped pointers, where flush_tag < head_idx.

    The age computation has to use mod-depth arithmetic for this case.
    """
    cocotb.log.info("=== Test: Partial Flush Wrapped ===")

    dut_if, model = await setup_test(dut)

    # Step 1: allocate and commit 30 entries to advance head_ptr to 30.
    for i in range(30):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=(i % 31) + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    for i in range(30):
        cdb = CDBWrite(tag=i, value=0x1000 + i)
        dut_if.drive_cdb_write(cdb)
        model.cdb_write(cdb)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_cdb_write()

    for _ in range(30):
        while model.can_commit():
            model.commit()
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after all commits"

    # Step 2: allocate 8 entries at indices 30, 31, 0, 1, 2, 3, 4, 5.
    allocated_tags = []
    for i in range(8):
        req = make_simple_alloc_request(pc=0x2000 + i * 4, rd=(i % 31) + 1)
        if i == 2:
            # Tag 0, the first entry past the wrap, is the branch.
            req = make_branch_request(pc=0x2000 + i * 4, predicted_taken=False)
        dut_if.drive_alloc_request(req)
        tag = model.allocate(req)
        allocated_tags.append(tag)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    assert allocated_tags == [30, 31, 0, 1, 2, 3, 4, 5], f"Tags: {allocated_tags}"
    assert dut_if.count == 8, f"Should have 8 entries, got {dut_if.count}"

    # head_idx = 30, tail_idx = 6
    cocotb.log.info(
        f"Before flush: head_ptr={dut_if.head_ptr}, tail_ptr={dut_if.tail_ptr}"
    )

    # Step 3: partial flush at tag 0, the branch. This is the wrap case,
    # flush_tag (0) < head_idx (30). Entries 1..5 are flushed; 30, 31 and 0
    # remain.
    await dut_if.partial_flush(0)
    model.flush_partial(0)

    await RisingEdge(dut_if.clock)

    cocotb.log.info(
        f"After flush: head_ptr={dut_if.head_ptr}, tail_ptr={dut_if.tail_ptr}"
    )
    cocotb.log.info(f"Count: {dut_if.count}")

    assert dut_if.count == 3, f"Should have 3 entries after flush, got {dut_if.count}"

    assert dut_if.head_ptr == model.head_ptr, "Head pointer mismatch"
    assert dut_if.tail_ptr == model.tail_ptr, "Tail pointer mismatch"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_full_flush(dut: Any) -> None:
    """Full flush empties a buffer holding eight entries."""
    cocotb.log.info("=== Test: Full Flush ===")

    dut_if, model = await setup_test(dut)

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

    await dut_if.full_flush()
    model.flush_all()

    await RisingEdge(dut_if.clock)

    assert dut_if.empty, "Should be empty after full flush"
    assert dut_if.count == 0, "Count should be 0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_jal_done_at_allocation(dut: Any) -> None:
    """JAL is marked done at allocation; its value is the link address."""
    cocotb.log.info("=== Test: JAL Done at Allocation ===")

    dut_if, model = await setup_test(dut)

    req = make_branch_request(
        pc=0x1000,
        is_jal=True,
        link_addr=0x1004,  # PC + 4
        predicted_taken=True,
        predicted_target=0x2000,
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)

    await RisingEdge(dut_if.clock)

    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # The JAL may already have committed, so head_done is only checked while
    # the entry is still present.
    if not dut_if.empty:
        assert dut_if.head_done, "JAL should be done after allocation"

    if model.can_commit():
        expected = model.commit()
        assert expected.value == 0x1004, "Value should be link address"

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after JAL commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_jal_call_commit_metadata(dut: Any) -> None:
    """JAL call metadata (is_call, is_jal, link value) reaches the commit bus."""
    cocotb.log.info("=== Test: JAL Call Commit Metadata ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    jal_pc = 0x1800
    target = 0x2400
    link_addr = jal_pc + 4
    req = make_branch_request(
        pc=jal_pc,
        predicted_taken=True,
        predicted_target=target,
        branch_target=target,
        is_jal=True,
        link_addr=link_addr,
        is_call=True,
    )
    dut_if.drive_alloc_request(req)
    tag = model.allocate(req)
    assert tag is not None
    expected_commits.append(
        ExpectedCommit(
            tag=tag,
            dest_reg=1,
            dest_valid=True,
            value=link_addr,
            pc=jal_pc,
            predicted_taken=True,
            branch_taken=True,
            branch_target=target,
            is_branch=True,
            is_call=True,
            is_jal=True,
        )
    )

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after JAL call commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_wfi_stall(dut: Any) -> None:
    """WFI stalls at the head until an interrupt is pending."""
    cocotb.log.info("=== Test: WFI Stall ===")

    dut_if, model = await setup_test(dut)

    await FallingEdge(dut_if.clock)
    req = AllocationRequest(pc=0x1000, is_wfi=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)

    await RisingEdge(dut_if.clock)

    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # WFI is marked done at allocation; the stall is in the commit gate.
    await RisingEdge(dut_if.clock)
    assert dut_if.head_done, "WFI should be marked done"

    await FallingEdge(dut_if.clock)
    dut_if.set_interrupt_pending(False)
    model.interrupt_pending = False

    await ClockCycles(dut_if.clock, 5)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "Should still have WFI (stalled)"

    await FallingEdge(dut_if.clock)
    dut_if.set_interrupt_pending(True)
    model.interrupt_pending = True

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)
    assert dut_if.empty, "WFI should have committed"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_fence_wait_sq(dut: Any) -> None:
    """FENCE stalls at the head until i_sq_committed_empty is high."""
    cocotb.log.info("=== Test: FENCE Wait SQ ===")

    dut_if, model = await setup_test(dut)

    await FallingEdge(dut_if.clock)
    req = AllocationRequest(pc=0x1000, is_fence=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Committed stores pending: the FENCE stalls.
    dut_if.set_sq_committed_empty(False)
    model.sq_committed_empty = False

    await ClockCycles(dut_if.clock, 3)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "FENCE should stall waiting for committed_empty"

    await FallingEdge(dut_if.clock)
    dut_if.set_sq_committed_empty(True)
    model.sq_committed_empty = True

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)

    assert dut_if.empty, "FENCE should have committed"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_csr_serialization(dut: Any) -> None:
    """A CSR instruction executes at commit and waits for i_csr_done."""
    cocotb.log.info("=== Test: CSR Serialization ===")

    dut_if, model = await setup_test(dut)

    await FallingEdge(dut_if.clock)
    # csr_addr must name an implemented CSR. Since Phase 3 M1 the ROB's
    # allocation-time existence map turns an unimplemented address (such as
    # the dataclass default 0x000) into an illegal-instruction trap at the
    # head instead of a serialized csr_start. mscratch (0x340) is a harmless
    # target.
    req = AllocationRequest(
        pc=0x1000, dest_reg=5, dest_valid=True, is_csr=True, csr_addr=0x340
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0x12345678)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await RisingEdge(dut_if.clock)
    assert dut_if.csr_start, "Should signal CSR start"

    await FallingEdge(dut_if.clock)
    dut_if.set_csr_done(False)
    model.csr_done = False

    await ClockCycles(dut_if.clock, 3)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "CSR should stall waiting for done"

    await FallingEdge(dut_if.clock)
    dut_if.set_csr_done(True)
    model.csr_done = True

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)

    assert dut_if.empty, "CSR should have committed"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_translation_csr_done_is_held_until_sq_drain(dut: Any) -> None:
    """A translation CSR remembers its one-cycle done pulse until SQ drain.

    The semantic fence-class event is delayed one cycle from retirement, and
    the final frontend flush follows one cycle after that. This is the phase
    relationship that lets the registered commit bus update csr_file before
    the refetch begins.
    """
    dut_if, model = await setup_test(dut)
    dut_if.set_sq_committed_empty(False)
    model.sq_committed_empty = False

    req = AllocationRequest(
        pc=0x1100,
        dest_reg=5,
        dest_valid=True,
        is_csr=True,
        # A read-only satp access still takes the translation drain: csr_file
        # writes its commit port for every CSR op, so the conservative flush
        # is kept for satp regardless of write intent.
        csr_write_intent=False,
        csr_addr=CSR_SATP,
        csr_op=0b010,
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert dut_if.csr_start, "translation CSR did not start at the ready head"

    # Mimic cpu_ooo's registered csr_done_q: high for one full cycle while
    # CSR_EXEC owns the head, then low for good. The serializer has to capture
    # that pulse into the dedicated drain state; it cannot ask for it again
    # when the SQ drains. Let the first edge move the serializer into
    # CSR_EXEC, then present the single completion sample.
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.set_csr_done(True)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.set_csr_done(False)

    for _ in range(3):
        assert not dut_if.empty, "translation CSR retired before the SQ drained"
        assert not dut.o_commit_valid_raw.value
        assert not dut_if.fence_class_flush_event
        assert not dut_if.translation_csr_commit_shadow
        assert not dut_if.fence_i_flush
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)

    dut_if.set_sq_committed_empty(True)
    model.sq_committed_empty = True
    dut.i_commit_hold.value = 1
    for _ in range(2):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        assert not dut_if.empty, "retire hold did not pin the translation CSR"
        assert not dut_if.fence_class_flush_event
        assert not dut_if.translation_csr_commit_shadow
        assert not dut_if.fence_i_flush

    dut.i_commit_hold.value = 0
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    empty, event, shadow, flush = sample_flush_phase(dut_if)
    assert empty, "translation CSR did not retire when the SQ drained"
    assert event
    assert shadow
    assert not flush

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    empty, event, shadow, flush = sample_flush_phase(dut_if)
    assert empty
    assert not event
    assert not shadow
    assert flush

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    assert not dut_if.fence_class_flush_event
    assert not dut_if.translation_csr_commit_shadow
    assert not dut_if.fence_i_flush


@cocotb.test()
async def test_writing_status_csrs_wait_for_sq(dut: Any) -> None:
    """Writing mstatus or sstatus uses the translation-CSR drain path."""
    dut_if, _model = await setup_test(dut)

    for case_index, csr_addr in enumerate((CSR_MSTATUS, CSR_SSTATUS)):
        dut_if.set_sq_committed_empty(False)
        tag = await drive_single_alloc(
            dut_if,
            AllocationRequest(
                pc=0x1200 + 4 * case_index,
                dest_reg=6,
                dest_valid=True,
                is_csr=True,
                csr_write_intent=True,
                csr_addr=csr_addr,
                csr_op=0b001,
            ),
        )

        dut_if.drive_cdb_write(CDBWrite(tag=tag, value=0))
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_cdb_write()
        assert dut_if.csr_start, f"CSR 0x{csr_addr:03x} did not start"

        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.set_csr_done(True)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.set_csr_done(False)

        empty, event, _shadow, _flush = sample_flush_phase(dut_if)
        assert not empty, f"CSR 0x{csr_addr:03x} bypassed the SQ drain"
        assert not event
        dut_if.set_sq_committed_empty(True)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        empty, event, shadow, _flush = sample_flush_phase(dut_if)
        assert empty
        assert event
        assert shadow

        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        assert dut_if.fence_i_flush
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        assert not dut_if.fence_i_flush


@cocotb.test()
async def test_nontranslation_csrs_do_not_wait_for_sq(dut: Any) -> None:
    """Read-only mstatus and writing mie keep ordinary CSR timing."""
    dut_if, _model = await setup_test(dut)
    dut_if.set_sq_committed_empty(False)

    cases = (
        (CSR_MSTATUS, False, 0b010),
        (CSR_MIE, True, 0b001),
    )
    for case_index, (csr_addr, write_intent, csr_op) in enumerate(cases):
        tag = await drive_single_alloc(
            dut_if,
            AllocationRequest(
                pc=0x1300 + 4 * case_index,
                dest_reg=7,
                dest_valid=True,
                is_csr=True,
                csr_write_intent=write_intent,
                csr_addr=csr_addr,
                csr_op=csr_op,
            ),
        )

        dut_if.drive_cdb_write(CDBWrite(tag=tag, value=0))
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_cdb_write()
        assert dut_if.csr_start, f"CSR 0x{csr_addr:03x} did not start"

        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.set_csr_done(True)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.set_csr_done(False)

        assert dut_if.empty, f"CSR 0x{csr_addr:03x} incorrectly waited for the SQ"
        for _ in range(2):
            assert not dut_if.fence_class_flush_event
            assert not dut_if.translation_csr_commit_shadow
            assert not dut_if.fence_i_flush
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)

        assert not dut_if.fence_class_flush_event
        assert not dut_if.translation_csr_commit_shadow
        assert not dut_if.fence_i_flush


@cocotb.test()
async def test_exception_handling(dut: Any) -> None:
    """An exceptional completion at the head raises trap_pending with pc and cause."""
    cocotb.log.info("=== Test: Exception Handling ===")

    dut_if, model = await setup_test(dut)

    await FallingEdge(dut_if.clock)
    req = make_simple_alloc_request(pc=0x1000, rd=1)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0, exception=True, exc_cause=4)  # Load addr misalign
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await RisingEdge(dut_if.clock)
    assert dut_if.trap_pending, "Should signal trap pending"
    assert dut_if.trap_pc == 0x1000, "Trap PC should match instruction PC"
    assert dut_if.trap_cause == 4, "Trap cause should match"

    await FallingEdge(dut_if.clock)
    dut_if.set_trap_taken(True)
    model.trap_taken = True

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_alloc_priv_fault_survives_nonexception_cdb(dut: Any) -> None:
    """A normal completion cannot erase an allocation-time privilege fault."""
    dut_if, model = await setup_test(dut)

    dut.i_priv.value = PRIV_U
    dut.i_priv_is_u.value = 1
    req = AllocationRequest(
        pc=0x2100,
        dest_reg=5,
        dest_valid=True,
        is_csr=True,
        csr_addr=CSR_MSTATUS,
    )
    tag = await drive_single_alloc(dut_if, req)
    model_tag = model.allocate(req, exception=True, exc_cause=EXC_ILLEGAL_INSTR)
    assert tag == model_tag

    # Change the live privilege after allocation to prove the fault was
    # captured at allocation rather than recomputed at the head. In the
    # integrated core a privilege change would flush this entry; only the
    # standalone unit can be driven this way.
    dut.i_priv.value = PRIV_M
    dut.i_priv_is_u.value = 0

    cdb = CDBWrite(tag=tag, value=0x1234)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert model.entries[tag].exception
    assert model.entries[tag].exc_cause == EXC_ILLEGAL_INSTR
    await RisingEdge(dut_if.clock)
    assert dut_if.trap_pending, "Allocation-time privilege fault was erased by CDB"
    assert not dut_if.csr_start, "Faulting CSR must not start serialization"
    assert dut_if.trap_pc == req.pc
    assert dut_if.trap_cause == EXC_ILLEGAL_INSTR


@cocotb.test()
async def test_cdb_exception_overrides_alloc_illegal_cause(dut: Any) -> None:
    """A real execution exception replaces a stored IllegalInstr cause."""
    dut_if, model = await setup_test(dut)

    dut.i_priv.value = PRIV_U
    dut.i_priv_is_u.value = 1
    req = AllocationRequest(
        pc=0x2200,
        dest_reg=6,
        dest_valid=True,
        is_csr=True,
        csr_addr=CSR_MSTATUS,
    )
    tag = await drive_single_alloc(dut_if, req)
    model_tag = model.allocate(req, exception=True, exc_cause=EXC_ILLEGAL_INSTR)
    assert tag == model_tag
    dut.i_priv.value = PRIV_M
    dut.i_priv_is_u.value = 0

    cdb_cause = 5
    cdb = CDBWrite(tag=tag, value=0, exception=True, exc_cause=cdb_cause)
    dut_if.drive_cdb_write_2(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write_2()

    assert model.entries[tag].exception
    assert model.entries[tag].exc_cause == cdb_cause
    await RisingEdge(dut_if.clock)
    assert dut_if.trap_pending
    assert not dut_if.csr_start
    assert dut_if.trap_cause == cdb_cause, "CDB exception must override IllegalInstr"


@cocotb.test()
async def test_fs_off_slot2_blocks_widen_commit_then_traps(dut: Any) -> None:
    """An FS-Off slot-2 fault cannot retire beside an ordinary head entry."""
    dut_if, model = await setup_test(dut)

    dut.i_mstatus_fs_off.value = 1
    req_1 = make_simple_alloc_request(pc=0x2300, rd=7)
    req_2 = AllocationRequest(
        pc=0x2304,
        rs_type=RS_FP,
        dest_rf=1,
        dest_reg=8,
        dest_valid=True,
        is_fp_instruction=True,
        has_fp_flags=True,
    )
    (_, tag_1, _), (_, tag_2, _) = await drive_dual_alloc(dut_if, req_1, req_2)
    assert model.allocate(req_1) == tag_1
    assert model.allocate(req_2, exception=True, exc_cause=EXC_ILLEGAL_INSTR) == tag_2

    # As above, remove the live gate after allocation so only the stored fault
    # can block widened retirement and drive the later trap.
    dut.i_mstatus_fs_off.value = 0

    cdb_2 = CDBWrite(tag=tag_2, value=0x2222)
    dut_if.drive_cdb_write_2(cdb_2)
    model.cdb_write(cdb_2)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write_2()
    assert model.entries[tag_2].exception
    assert model.entries[tag_2].exc_cause == EXC_ILLEGAL_INSTR

    cdb_1 = CDBWrite(tag=tag_1, value=0x1111)
    dut_if.drive_cdb_write(cdb_1)
    model.cdb_write(cdb_1)
    await RisingEdge(dut_if.clock)
    commit_1 = dut_if.read_commit()
    commit_2 = dut_if.read_commit_2()
    assert commit_1["valid"] and commit_1["tag"] == tag_1
    assert not commit_2["valid"], "FS-Off slot 2 retired beside the legal head"
    assert not dut_if.commit_2_valid_raw
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    assert dut_if.count == 1
    assert dut_if.head_tag == tag_2
    await RisingEdge(dut_if.clock)
    assert dut_if.trap_pending, "Held FS-Off entry did not trap at the head"
    assert dut_if.trap_pc == req_2.pc
    assert dut_if.trap_cause == EXC_ILLEGAL_INSTR


@cocotb.test()
async def test_same_cycle_stale_exception_does_not_override_alloc_illegal(
    dut: Any,
) -> None:
    """A stale CDB collision cannot replace a same-tag allocation's cause."""
    dut_if, model = await setup_test(dut)

    dut.i_priv.value = PRIV_U
    dut.i_priv_is_u.value = 1
    req = AllocationRequest(
        pc=0x2400,
        dest_reg=9,
        dest_valid=True,
        is_csr=True,
        csr_addr=CSR_MSTATUS,
    )
    stale_cause = 7
    stale = CDBWrite(tag=0, value=0xBAD, exception=True, exc_cause=stale_cause)
    dut_if.drive_alloc_request(req)
    dut_if.drive_cdb_write_2(stale)
    model_tag = model.allocate(req, exception=True, exc_cause=EXC_ILLEGAL_INSTR)
    assert model_tag == 0
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    dut_if.clear_cdb_write_2()

    dut.i_priv.value = PRIV_M
    dut.i_priv_is_u.value = 0
    completion = CDBWrite(tag=model_tag, value=0xCAFE)
    dut_if.drive_cdb_write(completion)
    model.cdb_write(completion)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await RisingEdge(dut_if.clock)
    assert dut_if.trap_pending
    assert dut_if.trap_cause == EXC_ILLEGAL_INSTR
    assert dut_if.trap_cause != stale_cause


@cocotb.test()
async def test_flush_reuse_clears_alloc_illegal(dut: Any) -> None:
    """A legal reallocation must not inherit a flushed tag's stored fault."""
    dut_if, model = await setup_test(dut)

    dut.i_priv.value = PRIV_U
    dut.i_priv_is_u.value = 1
    illegal_req = AllocationRequest(
        pc=0x2500,
        dest_reg=10,
        dest_valid=True,
        is_csr=True,
        csr_addr=CSR_MSTATUS,
    )
    stale_tag = await drive_single_alloc(dut_if, illegal_req)
    assert (
        model.allocate(illegal_req, exception=True, exc_cause=EXC_ILLEGAL_INSTR)
        == stale_tag
    )

    dut_if.drive_full_flush()
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_full_flush()
    model.flush_all()
    assert dut_if.empty

    dut.i_priv.value = PRIV_M
    dut.i_priv_is_u.value = 0
    legal_req = make_simple_alloc_request(pc=0x2504, rd=11)
    reused_tag = await drive_single_alloc(dut_if, legal_req)
    assert reused_tag == stale_tag
    assert model.allocate(legal_req) == reused_tag
    assert not model.entries[reused_tag].exception
    assert model.entries[reused_tag].exc_cause == 0

    completion = CDBWrite(tag=reused_tag, value=0xF00D)
    dut_if.drive_cdb_write(completion)
    model.cdb_write(completion)
    await RisingEdge(dut_if.clock)
    commit = dut_if.read_commit()
    assert commit["valid"] and commit["tag"] == reused_tag
    assert not commit["exception"]
    assert commit["exc_cause"] == 0
    assert not dut_if.trap_pending
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()
    assert dut_if.empty


# =============================================================================
# Constrained Random Tests
# =============================================================================


@cocotb.test()
async def test_random_allocation_commit(dut: Any) -> None:
    """Random allocation, completion and idle cycles.

    No model: the test tracks the pending tags and checks that the buffer is
    empty once every one of them has been completed.
    """
    cocotb.log.info("=== Test: Random Allocation and Commit ===")
    log_random_seed()

    dut_if, _ = await setup_test(dut)

    num_operations = 200
    pending_tags: set[int] = set()
    total_allocated = 0

    for op in range(num_operations):
        _, _, full = dut_if.read_alloc_response()

        action = random.choices(
            ["allocate", "complete", "idle"],
            weights=[0.5, 0.4, 0.1],
        )[0]

        if action == "allocate" and not full:
            pc = random.randint(0, 0xFFFFFFFF) & ~3  # Aligned
            rd = random.randint(0, 31)
            is_fp = random.random() < 0.2  # 20% FP

            req = make_simple_alloc_request(pc=pc, rd=rd, is_fp=is_fp)
            dut_if.drive_alloc_request(req)

            await RisingEdge(dut_if.clock)
            ready, alloc_tag, _ = dut_if.read_alloc_response()
            if ready:
                pending_tags.add(alloc_tag)
                total_allocated += 1

            await FallingEdge(dut_if.clock)
            dut_if.clear_alloc_request()

        elif action == "complete" and pending_tags:
            tag = random.choice(list(pending_tags))
            value = random.randint(0, MASK64)

            cdb = CDBWrite(tag=tag, value=value)
            dut_if.drive_cdb_write(cdb)
            pending_tags.discard(tag)

            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_cdb_write()

        else:
            # Idle cycle.
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)

    while pending_tags:
        tag = pending_tags.pop()
        cdb = CDBWrite(tag=tag, value=random.randint(0, MASK64))
        dut_if.drive_cdb_write(cdb)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_cdb_write()

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
    log_random_seed()

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

        # Complete the entries older than the branch.
        for i in range(branch_pos):
            tag = allocated_tags[i]
            if tag in pending_tags:
                cdb = CDBWrite(tag=tag, value=random.randint(0, MASK32))
                dut_if.drive_cdb_write(cdb)
                pending_tags.discard(tag)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_cdb_write()

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
            await dut_if.partial_flush(branch_tag)
            # The flushed entries never complete; drop them from the set.
            for i in range(branch_pos + 1, seq_len):
                pending_tags.discard(allocated_tags[i])
            await FallingEdge(dut_if.clock)

        for tag in list(pending_tags):
            cdb = CDBWrite(tag=tag, value=random.randint(0, MASK32))
            dut_if.drive_cdb_write(cdb)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_cdb_write()
        pending_tags.clear()

        await ClockCycles(dut_if.clock, seq_len + 5)

        # Full flush before the next sequence.
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
    log_random_seed()

    dut_if, _ = await setup_test(dut)

    num_cycles = 100

    for cycle in range(num_cycles):
        pending_tags: list[int] = []

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

        for tag in pending_tags:
            cdb = CDBWrite(tag=tag, value=random.randint(0, MASK64))
            dut_if.drive_cdb_write(cdb)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_cdb_write()

        for _ in range(10):
            if dut_if.empty:
                break
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)

        assert dut_if.empty, f"Cycle {cycle}: DUT should be empty"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_mixed_instruction_types(dut: Any) -> None:
    """Random mix of ALU, branch, store, FP ALU and FP store instructions."""
    cocotb.log.info("=== Test: Mixed Instruction Types ===")
    log_random_seed()

    dut_if, _ = await setup_test(dut)

    num_instructions = 50
    pending_tags: dict[int, str] = {}  # tag -> type
    all_allocated: list[tuple[int, str]] = []  # (tag, type) for debug
    all_completed: list[tuple[int, str]] = []  # (tag, type) for debug

    for i in range(num_instructions):
        instr_type = random.choices(
            ["alu", "branch", "store", "fp_alu", "fp_store"],
            weights=[0.4, 0.2, 0.15, 0.15, 0.1],
        )[0]

        if dut_if.full:
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

        if pending_tags and random.random() < 0.6:
            tag_to_complete = random.choice(list(pending_tags.keys()))
            itype = pending_tags[tag_to_complete]

            if itype == "branch":
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
                value = random.randint(0, MASK64)
                fp_flags = random.randint(0, 31) if "fp" in itype else 0
                cdb = CDBWrite(tag=tag_to_complete, value=value, fp_flags=fp_flags)
                dut_if.drive_cdb_write(cdb)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_cdb_write()

            all_completed.append((tag_to_complete, itype))
            del pending_tags[tag_to_complete]

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
async def test_full_buffer_state_stability(dut: Any) -> None:
    """A full, idle buffer keeps its count, head and full flag."""
    cocotb.log.info("=== Test: Full Buffer State Stability ===")

    dut_if, model = await setup_test(dut)

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

    count_before = dut_if.count
    head_before = dut_if.head_tag

    # The RTL raises an error on alloc_valid while full, so the test does not
    # drive it. It idles for 10 cycles and checks that nothing moved.
    await ClockCycles(dut_if.clock, 10)

    await RisingEdge(dut_if.clock)
    assert dut_if.count == count_before, "Count should not change"
    assert dut_if.head_tag == head_before, "Head should not change"
    assert dut_if.full, "Should still be full"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_back_to_back_commits(dut: Any) -> None:
    """Eight done entries commit back to back."""
    cocotb.log.info("=== Test: Back-to-Back Commits ===")

    dut_if, model = await setup_test(dut)

    num_entries = 8

    for i in range(num_entries):
        req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    assert dut_if.count == num_entries, f"Should have {num_entries} entries"

    for i in range(num_entries):
        cdb = CDBWrite(tag=i, value=0x1000 + i)
        dut_if.drive_cdb_write(cdb)
        model.cdb_write(cdb)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_cdb_write()

    while model.can_commit():
        model.commit()

    await ClockCycles(dut_if.clock, num_entries + 5)

    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Should be empty after all commits"
    assert model.empty, "Model should also be empty"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Coverage Gap Tests
# =============================================================================


@cocotb.test()
async def test_checkpoint_assignment(dut: Any) -> None:
    """A branch allocated with checkpoint_id=2 commits with has_checkpoint set.

    The commit must carry has_checkpoint=True and checkpoint_id=2.
    """
    cocotb.log.info("=== Test: Checkpoint Assignment ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    req = make_branch_request(
        pc=0x1000,
        predicted_taken=True,
        predicted_target=0x2000,
    )
    dut_if.drive_alloc_request(req)
    dut_if.drive_checkpoint(2)
    tag = model.allocate(req)
    assert tag is not None, "Allocation should succeed"
    model.set_checkpoint(tag, 2)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    dut_if.clear_checkpoint()

    # Queue the expected commit before resolving the branch.
    expected = ExpectedCommit(
        valid=True,
        tag=0,
        dest_rf=0,
        dest_reg=0,
        dest_valid=False,
        value=0,
        pc=0x1000,
        misprediction=False,
        has_checkpoint=True,
        checkpoint_id=2,
        redirect_pc=0x2000,
        predicted_taken=True,
        branch_taken=True,
        branch_target=0x2000,
        is_branch=True,
    )
    expected_commits.append(expected)

    # Resolve as predicted: taken to 0x2000.
    update = BranchUpdate(tag=tag, taken=True, target=0x2000, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_jalr_end_to_end(dut: Any) -> None:
    """Allocate a JALR, resolve it through a branch update, and commit it.

    The JALR's value is link_addr = pc+4 from allocation, but the entry is not
    done until the branch update resolves the target. The commit must carry
    dest_valid=True and value=link_addr.
    """
    cocotb.log.info("=== Test: JALR End-to-End ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    jalr_pc = 0x1000
    link_addr = jalr_pc + 4
    req = make_branch_request(
        pc=jalr_pc,
        is_jalr=True,
        link_addr=link_addr,
        predicted_taken=True,
        predicted_target=0x3000,
    )
    dut_if.drive_alloc_request(req)
    tag = model.allocate(req)
    assert tag is not None
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    assert dut_if.head_valid, "Head should be valid"
    assert not dut_if.head_done, "JALR should not be done until branch update"

    # Queue the expected commit before the branch update.
    expected = ExpectedCommit(
        valid=True,
        tag=tag,
        dest_rf=0,
        dest_reg=1,
        dest_valid=True,
        value=link_addr,
        pc=jalr_pc,
        misprediction=False,
        redirect_pc=0x3000,
        predicted_taken=True,
        branch_taken=True,
        branch_target=0x3000,
        is_branch=True,
        is_jalr=True,
    )
    expected_commits.append(expected)

    # Resolve as predicted: taken to 0x3000.
    update = BranchUpdate(tag=tag, taken=True, target=0x3000, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after JALR commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_jalr_return_commit_metadata(dut: Any) -> None:
    """JALR return metadata (is_return, is_jalr) reaches the commit bus."""
    cocotb.log.info("=== Test: JALR Return Commit Metadata ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    return_pc = 0x1A00
    target = 0x3400
    req = AllocationRequest(
        pc=return_pc,
        dest_reg=0,
        dest_valid=False,
        is_branch=True,
        predicted_taken=True,
        predicted_target=target,
        is_return=True,
        is_jalr=True,
    )
    dut_if.drive_alloc_request(req)
    tag = model.allocate(req)
    assert tag is not None
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    assert dut_if.head_valid, "Head should be valid"
    assert not dut_if.head_done, "JALR return should wait for branch update"

    expected_commits.append(
        ExpectedCommit(
            tag=tag,
            pc=return_pc,
            predicted_taken=True,
            branch_taken=True,
            branch_target=target,
            is_branch=True,
            is_return=True,
            is_jalr=True,
        )
    )

    update = BranchUpdate(tag=tag, taken=True, target=target, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after JALR return commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_amo_commits_normally(dut: Any) -> None:
    """An AMO commits like an ordinary entry once its CDB result arrives.

    AMO ordering is enforced at LQ issue, which waits for the AMO to reach
    the ROB head with the SQ committed-empty. The ROB itself does not
    consult i_sq_committed_empty for AMO commit.
    """
    cocotb.log.info("=== Test: AMO Commits Normally ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    req = AllocationRequest(pc=0x1000, dest_reg=5, dest_valid=True, is_amo=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Queue the expected commit before the CDB write: commit fires on the
    # same rising edge that registers done=1, so the monitor needs the
    # expectation already queued.
    expected = ExpectedCommit(
        valid=True,
        tag=0,
        dest_reg=5,
        dest_valid=True,
        value=0xAABBCCDD,
        pc=0x1000,
        is_amo=True,
    )
    expected_commits.append(expected)

    cdb = CDBWrite(tag=0, value=0xAABBCCDD)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "AMO should have committed (no SQ stall at ROB)"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fence_i_waits_for_sq(dut: Any) -> None:
    """FENCE.I stalls while committed stores are pending, then commits and flushes."""
    cocotb.log.info("=== Test: FENCE.I Waits for SQ ===")

    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x1000, is_fence_i=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    dut_if.set_sq_committed_empty(False)
    model.sq_committed_empty = False

    await ClockCycles(dut_if.clock, 3)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "FENCE.I should stall waiting for committed_empty"
    assert not dut_if.fence_i_flush, "fence_i_flush should not pulse while stalled"

    await FallingEdge(dut_if.clock)
    dut_if.set_sq_committed_empty(True)
    model.sq_committed_empty = True

    for _ in range(10):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        if dut_if.empty:
            break  # type: ignore[unreachable]
    assert dut_if.empty, "FENCE.I should have committed"

    # fence_i_flush is registered and pulses the cycle after commit; it may
    # already be visible or still one cycle away.
    seen_flush = False  # type: ignore[unreachable]
    for _ in range(3):
        await RisingEdge(dut_if.clock)
        if dut_if.fence_i_flush:
            seen_flush = True
            break
    assert seen_flush, "fence_i_flush should pulse after FENCE.I commit"

    # Pulse should be one cycle only  # type: ignore[unreachable]
    await RisingEdge(dut_if.clock)
    assert not dut_if.fence_i_flush, "fence_i_flush should deassert after one cycle"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_exception_on_csr(dut: Any) -> None:
    """A CSR completing with an exception enters SERIAL_TRAP_WAIT, not CSR_EXEC.

    The exception check precedes CSR serialization, so the head raises
    trap_pending and never csr_start.
    """
    cocotb.log.info("=== Test: Exception on CSR ===")

    dut_if, model = await setup_test(dut)

    req = AllocationRequest(
        pc=0x2000, dest_reg=5, dest_valid=True, is_csr=True, csr_addr=0x340
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0, exception=True, exc_cause=2)  # Illegal instruction
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await RisingEdge(dut_if.clock)
    assert dut_if.trap_pending, "Should signal trap pending (exception before CSR)"
    assert not dut_if.csr_start, "csr_start should NOT assert when exception present"
    assert dut_if.trap_pc == 0x2000, "Trap PC should match CSR instruction PC"
    assert dut_if.trap_cause == 2, "Trap cause should match"

    await ClockCycles(dut_if.clock, 3)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "Should stall waiting for trap_taken"

    await FallingEdge(dut_if.clock)
    dut_if.set_trap_taken(True)
    model.trap_taken = True

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_flush_during_serialization(dut: Any) -> None:
    """flush_all during SERIAL_CSR_EXEC empties the buffer and resets the serializer.

    A plain instruction is allocated and committed afterwards to show the
    serializer is back in IDLE.
    """
    cocotb.log.info("=== Test: Flush During Serialization ===")

    dut_if, model = await setup_test(dut)

    # csr_addr must exist (see test_csr_serialization).
    req = AllocationRequest(
        pc=0x1000, dest_reg=5, dest_valid=True, is_csr=True, csr_addr=0x340
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0x12345678)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await RisingEdge(dut_if.clock)
    assert dut_if.csr_start, "CSR should signal csr_start"
    assert not dut_if.empty, "CSR should be stalled in serialization"

    # Flush while the serializer is in SERIAL_CSR_EXEC.
    await dut_if.full_flush()
    model.flush_all()

    await RisingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after flush_all"
    assert dut_if.count == 0, "Count should be 0"  # type: ignore[unreachable]

    # Recovery check: an ordinary instruction allocates and commits.
    await FallingEdge(dut_if.clock)
    req = make_simple_alloc_request(pc=0x2000, rd=1)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0xDEADBEEF)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Normal instruction should commit after flush recovery"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Non-Interference & Additional Coverage Tests
# =============================================================================


@cocotb.test()
async def test_simultaneous_alloc_cdb_branch_noninterference(dut: Any) -> None:
    """Allocation, a CDB write and a branch update in one cycle do not interfere.

    Each operation targets a different entry. All three must take effect.
    """
    cocotb.log.info("=== Test: Simultaneous Alloc/CDB/Branch Non-Interference ===")

    dut_if, model = await setup_test(dut)

    # Tag 0 (ALU), tag 1 (ALU), tag 2 (branch).
    for i in range(3):
        if i == 2:
            req = make_branch_request(
                pc=0x1000 + i * 4,
                predicted_taken=True,
                predicted_target=0x3000,
            )
        else:
            req = make_simple_alloc_request(pc=0x1000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    assert dut_if.count == 3, f"Should have 3 entries, got {dut_if.count}"

    # Same falling edge: allocate tag 3, complete tag 1, resolve tag 2.
    alloc_req = make_simple_alloc_request(pc=0x100C, rd=4)
    dut_if.drive_alloc_request(alloc_req)
    model.allocate(alloc_req)

    cdb = CDBWrite(tag=1, value=0xBBBB)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)

    update = BranchUpdate(tag=2, taken=True, target=0x3000, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)

    dut_if.clear_alloc_request()
    dut_if.clear_cdb_write()
    dut_if.clear_branch_update()

    assert dut_if.count == 4, f"Should have 4 entries, got {dut_if.count}"

    dut_if.set_read_tag(1)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    done = dut_if.read_entry_done()
    value = dut_if.read_entry_value()
    assert done, "Entry 1 should be done after CDB write"
    assert value == 0xBBBB, f"Entry 1 value mismatch: {value:#x}"

    cdb = CDBWrite(tag=0, value=0xAAAA)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    cdb = CDBWrite(tag=3, value=0xDDDD)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 10)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after all commits"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fp_flags_commit_verification(dut: Any) -> None:
    """FP exception flags written over the CDB appear unchanged in the commit.

    The CDB write carries overflow + inexact (0b00101); the commit struct must
    carry the same value.
    """
    cocotb.log.info("=== Test: FP Flags Commit Verification ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    # FP instruction writing f1.
    req = make_simple_alloc_request(pc=0x2000, rd=1, is_fp=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    fp_flags_val = 0b00101  # OF (bit 2) + NX (bit 0)
    cdb = CDBWrite(tag=0, value=0x4050000000000000, fp_flags=fp_flags_val)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)

    # Queue the expected commit before the edge; the head commits on it.
    expected = ExpectedCommit(
        valid=True,
        tag=0,
        dest_rf=1,  # FP register
        dest_reg=1,
        dest_valid=True,
        value=0x4050000000000000,
        pc=0x2000,
        fp_flags=fp_flags_val,
    )
    expected_commits.append(expected)

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after commit"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_lr_sc_commit_behavior(dut: Any) -> None:
    """LR commits once done; SC is resolved by the wrapper and completes over the CDB.

    Neither consults the SQ in the ROB: LR ordering is enforced at LQ issue,
    and the SC result (0 for success) arrives as an ordinary CDB value.
    """
    cocotb.log.info("=== Test: LR/SC Commit Behavior ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    req = AllocationRequest(pc=0x3000, dest_reg=5, dest_valid=True, is_lr=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # SC is not done at dispatch; it needs the CDB write.
    req = AllocationRequest(pc=0x3004, dest_reg=6, dest_valid=True, is_sc=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    expected_lr = ExpectedCommit(
        valid=True,
        tag=0,
        dest_reg=5,
        dest_valid=True,
        value=0x1234,
        pc=0x3000,
        is_lr=True,
    )
    expected_commits.append(expected_lr)

    expected_sc = ExpectedCommit(
        valid=True,
        tag=1,
        dest_reg=6,
        dest_valid=True,
        value=0x0,
        pc=0x3004,
        is_sc=True,
    )
    expected_commits.append(expected_sc)

    cdb = CDBWrite(tag=0, value=0x1234)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # SC success.
    cdb = CDBWrite(tag=1, value=0x0)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 10)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after LR/SC commits"
    monitor.check_complete()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_flush_during_wfi(dut: Any) -> None:
    """flush_all during WFI_WAIT empties the buffer and returns the serializer to IDLE.

    A plain instruction is allocated and committed afterwards as the recovery
    check.
    """
    cocotb.log.info("=== Test: Flush During WFI ===")

    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x4000, is_wfi=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    dut_if.set_interrupt_pending(False)
    await ClockCycles(dut_if.clock, 3)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "WFI should be stalled (WFI_WAIT state)"

    await dut_if.full_flush()
    model.flush_all()
    await RisingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after flush_all during WFI_WAIT"
    assert dut_if.count == 0, "Count should be 0"  # type: ignore[unreachable]

    # Recovery check.
    await FallingEdge(dut_if.clock)
    req = make_simple_alloc_request(pc=0x5000, rd=1)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0xAAAA)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Normal instruction should commit after WFI flush recovery"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_flush_during_mret(dut: Any) -> None:
    """flush_all during MRET_EXEC empties the buffer and returns the serializer to IDLE.

    A plain instruction is allocated and committed afterwards as the recovery
    check.
    """
    cocotb.log.info("=== Test: Flush During MRET ===")

    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x6000, is_mret=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    await RisingEdge(dut_if.clock)
    assert dut_if.mret_start, "mret_start should be asserted"

    # mret_done stays low, so the serializer parks in MRET_EXEC.
    await ClockCycles(dut_if.clock, 2)
    await RisingEdge(dut_if.clock)
    assert not dut_if.empty, "MRET should be stalled (MRET_EXEC state)"

    await dut_if.full_flush()
    model.flush_all()
    await RisingEdge(dut_if.clock)

    assert dut_if.empty, "Buffer should be empty after flush_all during MRET_EXEC"
    assert dut_if.count == 0, "Count should be 0"  # type: ignore[unreachable]

    # Recovery check.
    await FallingEdge(dut_if.clock)
    req = make_simple_alloc_request(pc=0x7000, rd=2)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0xBBBB)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "Normal instruction should commit after MRET flush recovery"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_sequential_serializing_instructions(dut: Any) -> None:
    """A CSR followed by a FENCE commit in order, each through its own handshake."""
    cocotb.log.info("=== Test: Sequential Serializing Instructions ===")

    dut_if, model = await setup_test(dut)

    # CSR at tag 0. csr_addr must exist (see test_csr_serialization).
    req = AllocationRequest(
        pc=0x8000, dest_reg=5, dest_valid=True, is_csr=True, csr_addr=0x340
    )
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # FENCE at tag 1.
    req = AllocationRequest(pc=0x8004, is_fence=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    assert dut_if.count == 2, f"Should have 2 entries, got {dut_if.count}"

    cdb = CDBWrite(tag=0, value=0x12345678)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await RisingEdge(dut_if.clock)
    assert dut_if.csr_start, "CSR should signal csr_start"
    assert not dut_if.empty, "Should stall for CSR"

    await FallingEdge(dut_if.clock)
    dut_if.set_csr_done(True)

    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.set_csr_done(False)

    # The FENCE is now at the head. It was marked done at allocation and the
    # SQ is empty by default, so it commits without further input.
    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)

    assert dut_if.empty, "Both CSR and FENCE should have committed"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_alloc_ready_deasserts_during_flush(dut: Any) -> None:
    """alloc_ready is low while flush_en or flush_all is asserted.

    It reasserts once the flush input clears. This pins the current behavior
    so a change to the allocation gate is caught.
    """
    cocotb.log.info("=== Test: alloc_ready Deasserts During Flush ===")

    dut_if, model = await setup_test(dut)

    for i in range(4):
        req = make_simple_alloc_request(pc=0x9000 + i * 4, rd=i + 1)
        dut_if.drive_alloc_request(req)
        model.allocate(req)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_alloc_request()

    await RisingEdge(dut_if.clock)
    ready, _, _ = dut_if.read_alloc_response()
    assert ready, "alloc_ready should be asserted in normal operation"

    # --- flush_en ---
    await FallingEdge(dut_if.clock)
    dut_if.drive_partial_flush(1)

    await RisingEdge(dut_if.clock)
    ready, _, _ = dut_if.read_alloc_response()
    assert not ready, "alloc_ready should deassert during flush_en"

    await FallingEdge(dut_if.clock)
    dut_if.clear_partial_flush()

    await RisingEdge(dut_if.clock)
    ready, _, _ = dut_if.read_alloc_response()
    assert ready, "alloc_ready should reassert after flush_en clears"

    # --- flush_all ---
    await FallingEdge(dut_if.clock)
    dut_if.drive_full_flush()

    await RisingEdge(dut_if.clock)
    ready, _, _ = dut_if.read_alloc_response()
    assert not ready, "alloc_ready should deassert during flush_all"

    await FallingEdge(dut_if.clock)
    dut_if.clear_full_flush()

    await RisingEdge(dut_if.clock)
    ready, _, _ = dut_if.read_alloc_response()
    assert ready, "alloc_ready should reassert after flush_all clears"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Atomics / committed_empty Tests
# =============================================================================


@cocotb.test()
async def test_sc_resolves_success(dut: Any) -> None:
    """SC with CDB value=0 commits value=0 (success)."""
    cocotb.log.info("=== Test: SC Resolves Success ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    req = AllocationRequest(pc=0x4000, dest_reg=10, dest_valid=True, is_sc=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Queue the expected commit before the CDB write; the head commits on it.
    expected_commits.append(
        ExpectedCommit(
            valid=True,
            tag=0,
            dest_reg=10,
            dest_valid=True,
            value=0,
            pc=0x4000,
            is_sc=True,
        )
    )

    cdb = CDBWrite(tag=0, value=0)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "SC should have committed"
    monitor.check_complete()
    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_sc_resolves_failure(dut: Any) -> None:
    """SC with CDB value=1 commits value=1 (failure)."""
    cocotb.log.info("=== Test: SC Resolves Failure ===")

    dut_if, model = await setup_test(dut)

    expected_commits: deque[ExpectedCommit] = deque()
    monitor = CommitMonitor(dut_if.dut, expected_commits)
    cocotb.start_soon(monitor.run())

    req = AllocationRequest(pc=0x4000, dest_reg=10, dest_valid=True, is_sc=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # Queue the expected commit before the CDB write; the head commits on it.
    expected_commits.append(
        ExpectedCommit(
            valid=True,
            tag=0,
            dest_reg=10,
            dest_valid=True,
            value=1,
            pc=0x4000,
            is_sc=True,
        )
    )

    cdb = CDBWrite(tag=0, value=1)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "SC should have committed"
    monitor.check_complete()
    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_sc_commits_via_cdb(dut: Any) -> None:
    """SC is not done at dispatch; it commits only after its CDB write."""
    cocotb.log.info("=== Test: SC Commits Via CDB ===")

    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x5000, dest_reg=7, dest_valid=True, is_sc=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    await ClockCycles(dut_if.clock, 3)
    await FallingEdge(dut_if.clock)
    assert not dut_if.empty, "SC should not commit without CDB write"

    cdb = CDBWrite(tag=0, value=0)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 3)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "SC should commit after CDB write"


@cocotb.test()
async def test_lr_commits_normally(dut: Any) -> None:
    """LR at the head with done=1 commits; the ROB does not gate LR on the SQ."""
    cocotb.log.info("=== Test: LR Commits Normally ===")

    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x6000, dest_reg=8, dest_valid=True, is_lr=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    cdb = CDBWrite(tag=0, value=0xFEEDFACE)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "LR should commit even with SQ not empty"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fence_uses_committed_empty(dut: Any) -> None:
    """FENCE waits for i_sq_committed_empty and nothing else from the SQ.

    Younger, uncommitted stores may sit in the SQ while a FENCE is at the
    head. Only committed stores have to drain; the ROB has no
    all-entries-empty input.
    """
    cocotb.log.info("=== Test: FENCE Uses committed_empty ===")

    dut_if, model = await setup_test(dut)

    await FallingEdge(dut_if.clock)
    req = AllocationRequest(pc=0x7000, is_fence=True)
    dut_if.drive_alloc_request(req)
    model.allocate(req)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()

    # No committed stores pending, so the FENCE does not stall.
    dut_if.set_sq_committed_empty(True)
    model.sq_committed_empty = True

    await ClockCycles(dut_if.clock, 5)
    await FallingEdge(dut_if.clock)
    assert dut_if.empty, "FENCE should commit when committed_empty=true"

    cocotb.log.info("=== Test Passed ===")

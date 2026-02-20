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

"""Integration tests for the Tomasulo wrapper (ROB + RAT + RS).

Ports the original rob_rat_wrapper tests and adds RS integration tests
exercising the full dispatch -> wakeup -> issue -> commit pipeline.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

from .tomasulo_interface import TomasuloInterface
from .tomasulo_model import TomasuloModel

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
)
from cocotb_tests.tomasulo.register_alias_table.rat_model import (
    LookupResult,
)

NUM_CHECKPOINTS = 4


# =============================================================================
# Helpers
# =============================================================================


def make_int_req(
    pc: int = 0x1000,
    rd: int = 1,
    is_branch: bool = False,
    predicted_taken: bool = False,
    predicted_target: int = 0,
) -> AllocationRequest:
    """Create an integer register allocation request."""
    return AllocationRequest(
        pc=pc,
        dest_rf=0,
        dest_reg=rd,
        dest_valid=True,
        is_branch=is_branch,
        predicted_taken=predicted_taken,
        predicted_target=predicted_target,
    )


def make_fp_req(pc: int = 0x1000, fd: int = 1) -> AllocationRequest:
    """Create a floating-point register allocation request."""
    return AllocationRequest(pc=pc, dest_rf=1, dest_reg=fd, dest_valid=True)


def make_store_req(pc: int = 0x1000) -> AllocationRequest:
    """Create a store instruction allocation request."""
    return AllocationRequest(pc=pc, is_store=True, dest_valid=False)


def make_branch_req(
    pc: int = 0x1000,
    rd: int = 0,
    predicted_taken: bool = True,
    predicted_target: int = 0x2000,
) -> AllocationRequest:
    """Create a branch instruction allocation request."""
    return AllocationRequest(
        pc=pc,
        dest_rf=0,
        dest_reg=rd,
        dest_valid=(rd != 0),
        is_branch=True,
        predicted_taken=predicted_taken,
        predicted_target=predicted_target,
    )


def log_random_seed() -> int:
    """Generate, log, and return a random seed for reproducibility."""
    seed = random.getrandbits(32)
    random.seed(seed)
    cocotb.log.info(f"Random seed: {seed}")
    return seed


async def setup_test(dut: Any) -> tuple[TomasuloInterface, TomasuloModel]:
    """Initialize clock, interface, model and reset DUT."""
    clock = Clock(dut.i_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    dut_if = TomasuloInterface(dut)
    model = TomasuloModel()
    await dut_if.reset_dut()
    return dut_if, model


def check_rat_lookup(result: LookupResult, expected: LookupResult, label: str) -> None:
    """Assert RAT lookup result matches expected."""
    assert (
        result.renamed == expected.renamed
    ), f"{label}: renamed mismatch DUT={result.renamed} model={expected.renamed}"
    if expected.renamed:
        assert (
            result.tag == expected.tag
        ), f"{label}: tag mismatch DUT={result.tag} model={expected.tag}"


async def wait_for_commit(dut_if: TomasuloInterface, max_cycles: int = 20) -> dict:
    """Wait for a valid commit, raising TimeoutError if not seen."""
    for _ in range(max_cycles):
        await RisingEdge(dut_if.clock)
        commit = dut_if.read_commit()
        if commit["valid"]:
            await FallingEdge(dut_if.clock)
            return commit
    raise TimeoutError("No commit observed within timeout")


# =============================================================================
# Ported ROB-RAT Tests (backward compatibility)
# =============================================================================


@cocotb.test()
async def test_dispatch_and_commit_clears_rat(dut: Any) -> None:
    """Commit bus wire: dispatch INT instr -> CDB write -> commit -> RAT cleared."""
    cocotb.log.info("=== Test: Dispatch and Commit Clears RAT ===")
    dut_if, model = await setup_test(dut)

    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    dut_if.set_int_src1(5, 0xAAAA)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed and result.tag == tag

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag, value=0xDEADBEEF))
    model.cdb_write(CDBWrite(tag=tag, value=0xDEADBEEF))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["valid"] and commit["tag"] == tag

    dut_if.set_int_src1(5, 0xBBBB)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0xBBBB)
    check_rat_lookup(result, expected, "x5 after commit")
    assert not result.renamed

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_waw_commit_preserves_newer_rename(dut: Any) -> None:
    """Tag-match guard: dispatch A(x5,T0), dispatch B(x5,T1), commit A -> RAT still T1."""
    cocotb.log.info("=== Test: WAW Commit Preserves Newer Rename ===")
    dut_if, model = await setup_test(dut)

    req_a = make_int_req(pc=0x1000, rd=5)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)
    req_b = make_int_req(pc=0x1004, rd=5)
    tag_b = await dut_if.dispatch(req_b)
    model.dispatch(req_b)

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    model.cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await wait_for_commit(dut_if)
    model.try_commit()

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after A commits")
    assert result.renamed and result.tag == tag_b

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rename_and_commit_same_cycle_priority(dut: Any) -> None:
    """Rename > commit on same register in same cycle."""
    cocotb.log.info("=== Test: Rename and Commit Same Cycle Priority ===")
    dut_if, model = await setup_test(dut)

    req_a = make_int_req(pc=0x1000, rd=5)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    model.cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    req_b = make_int_req(pc=0x1004, rd=5)
    dut_if.drive_alloc_request(req_b)
    _, tag_b, _ = dut_if.read_alloc_response()
    dut_if.drive_rat_rename(0, 5, tag_b)
    model.dispatch(req_b)
    await RisingEdge(dut_if.clock)
    model.try_commit()
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    dut_if.clear_rat_rename()

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after same-cycle rename+commit")
    assert result.renamed and result.tag == tag_b

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_checkpoint_save_and_correct_commit(dut: Any) -> None:
    """Full checkpoint lifecycle: save -> correct prediction -> commit frees checkpoint."""
    cocotb.log.info("=== Test: Branch Checkpoint Save and Correct Commit ===")
    dut_if, model = await setup_test(dut)

    req = make_branch_req(pc=0x1000, predicted_taken=True, predicted_target=0x2000)
    tag = await dut_if.dispatch(req, checkpoint_save=True)
    model.dispatch(req, checkpoint_save=True)

    await FallingEdge(dut_if.clock)
    update = BranchUpdate(tag=tag, taken=True, target=0x2000, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["valid"] and commit["has_checkpoint"] and not commit["misprediction"]

    cp_id = commit["checkpoint_id"]
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_free(cp_id)
    model.rat.checkpoint_free(cp_id)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_free()

    assert dut_if.checkpoint_available

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_misprediction_recovery(dut: Any) -> None:
    """Dispatch, checkpoint, post-branch renames, misprediction -> recover."""
    cocotb.log.info("=== Test: Branch Misprediction Recovery ===")
    dut_if, model = await setup_test(dut)

    req_pre = make_int_req(pc=0x1000, rd=5)
    tag_pre = await dut_if.dispatch(req_pre)
    model.dispatch(req_pre)

    req_br = make_branch_req(pc=0x1004, predicted_taken=True, predicted_target=0x3000)
    cp_id = dut_if.checkpoint_alloc_id
    tag_br = await dut_if.dispatch(req_br, checkpoint_save=True)
    model.dispatch(req_br, checkpoint_save=True)

    req_post = make_int_req(pc=0x3000, rd=5)
    await dut_if.dispatch(req_post)
    model.dispatch(req_post)

    await FallingEdge(dut_if.clock)
    update = BranchUpdate(tag=tag_br, taken=False, target=0x1008, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    dut_if.drive_flush_en(tag_br)
    dut_if.drive_checkpoint_restore(cp_id)
    model.misprediction_recovery(cp_id, tag_br)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_flush_en()
    dut_if.clear_checkpoint_restore()

    assert dut_if.rob_count == 2

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after recovery")
    assert result.renamed and result.tag == tag_pre

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_multiple_branches_checkpoint_exhaustion(dut: Any) -> None:
    """4 branches exhaust checkpoints."""
    cocotb.log.info("=== Test: Checkpoint Exhaustion ===")
    dut_if, model = await setup_test(dut)

    for i in range(NUM_CHECKPOINTS):
        req = make_branch_req(
            pc=0x1000 + i * 4, predicted_taken=True, predicted_target=0x2000 + i * 0x100
        )
        await dut_if.dispatch(req, checkpoint_save=True)
        model.dispatch(req, checkpoint_save=True)

    assert not dut_if.checkpoint_available

    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_free(0)
    model.rat.checkpoint_free(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_free()
    assert dut_if.checkpoint_available

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_full_flush_clears_all(dut: Any) -> None:
    """flush_all clears ROB + RAT + RS."""
    cocotb.log.info("=== Test: Full Flush Clears All ===")
    dut_if, model = await setup_test(dut)

    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Also put something in RS
    dut_if.drive_rs_dispatch(
        rob_tag=tag, op=0, src1_ready=False, src1_tag=10, src3_ready=True
    )
    model.rs_dispatch(rob_tag=tag, op=0, src1_ready=False, src1_tag=10, src3_ready=True)
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    assert not dut_if.rs_empty
    assert not dut_if.rob_empty

    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.rob_empty
    assert dut_if.rs_empty  # type: ignore[unreachable]
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_int_src1().renamed

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fp_dispatch_commit_clears_fp_rat(dut: Any) -> None:
    """FP dest_rf=1 propagates correctly through commit bus."""
    cocotb.log.info("=== Test: FP Dispatch/Commit Clears FP RAT ===")
    dut_if, model = await setup_test(dut)

    req = make_fp_req(pc=0x2000, fd=3)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    dut_if.set_fp_src1(3, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_fp_src1().renamed

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag, value=0x4000000000000000))
    model.cdb_write(CDBWrite(tag=tag, value=0x4000000000000000))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["dest_rf"] == 1

    dut_if.set_fp_src1(3, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_fp_src1().renamed

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_store_commit_no_rat_effect(dut: Any) -> None:
    """dest_valid=0 prevents RAT modification for stores."""
    cocotb.log.info("=== Test: Store Commit No RAT Effect ===")
    dut_if, model = await setup_test(dut)

    req_alu = make_int_req(pc=0x1000, rd=5)
    tag_alu = await dut_if.dispatch(req_alu)
    model.dispatch(req_alu)

    req_st = make_store_req(pc=0x1004)
    tag_st = await dut_if.dispatch(req_st)
    model.dispatch(req_st)

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_alu, value=0x1234))
    model.cdb_write(CDBWrite(tag=tag_alu, value=0x1234))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_st, value=0))
    model.cdb_write(CDBWrite(tag=tag_st, value=0))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    for _ in range(20):
        await RisingEdge(dut_if.clock)
        if dut_if.rob_empty:
            break
    await FallingEdge(dut_if.clock)

    while model.rob.can_commit():
        model.try_commit()

    assert dut_if.rob_empty

    dut_if.set_int_src1(5, 0x9999)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x9999)
    check_rat_lookup(result, expected, "x5 after store commit")
    assert not result.renamed

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_x0_destination_invariant(dut: Any) -> None:
    """x0 remains hardwired zero."""
    cocotb.log.info("=== Test: x0 Destination Invariant ===")
    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x1000, dest_rf=0, dest_reg=0, dest_valid=False)
    await dut_if.dispatch(req)
    model.dispatch(req)

    dut_if.set_int_src1(0, 0xFFFFFFFF)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert not result.renamed and result.value == 0

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# New RS Integration Tests
# =============================================================================


@cocotb.test()
async def test_dispatch_through_rob_rat_rs(dut: Any) -> None:
    """Dispatch allocates ROB tag, renames in RAT, dispatches to RS."""
    cocotb.log.info("=== Test: Dispatch Through ROB+RAT+RS ===")
    dut_if, model = await setup_test(dut)

    # Dispatch to ROB + RAT
    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Dispatch to RS with that tag, src1 ready, src2 pending
    dut_if.drive_rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=False,
        src2_tag=10,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=False,
        src2_tag=10,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    assert dut_if.rs_count == 1
    assert dut_if.rob_count == 1

    # RS should not issue (src2 not ready)
    dut_if.set_rs_fu_ready(True)
    assert not dut_if.rs_issue_valid

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_wakes_rs_and_completes_rob(dut: Any) -> None:
    """Single CDB broadcast simultaneously wakes RS and marks ROB done."""
    cocotb.log.info("=== Test: CDB Wakes RS and Completes ROB ===")
    dut_if, model = await setup_test(dut)

    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # RS entry: src1 waiting on some other tag
    dut_if.drive_rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=False,
        src1_tag=tag,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=False,
        src1_tag=tag,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # CDB broadcast: wakes RS src1 AND marks ROB entry done
    dut_if.drive_cdb(tag=tag, value=0xCAFE)
    model.cdb_write_and_snoop(tag=tag, value=0xCAFE)
    await dut_if.step()
    dut_if.clear_cdb()

    # RS should now be ready to issue
    dut_if.set_rs_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_rs_issue()
    assert issue["valid"], "RS should issue after CDB wakeup"
    assert issue["rob_tag"] == tag

    # ROB head should be done
    assert dut_if.head_done, "ROB head should be done after CDB"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_full_pipeline_cycle(dut: Any) -> None:
    """Dispatch -> RS wakeup via CDB -> RS issue -> CDB result -> commit."""
    cocotb.log.info("=== Test: Full Pipeline Cycle ===")
    dut_if, model = await setup_test(dut)

    # 1. Dispatch instruction to ROB + RAT + RS
    req = make_int_req(pc=0x1000, rd=7)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # RS dispatch: src1 not ready (waiting on some producer tag 20)
    dut_if.drive_rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=False,
        src1_tag=20,
        src2_ready=True,
        src2_value=0x42,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=False,
        src1_tag=20,
        src2_ready=True,
        src2_value=0x42,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # 2. CDB from producer (tag 20) wakes RS src1
    dut_if.drive_cdb_broadcast(tag=20, value=0xAAAA)
    model.rs.cdb_snoop(tag=20, value=0xAAAA)
    await dut_if.step()
    dut_if.clear_cdb_broadcast()

    # 3. RS issues
    dut_if.set_rs_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_rs_issue()
    assert issue["valid"], "RS should issue"
    assert issue["rob_tag"] == tag
    model_issue = model.rs_try_issue(fu_ready=True)
    assert model_issue is not None

    await dut_if.step()
    assert dut_if.rs_empty, "RS should be empty after issue"

    # 4. FU produces result -> CDB -> ROB done
    dut_if.drive_cdb(tag=tag, value=0xBEEF)
    model.cdb_write(CDBWrite(tag=tag, value=0xBEEF))
    await dut_if.step()
    dut_if.clear_cdb()

    # 5. ROB commits -> RAT clears
    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["valid"] and commit["tag"] == tag

    dut_if.set_int_src1(7, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(7, 0)
    check_rat_lookup(result, expected, "x7 after full pipeline")
    assert not result.renamed, "x7 should be cleared after commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_flush_coherence_across_modules(dut: Any) -> None:
    """Partial flush invalidates RS and ROB entries, restores RAT checkpoint."""
    cocotb.log.info("=== Test: Flush Coherence Across Modules ===")
    dut_if, model = await setup_test(dut)

    # Pre-branch instruction
    req_pre = make_int_req(pc=0x1000, rd=5)
    tag_pre = await dut_if.dispatch(req_pre)
    model.dispatch(req_pre)

    # Branch with checkpoint
    req_br = make_branch_req(pc=0x1004, predicted_taken=True, predicted_target=0x3000)
    cp_id = dut_if.checkpoint_alloc_id
    tag_br = await dut_if.dispatch(req_br, checkpoint_save=True)
    model.dispatch(req_br, checkpoint_save=True)

    # Post-branch instruction dispatched to RS too
    req_post = make_int_req(pc=0x3000, rd=5)
    tag_post = await dut_if.dispatch(req_post)
    model.dispatch(req_post)

    # RS dispatch for post-branch instruction
    dut_if.drive_rs_dispatch(
        rob_tag=tag_post,
        op=0,
        src1_ready=True,
        src1_value=0x1,
        src2_ready=True,
        src2_value=0x2,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag_post,
        op=0,
        src1_ready=True,
        src1_value=0x1,
        src2_ready=True,
        src2_value=0x2,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    assert dut_if.rs_count == 1

    # Branch mispredicts
    update = BranchUpdate(tag=tag_br, taken=False, target=0x1008, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await dut_if.step()
    dut_if.clear_branch_update()

    # Partial flush + checkpoint restore
    dut_if.drive_flush_en(tag_br)
    dut_if.drive_checkpoint_restore(cp_id)
    model.misprediction_recovery(cp_id, tag_br)
    await dut_if.step()
    dut_if.clear_flush_en()
    dut_if.clear_checkpoint_restore()

    # RS should be empty (post-branch entry flushed)
    assert dut_if.rs_empty, "RS should be empty after partial flush"
    # ROB should have 2 (pre-branch + branch)
    assert dut_if.rob_count == 2
    # RAT restored
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after flush")
    assert result.renamed and result.tag == tag_pre

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rs_full_stalls_dispatch(dut: Any) -> None:
    """RS full signal prevents further dispatch."""
    cocotb.log.info("=== Test: RS Full Stalls Dispatch ===")
    dut_if, model = await setup_test(dut)

    # Fill RS with 8 entries
    for i in range(8):
        dut_if.drive_rs_dispatch(
            rob_tag=i,
            op=0,
            src1_ready=False,
            src1_tag=20,
            src2_ready=False,
            src2_tag=21,
            src3_ready=True,
        )
        model.rs_dispatch(
            rob_tag=i,
            op=0,
            src1_ready=False,
            src1_tag=20,
            src2_ready=False,
            src2_tag=21,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_rs_dispatch()

    assert dut_if.rs_full, "RS should be full"
    assert model.rs.is_full()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rob_bypass_read_with_rs_state(dut: Any) -> None:
    """ROB bypass read and RS state consistency."""
    cocotb.log.info("=== Test: ROB Bypass Read with RS State ===")
    dut_if, model = await setup_test(dut)

    req = make_int_req(pc=0x1000, rd=8)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Put in RS
    dut_if.drive_rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=True,
        src1_value=0x100,
        src2_ready=True,
        src2_value=0x200,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=True,
        src1_value=0x100,
        src2_ready=True,
        src2_value=0x200,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # RS has the entry, ROB entry is NOT done yet
    dut_if.set_read_tag(tag)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_entry_done(), "ROB entry should not be done yet"

    # Issue from RS
    dut_if.set_rs_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_rs_issue()
    assert issue["valid"], "RS should issue"

    await dut_if.step()
    assert dut_if.rs_empty

    # Complete via CDB -> ROB done
    dut_if.drive_cdb(tag=tag, value=0xDEAD)
    model.cdb_write(CDBWrite(tag=tag, value=0xDEAD))
    await dut_if.step()
    dut_if.clear_cdb()

    # Now ROB bypass read should show done
    dut_if.set_read_tag(tag)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_entry_done(), "ROB entry should be done now"
    assert dut_if.read_entry_value() == 0xDEAD

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_random_dispatch_execute_commit(dut: Any) -> None:
    """Constrained random: dispatch, RS dispatch, CDB, issue, commit, flush."""
    cocotb.log.info("=== Test: Random Dispatch/Execute/Commit ===")
    seed = log_random_seed()
    dut_if, model = await setup_test(dut)

    dut_if.set_rs_fu_ready(True)
    await Timer(1, unit="ps")  # Let fu_ready propagate
    num_dispatches = 0
    prev_was_flush = False
    pending_tags: set[int] = set()  # Track valid ROB tags for safe CDB

    for cycle in range(200):
        # Read DUT state BEFORE try_issue (matches RTL's registered state)
        dut_rob_full = dut_if.rob_full
        dut_rs_full = dut_if.rs_full

        # Check RS issue from settled state (skip after flush cycles)
        if not prev_was_flush:
            issue = dut_if.read_rs_issue()
            model_issue = model.rs_try_issue(fu_ready=True)
            if model_issue is not None:
                assert issue["valid"], f"Cycle {cycle}: model issued but DUT did not"

        # Auto-commit ROB head if done (one per cycle, matching DUT rate)
        c = model.try_commit()
        if c is not None and c["valid"]:
            pending_tags.discard(c["tag"])

        r = random.random()
        prev_was_flush = False

        # Dispatch + RS dispatch (~35%)
        # Drive ROB alloc + RAT rename + RS dispatch all before a SINGLE
        # clock edge so the DUT processes them atomically (avoids the extra
        # edge that dut_if.dispatch() would introduce).
        if r < 0.35 and not dut_rob_full and not dut_rs_full:
            ready, tag, _ = dut_if.read_alloc_response()
            if ready:
                rd = random.randint(1, 31)
                req = make_int_req(pc=0x1000 + num_dispatches * 4, rd=rd)

                # Drive ROB alloc + RAT rename
                dut_if.drive_alloc_request(req)
                if req.dest_valid:
                    dut_if.drive_rat_rename(req.dest_rf, req.dest_reg, tag)
                model.dispatch(req)
                pending_tags.add(tag)

                # Drive RS dispatch in the same cycle
                src1_ready = random.choice([True, False])
                src2_ready = random.choice([True, False])
                src1_tag = random.randint(0, 31)
                src2_tag = random.randint(0, 31)
                src1_value = random.getrandbits(64) if src1_ready else 0
                src2_value = random.getrandbits(64) if src2_ready else 0

                dut_if.drive_rs_dispatch(
                    rob_tag=tag,
                    op=0,
                    src1_ready=src1_ready,
                    src1_tag=src1_tag,
                    src1_value=src1_value,
                    src2_ready=src2_ready,
                    src2_tag=src2_tag,
                    src2_value=src2_value,
                    src3_ready=True,
                )
                model.rs_dispatch(
                    rob_tag=tag,
                    op=0,
                    src1_ready=src1_ready,
                    src1_tag=src1_tag,
                    src1_value=src1_value,
                    src2_ready=src2_ready,
                    src2_tag=src2_tag,
                    src2_value=src2_value,
                    src3_ready=True,
                )
                await dut_if.step()
                dut_if.clear_alloc_request()
                dut_if.clear_rat_rename()
                dut_if.clear_rs_dispatch()
                num_dispatches += 1
            else:
                await dut_if.step()

        # CDB broadcast to a valid ROB entry (~30%)
        elif r < 0.65 and pending_tags:
            cdb_tag = random.choice(list(pending_tags))
            cdb_value = random.getrandbits(64)
            dut_if.drive_cdb(tag=cdb_tag, value=cdb_value)
            model.cdb_write_and_snoop(tag=cdb_tag, value=cdb_value)
            pending_tags.discard(cdb_tag)  # An instruction completes only once
            await dut_if.step()
            dut_if.clear_cdb()

        # Flush all (~5%)
        elif r < 0.70:
            prev_was_flush = True
            dut_if.drive_flush_all()
            model.flush_all()
            pending_tags.clear()
            await dut_if.step()
            dut_if.clear_flush_all()

        # Idle (~30%)
        else:
            await dut_if.step()

    # Final: flush and verify clean state
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.rob_empty
    assert dut_if.rs_empty

    cocotb.log.info(f"=== Test Passed ({num_dispatches} dispatches, seed={seed}) ===")

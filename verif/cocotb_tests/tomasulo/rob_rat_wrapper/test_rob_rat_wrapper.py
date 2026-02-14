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

"""Integration tests for the ROB-RAT wrapper.

Exercises the cross-module commit bus, checkpoint lifecycle, flush
propagation, WAW hazards, and misprediction recovery — interactions
that unit tests on each module individually cannot catch.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

from .rob_rat_interface import RobRatInterface
from .rob_rat_model import RobRatModel

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
    MASK32,
    MASK64,
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
    """Create a simple INT ALU allocation request with dest_valid=True."""
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
    """Create a simple FP allocation request with dest_valid=True, dest_rf=1."""
    return AllocationRequest(
        pc=pc,
        dest_rf=1,
        dest_reg=fd,
        dest_valid=True,
    )


def make_store_req(pc: int = 0x1000) -> AllocationRequest:
    """Create a store request (no destination register)."""
    return AllocationRequest(
        pc=pc,
        is_store=True,
        dest_valid=False,
    )


def make_branch_req(
    pc: int = 0x1000,
    rd: int = 0,
    predicted_taken: bool = True,
    predicted_target: int = 0x2000,
) -> AllocationRequest:
    """Create a branch allocation request."""
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
    """Log and return the random seed for reproducibility."""
    seed = random.getrandbits(32)
    random.seed(seed)
    cocotb.log.info(f"Random seed: {seed}")
    return seed


async def setup_test(dut: Any) -> tuple[RobRatInterface, RobRatModel]:
    """Set up test with clock, reset, and return interface and model."""
    clock = Clock(dut.i_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut_if = RobRatInterface(dut)
    model = RobRatModel()
    await dut_if.reset_dut()

    return dut_if, model


def check_rat_lookup(result: LookupResult, expected: LookupResult, label: str) -> None:
    """Assert RAT lookup matches expected."""
    assert (
        result.renamed == expected.renamed
    ), f"{label}: renamed mismatch DUT={result.renamed} model={expected.renamed}"
    if expected.renamed:
        assert (
            result.tag == expected.tag
        ), f"{label}: tag mismatch DUT={result.tag} model={expected.tag}"


async def wait_for_commit(dut_if: RobRatInterface, max_cycles: int = 20) -> dict:
    """Wait until a valid commit appears, return commit info."""
    for _ in range(max_cycles):
        await RisingEdge(dut_if.clock)
        commit = dut_if.read_commit()
        if commit["valid"]:
            await FallingEdge(dut_if.clock)
            return commit
    raise TimeoutError("No commit observed within timeout")


# =============================================================================
# Test 1: Dispatch and commit clears RAT
# =============================================================================


@cocotb.test()
async def test_dispatch_and_commit_clears_rat(dut: Any) -> None:
    """Commit bus wire: dispatch INT instr -> CDB write -> commit -> RAT entry cleared."""
    cocotb.log.info("=== Test: Dispatch and Commit Clears RAT ===")

    dut_if, model = await setup_test(dut)

    # Dispatch INT instruction writing to x5
    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Verify RAT shows x5 renamed
    dut_if.set_int_src1(5, 0xAAAA)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0xAAAA)
    check_rat_lookup(result, expected, "x5 after dispatch")
    assert result.renamed, "x5 should be renamed after dispatch"
    assert result.tag == tag, f"x5 tag should be {tag}"

    # CDB write to mark done
    await FallingEdge(dut_if.clock)
    cdb = CDBWrite(tag=tag, value=0xDEADBEEF)
    dut_if.drive_cdb_write(cdb)
    model.cdb_write(cdb)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Wait for commit (commit bus propagates to RAT automatically)
    commit = await wait_for_commit(dut_if)
    model.try_commit()

    assert commit["valid"], "Commit should be valid"
    assert commit["tag"] == tag, f"Commit tag mismatch: {commit['tag']} != {tag}"
    assert commit["dest_reg"] == 5, "Commit dest_reg should be 5"
    assert commit["dest_valid"], "Commit dest_valid should be true"

    # Verify RAT x5 is now cleared (commit bus tag matches)
    dut_if.set_int_src1(5, 0xBBBB)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0xBBBB)
    check_rat_lookup(result, expected, "x5 after commit")
    assert not result.renamed, "x5 should NOT be renamed after commit"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 2: WAW commit preserves newer rename
# =============================================================================


@cocotb.test()
async def test_waw_commit_preserves_newer_rename(dut: Any) -> None:
    """Tag-match guard: dispatch A(x5,T0), dispatch B(x5,T1), commit A -> RAT still T1."""
    cocotb.log.info("=== Test: WAW Commit Preserves Newer Rename ===")

    dut_if, model = await setup_test(dut)

    # Dispatch A: x5 -> T0
    req_a = make_int_req(pc=0x1000, rd=5)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)

    # Dispatch B: x5 -> T1 (overwrites rename)
    req_b = make_int_req(pc=0x1004, rd=5)
    tag_b = await dut_if.dispatch(req_b)
    model.dispatch(req_b)

    assert tag_a != tag_b, "Tags should be different"

    # Verify RAT shows T1 for x5
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed and result.tag == tag_b, f"x5 should show T1={tag_b}"

    # Complete A via CDB and let it commit
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    model.cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Wait for A to commit
    await wait_for_commit(dut_if)
    model.try_commit()

    # After committing A, x5 should STILL show T1 (tag mismatch prevents clear)
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after A commits")
    assert result.renamed, "x5 should still be renamed (WAW protection)"
    assert result.tag == tag_b, f"x5 should still show T1={tag_b}"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 3: Rename and commit same cycle priority
# =============================================================================


@cocotb.test()
async def test_rename_and_commit_same_cycle_priority(dut: Any) -> None:
    """Rename > commit on same register in same cycle."""
    cocotb.log.info("=== Test: Rename and Commit Same Cycle Priority ===")

    dut_if, model = await setup_test(dut)

    # Dispatch first instruction to x5 -> T0
    req_a = make_int_req(pc=0x1000, rd=5)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)

    # Complete A so it can commit
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    model.cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Now on the same falling edge, dispatch B to x5 (rename) while A commits
    # A's commit goes through the commit bus; B's rename writes to RAT.
    # The rename should win (higher priority) — x5 should show new tag.
    req_b = make_int_req(pc=0x1004, rd=5)
    # Drive alloc for B and RAT rename simultaneously
    dut_if.drive_alloc_request(req_b)
    _, tag_b, _ = dut_if.read_alloc_response()
    dut_if.drive_rat_rename(0, 5, tag_b)
    model.dispatch(req_b)
    # Let commit and rename happen on same rising edge
    # The commit from A's CDB write should appear this cycle
    await RisingEdge(dut_if.clock)
    # We need to process model commit for A here
    model.try_commit()
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    dut_if.clear_rat_rename()

    # Check: x5 should be renamed to tag_b (rename wins over commit clear)
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after same-cycle rename+commit")
    assert result.renamed, "x5 should be renamed (rename wins over commit)"
    assert result.tag == tag_b, f"x5 should show new tag {tag_b}"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 4: Branch checkpoint save and correct commit
# =============================================================================


@cocotb.test()
async def test_branch_checkpoint_save_and_correct_commit(dut: Any) -> None:
    """Full checkpoint lifecycle: save -> correct prediction -> commit frees checkpoint."""
    cocotb.log.info("=== Test: Branch Checkpoint Save and Correct Commit ===")

    dut_if, model = await setup_test(dut)

    # Dispatch branch with checkpoint save
    req = make_branch_req(pc=0x1000, predicted_taken=True, predicted_target=0x2000)
    tag = await dut_if.dispatch(req, checkpoint_save=True)
    model.dispatch(req, checkpoint_save=True)

    # Verify checkpoint was consumed
    avail_model, _ = model.checkpoint_available()
    assert dut_if.checkpoint_available == avail_model

    # Resolve branch correctly (not mispredicted)
    await FallingEdge(dut_if.clock)
    update = BranchUpdate(tag=tag, taken=True, target=0x2000, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    # Wait for commit
    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["valid"], "Branch should commit"
    assert commit["has_checkpoint"], "Branch should have checkpoint"
    assert not commit["misprediction"], "Branch should not be mispredicted"

    # Free the checkpoint (normally done by flush controller on correct branch)
    cp_id = commit["checkpoint_id"]
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_free(cp_id)
    model.rat.checkpoint_free(cp_id)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_free()

    # Verify all checkpoints are free again
    avail_model, _ = model.checkpoint_available()
    assert dut_if.checkpoint_available == avail_model
    assert dut_if.checkpoint_available, "All checkpoints should be free"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 5: Branch misprediction recovery
# =============================================================================


@cocotb.test()
async def test_branch_misprediction_recovery(dut: Any) -> None:
    """End-to-end: dispatch, checkpoint, post-branch renames, misprediction -> recover."""
    cocotb.log.info("=== Test: Branch Misprediction Recovery ===")

    dut_if, model = await setup_test(dut)

    # Pre-branch: rename x5 -> T0
    req_pre = make_int_req(pc=0x1000, rd=5)
    tag_pre = await dut_if.dispatch(req_pre)
    model.dispatch(req_pre)

    # Dispatch branch with checkpoint
    req_br = make_branch_req(pc=0x1004, predicted_taken=True, predicted_target=0x3000)
    cp_id = dut_if.checkpoint_alloc_id
    tag_br = await dut_if.dispatch(req_br, checkpoint_save=True)
    model.dispatch(req_br, checkpoint_save=True)

    # Post-branch renames (speculative)
    req_post1 = make_int_req(pc=0x3000, rd=5)  # Overwrite x5
    tag_post1 = await dut_if.dispatch(req_post1)
    model.dispatch(req_post1)

    req_post2 = make_int_req(pc=0x3004, rd=6)
    await dut_if.dispatch(req_post2)
    model.dispatch(req_post2)

    # Verify x5 shows post-branch tag
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed and result.tag == tag_post1, "x5 should show post-branch tag"

    # Branch mispredicts! Resolve with misprediction
    await FallingEdge(dut_if.clock)
    update = BranchUpdate(tag=tag_br, taken=False, target=0x1008, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    # Perform recovery: partial flush (entries after branch) + RAT restore
    dut_if.drive_flush_en(tag_br)
    dut_if.drive_checkpoint_restore(cp_id)
    model.misprediction_recovery(cp_id, tag_br)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_flush_en()
    dut_if.clear_checkpoint_restore()

    # Verify ROB flushed post-branch entries
    assert (
        dut_if.rob_count == 2
    ), f"ROB should have 2 entries (pre-branch + branch), got {dut_if.rob_count}"

    # Verify RAT restored: x5 should be at pre-branch tag, x6 not renamed
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after recovery")
    assert (
        result.renamed and result.tag == tag_pre
    ), f"x5 should be restored to pre-branch tag {tag_pre}, got {result.tag}"

    dut_if.set_int_src1(6, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(6, 0)
    check_rat_lookup(result, expected, "x6 after recovery")
    assert not result.renamed, "x6 should not be renamed after recovery"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 6: Checkpoint exhaustion
# =============================================================================


@cocotb.test()
async def test_multiple_branches_checkpoint_exhaustion(dut: Any) -> None:
    """4 branches exhaust checkpoints, verify o_checkpoint_available goes false."""
    cocotb.log.info("=== Test: Multiple Branches Checkpoint Exhaustion ===")

    dut_if, model = await setup_test(dut)

    # Dispatch 4 branches, each saving a checkpoint
    tags = []
    for i in range(NUM_CHECKPOINTS):
        req = make_branch_req(
            pc=0x1000 + i * 4,
            predicted_taken=True,
            predicted_target=0x2000 + i * 0x100,
        )
        tag = await dut_if.dispatch(req, checkpoint_save=True)
        model.dispatch(req, checkpoint_save=True)
        tags.append(tag)

    # Verify checkpoints exhausted
    assert not dut_if.checkpoint_available, "All checkpoints should be exhausted"
    avail_model, _ = model.checkpoint_available()
    assert not avail_model, "Model should also show exhausted"

    # Free one checkpoint — should become available again
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_free(0)
    model.rat.checkpoint_free(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_free()

    cp_avail: bool = dut_if.checkpoint_available
    assert cp_avail, "Checkpoint should be available after free"
    avail_after_free, _ = model.checkpoint_available()
    assert avail_after_free

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 7: Full flush clears both
# =============================================================================


@cocotb.test()
async def test_full_flush_clears_both(dut: Any) -> None:
    """i_flush_all clears ROB + RAT + checkpoints simultaneously."""
    cocotb.log.info("=== Test: Full Flush Clears Both ===")

    dut_if, model = await setup_test(dut)

    # Seed some state in both modules
    req1 = make_int_req(pc=0x1000, rd=5)
    await dut_if.dispatch(req1)
    model.dispatch(req1)

    req2 = make_fp_req(pc=0x1004, fd=3)
    await dut_if.dispatch(req2)
    model.dispatch(req2)

    req3 = make_branch_req(pc=0x1008)
    await dut_if.dispatch(req3, checkpoint_save=True)
    model.dispatch(req3, checkpoint_save=True)

    # Verify state exists
    assert dut_if.rob_count == 3
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_int_src1().renamed

    # Full flush
    await FallingEdge(dut_if.clock)
    dut_if.drive_flush_all()
    model.flush_all()
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_flush_all()

    # Verify ROB is empty
    assert dut_if.rob_empty, "ROB should be empty after flush"
    assert dut_if.rob_count == 0, "ROB count should be 0"

    # Verify RAT cleared
    dut_if.set_int_src1(5, 0xAA)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0xAA)
    check_rat_lookup(result, expected, "x5 after flush")
    assert not result.renamed, "x5 should not be renamed after flush"

    dut_if.set_fp_src1(3, 0xBB)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    expected = model.lookup_fp(3, 0xBB)
    check_rat_lookup(result, expected, "f3 after flush")
    assert not result.renamed, "f3 should not be renamed after flush"

    # Verify checkpoints freed
    assert dut_if.checkpoint_available, "Checkpoints should be available after flush"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 8: FP dispatch/commit clears FP RAT
# =============================================================================


@cocotb.test()
async def test_fp_dispatch_commit_clears_fp_rat(dut: Any) -> None:
    """dest_rf=1 propagates correctly through commit bus for FP registers."""
    cocotb.log.info("=== Test: FP Dispatch/Commit Clears FP RAT ===")

    dut_if, model = await setup_test(dut)

    # Dispatch FP instruction: f3 -> T0
    req = make_fp_req(pc=0x2000, fd=3)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Verify FP RAT shows f3 renamed
    dut_if.set_fp_src1(3, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    assert result.renamed and result.tag == tag, "f3 should be renamed"

    # CDB write + wait for commit
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag, value=0x4000000000000000))
    model.cdb_write(CDBWrite(tag=tag, value=0x4000000000000000))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    commit = await wait_for_commit(dut_if)
    model.try_commit()

    assert commit["dest_rf"] == 1, "Commit dest_rf should be 1 (FP)"
    assert commit["dest_reg"] == 3
    assert commit["dest_valid"]

    # Verify FP RAT f3 cleared
    dut_if.set_fp_src1(3, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    expected = model.lookup_fp(3, 0)
    check_rat_lookup(result, expected, "f3 after FP commit")
    assert not result.renamed, "f3 should not be renamed after FP commit"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 9: Store commit no RAT effect
# =============================================================================


@cocotb.test()
async def test_store_commit_no_rat_effect(dut: Any) -> None:
    """dest_valid=0 correctly prevents RAT modification for stores."""
    cocotb.log.info("=== Test: Store Commit No RAT Effect ===")

    dut_if, model = await setup_test(dut)

    # Rename x5 first
    req_alu = make_int_req(pc=0x1000, rd=5)
    tag_alu = await dut_if.dispatch(req_alu)
    model.dispatch(req_alu)

    # Dispatch a store (dest_valid=0)
    req_st = make_store_req(pc=0x1004)
    tag_st = await dut_if.dispatch(req_st)
    model.dispatch(req_st)

    # Complete both entries via CDB in a single cycle so they're both done
    # before either commits. This avoids timing issues where a commit slips
    # through an unobserved rising edge between separate CDB writes.
    # ROB only has one CDB port, so complete ALU first, then store.
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_alu, value=0x1234))
    model.cdb_write(CDBWrite(tag=tag_alu, value=0x1234))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    # Immediately drive store CDB (no extra cycle gap)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_st, value=0))
    model.cdb_write(CDBWrite(tag=tag_st, value=0))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # Wait for ROB to drain completely (both ALU and store commit in-order)
    for _ in range(20):
        await RisingEdge(dut_if.clock)
        if dut_if.rob_empty:
            break
    await FallingEdge(dut_if.clock)

    # Process both commits in model
    while model.rob.can_commit():
        model.try_commit()

    assert dut_if.rob_empty, "ROB should be empty after both commits"

    # Verify x5 is no longer renamed (cleared by ALU commit, not by store)
    dut_if.set_int_src1(5, 0x9999)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x9999)
    check_rat_lookup(result, expected, "x5 after store commit")
    assert not result.renamed, "x5 should not be renamed (ALU commit cleared it)"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 10: x0 destination invariant
# =============================================================================


@cocotb.test()
async def test_x0_destination_invariant(dut: Any) -> None:
    """x0 remains hardwired zero throughout dispatch/commit cycle.

    The real pipeline never sets dest_valid for x0 instructions (the decoder
    clears it), so we use dest_valid=False here.  We also dispatch a separate
    instruction targeting x5 to create RAT activity, and verify x0 stays
    zero through all of it.
    """
    cocotb.log.info("=== Test: x0 Destination Invariant ===")

    dut_if, model = await setup_test(dut)

    # Dispatch instruction whose architectural dest is x0 — the real pipeline
    # sets dest_valid=False for x0, so the RAT rename is never driven.
    req_x0 = AllocationRequest(pc=0x1000, dest_rf=0, dest_reg=0, dest_valid=False)
    tag_x0 = await dut_if.dispatch(req_x0)
    model.dispatch(req_x0)

    # Also dispatch an instruction to x5 so RAT has some rename state
    req_x5 = make_int_req(pc=0x1004, rd=5)
    await dut_if.dispatch(req_x5)
    model.dispatch(req_x5)

    # x0 should NOT be renamed
    dut_if.set_int_src1(0, 0xFFFFFFFF)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(0, 0xFFFFFFFF)
    check_rat_lookup(result, expected, "x0 after dispatch")
    assert not result.renamed, "x0 should never be renamed"
    assert result.value == 0, "x0 value should always be 0"

    # x5 should be renamed
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_int_src1().renamed, "x5 should be renamed"

    # Complete x0 instruction and commit
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_x0, value=0xBAD))
    model.cdb_write(CDBWrite(tag=tag_x0, value=0xBAD))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await wait_for_commit(dut_if)
    model.try_commit()

    # x0 still hardwired zero after commit
    dut_if.set_int_src1(0, 0xFFFFFFFF)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert not result.renamed, "x0 should never be renamed after commit"
    assert result.value == 0, "x0 value should always be 0"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 11: ROB bypass read with RAT state
# =============================================================================


@cocotb.test()
async def test_rob_bypass_read_with_rat_state(dut: Any) -> None:
    """ROB read interface returns done/value while RAT still shows renamed."""
    cocotb.log.info("=== Test: ROB Bypass Read with RAT State ===")

    dut_if, model = await setup_test(dut)

    # Dispatch two instructions
    req1 = make_int_req(pc=0x1000, rd=5)
    tag1 = await dut_if.dispatch(req1)
    model.dispatch(req1)

    req2 = make_int_req(pc=0x1004, rd=6)
    tag2 = await dut_if.dispatch(req2)
    model.dispatch(req2)

    # Complete T1 via CDB but NOT T0
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag2, value=0xCAFE))
    model.cdb_write(CDBWrite(tag=tag2, value=0xCAFE))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    # ROB bypass read: T1 should be done with value 0xCAFE
    dut_if.set_read_tag(tag2)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_entry_done(), f"ROB entry {tag2} should be done"
    assert dut_if.read_entry_value() == 0xCAFE, "ROB entry value mismatch"

    # But RAT still shows x6 as renamed to T1 (not yet committed)
    dut_if.set_int_src1(6, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(6, 0)
    check_rat_lookup(result, expected, "x6 while ROB done but not committed")
    assert result.renamed and result.tag == tag2, "x6 should still be renamed"

    # ROB bypass read: T0 should NOT be done
    await FallingEdge(dut_if.clock)
    dut_if.set_read_tag(tag1)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_entry_done(), f"ROB entry {tag1} should not be done"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Test 12: Constrained random dispatch/execute/commit
# =============================================================================


@cocotb.test()
async def test_random_dispatch_execute_commit(dut: Any) -> None:
    """Constrained random: 200 iterations of mixed INT/FP/branch/store."""
    cocotb.log.info("=== Test: Random Dispatch/Execute/Commit ===")
    seed = log_random_seed()

    dut_if, model = await setup_test(dut)

    in_flight: list[tuple[int, AllocationRequest]] = []
    completed_tags: set[int] = set()
    num_iterations = 200
    num_dispatches = 0
    num_commits = 0
    prev_dut_head: int | None = None

    def observe_commit() -> dict | None:
        """Detect DUT commits via registered head-pointer changes.

        The DUT's o_commit bus is combinational — it previews the entry
        that *will* dequeue on the next rising edge.  Relying on
        o_commit.valid introduces a one-cycle ambiguity between the
        preview and the registered dequeue, causing the model to miss
        commits when a dequeue fires inside dispatch() or after
        flush_en is cleared.

        Instead we track the DUT's registered head pointer (o_head_tag).
        When it changes between calls a dequeue has occurred and we
        advance the model to match.  Commit metadata (checkpoint info
        etc.) comes from the model's own entry data, avoiding the need
        to buffer the combinational o_commit output.

        If the head advanced by more than 1 (multiple dequeues between
        calls), each intermediate commit is processed individually.
        Returns the last committed entry's data, or None.
        """
        nonlocal prev_dut_head, in_flight, num_commits

        dut_head = int(dut_if.dut.o_head_tag.value)
        committed = None

        if prev_dut_head is not None and dut_head != prev_dut_head:
            delta = (dut_head - prev_dut_head) & model.rob.tag_mask
            cursor = prev_dut_head
            for _ in range(delta):
                expected_tag = cursor & model.rob.tag_mask
                result = model.try_commit()
                assert result is not None, (
                    f"DUT dequeued (head {prev_dut_head} -> {dut_head}, "
                    f"cursor={cursor}) but model cannot commit "
                    f"(model_head={model.rob.head_idx}, "
                    f"done={model.rob.head_entry.done}, "
                    f"valid={model.rob.head_entry.valid})"
                )
                assert result["tag"] == expected_tag, (
                    f"Commit tag mismatch: DUT dequeued tag {expected_tag}, "
                    f"model committed tag {result['tag']} "
                    f"(head {prev_dut_head}->{dut_head}, cursor={cursor})"
                )

                committed = result
                ctag = result["tag"]
                in_flight = [(t, rq) for t, rq in in_flight if t != ctag]
                completed_tags.discard(ctag)
                num_commits += 1
                cursor = (cursor + 1) & model.rob.tag_mask

        prev_dut_head = dut_head
        return committed

    # Timing invariant: every iteration starts and ends at FallingEdge.
    # Every RisingEdge is followed by observe_commit() so the model
    # detects head-pointer changes promptly.

    for i in range(num_iterations):
        r = random.random()

        # Dispatch new instruction (if DUT ROB not full, ~40%)
        if r < 0.40 and not dut_if.rob_full:
            # Double-check alloc_ready (may differ from rob_full during flush)
            ready, _, _ = dut_if.read_alloc_response()
            if not ready:
                await RisingEdge(dut_if.clock)
                observe_commit()
                await FallingEdge(dut_if.clock)
                continue

            kind = random.choice(["int", "fp", "store", "branch"])

            if kind == "int":
                rd = random.randint(1, 31)
                req = make_int_req(pc=0x1000 + num_dispatches * 4, rd=rd)
            elif kind == "fp":
                fd = random.randint(0, 31)
                req = make_fp_req(pc=0x1000 + num_dispatches * 4, fd=fd)
            elif kind == "store":
                req = make_store_req(pc=0x1000 + num_dispatches * 4)
            else:  # branch
                req = make_branch_req(
                    pc=0x1000 + num_dispatches * 4,
                    predicted_taken=random.choice([True, False]),
                    predicted_target=random.randint(0, MASK32),
                )

            save_cp = kind == "branch" and dut_if.checkpoint_available
            tag = await dut_if.dispatch(req, checkpoint_save=save_cp)
            # dispatch() ends at FallingEdge — observe any commit from the
            # rising edge that just passed, BEFORE updating the model so
            # the model processes events in the same order as the DUT.
            commit = observe_commit()
            model.dispatch(req, checkpoint_save=save_cp)
            in_flight.append((tag, req))
            num_dispatches += 1

            # Free checkpoint if the committed entry had one
            if commit and commit["has_checkpoint"] and not commit["misprediction"]:
                cp_id = commit["checkpoint_id"]
                dut_if.drive_checkpoint_free(cp_id)
                model.rat.checkpoint_free(cp_id)
                await RisingEdge(dut_if.clock)
                observe_commit()
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_free()

        # CDB write / branch update to random in-flight entry (~30%)
        elif r < 0.70 and in_flight:
            # Find an entry not yet completed
            uncompleted = [
                (t, rq)
                for t, rq in in_flight
                if t not in completed_tags
                and not model.rob.entries[t & model.rob.tag_mask].done
            ]
            if uncompleted:
                tag, req = random.choice(uncompleted)
                value = random.randint(0, MASK64)

                if req.is_branch:
                    # Re-verify entry state
                    entry_m = model.rob.entries[tag & model.rob.tag_mask]
                    if not entry_m.valid or not entry_m.is_branch:
                        await RisingEdge(dut_if.clock)
                        observe_commit()
                        await FallingEdge(dut_if.clock)
                        continue

                    # Branch uses branch_update interface
                    mispred = random.random() < 0.15
                    update = BranchUpdate(
                        tag=tag,
                        taken=random.choice([True, False]),
                        target=random.randint(0, MASK32),
                        mispredicted=mispred,
                    )

                    if mispred and entry_m.has_checkpoint:
                        # Misprediction with checkpoint: drive branch_update
                        # + flush_en + checkpoint_restore on the SAME edge
                        # so the DUT processes the branch resolution and
                        # partial flush atomically (matching the model).
                        cp_id = entry_m.checkpoint_id
                        dut_if.drive_branch_update(update)
                        dut_if.drive_flush_en(tag)
                        dut_if.drive_checkpoint_restore(cp_id)
                        model.branch_update(update)
                        model.misprediction_recovery(cp_id, tag)
                        await RisingEdge(dut_if.clock)
                        observe_commit()
                        await FallingEdge(dut_if.clock)
                        dut_if.clear_branch_update()
                        dut_if.clear_flush_en()
                        dut_if.clear_checkpoint_restore()

                        # Remove flushed entries from in_flight
                        in_flight = [
                            (t, rq)
                            for t, rq in in_flight
                            if model.rob.entries[t & model.rob.tag_mask].valid
                        ]
                        completed_tags = {
                            t
                            for t in completed_tags
                            if model.rob.entries[t & model.rob.tag_mask].valid
                        }
                    else:
                        # Correctly predicted, or mispredicted without
                        # checkpoint — just drive branch_update alone.
                        dut_if.drive_branch_update(update)
                        model.branch_update(update)
                        await RisingEdge(dut_if.clock)
                        observe_commit()
                        await FallingEdge(dut_if.clock)
                        dut_if.clear_branch_update()
                else:
                    # Re-verify entry state
                    entry_m = model.rob.entries[tag & model.rob.tag_mask]
                    if not entry_m.valid or entry_m.done:
                        await RisingEdge(dut_if.clock)
                        observe_commit()
                        await FallingEdge(dut_if.clock)
                        continue

                    cdb = CDBWrite(tag=tag, value=value)
                    # Drive at current FallingEdge (no extra await)
                    dut_if.drive_cdb_write(cdb)
                    model.cdb_write(cdb)
                    await RisingEdge(dut_if.clock)
                    observe_commit()
                    await FallingEdge(dut_if.clock)
                    dut_if.clear_cdb_write()
                    completed_tags.add(tag)
            else:
                # Nothing to complete — idle for one cycle
                await RisingEdge(dut_if.clock)
                observe_commit()
                await FallingEdge(dut_if.clock)

        # Let a cycle pass — observe any auto-commit (~20%)
        elif r < 0.90:
            await RisingEdge(dut_if.clock)
            commit = observe_commit()
            if commit and commit["has_checkpoint"] and not commit["misprediction"]:
                cp_id = commit["checkpoint_id"]
                await FallingEdge(dut_if.clock)
                dut_if.drive_checkpoint_free(cp_id)
                model.rat.checkpoint_free(cp_id)
                await RisingEdge(dut_if.clock)
                observe_commit()
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_free()
            else:
                await FallingEdge(dut_if.clock)

        # Periodic flush_all (~10%)
        else:
            # Drive at current FallingEdge (no extra await)
            dut_if.drive_flush_all()
            await RisingEdge(dut_if.clock)
            # Observe any commit that fired on this edge before flush took effect
            observe_commit()
            model.flush_all()
            await FallingEdge(dut_if.clock)
            dut_if.clear_flush_all()
            in_flight.clear()
            completed_tags.clear()

    # Drain: flush everything so both DUT and model reach a clean state.
    await FallingEdge(dut_if.clock)
    dut_if.drive_flush_all()
    await RisingEdge(dut_if.clock)
    observe_commit()
    model.flush_all()
    await FallingEdge(dut_if.clock)
    dut_if.clear_flush_all()

    # Final verification: check all INT and FP registers match model
    for addr in range(32):
        regfile_val = random.randint(0, MASK32)
        dut_if.set_int_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(addr, regfile_val)
        check_rat_lookup(result, expected, f"Final INT x{addr}")

    for addr in range(32):
        regfile_val = random.randint(0, MASK64)
        dut_if.set_fp_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(addr, regfile_val)
        check_rat_lookup(result, expected, f"Final FP f{addr}")

    cocotb.log.info(
        f"=== Test Passed ({num_dispatches} dispatches, {num_commits} commits, seed={seed}) ==="
    )

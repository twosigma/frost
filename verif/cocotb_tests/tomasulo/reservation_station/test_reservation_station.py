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

"""Unit tests for the Reservation Station module.

Covers dispatch, CDB wakeup, issue logic, flush, and constrained random.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from .rs_interface import RSInterface, MASK_TAG
from .rs_model import RSModel

RS_DEPTH = 8  # Default parameter

# Operation codes (from instr_op_e: ADD=0, SUB=1, ...)
OP_ADD = 0
OP_SUB = 1
OP_AND = 2
OP_OR = 3
OP_MUL = 38  # approximate


# =============================================================================
# Helpers
# =============================================================================


async def setup_test(dut: Any) -> tuple[RSInterface, RSModel]:
    """Set up test with clock, reset, and return interface and model."""
    clock = Clock(dut.i_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut_if = RSInterface(dut)
    model = RSModel(depth=RS_DEPTH)
    await dut_if.reset_dut()

    return dut_if, model


def log_random_seed() -> int:
    """Log and return the random seed for reproducibility."""
    seed = random.getrandbits(32)
    random.seed(seed)
    cocotb.log.info(f"Random seed: {seed}")
    return seed


def check_issue(dut_issue: dict, model_issue: dict | None, label: str) -> None:
    """Compare DUT issue output to model expected issue."""
    if model_issue is None:
        assert not dut_issue["valid"], f"{label}: DUT issued but model did not"
        return
    assert dut_issue["valid"], f"{label}: model issued but DUT did not"
    for key in (
        "rob_tag",
        "op",
        "src1_value",
        "src2_value",
        "src3_value",
        "imm",
        "use_imm",
        "rm",
        "branch_target",
        "predicted_taken",
        "predicted_target",
        "is_fp_mem",
        "mem_size",
        "mem_signed",
        "csr_addr",
        "csr_imm",
    ):
        assert (
            dut_issue[key] == model_issue[key]
        ), f"{label}: {key} mismatch DUT={dut_issue[key]:#x} model={model_issue[key]:#x}"


# =============================================================================
# Basic Tests
# =============================================================================


@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """After reset: empty, not full, count=0, no issue."""
    cocotb.log.info("=== Test: Reset State ===")
    dut_if, _ = await setup_test(dut)

    assert dut_if.empty, "Should be empty after reset"
    assert not dut_if.full, "Should not be full after reset"
    assert dut_if.count == 0, "Count should be 0 after reset"
    assert not dut_if.issue_valid, "No issue after reset"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_single(dut: Any) -> None:
    """Dispatch one entry and verify count/status."""
    cocotb.log.info("=== Test: Dispatch Single ===")
    dut_if, model = await setup_test(dut)

    # Dispatch with src1 ready, src2 not ready
    dut_if.drive_dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0xAAAA,
        src2_ready=False,
        src2_tag=5,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0xAAAA,
        src2_ready=False,
        src2_tag=5,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    assert not dut_if.empty, "Should not be empty"
    assert dut_if.count == 1, f"Count should be 1, got {dut_if.count}"
    assert not dut_if.full, "Should not be full"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_and_issue(dut: Any) -> None:
    """Dispatch with all sources ready, then issue next cycle."""
    cocotb.log.info("=== Test: Dispatch and Issue ===")
    dut_if, model = await setup_test(dut)

    # Dispatch with all sources ready
    dut_if.drive_dispatch(
        rob_tag=2,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=2,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # Now set FU ready and check issue
    # Note: RTL uses registered outputs — entry was written on previous rising edge,
    # issue output is combinational from registered state. So the entry is now valid
    # and ready. Set fu_ready and wait for combinational logic to settle.
    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle after driving input

    # Read combinational issue output
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)

    check_issue(issue, model_issue, "first issue")

    # After the issue fires and we step, entry should be cleared
    await dut_if.step()
    dut_if.set_fu_ready(False)

    assert dut_if.empty, "Should be empty after issue"
    assert dut_if.count == 0, f"Count should be 0, got {dut_if.count}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_full(dut: Any) -> None:
    """Fill RS to capacity, verify full flag."""
    cocotb.log.info("=== Test: Dispatch Full ===")
    dut_if, model = await setup_test(dut)

    for i in range(RS_DEPTH):
        dut_if.drive_dispatch(
            rob_tag=i,
            op=OP_ADD,
            src1_ready=False,
            src1_tag=(i + 10) & MASK_TAG,
            src2_ready=False,
            src2_tag=(i + 20) & MASK_TAG,
            src3_ready=True,
        )
        model.dispatch(
            rob_tag=i,
            op=OP_ADD,
            src1_ready=False,
            src1_tag=(i + 10) & MASK_TAG,
            src2_ready=False,
            src2_tag=(i + 20) & MASK_TAG,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_dispatch()

    assert dut_if.full, "Should be full"
    assert dut_if.count == RS_DEPTH, f"Count should be {RS_DEPTH}, got {dut_if.count}"
    assert model.is_full(), "Model should be full"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_blocked_when_full(dut: Any) -> None:
    """Dispatch rejected when full (dispatch_fire=0)."""
    cocotb.log.info("=== Test: Dispatch Blocked When Full ===")
    dut_if, model = await setup_test(dut)

    # Fill RS
    for i in range(RS_DEPTH):
        dut_if.drive_dispatch(
            rob_tag=i,
            op=OP_ADD,
            src1_ready=False,
            src1_tag=10,
            src2_ready=False,
            src2_tag=20,
            src3_ready=True,
        )
        model.dispatch(
            rob_tag=i,
            op=OP_ADD,
            src1_ready=False,
            src1_tag=10,
            src2_ready=False,
            src2_tag=20,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_dispatch()

    assert dut_if.full, "Should be full"

    # Try to dispatch one more — it should NOT take effect
    old_count = dut_if.count
    dut_if.drive_dispatch(
        rob_tag=31,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0xBEEF,
        src2_ready=True,
        src2_value=0xCAFE,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    assert dut_if.count == old_count, "Count should not change when full"
    assert dut_if.full, "Should still be full"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# CDB Wakeup Tests
# =============================================================================


@cocotb.test()
async def test_cdb_wakeup_src1(dut: Any) -> None:
    """CDB wakes src1 pending operand."""
    cocotb.log.info("=== Test: CDB Wakeup Src1 ===")
    dut_if, model = await setup_test(dut)

    # Dispatch with src1 not ready (waiting on tag 5)
    dut_if.drive_dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=5,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=5,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # Not ready yet — FU ready but issue should not fire
    dut_if.set_fu_ready(True)
    assert not dut_if.issue_valid, "Should not issue (src1 not ready)"

    # CDB broadcast with tag 5 to wake src1
    dut_if.drive_cdb(tag=5, value=0xDEAD)
    model.cdb_snoop(tag=5, value=0xDEAD)

    await dut_if.step()
    dut_if.clear_cdb()

    # Now should issue
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "after CDB wakeup src1")

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_wakeup_src2(dut: Any) -> None:
    """CDB wakes src2 pending operand."""
    cocotb.log.info("=== Test: CDB Wakeup Src2 ===")
    dut_if, model = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=2,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=False,
        src2_tag=7,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=2,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=False,
        src2_tag=7,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    dut_if.set_fu_ready(True)
    assert not dut_if.issue_valid, "Should not issue (src2 not ready)"

    dut_if.drive_cdb(tag=7, value=0xBEEF)
    model.cdb_snoop(tag=7, value=0xBEEF)
    await dut_if.step()
    dut_if.clear_cdb()

    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "after CDB wakeup src2")

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_wakeup_src3(dut: Any) -> None:
    """CDB wakes src3 pending operand (FMA-style)."""
    cocotb.log.info("=== Test: CDB Wakeup Src3 ===")
    dut_if, model = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=3,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=False,
        src3_tag=9,
    )
    model.dispatch(
        rob_tag=3,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=False,
        src3_tag=9,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    dut_if.set_fu_ready(True)
    assert not dut_if.issue_valid, "Should not issue (src3 not ready)"

    dut_if.drive_cdb(tag=9, value=0x3333)
    model.cdb_snoop(tag=9, value=0x3333)
    await dut_if.step()
    dut_if.clear_cdb()

    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "after CDB wakeup src3")

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_wakeup_multiple_sources(dut: Any) -> None:
    """Single CDB wakes multiple sources of the same entry (same tag)."""
    cocotb.log.info("=== Test: CDB Wakeup Multiple Sources ===")
    dut_if, model = await setup_test(dut)

    # Both src1 and src2 waiting on the same tag
    dut_if.drive_dispatch(
        rob_tag=4,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=3,
        src2_ready=False,
        src2_tag=3,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=4,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=3,
        src2_ready=False,
        src2_tag=3,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    dut_if.set_fu_ready(True)
    assert not dut_if.issue_valid, "Should not issue yet"

    # Single CDB broadcast wakes both
    dut_if.drive_cdb(tag=3, value=0xAAAA)
    model.cdb_snoop(tag=3, value=0xAAAA)
    await dut_if.step()
    dut_if.clear_cdb()

    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "after CDB wakeup both sources")

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_wakeup_across_entries(dut: Any) -> None:
    """CDB wakes sources in different entries."""
    cocotb.log.info("=== Test: CDB Wakeup Across Entries ===")
    dut_if, model = await setup_test(dut)

    # Entry 0: src1 waiting on tag 10
    dut_if.drive_dispatch(
        rob_tag=0,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=10,
        src2_ready=True,
        src2_value=0x1,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=0,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=10,
        src2_ready=True,
        src2_value=0x1,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # Entry 1: src2 waiting on tag 10
    dut_if.drive_dispatch(
        rob_tag=1,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0x2,
        src2_ready=False,
        src2_tag=10,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=1,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0x2,
        src2_ready=False,
        src2_tag=10,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # CDB broadcast wakes both entries
    dut_if.drive_cdb(tag=10, value=0xBBBB)
    model.cdb_snoop(tag=10, value=0xBBBB)
    await dut_if.step()
    dut_if.clear_cdb()

    # Both should now be ready — lowest index (0) issues first
    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "entry 0 issues first")
    assert issue["rob_tag"] == 0, "Entry 0 should issue first (priority)"

    # Step to consume the issue (entry 0 invalidated on rising edge)
    await dut_if.step()

    # Entry 1 should issue next (fu_ready still 1, combinational output settled by step)
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "entry 1 issues second")
    assert issue["rob_tag"] == 1, "Entry 1 should issue second"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_bypass_at_dispatch(dut: Any) -> None:
    """Source becomes ready via CDB same cycle as dispatch."""
    cocotb.log.info("=== Test: CDB Bypass at Dispatch ===")
    dut_if, model = await setup_test(dut)

    # Dispatch with src1 not ready, but CDB is broadcasting same tag this cycle
    dut_if.drive_dispatch(
        rob_tag=5,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=12,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    dut_if.drive_cdb(tag=12, value=0xCAFE)
    model.dispatch(
        rob_tag=5,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=12,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
        cdb_valid=True,
        cdb_tag=12,
        cdb_value=0xCAFE,
    )
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_cdb()

    # Entry should be ready immediately (CDB bypassed at dispatch)
    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "CDB bypass at dispatch")
    assert issue["valid"], "Should issue immediately with CDB bypass"
    assert issue["src1_value"] == 0xCAFE, "src1_value should be CDB value"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Issue Logic Tests
# =============================================================================


@cocotb.test()
async def test_issue_priority(dut: Any) -> None:
    """Multiple ready entries, lowest index issues first."""
    cocotb.log.info("=== Test: Issue Priority ===")
    dut_if, model = await setup_test(dut)

    # Dispatch 3 entries, all ready
    for i in range(3):
        dut_if.drive_dispatch(
            rob_tag=i,
            op=OP_ADD + i,
            src1_ready=True,
            src1_value=i * 0x100,
            src2_ready=True,
            src2_value=i * 0x200,
            src3_ready=True,
        )
        model.dispatch(
            rob_tag=i,
            op=OP_ADD + i,
            src1_ready=True,
            src1_value=i * 0x100,
            src2_ready=True,
            src2_value=i * 0x200,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_dispatch()

    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle

    # Issue all 3, verify order is index 0, 1, 2
    for expected_tag in range(3):
        issue = dut_if.read_issue()
        model_issue = model.try_issue(fu_ready=True)
        check_issue(issue, model_issue, f"priority issue tag={expected_tag}")
        assert (
            issue["rob_tag"] == expected_tag
        ), f"Expected tag {expected_tag}, got {issue['rob_tag']}"
        await dut_if.step()

    assert dut_if.empty, "Should be empty after issuing all"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_issue_gated_by_fu_ready(dut: Any) -> None:
    """Ready entry but FU not ready — no issue."""
    cocotb.log.info("=== Test: Issue Gated by FU Ready ===")
    dut_if, model = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # FU not ready
    dut_if.set_fu_ready(False)
    await Timer(1, unit="ps")  # Let combinational logic settle
    assert not dut_if.issue_valid, "Should not issue when FU not ready"

    # Make FU ready
    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    assert dut_if.issue_valid, "Should issue when FU is ready"

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_use_imm_bypasses_src2(dut: Any) -> None:
    """use_imm=1 means src2 not needed for ready check."""
    cocotb.log.info("=== Test: Use Imm Bypasses Src2 ===")
    dut_if, model = await setup_test(dut)

    # Dispatch with src2 NOT ready but use_imm=True
    dut_if.drive_dispatch(
        rob_tag=6,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=False,
        src2_tag=15,  # src2 not ready
        src3_ready=True,
        use_imm=True,
        imm=0x42,
    )
    model.dispatch(
        rob_tag=6,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=False,
        src2_tag=15,
        src3_ready=True,
        use_imm=True,
        imm=0x42,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # Should be ready because use_imm bypasses src2
    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "use_imm bypass")
    assert issue["valid"], "Should issue with use_imm=1 despite src2 not ready"
    assert issue["use_imm"], "use_imm should be set"
    assert issue["imm"] == 0x42, f"imm should be 0x42, got {issue['imm']:#x}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_issue_output_fields(dut: Any) -> None:
    """Verify all rs_issue_t fields match dispatched values."""
    cocotb.log.info("=== Test: Issue Output Fields ===")
    dut_if, model = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=7,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0xAAAA_BBBB_CCCC_DDDD,
        src2_ready=True,
        src2_value=0x1111_2222_3333_4444,
        src3_ready=True,
        src3_value=0x5555_6666_7777_8888,
        imm=0xDEAD_BEEF,
        use_imm=False,
        rm=3,
        branch_target=0x1000_0000,
        predicted_taken=True,
        predicted_target=0x2000_0000,
        is_fp_mem=True,
        mem_size=2,
        mem_signed=True,
        csr_addr=0x300,
        csr_imm=0x1F,
    )
    model.dispatch(
        rob_tag=7,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0xAAAA_BBBB_CCCC_DDDD,
        src2_ready=True,
        src2_value=0x1111_2222_3333_4444,
        src3_ready=True,
        src3_value=0x5555_6666_7777_8888,
        imm=0xDEAD_BEEF,
        use_imm=False,
        rm=3,
        branch_target=0x1000_0000,
        predicted_taken=True,
        predicted_target=0x2000_0000,
        is_fp_mem=True,
        mem_size=2,
        mem_signed=True,
        csr_addr=0x300,
        csr_imm=0x1F,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "full field check")

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Flush Tests
# =============================================================================


@cocotb.test()
async def test_flush_all(dut: Any) -> None:
    """flush_all clears all entries."""
    cocotb.log.info("=== Test: Flush All ===")
    dut_if, model = await setup_test(dut)

    # Fill with 4 entries
    for i in range(4):
        dut_if.drive_dispatch(
            rob_tag=i,
            op=OP_ADD,
            src1_ready=True,
            src1_value=i,
            src2_ready=True,
            src2_value=i,
            src3_ready=True,
        )
        model.dispatch(
            rob_tag=i,
            op=OP_ADD,
            src1_ready=True,
            src1_value=i,
            src2_ready=True,
            src2_value=i,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_dispatch()

    assert dut_if.count == 4, f"Count should be 4, got {dut_if.count}"

    # Flush all
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.empty, "Should be empty after flush_all"
    assert dut_if.count == 0, f"Count should be 0 after flush_all, got {dut_if.count}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_partial_flush(dut: Any) -> None:
    """Partial flush invalidates only younger entries."""
    cocotb.log.info("=== Test: Partial Flush ===")
    dut_if, model = await setup_test(dut)

    head_tag = 0

    # Dispatch 4 entries with rob_tags 0, 1, 2, 3
    for i in range(4):
        dut_if.drive_dispatch(
            rob_tag=i,
            op=OP_ADD,
            src1_ready=True,
            src1_value=i,
            src2_ready=True,
            src2_value=i,
            src3_ready=True,
        )
        model.dispatch(
            rob_tag=i,
            op=OP_ADD,
            src1_ready=True,
            src1_value=i,
            src2_ready=True,
            src2_value=i,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_dispatch()

    # Partial flush: tag=1, head=0 -> entries with age > flush_age should be flushed
    # Entry 0: age=0, flush_age=1 -> 0 > 1? No -> keep
    # Entry 1: age=1, flush_age=1 -> 1 > 1? No -> keep
    # Entry 2: age=2, flush_age=1 -> 2 > 1? Yes -> flush
    # Entry 3: age=3, flush_age=1 -> 3 > 1? Yes -> flush
    dut_if.drive_partial_flush(flush_tag=1, head_tag=head_tag)
    model.partial_flush(flush_tag=1, head_tag=head_tag)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert (
        dut_if.count == 2
    ), f"Count should be 2 after partial flush, got {dut_if.count}"
    assert model.count() == 2, "Model count should be 2"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_partial_flush_preserves_older(dut: Any) -> None:
    """Entries at/before flush_tag are preserved."""
    cocotb.log.info("=== Test: Partial Flush Preserves Older ===")
    dut_if, model = await setup_test(dut)

    head_tag = 0

    # Dispatch entry with rob_tag=0 (oldest)
    dut_if.drive_dispatch(
        rob_tag=0,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0xAAAA,
        src2_ready=True,
        src2_value=0xBBBB,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=0,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0xAAAA,
        src2_ready=True,
        src2_value=0xBBBB,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # Dispatch entry with rob_tag=5 (younger)
    dut_if.drive_dispatch(
        rob_tag=5,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0xCCCC,
        src2_ready=True,
        src2_value=0xDDDD,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=5,
        op=OP_SUB,
        src1_ready=True,
        src1_value=0xCCCC,
        src2_ready=True,
        src2_value=0xDDDD,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    assert dut_if.count == 2

    # Partial flush: tag=2, head=0 -> flush entries with age > 2
    # Entry rob_tag=0: age=0, keep
    # Entry rob_tag=5: age=5, flush
    dut_if.drive_partial_flush(flush_tag=2, head_tag=head_tag)
    model.partial_flush(flush_tag=2, head_tag=head_tag)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert dut_if.count == 1, f"Count should be 1, got {dut_if.count}"

    # The preserved entry should still issue
    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "preserved entry issues")
    assert issue["rob_tag"] == 0, "Preserved entry should have rob_tag=0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_wakeup_during_partial_flush(dut: Any) -> None:
    """CDB wakeup must reach surviving entries even when flush_en is asserted."""
    cocotb.log.info("=== Test: CDB Wakeup During Partial Flush ===")
    dut_if, model = await setup_test(dut)

    head_tag = 0

    # Entry 0: older (rob_tag=1), src1 pending on tag=10 — should SURVIVE flush
    dut_if.drive_dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=10,
        src2_ready=True,
        src2_value=0xAAAA,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=10,
        src2_ready=True,
        src2_value=0xAAAA,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # Entry 1: younger (rob_tag=5) — should be FLUSHED
    dut_if.drive_dispatch(
        rob_tag=5,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0xBBBB,
        src2_ready=True,
        src2_value=0xCCCC,
        src3_ready=True,
    )
    model.dispatch(
        rob_tag=5,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0xBBBB,
        src2_ready=True,
        src2_value=0xCCCC,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    assert dut_if.count == 2

    # Drive partial flush AND CDB on the SAME cycle.
    # Flush tag=2, head=0 -> entry rob_tag=5 (age 5 > 2) flushed,
    #                         entry rob_tag=1 (age 1 <= 2) survives.
    # CDB tag=10 should wake entry 0's src1 even though flush_en is high.
    dut_if.drive_partial_flush(flush_tag=2, head_tag=head_tag)
    dut_if.drive_cdb(tag=10, value=0xDEAD)
    model.partial_flush(flush_tag=2, head_tag=head_tag)
    model.cdb_snoop(tag=10, value=0xDEAD)
    await dut_if.step()
    dut_if.clear_partial_flush()
    dut_if.clear_cdb()

    # Only the surviving entry should remain, and it should now be ready
    assert dut_if.count == 1, f"Expected 1 entry, got {dut_if.count}"

    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    assert issue["valid"], "Surviving entry should issue (CDB woke src1 during flush)"
    assert model_issue is not None
    assert issue["rob_tag"] == 1
    assert issue["src1_value"] == 0xDEAD, "src1 should have CDB value"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Constrained Random Tests
# =============================================================================


@cocotb.test()
async def test_random_dispatch_wakeup_issue(dut: Any) -> None:
    """200 random operations mixing dispatch, CDB wakeup, and issue."""
    cocotb.log.info("=== Test: Random Dispatch/Wakeup/Issue ===")
    log_random_seed()
    dut_if, model = await setup_test(dut)

    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let fu_ready propagate
    issued_count = 0

    for cycle in range(200):
        # Read DUT state from settled registered state
        dut_full = dut_if.full
        dut_count = dut_if.count

        # Peek model issue without mutating, then compare with DUT combinational issue.
        model_issue_info = model.peek_issue(fu_ready=True)
        issue = dut_if.read_issue()
        model_issue = model_issue_info[1] if model_issue_info is not None else None

        if model_issue is not None:
            assert issue["valid"], f"Cycle {cycle}: model issued but DUT did not"
            check_issue(issue, model_issue, f"cycle {cycle}")
            issued_count += 1
        else:
            assert not issue["valid"], f"Cycle {cycle}: DUT issued but model did not"

        # Drive new inputs for this cycle
        # Gate dispatch on DUT full/count from the old registered state.
        action = random.choice(["dispatch", "cdb", "idle"])

        if action == "dispatch" and not dut_full:
            rob_tag = random.randint(0, 31)
            op = random.randint(0, 10)
            src1_ready = random.choice([True, False])
            src1_tag = random.randint(0, 31)
            src1_value = random.getrandbits(64)
            src2_ready = random.choice([True, False])
            src2_tag = random.randint(0, 31)
            src2_value = random.getrandbits(64)
            src3_ready = random.choice([True, False])
            src3_tag = random.randint(0, 31)
            src3_value = random.getrandbits(64)
            use_imm = random.choice([True, False])
            imm = random.getrandbits(32)

            dut_if.drive_dispatch(
                rob_tag=rob_tag,
                op=op,
                src1_ready=src1_ready,
                src1_tag=src1_tag,
                src1_value=src1_value,
                src2_ready=src2_ready,
                src2_tag=src2_tag,
                src2_value=src2_value,
                src3_ready=src3_ready,
                src3_tag=src3_tag,
                src3_value=src3_value,
                use_imm=use_imm,
                imm=imm,
            )
            model.dispatch(
                rob_tag=rob_tag,
                op=op,
                src1_ready=src1_ready,
                src1_tag=src1_tag,
                src1_value=src1_value,
                src2_ready=src2_ready,
                src2_tag=src2_tag,
                src2_value=src2_value,
                src3_ready=src3_ready,
                src3_tag=src3_tag,
                src3_value=src3_value,
                use_imm=use_imm,
                imm=imm,
            )

        elif action == "cdb" and dut_count > 0:
            cdb_tag = random.randint(0, 31)
            cdb_value = random.getrandbits(64)
            dut_if.drive_cdb(tag=cdb_tag, value=cdb_value)
            model.cdb_snoop(tag=cdb_tag, value=cdb_value)

        # Consume issue after same-cycle action modeling.
        # This matches RTL behavior where dispatch/free-index selection uses the
        # old registered state before issue invalidation takes effect.
        if model_issue_info is not None:
            model.consume_issue(model_issue_info[0])

        # Step: DUT registers inputs, issue invalidation, CDB wakeup
        await dut_if.step()
        dut_if.clear_dispatch()
        dut_if.clear_cdb()

    # Final count check
    assert (
        dut_if.count == model.count()
    ), f"Final count mismatch: DUT={dut_if.count} model={model.count()}"

    cocotb.log.info(f"=== Test Passed ({issued_count} issues) ===")


@cocotb.test()
async def test_random_with_flush(dut: Any) -> None:
    """Random operations including periodic flush events."""
    cocotb.log.info("=== Test: Random with Flush ===")
    log_random_seed()
    dut_if, model = await setup_test(dut)

    dut_if.set_fu_ready(True)
    await Timer(1, unit="ps")  # Let fu_ready propagate

    for cycle in range(200):
        # Read DUT state from settled registered state
        dut_full = dut_if.full
        dut_count = dut_if.count

        # Peek model issue without mutating, then compare with DUT combinational issue.
        model_issue_info = model.peek_issue(fu_ready=True)
        issue = dut_if.read_issue()
        model_issue = model_issue_info[1] if model_issue_info is not None else None

        if model_issue is not None:
            assert issue["valid"], f"Cycle {cycle}: model issued but DUT did not"
        else:
            assert not issue["valid"], f"Cycle {cycle}: DUT issued but model did not"

        # Drive new inputs for this cycle
        # Gate dispatch on DUT's full signal (matches RTL dispatch_fire gate)
        action = random.choices(
            ["dispatch", "cdb", "flush_all", "partial_flush", "idle"],
            weights=[40, 30, 5, 10, 15],
        )[0]

        flush_applied = False

        if action == "dispatch" and not dut_full:
            rob_tag = random.randint(0, 31)
            src1_ready = random.choice([True, False])
            src1_tag = random.randint(0, 31)
            src2_ready = random.choice([True, False])
            src2_tag = random.randint(0, 31)
            src3_ready = True  # simplify
            use_imm = random.choice([True, False])

            src1_value = random.getrandbits(64)
            src2_value = random.getrandbits(64)
            imm = random.getrandbits(32)

            dut_if.drive_dispatch(
                rob_tag=rob_tag,
                op=0,
                src1_ready=src1_ready,
                src1_tag=src1_tag,
                src1_value=src1_value,
                src2_ready=src2_ready,
                src2_tag=src2_tag,
                src2_value=src2_value,
                src3_ready=src3_ready,
                use_imm=use_imm,
                imm=imm,
            )
            model.dispatch(
                rob_tag=rob_tag,
                op=0,
                src1_ready=src1_ready,
                src1_tag=src1_tag,
                src1_value=src1_value,
                src2_ready=src2_ready,
                src2_tag=src2_tag,
                src2_value=src2_value,
                src3_ready=src3_ready,
                use_imm=use_imm,
                imm=imm,
            )

        elif action == "cdb" and dut_count > 0:
            cdb_tag = random.randint(0, 31)
            cdb_value = random.getrandbits(64)
            dut_if.drive_cdb(tag=cdb_tag, value=cdb_value)
            model.cdb_snoop(tag=cdb_tag, value=cdb_value)

        elif action == "flush_all":
            dut_if.drive_flush_all()
            model.flush_all()
            flush_applied = True

        elif action == "partial_flush" and dut_count > 0:
            flush_tag = random.randint(0, 31)
            head_tag = random.randint(0, 31)
            dut_if.drive_partial_flush(flush_tag=flush_tag, head_tag=head_tag)
            model.partial_flush(flush_tag=flush_tag, head_tag=head_tag)
            flush_applied = True

        # Flush has priority over issue invalidation in RTL.
        if not flush_applied and model_issue_info is not None:
            model.consume_issue(model_issue_info[0])

        # Step: DUT registers inputs, processes issue/flush/CDB
        await dut_if.step()
        dut_if.clear_dispatch()
        dut_if.clear_cdb()
        dut_if.clear_flush_all()
        dut_if.clear_partial_flush()

    # Final count check
    assert (
        dut_if.count == model.count()
    ), f"Final count mismatch: DUT={dut_if.count} model={model.count()}"

    cocotb.log.info("=== Test Passed ===")

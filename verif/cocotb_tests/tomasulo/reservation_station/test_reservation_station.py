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

Covers dispatch, two-lane CDB wakeup/replay, issue logic, repair, flush, and
constrained random.
"""

import random
import re
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer
from config import MASK_XLEN, XLEN

from .rs_interface import RSInterface, MASK_TAG
from .rs_model import RSModel

RS_DEPTH = 8  # Default parameter

# Operation codes (from instr_op_e: ADD=0, SUB=1, ...)
OP_ADD = 0
OP_SUB = 1
OP_AND = 2
OP_OR = 3


def _parse_op_value(name: str) -> int:
    """Parse a named enum value from instr_op_e in riscv_pkg.sv."""
    pkg_path = (
        Path(__file__).resolve().parents[4]
        / "hw"
        / "rtl"
        / "cpu_and_mem"
        / "cpu"
        / "riscv_pkg.sv"
    )
    text = pkg_path.read_text()
    m = re.search(
        r"typedef\s+enum"
        r"(?:\s+(?:bit|logic)(?:\s+(?:signed|unsigned))?(?:\s*\[[^\r\n]+?\])?)?"
        r"\s*\{([^}]*)\}\s*instr_op_e\s*;",
        text,
        re.DOTALL,
    )
    if not m:
        raise RuntimeError("Could not find instr_op_e")
    val = 0
    for line in m.group(1).splitlines():
        line = re.sub(r"//.*", "", line).strip().rstrip(",")
        if not line:
            continue
        em = re.fullmatch(
            r"([A-Z_][A-Z0-9_]*)\s*=\s*(?:\d*'[bBdDhHoO])?([0-9a-fA-F_]+)", line
        )
        if em:
            bm = re.search(r"'([bBdDhHoO])", line)
            base = {"b": 2, "d": 10, "h": 16, "o": 8}[bm.group(1).lower()] if bm else 10
            val = int(em.group(2).replace("_", ""), base)
            if em.group(1) == name:
                return val
            val += 1
            continue
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", line):
            if line == name:
                return val
            val += 1
            continue
        raise RuntimeError(f"Cannot parse instr_op_e entry: {line!r}")
    raise RuntimeError(f"{name} not found in instr_op_e")


OP_SC_W = _parse_op_value("SC_W")


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
        "pc",
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
    # Stage2 pipeline: issue_fire latches into stage2 on rising edge,
    # so we need one step for the data to appear on o_issue.
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads stage2

    # Read issue output from stage2 register
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


@cocotb.test()
async def test_dispatch_slot2_only_and_issue(dut: Any) -> None:
    """Slot-2-only dispatch uses the first free entry and issues normally."""
    cocotb.log.info("=== Test: Dispatch Slot 2 Only and Issue ===")
    dut_if, model = await setup_test(dut)

    dispatch: dict[str, Any] = {
        "rob_tag": 8,
        "op": OP_OR,
        "src1_ready": True,
        "src1_value": 0x1111_2222,
        "src2_ready": True,
        "src2_value": 0x3333_4444,
        "src3_ready": True,
        "src3_value": 0x5555_6666,
        "imm": 0x1234_5678,
        "rm": 2,
        "branch_target": 0x8000_1000,
        "predicted_taken": True,
        "predicted_target": 0x8000_2000,
        "is_fp_mem": True,
        "mem_size": 2,
        "mem_signed": True,
        "csr_addr": 0x305,
        "csr_imm": 0x7,
    }

    dut_if.drive_dispatch_2(**dispatch)
    model.dispatch(**dispatch)
    await dut_if.step()
    dut_if.clear_dispatch_2()

    empty_after_dispatch = dut_if.empty
    assert not empty_after_dispatch, "Should not be empty after slot-2-only dispatch"
    assert dut_if.count == 1, f"Count should be 1, got {dut_if.count}"

    dut_if.set_fu_ready(True)
    await dut_if.step()
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "slot-2-only issue")
    assert issue["rob_tag"] == 8, "Slot-2-only entry should issue"

    await dut_if.step()
    dut_if.set_fu_ready(False)
    empty_after_issue = dut_if.empty
    assert empty_after_issue, "Should be empty after issuing slot-2-only entry"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_slot1_slot2_same_cycle_issue_order(dut: Any) -> None:
    """Slot 1 and slot 2 can dispatch together and issue from distinct entries."""
    cocotb.log.info("=== Test: Dispatch Slot 1 + Slot 2 Same Cycle ===")
    dut_if, model = await setup_test(dut)

    slot1: dict[str, Any] = {
        "rob_tag": 10,
        "op": OP_ADD,
        "src1_ready": True,
        "src1_value": 0x1000,
        "src2_ready": True,
        "src2_value": 0x2000,
        "src3_ready": True,
        "src3_value": 0x3000,
        "imm": 0x10,
    }
    slot2: dict[str, Any] = {
        "rob_tag": 11,
        "op": OP_SUB,
        "src1_ready": True,
        "src1_value": 0x4000,
        "src2_ready": True,
        "src2_value": 0x5000,
        "src3_ready": True,
        "src3_value": 0x6000,
        "imm": 0x20,
    }

    dut_if.drive_dispatch(**slot1)
    dut_if.drive_dispatch_2(intent_1=True, **slot2)
    model.dispatch(**slot1)
    model.dispatch(**slot2)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_dispatch_2()

    assert dut_if.count == 2, f"Count should be 2, got {dut_if.count}"

    dut_if.set_fu_ready(True)
    await dut_if.step()

    for expected_tag in (10, 11):
        issue = dut_if.read_issue()
        model_issue = model.try_issue(fu_ready=True)
        check_issue(issue, model_issue, f"dual dispatch issue tag={expected_tag}")
        assert (
            issue["rob_tag"] == expected_tag
        ), f"Expected tag {expected_tag}, got {issue['rob_tag']}"
        await dut_if.step()

    assert dut_if.empty, "Should be empty after issuing both dual-dispatch entries"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_indexed_repair_dual_dispatch_sources(dut: Any) -> None:
    """Each dispatch slot's repair channels update only its allocated entry."""
    cocotb.log.info("=== Test: Indexed Repair Dual Dispatch ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=20,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=1,
        src2_ready=False,
        src2_tag=2,
        src3_ready=False,
        src3_tag=3,
    )
    dut_if.drive_dispatch_2(
        intent_1=True,
        rob_tag=21,
        op=OP_SUB,
        src1_ready=False,
        src1_tag=4,
        src2_ready=False,
        src2_tag=5,
        src3_ready=False,
        src3_tag=6,
    )
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_dispatch_2()

    for channel, tag, value in (
        (1, 1, 0x1111),
        (2, 2, 0x2222),
        (3, 3, 0x3333),
        (4, 4, 0x4444),
        (5, 5, 0x5555),
        (6, 6, 0x6666),
    ):
        dut_if.drive_repair(channel, tag, value)
    await dut_if.step()
    dut_if.clear_repairs()

    dut_if.set_fu_ready(True)
    await dut_if.step()
    first = dut_if.read_issue()
    assert first["valid"] and first["rob_tag"] == 20
    assert (first["src1_value"], first["src2_value"], first["src3_value"]) == (
        0x1111,
        0x2222,
        0x3333,
    )

    await dut_if.step()
    second = dut_if.read_issue()
    assert second["valid"] and second["rob_tag"] == 21
    assert (second["src1_value"], second["src2_value"], second["src3_value"]) == (
        0x4444,
        0x5555,
        0x6666,
    )

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_indexed_repair_back_to_back_and_cdb_priority(dut: Any) -> None:
    """Repair an old target while capturing the next; a live CDB wins data priority."""
    cocotb.log.info("=== Test: Indexed Repair Back-to-Back + CDB Priority ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=22,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=7,
        src2_ready=True,
        src2_value=0x22,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # The old allocation consumes channel 1 while a new allocation captures
    # the next cycle's channel-1 target.  Deliberately disagree on values to
    # prove the existing CDB0 > CDB1 > repair priority is retained.
    dut_if.drive_dispatch(
        rob_tag=23,
        op=OP_SUB,
        src1_ready=False,
        src1_tag=8,
        src2_ready=True,
        src2_value=0x23,
        src3_ready=True,
    )
    dut_if.drive_repair(1, tag=7, value=0xBAD0)
    dut_if.drive_cdb(tag=7, value=0xCDB0)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_repairs()
    dut_if.clear_cdb()

    dut_if.drive_repair(1, tag=8, value=0x8888)
    await dut_if.step()
    dut_if.clear_repairs()

    dut_if.set_fu_ready(True)
    await dut_if.step()
    first = dut_if.read_issue()
    assert first["valid"] and first["rob_tag"] == 22
    assert first["src1_value"] == 0xCDB0

    await dut_if.step()
    second = dut_if.read_issue()
    assert second["valid"] and second["rob_tag"] == 23
    assert second["src1_value"] == 0x8888

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_indexed_repair_flush_discards_target(dut: Any) -> None:
    """A flush drops the saved target before the physical entry is reused."""
    cocotb.log.info("=== Test: Indexed Repair Flush Target ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=24,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=9,
        src2_ready=True,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    dut_if.drive_repair(1, tag=9, value=0x9999)
    dut.i_flush_all.value = 1
    await dut_if.step()
    dut_if.clear_repairs()
    dut.i_flush_all.value = 0
    assert dut_if.empty

    # Reuse the low-index entry.  It must remain blocked until its own repair
    # arrives; the flushed packet's response cannot leak into it.
    dut_if.drive_dispatch(
        rob_tag=25,
        op=OP_SUB,
        src1_ready=False,
        src1_tag=10,
        src2_ready=True,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.set_fu_ready(True)
    assert not dut_if.read_issue()["valid"]

    # The replacement packet's own fixed-latency response arrives now.
    dut_if.drive_repair(1, tag=10, value=0xAAAA)
    await dut_if.step()
    dut_if.clear_repairs()
    await dut_if.step()
    issue = dut_if.read_issue()
    assert issue["valid"] and issue["rob_tag"] == 25
    assert issue["src1_value"] == 0xAAAA

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_slot2_cdb_bypass_at_dispatch(dut: Any) -> None:
    """Slot-2 dispatch-cycle CDB match wakes via the deferred delivery."""
    cocotb.log.info("=== Test: Slot 2 CDB Bypass at Dispatch ===")
    dut_if, model = await setup_test(dut)

    dut_if.drive_dispatch_2(
        rob_tag=12,
        op=OP_AND,
        src1_ready=False,
        src1_tag=6,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    dut_if.drive_cdb(tag=6, value=0xCAFE)
    model.dispatch(
        rob_tag=12,
        op=OP_AND,
        src1_ready=False,
        src1_tag=6,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
        cdb_valid=True,
        cdb_tag=6,
        cdb_value=0xCAFE,
    )
    await dut_if.step()
    dut_if.clear_dispatch_2()
    dut_if.clear_cdb()

    # Deferred dispatch-CDB capture: the broadcast value arrives via the
    # registered lane copy one cycle after dispatch, so no issue yet.
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: deferred delivery lands ready+value
    assert not dut_if.issue_valid, "dispatch-cycle CDB wake must defer one cycle"
    model.deliver_pending()

    await dut_if.step()  # rising edge: issue_fire loads stage2
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "slot-2 CDB bypass at dispatch")
    assert issue["rob_tag"] == 12
    assert issue["src1_value"] == 0xCAFE, "src1 should capture CDB value"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_full_for_2_blocks_slot2_of_dual_dispatch(dut: Any) -> None:
    """Near-full RS accepts slot 1 but blocks slot 2 of a dual dispatch."""
    cocotb.log.info("=== Test: Full-for-2 Blocks Slot 2 of Dual Dispatch ===")
    dut_if, model = await setup_test(dut)

    for i in range(RS_DEPTH - 1):
        dispatch: dict[str, Any] = {
            "rob_tag": i,
            "op": OP_ADD,
            "src1_ready": False,
            "src1_tag": (i + 10) & MASK_TAG,
            "src2_ready": False,
            "src2_tag": (i + 20) & MASK_TAG,
            "src3_ready": True,
        }
        dut_if.drive_dispatch(**dispatch)
        model.dispatch(**dispatch)
        await dut_if.step()
        dut_if.clear_dispatch()

    assert dut_if.count == RS_DEPTH - 1, f"Count should be {RS_DEPTH - 1}"
    full_before_dual = dut_if.full
    assert not full_before_dual, "Should not be full with one free entry"
    assert dut_if.full_for_2, "Should be full_for_2 with one free entry"
    assert model.is_full_for_2(), "Model should also be full_for_2"

    slot1: dict[str, Any] = {
        "rob_tag": 20,
        "op": OP_OR,
        "src1_ready": True,
        "src1_value": 0xAAAA,
        "src2_ready": True,
        "src2_value": 0xBBBB,
        "src3_ready": True,
    }
    slot2: dict[str, Any] = {
        "rob_tag": 21,
        "op": OP_SUB,
        "src1_ready": True,
        "src1_value": 0xCCCC,
        "src2_ready": True,
        "src2_value": 0xDDDD,
        "src3_ready": True,
    }

    dut_if.drive_dispatch(**slot1)
    dut_if.drive_dispatch_2(intent_1=True, **slot2)
    model.dispatch(**slot1)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_dispatch_2()

    assert (
        dut_if.count == RS_DEPTH
    ), f"Only slot 1 should be accepted, got {dut_if.count}"
    full_after_slot1 = dut_if.full
    assert full_after_slot1, "Should be full after accepting slot 1"

    dut_if.set_fu_ready(True)
    await dut_if.step()
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "near-full accepted slot 1")
    assert issue["rob_tag"] == 20, "Slot 2 should have been blocked"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_partial_flush_after_dual_dispatch(dut: Any) -> None:
    """Partial flush removes a younger slot-2 entry from a dual dispatch."""
    cocotb.log.info("=== Test: Partial Flush After Dual Dispatch ===")
    dut_if, model = await setup_test(dut)

    slot1: dict[str, Any] = {
        "rob_tag": 1,
        "op": OP_ADD,
        "src1_ready": True,
        "src1_value": 0x1111,
        "src2_ready": True,
        "src2_value": 0x2222,
        "src3_ready": True,
    }
    slot2: dict[str, Any] = {
        "rob_tag": 5,
        "op": OP_SUB,
        "src1_ready": True,
        "src1_value": 0x3333,
        "src2_ready": True,
        "src2_value": 0x4444,
        "src3_ready": True,
    }

    dut_if.drive_dispatch(**slot1)
    dut_if.drive_dispatch_2(intent_1=True, **slot2)
    model.dispatch(**slot1)
    model.dispatch(**slot2)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_dispatch_2()

    assert dut_if.count == 2, f"Count should be 2, got {dut_if.count}"

    dut_if.drive_partial_flush(flush_tag=1, head_tag=0)
    model.partial_flush(flush_tag=1, head_tag=0)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert (
        dut_if.count == 1
    ), f"Only the older slot-1 entry should remain, got {dut_if.count}"

    dut_if.set_fu_ready(True)
    await dut_if.step()
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "dual dispatch survivor")
    assert issue["rob_tag"] == 1, "Older slot-1 entry should survive flush"

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
    # CDB bypass wakeup: entry becomes ready same cycle as CDB broadcast,
    # issue_fire loads stage2 at the next posedge (1 step, not 2).
    dut_if.drive_cdb(tag=5, value=0xDEAD)
    model.cdb_snoop(tag=5, value=0xDEAD)

    await dut_if.step()
    dut_if.clear_cdb()

    # Now should issue from stage2 (CDB bypass wakeup: 1 cycle after broadcast)
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

    # CDB bypass wakeup: issue appears 1 cycle after broadcast
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

    # CDB bypass wakeup: issue appears 1 cycle after broadcast
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

    # CDB bypass wakeup: issue appears 1 cycle after broadcast
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
    # Stage2 pipeline: need one step for issue_fire to load stage2
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads stage2 with entry 0
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "entry 0 issues first")
    assert issue["rob_tag"] == 0, "Entry 0 should issue first (priority)"

    # Step to consume entry 0, back-to-back refill with entry 1
    await dut_if.step()

    # Entry 1 should issue next via back-to-back pipeline refill
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "entry 1 issues second")
    assert issue["rob_tag"] == 1, "Entry 1 should issue second"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_bypass_at_dispatch(dut: Any) -> None:
    """Dispatch-cycle CDB match delivers ready+value one cycle later."""
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

    # Deferred dispatch-CDB capture: the entry wakes one cycle later than a
    # resident wakeup would — the delivery cycle moves the registered lane
    # copy into the value array and sets ready; only then can issue fire.
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: deferred delivery lands ready+value
    assert not dut_if.issue_valid, "dispatch-cycle CDB wake must defer one cycle"
    model.deliver_pending()

    await dut_if.step()  # rising edge: issue_fire loads stage2
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "CDB bypass at dispatch")
    assert issue["valid"], "Should issue with CDB bypass"
    assert issue["src1_value"] == 0xCAFE, "src1_value should be CDB value"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_cdb_replay_dual_slot_dual_lane(dut: Any) -> None:
    """Both allocation slots replay both CDB lanes across all source positions."""
    cocotb.log.info("=== Test: Dispatch CDB Replay Dual Slot + Dual Lane ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=26,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=10,
        src1_value=0xA001,
        src2_ready=False,
        src2_tag=11,
        src2_value=0xA002,
        src3_ready=False,
        src3_tag=10,
        src3_value=0xA003,
    )
    dut_if.drive_dispatch_2(
        intent_1=True,
        rob_tag=27,
        op=OP_SUB,
        src1_ready=False,
        src1_tag=11,
        src1_value=0xB001,
        src2_ready=False,
        src2_tag=10,
        src2_value=0xB002,
        src3_ready=False,
        src3_tag=11,
        src3_value=0xB003,
    )
    dut_if.drive_cdb(tag=10, value=0x1010)
    dut_if.drive_cdb_2(tag=11, value=0x1111)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_dispatch_2()
    dut_if.clear_cdb()
    dut_if.clear_cdb_2()

    dut_if.set_fu_ready(True)
    await dut_if.step()
    assert not dut_if.issue_valid, "replay delivery must remain sequential"

    await dut_if.step()
    first = dut_if.read_issue()
    assert first["valid"] and first["rob_tag"] == 26
    assert (first["src1_value"], first["src2_value"], first["src3_value"]) == (
        0x1010,
        0x1111,
        0x1010,
    )

    await dut_if.step()
    second = dut_if.read_issue()
    assert second["valid"] and second["rob_tag"] == 27
    assert (second["src1_value"], second["src2_value"], second["src3_value"]) == (
        0x1111,
        0x1010,
        0x1111,
    )

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_cdb_replay_back_to_back_lane0_priority(dut: Any) -> None:
    """Back-to-back replay captures remain distinct and lane 0 wins a collision."""
    cocotb.log.info("=== Test: Dispatch CDB Replay Back-to-Back + Lane Priority ===")
    dut_if, _ = await setup_test(dut)

    # The CDB contract normally gives the two lanes distinct tags.  Drive a
    # deliberate same-tag collision to check that priority is captured in the
    # entry's lane selector, with lane 0's registered value winning.
    dut_if.drive_dispatch(
        rob_tag=18,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=18,
        src1_value=0xBAD,
        src2_ready=True,
        src2_value=0x1818,
        src3_ready=True,
    )
    dut_if.drive_cdb(tag=18, value=0xA180)
    dut_if.drive_cdb_2(tag=18, value=0xA181)
    await dut_if.step()

    # Capture a second allocation while the first entry's pend/lane state and
    # registered value are being consumed. Nonblocking ordering must preserve
    # both deliveries.
    dut_if.drive_dispatch(
        rob_tag=19,
        op=OP_SUB,
        src1_ready=False,
        src1_tag=19,
        src1_value=0xBAD,
        src2_ready=True,
        src2_value=0x1919,
        src3_ready=True,
    )
    dut_if.clear_cdb()
    dut_if.drive_cdb_2(tag=19, value=0xB191)
    await dut_if.step()

    dut_if.clear_dispatch()
    dut_if.clear_cdb_2()
    await dut_if.step()

    dut_if.set_fu_ready(True)
    await dut_if.step()
    first = dut_if.read_issue()
    assert first["valid"] and first["rob_tag"] == 18
    assert first["src1_value"] == 0xA180

    await dut_if.step()
    second = dut_if.read_issue()
    assert second["valid"] and second["rob_tag"] == 19
    assert second["src1_value"] == 0xB191

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_first_resident_unrelated_live_cdb_still_bypasses(dut: Any) -> None:
    """No pending match may suppress a true first-resident lane-1 wakeup."""
    cocotb.log.info("=== Test: First Resident Unrelated Live CDB Bypass ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=28,
        op=OP_AND,
        src1_ready=False,
        src1_tag=7,
        src1_value=0xBAD,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    # The dispatch-cycle lane is valid but does not match src1.
    dut_if.drive_cdb(tag=6, value=0x6666)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_cdb()

    # During the first-resident cycle, a different live tag does match src1.
    # It must issue through lane 1 on this edge; blanket token suppression
    # would add an observable cycle here.
    dut_if.drive_cdb_2(tag=7, value=0x7777)
    dut_if.set_fu_ready(True)
    await dut_if.step()
    issue = dut_if.read_issue()
    dut_if.clear_cdb_2()
    assert issue["valid"] and issue["rob_tag"] == 28
    assert issue["src1_value"] == 0x7777

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_cdb_replay_blocks_tag_aba_live_bypass(dut: Any) -> None:
    """A same-tag live rebroadcast cannot replace the captured prior value."""
    cocotb.log.info("=== Test: Dispatch CDB Replay Tag ABA ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=29,
        op=OP_OR,
        src1_ready=False,
        src1_tag=12,
        src1_value=0xBAD,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    dut_if.drive_cdb(tag=12, value=0xCAFE)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_cdb()

    # Hypothetical immediate ROB-tag reuse: the current lane has the same tag
    # but a foreign value.  Replay must suppress issue for this edge and its
    # last data write must retain the dispatch-cycle value.
    dut_if.drive_cdb_2(tag=12, value=0xDEAD)
    dut_if.set_fu_ready(True)
    await dut_if.step()
    assert not dut_if.issue_valid, "true prior replay must suppress ABA live bypass"
    dut_if.clear_cdb_2()

    await dut_if.step()
    issue = dut_if.read_issue()
    assert issue["valid"] and issue["rob_tag"] == 29
    assert issue["src1_value"] == 0xCAFE

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_cdb_replay_ignores_ready_source_tag(dut: Any) -> None:
    """A ready source keeps its packet value even when its tag matches replay."""
    cocotb.log.info("=== Test: Dispatch CDB Replay Ready Source Immunity ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=30,
        op=OP_ADD,
        src1_ready=True,
        src1_tag=13,
        src1_value=0x1357,
        src2_ready=True,
        src2_value=0x2468,
        src3_ready=True,
    )
    dut_if.drive_cdb(tag=13, value=0xDEAD)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_cdb()

    # Hold issue off through the replay edge so a bad replay write cannot be
    # hidden by a dispatch-cycle issue capture.
    await dut_if.step()
    dut_if.set_fu_ready(True)
    await dut_if.step()
    issue = dut_if.read_issue()
    assert issue["valid"] and issue["rob_tag"] == 30
    assert issue["src1_value"] == 0x1357

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_cdb_replay_coalesces_indexed_repair(dut: Any) -> None:
    """Replay and the same allocation-indexed repair may land together."""
    cocotb.log.info("=== Test: Dispatch CDB Replay + Indexed Repair ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=31,
        op=OP_SUB,
        src1_ready=False,
        src1_tag=14,
        src1_value=0xBAD,
        src2_ready=True,
        src2_value=0x1414,
        src3_ready=True,
    )
    dut_if.drive_cdb(tag=14, value=0xE14E)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_cdb()

    # Channel 1 is the slot-1/src1 fixed-position response.  The wrapper's
    # coalesce contract requires the same producer value as prior-lane replay.
    dut_if.drive_repair(1, tag=14, value=0xE14E)
    dut_if.set_fu_ready(True)
    await dut_if.step()
    assert not dut_if.issue_valid
    dut_if.clear_repairs()

    await dut_if.step()
    issue = dut_if.read_issue()
    assert issue["valid"] and issue["rob_tag"] == 31
    assert issue["src1_value"] == 0xE14E

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_cdb_replay_flush_discards_target(dut: Any) -> None:
    """A flush in the replay cycle prevents stale delivery after index reuse."""
    cocotb.log.info("=== Test: Dispatch CDB Replay Flush Target ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=15,
        src2_ready=True,
        src3_ready=True,
    )
    dut_if.drive_cdb(tag=15, value=0x1515)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_cdb()

    dut_if.drive_flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()
    assert dut_if.empty

    # Reuse entry zero with a different pending source. Neither the flushed
    # per-entry pending/lane state nor its prior CDB value may wake the
    # replacement.
    dut_if.drive_dispatch(
        rob_tag=2,
        op=OP_SUB,
        src1_ready=False,
        src1_tag=16,
        src1_value=0xBAD,
        src2_ready=True,
        src2_value=0x1616,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.set_fu_ready(True)
    await dut_if.step()
    assert not dut_if.issue_valid

    dut_if.drive_cdb(tag=16, value=0xBEEF)
    await dut_if.step()
    dut_if.clear_cdb()
    issue = dut_if.read_issue()
    assert issue["valid"] and issue["rob_tag"] == 2
    assert issue["src1_value"] == 0xBEEF

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dispatch_cdb_replay_survives_partial_flush(dut: Any) -> None:
    """Replay still delivers when its older entry survives a partial flush."""
    cocotb.log.info("=== Test: Dispatch CDB Replay During Partial Flush ===")
    dut_if, _ = await setup_test(dut)

    dut_if.drive_dispatch(
        rob_tag=1,
        op=OP_ADD,
        src1_ready=False,
        src1_tag=17,
        src1_value=0xBAD,
        src2_ready=True,
        src2_value=0x1717,
        src3_ready=True,
    )
    dut_if.drive_cdb(tag=17, value=0xA17A)
    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.clear_cdb()

    # rob_tag 1 is older than the boundary at tag 2 relative to head 0.  Issue
    # is suppressed during flush, but replay must still update this survivor.
    dut_if.drive_partial_flush(flush_tag=2, head_tag=0)
    dut_if.set_fu_ready(True)
    await dut_if.step()
    dut_if.clear_partial_flush()
    assert dut_if.count == 1
    assert not dut_if.issue_valid

    await dut_if.step()
    issue = dut_if.read_issue()
    assert issue["valid"] and issue["rob_tag"] == 1
    assert issue["src1_value"] == 0xA17A

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

    # Stage2 pipeline: first step loads stage2 with entry 0
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads stage2 with entry 0

    # Issue all 3, verify order is index 0, 1, 2
    for expected_tag in range(3):
        issue = dut_if.read_issue()
        model_issue = model.try_issue(fu_ready=True)
        check_issue(issue, model_issue, f"priority issue tag={expected_tag}")
        assert (
            issue["rob_tag"] == expected_tag
        ), f"Expected tag {expected_tag}, got {issue['rob_tag']}"
        await dut_if.step()  # consume current, back-to-back refill with next

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

    # FU not ready — nothing moves to stage2
    dut_if.set_fu_ready(False)
    await dut_if.step()  # rising edge: no issue_fire (fu_ready=0), stage2 stays empty
    assert not dut_if.issue_valid, "Should not issue when FU not ready"

    # Make FU ready — issue_fire loads stage2
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads stage2
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
        src2_ready=True,
        src2_tag=0,
        src3_ready=True,
        use_imm=True,
        imm=0x42,
    )
    model.dispatch(
        rob_tag=6,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=True,
        src2_tag=0,
        src3_ready=True,
        use_imm=True,
        imm=0x42,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # Dispatch is responsible for marking unused src2 operands ready.
    # Stage2 pipeline: need one step for issue_fire to load stage2
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads stage2
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "use_imm ready path")
    assert issue["valid"], "Should issue when dispatch already marked src2 ready"
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

    # Stage2 pipeline: need one step for issue_fire to load stage2
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads stage2
    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "full field check")

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_xlen_wide_issue_metadata(dut: Any) -> None:
    """Preserve upper-half immediate, PC, and target fields at XLEN=64."""
    cocotb.log.info("=== Test: XLEN-Wide Issue Metadata ===")
    dut_if, model = await setup_test(dut)

    xlen_fields = {
        "imm": 0xF123_4567_89AB_CDEF,
        "branch_target": 0x8123_4567_8000_1000,
        "predicted_target": 0x9234_5678_8000_2000,
        "pc": 0xA345_6789_8000_3000,
    }
    dispatch: dict[str, Any] = {
        "rob_tag": 9,
        "op": OP_ADD,
        "src1_ready": True,
        "src1_value": 0x1111_2222_3333_4444,
        "src2_ready": True,
        "src2_value": 0x5555_6666_7777_8888,
        "src3_ready": True,
        "src3_value": 0x9999_AAAA_BBBB_CCCC,
        "use_imm": True,
        "predicted_taken": True,
        **xlen_fields,
    }

    dut_if.drive_dispatch(**dispatch)
    idx = model.dispatch(**dispatch)
    assert idx is not None

    expected_fields = {name: value & MASK_XLEN for name, value in xlen_fields.items()}
    entry = model.entries[idx]
    for name, expected in expected_fields.items():
        assert getattr(entry, name) == expected, (
            f"model {name} mismatch: got {getattr(entry, name):#x}, "
            f"expected {expected:#x}"
        )
    if XLEN == 64:
        assert all(
            value >> 32 for value in expected_fields.values()
        ), "RV64 directed metadata vectors must exercise every upper half"

    await dut_if.step()
    dut_if.clear_dispatch()
    dut_if.set_fu_ready(True)
    await dut_if.step()

    issue = dut_if.read_issue()
    model_issue = model.try_issue(fu_ready=True)
    check_issue(issue, model_issue, "XLEN-wide metadata")
    for name, expected in expected_fields.items():
        assert (
            issue[name] == expected
        ), f"DUT {name} mismatch: got {issue[name]:#x}, expected {expected:#x}"

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
    # Stage2 pipeline: need one step for issue_fire to load stage2
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads stage2
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

    # Stage2 pipeline: need one step for issue_fire to load stage2
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads stage2
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
    issued_count = 0

    # Stage2 pipeline delay tracking: the DUT's issue output is 1 cycle behind
    # the model's prediction because of the stage2 register.
    prev_model_issue: dict | None = None
    prev_model_issue_info: tuple[int, dict] | None = None

    for cycle in range(200):
        await Timer(1, unit="ps")

        # Read DUT state from settled registered state
        dut_full = dut_if.full
        dut_count = dut_if.count

        # Compare DUT output with PREVIOUS cycle's model prediction (stage2 delay)
        issue = dut_if.read_issue()
        if prev_model_issue is not None:
            assert issue["valid"], f"Cycle {cycle}: model issued but DUT did not"
            check_issue(issue, prev_model_issue, f"cycle {cycle}")
            issued_count += 1
        else:
            assert not issue["valid"], f"Cycle {cycle}: DUT issued but model did not"

        # Consume the previous cycle's issued entry from the model
        if prev_model_issue_info is not None:
            model.consume_issue(prev_model_issue_info[0])

        # Drive new inputs for this cycle.
        # CDB is driven BEFORE the model peek so same-cycle CDB bypass wakeup
        # is reflected.  Dispatch is driven AFTER the peek because newly-
        # dispatched entries take one extra cycle to register in the DUT RS.
        action = random.choice(["dispatch", "cdb", "idle"])

        if action == "cdb" and dut_count > 0:
            cdb_tag = random.randint(0, 31)
            cdb_value = random.getrandbits(64)
            dut_if.drive_cdb(tag=cdb_tag, value=cdb_value)
            model.cdb_snoop(tag=cdb_tag, value=cdb_value)

        # Peek what the model WOULD issue this cycle (will appear on DUT next
        # cycle).  Peek AFTER CDB snoop so same-cycle CDB bypass wakeup is
        # reflected, but BEFORE dispatch so newly-dispatched entries (which
        # need one cycle to register) don't appear prematurely.
        model_issue_info = model.peek_issue(fu_ready=True)
        prev_model_issue = model_issue_info[1] if model_issue_info is not None else None
        prev_model_issue_info = model_issue_info

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

        # Step: DUT registers inputs, issue_fire loads stage2, CDB wakeup
        await dut_if.step()
        dut_if.clear_dispatch()
        dut_if.clear_cdb()

    if prev_model_issue_info is not None:
        issue = dut_if.read_issue()
        assert issue["valid"], "Final drain: model issued but DUT did not"
        check_issue(issue, prev_model_issue, "final drain")
        model.consume_issue(prev_model_issue_info[0])

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

    # Stage2 pipeline delay tracking: the DUT's issue output is 1 cycle behind
    # the model's prediction because of the stage2 register.
    prev_model_issue: dict | None = None
    prev_model_issue_info: tuple[int, dict] | None = None

    for cycle in range(200):
        await Timer(1, unit="ps")

        # Read DUT state from settled registered state
        dut_full = dut_if.full
        dut_count = dut_if.count

        # Compare DUT output with PREVIOUS cycle's model prediction (stage2 delay)
        issue = dut_if.read_issue()
        if prev_model_issue is not None:
            assert issue["valid"], f"Cycle {cycle}: model issued but DUT did not"
        else:
            assert not issue["valid"], f"Cycle {cycle}: DUT issued but model did not"

        # Consume the previous cycle's issued entry from the model
        if prev_model_issue_info is not None:
            model.consume_issue(prev_model_issue_info[0])

        # Drive new inputs for this cycle.
        # CDB/flush is driven BEFORE the model peek so same-cycle CDB bypass
        # wakeup is reflected.  Dispatch is driven AFTER the peek because
        # newly-dispatched entries take one extra cycle to register in the DUT.
        action = random.choices(
            ["dispatch", "cdb", "flush_all", "partial_flush", "idle"],
            weights=[40, 30, 5, 10, 15],
        )[0]

        flush_applied = False

        if action == "cdb" and dut_count > 0:
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

        # Flush squashes any pending stage2 instruction
        if flush_applied:
            prev_model_issue = None
            prev_model_issue_info = None

        # Peek AFTER CDB snoop/flush but BEFORE dispatch.
        if not flush_applied:
            model_issue_info = model.peek_issue(fu_ready=True)
            prev_model_issue = (
                model_issue_info[1] if model_issue_info is not None else None
            )
            prev_model_issue_info = model_issue_info

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

        # Step: DUT registers inputs, issue_fire loads stage2, flush/CDB
        await dut_if.step()
        dut_if.clear_dispatch()
        dut_if.clear_cdb()
        dut_if.clear_flush_all()
        dut_if.clear_partial_flush()

    if prev_model_issue_info is not None:
        issue = dut_if.read_issue()
        assert issue["valid"], "Final drain: model issued but DUT did not"
        model.consume_issue(prev_model_issue_info[0])

    # Final count check
    assert (
        dut_if.count == model.count()
    ), f"Final count mismatch: DUT={dut_if.count} model={model.count()}"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# SC Issue Peek Tests
# =============================================================================


@cocotb.test()
async def test_next_issue_is_sc_output(dut: Any) -> None:
    """o_next_issue_is_sc goes high when next-to-issue entry is SC_W."""
    cocotb.log.info("=== Test: Next Issue Is SC Output ===")
    dut_if, _ = await setup_test(dut)

    # Initially no entries → should be low
    sc_sig = dut.o_next_issue_is_sc
    assert not int(sc_sig.value), "o_next_issue_is_sc should be low when RS empty"

    # Dispatch an SC_W entry with all operands ready
    dut_if.drive_dispatch(
        rob_tag=1,
        op=OP_SC_W,
        src1_ready=True,
        src1_value=0x1000,
        src2_ready=True,
        src2_value=0xAABB,
        src3_ready=True,
        imm=0,
        use_imm=True,
    )
    await dut_if.step()
    dut_if.clear_dispatch()

    # o_next_issue_is_sc now reads from stage2 (registered), so we need
    # fu_ready=True + step to load the SC_W entry into stage2 first.
    dut_if.set_fu_ready(True)
    await dut_if.step()  # rising edge: issue_fire loads SC_W into stage2
    await Timer(1, unit="ps")
    assert int(sc_sig.value), "o_next_issue_is_sc should be high for ready SC_W entry"

    # Consume the SC_W entry from stage2
    await dut_if.step()  # rising edge: stage2 consumed
    dut_if.set_fu_ready(False)

    # RS is now empty, stage2 consumed → o_next_issue_is_sc should be low
    await Timer(1, unit="ps")
    assert not int(sc_sig.value), "o_next_issue_is_sc should be low after SC issued"
    assert dut_if.empty, "RS should be empty after issue"

    cocotb.log.info("=== Test Passed ===")

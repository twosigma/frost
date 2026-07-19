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

"""Tomasulo wrapper tests for cpu_ooo's split-RS dispatch parameterization."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
)

from .tomasulo_interface import (
    RS_FDIV,
    RS_FMUL,
    RS_FP,
    RS_INT,
    RS_MEM,
    RS_MUL,
    TomasuloInterface,
)

ALL_RS_TYPES = [RS_INT, RS_MUL, RS_MEM, RS_FP, RS_FMUL, RS_FDIV]
RS_NAMES = {
    RS_INT: "INT_RS",
    RS_MUL: "MUL_RS",
    RS_MEM: "MEM_RS",
    RS_FP: "FP_RS",
    RS_FMUL: "FMUL_RS",
    RS_FDIV: "FDIV_RS",
}


async def setup_test(dut: Any) -> TomasuloInterface:
    """Initialize clock, wrapper interface, and reset DUT."""
    clock = Clock(dut.i_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    dut_if = TomasuloInterface(dut)
    await dut_if.reset_dut()
    return dut_if


def ready_payload(rob_tag: int, op: int = 0) -> dict[str, Any]:
    """Return an RS dispatch payload that will enqueue but not issue."""
    return {
        "rob_tag": rob_tag,
        "op": op,
        "src1_ready": True,
        "src1_value": 0x1000 + rob_tag,
        "src2_ready": True,
        "src2_value": 0x2000 + rob_tag,
        "src3_ready": True,
        "src3_value": 0x3000 + rob_tag,
    }


async def step_and_clear_dispatch(dut_if: TomasuloInterface) -> None:
    """Commit one dispatch cycle, then clear every dispatch input family."""
    await dut_if.step()
    dut_if.clear_rs_dispatch()
    dut_if.clear_split_rs_dispatch()
    dut_if.clear_split_rs_dispatch_2()


def assert_rs_counts(
    dut_if: TomasuloInterface, expected_counts: dict[int, int]
) -> None:
    """Assert all RS counts match expected values."""
    for rs_type in ALL_RS_TYPES:
        expected = expected_counts.get(rs_type, 0)
        actual = dut_if.rs_count_for(rs_type)
        assert (
            actual == expected
        ), f"{RS_NAMES[rs_type]} count mismatch: got {actual}, expected {expected}"


@cocotb.test()
async def test_split_rs_slot1_routes_each_family(dut: Any) -> None:
    """Slot-1 per-RS split dispatch ports route to every RS family."""
    cocotb.log.info("=== Test: Split RS Slot-1 Routes Each Family ===")
    dut_if = await setup_test(dut)

    expected_counts: dict[int, int] = {}
    for idx, rs_type in enumerate(ALL_RS_TYPES, start=1):
        dut_if.drive_split_rs_dispatch(rs_type, **ready_payload(idx))
        await step_and_clear_dispatch(dut_if)
        expected_counts[rs_type] = expected_counts.get(rs_type, 0) + 1
        assert_rs_counts(dut_if, expected_counts)

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_split_rs_slot2_same_family_allocates_second_entry(dut: Any) -> None:
    """Slot 1 and slot 2 can dispatch to the same RS through split ports."""
    cocotb.log.info("=== Test: Split RS Slot-2 Same Family ===")
    dut_if = await setup_test(dut)

    dut_if.drive_split_rs_dispatch(RS_INT, **ready_payload(1))
    dut_if.drive_split_rs_dispatch_2(RS_INT, **ready_payload(2))
    await step_and_clear_dispatch(dut_if)

    assert_rs_counts(dut_if, {RS_INT: 2})

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_split_rs_slot2_different_family_routes_independently(dut: Any) -> None:
    """Slot 2 can route to a different RS family than slot 1 in split mode."""
    cocotb.log.info("=== Test: Split RS Slot-2 Different Family ===")
    dut_if = await setup_test(dut)

    dut_if.drive_split_rs_dispatch(RS_INT, **ready_payload(3))
    dut_if.drive_split_rs_dispatch_2(RS_MEM, **ready_payload(4))
    await step_and_clear_dispatch(dut_if)

    assert_rs_counts(dut_if, {RS_INT: 1, RS_MEM: 1})

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_split_rs_ignores_legacy_single_bus_dispatch(dut: Any) -> None:
    """The split-RS production parameter ignores the legacy single dispatch bus."""
    cocotb.log.info("=== Test: Split RS Ignores Legacy Single Bus ===")
    dut_if = await setup_test(dut)

    dut_if.drive_rs_dispatch(RS_INT, **ready_payload(5))
    dut_if.drive_split_rs_dispatch(RS_MEM, **ready_payload(6))
    await step_and_clear_dispatch(dut_if)

    assert_rs_counts(dut_if, {RS_MEM: 1})

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_split_fp_pending_done_repair_survives_recovery_hold(dut: Any) -> None:
    """Production split dispatch retains an FP repair while dequeue is held."""
    cocotb.log.info("=== Test: Split FP Pending Done Repair Under Hold ===")
    dut_if = await setup_test(dut)
    dut_if.set_commit_hold(True)

    producer_value = 0x3FF0_0000_0000_0000
    producer_tag = await dut_if.dispatch(
        AllocationRequest(pc=0x7000, dest_rf=1, dest_reg=1, dest_valid=True)
    )
    dut_if.drive_cdb_write(CDBWrite(tag=producer_tag, value=producer_value))
    await dut_if.step()
    dut_if.clear_cdb_write()

    dut_if.set_read_tag(producer_tag)
    for _ in range(6):
        await Timer(1, unit="ps")
        if dut_if.read_entry_done():
            break
        await dut_if.step()
    assert dut_if.read_entry_done()
    assert dut_if.read_entry_value() == producer_value

    consumer_tag = await dut_if.dispatch(
        AllocationRequest(pc=0x7004, dest_rf=1, dest_reg=2, dest_valid=True)
    )
    dut_if.drive_split_rs_dispatch(
        RS_FP,
        rob_tag=consumer_tag,
        op=0,
        src1_ready=False,
        src1_tag=producer_tag,
        src2_ready=True,
        src2_value=0x4000_0000_0000_0000,
        src3_ready=True,
    )
    await step_and_clear_dispatch(dut_if)

    # Hold only after the split-routed packet is resident in the FP buffer.
    dut.i_backend_recovery_hold.value = 1
    dut_if.drive_dispatch_bypass(1, producer_tag)
    dut_if.set_fu_ready(RS_FP, True)
    await dut_if.step()
    dut_if.clear_dispatch_bypasses()

    dut.i_backend_recovery_hold.value = 0
    issue = None
    for _ in range(8):
        await Timer(1, unit="ps")
        candidate = dut_if.read_rs_issue_for(RS_FP)
        if candidate["valid"]:
            issue = candidate
            break
        await dut_if.step()
    assert issue is not None, "Split-routed FP packet never issued after recovery hold"
    assert issue["rob_tag"] == consumer_tag
    assert issue["src1_value"] == producer_value

    cocotb.log.info("=== Test Passed ===")

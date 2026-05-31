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

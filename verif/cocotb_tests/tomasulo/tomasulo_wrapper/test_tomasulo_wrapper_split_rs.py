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

"""Tomasulo wrapper tests for cpu_ooo's split-RS dispatch parameterization.

Includes directed coverage of the production INT_RS depth-8 fill boundary,
primary-issue effective operand capture through both issue-only CDB metadata
anchors, SQ-local CDB-lane repair timing, FP pending-repair recovery hold, and
both effective ALU CDB packets for test-injection, live-adapter, and
held-adapter source states.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer
from config import MASK_XLEN, XLEN

from cocotb_tests.tomasulo.cdb_arbiter.cdb_arbiter_interface import (
    unpack_cdb_broadcast,
)
from cocotb_tests.tomasulo.cdb_arbiter.cdb_arbiter_model import (
    CdbBroadcast,
    FU_ALU,
    FU_ALU2,
    FU_FP_ADD,
    FU_MEM,
    FU_MUL,
)
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
    instr_op_value,
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
OP_SW = instr_op_value("SW")
OP_LW = instr_op_value("LW")
OP_FMADD_D = instr_op_value("FMADD_D")


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


def read_cdb_lanes(dut: Any) -> list[CdbBroadcast]:
    """Sample both combinational wrapper CDB lanes."""
    return [
        unpack_cdb_broadcast(int(dut.o_cdb.value)),
        unpack_cdb_broadcast(int(dut.o_cdb_2.value)),
    ]


def read_sq_local_cdb(dut: Any, lane: int) -> tuple[bool, int, int]:
    """Decode one SQ-only registered CDB copy as (valid, tag, XLEN value)."""
    signal = dut.sq_cdb_bus_q if lane == 0 else dut.sq_cdb_bus_2_q
    raw = int(signal.value)
    value = raw & MASK_XLEN
    tag = (raw >> XLEN) & 0x1F
    valid = bool((raw >> (XLEN + 5)) & 1)
    return valid, tag, value


def read_sq_early_addr_update(dut: Any) -> tuple[bool, int, int, bool]:
    """Decode the slot-1 early SQ update as (valid, tag, address, is_mmio)."""
    raw = int(dut.sq_early_addr_update.value)
    is_mmio = bool(raw & 1)
    address = (raw >> 1) & MASK_XLEN
    tag = (raw >> (XLEN + 1)) & 0x1F
    valid = bool((raw >> (XLEN + 6)) & 1)
    return valid, tag, address, is_mmio


def assert_cdb_packet(
    cdb: CdbBroadcast,
    *,
    fu_type: int,
    tag: int,
    value: int,
    exception: bool = False,
    exc_cause: int = 0,
    fp_flags: int = 0,
) -> None:
    """Check every field of one valid CDB packet."""
    assert cdb.valid
    assert cdb.fu_type == fu_type
    assert cdb.tag == tag
    assert cdb.value == value
    assert cdb.exception == exception
    assert cdb.exc_cause == exc_cause
    assert cdb.fp_flags == fp_flags


async def dispatch_two_ready_adds(
    dut_if: TomasuloInterface,
    *,
    pc_base: int,
    operands: tuple[tuple[int, int], tuple[int, int]],
) -> dict[int, int]:
    """Allocate and split-dispatch two ready ADDs, returning tag-to-sum."""
    tags = [
        await dut_if.dispatch(AllocationRequest(pc=pc_base)),
        await dut_if.dispatch(AllocationRequest(pc=pc_base + 4)),
    ]
    expected = {
        tag: (src1 + src2) & MASK_XLEN
        for tag, (src1, src2) in zip(tags, operands, strict=True)
    }

    for lane, (tag, (src1, src2)) in enumerate(zip(tags, operands, strict=True)):
        drive = (
            dut_if.drive_split_rs_dispatch
            if lane == 0
            else dut_if.drive_split_rs_dispatch_2
        )
        drive(
            RS_INT,
            rob_tag=tag,
            op=0,  # ADD is the first instr_op_e member.
            src1_ready=True,
            src1_value=src1,
            src2_ready=True,
            src2_value=src2,
            src3_ready=True,
        )

    dut_if.set_fu_ready(RS_INT, True)
    await step_and_clear_dispatch(dut_if)
    return expected


async def wait_for_alu2_cdb(
    dut_if: TomasuloInterface, max_cycles: int = 8
) -> tuple[int, CdbBroadcast]:
    """Wait for a real ALU2 packet on either CDB lane."""
    for _ in range(max_cycles):
        await Timer(1, unit="ps")
        for lane, cdb in enumerate(read_cdb_lanes(dut_if.dut)):
            if cdb.valid and cdb.fu_type == FU_ALU2:
                return lane, cdb
        await dut_if.step()
    raise TimeoutError("ALU2 result did not reach either CDB lane")


@cocotb.test()
async def test_lq_partial_flush_timing_companion_is_full_flush_dominated(
    dut: Any,
) -> None:
    """The LQ's early-recovery cofactor may differ only under full flush."""
    cocotb.log.info("=== Test: LQ Partial-Flush Timing Companion ===")
    dut_if = await setup_test(dut)

    async def park_load(tag: int) -> None:
        dut_if.drive_split_rs_dispatch(
            RS_MEM,
            rob_tag=tag,
            op=OP_LW,
            src1_ready=False,
            src1_tag=31,
            src2_ready=True,
            src3_ready=True,
            imm=0,
            use_imm=True,
        )
        await step_and_clear_dispatch(dut_if)
        assert dut_if.lq_count == 1

    await park_load(3)
    dut_if.drive_flush_en(flush_tag=3)
    await Timer(1, unit="ns")
    assert dut.speculative_flush_en.value
    assert dut.lq_partial_flush_en.value
    assert not dut.speculative_flush_all.value

    # Commit-time recovery promotes the flush to the LQ's full-flush class.
    # The canonical partial term is masked, while the timing companion may
    # remain high because the full-reset input makes any payload difference
    # architecturally unobservable.
    dut.i_flush_after_head_commit.value = 1
    await Timer(1, unit="ns")
    assert dut.speculative_flush_all.value
    assert not dut.speculative_flush_en.value
    assert dut.lq_partial_flush_en.value

    await dut_if.step()
    dut.i_flush_after_head_commit.value = 0
    dut_if.clear_flush_en()
    assert dut_if.lq_count == 0
    assert not dut.o_lq_mem_read_en.value
    assert not any(cdb.valid for cdb in read_cdb_lanes(dut))

    # An architectural full flush does not mask the canonical partial term,
    # so both partial inputs remain equal while full-flush priority clears the
    # parked entry.
    await park_load(4)
    dut_if.drive_flush_en(flush_tag=4)
    dut_if.drive_flush_all()
    await Timer(1, unit="ns")
    assert dut.speculative_flush_all.value
    assert dut.speculative_flush_en.value
    assert dut.lq_partial_flush_en.value

    await dut_if.step()
    dut_if.clear_flush_all()
    dut_if.clear_flush_en()
    assert dut_if.lq_count == 0
    assert not dut.o_lq_mem_read_en.value
    assert not any(cdb.valid for cdb in read_cdb_lanes(dut))
    cocotb.log.info("=== Test Passed ===")


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
async def test_split_rs_int_depth8_accepts_pair_at_count6(dut: Any) -> None:
    """A split INT pair occupies and issues from depth-8 entries 6 and 7."""
    cocotb.log.info("=== Test: Split INT_RS Depth-8 Pair Boundary ===")
    dut_if = await setup_test(dut)

    # Park six unready entries so the boundary pair must allocate the two
    # highest logical entries.  Keep their wait tag distinct from the pair's
    # result tags so issuing the pair cannot wake any filler.
    for entry in range(6):
        dut_if.drive_split_rs_dispatch(
            RS_INT,
            rob_tag=entry,
            op=0,
            src1_ready=False,
            src1_tag=0x1F,
            src2_ready=True,
            src2_value=0x4000 + entry,
            src3_ready=True,
        )
        await step_and_clear_dispatch(dut_if)

    assert_rs_counts(dut_if, {RS_INT: 6})
    assert not dut_if.rs_full_for(RS_INT), "INT_RS must not be full at count 6"
    assert not bool(
        dut.o_int_rs_full_for_2.value
    ), "INT_RS must admit a two-slot bundle at count 6"

    boundary_payloads = (
        {
            "rob_tag": 6,
            "op": 0,
            "src1_ready": True,
            "src1_value": 0x1020_3040,
            "src2_ready": True,
            "src2_value": 0x0102_0304,
            "src3_ready": True,
        },
        {
            "rob_tag": 7,
            "op": 0,
            "src1_ready": True,
            "src1_value": 0x5060_7080,
            "src2_ready": True,
            "src2_value": 0x0506_0708,
            "src3_ready": True,
        },
    )
    dut_if.drive_split_rs_dispatch(RS_INT, **boundary_payloads[0])
    dut_if.drive_split_rs_dispatch_2(RS_INT, **boundary_payloads[1])
    await step_and_clear_dispatch(dut_if)

    assert_rs_counts(dut_if, {RS_INT: 8})
    assert dut_if.rs_full_for(RS_INT), "INT_RS must be full at count 8"
    assert bool(
        dut.o_int_rs_full_for_2.value
    ), "A full INT_RS must also assert full_for_2"

    # With both ALU pipes held, neither high-index payload may disappear.
    await dut_if.step()
    assert_rs_counts(dut_if, {RS_INT: 8})
    assert dut_if.rs_full_for(RS_INT)

    # Release both pipes.  Port 0 must expose entry 6 with its exact payload;
    # the two ALU CDB packets then prove that both entries retained distinct
    # tags and operands through the production depth-8 selector/RAM topology.
    dut_if.set_fu_ready(RS_INT, True)
    await dut_if.step()
    issue = dut_if.read_rs_issue_for(RS_INT)
    assert issue["valid"], "Boundary pair did not issue after releasing INT ALUs"
    assert issue["rob_tag"] == boundary_payloads[0]["rob_tag"]
    assert issue["op"] == boundary_payloads[0]["op"]
    assert issue["src1_value"] == boundary_payloads[0]["src1_value"]
    assert issue["src2_value"] == boundary_payloads[0]["src2_value"]
    assert_rs_counts(dut_if, {RS_INT: 6})
    assert not dut_if.rs_full_for(RS_INT)
    assert not bool(dut.o_int_rs_full_for_2.value)

    lane, lane1 = await wait_for_alu2_cdb(dut_if)
    assert lane == 1, "Simultaneous ALU result must outrank ALU2"
    lane0 = read_cdb_lanes(dut)[0]
    assert_cdb_packet(
        lane0,
        fu_type=FU_ALU,
        tag=boundary_payloads[0]["rob_tag"],
        value=(boundary_payloads[0]["src1_value"] + boundary_payloads[0]["src2_value"])
        & MASK_XLEN,
    )
    assert_cdb_packet(
        lane1,
        fu_type=FU_ALU2,
        tag=boundary_payloads[1]["rob_tag"],
        value=(boundary_payloads[1]["src1_value"] + boundary_payloads[1]["src2_value"])
        & MASK_XLEN,
    )

    # Count 7 is a separate status contract: one free slot remains, but a
    # two-slot bundle cannot fit.
    await dut_if.step()
    dut_if.set_fu_ready(RS_INT, False)
    dut_if.drive_split_rs_dispatch(
        RS_INT,
        rob_tag=8,
        op=0,
        src1_ready=False,
        src1_tag=0x1F,
        src2_ready=True,
        src3_ready=True,
    )
    await step_and_clear_dispatch(dut_if)
    assert_rs_counts(dut_if, {RS_INT: 7})
    assert not dut_if.rs_full_for(RS_INT), "Count 7 must leave one INT_RS slot"
    assert bool(
        dut.o_int_rs_full_for_2.value
    ), "Count 7 must advertise that a two-slot INT bundle cannot fit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_split_int_primary_capture_uses_both_issue_cdb_anchors(
    dut: Any,
) -> None:
    """Port 0 captures exact lane-0/src1 and lane-1/src2 live CDB values."""
    cocotb.log.info("=== Test: Split INT Primary Capture CDB Anchors ===")
    dut_if = await setup_test(dut)

    for target_lane in range(2):
        if target_lane:
            await dut_if.reset_dut()

        dut_if.set_commit_hold(True)
        blocker_tag = await dut_if.dispatch(AllocationRequest(pc=0x6500))
        producer_tag = await dut_if.dispatch(AllocationRequest(pc=0x6504))
        consumer_tag = await dut_if.dispatch(AllocationRequest(pc=0x6508))

        wake_value = 0x89AB_CDEF_1020_3040 & MASK_XLEN
        resident_value = (0x7654_3210_0102_0304) & MASK_XLEN
        expected_src1 = wake_value if target_lane == 0 else resident_value
        expected_src2 = resident_value if target_lane == 0 else wake_value
        expected_result = (expected_src1 + expected_src2) & MASK_XLEN

        # A sole resident entry is necessarily port 0's winner. Exercise src1
        # from registered lane 0, then src2 from registered lane 1 after reset.
        dut_if.drive_split_rs_dispatch(
            RS_INT,
            rob_tag=consumer_tag,
            op=0,
            src1_ready=target_lane != 0,
            src1_tag=producer_tag,
            src1_value=resident_value,
            src2_ready=target_lane != 1,
            src2_tag=producer_tag,
            src2_value=resident_value,
            src3_ready=True,
        )
        await step_and_clear_dispatch(dut_if)
        assert dut_if.rs_count_for(RS_INT) == 1

        dut_if.set_fu_ready(RS_INT, True)
        dut_if.drive_fu_complete(FU_FP_ADD, tag=producer_tag, value=wake_value)
        if target_lane == 1:
            # MUL outranks FP_ADD, so the matching producer is exclusively on
            # lane 1 while an unrelated packet occupies lane 0.
            dut_if.drive_fu_complete(FU_MUL, tag=blocker_tag, value=0xB10C_0001)
        await Timer(1, unit="ps")
        lanes = read_cdb_lanes(dut)
        assert_cdb_packet(
            lanes[target_lane],
            fu_type=FU_FP_ADD,
            tag=producer_tag,
            value=wake_value,
        )

        # Register the ordinary INT-local CDB packet and the issue-only anchor
        # on the same edge. The entry is now combinationally ready, but port 0
        # has not yet captured it into stage2.
        await dut_if.step()
        dut_if.clear_fu_complete(FU_FP_ADD)
        if target_lane == 1:
            dut_if.clear_fu_complete(FU_MUL)
        assert bool(
            dut.int_rs_issue_cdb_valid.value
            if target_lane == 0
            else dut.int_rs_issue_cdb_2_valid.value
        )
        assert (
            int(
                dut.int_rs_issue_cdb_tag.value
                if target_lane == 0
                else dut.int_rs_issue_cdb_2_tag.value
            )
            == producer_tag
        )
        assert not dut_if.read_rs_issue_for(RS_INT)["valid"]

        # The next edge performs the same-cycle bypass capture. Port 0 must
        # expose the exact canonical lane value and its ADD result immediately.
        await dut_if.step()
        issue = dut_if.read_rs_issue_for(RS_INT)
        assert issue["valid"] and issue["rob_tag"] == consumer_tag
        assert issue["src1_value"] == expected_src1
        assert issue["src2_value"] == expected_src2
        await Timer(1, unit="ps")
        assert_cdb_packet(
            read_cdb_lanes(dut)[0],
            fu_type=FU_ALU,
            tag=consumer_tag,
            value=expected_result,
        )

        # Backpressure after capture must hold the effective operands in the
        # existing stage2 bank; releasing the ALU reproduces the same packet.
        dut_if.set_fu_ready(RS_INT, False)
        await dut_if.step()
        assert not dut_if.read_rs_issue_for(RS_INT)["valid"]
        dut_if.set_fu_ready(RS_INT, True)
        await Timer(1, unit="ps")
        held_issue = dut_if.read_rs_issue_for(RS_INT)
        assert held_issue["valid"] and held_issue["rob_tag"] == consumer_tag
        assert held_issue["src1_value"] == expected_src1
        assert held_issue["src2_value"] == expected_src2
        assert_cdb_packet(
            read_cdb_lanes(dut)[0],
            fu_type=FU_ALU,
            tag=consumer_tag,
            value=expected_result,
        )

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
async def test_split_sq_local_cdb_lanes_preserve_repair_timing(dut: Any) -> None:
    """Each registered SQ CDB lane repairs an unready store on the legacy edges."""
    cocotb.log.info("=== Test: Split SQ-Local CDB Lane Repair Timing ===")
    dut_if = await setup_test(dut)

    for target_lane in range(2):
        if target_lane:
            await dut_if.reset_dut()

        dut_if.set_commit_hold(True)
        blocker_tag = await dut_if.dispatch(AllocationRequest(pc=0x6800))
        producer_tag = await dut_if.dispatch(AllocationRequest(pc=0x6804))
        store_tag = await dut_if.dispatch(
            AllocationRequest(pc=0x6808, is_store=True, dest_valid=False)
        )

        low_base = 0x1000 + target_lane * 0x1000
        base_value = (0x1234_5678 << 32) | low_base
        immediate = 0x34 + target_lane * 0x10
        store_data = 0xCAFE_1000 + target_lane
        # Phase 3 M2: the early store-address adders carry the full width.
        # The producer-side canonical_paddr masking was retired; out-of-map
        # addresses fault instead of aliasing.
        expected_addr = (base_value + immediate) & MASK_XLEN

        # Production split dispatch allocates both MEM_RS and SQ, but an
        # unready base leaves the SQ address empty while the persistent repair
        # candidate waits for producer_tag.
        dut_if.drive_split_rs_dispatch(
            RS_MEM,
            rob_tag=store_tag,
            op=OP_SW,
            src1_ready=False,
            src1_tag=producer_tag,
            src2_ready=True,
            src2_value=store_data,
            src3_ready=True,
            imm=immediate,
            use_imm=True,
            mem_size=2,
            mem_signed=False,
        )
        await step_and_clear_dispatch(dut_if)
        assert dut_if.rs_count_for(RS_MEM) == 1
        assert int(dut.u_sq.sq_valid.value) & 1, "store must occupy SQ slot 0"
        assert not (int(dut.u_sq.sq_addr_valid.value) & 1)
        assert not dut_if.read_rs_issue_for(RS_MEM)["valid"]

        dut_if.set_fu_ready(RS_MEM, True)
        dut_if.drive_fu_complete(FU_FP_ADD, tag=producer_tag, value=base_value)
        if target_lane == 1:
            # MUL outranks FP_ADD, placing the producer exclusively on lane 1.
            dut_if.drive_fu_complete(FU_MUL, tag=blocker_tag, value=0xB10C_0001)
        await Timer(1, unit="ps")

        lanes = read_cdb_lanes(dut)
        assert_cdb_packet(
            lanes[target_lane],
            fu_type=FU_FP_ADD,
            tag=producer_tag,
            value=base_value,
        )
        if target_lane == 0:
            assert not lanes[1].valid
        else:
            assert_cdb_packet(
                lanes[0],
                fu_type=FU_MUL,
                tag=blocker_tag,
                value=0xB10C_0001,
            )
        assert not read_sq_local_cdb(dut, target_lane)[0]
        assert not read_sq_early_addr_update(dut)[0]
        assert not dut_if.read_rs_issue_for(RS_MEM)["valid"]

        # First edge: the selected combinational lane enters its SQ-local and
        # generic CDB registers.  The early update must appear immediately,
        # while both the SQ state write and MEM_RS stage-2 issue remain pending.
        await dut_if.step()
        dut_if.clear_fu_complete(FU_FP_ADD)
        if target_lane == 1:
            dut_if.clear_fu_complete(FU_MUL)

        assert read_sq_local_cdb(dut, target_lane) == (
            True,
            producer_tag,
            base_value & MASK_XLEN,
        )
        assert read_sq_early_addr_update(dut) == (
            True,
            store_tag,
            expected_addr,
            False,
        )
        assert not (int(dut.u_sq.sq_addr_valid.value) & 1)
        assert not dut_if.read_rs_issue_for(RS_MEM)["valid"]

        # Second edge: SQ consumes that early update and MEM_RS exposes the
        # store from stage 2 with the same repaired base.  An extra register in
        # either SQ-local copy would move sq_addr_valid to a later edge.
        await dut_if.step()
        assert not read_sq_early_addr_update(dut)[0]
        assert int(dut.u_sq.sq_addr_valid.value) & 1
        issue = dut_if.read_rs_issue_for(RS_MEM)
        assert issue["valid"] and issue["rob_tag"] == store_tag
        assert issue["src1_value"] == base_value
        assert issue["src2_value"] == store_data
        assert issue["imm"] == immediate
        assert issue["mem_needs_sq"]
        assert dut_if.rs_count_for(RS_MEM) == 0

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


@cocotb.test()
async def test_split_fmul_pending_done_repair_uses_three_channels(dut: Any) -> None:
    """Production split routing stores three FMUL repair responses before RS entry."""
    cocotb.log.info("=== Test: Split FMUL Three-Source Pending Repair ===")
    dut_if = await setup_test(dut)
    dut_if.set_commit_hold(True)

    producer_values = (
        0x3FF0_0000_0000_0000,
        0x4000_0000_0000_0000,
        0x4008_0000_0000_0000,
    )
    producer_tags = (
        await dut_if.dispatch(
            AllocationRequest(pc=0x7020, dest_rf=1, dest_reg=3, dest_valid=True)
        ),
        await dut_if.dispatch(
            AllocationRequest(pc=0x7024, dest_rf=1, dest_reg=4, dest_valid=True)
        ),
        await dut_if.dispatch(
            AllocationRequest(pc=0x7028, dest_rf=1, dest_reg=5, dest_valid=True)
        ),
    )
    for tag, value in zip(producer_tags, producer_values, strict=True):
        dut_if.drive_cdb_write(CDBWrite(tag=tag, value=value))
        await dut_if.step()
        dut_if.clear_cdb_write()
        dut_if.set_read_tag(tag)
        for _ in range(6):
            await Timer(1, unit="ps")
            if dut_if.read_entry_done():
                break
            await dut_if.step()
        assert dut_if.read_entry_done()
        assert dut_if.read_entry_value() == value

    consumer_tag = await dut_if.dispatch(
        AllocationRequest(pc=0x702C, dest_rf=1, dest_reg=6, dest_valid=True)
    )
    dut_if.drive_split_rs_dispatch(
        RS_FMUL,
        rob_tag=consumer_tag,
        op=OP_FMADD_D,
        src1_ready=False,
        src1_tag=producer_tags[0],
        src2_ready=False,
        src2_tag=producer_tags[1],
        src3_ready=False,
        src3_tag=producer_tags[2],
    )
    dut_if.set_fu_ready(RS_FMUL, True)
    await step_and_clear_dispatch(dut_if)
    assert int(dut.fmul_pending_repair_capture_q.value)

    for channel, tag in enumerate(producer_tags, start=1):
        dut_if.drive_dispatch_bypass(channel, tag)
    await Timer(1, unit="ps")
    assert int(dut.fmul_repair_window_block.value)
    assert not int(dut.fmul_dispatch_dequeue.value)
    await dut_if.step()
    dut_if.clear_dispatch_bypasses()

    await Timer(1, unit="ps")
    assert int(dut.fmul_dispatch_dequeue.value)
    await dut_if.step()

    issue = None
    for _ in range(5):
        await Timer(1, unit="ps")
        candidate = dut_if.read_rs_issue_for(RS_FMUL)
        if candidate["valid"]:
            issue = candidate
            break
        await dut_if.step()
    assert issue is not None, "Split-routed FMUL packet never issued"
    assert issue["rob_tag"] == consumer_tag
    assert issue["src1_value"] == producer_values[0]
    assert issue["src2_value"] == producer_values[1]
    assert issue["src3_value"] == producer_values[2]

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_alu_effective_packet_uses_idle_injection(dut: Any) -> None:
    """An idle ALU adapter exposes the complete slot-0 injection packet."""
    cocotb.log.info("=== Test: ALU Effective Packet Injection Source ===")
    dut_if = await setup_test(dut)

    tag = await dut_if.dispatch(AllocationRequest(pc=0x70F0))
    value = 0xA15C_A11E_CAFE_BEEF
    dut_if.drive_fu_complete(
        FU_ALU,
        tag=tag,
        value=value,
        exception=True,
        exc_cause=0x11,
        fp_flags=0x14,
    )
    await Timer(1, unit="ps")

    lane0, lane1 = read_cdb_lanes(dut)
    assert_cdb_packet(
        lane0,
        fu_type=FU_ALU,
        tag=tag,
        value=value,
        exception=True,
        exc_cause=0x11,
        fp_flags=0x14,
    )
    assert not lane1.valid
    assert int(dut.o_cdb_grant.value) == 1 << FU_ALU

    dut_if.clear_fu_complete(FU_ALU)
    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_alu2_effective_packet_uses_idle_injection(dut: Any) -> None:
    """An idle ALU2 adapter exposes the complete slot-7 injection packet."""
    cocotb.log.info("=== Test: ALU2 Effective Packet Injection Source ===")
    dut_if = await setup_test(dut)

    tag = await dut_if.dispatch(AllocationRequest(pc=0x7100))
    value = 0xD15C_A11E_CAFE_BEEF
    dut_if.drive_fu_complete(
        FU_ALU2,
        tag=tag,
        value=value,
        exception=True,
        exc_cause=0x12,
        fp_flags=0x15,
    )
    await Timer(1, unit="ps")

    lane0, lane1 = read_cdb_lanes(dut)
    assert_cdb_packet(
        lane0,
        fu_type=FU_ALU2,
        tag=tag,
        value=value,
        exception=True,
        exc_cause=0x12,
        fp_flags=0x15,
    )
    assert not lane1.valid
    assert int(dut.o_cdb_grant.value) == 1 << FU_ALU2

    dut_if.clear_fu_complete(FU_ALU2)
    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_alu2_effective_packet_uses_live_adapter(dut: Any) -> None:
    """A grantable second ADD reaches CDB directly through the live adapter."""
    cocotb.log.info("=== Test: ALU2 Effective Packet Live Source ===")
    dut_if = await setup_test(dut)
    expected = await dispatch_two_ready_adds(
        dut_if,
        pc_base=0x7200,
        operands=(
            (0x0000_0001_1020_3040, 0x0000_0002_0102_0304),
            (0x0000_0003_5060_7080, 0x0000_0004_0506_0708),
        ),
    )

    lane, cdb = await wait_for_alu2_cdb(dut_if)
    assert lane == 1, "ALU outranks a simultaneous ALU2 result"
    lane0 = read_cdb_lanes(dut)[0]
    assert {lane0.tag, cdb.tag} == set(expected)
    assert_cdb_packet(
        lane0,
        fu_type=FU_ALU,
        tag=lane0.tag,
        value=expected[lane0.tag],
    )
    assert_cdb_packet(
        cdb,
        fu_type=FU_ALU2,
        tag=cdb.tag,
        value=expected[cdb.tag],
    )
    assert int(dut.o_cdb_grant.value) & (1 << FU_ALU)
    assert int(dut.o_cdb_grant.value) & (1 << FU_ALU2)

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_alu2_effective_packet_held_adapter_beats_injection(dut: Any) -> None:
    """A contended ALU2 result is held and wins over divergent slot-7 input."""
    cocotb.log.info("=== Test: ALU2 Effective Packet Held Source ===")
    dut_if = await setup_test(dut)

    # Park an incomplete entry at the ROB head so repeated blocker packets
    # cannot commit and turn into free-tag noise during the contention window.
    await dut_if.dispatch(AllocationRequest(pc=0x7300))
    mul_tag = await dut_if.dispatch(AllocationRequest(pc=0x7304))
    mem_tag = await dut_if.dispatch(AllocationRequest(pc=0x7308))
    dut_if.drive_fu_complete(FU_MUL, tag=mul_tag, value=0x1111)
    dut_if.drive_fu_complete(FU_MEM, tag=mem_tag, value=0x2222)

    expected = await dispatch_two_ready_adds(
        dut_if,
        pc_base=0x7310,
        operands=(
            (0x0000_1111_1111_2222, 0x0000_2222_0101_0202),
            (0x0000_3333_3333_4444, 0x0000_4444_0303_0404),
        ),
    )

    # MUL and MEM own both lanes. Wait until both INT entries have left the RS;
    # their ungranted ALU/ALU2 completions are then resident in the adapters.
    for _ in range(8):
        await Timer(1, unit="ps")
        assert all(cdb.fu_type != FU_ALU2 for cdb in read_cdb_lanes(dut))
        if dut_if.rs_count_for(RS_INT) == 0:
            break
        await dut_if.step()
    else:
        raise TimeoutError("dual ADDs did not leave INT_RS under CDB contention")

    assert not (int(dut.o_cdb_grant.value) & (1 << FU_ALU2))
    await dut_if.step()

    # Make every injection field disagree with a normal ADD result. The
    # adapter-held packet must remain the effective slot-7 request.
    injected_value = 0xFEED_FACE_DEAD_BEEF
    dut_if.drive_fu_complete(
        FU_ALU2,
        tag=0x1F,
        value=injected_value,
        exception=True,
        exc_cause=0x1B,
        fp_flags=0x1D,
    )
    dut_if.clear_fu_complete(FU_MUL)
    dut_if.clear_fu_complete(FU_MEM)
    await Timer(1, unit="ps")

    lane, cdb = await wait_for_alu2_cdb(dut_if, max_cycles=1)
    assert lane == 1, "held ALU outranks held ALU2"
    lane0 = read_cdb_lanes(dut)[0]
    assert {lane0.tag, cdb.tag} == set(expected)
    assert_cdb_packet(
        lane0,
        fu_type=FU_ALU,
        tag=lane0.tag,
        value=expected[lane0.tag],
    )
    assert cdb.tag != 0x1F
    assert cdb.value != injected_value
    assert_cdb_packet(
        cdb,
        fu_type=FU_ALU2,
        tag=cdb.tag,
        value=expected[cdb.tag],
    )
    assert int(dut.o_cdb_grant.value) & (1 << FU_ALU2)

    dut_if.clear_fu_complete(FU_ALU2)
    cocotb.log.info("=== Test Passed ===")

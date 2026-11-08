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

"""Tomasulo wrapper tests with SPLIT_RS_DISPATCH=1, as used by cpu_ooo."""

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
    BranchUpdate,
    CDBWrite,
)
from .tomasulo_interface import (
    RS_FP,
    RS_INT,
    RS_MEM,
    RS_MUL,
    TomasuloInterface,
    instr_op_value,
)

ALL_RS_TYPES = [RS_INT, RS_MUL, RS_MEM, RS_FP]
RS_NAMES = {
    RS_INT: "INT_RS",
    RS_MUL: "MUL_RS",
    RS_MEM: "MEM_RS",
    RS_FP: "FP_RS",
}
OP_SW = instr_op_value("SW")
OP_LW = instr_op_value("LW")
OP_FMADD_D = instr_op_value("FMADD_D")
OP_JALR = instr_op_value("JALR")


async def setup_test(dut: Any) -> TomasuloInterface:
    """Initialize clock, wrapper interface, and reset DUT."""
    clock = Clock(dut.i_clk, 10, unit="ns")
    clock.start()
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
        assert actual == expected, (
            f"{RS_NAMES[rs_type]} count mismatch: got {actual}, expected {expected}"
        )


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


@cocotb.test()
async def test_mem_rs_capacity_and_flush_reuse(dut: Any) -> None:
    """Eight memory entries expose both capacity limits and survive flush reuse."""
    dut_if = await setup_test(dut)

    async def enqueue(*tags: int) -> None:
        for tag in tags:
            allocated = await dut_if.dispatch(
                AllocationRequest(
                    pc=0x1000 + 4 * tag,
                    rs_type=RS_MEM,
                    is_store=tag % 2 != 0,
                )
            )
            assert allocated == tag
        for lane, tag in enumerate(tags):
            drive = (
                dut_if.drive_split_rs_dispatch
                if lane == 0
                else dut_if.drive_split_rs_dispatch_2
            )
            drive(
                RS_MEM,
                rob_tag=tag,
                op=OP_LW if tag % 2 == 0 else OP_SW,
                src1_ready=False,
                src1_tag=30,
                src2_ready=False,
                src2_tag=31,
                src3_ready=True,
            )
        await step_and_clear_dispatch(dut_if)

    async def check_capacity(count: int) -> None:
        await Timer(1, unit="ps")
        assert_rs_counts(dut_if, {RS_MEM: count})
        assert dut_if.rob_count == count
        assert dut_if.rs_full_for(RS_MEM) == (count == 8)
        assert bool(dut.o_mem_rs_full_for_2.value) == (count >= 7)
        assert not dut_if.rs_issue_valid_for(RS_MEM)

    for first in (0, 2, 4):
        await enqueue(first, first + 1)
        await check_capacity(first + 2)
    await enqueue(6)
    await check_capacity(7)
    await enqueue(7)
    await check_capacity(8)

    dut_if.drive_flush_en(3)
    await dut_if.step()
    dut_if.clear_flush_en()
    await check_capacity(4)
    await dut_if.step()  # The SQ repairs its tail before allocation resumes.
    await enqueue(4, 5)
    await check_capacity(6)
    await enqueue(6, 7)
    await check_capacity(8)

    dut_if.drive_flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()
    await check_capacity(0)
    await dut_if.step()
    await enqueue(0, 1)
    await check_capacity(2)


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
    """The LQ's partial-flush input may differ from speculative_flush_en only under full flush."""
    cocotb.log.info("=== Test: LQ Partial-Flush Input Under Full Flush ===")
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

    # Commit-time recovery fully flushes the LQ. lq_partial_flush_en may
    # remain high while speculative_flush_en is masked; full flush wins.
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

    # An i_flush_all full flush does not mask speculative_flush_en, so both
    # partial terms stay equal while the full flush clears the parked entry.
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
@cocotb.parametrize(filler_count=[6, 14])
async def test_split_rs_int_pair_at_issue_window_and_capacity(
    dut: Any, filler_count: int
) -> None:
    """Pairs retain exact payloads inside the issue window and at full capacity."""
    dut_if = await setup_test(dut)
    depth = 16
    in_second_issue_window = filler_count == 6

    # Park unready entries below the boundary pair. Their wait tag must stay
    # distinct from both result tags, so neither completed ADD wakes a filler.
    for entry in range(filler_count):
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

    assert_rs_counts(dut_if, {RS_INT: filler_count})
    assert not dut_if.rs_full_for(RS_INT)
    assert not bool(dut.o_int_rs_full_for_2.value)
    operands = ((0x1020_3040, 0x0102_0304), (0x5060_7080, 0x0506_0708))
    expected = {}
    for slot, (src1, src2) in enumerate(operands):
        tag = filler_count + slot
        expected[tag] = (
            FU_ALU2 if slot == 1 and in_second_issue_window else FU_ALU,
            (src1 + src2) & MASK_XLEN,
        )
        drive = (
            dut_if.drive_split_rs_dispatch
            if slot == 0
            else dut_if.drive_split_rs_dispatch_2
        )
        drive(
            RS_INT,
            rob_tag=tag,
            op=0,
            src1_ready=True,
            src1_value=src1,
            src2_ready=True,
            src2_value=src2,
            src3_ready=True,
        )
    await step_and_clear_dispatch(dut_if)

    count = filler_count + 2
    assert_rs_counts(dut_if, {RS_INT: count})
    assert dut_if.rs_full_for(RS_INT) == (count == depth)
    assert bool(dut.o_int_rs_full_for_2.value) == (count >= depth - 1)
    await dut_if.step()
    assert_rs_counts(dut_if, {RS_INT: count})

    # Entries 6 and 7 may issue together. Entries 14 and 15 are outside
    # ISSUE2_WINDOW and must use port 0 on successive cycles.
    dut_if.set_fu_ready(RS_INT, True)
    await dut_if.step()
    issue = dut_if.read_rs_issue_for(RS_INT)
    assert issue["valid"]
    assert issue["rob_tag"] == filler_count
    assert issue["src1_value"] == operands[0][0]
    assert issue["src2_value"] == operands[0][1]
    issue_2 = dut_if.read_int_rs_issue_2()
    assert bool(issue_2["valid"]) == in_second_issue_window
    if in_second_issue_window:
        assert issue_2["rob_tag"] == filler_count + 1
    assert_rs_counts(dut_if, {RS_INT: filler_count + int(not in_second_issue_window)})

    seen = set()
    for _ in range(10):
        for packet in read_cdb_lanes(dut):
            if not packet.valid:
                continue
            assert packet.tag in expected
            assert packet.tag not in seen, "Boundary ADD completed more than once"
            fu_type, value = expected[packet.tag]
            assert_cdb_packet(packet, fu_type=fu_type, tag=packet.tag, value=value)
            seen.add(packet.tag)
        if len(seen) == 2:
            break
        await dut_if.step()
    assert seen == set(expected), "Both boundary ADDs must complete"
    assert_rs_counts(dut_if, {RS_INT: filler_count})

    # Refill one slot with an unready instruction. Only count 15 must reject
    # another pair while continuing to admit a single instruction.
    await dut_if.step()
    dut_if.set_fu_ready(RS_INT, False)
    dut_if.drive_split_rs_dispatch(
        RS_INT,
        rob_tag=filler_count + 2,
        op=0,
        src1_ready=False,
        src1_tag=0x1F,
        src2_ready=True,
        src3_ready=True,
    )
    await step_and_clear_dispatch(dut_if)
    assert_rs_counts(dut_if, {RS_INT: filler_count + 1})
    assert not dut_if.rs_full_for(RS_INT)
    assert bool(dut.o_int_rs_full_for_2.value) == (filler_count + 1 == depth - 1)


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

        # Both INT CDB copies register together. The entry is ready, but
        # port 0 captures it into stage2 only on the next edge.
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
        # present the lane's exact value and its ADD result immediately.
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
    """With SPLIT_RS_DISPATCH=1 the wrapper ignores the single-slot i_rs_dispatch bus."""
    cocotb.log.info("=== Test: Split RS Ignores Single-Slot Bus ===")
    dut_if = await setup_test(dut)

    dut_if.drive_rs_dispatch(RS_INT, **ready_payload(5))
    dut_if.drive_split_rs_dispatch(RS_MEM, **ready_payload(6))
    await step_and_clear_dispatch(dut_if)

    assert_rs_counts(dut_if, {RS_MEM: 1})

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_split_sq_local_cdb_lanes_preserve_repair_timing(dut: Any) -> None:
    """Each SQ-local CDB lane repairs an unready store on the expected edge."""
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
        # The early store-address adders keep the full XLEN width: the
        # address is not masked, and an out-of-map address faults.
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

        # First edge: both CDB copies register and the early update appears.
        # The SQ write and MEM_RS stage2 capture wait for the next edge.
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

        # Second edge: SQ consumes the update; MEM_RS stage2 presents the
        # store with the same repaired base.
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

    for _ in range(6):
        await Timer(1, unit="ps")
        if dut_if.rob_entry_done(producer_tag):
            break
        await dut_if.step()
    assert dut_if.rob_entry_done(producer_tag)
    assert await dut_if.read_rob_entry_value(producer_tag) == producer_value

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
async def test_split_fp_pending_done_repair_uses_three_channels(dut: Any) -> None:
    """Production split routing stores three FMA repair responses before RS entry."""
    cocotb.log.info("=== Test: Split FP Three-Source Pending Repair ===")
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
        for _ in range(6):
            await Timer(1, unit="ps")
            if dut_if.rob_entry_done(tag):
                break
            await dut_if.step()
        assert dut_if.rob_entry_done(tag)
        assert await dut_if.read_rob_entry_value(tag) == value

    consumer_tag = await dut_if.dispatch(
        AllocationRequest(pc=0x702C, dest_rf=1, dest_reg=6, dest_valid=True)
    )
    dut_if.drive_split_rs_dispatch(
        RS_FP,
        rob_tag=consumer_tag,
        op=OP_FMADD_D,
        src1_ready=False,
        src1_tag=producer_tags[0],
        src2_ready=False,
        src2_tag=producer_tags[1],
        src3_ready=False,
        src3_tag=producer_tags[2],
    )
    dut_if.set_fu_ready(RS_FP, True)
    await step_and_clear_dispatch(dut_if)
    assert int(dut.fp_pending_repair_capture_q.value)
    assert int(dut.fp_pending_repair_wait_q.value)

    for channel, tag in enumerate(producer_tags, start=1):
        dut_if.drive_dispatch_bypass(channel, tag)
    await Timer(1, unit="ps")
    assert int(dut.fp_repair_window_block.value)
    assert not int(dut.fp_dispatch_dequeue.value)
    await dut_if.step()
    dut_if.clear_dispatch_bypasses()

    await Timer(1, unit="ps")
    assert not int(dut.fp_pending_repair_wait_q.value)
    assert int(dut.fp_dispatch_dequeue.value)
    await dut_if.step()

    issue = None
    for _ in range(5):
        await Timer(1, unit="ps")
        candidate = dut_if.read_rs_issue_for(RS_FP)
        if candidate["valid"]:
            issue = candidate
            break
        await dut_if.step()
    assert issue is not None, "Split-routed FMA packet never issued"
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

    # MUL and MEM occupy both lanes. Wait until both INT entries have left the RS;
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


def cdb_lane_packets(dut: Any) -> set[tuple[int, int, int]]:
    """Return the valid packets on both combinational CDB lanes as (FU, tag, value)."""
    return {
        (cdb.fu_type, cdb.tag, cdb.value) for cdb in read_cdb_lanes(dut) if cdb.valid
    }


async def run_port0_behind_held_alu_result(
    dut: Any, *, second_is_jalr: bool, second_loses: bool
) -> None:
    """Hold port 0's first result behind MUL and MEM, then present its next op.

    Port 0 issues A and then B on consecutive cycles. A presents while MUL and
    MEM take both lanes, so the ALU adapter holds it. In the next cycle port 0
    presents B through the idle ALU2 adapter, unless B is a JALR, which waits
    for A's grant and then presents through the ALU adapter. With
    second_loses, MUL and MEM also take both lanes from A and B in B's cycle,
    and the ALU2 adapter holds B.
    """
    dut_if = await setup_test(dut)

    # Park an incomplete entry at the ROB head so the blockers cannot retire.
    await dut_if.dispatch(AllocationRequest(pc=0x7300))
    mul_tag = await dut_if.dispatch(AllocationRequest(pc=0x7304))
    mem_tag = await dut_if.dispatch(AllocationRequest(pc=0x7308))
    a_tag = await dut_if.dispatch(AllocationRequest(pc=0x7310))
    b_tag = await dut_if.dispatch(
        AllocationRequest(
            pc=0x7314,
            is_branch=second_is_jalr,
            is_jalr=second_is_jalr,
            predicted_taken=second_is_jalr,
            predicted_target=0x9000 if second_is_jalr else 0,
        )
    )
    a_value = (0x0000_1111_0000_0001 + 0x0000_2222_0000_0002) & MASK_XLEN
    b_link = 0x7318
    b_value = b_link if second_is_jalr else (0x0000_3333_0000_0003 + 0x4) & MASK_XLEN
    dut_if.set_fu_ready(RS_INT, True)

    # A enters INT_RS; port 0 selects it in the next cycle.
    dut_if.drive_split_rs_dispatch(
        RS_INT,
        rob_tag=a_tag,
        op=0,
        src1_ready=True,
        src1_value=0x0000_1111_0000_0001,
        src2_ready=True,
        src2_value=0x0000_2222_0000_0002,
        src3_ready=True,
    )
    await step_and_clear_dispatch(dut_if)

    # B enters INT_RS while port 0 selects A.
    b_payload: dict[str, Any] = {
        "rob_tag": b_tag,
        "src1_ready": True,
        "src2_ready": True,
        "src3_ready": True,
    }
    if second_is_jalr:
        b_payload.update(
            op=OP_JALR,
            src1_value=0x9000,
            imm=b_link,
            predicted_taken=True,
            predicted_target=0x9000,
            predicted_target_ok=True,
            pc=0x7314,
            link_addr=b_link,
        )
    else:
        b_payload.update(op=0, src1_value=0x0000_3333_0000_0003, src2_value=0x4)
    dut_if.drive_split_rs_dispatch(RS_INT, **b_payload)
    await step_and_clear_dispatch(dut_if)

    # A presents on port 0 and loses to MUL and MEM; port 0 selects B.
    dut_if.drive_fu_complete(FU_MUL, tag=mul_tag, value=0x1111)
    dut_if.drive_fu_complete(FU_MEM, tag=mem_tag, value=0x2222)
    await Timer(1, unit="ps")
    issue = dut_if.read_rs_issue()
    assert issue["valid"] and issue["rob_tag"] == a_tag
    assert not (int(dut.o_cdb_grant.value) & (1 << FU_ALU))
    await dut_if.step()
    if not second_loses:
        dut_if.clear_fu_complete(FU_MUL)
        dut_if.clear_fu_complete(FU_MEM)
    await Timer(1, unit="ps")
    assert int(dut.alu_adapter_result_pending.value)

    if second_is_jalr:
        # The JALR stays in stage 2 until the ALU adapter is free.
        assert not int(dut.int_rs_fu_ready.value)
        assert cdb_lane_packets(dut) == {(FU_ALU, a_tag, a_value)}
        await dut_if.step()
        await Timer(1, unit="ps")
        assert cdb_lane_packets(dut) == {(FU_ALU, b_tag, b_value)}
    elif second_loses:
        # B passes through the ALU2 adapter, loses with A, and waits there.
        assert int(dut.int_rs_fu_ready.value)
        assert not (int(dut.o_cdb_grant.value) & ((1 << FU_ALU) | (1 << FU_ALU2)))
        await dut_if.step()
        dut_if.clear_fu_complete(FU_MUL)
        dut_if.clear_fu_complete(FU_MEM)
        await Timer(1, unit="ps")
        assert int(dut.alu2_adapter_result_pending.value)
        assert cdb_lane_packets(dut) == {
            (FU_ALU, a_tag, a_value),
            (FU_ALU2, b_tag, b_value),
        }
    else:
        # B passes through the idle ALU2 adapter while A keeps the ALU slot.
        assert int(dut.int_rs_fu_ready.value)
        assert cdb_lane_packets(dut) == {
            (FU_ALU, a_tag, a_value),
            (FU_ALU2, b_tag, b_value),
        }

    for _ in range(3):
        await dut_if.step()
    assert dut_if.rob_entry_done(a_tag)
    assert dut_if.rob_entry_done(b_tag)
    assert await dut_if.read_rob_entry_value(a_tag) == a_value
    assert await dut_if.read_rob_entry_value(b_tag) == b_value
    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_port0_passes_through_alu2_while_alu_holds(dut: Any) -> None:
    """Port 0's next result uses the idle ALU2 adapter while the ALU adapter holds."""
    await run_port0_behind_held_alu_result(
        dut, second_is_jalr=False, second_loses=False
    )


@cocotb.test()
async def test_port0_pass_through_result_waits_in_alu2(dut: Any) -> None:
    """A passed-through port-0 result that loses waits in the ALU2 adapter."""
    await run_port0_behind_held_alu_result(dut, second_is_jalr=False, second_loses=True)


@cocotb.test()
async def test_port0_jalr_waits_for_held_alu_result(dut: Any) -> None:
    """A JALR in port 0's stage 2 waits for the held ALU result, then uses ALU."""
    await run_port0_behind_held_alu_result(dut, second_is_jalr=True, second_loses=False)


async def check_held_jalr_link(
    dut: Any, contended_cycles: int, *, jalr_at_head_next: bool = False
) -> None:
    """Hold a JALR's link behind MUL and MEM and check the JALR waits for it.

    The branch update marks a JALR done while its link still has to reach the
    CDB. With the ROB full behind the JALR and MUL and MEM taking both lanes,
    the link waits in the ALU adapter. If the JALR retired meanwhile, its tag
    would be reallocated and the late link broadcast would complete the new
    entry: in the drain window after three contended cycles, silently after
    more. With jalr_at_head_next, two-wide commit is enabled and the JALR sits
    at head+1 behind a done entry, at the tag wrap (head 31, JALR 0), so the
    slot-2 gate decides.
    """
    dut_if = await setup_test(dut)
    dut_if.set_fu_ready(RS_INT, False)

    head_entry_tag: int | None = None
    if jalr_at_head_next:
        dut_if.set_widen_commit_ok(True)
        # Retire 31 entries so that the head reaches the last tag.
        for index in range(31):
            tag = await dut_if.dispatch(AllocationRequest(pc=0x6000 + 4 * index))
            dut_if.drive_fu_complete(FU_MUL, tag=tag, value=index)
            await dut_if.step()
            dut_if.clear_fu_complete(FU_MUL)
        for _ in range(4):
            await dut_if.step()
        assert dut_if.rob_empty and dut_if.head_tag == 31
        # A done entry at the head, held by commit hold until the JALR's
        # link is held, so that the JALR is head+1 when both are done.
        dut_if.set_commit_hold(True)
        head_entry_tag = await dut_if.dispatch(AllocationRequest(pc=0x7FFC))
        dut_if.drive_fu_complete(FU_MUL, tag=head_entry_tag, value=0x55)
        await dut_if.step()
        dut_if.clear_fu_complete(FU_MUL)

    jalr_pc = 0x8000
    target = 0x9000
    link = jalr_pc + 4
    jalr_tag = await dut_if.dispatch(
        AllocationRequest(
            pc=jalr_pc,
            is_branch=True,
            is_jalr=True,
            predicted_taken=True,
            predicted_target=target,
            dest_valid=True,
            dest_reg=1,
        )
    )
    dut_if.drive_split_rs_dispatch(
        RS_INT,
        rob_tag=jalr_tag,
        op=OP_JALR,
        src1_ready=True,
        src1_value=target,
        src2_ready=True,
        src3_ready=True,
        imm=link,
        predicted_taken=True,
        predicted_target=target,
        predicted_target_ok=True,
        pc=jalr_pc,
        link_addr=link,
    )
    await step_and_clear_dispatch(dut_if)

    # Fill the ROB behind the JALR with entries that only complete when a
    # test-injected MUL or MEM packet names them.
    younger: list[int] = []
    while not dut_if.rob_full:
        younger.append(
            await dut_if.dispatch(
                AllocationRequest(pc=jalr_pc + 0x100 + 4 * len(younger))
            )
        )
    expected_head = head_entry_tag if head_entry_tag is not None else jalr_tag
    assert dut_if.head_tag == expected_head

    # Port 0 selects the JALR, then presents it.
    dut_if.set_fu_ready(RS_INT, True)
    for _ in range(8):
        await dut_if.step()
        issue = dut_if.read_rs_issue()
        if issue["valid"] and issue["rob_tag"] == jalr_tag:
            break
    else:
        raise TimeoutError("JALR did not reach INT RS port 0")

    # Resolve the JALR as predicted in its presentation cycle, as
    # branch_resolution does, while MUL and MEM take both lanes for several
    # cycles. A new ROB request waits for room the whole time.
    dut_if.drive_branch_update(BranchUpdate(tag=jalr_tag, taken=True, target=target))
    lane_tags = iter(younger)
    reused_tag_cycle: int | None = None
    link_grant_cycle: int | None = None
    jalr_commit_cycle: int | None = None
    held_link_committed = False
    for cycle in range(contended_cycles + 12):
        if cycle < contended_cycles:
            dut_if.drive_fu_complete(FU_MUL, tag=next(lane_tags), value=0x1111)
            dut_if.drive_fu_complete(FU_MEM, tag=next(lane_tags), value=0x2222)
        else:
            dut_if.clear_fu_complete(FU_MUL)
            dut_if.clear_fu_complete(FU_MEM)
        # Dispatch requests allocation only while the ROB reports room.
        rob_has_room = not int(dut.o_rob_full.value)
        if reused_tag_cycle is None and rob_has_room:
            dut_if.drive_alloc_request(AllocationRequest(pc=0xA000))
        else:
            dut_if.clear_alloc_request()
        await Timer(1, unit="ps")
        if cycle == 0:
            assert not (int(dut.o_cdb_grant.value) & (1 << FU_ALU)), (
                "MUL and MEM should take both lanes from the JALR link"
            )
        held = (
            bool(int(dut.alu_adapter_result_pending.value))
            and (
                int(dut.alu_adapter_to_arbiter.value)
                >> (len(dut.alu_adapter_to_arbiter) - 6)
            )
            & 0x1F
            == jalr_tag
        )
        if held and int(dut.o_cdb_grant.value) & (1 << FU_ALU):
            link_grant_cycle = cycle
        for read in (dut_if.read_commit, dut_if.read_commit_2):
            commit = read()
            if commit["valid"] and commit["tag"] == jalr_tag:
                jalr_commit_cycle = cycle
                if held:
                    held_link_committed = True
        if reused_tag_cycle is None and rob_has_room:
            alloc_ready, alloc_tag, _ = dut_if.read_alloc_response()
            if alloc_ready and alloc_tag == jalr_tag:
                reused_tag_cycle = cycle
        await dut_if.step()
        if cycle == 0:
            dut_if.clear_branch_update()
            # Both the head entry and the JALR are done from here on.
            dut_if.set_commit_hold(False)
        dut_if.clear_alloc_request()

    reused_done = reused_tag_cycle is not None and dut_if.rob_entry_done(jalr_tag)
    reused_value = await dut_if.read_rob_entry_value(jalr_tag) if reused_done else None
    cocotb.log.info(
        f"link granted in cycle {link_grant_cycle}; JALR retired in cycle "
        f"{jalr_commit_cycle} (while held: {held_link_committed}); tag {jalr_tag} "
        f"reused in cycle {reused_tag_cycle}; reused entry done: {reused_done}; value: "
        f"{reused_value if reused_value is None else hex(reused_value)} (link {link:#x})"
    )
    assert not held_link_committed, (
        "JALR retired while its link was held in the ALU adapter"
    )
    assert link_grant_cycle is not None, "the held link was never granted"
    assert jalr_commit_cycle is not None, "the JALR never retired"
    assert jalr_commit_cycle > link_grant_cycle
    assert reused_tag_cycle is not None, "the JALR's tag was never reallocated"
    assert not dut_if.rob_entry_done(jalr_tag), (
        "the JALR's late link broadcast completed the entry that reused its tag"
    )
    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_held_jalr_link_six_cycles(dut: Any) -> None:
    """A JALR waits for a link that MUL and MEM hold for six cycles."""
    await check_held_jalr_link(dut, contended_cycles=6)


@cocotb.test()
async def test_held_jalr_link_three_cycles(dut: Any) -> None:
    """A JALR waits for a link that MUL and MEM hold for three cycles."""
    await check_held_jalr_link(dut, contended_cycles=3)


@cocotb.test()
async def test_held_jalr_link_at_head_next(dut: Any) -> None:
    """Two-wide commit does not retire a JALR at head+1 while its link is held."""
    await check_held_jalr_link(dut, contended_cycles=4, jalr_at_head_next=True)

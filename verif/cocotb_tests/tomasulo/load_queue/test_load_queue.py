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

"""Unit tests for the load queue.

Covers allocation on one or both slots, load sizes and sign extension, SQ
disambiguation and forwarding, the L0 cache, MMIO loads and the router's
pending handshake, overlapped cached-tier loads, dword responses, flushes,
LR reservations, AMO ordering, compute, and cancellation, DMA coherence, CDB
back-pressure, and a constrained-random sequence. The dispatch-capacity tests
check that the registered dispatch-full flags may lag a completion or flush
by a cycle but never report room that is not there. "Normal" AMOs (SWAP, ADD,
XOR, AND, OR) spend one cycle in AMO_COMPUTE; MIN and MAX do not.

Expected values follow hw/rtl/README.md, "Data-tier bus contract": memory
responses are aligned 64-bit beats and the LQ extracts by addr[2:0].
drive_mem_response replicates a word across both beat lanes (correct at
either addr[2]) unless dword=True.
"""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer
from config import MASK32, MASK64, MASK_XLEN

from .lq_interface import LQInterface
from .lq_model import (
    LQModel,
    FuComplete,
    SQForwardResult,
    MEM_SIZE_BYTE,
    MEM_SIZE_HALF,
    MEM_SIZE_WORD,
    MEM_SIZE_DOUBLE,
    sign_extend_to_xlen,
)

CLOCK_PERIOD_NS = 10
LQ_DEPTH = 8


def wbeat(word: int) -> int:
    """Replicate a write word across both lanes of the 64-bit beat ({2{word}})."""
    word &= MASK32
    return (word << 32) | word


AMO_RESCUE_THRESHOLD = 16384


async def setup(dut: Any) -> tuple[LQInterface, LQModel]:
    """Start clock, reset DUT, and return interface and model."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut_if = LQInterface(dut)
    model = LQModel()
    await dut_if.reset_dut()
    return dut_if, model


async def alloc_and_addr(
    dut_if: LQInterface,
    model: LQModel,
    rob_tag: int,
    address: int,
    is_fp: bool = False,
    size: int = MEM_SIZE_WORD,
    sign_ext: bool = False,
    is_mmio: bool = False,
) -> None:
    """Allocate an entry, step, then update its address and step."""
    dut_if.drive_alloc(rob_tag, is_fp=is_fp, size=size, sign_ext=sign_ext)
    model.alloc(rob_tag, is_fp, size, sign_ext)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag, address, is_mmio=is_mmio)
    model.addr_update(rob_tag, address, is_mmio)
    await dut_if.step()
    dut_if.clear_addr_update()


async def wait_for_fu_complete(dut_if: LQInterface, max_cycles: int = 4) -> FuComplete:
    """Poll the FU completion output for up to `max_cycles` cycles.

    Returns the first valid result, or the last sample on timeout.
    """
    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    for _ in range(max_cycles):
        if result.valid:
            return result
        await dut_if.step()
        result = dut_if.read_fu_complete()
    return result


async def wait_for_sq_check(
    dut_if: LQInterface, max_cycles: int = 4
) -> dict[str, int | bool]:
    """Poll the SQ-check outputs for up to `max_cycles` cycles.

    Returns the first valid check, or the last sample on timeout.
    """
    await Timer(1, unit="ns")
    sq_check = dut_if.read_sq_check()
    for _ in range(max_cycles):
        if sq_check["valid"]:
            return sq_check
        await dut_if.step()
        sq_check = dut_if.read_sq_check()
    return sq_check


async def wait_for_mem_request(
    dut_if: LQInterface, max_cycles: int = 4
) -> dict[str, int | bool]:
    """Poll the memory read request for up to `max_cycles` cycles.

    Returns the first request with `en` set, or the last sample on timeout.
    """
    await Timer(1, unit="ns")
    mem_req = dut_if.read_mem_request()
    for _ in range(max_cycles):
        if mem_req["en"]:
            return mem_req
        await dut_if.step()
        mem_req = dut_if.read_mem_request()
    return mem_req


async def accept_fu_complete(dut_if: LQInterface) -> None:
    """Accept and clear the currently-presented staged completion."""
    await dut_if.accept_fu_complete()


async def advance_normal_amo_compute(dut_if: LQInterface) -> None:
    """Check that a normal AMO has not started its write, then step past AMO_COMPUTE."""
    await Timer(1, unit="ns")
    assert not dut_if.read_amo_mem_write()["en"], "Normal AMO skipped its compute cycle"
    # Invert the response bus: the result must come from the captured operands.
    dut_if.dut.i_mem_read_data.value = MASK64 ^ int(dut_if.dut.i_mem_read_data.value)
    await dut_if.step()


async def complete_prepared_amo(
    dut_if: LQInterface,
    *,
    rob_tag: int,
    address: int,
    old_value: int,
    expected_write: int,
    description: str,
    size: int = MEM_SIZE_WORD,
    stall_cycles: int = 0,
    expect_equal_relation: bool = False,
    is_minmax: bool = False,
    response_beat: int | None = None,
) -> None:
    """Run an allocated, addressed AMO at the ROB head through to its CDB result.

    Checks the write latency (one AMO_COMPUTE cycle unless MIN/MAX), the write
    address and beat, that the write holds for `stall_cycles` cycles without
    write-done, and the old value on the CDB.
    """
    is_dword = size == MEM_SIZE_DOUBLE
    dut_if.drive_rob_head_tag(rob_tag)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)

    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], f"{description}: AMO read did not issue"
    assert mem_req["addr"] == address, (
        f"{description}: expected read address 0x{address:08x}, got 0x{mem_req['addr']:08x}"
    )
    await dut_if.step()

    dut_if.drive_mem_response(
        old_value if response_beat is None else response_beat,
        dword=is_dword or response_beat is not None,
    )
    await dut_if.step()
    dut_if.clear_mem_response()
    if not is_minmax:
        await advance_normal_amo_compute(dut_if)

    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], f"{description}: AMO write did not become active"
    assert amo_write["addr"] == address, (
        f"{description}: expected write address 0x{address:08x}, got 0x{amo_write['addr']:08x}"
    )
    assert amo_write["is_dword"] == is_dword, (
        f"{description}: expected is_dword={is_dword}, got {amo_write['is_dword']}"
    )
    # A .W write replicates the word across the beat ({2{result}}) and the
    # router's word strobes select the addressed half. A .D write fills the beat.
    expected_beat = (
        expected_write & MASK64
        if is_dword
        else ((expected_write & MASK32) << 32) | (expected_write & MASK32)
    )
    assert amo_write["data"] == expected_beat, (
        f"{description}: expected write beat 0x{expected_beat:016x}, "
        f"got 0x{amo_write['data']:016x}"
    )
    if expect_equal_relation:
        relation = int(dut_if.dut.amo_minmax_selected_relation.value)
        assert relation == 0b10, (
            f"{description}: expected captured EQ relation 10, got {relation:02b}"
        )
        assert not bool(dut_if.dut.amo_minmax_select_old_active.value), (
            f"{description}: strict MIN/MAX equality must select rs2"
        )

    # With write-done withheld, the write request must hold unchanged: its data
    # depends only on the operands and MIN/MAX relation captured at the
    # response, not on live entry state, and it is a level, not a pulse.
    for stall_cycle in range(stall_cycles):
        await dut_if.step()
        stalled_write = dut_if.read_amo_mem_write()
        assert stalled_write == amo_write, (
            f"{description}: write changed on stalled active cycle {stall_cycle}: "
            f"expected {amo_write}, got {stalled_write}"
        )

    dut_if.drive_amo_mem_write_done(True)
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)

    result = await wait_for_fu_complete(dut_if, max_cycles=8)
    assert result.valid, f"{description}: old value did not reach the CDB"
    assert result.tag == rob_tag, (
        f"{description}: expected CDB tag {rob_tag}, got {result.tag}"
    )
    expected_old_value = (
        old_value & MASK_XLEN if is_dword else sign_extend_to_xlen(old_value, 32)
    )
    assert result.value == expected_old_value, (
        f"{description}: expected CDB old value 0x{expected_old_value:x}, "
        f"got 0x{result.value:016x}"
    )
    await accept_fu_complete(dut_if)


async def complete_load_no_forward(
    dut_if: LQInterface,
    model: LQModel,
    mem_data: int,
    rob_head_tag: int = 0,
) -> FuComplete:
    """Disambiguate with no SQ match, issue to memory, respond, and read CDB."""
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_rob_head_tag(rob_head_tag)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Expected memory read to be issued"

    # Step to register the issue
    await dut_if.step()

    dut_if.drive_mem_response(mem_data)
    model.mem_response(mem_data)
    await dut_if.step()
    dut_if.clear_mem_response()

    # Clear SQ signals to avoid issuing next candidate prematurely
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()

    result = await wait_for_fu_complete(dut_if)
    if result.valid:
        await accept_fu_complete(dut_if)
    return result


async def complete_load_fast_path_or_memory(
    dut_if: LQInterface,
    model: LQModel,
    mem_data: int,
    expected_addr: int,
) -> tuple[FuComplete, bool]:
    """Complete a disambiguated load from an L0 hit or, on a miss, from memory.

    Returns the result and whether it came from the L0.
    """
    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    mem_req = dut_if.read_mem_request()

    for _ in range(6):
        if mem_req["en"]:
            assert mem_req["addr"] == expected_addr
            await dut_if.step()
            dut_if.drive_mem_response(mem_data)
            model.mem_response(mem_data)
            await dut_if.step()
            dut_if.clear_mem_response()
            dut_if.drive_sq_all_older_known(False)
            dut_if.clear_sq_forward()
            result = await wait_for_fu_complete(dut_if)
            if result.valid:
                await accept_fu_complete(dut_if)
            return result, False

        if result.valid:
            model.cache_hit_complete()
            _ = model.get_fu_complete()
            model.free_cdb_entry()
            model.advance_head()
            dut_if.drive_sq_all_older_known(False)
            dut_if.clear_sq_forward()
            await accept_fu_complete(dut_if)
            return result, True

        await dut_if.step()
        result = dut_if.read_fu_complete()
        mem_req = dut_if.read_mem_request()

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    return result, False


# ============================================================================
# Test 1: Reset state
# ============================================================================
@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """Empty after reset, no valid outputs."""
    dut_if, _ = await setup(dut)
    await Timer(1, unit="ns")

    assert dut_if.empty, "LQ should be empty after reset"
    assert not dut_if.full, "LQ should not be full after reset"
    assert dut_if.count == 0, "Count should be 0 after reset"
    assert not dut_if.read_fu_complete().valid, "No CDB output after reset"
    assert not dut_if.read_mem_request()["en"], "No memory request after reset"
    assert not dut_if.read_sq_check()["valid"], "No SQ check after reset"


# ============================================================================
# Test 2: Allocate single entry
# ============================================================================
@cocotb.test()
async def test_alloc_single(dut: Any) -> None:
    """Allocate one entry, count=1."""
    dut_if, model = await setup(dut)

    dut_if.drive_alloc(rob_tag=5, size=MEM_SIZE_WORD)
    model.alloc(5, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    assert dut_if.count == 1, f"Expected count=1, got {dut_if.count}"
    assert not dut_if.empty, "Should not be empty"
    assert not dut_if.full, "Should not be full"


# ============================================================================
# Test 2b: Allocate slot 2 only
# ============================================================================
@cocotb.test()
async def test_alloc_slot2_only(dut: Any) -> None:
    """Slot-2-only load allocation takes the next free entry and can complete."""
    dut_if, model = await setup(dut)

    dut_if.drive_alloc_2(rob_tag=6, size=MEM_SIZE_WORD)
    model.alloc(6, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc_2()

    assert dut_if.count == 1, f"Expected count=1, got {dut_if.count}"
    assert not dut_if.empty, "Should not be empty after slot-2-only alloc"

    dut_if.drive_addr_update(rob_tag=6, address=0x1060)
    model.addr_update(6, 0x1060)
    await dut_if.step()
    dut_if.clear_addr_update()

    result = await complete_load_no_forward(dut_if, model, mem_data=0x1234_5678)

    assert result.valid, "Slot-2-only load should complete"
    assert result.tag == 6, f"Expected tag=6, got {result.tag}"
    assert result.value == 0x1234_5678


# ============================================================================
# Test 2c: Allocate slot 1 + slot 2 in the same cycle
# ============================================================================
@cocotb.test()
async def test_alloc_slot1_slot2_pair_completes_in_order(dut: Any) -> None:
    """Two simultaneous load allocations preserve program-order completion."""
    dut_if, model = await setup(dut)

    dut_if.drive_alloc(rob_tag=10, size=MEM_SIZE_WORD)
    dut_if.drive_alloc_2(rob_tag=11, size=MEM_SIZE_WORD)
    model.alloc(10, False, MEM_SIZE_WORD, False)
    model.alloc(11, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.clear_alloc_2()

    assert dut_if.count == 2, f"Expected two allocated entries, got {dut_if.count}"

    # Use distinct dwords. The L0 holds dword lines, so a second load in the
    # same dword would hit the line the first response filled and skip the
    # ordered memory path under test.
    dut_if.drive_addr_update(rob_tag=10, address=0x1100)
    model.addr_update(10, 0x1100)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_addr_update(rob_tag=11, address=0x1108)
    model.addr_update(11, 0x1108)
    await dut_if.step()
    dut_if.clear_addr_update()

    first = await complete_load_no_forward(dut_if, model, mem_data=0xAAAA_0001)
    assert first.valid and first.tag == 10, (
        f"Expected first completion tag=10, got {first}"
    )
    assert first.value == 0xAAAA_0001

    second = await complete_load_no_forward(dut_if, model, mem_data=0xBBBB_0002)
    assert second.valid and second.tag == 11, (
        f"Expected second completion tag=11, got {second}"
    )
    assert second.value == 0xBBBB_0002


# ============================================================================
# Test 3: Allocate to full
# ============================================================================
@cocotb.test()
async def test_alloc_to_full(dut: Any) -> None:
    """Fill all 8 entries, verify o_full."""
    dut_if, model = await setup(dut)

    for i in range(LQ_DEPTH):
        dut_if.drive_alloc(rob_tag=i, size=MEM_SIZE_WORD)
        model.alloc(i, False, MEM_SIZE_WORD, False)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == LQ_DEPTH, f"Expected count={LQ_DEPTH}, got {dut_if.count}"
    assert dut_if.full, "Should be full"
    assert not dut_if.empty, "Should not be empty"


# ============================================================================
# Test 3b: Dispatch back-pressure conservatively lags entry frees
# ============================================================================
@cocotb.test()
async def test_dispatch_backpressure_lags_free_without_understating_capacity(
    dut: Any,
) -> None:
    """The exact o_full clears on the freeing edge; o_dispatch_full one edge later."""
    dut_if, _ = await setup(dut)

    for tag in range(LQ_DEPTH):
        dut_if.drive_alloc(rob_tag=tag, size=MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == LQ_DEPTH
    exact_full_before_free = dut_if.full
    assert exact_full_before_free
    assert bool(dut.o_dispatch_full.value)
    assert bool(dut.o_dispatch_full_for_2.value)

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    async def complete_tag(tag: int, address: int, data: int) -> None:
        dut_if.drive_addr_update(rob_tag=tag, address=address)
        await dut_if.step()
        dut_if.clear_addr_update()

        mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
        assert mem_req["en"], f"tag {tag} never issued"
        assert mem_req["addr"] == address
        await dut_if.step()

        dut_if.drive_mem_response(data)
        await dut_if.step()
        dut_if.clear_mem_response()

        result = await wait_for_fu_complete(dut_if, max_cycles=8)
        assert result.valid and result.tag == tag

    # Capturing tag 0's result frees its entry in the full queue. The exact
    # count drops to seven on that edge, but o_dispatch_full takes no credit
    # for the free and stays high for one more cycle.
    await complete_tag(tag=0, address=0xE300, data=0x1111_0000)
    assert dut_if.count == LQ_DEPTH - 1
    exact_full_after_first_free = dut_if.full
    exact_full_for_2_after_first_free = dut_if.full_for_2
    assert not exact_full_after_first_free
    assert exact_full_for_2_after_first_free
    assert bool(dut.o_dispatch_full.value), "Dispatch took same-edge free credit"
    assert bool(dut.o_dispatch_full_for_2.value)

    await accept_fu_complete(dut_if)
    assert not bool(dut.o_dispatch_full.value), (
        "Dispatch-full did not clear after one edge"
    )
    assert bool(dut.o_dispatch_full_for_2.value)

    # Freeing a second entry (count 6) clears o_full_for_2 on the free edge;
    # o_dispatch_full_for_2 stays high through that edge and clears on the next.
    await complete_tag(tag=1, address=0xE308, data=0x2222_0000)
    assert dut_if.count == LQ_DEPTH - 2
    exact_full_after_second_free = dut_if.full
    exact_full_for_2_after_second_free = dut_if.full_for_2
    assert not exact_full_after_second_free
    assert not exact_full_for_2_after_second_free
    assert bool(dut.o_dispatch_full_for_2.value), (
        "Two-wide dispatch took same-edge free credit"
    )

    await accept_fu_complete(dut_if)
    assert not bool(dut.o_dispatch_full_for_2.value), (
        "Two-wide dispatch-full did not clear after one edge"
    )


# ============================================================================
# Test 3c: Flush-cycle requests reserve conservatively but never allocate
# ============================================================================
@cocotb.test()
async def test_dispatch_reservation_on_partial_flush_cannot_create_ghost(
    dut: Any,
) -> None:
    """A request on a partial-flush cycle may stall dispatch but never allocates."""
    dut_if, _ = await setup(dut)
    dut_if.drive_rob_head_tag(0)

    for tag in range(LQ_DEPTH - 1):
        dut_if.drive_alloc(rob_tag=tag, size=MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == LQ_DEPTH - 1
    exact_full_before_flush = dut_if.full
    exact_full_for_2_before_flush = dut_if.full_for_2
    assert not exact_full_before_flush
    assert exact_full_for_2_before_flush

    # The registered dispatch-full flags count the raw request, but the entry
    # write is flush-gated, as the ROB's allocation is. The partial flush keeps
    # tag 0 and kills tags 1..6; tag 20 must not allocate.
    dut_if.drive_alloc(rob_tag=20, size=MEM_SIZE_WORD)
    dut_if.drive_partial_flush(flush_tag=0)
    await dut_if.step()
    dut_if.clear_partial_flush()
    dut_if.clear_alloc()

    assert dut_if.count == 1, "Flush-cycle request created a ghost LQ entry"
    assert int(dut.lq_valid.value) == 0b0000_0001
    exact_full_after_flush = dut_if.full
    exact_full_for_2_after_flush = dut_if.full_for_2
    assert not exact_full_after_flush
    assert not exact_full_for_2_after_flush
    assert bool(dut.o_dispatch_full.value), (
        "Raw flush-cycle request was not conservatively reserved"
    )

    await dut_if.step()
    assert dut_if.count == 1
    assert not bool(dut.o_dispatch_full.value)
    assert not bool(dut.o_dispatch_full_for_2.value)


# ============================================================================
# Test 3d: Dual allocation and response-bypass free remain conservative
# ============================================================================
@cocotb.test()
async def test_dispatch_reservation_covers_dual_alloc_with_simultaneous_free(
    dut: Any,
) -> None:
    """Dual allocation with a same-edge free: dispatch-full errs toward full.

    The registered flags ignore the free, so they may overstate occupancy but
    never understate it.
    """
    dut_if, _ = await setup(dut)

    for tag in range(LQ_DEPTH - 2):
        dut_if.drive_alloc(rob_tag=tag, size=MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0xE380)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"] and mem_req["addr"] == 0xE380
    await dut_if.step()

    # Both allocations see only physical slots 6 and 7 free in the pre-edge
    # mask. The response bypass simultaneously frees slot 0. The actual mask is
    # therefore 0xFE (seven entries), while dispatch conservatively predicts
    # six + two reservations == full and ignores the free.
    dut_if.drive_alloc(rob_tag=6, size=MEM_SIZE_WORD)
    dut_if.drive_alloc_2(rob_tag=7, size=MEM_SIZE_WORD)
    dut_if.drive_mem_response(0x3333_0000)
    await dut_if.step()
    dut_if.clear_mem_response()
    dut_if.clear_alloc()
    dut_if.clear_alloc_2()

    result = dut_if.read_fu_complete()
    assert result.valid and result.tag == 0
    assert dut_if.count == LQ_DEPTH - 1
    assert int(dut.lq_valid.value) == 0xFE, "Free and allocation targets collided"
    assert not dut_if.full
    assert dut_if.full_for_2
    assert bool(dut.o_dispatch_full.value), "Dispatch prediction took free credit"
    assert bool(dut.o_dispatch_full_for_2.value)

    await accept_fu_complete(dut_if)
    assert not bool(dut.o_dispatch_full.value)
    assert bool(dut.o_dispatch_full_for_2.value)


# ============================================================================
# Test 4: Address update
# ============================================================================
@cocotb.test()
async def test_addr_update(dut: Any) -> None:
    """Allocate -> address update -> SQ check should show address."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=3, address=0x1000)

    # With every older SQ address known, the load reaches the SQ check.
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "SQ check should be valid"
    assert sq_check["addr"] == 0x1000, (
        f"Expected addr=0x1000, got 0x{sq_check['addr']:x}"
    )
    assert sq_check["rob_tag"] == 3


# ============================================================================
# Test 5: Simple LW flow
# ============================================================================
@cocotb.test()
async def test_simple_lw(dut: Any) -> None:
    """Full LW flow: alloc -> addr -> disambig -> mem issue -> mem resp -> CDB."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=7, address=0x2000)
    result = await complete_load_no_forward(dut_if, model, mem_data=0xDEAD_BEEF)

    assert result.valid, "CDB should be valid"
    assert result.tag == 7, f"Expected tag=7, got {result.tag}"
    assert result.value == 0xDEAD_BEEF, f"Expected 0xDEADBEEF, got 0x{result.value:x}"


# ============================================================================
# Test 6: LB signed
# ============================================================================
@cocotb.test()
async def test_lb_signed(dut: Any) -> None:
    """LB with sign extension."""
    dut_if, model = await setup(dut)

    # LB at address 0x1001 (byte offset 1), data has 0x80 at byte 1
    await alloc_and_addr(
        dut_if, model, rob_tag=1, address=0x1001, size=MEM_SIZE_BYTE, sign_ext=True
    )
    result = await complete_load_no_forward(dut_if, model, mem_data=0x0000_8000)

    assert result.valid
    # Byte at offset 1 is 0x80, sign-extended to architectural XLEN.
    expected = sign_extend_to_xlen(0x80, 8)
    assert result.value == expected, f"Expected 0x{expected:x}, got 0x{result.value:x}"


# ============================================================================
# Test 7: LBU unsigned
# ============================================================================
@cocotb.test()
async def test_lbu_unsigned(dut: Any) -> None:
    """LBU with zero extension."""
    dut_if, model = await setup(dut)

    # LBU at address 0x1001 (byte offset 1)
    await alloc_and_addr(
        dut_if, model, rob_tag=2, address=0x1001, size=MEM_SIZE_BYTE, sign_ext=False
    )
    result = await complete_load_no_forward(dut_if, model, mem_data=0x0000_8000)

    assert result.valid
    # Byte at offset 1 is 0x80, zero-extended to 0x00000080
    expected = 0x80
    assert result.value == expected, f"Expected 0x{expected:x}, got 0x{result.value:x}"


# ============================================================================
# Test 8: LH signed
# ============================================================================
@cocotb.test()
async def test_lh_signed(dut: Any) -> None:
    """LH with sign extension."""
    dut_if, model = await setup(dut)

    # LH at address 0x1002 (upper halfword), data has 0x8001 at upper half
    await alloc_and_addr(
        dut_if, model, rob_tag=3, address=0x1002, size=MEM_SIZE_HALF, sign_ext=True
    )
    result = await complete_load_no_forward(dut_if, model, mem_data=0x8001_0000)

    assert result.valid
    expected = sign_extend_to_xlen(0x8001, 16)
    assert result.value == expected, f"Expected 0x{expected:x}, got 0x{result.value:x}"


# ============================================================================
# Test 9: LHU unsigned
# ============================================================================
@cocotb.test()
async def test_lhu_unsigned(dut: Any) -> None:
    """LHU with zero extension."""
    dut_if, model = await setup(dut)

    # LHU at address 0x1002 (upper halfword)
    await alloc_and_addr(
        dut_if, model, rob_tag=4, address=0x1002, size=MEM_SIZE_HALF, sign_ext=False
    )
    result = await complete_load_no_forward(dut_if, model, mem_data=0x8001_0000)

    assert result.valid
    expected = 0x8001
    assert result.value == expected, f"Expected 0x{expected:x}, got 0x{result.value:x}"


# ============================================================================
# Test 10: SQ forward
# ============================================================================
@cocotb.test()
async def test_sq_forward(dut: Any) -> None:
    """An SQ match completes the load by forwarding when forwarding is enabled.

    Otherwise the load waits until the match clears and then reads memory.
    """
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=10, address=0x3000)

    # SQ says: match, can forward, data = 0xCAFEBABE
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=True, can_forward=True, data=0xCAFE_BABE)
    model.apply_forward(SQForwardResult(match=True, can_forward=True, data=0xCAFE_BABE))
    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "Expected forwarded load to reach SQ check stage"

    # While SQ still reports a match, the load must not issue to memory.
    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "Should not issue memory read when SQ forwards"

    result = await wait_for_fu_complete(dut_if)
    if not result.valid:
        # Forwarding disabled (ENABLE_SQ_FORWARD_FAST_PATH=0): release the SQ
        # match and let memory complete the load.
        dut_if.clear_sq_forward()
        mem_req = await wait_for_mem_request(dut_if)
        assert mem_req["en"], "Expected memory read once SQ conflict is released"
        assert mem_req["addr"] == 0x3000
        await dut_if.step()
        dut_if.drive_mem_response(0xCAFE_BABE)
        model.mem_response(0xCAFE_BABE)
        await dut_if.step()
        dut_if.clear_mem_response()
        dut_if.drive_sq_all_older_known(False)
        result = await wait_for_fu_complete(dut_if)
    else:
        dut_if.clear_sq_forward()
        dut_if.drive_sq_all_older_known(False)
        result = await wait_for_fu_complete(dut_if)

    assert result.valid, "Load should complete via SQ fast path or memory fallback"
    assert result.tag == 10
    assert result.value == 0xCAFE_BABE, f"Expected 0xCAFEBABE, got 0x{result.value:x}"


# ============================================================================
# Test 11: SQ disambiguation stall
# ============================================================================
@cocotb.test()
async def test_sq_disambig_stall(dut: Any) -> None:
    """Older SQ address unknown -> load cannot issue."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=11, address=0x4000)

    # SQ says: not all older addresses known
    dut_if.drive_sq_all_older_known(False)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")

    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "Should not issue when older SQ addrs unknown"


# ============================================================================
# Test 12: SQ match but no forward
# ============================================================================
@cocotb.test()
async def test_sq_match_no_forward(dut: Any) -> None:
    """SQ match but can't forward -> load stalls."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=12, address=0x5000)

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=True, can_forward=False)
    await Timer(1, unit="ns")

    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "Should not issue when SQ match but can't forward"


# ============================================================================
# Test 13: MMIO load waits for head
# ============================================================================
@cocotb.test()
async def test_mmio_load(dut: Any) -> None:
    """MMIO load waits until rob_tag == head_tag."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=5, address=0x4000_0000, is_mmio=True)

    # ROB head at tag 3, not the load's tag
    dut_if.drive_rob_head_tag(3)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")

    # Not at head: no SQ check
    sq_check = dut_if.read_sq_check()
    assert not sq_check["valid"], "MMIO should not check SQ when not at head"

    # Move the head to the load's tag
    dut_if.drive_rob_head_tag(5)
    sq_check = await wait_for_sq_check(dut_if)

    assert sq_check["valid"], "MMIO should check SQ when at head"
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "MMIO should issue when at head"


# ============================================================================
# Test 13b: The router's pending bit serializes MMIO handoffs
# ============================================================================
@cocotb.test()
async def test_mmio_handoff_obeys_router_pending_feedback(dut: Any) -> None:
    """The router's pending bit blocks younger launches until it accepts the MMIO load.

    The LQ hands the ROB-head MMIO load to the router without waiting for
    committed stores to drain; the router parks the read and checks the drain
    before accepting it. The pending bit reaches the LQ through
    ``i_mem_bus_busy`` and stays high through the accept cycle, so no second
    handoff happens. The device response and the next handoff may share a
    cycle. An MMIO load takes no cached-load slot.
    """
    dut_if, model = await setup(dut)

    mmio_addr = 0x4000_0000
    younger_addr = 0x1800

    # Allocate the MMIO load at the ROB head and a younger ordinary load that
    # would otherwise be ready to launch on a following cycle.
    await alloc_and_addr(dut_if, model, rob_tag=5, address=mmio_addr, is_mmio=True)
    await alloc_and_addr(dut_if, model, rob_tag=6, address=younger_addr)
    dut_if.drive_rob_head_tag(5)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(False)

    # Committed stores have not drained. The router enforces that wait, so the
    # LQ still hands off the MMIO load, exactly once. The younger load may
    # already hold the staging register from the setup cycles, and ROB-head
    # priority may evict it; only the head MMIO request may reach the router.
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "head MMIO request never reached the router boundary"
    assert mem_req["addr"] == mmio_addr
    assert not bool(dut.i_sq_committed_empty.value)

    model_req = model.issue_to_memory(
        True,
        SQForwardResult(),
        rob_head_tag=5,
        sq_committed_empty=False,
    )
    assert model_req is not None and model_req["addr"] == mmio_addr

    # Register the handoff, then drive the router's pending bit and the LQ
    # bus-busy that the wrapper derives from it. The younger load has no SQ
    # conflict but must not send a second request while the first is parked.
    await dut_if.step()
    assert dut_if.mem_outstanding
    dut_if.drive_mem_request_pending(True)
    dut_if.drive_mem_bus_busy(True)
    for cycle in range(6):
        mem_req = dut_if.read_mem_request()
        assert not mem_req["en"], (
            f"cycle {cycle}: younger load escaped while router pending was high"
        )
        await dut_if.step()

    # The pending bit stays high through the accept cycle and clears on its
    # closing edge; the response arrives in the next cycle, with pending low.
    # A launch does not wait for the fast owner's response, so the younger
    # staged load may launch as soon as i_mem_bus_busy drops.
    dut_if.drive_sq_committed_empty(True)
    dut_if.drive_mem_request_pending(False)
    dut_if.drive_mem_bus_busy(False)
    dut_if.drive_mem_response(0xA55A_1234)
    model.mem_response(0xA55A_1234)
    await Timer(1, unit="ns")
    # The staged younger load may launch in the response cycle itself. Sample
    # that cycle too, or the check below would miss its one-cycle request.
    release_request = dut_if.read_mem_request()
    younger_seen = release_request["en"]
    if younger_seen:
        assert release_request["addr"] == younger_addr
    await dut_if.step()
    dut_if.clear_mem_response()
    dut_if.drive_sq_committed_empty(False)

    # Sample both signals before every edge so the younger request's one-cycle
    # pulse cannot be hidden by waiting for the independently held CDB result.
    result = dut_if.read_fu_complete()
    for _ in range(10):
        mem_req = dut_if.read_mem_request()
        if mem_req["en"]:
            assert mem_req["addr"] == younger_addr
            younger_seen = True
        if result.valid and younger_seen:
            break
        await dut_if.step()
        result = dut_if.read_fu_complete()
    assert result.valid and result.tag == 5
    assert result.value == 0xA55A_1234

    # The younger load launched once the router's pending bit dropped. Ordinary
    # low-BRAM loads never wait for committed stores to drain; for device
    # reads the router applies that wait.
    assert younger_seen


@cocotb.test()
async def test_mmio_full_flush_cancels_router_pending_without_response_debt(
    dut: Any,
) -> None:
    """After a full flush cancels a request parked in the router, no response is owed."""
    dut_if, model = await setup(dut)

    mmio_addr = 0x4000_0000
    replacement_addr = 0x1A00
    await alloc_and_addr(dut_if, model, rob_tag=5, address=mmio_addr, is_mmio=True)
    dut_if.drive_rob_head_tag(5)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"] and mem_req["addr"] == mmio_addr
    await dut_if.step()
    mem_outstanding_after_handoff = dut_if.mem_outstanding
    assert mem_outstanding_after_handoff

    # The router holds the request but has not accepted it. A full flush
    # cancels it there, so the LQ must clear mem_outstanding without setting
    # drop_mem_response_pending.
    dut_if.drive_mem_request_pending(True)
    dut_if.drive_mem_bus_busy(True)
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()
    dut_if.drive_mem_request_pending(False)
    dut_if.drive_mem_bus_busy(False)
    assert dut_if.empty
    assert not dut_if.mem_outstanding

    await alloc_and_addr(dut_if, model, rob_tag=1, address=replacement_addr)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], "canceled router request left a response owed"
    assert mem_req["addr"] == replacement_addr


@cocotb.test()
async def test_cached_full_flush_after_accept_drains_stale_response(
    dut: Any,
) -> None:
    """After a full flush, a cached read the router accepted still owes its response.

    Only the load's cached slot waits for it: a replacement load launches
    meanwhile, through another slot or the fast tier. When the stale response
    lands it is drained with no completion and no L0 fill, and the slot frees.
    """
    dut_if, model = await setup(dut)

    cached_addr = 0x8000_0200
    replacement_addr = 0x1C00
    await alloc_and_addr(dut_if, model, rob_tag=5, address=cached_addr)
    dut_if.drive_rob_head_tag(5)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"] and mem_req["addr"] == cached_addr
    stale_slot = mem_req["id"]
    await dut_if.step()
    # With the write port free, the router accepts a cached request in the
    # cycle it arrives, so the pending bit stays low; the response may take
    # any number of cycles.
    dut_if.drive_mem_request_pending(False)
    dut_if.drive_mem_bus_busy(False)

    # Flush the load after the handoff. A replacement load may allocate, stage
    # and launch; only the flushed load's slot waits for the stale response.
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    assert dut_if.empty

    await alloc_and_addr(dut_if, model, rob_tag=1, address=replacement_addr)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], "replacement blocked by another slot's stale response"
    assert mem_req["addr"] == replacement_addr
    await dut_if.step()
    # The fast-tier replacement answers next cycle and completes normally.
    dut_if.drive_mem_response(0x0123_4567)
    model.mem_response(0x0123_4567)
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 1 and result.value == 0x0123_4567
    await accept_fu_complete(dut_if)

    # Now the stale cached response lands: drained, not completed, no L0 fill.
    dut_if.drive_mem_response(0xDEAD_BEEF, cached=True, slot=stale_slot)
    await Timer(1, unit="ns")
    assert not dut_if.read_fu_complete().valid
    assert not bool(dut.o_l0_fill.value), "stale cached response must not refill L0"
    await dut_if.step()
    dut_if.clear_mem_response()
    assert not (await wait_for_fu_complete(dut_if, max_cycles=2)).valid


@cocotb.test()
async def test_mmio_response_coincident_with_full_flush_drains_immediately(
    dut: Any,
) -> None:
    """An MMIO response arriving with a full flush is drained at once; nothing is owed."""
    dut_if, model = await setup(dut)

    mmio_addr = 0x4000_0000
    replacement_addr = 0x1E00
    await alloc_and_addr(dut_if, model, rob_tag=5, address=mmio_addr, is_mmio=True)
    dut_if.drive_rob_head_tag(5)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"] and mem_req["addr"] == mmio_addr
    await dut_if.step()
    mem_outstanding_after_handoff = dut_if.mem_outstanding
    assert mem_outstanding_after_handoff

    # Model the router's pending cycle and its accept edge. In the next cycle
    # pending is low and the response arrives.
    dut_if.drive_mem_request_pending(True)
    dut_if.drive_mem_bus_busy(True)
    await dut_if.step()
    dut_if.drive_mem_request_pending(False)
    dut_if.drive_mem_bus_busy(False)
    dut_if.drive_flush_all()
    model.flush_all()
    dut_if.drive_mem_response(0x1234_5678)
    await Timer(1, unit="ns")
    assert not dut_if.read_fu_complete().valid
    assert not bool(dut.o_l0_fill.value)
    await dut_if.step()
    dut_if.clear_mem_response()
    dut_if.clear_flush_all()
    assert dut_if.empty
    assert not dut_if.mem_outstanding

    await alloc_and_addr(dut_if, model, rob_tag=1, address=replacement_addr)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], "coincident MMIO response left a response owed"
    assert mem_req["addr"] == replacement_addr


# ============================================================================
# Test 13c: Misaligned MMIO completes without a device read during SQ drain
# ============================================================================
@cocotb.test()
async def test_misaligned_mmio_completes_without_device_read_during_drain(
    dut: Any,
) -> None:
    """A misaligned MMIO load faults with no device read, even while stores drain.

    With i_trap_misaligned_accesses set, the LQ completes the load with its
    fault while committed stores are still draining; the trap unit waits for
    the drain before taking the trap.
    """
    dut_if, model = await setup(dut)

    mmio_addr = 0x4000_0002
    await alloc_and_addr(dut_if, model, rob_tag=6, address=mmio_addr, is_mmio=True)
    dut_if.drive_rob_head_tag(6)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_trap_misaligned_accesses(True)
    dut_if.drive_sq_committed_empty(False)

    result = dut_if.read_fu_complete()
    for cycle in range(8):
        await Timer(1, unit="ns")
        assert not dut_if.read_mem_request()["en"], (
            f"cycle {cycle}: misaligned MMIO unexpectedly launched a memory read"
        )
        result = dut_if.read_fu_complete()
        if result.valid:
            break
        await dut_if.step()
    assert result.valid, (
        "misaligned MMIO did not report its no-read fault while stores drained"
    )
    assert result.tag == 6
    assert result.exception, "misaligned MMIO completion must be exceptional"
    assert result.exc_cause == 4, "expected load-address-misaligned cause"
    assert result.value == mmio_addr, "faulting MMIO address must be carried as mtval"
    assert not bool(dut.i_sq_committed_empty.value), (
        "test unexpectedly opened the drain gate"
    )
    assert not dut_if.read_mem_request()["en"], (
        "misaligned MMIO must not access the device"
    )


# ============================================================================
# Test 14: FLD single beat
# ============================================================================
@cocotb.test()
async def test_fld_single_beat(dut: Any) -> None:
    """FLD: one memory read returning the full beat, 64-bit CDB broadcast."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(
        dut_if, model, rob_tag=14, address=0x6000, is_fp=True, size=MEM_SIZE_DOUBLE
    )

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "FLD should issue"
    assert mem_req["addr"] == 0x6000, (
        f"FLD addr should be 0x6000, got 0x{mem_req['addr']:x}"
    )

    await dut_if.step()

    # One response carries the whole aligned dword
    fld_beat = 0xCCCC_DDDD_AAAA_BBBB
    dut_if.drive_mem_response(fld_beat, dword=True)
    model.mem_response(fld_beat)
    await dut_if.step()
    dut_if.clear_mem_response()

    # CDB should have full 64-bit value after the staged completion registers it
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "CDB should be valid after FLD"
    assert result.tag == 14
    assert result.value == fld_beat, (
        f"Expected 0x{fld_beat:016x}, got 0x{result.value:016x}"
    )
    await accept_fu_complete(dut_if)


@cocotb.test()
async def test_dword_response_bypass(dut: Any) -> None:
    """LD/FLD/LR.D complete at response capture in both tiers, exactly once."""
    from .lq_interface import LR_D

    dut_if, _ = await setup(dut)
    for cached in (False, True):
        for kind in ("ld", "fld", "lr.d"):
            await dut_if.reset_dut()
            address = (0x8000_0000 if cached else 0) + 0x6800
            value = 0x8765_4321_FEDC_BA98
            dut_if.drive_rob_head_tag(3)
            dut_if.drive_alloc(
                3,
                is_fp=kind == "fld",
                size=MEM_SIZE_DOUBLE,
                is_lr=kind == "lr.d",
                amo_op=LR_D if kind == "lr.d" else 0,
            )
            await dut_if.step()
            dut_if.clear_alloc()
            dut_if.drive_addr_update(3, address)
            await dut_if.step()
            dut_if.clear_addr_update()
            dut_if.drive_sq_all_older_known(True)
            dut_if.drive_sq_forward(match=False, can_forward=False)
            request = await wait_for_mem_request(dut_if)
            assert request["en"] and request["addr"] == address
            await dut_if.step()
            dut_if.drive_mem_response(value, dword=True)
            await dut_if.step()
            dut_if.clear_mem_response()

            # No polling here: the latency itself is the contract under test.
            result = dut_if.read_fu_complete()
            assert result.valid, f"{kind}, cached={cached}: missed response bypass"
            assert result.tag == 3 and result.value == value and not result.exception
            assert bool(dut.o_reservation_valid.value) == (kind == "lr.d")
            for _ in range(3):
                await dut_if.step()
                assert dut_if.read_fu_complete() == result, "blocked result changed"
                assert not dut_if.read_mem_request()["en"], "duplicate memory read"
            await accept_fu_complete(dut_if)
            for _ in range(5):
                await dut_if.step()
                assert not dut_if.read_fu_complete().valid, "duplicate completion"
            assert dut_if.empty


@cocotb.test()
async def test_dword_response_backpressure_and_reordering(dut: Any) -> None:
    """A held younger dword completion forces the older response to the RAM path."""
    dut_if, model = await setup(dut)
    requests = []
    values = {1: 0x0123_4567_89AB_CDEF, 2: 0xFEDC_BA98_7654_3210}
    for tag in (1, 2):
        await alloc_and_addr(
            dut_if,
            model,
            tag,
            0x8000_7000 + tag * 8,
            is_fp=tag == 2,
            size=MEM_SIZE_DOUBLE,
        )
        dut_if.drive_sq_all_older_known(True)
        dut_if.drive_sq_forward(match=False, can_forward=False)
        request = await wait_for_mem_request(dut_if)
        assert request["en"]
        requests.append(request)
        await dut_if.step()
    assert requests[0]["id"] != requests[1]["id"]

    dut_if.drive_mem_response(
        values[2], dword=True, cached=True, slot=int(requests[1]["id"])
    )
    await dut_if.step()
    dut_if.clear_mem_response()
    result = dut_if.read_fu_complete()
    assert result.valid and result.tag == 2 and result.value == values[2]

    dut_if.drive_mem_response(
        values[1], dword=True, cached=True, slot=int(requests[0]["id"])
    )
    await dut_if.step()
    dut_if.clear_mem_response()
    for _ in range(3):
        assert dut_if.read_fu_complete() == result, "response overwrote held CDB result"
        await dut_if.step()
    await accept_fu_complete(dut_if)
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 1 and result.value == values[1]
    await accept_fu_complete(dut_if)
    for _ in range(5):
        await dut_if.step()
        assert not dut_if.read_fu_complete().valid, "response completed twice"
    assert dut_if.empty


@cocotb.test()
async def test_dword_response_flush_boundary(dut: Any) -> None:
    """A flush that kills a dword load drains its response; a surviving load completes."""
    dut_if, _ = await setup(dut)
    for cached in (False, True):
        for flush in ("full", "younger", "older"):
            await dut_if.reset_dut()
            model = LQModel()
            address = (0x8000_0000 if cached else 0) + 0x7400
            await alloc_and_addr(dut_if, model, 4, address, size=MEM_SIZE_DOUBLE)
            dut_if.drive_sq_all_older_known(True)
            dut_if.drive_sq_forward(match=False, can_forward=False)
            request = await wait_for_mem_request(dut_if)
            assert request["en"]
            await dut_if.step()
            if flush == "full":
                dut_if.drive_flush_all()
            else:
                dut_if.drive_partial_flush(
                    2 if flush == "younger" else 6, early_recovery=True
                )
            value = 0x9876_5432_10FE_DCBA
            dut_if.drive_mem_response(value, dword=True)
            await dut_if.step()
            dut_if.clear_mem_response()
            dut_if.clear_flush_all()
            dut_if.clear_partial_flush()
            result = await wait_for_fu_complete(dut_if)
            if flush == "older":
                assert result.valid and result.tag == 4 and result.value == value
                await accept_fu_complete(dut_if)
            else:
                assert not result.valid, f"{flush} flush leaked a dword completion"
            for _ in range(5):
                await dut_if.step()
                assert not dut_if.read_fu_complete().valid


@cocotb.test()
async def test_lr_d_response_dma_invalidation(dut: Any) -> None:
    """DMA invalidation on LR.D response suppresses reservation, not its value."""
    from .lq_interface import LR_D

    dut_if, _ = await setup(dut)
    address = 0x8000_7800
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_alloc(1, size=MEM_SIZE_DOUBLE, is_lr=True, amo_op=LR_D)
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_addr_update(1, address)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    request = await wait_for_mem_request(dut_if)
    assert request["en"]
    await dut_if.step()
    dut.i_coh_inval_valid.value = 1
    dut.i_coh_inval_addr.value = address
    value = 0xABCD_EF01_2345_6789
    dut_if.drive_mem_response(value, dword=True)
    await dut_if.step()
    dut_if.clear_mem_response()
    dut.i_coh_inval_valid.value = 0
    result = dut_if.read_fu_complete()
    assert result.valid and result.tag == 1 and result.value == value
    assert not bool(dut.o_reservation_valid.value)
    await accept_fu_complete(dut_if)
    for _ in range(5):
        await dut_if.step()
        assert not dut_if.read_fu_complete().valid
        assert not bool(dut.o_reservation_valid.value)


# ============================================================================
# Test 15: FLW NaN-boxing
# ============================================================================
@cocotb.test()
async def test_flw_nan_boxing(dut: Any) -> None:
    """FLW: 32-bit value NaN-boxed to 64 bits on CDB."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(
        dut_if, model, rob_tag=15, address=0x7000, is_fp=True, size=MEM_SIZE_WORD
    )
    result = await complete_load_no_forward(dut_if, model, mem_data=0x3F80_0000)

    assert result.valid
    expected = 0xFFFF_FFFF_3F80_0000
    assert result.value == expected, (
        f"Expected 0x{expected:016x}, got 0x{result.value:016x}"
    )


# ============================================================================
# Test 16: Flush all
# ============================================================================
@cocotb.test()
async def test_flush_all(dut: Any) -> None:
    """Flush all entries, LQ empty."""
    dut_if, model = await setup(dut)

    for i in range(4):
        dut_if.drive_alloc(rob_tag=i, size=MEM_SIZE_WORD)
        model.alloc(i, False, MEM_SIZE_WORD, False)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == 4

    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.empty, "LQ should be empty after flush_all"
    assert dut_if.count == 0


# ============================================================================
# Test 16b: Flush-cycle SQ-check payload capture contract
# ============================================================================
@cocotb.test()
async def test_flush_cycle_sq_check_payload_capture_contract(dut: Any) -> None:
    """Full flush kills a coincident capture; partial flush blocks it.

    Full flush is absent from the early gate behind ``sq_check_payload_en``:
    the payload may toggle on the flush edge because the same edge resets all
    SQ-check controls and LQ-valid state. Partial flush is selective, so it
    must suppress the payload enable instead of relying on a bulk reset.
    """
    dut_if, _ = await setup(dut)

    full_flush_tag = 2
    full_flush_addr = 0x1234_5678

    dut_if.drive_alloc(rob_tag=full_flush_tag, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    # Prime the registered CAM look-ahead so the next-cycle address update is
    # a same-cycle SQ-check candidate.
    dut_if.drive_pre_issue(full_flush_tag)
    await dut_if.step()
    dut_if.clear_pre_issue()

    dut_if.drive_addr_update(full_flush_tag, full_flush_addr)
    dut_if.drive_flush_all()
    await Timer(1, unit="ns")

    assert bool(dut.issue_mem_found.value), "full-flush marker was not selected"
    assert bool(dut.sq_check_payload_en.value), (
        "full flush must not gate the dead SQ-check payload write"
    )
    assert int(dut.sq_check_addr_next.value) == full_flush_addr

    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.clear_flush_all()

    # The payload write happened, but full-flush reset priority makes it dead.
    assert int(dut.sq_check_addr_q.value) == full_flush_addr
    assert dut_if.empty, "full flush left a live LQ row"
    assert dut_if.count == 0
    assert not bool(dut.sq_check_pending.value)
    assert not bool(dut.sq_check_phase2.value)
    assert int(dut.sq_check_in_flight_mask.value) == 0
    assert not dut_if.read_sq_check()["valid"]
    assert not dut_if.read_mem_request()["en"]
    assert not dut_if.read_fu_complete().valid
    assert not bool(dut.o_mem_addr_valid.value)
    assert not dut_if.read_amo_mem_write()["en"]

    partial_flush_tag = 3
    partial_flush_addr = 0xCAFE_BA5C

    dut_if.drive_alloc(rob_tag=partial_flush_tag, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_pre_issue(partial_flush_tag)
    await dut_if.step()
    dut_if.clear_pre_issue()

    # With ROB head 0, flushing after tag 2 kills tag 3.  Unlike full flush,
    # this selective flush must prevent the coincident candidate from ever
    # becoming staged.
    dut_if.drive_addr_update(partial_flush_tag, partial_flush_addr)
    dut_if.drive_partial_flush(flush_tag=2)
    await Timer(1, unit="ns")

    assert bool(dut.issue_mem_found.value), "partial-flush marker was not selected"
    assert not bool(dut.sq_check_payload_en.value), (
        "partial flush admitted an SQ-check payload capture"
    )

    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.clear_partial_flush()

    assert int(dut.sq_check_addr_q.value) == full_flush_addr, (
        "partial flush overwrote the prior dead payload with its marker"
    )
    assert dut_if.empty, "partial flush left its younger LQ row live"
    assert dut_if.count == 0
    assert not bool(dut.sq_check_pending.value)
    assert not bool(dut.sq_check_phase2.value)
    assert int(dut.sq_check_in_flight_mask.value) == 0

    # Observe one unflushed cycle as well: no delayed stage or external side
    # effect may escape after recovery deasserts.
    await dut_if.step()
    assert not dut_if.read_sq_check()["valid"]
    assert not dut_if.read_mem_request()["en"]
    assert not dut_if.read_fu_complete().valid
    assert not bool(dut.o_mem_addr_valid.value)
    assert not dut_if.read_amo_mem_write()["en"]


# ============================================================================
# Test 17: Partial flush
# ============================================================================
@cocotb.test()
async def test_partial_flush(dut: Any) -> None:
    """Flush younger entries, older entries survive."""
    dut_if, model = await setup(dut)

    dut_if.drive_rob_head_tag(0)

    for i in range(4):
        dut_if.drive_alloc(rob_tag=i, size=MEM_SIZE_WORD)
        model.alloc(i, False, MEM_SIZE_WORD, False)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == 4

    # Partial flush: invalidate entries younger than tag 1
    # (tags 2 and 3 should be flushed, tags 0 and 1 survive)
    dut_if.drive_partial_flush(flush_tag=1)
    model.partial_flush(1, 0)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert dut_if.count == 2, f"Expected count=2, got {dut_if.count}"


# ============================================================================
# Test 18: Oldest first ordering
# ============================================================================
@cocotb.test()
async def test_oldest_first_ordering(dut: Any) -> None:
    """Multiple ready loads, oldest issues first."""
    dut_if, model = await setup(dut)

    for tag in [10, 11]:
        await alloc_and_addr(dut_if, model, rob_tag=tag, address=0x1000 + tag * 4)

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    # The SQ check presents the oldest ready load (tag 10)
    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["rob_tag"] == 10, (
        f"Expected oldest tag=10, got {sq_check['rob_tag']}"
    )


# ============================================================================
# Test 19: CDB back-pressure
# ============================================================================
@cocotb.test()
async def test_cdb_backpressure(dut: Any) -> None:
    """Staged completion remains asserted until the consumer accepts it."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=19, address=0x8000)

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Expected memory read before response"
    await dut_if.step()

    dut_if.drive_mem_response(0x1234_5678)
    model.mem_response(0x1234_5678)
    await dut_if.step()
    dut_if.clear_mem_response()

    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "Staged completion should appear once ready"
    assert result.value == 0x1234_5678

    # Without acceptance, the staged result must remain visible.
    await dut_if.step()
    held = dut_if.read_fu_complete()
    assert held.valid, "Completion should stay asserted until accepted"
    assert held.value == 0x1234_5678

    await accept_fu_complete(dut_if)
    assert not dut_if.read_fu_complete().valid, (
        "Completion should clear after acceptance"
    )


# ============================================================================
# Test 20: Back-to-back loads
# ============================================================================
@cocotb.test()
async def test_back_to_back_loads(dut: Any) -> None:
    """Complete one load, immediately issue next."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=20, address=0xA000)
    await alloc_and_addr(dut_if, model, rob_tag=21, address=0xA004)

    result = await complete_load_no_forward(dut_if, model, mem_data=0x1111_1111)
    assert result.valid and result.tag == 20

    # Clear SQ signals before stepping to avoid second load issuing prematurely
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()

    # Free the entry (step past CDB broadcast)
    await dut_if.step()

    # Second load should now be the issue candidate
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")

    sq_check = dut_if.read_sq_check()
    assert sq_check["valid"], "Second load should be ready"
    assert sq_check["rob_tag"] == 21


# ============================================================================
# Test 21: Empty SQ skips the SQ query round-trip
# ============================================================================
@cocotb.test()
async def test_empty_sq_skips_disambiguation_query(dut: Any) -> None:
    """When the SQ is empty, a staged load should issue without an SQ query."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=22, address=0xA100)

    dut_if.drive_sq_empty(True)
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()

    await Timer(1, unit="ns")
    assert not dut_if.read_sq_check()["valid"], "Empty SQ should skip the SQ query"

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], (
        "Load should issue once the staged empty-SQ candidate reaches phase 2"
    )
    assert mem_req["addr"] == 0xA100

    await dut_if.step()
    dut_if.drive_mem_response(0x1234_5678)
    await dut_if.step()
    dut_if.clear_mem_response()
    dut_if.drive_sq_empty(False)

    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "Load should complete after the memory response"
    assert result.tag == 22
    assert result.value == 0x1234_5678

    await accept_fu_complete(dut_if)


# ============================================================================
# Test 21b: Constrained random
# ============================================================================
@cocotb.test()
async def test_constrained_random(dut: Any) -> None:
    """Random allocations, memory traffic, and full flushes; check count/full/empty."""
    dut_if, _model = await setup(dut)
    dut_if.drive_sq_empty(True)

    rng = random.Random(cocotb.RANDOM_SEED)
    num_cycles = 200
    next_tag = 0

    for cycle in range(num_cycles):
        action = rng.random()

        # Priority 1: drain any DUT staged result.  The LQ has response/cache
        # bypass paths that can free an entry in the same cycle they create the
        # staged CDB payload, so this random test checks interface invariants
        # instead of mirroring every bypass cycle in a Python scoreboard.
        dut_cdb = dut_if.read_fu_complete()
        if dut_cdb.valid:
            dut_if.drive_result_accepted(True)
            await dut_if.step()
            dut_if.clear_result_accepted()

        # Priority 2: Provide memory response if outstanding
        elif bool(dut.mem_outstanding.value):
            data = rng.randint(0, MASK32)
            dut_if.drive_mem_response(data)
            await dut_if.step()
            dut_if.clear_mem_response()

        # Priority 3: Random action
        elif action < 0.05:
            # Flush all
            dut_if.drive_flush_all()
            await dut_if.step()
            dut_if.clear_flush_all()

        elif action < 0.35 and not dut_if.full:
            # Allocate + address update
            tag = next_tag % 32
            next_tag += 1
            size = rng.choice([MEM_SIZE_BYTE, MEM_SIZE_HALF, MEM_SIZE_WORD])
            sign_ext = rng.random() < 0.5
            dut_if.drive_alloc(rob_tag=tag, size=size, sign_ext=sign_ext)
            await dut_if.step()
            dut_if.clear_alloc()

            addr = rng.randint(0, 0xFFFF) & ~0x3
            dut_if.drive_addr_update(tag, addr)
            await dut_if.step()
            dut_if.clear_addr_update()

        else:
            # Try to issue a memory read
            dut_if.drive_sq_all_older_known(True)
            dut_if.drive_sq_forward(match=False, can_forward=False)
            await Timer(1, unit="ns")

            await dut_if.step()
            dut_if.drive_sq_all_older_known(False)
            dut_if.clear_sq_forward()

        # Check DUT-visible queue invariants.
        assert 0 <= dut_if.count <= LQ_DEPTH, (
            f"cycle {cycle}: invalid count {dut_if.count}"
        )
        assert dut_if.full == (dut_if.count == LQ_DEPTH), (
            f"cycle {cycle}: full/count mismatch"
        )
        assert dut_if.empty == (dut_if.count == 0), (
            f"cycle {cycle}: empty/count mismatch"
        )

    cocotb.log.info(f"=== Constrained random test passed ({num_cycles} cycles) ===")


# ============================================================================
# Test 22: Stale response after partial flush
# ============================================================================
@cocotb.test()
async def test_stale_response_after_partial_flush(dut: Any) -> None:
    """Partial flush of in-flight load, late mem response is discarded."""
    dut_if, model = await setup(dut)

    dut_if.drive_rob_head_tag(0)

    await alloc_and_addr(dut_if, model, rob_tag=5, address=0x1000)

    # Issue to memory
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Should issue to memory"
    model.issue_to_memory(True, SQForwardResult())
    await dut_if.step()
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()

    # Partial flush: tag 5 is younger than tag 2 (relative to head 0)
    dut_if.drive_partial_flush(flush_tag=2)
    model.partial_flush(2, 0)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert dut_if.count == 0, f"Tag 5 should be flushed, count={dut_if.count}"
    assert not dut_if.mem_outstanding, "Killed response owner remained live after flush"
    assert model.mem_outstanding, "Model should keep mem_outstanding (drain)"

    # The late memory response is drained, not completed
    dut_if.drive_mem_response(0xDEAD_BEEF)
    model.mem_response_drain(0xDEAD_BEEF)
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_fill.value), "Late stale response refilled L0"
    assert not dut_if.read_fu_complete().valid, (
        "Late stale response completed a killed load"
    )
    await dut_if.step()
    dut_if.clear_mem_response()

    assert not dut_if.mem_outstanding
    assert not model.mem_outstanding, "mem_outstanding should be cleared after drain"
    assert dut_if.count == 0, "No valid entries after drain"  # type: ignore[unreachable]

    # Allocation works again: no stale state remains
    dut_if.drive_alloc(rob_tag=10, size=MEM_SIZE_WORD)
    model.alloc(10, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    assert dut_if.count == 1, "Should be able to allocate after drain"


# ============================================================================
# Test 22b: Partial-flush-coincident response warms L0 but is still discarded
# ============================================================================
@cocotb.test()
async def test_partial_flush_coincident_response_fills_l0_only(dut: Any) -> None:
    """A killed load's coincident ordinary response may fill L0, not complete.

    The branch-recovery flush does not change architectural memory, so an
    ordinary non-MMIO response remains a valid cache image. The killed load
    must still leave the LQ without an FU completion.
    """
    dut_if, model = await setup(dut)

    addr = 0x1800
    returned_word = 0xD15C_A11E

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_empty(True)
    await alloc_and_addr(dut_if, model, rob_tag=5, address=addr)

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Expected the soon-to-be-flushed load to issue"
    assert mem_req["addr"] == addr
    model_req = model.issue_to_memory(True, SQForwardResult())
    assert model_req is not None and model_req["addr"] == addr
    await dut_if.step()

    # Tag 5 is younger than the tag-2 flush boundary.  Present its response in
    # the same cycle as the flush: the cache fill pulse must fire, while the
    # LQ response-accept path remains suppressed.
    dut_if.drive_partial_flush(flush_tag=2, early_recovery=True)
    dut_if.drive_mem_response(returned_word)
    model.partial_flush(2, 0)
    model.mem_response_drain(returned_word)
    await Timer(1, unit="ns")
    assert bool(dut.o_l0_fill.value), (
        "Safe ordinary response did not fill L0 on the coincident partial flush"
    )
    assert not dut_if.read_fu_complete().valid, (
        "Killed load completed while its response was being drained"
    )

    await dut_if.step()
    dut_if.clear_partial_flush()
    dut_if.clear_mem_response()
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()

    assert dut_if.empty, "Partial flush did not remove the killed load"
    assert dut_if.count == 0
    assert not (await wait_for_fu_complete(dut_if, max_cycles=2)).valid, (
        "Drained response produced a delayed FU completion"
    )

    # A later architectural load to the same word must consume the retained
    # memory image from L0 without issuing another memory request.
    await alloc_and_addr(dut_if, model, rob_tag=6, address=addr)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    result, used_fast_path = await complete_load_fast_path_or_memory(
        dut_if, model, mem_data=returned_word, expected_addr=addr
    )
    assert used_fast_path, "Coincident partial-flush response did not warm L0"
    assert result.valid and result.tag == 6
    assert result.value == returned_word


# ============================================================================
# Test 23: Tail reclamation after partial flush
# ============================================================================
@cocotb.test()
async def test_tail_reclamation_after_partial_flush(dut: Any) -> None:
    """After partial flush, LQ not falsely full, can allocate."""
    dut_if, model = await setup(dut)

    dut_if.drive_rob_head_tag(0)

    # Fill all 8 entries with tags 0-7
    for i in range(LQ_DEPTH):
        dut_if.drive_alloc(rob_tag=i, size=MEM_SIZE_WORD)
        model.alloc(i, False, MEM_SIZE_WORD, False)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.full, "LQ should be full"

    # Partial flush: invalidate tags 4-7 (younger than tag 3)
    dut_if.drive_partial_flush(flush_tag=3)
    model.partial_flush(3, 0)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert dut_if.count == 4, f"Expected 4 valid entries, got {dut_if.count}"
    assert not dut_if.full, (
        "LQ should NOT be full after partial flush with tail reclamation"
    )

    # Should be able to allocate new entries
    dut_if.drive_alloc(rob_tag=20, size=MEM_SIZE_WORD)  # type: ignore[unreachable]
    model.alloc(20, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    assert dut_if.count == 5, f"Expected 5 after allocation, got {dut_if.count}"


# ============================================================================
# Test 24: Non-contiguous hole reuse without immediate tail compaction
# ============================================================================
@cocotb.test()
async def test_tail_retraction_non_contiguous_hole(dut: Any) -> None:
    """Sparse allocation reuses holes even though partial flush leaves tail stale.

    Allocate out-of-ROB-order so that a partial flush creates the pattern:
      idx 0(V) 1(V) 2(INVALID) 3(V) 4(INVALID) 5(INVALID)
    The queue should not report full after reusing four free holes, and the
    fifth new allocation should consume the last remaining hole.
    """
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(0)

    # Allocate 6 entries with tags that create a hole after flush.
    # Tags 5, 6, 7 are younger than flush_tag=4, tags 0, 1, 2 are not.
    for tag in [0, 1, 5, 2, 6, 7]:
        dut_if.drive_alloc(rob_tag=tag, size=MEM_SIZE_WORD)
        model.alloc(tag, False, MEM_SIZE_WORD, False)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == 6, f"Expected 6 entries, got {dut_if.count}"

    # Partial flush: tags 5, 6, 7 are younger than 4 (relative to head 0)
    # Post-flush: idx 0(V:tag0) 1(V:tag1) 2(I:tag5) 3(V:tag2) 4(I:tag6) 5(I:tag7)
    dut_if.drive_partial_flush(flush_tag=4)
    model.partial_flush(4, 0)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert dut_if.count == 3, f"Expected 3 valid entries, got {dut_if.count}"
    assert not dut_if.full, "LQ should not be full after partial flush"

    # Four allocations should reuse four of the five free holes, but the queue
    # should not report full until the final free slot is consumed.
    for i in range(4):
        dut_if.drive_alloc(rob_tag=10 + i, size=MEM_SIZE_WORD)
        model.alloc(10 + i, False, MEM_SIZE_WORD, False)
        await dut_if.step()
        dut_if.clear_alloc()

    count = dut_if.count
    assert count == 7, f"Expected 7 valid entries (with hole), got {count}"
    assert model.count == 7, f"Model count must match DUT (got {model.count})"
    assert not dut_if.full, "LQ should not be full while one free hole remains"
    assert not model.full, "Model should not be full while one free hole remains"

    dut_if.drive_alloc(rob_tag=14, size=MEM_SIZE_WORD)
    model.alloc(14, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    assert dut_if.count == 8, f"Expected 8 valid entries, got {dut_if.count}"
    assert model.count == 8, f"Model count must match DUT (got {model.count})"


# ============================================================================
# Test 25: L0 cache hit delivers data after SQ disambiguation
# ============================================================================
@cocotb.test()
async def test_cache_hit_bypasses_memory(dut: Any) -> None:
    """L0-warm load completes from fast path or falls back to memory.

    Flow: first load -> memory -> fills cache -> second load same addr -> cache hit.
    """
    dut_if, model = await setup(dut)

    # First load: fill the cache via memory
    await alloc_and_addr(dut_if, model, rob_tag=1, address=0x2000)
    result = await complete_load_no_forward(dut_if, model, mem_data=0xAAAA_BBBB)
    assert result.valid and result.tag == 1
    assert result.value == 0xAAAA_BBBB

    # Free entry (step to consume CDB broadcast)
    await dut_if.step()

    # Second load at the same address should hit L0 after SQ disambiguation
    await alloc_and_addr(dut_if, model, rob_tag=2, address=0x2000)

    # Drive SQ disambiguation: no older conflicting store
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    result, used_fast_path = await complete_load_fast_path_or_memory(
        dut_if, model, mem_data=0xAAAA_BBBB, expected_addr=0x2000
    )
    assert result.valid, "Second load should complete from cache or memory fallback"
    assert result.tag == 2
    assert result.value == 0xAAAA_BBBB, f"Expected 0xAAAABBBB, got 0x{result.value:x}"
    if used_fast_path:
        assert not dut_if.read_mem_request()["en"], (
            "Fast-path cache hit should skip memory"
        )


@cocotb.test()
async def test_cache_hit_blocked_while_mem_bus_busy(dut: Any) -> None:
    """A warm L0 hit must wait while a store or AMO write holds the memory port.

    The write can hold the port before its L0 invalidation takes effect, so a
    load that has passed the SQ check must not complete from the L0 while
    i_mem_bus_busy is high.
    """
    dut_if, model = await setup(dut)

    addr = 0x8000_0040
    stale_word = 0x1122_3344

    # Fill L0 with the old value.
    dut_if.drive_sq_empty(True)
    await alloc_and_addr(dut_if, model, rob_tag=1, address=addr)
    result = await complete_load_no_forward(dut_if, model, mem_data=stale_word)
    assert result.valid and result.value == stale_word
    await dut_if.step()

    # Capture another load to the same warm line. Keep SQ non-empty so the
    # candidate reaches phase 2 through the SQ-check response path,
    # matching an older-store drain window.
    dut_if.drive_sq_empty(False)
    await alloc_and_addr(dut_if, model, rob_tag=2, address=addr)

    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "Expected LQ to present SQ check"
    assert sq_check["addr"] == addr

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await dut_if.step()

    dut_if.drive_mem_bus_busy(True)
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_hit.value), "L0 fast path fired while memory bus was busy"
    assert not dut_if.read_fu_complete().valid, (
        "Load completed from stale L0 during SQ write"
    )
    assert not dut_if.read_mem_request()["en"], (
        "Busy memory bus should block memory issue"
    )

    await dut_if.step()
    assert not (await wait_for_fu_complete(dut_if, max_cycles=1)).valid

    dut_if.drive_mem_bus_busy(False)
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()


@cocotb.test()
async def test_cache_hit_blocked_until_delayed_store_invalidation(dut: Any) -> None:
    """A store's write launch invalidates the warm L0 line, so it never hits stale.

    A cached-tier store's write stays in flight for cycles after the SQ write
    pulse drops, and a younger load to the same address must not use the stale
    L0 line in that gap. The SQ invalidates the line in the launch cycle, where
    i_mem_bus_busy and the L0's same-cycle invalidate suppression also block
    the hit. In the gap the load misses and may issue to memory; the router
    orders that read behind the in-flight write
    (test_load_queued_behind_cached_write_inflight).
    """
    dut_if, model = await setup(dut)

    addr = 0x8000_0080
    stale_word = 0xCAFE_BABE
    fresh_word = 0x0BAD_F00D

    # Fill L0 with the old value.
    dut_if.drive_sq_empty(True)
    await alloc_and_addr(dut_if, model, rob_tag=1, address=addr)
    result = await complete_load_no_forward(dut_if, model, mem_data=stale_word)
    assert result.valid and result.value == stale_word
    await dut_if.step()

    # Capture another load to the same warm line through the SQ-check path so
    # it models a younger load behind a draining store.
    dut_if.drive_sq_empty(False)
    await alloc_and_addr(dut_if, model, rob_tag=2, address=addr)

    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "Expected LQ to present SQ check"
    assert sq_check["addr"] == addr

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await dut_if.step()

    # Store launch cycle: the memory port is busy and the SQ fires the L0
    # invalidate for the written address in this same cycle. The warm line
    # must not hit (busy gate + same-cycle invalidate suppress).
    dut_if.drive_mem_bus_busy(True)
    dut_if.drive_cache_invalidate(addr)
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_hit.value), (
        "L0 fast path fired while SQ write owned the bus"
    )
    assert not dut_if.read_fu_complete().valid, (
        "Load completed from stale L0 during SQ write"
    )
    assert not dut_if.read_mem_request()["en"], (
        "Busy memory bus should block memory issue"
    )
    await dut_if.step()
    dut_if.clear_cache_invalidate()

    # Cached-tier delayed-write gap: the write pulse and busy are gone while the
    # store is still in its write pipeline. The line was invalidated at launch,
    # so the load must miss: no stale hit, no stale completion. Issuing to
    # memory here is fine because the router orders the read behind the
    # in-flight write.
    dut_if.drive_mem_bus_busy(False)
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_hit.value), (
        "L0 fast path fired in the write-flight gap despite the launch-time "
        "invalidation"
    )
    assert not dut_if.read_fu_complete().valid, (
        "Load completed from stale L0 in the write-flight gap"
    )
    mem_req = dut_if.read_mem_request()
    await dut_if.step()

    if not mem_req["en"]:
        mem_req = await wait_for_mem_request(dut_if, max_cycles=3)
    assert mem_req["en"], "Load should issue to memory after the launch invalidation"
    assert mem_req["addr"] == addr

    dut_if.drive_mem_response(fresh_word)
    model.mem_response(fresh_word)
    await dut_if.step()
    dut_if.clear_mem_response()

    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "Load should complete after fetching fresh memory data"
    assert result.tag == 2
    assert result.value == fresh_word, (
        f"Expected fresh value 0x{fresh_word:x}, got 0x{result.value:x}"
    )

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    await accept_fu_complete(dut_if)


@cocotb.test()
async def test_cached_response_after_invalidate_does_not_refill_l0(dut: Any) -> None:
    """A cached-tier response must not fill L0 after a store hit its dword in flight.

    An older store to the other word of the same dword does not conflict with
    the load, so the load can launch before the store drains, and its beat may
    then hold the pre-store word. The response still completes the load but
    must not fill L0, or a younger load could hit stale data.
    """
    dut_if, model = await setup(dut)

    addr = 0x8000_0200
    stale_word = 0x1122_3344
    fresh_word = 0x5566_7788

    dut_if.drive_sq_empty(True)

    # Launch a cached-region load and leave its response delayed.
    await alloc_and_addr(dut_if, model, rob_tag=1, address=addr)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Expected first cached load to issue"
    assert mem_req["addr"] == addr
    await dut_if.step()

    # A store write invalidates the load's dword while its read is in flight.
    dut_if.drive_cache_invalidate(addr)
    await dut_if.step()
    dut_if.clear_cache_invalidate()

    # The load still completes with the value its read returned.
    await dut_if.step()
    dut_if.drive_mem_response(stale_word)
    model.mem_response(stale_word)
    await dut_if.step()
    dut_if.clear_mem_response()

    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "Delayed cached load should still complete"
    assert result.tag == 1
    assert result.value == stale_word
    await accept_fu_complete(dut_if)

    # A later load to the same word must miss L0 and fetch the post-store value.
    await alloc_and_addr(dut_if, model, rob_tag=2, address=addr)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")

    assert not bool(dut.o_l0_hit.value), (
        "Stale cached response refilled L0 after invalidation"
    )
    mem_req = await wait_for_mem_request(dut_if, max_cycles=4)
    assert mem_req["en"], "Later load should miss L0 and issue to memory"
    assert mem_req["addr"] == addr
    await dut_if.step()

    dut_if.drive_mem_response(fresh_word)
    model.mem_response(fresh_word)
    await dut_if.step()
    dut_if.clear_mem_response()

    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "Later load should complete from memory"
    assert result.tag == 2
    assert result.value == fresh_word

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    await accept_fu_complete(dut_if)


@cocotb.test()
async def test_cached_response_during_flush_all_does_not_refill_l0(dut: Any) -> None:
    """A cached-tier response coincident with flush_all must be drained only."""
    dut_if, model = await setup(dut)

    addr = 0x8000_0300
    stale_word = 0x0000_0CC0
    fresh_word = 0xA5A5_5A5A

    dut_if.drive_sq_empty(True)

    # Launch a cached-region load and delay its response until full flush.
    await alloc_and_addr(dut_if, model, rob_tag=1, address=addr)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Expected cached load to issue"
    assert mem_req["addr"] == addr
    await dut_if.step()

    # The response arrives in the same cycle as trap/MRET-style full flush.
    # It must not complete the killed load and must not refill the persistent L0.
    dut_if.drive_flush_all()
    model.flush_all()
    dut_if.drive_mem_response(stale_word)
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_fill.value), "Full-flush response filled L0"
    await dut_if.step()
    dut_if.clear_flush_all()
    dut_if.clear_mem_response()

    assert dut_if.empty, "Full flush should clear the LQ"
    assert not (await wait_for_fu_complete(dut_if, max_cycles=1)).valid

    # A later load to the same word must miss L0 and fetch the fresh value.
    await alloc_and_addr(dut_if, model, rob_tag=2, address=addr)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")

    assert not bool(dut.o_l0_hit.value), "Flushed response left a stale L0 hit"
    mem_req = await wait_for_mem_request(dut_if, max_cycles=4)
    assert mem_req["en"], "Later load should miss L0 and issue to memory"
    assert mem_req["addr"] == addr
    await dut_if.step()

    dut_if.drive_mem_response(fresh_word)
    model.mem_response(fresh_word)
    await dut_if.step()
    dut_if.clear_mem_response()

    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "Later load should complete from memory"
    assert result.tag == 2
    assert result.value == fresh_word

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    await accept_fu_complete(dut_if)


# ============================================================================
# Test 26: Cache miss fills cache, subsequent hit
# ============================================================================
@cocotb.test()
async def test_cache_miss_fills_cache(dut: Any) -> None:
    """Cache miss -> fill -> subsequent load uses fast path or memory fallback."""
    dut_if, model = await setup(dut)

    # First load at 0x3000 misses the cold cache and goes to memory
    await alloc_and_addr(dut_if, model, rob_tag=3, address=0x3000)
    result = await complete_load_no_forward(dut_if, model, mem_data=0x1234_5678)
    assert result.valid and result.value == 0x1234_5678
    await dut_if.step()

    # Second load at 0x3000 should hit the cache after SQ disambiguation
    await alloc_and_addr(dut_if, model, rob_tag=4, address=0x3000)

    # Drive SQ disambiguation: no older conflicting store
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    result, _ = await complete_load_fast_path_or_memory(
        dut_if, model, mem_data=0x1234_5678, expected_addr=0x3000
    )
    assert result.valid, "Second load should complete after warm-cache lookup"
    assert result.tag == 4
    assert result.value == 0x1234_5678


# ============================================================================
# Test 27: Warm-cache LBU uses the fast path
# ============================================================================
@cocotb.test()
async def test_cache_hit_lbu_uses_fast_path(dut: Any) -> None:
    """Warm-cache LBU should complete without issuing a memory read."""
    dut_if, model = await setup(dut)

    base_addr = 0x2400
    raw_word = 0x80FE_AA55

    await alloc_and_addr(dut_if, model, rob_tag=5, address=base_addr)
    result = await complete_load_no_forward(dut_if, model, mem_data=raw_word)
    assert result.valid and result.value == raw_word
    await dut_if.step()

    await alloc_and_addr(
        dut_if,
        model,
        rob_tag=6,
        address=base_addr + 1,
        size=MEM_SIZE_BYTE,
        sign_ext=False,
    )

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    result, used_fast_path = await complete_load_fast_path_or_memory(
        dut_if,
        model,
        mem_data=raw_word,
        expected_addr=base_addr + 1,
    )
    assert result.valid, "Warm-cache LBU should complete"
    assert result.tag == 6
    assert result.value == 0xAA
    assert used_fast_path, "Warm-cache LBU should bypass memory"


# ============================================================================
# Test 28: Warm-cache LH/LHU use the fast path
# ============================================================================
@cocotb.test()
async def test_cache_hit_halfword_uses_fast_path(dut: Any) -> None:
    """Warm-cache LH and LHU should complete without issuing a memory read."""
    dut_if, model = await setup(dut)

    base_addr = 0x2800
    raw_word = 0x8001_7F22

    await alloc_and_addr(dut_if, model, rob_tag=7, address=base_addr)
    result = await complete_load_no_forward(dut_if, model, mem_data=raw_word)
    assert result.valid and result.value == raw_word
    await dut_if.step()

    await alloc_and_addr(
        dut_if,
        model,
        rob_tag=0,
        address=base_addr + 2,
        size=MEM_SIZE_HALF,
        sign_ext=True,
    )

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    result, used_fast_path = await complete_load_fast_path_or_memory(
        dut_if,
        model,
        mem_data=raw_word,
        expected_addr=base_addr + 2,
    )
    assert result.valid, "Warm-cache LH should complete"
    assert result.tag == 0
    assert result.value == sign_extend_to_xlen(0x8001, 16)
    assert used_fast_path, "Warm-cache LH should bypass memory"
    await dut_if.step()

    await alloc_and_addr(
        dut_if,
        model,
        rob_tag=1,
        address=base_addr + 2,
        size=MEM_SIZE_HALF,
        sign_ext=False,
    )

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    result, used_fast_path = await complete_load_fast_path_or_memory(
        dut_if,
        model,
        mem_data=raw_word,
        expected_addr=base_addr + 2,
    )
    assert result.valid, "Warm-cache LHU should complete"
    assert result.tag == 1
    assert result.value == 0x8001
    assert used_fast_path, "Warm-cache LHU should bypass memory"


# ============================================================================
# Test 29: MMIO address always misses cache
# ============================================================================
@cocotb.test()
async def test_cache_mmio_bypass(dut: Any) -> None:
    """An MMIO load at the ROB head reads memory; the L0 never serves MMIO."""
    dut_if, model = await setup(dut)

    # MMIO quadrant: addr[31:30] == 2'b01
    mmio_addr = 0x4000_0000

    # A load from an MMIO address must go through memory
    await alloc_and_addr(dut_if, model, rob_tag=5, address=mmio_addr, is_mmio=True)

    # Set ROB head to tag 5 (MMIO loads must be at head)
    dut_if.drive_rob_head_tag(5)

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    # Memory should be issued (cache always misses MMIO)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "MMIO load should issue to memory, not cache"


# ============================================================================
# Test 29b: FLD fills both cache words, subsequent LW hits correct addresses
# ============================================================================
@cocotb.test()
async def test_fld_cache_fill_both_words(dut: Any) -> None:
    """FLD fills its dword L0 line; later LW loads hit either word of it."""
    dut_if, model = await setup(dut)

    base_addr = 0x2000
    low_word = 0xAAAA_BBBB
    high_word = 0xCCCC_DDDD
    fld_beat = (high_word << 32) | low_word

    # -- FLD at base_addr: single-beat memory completion fills the line --
    await alloc_and_addr(
        dut_if, model, rob_tag=1, address=base_addr, is_fp=True, size=MEM_SIZE_DOUBLE
    )

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "FLD should issue"
    assert mem_req["addr"] == base_addr
    await dut_if.step()

    dut_if.drive_mem_response(fld_beat, dword=True)
    model.mem_response(fld_beat)
    await dut_if.step()
    dut_if.clear_mem_response()

    # CDB broadcast for FLD
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "FLD CDB should be valid"
    assert result.tag == 1
    await accept_fu_complete(dut_if)

    # -- LW at base_addr: should hit L0 cache with low_word --
    await alloc_and_addr(dut_if, model, rob_tag=2, address=base_addr)

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    result, _ = await complete_load_fast_path_or_memory(
        dut_if, model, mem_data=low_word, expected_addr=base_addr
    )
    assert result.valid, "LW at base_addr should complete"
    assert result.tag == 2
    assert result.value == low_word, (
        f"LW at base_addr: expected 0x{low_word:08x}, got 0x{result.value:08x} "
        "(dword L0 line served the wrong word?)"
    )

    # -- LW at base_addr + 4: should hit L0 cache with high_word --
    await alloc_and_addr(dut_if, model, rob_tag=3, address=base_addr + 4)

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    result, _ = await complete_load_fast_path_or_memory(
        dut_if, model, mem_data=high_word, expected_addr=base_addr + 4
    )
    assert result.valid, "LW at base_addr+4 should complete"
    assert result.tag == 3
    assert result.value == high_word, (
        f"LW at base_addr+4: expected 0x{high_word:08x}, got 0x{result.value:08x}"
    )


# ============================================================================
# Test 29c: MMIO load blocks SQ forwarding even when SQ says can_forward
# ============================================================================
@cocotb.test()
async def test_mmio_load_blocks_sq_forward(dut: Any) -> None:
    """An MMIO load never takes forwarded data, even when the SQ reports can_forward.

    With a matching older store it stalls instead. In the RTL, sq_do_forward
    excludes MMIO loads (!sq_check_is_mmio_q), but this bench runs with
    ENABLE_SQ_FORWARD_FAST_PATH=0, where no load forwards, so the test checks
    the stall rather than that guard.
    """
    dut_if, model = await setup(dut)

    mmio_addr = 0x4000_0000

    await alloc_and_addr(dut_if, model, rob_tag=5, address=mmio_addr, is_mmio=True)

    # MMIO loads require rob_tag == head_tag to issue
    dut_if.drive_rob_head_tag(5)

    # SQ says: all older known, can_forward=True (would forward for non-MMIO)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=True, can_forward=True, data=0xBADD_A7A0)

    # SQ check should be valid (MMIO at head can disambiguate)
    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "MMIO load at head should check SQ"

    # Despite can_forward=True the load gets no forwarded data. It does not
    # issue to memory either: sq_can_issue is false while match=True, so it
    # stalls. That is the required behavior; an MMIO load behind a matching
    # store waits until that store has drained.
    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], (
        "MMIO load with SQ match should stall, not issue to memory"
    )

    # Step once; the entry must not become data_valid through forwarding
    await dut_if.step()

    # Verify no CDB broadcast happened (load is still waiting)
    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    assert not result.valid, "MMIO load should not have been forwarded"

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()


# ============================================================================
# Test 30: LR waits for ROB head
# ============================================================================
@cocotb.test()
async def test_lr_waits_for_rob_head(dut: Any) -> None:
    """LR entry doesn't issue until rob_tag matches ROB head tag."""
    dut_if, model = await setup(dut)

    dut_if.drive_alloc(rob_tag=5, size=MEM_SIZE_WORD, is_lr=True)
    model.alloc(5, False, MEM_SIZE_WORD, False, is_lr=True)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=5, address=0x1000)
    model.addr_update(5, 0x1000)
    await dut_if.step()
    dut_if.clear_addr_update()

    # ROB head at tag 3, not the LR's tag: the LR must not issue
    dut_if.drive_rob_head_tag(3)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)

    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "LR should not issue when not at ROB head"

    # Head at the LR's tag: the LR issues
    dut_if.drive_rob_head_tag(5)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "LR should issue when at ROB head"


# ============================================================================
# Test 31: LR sets reservation
# ============================================================================
@cocotb.test()
async def test_lr_sets_reservation(dut: Any) -> None:
    """After LR memory response, o_reservation_valid=1."""
    dut_if, model = await setup(dut)

    assert not dut_if.read_reservation_valid(), (
        "Reservation should be invalid after reset"
    )

    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_lr=True)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_lr=True)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0x2000)
    model.addr_update(0, 0x2000)
    await dut_if.step()
    dut_if.clear_addr_update()

    # Issue LR (at ROB head)
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "LR should issue"
    await dut_if.step()

    dut_if.drive_mem_response(0xDEADBEEF)
    model.mem_response(0xDEADBEEF)
    await dut_if.step()
    dut_if.clear_mem_response()

    await Timer(1, unit="ns")
    assert dut_if.read_reservation_valid(), "Reservation should be valid after LR"
    assert dut_if.read_reservation_addr() == 0x2000, "Reservation addr should match"


# ============================================================================
# Test 32: LR reservation cleared by flush_all
# ============================================================================
@cocotb.test()
async def test_lr_reservation_cleared_by_flush(dut: Any) -> None:
    """flush_all clears reservation."""
    dut_if, model = await setup(dut)

    # Set up LR and get reservation
    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_lr=True)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_lr=True)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0x3000)
    model.addr_update(0, 0x3000)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "LR should issue before reservation is set"
    await dut_if.step()

    dut_if.drive_mem_response(0x1234)
    model.mem_response(0x1234)
    await dut_if.step()
    dut_if.clear_mem_response()

    await Timer(1, unit="ns")
    assert dut_if.read_reservation_valid(), "Reservation should be set"

    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert not dut_if.read_reservation_valid(), "Reservation cleared after flush_all"


# ============================================================================
# Test 33: LR reservation cleared by SC
# ============================================================================
@cocotb.test()
async def test_lr_reservation_cleared_by_sc(dut: Any) -> None:
    """i_sc_clear_reservation clears reservation."""
    dut_if, model = await setup(dut)

    # Set up LR and get reservation
    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_lr=True)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_lr=True)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0x4000)
    model.addr_update(0, 0x4000)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "LR should issue before reservation is set"
    await dut_if.step()

    dut_if.drive_mem_response(0x5678)
    model.mem_response(0x5678)
    await dut_if.step()
    dut_if.clear_mem_response()

    await Timer(1, unit="ns")
    assert dut_if.read_reservation_valid(), "Reservation should be set"

    dut_if.drive_sc_clear_reservation(True)
    model.sc_clear_reservation()
    await dut_if.step()
    dut_if.drive_sc_clear_reservation(False)

    assert not dut_if.read_reservation_valid(), "Reservation cleared by SC"


# ============================================================================
# Test 34: LR reservation cleared by snoop
# ============================================================================
@cocotb.test()
async def test_lr_reservation_cleared_by_snoop(dut: Any) -> None:
    """i_reservation_snoop_invalidate clears reservation."""
    dut_if, model = await setup(dut)

    # Set up LR and get reservation
    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_lr=True)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_lr=True)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0x5000)
    model.addr_update(0, 0x5000)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "LR should issue before reservation is set"
    await dut_if.step()

    dut_if.drive_mem_response(0x9ABC)
    model.mem_response(0x9ABC)
    await dut_if.step()
    dut_if.clear_mem_response()

    await Timer(1, unit="ns")
    assert dut_if.read_reservation_valid(), "Reservation should be set"

    dut_if.drive_reservation_snoop_invalidate(True)
    model.reservation_snoop_invalidate()
    await dut_if.step()
    dut_if.drive_reservation_snoop_invalidate(False)

    assert not dut_if.read_reservation_valid(), "Reservation cleared by snoop"


# ============================================================================
# Test 35: AMO waits for ROB head and SQ committed empty
# ============================================================================
@cocotb.test()
async def test_amo_waits_for_rob_head_and_sq_committed_empty(dut: Any) -> None:
    """AMO entry doesn't issue until rob_tag == head AND sq_committed_empty."""
    dut_if, model = await setup(dut)

    from .lq_interface import AMOSWAP_W

    dut_if.drive_alloc(rob_tag=3, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(3, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=3, address=0x6000, amo_rs2=0xAA)
    model.addr_update(3, 0x6000, amo_rs2=0xAA)
    await dut_if.step()
    dut_if.clear_addr_update()

    # Case 1: head=3 but sq_committed_empty=false: no issue
    dut_if.drive_rob_head_tag(3)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(False)

    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "AMO should not issue when sq_committed_empty=false"

    # Case 2: head=0 but sq_committed_empty=true: no issue
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_committed_empty(True)
    await Timer(1, unit="ns")

    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "AMO should not issue when not at ROB head"

    # Case 3: head=3 and sq_committed_empty=true: issues
    dut_if.drive_rob_head_tag(3)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "AMO should issue when at ROB head and sq_committed_empty"


# ============================================================================
# Test 35b: ROB-head AMO ignores a physically earlier younger AMO
# ============================================================================
@cocotb.test()
async def test_head_amo_ignores_physically_earlier_younger_amo(dut: Any) -> None:
    """Physical queue order does not make a younger AMO block the ROB-head AMO."""
    dut_if, model = await setup(dut)

    from .lq_interface import AMOSWAP_W

    # Physical order: younger pending AMO, then the ROB-head AMO. Dependency
    # rows are built from ROB-tag age, not physical order, so the head AMO
    # stays eligible.
    dut_if.drive_alloc(rob_tag=1, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(1, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=1, address=0x9000, amo_rs2=0x11)
    model.addr_update(1, 0x9000, amo_rs2=0x11)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_addr_update(rob_tag=0, address=0x9004, amo_rs2=0x22)
    model.addr_update(0, 0x9004, amo_rs2=0x22)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_empty(True)
    dut_if.drive_sq_committed_empty(True)

    mem_req = await wait_for_mem_request(dut_if, max_cycles=AMO_RESCUE_THRESHOLD + 8)
    assert mem_req["en"], "ROB-head AMO should ignore physically earlier younger AMO"
    assert mem_req["addr"] == 0x9004, (
        f"Expected head AMO addr=0x9004, got 0x{mem_req['addr']:x}"
    )


# ============================================================================
# Test 35c: AMO write fence orders younger loads behind the head AMO
# ============================================================================
@cocotb.test()
async def test_blocked_head_amo_does_not_preempt_normal_candidate(dut: Any) -> None:
    """Younger loads are fenced until every older AMO has written memory.

    The AMO write fence (older_amo_write_pending) holds any load younger than
    an un-written AMO: letting it launch would read the pre-AMO memory value.
    The fenced load also releases SQ-check staging, so the eligible ROB-head
    AMO itself is the entry that reaches the memory port first.
    """
    dut_if, model = await setup(dut)

    from .lq_interface import AMOSWAP_W

    # Physical order: normal younger load, younger pending AMO, ROB-head AMO.
    # Both AMOs are architecturally older than the normal load, so the AMO
    # write fence holds the load and the eligible ROB-head AMO issues first.
    dut_if.drive_alloc(rob_tag=2, size=MEM_SIZE_WORD)
    model.alloc(2, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_alloc(rob_tag=1, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(1, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=2, address=0xA000)
    model.addr_update(2, 0xA000)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_addr_update(rob_tag=1, address=0xA004, amo_rs2=0x11)
    model.addr_update(1, 0xA004, amo_rs2=0x11)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_addr_update(rob_tag=0, address=0xA008, amo_rs2=0x22)
    model.addr_update(0, 0xA008, amo_rs2=0x22)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_empty(True)
    dut_if.drive_sq_committed_empty(True)

    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], "Head AMO read should issue while younger loads are fenced"
    assert mem_req["addr"] == 0xA008, (
        f"Expected head AMO addr=0xA008 (younger load fenced), got 0x{mem_req['addr']:x}"
    )


# ============================================================================
# Test 35d: AMO write fence evicts a fenced younger load from SQ-check
# ============================================================================
@cocotb.test()
async def test_blocked_head_amo_does_not_replace_busy_sq_check(dut: Any) -> None:
    """A staged load fenced by older AMOs releases SQ-check for the head AMO.

    Once older un-written AMOs exist, the staged younger load must not issue
    (it would read pre-AMO memory).  It releases staging instead, and the
    eligible ROB-head AMO takes the memory port.
    """
    dut_if, model = await setup(dut)

    from .lq_interface import AMOSWAP_W

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_empty(False)
    dut_if.drive_sq_all_older_known(False)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)

    await alloc_and_addr(dut_if, model, rob_tag=2, address=0xB000)

    sq_check = await wait_for_sq_check(dut_if, max_cycles=4)
    assert sq_check["valid"], "Younger load should occupy SQ-check"
    assert sq_check["rob_tag"] == 2

    # Physical order after the staged load: younger pending AMO, then the true
    # ROB-head AMO.  Both AMOs are architecturally older than the staged load
    # (tags 0 and 1 vs 2), so the AMO write fence must evict the staged load
    # and the head AMO must reach the memory port.
    dut_if.drive_alloc(rob_tag=1, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(1, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=1, address=0xB004, amo_rs2=0x11)
    model.addr_update(1, 0xB004, amo_rs2=0x11)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_addr_update(rob_tag=0, address=0xB008, amo_rs2=0x22)
    model.addr_update(0, 0xB008, amo_rs2=0x22)
    await dut_if.step()
    dut_if.clear_addr_update()

    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], (
        "Head AMO read should issue once the fenced load releases staging"
    )
    assert mem_req["addr"] == 0xB008, (
        f"Expected head AMO addr=0xB008 (fenced load evicted), got 0x{mem_req['addr']:x}"
    )


# ============================================================================
# Test 35e: Every older-AMO dependency must retire independently
# ============================================================================
@cocotb.test()
async def test_younger_load_waits_for_every_older_amo_dependency(dut: Any) -> None:
    """Completing one of two older AMOs must not release a younger load."""
    dut_if, _ = await setup(dut)

    from .lq_interface import AMOSWAP_W

    # Physical/program order is AMO 0, AMO 1, then load 2. Leave AMO 1 without
    # an address so it cannot issue after AMO 0 completes. The younger load is
    # otherwise fully ready, making any lost dependency visible as a read.
    for rob_tag in (0, 1):
        dut_if.drive_alloc(
            rob_tag=rob_tag,
            size=MEM_SIZE_WORD,
            is_amo=True,
            amo_op=AMOSWAP_W,
        )
        await dut_if.step()
        dut_if.clear_alloc()

    dut_if.drive_alloc(rob_tag=2, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0xC000, amo_rs2=0x1234)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.drive_addr_update(rob_tag=2, address=0xC008)
    await dut_if.step()
    dut_if.clear_addr_update()

    await complete_prepared_amo(
        dut_if,
        rob_tag=0,
        address=0xC000,
        old_value=0xAAAA_5555,
        expected_write=0x1234,
        description="first of two older AMOs",
    )

    dut_if.drive_rob_head_tag(1)
    for _ in range(6):
        await Timer(1, unit="ns")
        assert not dut_if.mem_outstanding, (
            "Younger load launched after only one of two older AMOs completed"
        )
        assert not dut_if.read_mem_request()["en"], (
            "Younger load was released while the second older AMO was pending"
        )
        await dut_if.step()


# ============================================================================
# Test 35f: Reusing an AMO's physical slot starts a new dependency generation
# ============================================================================
@cocotb.test()
async def test_younger_amo_slot_reuse_does_not_revive_stale_dependency(
    dut: Any,
) -> None:
    """A younger AMO reusing a slot cannot re-block an older surviving load."""
    dut_if, _ = await setup(dut)

    from .lq_interface import AMOSWAP_W

    # AMO 0 occupies physical slot 0; the surviving load occupies slot 1 and
    # records slot 0 as an older dependency. Keep the load addressless while
    # AMO 0 completes so it cannot launch before slot 0 is reused.
    dut_if.drive_alloc(
        rob_tag=0,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOSWAP_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_alloc(rob_tag=1, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0xD000, amo_rs2=0xCAFE)
    await dut_if.step()
    dut_if.clear_addr_update()
    await complete_prepared_amo(
        dut_if,
        rob_tag=0,
        address=0xD000,
        old_value=0x1020_3040,
        expected_write=0xCAFE,
        description="AMO before physical-slot reuse",
    )
    assert dut_if.count == 1, f"Expected only the surviving load, got {dut_if.count}"

    # Fill physical slots 2..7, wrapping the allocator back to freed slot 0.
    # These fillers remain addressless and therefore cannot contend for issue.
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_all_older_known(False)
    for filler_tag in range(2, 8):
        dut_if.drive_alloc(rob_tag=filler_tag, size=MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    # Tag 8 is younger than the surviving tag-1 load but reuses the exact
    # physical bit that represented completed AMO 0.
    dut_if.drive_alloc(
        rob_tag=8,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOSWAP_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    assert dut_if.full, "Younger AMO did not reuse the final free physical slot"

    dut_if.drive_addr_update(rob_tag=1, address=0xD100)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)

    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], "Older load deadlocked on a reused stale AMO dependency"
    assert mem_req["addr"] == 0xD100, (
        f"Expected older load addr=0xD100, got 0x{mem_req['addr']:x}"
    )


# ============================================================================
# Test 35g: Slot-2 sees a simultaneous older slot-1 AMO
# ============================================================================
@cocotb.test()
async def test_dual_alloc_slot2_load_depends_on_slot1_amo(dut: Any) -> None:
    """A slot-2 load captures a slot-1 AMO allocated on the same edge."""
    dut_if, _ = await setup(dut)

    from .lq_interface import AMOSWAP_W

    dut_if.drive_alloc(
        rob_tag=0,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOSWAP_W,
    )
    dut_if.drive_alloc_2(rob_tag=1, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.clear_alloc_2()

    # Only the younger load is address-ready. With no dependency capture it
    # would pass SQ-check and issue; the addressless older AMO cannot explain
    # an idle memory port.
    dut_if.drive_addr_update(rob_tag=1, address=0xE004)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_empty(True)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)

    for _ in range(6):
        await Timer(1, unit="ns")
        assert not dut_if.mem_outstanding, (
            "Slot-2 load launched through its simultaneous older slot-1 AMO"
        )
        assert not dut_if.read_mem_request()["en"], (
            "Slot-2 load did not capture the simultaneous slot-1 AMO dependency"
        )
        await dut_if.step()


# ============================================================================
# Test 35h: Partial-flush dependency state cannot poison physical-slot reuse
# ============================================================================
@cocotb.test()
async def test_partial_flush_dependency_row_cannot_poison_reused_slot(
    dut: Any,
) -> None:
    """A flushed row may stay blocked for one invalid cycle, never on reuse."""
    dut_if, _ = await setup(dut)

    from .lq_interface import AMOSWAP_W

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_empty(True)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)

    # Physical slot 0 survives the tag-0 partial-flush boundary. Slot 1 is a
    # pending AMO and slot 2 is its younger dependent load.
    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_alloc(
        rob_tag=1,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOSWAP_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_alloc(rob_tag=2, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    # Dependency rows are built in the cycle after allocation.
    await dut_if.step()
    assert int(dut.lq_valid.value) == 0b0000_0111, "Unexpected initial physical layout"
    assert int(dut.older_amo_block_q.value) == (1 << 2), (
        "Younger load did not capture its older-AMO dependency"
    )

    # Make only the dependent load address-ready. With an empty SQ it would be
    # immediately eligible except for its exact older-AMO dependency.
    dut_if.drive_addr_update(rob_tag=2, address=0xE100)
    await dut_if.step()
    dut_if.clear_addr_update()
    await Timer(1, unit="ns")
    assert not dut_if.read_sq_check()["valid"], "Blocked load entered SQ check"
    assert not dut_if.read_mem_request()["en"], "Blocked load reached memory"
    assert not dut_if.mem_outstanding, "Blocked load acquired response ownership"

    # This is not flush_all_entries: head=0 differs from flush_tag+1. The
    # surviving tag-0 row remains live, while tags 1 and 2 are invalidated.
    # Dependency maintenance is allowed to be conservative for this one dead
    # cycle, but the stale-high bit must have no architectural effect.
    dut_if.drive_partial_flush(flush_tag=0)
    await dut_if.step()
    dut_if.clear_partial_flush()
    assert int(dut.lq_valid.value) == 0b0000_0001, (
        "Partial flush retained a younger row"
    )
    assert dut_if.count == 1, f"Expected one retained entry, got {dut_if.count}"
    assert int(dut.older_amo_block_q.value) == (1 << 2), (
        "Partial flush cleared the dependency row on its own edge, not the next"
    )
    assert not dut_if.read_sq_check()["valid"], (
        "Invalid stale-high row entered SQ check"
    )
    assert not dut_if.read_mem_request()["en"], "Invalid stale-high row reached memory"
    assert not dut_if.read_fu_complete().valid, "Invalid stale-high row completed"
    assert not dut_if.mem_outstanding, (
        "Invalid stale-high row acquired response ownership"
    )

    # One complete invalid cycle must drain both the killed destination row and
    # killed AMO source column before either physical identity can be reused.
    await dut_if.step()
    assert int(dut.older_amo_block_q.value) == 0, (
        "Invalid-cycle dependency cleanup stalled"
    )

    # With the free-search cursor at slot 3, these occupy 3..7 and then slot 1,
    # leaving only the formerly dependent physical slot 2 free.
    for filler_tag in range(3, 9):
        dut_if.drive_alloc(rob_tag=filler_tag, size=MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()
    assert dut_if.count == 7, f"Expected seven live entries, got {dut_if.count}"
    assert int(dut.lq_valid.value) == 0xFB, "Allocator did not isolate physical slot 2"
    assert int(dut.older_amo_block_q.value) == 0, (
        "Filler allocation revived stale state"
    )

    dut_if.drive_alloc(rob_tag=9, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()
    assert dut_if.full, "Reusing the final physical slot did not fill the LQ"
    assert int(dut.lq_valid.value) == 0xFF, "Physical slot 2 was not reused"
    assert int(dut.older_amo_block_q.value) == 0, (
        "Reused slot inherited stale AMO state"
    )

    dut_if.drive_addr_update(rob_tag=9, address=0xE200)
    await dut_if.step()
    dut_if.clear_addr_update()
    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], "Reused slot retained a stale partial-flush AMO block"
    assert mem_req["addr"] == 0xE200, (
        f"Expected reused-slot load addr=0xE200, got 0x{mem_req['addr']:x}"
    )


# ============================================================================
# Test 35i: Earliest legal reuse drains the prior dependency generation
# ============================================================================
@cocotb.test()
async def test_dependency_row_drains_on_immediate_next_edge_slot_reuse(
    dut: Any,
) -> None:
    """The sole flushed hole may be reused next edge without stale AMO state."""
    dut_if, _ = await setup(dut)

    from .lq_interface import AMOSWAP_W

    # With ROB head 10 and flush boundary 20, tag 21 is the only younger tag.
    # Physical slot 0 holds its older AMO (tag 19), slot 1 the dependent load,
    # and slots 2..7 hold distinct entries older than the boundary.
    dut_if.drive_rob_head_tag(10)
    dut_if.drive_sq_empty(True)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    dut_if.drive_alloc(
        rob_tag=19,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOSWAP_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_alloc(rob_tag=21, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()
    for filler_tag in range(10, 16):
        dut_if.drive_alloc(rob_tag=filler_tag, size=MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    # Step once so the last allocation's dependency row is built. Eight
    # single-slot bundles also wrap the free-search cursor back to slot 0, so
    # slot 1 will be the first and only hole after the flush.
    await dut_if.step()
    assert int(dut.lq_valid.value) == 0xFF
    assert int(dut.older_amo_block_q.value) == (1 << 1), (
        "Physical slot 1 did not capture the older AMO"
    )

    dut_if.drive_partial_flush(flush_tag=20)
    await dut_if.step()
    dut_if.clear_partial_flush()
    assert dut_if.count == LQ_DEPTH - 1
    assert int(dut.lq_valid.value) == 0xFD, "Flush did not isolate physical slot 1"
    assert int(dut.older_amo_block_q.value) == (1 << 1), (
        "Expected one dead-cycle stale-high dependency"
    )

    # Reuse the sole hole immediately, with no idle cycle between. On this edge
    # the dependency logic sees !lq_valid[1] and clears the old row, while
    # allocation writes the new entry with no ready state.
    dut_if.drive_alloc(rob_tag=16, size=MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()
    assert dut_if.count == LQ_DEPTH
    assert int(dut.lq_valid.value) == 0xFF
    assert int(dut.older_amo_block_q.value) == 0
    assert (int(dut.lq_addr_valid.value) & (1 << 1)) == 0
    assert (int(dut.lq_issued.value) & (1 << 1)) == 0
    assert (int(dut.lq_data_valid.value) & (1 << 1)) == 0

    # Tag 16 is architecturally older than the still-pending tag-19 AMO, so its
    # rebuilt row remains clear. It must issue from reused slot 1.
    dut_if.drive_addr_update(rob_tag=16, address=0xE280)
    await dut_if.step()
    dut_if.clear_addr_update()
    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], "Immediate slot reuse retained a stale AMO block"
    assert mem_req["addr"] == 0xE280


# ============================================================================
# Test 36: AMO SWAP
# ============================================================================
@cocotb.test()
async def test_amo_swap(dut: Any) -> None:
    """AMOSWAP: read old value, write rs2, CDB gets old value."""
    dut_if, model = await setup(dut)

    from .lq_interface import AMOSWAP_W

    rs2_val = 0xCAFEBABE
    old_val = 0xDEADBEEF

    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0x7000, amo_rs2=rs2_val)
    model.addr_update(0, 0x7000, amo_rs2=rs2_val)
    await dut_if.step()
    dut_if.clear_addr_update()

    # Issue AMO (at head, sq committed empty)
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "AMO should issue memory read"
    await dut_if.step()

    # Memory response: old value
    dut_if.drive_mem_response(old_val)
    model.mem_response(old_val)
    await dut_if.step()
    dut_if.clear_mem_response()

    await advance_normal_amo_compute(dut_if)
    model.amo_compute_complete()

    # AMO write should fire (write rs2 to memory)
    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], "AMO write should be active"
    assert amo_write["addr"] == 0x7000, f"AMO write addr: {amo_write['addr']:#x}"
    assert amo_write["data"] == wbeat(rs2_val), f"AMOSWAP write: {amo_write['data']:#x}"

    dut_if.drive_amo_mem_write_done(True)
    model.amo_write_done()
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)

    # CDB should have old value after the staged completion registers it
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "CDB should be valid after AMO"
    assert result.tag == 0
    expected_old_value = sign_extend_to_xlen(old_val, 32)
    assert result.value == expected_old_value, (
        f"Expected 0x{expected_old_value:x}, got 0x{result.value:x}"
    )
    await accept_fu_complete(dut_if)


# ============================================================================
# Test 37: AMO ADD
# ============================================================================
@cocotb.test()
async def test_amo_add(dut: Any) -> None:
    """AMOADD: write old+rs2 to memory, CDB gets old value."""
    dut_if, model = await setup(dut)

    from .lq_interface import AMOADD_W

    rs2_val = 100
    old_val = 200

    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOADD_W)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOADD_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0x8000, amo_rs2=rs2_val)
    model.addr_update(0, 0x8000, amo_rs2=rs2_val)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "AMOADD should issue memory read"
    await dut_if.step()

    dut_if.drive_mem_response(old_val)
    model.mem_response(old_val)
    await dut_if.step()
    dut_if.clear_mem_response()

    await advance_normal_amo_compute(dut_if)
    model.amo_compute_complete()

    # AMO write: old + rs2
    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], "AMO write should be active"
    expected_write = (old_val + rs2_val) & MASK32
    assert amo_write["data"] == wbeat(expected_write), (
        f"AMOADD should write beat {wbeat(expected_write):#x}, got {amo_write['data']:#x}"
    )

    dut_if.drive_amo_mem_write_done(True)
    model.amo_write_done()
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)

    # CDB gets old value after the staged completion registers it
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "CDB should be valid"
    assert result.value == old_val, f"Expected {old_val}, got {result.value}"
    await accept_fu_complete(dut_if)


# ============================================================================
# Test 37b: Slot-2-only AMO gets its compact kind from the delayed write
# ============================================================================
@cocotb.test()
async def test_slot2_only_amo_uses_compact_staged_kind(dut: Any) -> None:
    """A slot-2-only AMO uses its compact kind, written one cycle after allocation."""
    dut_if, model = await setup(dut)

    from .lq_interface import AMOADD_W

    # Allocate through slot 2 only, then send the address update as early as
    # possible. The delayed compact-kind write lands on the address-update
    # edge, before SQ-check phase 2 can launch the AMO read.
    rs2_val = 11
    old_val = 7
    dut_if.drive_alloc_2(
        rob_tag=0,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOADD_W,
    )
    model.alloc(0, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOADD_W)
    await dut_if.step()
    dut_if.clear_alloc_2()

    dut_if.drive_addr_update(rob_tag=0, address=0x8080, amo_rs2=rs2_val)
    model.addr_update(0, 0x8080, amo_rs2=rs2_val)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Slot-2-only AMO should issue its memory read"
    await dut_if.step()

    dut_if.drive_mem_response(old_val)
    model.mem_response(old_val)
    await dut_if.step()
    dut_if.clear_mem_response()

    await advance_normal_amo_compute(dut_if)
    model.amo_compute_complete()

    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], "Slot-2-only AMO write should be active"
    assert amo_write["addr"] == 0x8080
    assert amo_write["data"] == wbeat(old_val + rs2_val), (
        f"Expected compact AMOADD result beat {wbeat(old_val + rs2_val):#x}, "
        f"got {amo_write['data']:#x}"
    )
    assert amo_write["data"] != wbeat(rs2_val), (
        "AMO operation unexpectedly decoded as AMOSWAP"
    )

    dut_if.drive_amo_mem_write_done(True)
    model.amo_write_done()
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "Slot-2-only AMO should complete on the CDB"
    assert result.tag == 0
    assert result.value == old_val
    await accept_fu_complete(dut_if)


# ============================================================================
# Test 37c: Every compact AMO kind computes the right result
# ============================================================================
@cocotb.test()
async def test_all_compact_amo_kinds_preserve_arithmetic(dut: Any) -> None:
    """Check all nine compact AMO kinds, including signed and unsigned edge cases."""
    dut_if, _ = await setup(dut)

    from .lq_interface import (
        AMOADD_W,
        AMOAND_W,
        AMOMAXU_W,
        AMOMAX_W,
        AMOMINU_W,
        AMOMIN_W,
        AMOOR_W,
        AMOSWAP_W,
        AMOXOR_W,
    )

    cases = [
        ("AMOSWAP", AMOSWAP_W, 0xDEAD_BEEF, 0x1234_5678, 0x1234_5678),
        ("AMOADD-overflow", AMOADD_W, 0xFFFF_FFFE, 0x0000_0003, 0x0000_0001),
        ("AMOXOR", AMOXOR_W, 0xA5A5_0F0F, 0x0FF0_55AA, 0xAA55_5AA5),
        ("AMOAND", AMOAND_W, 0xF0F0_AA55, 0x0FF0_5A5A, 0x00F0_0A50),
        ("AMOOR", AMOOR_W, 0xF000_0055, 0x0F00_AA00, 0xFF00_AA55),
        (
            "AMOMIN-signed",
            AMOMIN_W,
            0x8000_0000,
            0x7FFF_FFFF,
            0x8000_0000,
        ),
        (
            "AMOMAX-signed",
            AMOMAX_W,
            0x8000_0000,
            0x7FFF_FFFF,
            0x7FFF_FFFF,
        ),
        (
            "AMOMINU-unsigned",
            AMOMINU_W,
            0xFFFF_FFFF,
            0x0000_0001,
            0x0000_0001,
        ),
        (
            "AMOMAXU-unsigned",
            AMOMAXU_W,
            0x8000_0000,
            0x7FFF_FFFF,
            0x8000_0000,
        ),
    ]

    for case_idx, (name, amo_op, old_value, rs2_value, expected_write) in enumerate(
        cases
    ):
        rob_tag = case_idx
        address = 0x9000 + case_idx * 4

        dut_if.drive_alloc(
            rob_tag=rob_tag,
            size=MEM_SIZE_WORD,
            is_amo=True,
            amo_op=amo_op,
        )
        await dut_if.step()
        dut_if.clear_alloc()

        dut_if.drive_addr_update(
            rob_tag=rob_tag,
            address=address,
            amo_rs2=rs2_value,
        )
        await dut_if.step()
        dut_if.clear_addr_update()

        await complete_prepared_amo(
            dut_if,
            rob_tag=rob_tag,
            address=address,
            old_value=old_value,
            expected_write=expected_write,
            description=name,
            is_minmax=amo_op in (AMOMIN_W, AMOMAX_W, AMOMINU_W, AMOMAXU_W),
        )


# ============================================================================
# Test 37d: MIN/MAX width, equality, and write stalls
# ============================================================================
@cocotb.test()
async def test_amo_minmax_relation_split_width_equality_and_stall(dut: Any) -> None:
    """Check every MIN/MAX kind, W/D extrema and equality, and active stalls."""
    dut_if, _ = await setup(dut)

    from .lq_interface import (
        AMOMAXU_D,
        AMOMAXU_W,
        AMOMAX_D,
        AMOMAX_W,
        AMOMINU_D,
        AMOMINU_W,
        AMOMIN_D,
        AMOMIN_W,
    )

    # Hostile RV64 upper halves catch an accidental XLEN-wide implementation
    # of AMO*.W.
    upper_ones = 0xFFFF_FFFF_0000_0000
    word_cases = [
        (
            "AMOMIN.W signed extrema selects old",
            AMOMIN_W,
            0x8000_0000,
            upper_ones | 0x7FFF_FFFF,
            0x8000_0000,
        ),
        (
            "AMOMIN.W signed extrema selects rs2",
            AMOMIN_W,
            0x7FFF_FFFF,
            0x0000_0000_8000_0000,
            0x8000_0000,
        ),
        (
            "AMOMAX.W signed extrema selects rs2",
            AMOMAX_W,
            0x8000_0000,
            upper_ones | 0x7FFF_FFFF,
            0x7FFF_FFFF,
        ),
        (
            "AMOMAX.W signed extrema selects old",
            AMOMAX_W,
            0x7FFF_FFFF,
            0x0000_0000_8000_0000,
            0x7FFF_FFFF,
        ),
        (
            "AMOMINU.W unsigned extrema selects old",
            AMOMINU_W,
            0x0000_0000,
            0xFFFF_FFFF,
            0x0000_0000,
        ),
        (
            "AMOMINU.W unsigned extrema selects rs2",
            AMOMINU_W,
            0xFFFF_FFFF,
            upper_ones,
            0x0000_0000,
        ),
        (
            "AMOMAXU.W unsigned extrema selects rs2",
            AMOMAXU_W,
            0x0000_0000,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
        ),
        (
            "AMOMAXU.W unsigned extrema selects old",
            AMOMAXU_W,
            0xFFFF_FFFF,
            upper_ones,
            0xFFFF_FFFF,
        ),
        (
            "AMOMIN.W equality ignores hostile rs2 upper half",
            AMOMIN_W,
            0x8000_0001,
            0x0123_4567_8000_0001,
            0x8000_0001,
        ),
        (
            "AMOMAX.W equality ignores hostile rs2 upper half",
            AMOMAX_W,
            0x8000_0001,
            0x89AB_CDEF_8000_0001,
            0x8000_0001,
        ),
        (
            "AMOMINU.W equality ignores hostile rs2 upper half",
            AMOMINU_W,
            0x8000_0001,
            0x0000_0000_8000_0001,
            0x8000_0001,
        ),
        (
            "AMOMAXU.W equality ignores hostile rs2 upper half",
            AMOMAXU_W,
            0x8000_0001,
            0xDEAD_BEEF_8000_0001,
            0x8000_0001,
        ),
    ]

    cases = [
        (name, MEM_SIZE_WORD, amo_op, old_value, rs2_value, expected_write)
        for name, amo_op, old_value, rs2_value, expected_write in word_cases
    ]
    dword_cases = [
        (
            "AMOMIN.D signed extrema selects old",
            AMOMIN_D,
            0x8000_0000_0000_0000,
            0x7FFF_FFFF_FFFF_FFFF,
            0x8000_0000_0000_0000,
        ),
        (
            "AMOMIN.D signed extrema selects rs2",
            AMOMIN_D,
            0x7FFF_FFFF_FFFF_FFFF,
            0x8000_0000_0000_0000,
            0x8000_0000_0000_0000,
        ),
        (
            "AMOMAX.D signed extrema selects rs2",
            AMOMAX_D,
            0x8000_0000_0000_0000,
            0x7FFF_FFFF_FFFF_FFFF,
            0x7FFF_FFFF_FFFF_FFFF,
        ),
        (
            "AMOMAX.D signed extrema selects old",
            AMOMAX_D,
            0x7FFF_FFFF_FFFF_FFFF,
            0x8000_0000_0000_0000,
            0x7FFF_FFFF_FFFF_FFFF,
        ),
        (
            "AMOMINU.D unsigned extrema selects old",
            AMOMINU_D,
            0x0000_0000_0000_0000,
            0xFFFF_FFFF_FFFF_FFFF,
            0x0000_0000_0000_0000,
        ),
        (
            "AMOMINU.D unsigned extrema selects rs2",
            AMOMINU_D,
            0xFFFF_FFFF_FFFF_FFFF,
            0x0000_0000_0000_0000,
            0x0000_0000_0000_0000,
        ),
        (
            "AMOMAXU.D unsigned extrema selects rs2",
            AMOMAXU_D,
            0x0000_0000_0000_0000,
            0xFFFF_FFFF_FFFF_FFFF,
            0xFFFF_FFFF_FFFF_FFFF,
        ),
        (
            "AMOMAXU.D unsigned extrema selects old",
            AMOMAXU_D,
            0xFFFF_FFFF_FFFF_FFFF,
            0x0000_0000_0000_0000,
            0xFFFF_FFFF_FFFF_FFFF,
        ),
        (
            "AMOMIN.D equality selects the same value",
            AMOMIN_D,
            0x8000_0000_0000_0001,
            0x8000_0000_0000_0001,
            0x8000_0000_0000_0001,
        ),
        (
            "AMOMAX.D equality selects the same value",
            AMOMAX_D,
            0x7FFF_FFFF_FFFF_FFFE,
            0x7FFF_FFFF_FFFF_FFFE,
            0x7FFF_FFFF_FFFF_FFFE,
        ),
        (
            "AMOMINU.D equality selects the same value",
            AMOMINU_D,
            0x0123_4567_89AB_CDEF,
            0x0123_4567_89AB_CDEF,
            0x0123_4567_89AB_CDEF,
        ),
        (
            "AMOMAXU.D equality selects the same value",
            AMOMAXU_D,
            0xFEDC_BA98_7654_3210,
            0xFEDC_BA98_7654_3210,
            0xFEDC_BA98_7654_3210,
        ),
    ]
    cases.extend(
        (name, MEM_SIZE_DOUBLE, amo_op, old_value, rs2_value, expected_write)
        for name, amo_op, old_value, rs2_value, expected_write in dword_cases
    )

    for case_idx, (
        name,
        size,
        amo_op,
        old_value,
        rs2_value,
        expected_write,
    ) in enumerate(cases):
        rob_tag = case_idx
        address = 0xC000 + case_idx * 16
        if size == MEM_SIZE_WORD and (case_idx & 1):
            address += 4

        dut_if.drive_alloc(
            rob_tag=rob_tag,
            size=size,
            is_amo=True,
            amo_op=amo_op,
        )
        await dut_if.step()
        dut_if.clear_alloc()

        dut_if.drive_addr_update(
            rob_tag=rob_tag,
            address=address,
            amo_rs2=rs2_value,
        )
        await dut_if.step()
        dut_if.clear_addr_update()

        await complete_prepared_amo(
            dut_if,
            rob_tag=rob_tag,
            address=address,
            old_value=old_value,
            expected_write=expected_write,
            description=name,
            size=size,
            stall_cycles=3,
            is_minmax=True,
            expect_equal_relation=(
                (old_value & (MASK64 if size == MEM_SIZE_DOUBLE else MASK32))
                == (rs2_value & (MASK64 if size == MEM_SIZE_DOUBLE else MASK32))
            ),
        )


# ============================================================================
# Test 37e: Simultaneous dual AMO allocations retain distinct compact kinds
# ============================================================================
@cocotb.test()
async def test_dual_allocated_amos_keep_distinct_compact_kinds(dut: Any) -> None:
    """Both staged allocation ports preserve their own index and AMO kind."""
    dut_if, _ = await setup(dut)

    from .lq_interface import AMOADD_W, AMOXOR_W

    # Both requests are accepted on one edge and must drain to different
    # physical entries on the next edge. Distinguishable operations catch
    # swapped indices, swapped staging bits, and one port overwriting the other.
    dut_if.drive_alloc(
        rob_tag=0,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOADD_W,
    )
    dut_if.drive_alloc_2(
        rob_tag=1,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOXOR_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.clear_alloc_2()

    dut_if.drive_addr_update(rob_tag=0, address=0xA000, amo_rs2=7)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.drive_addr_update(rob_tag=1, address=0xA004, amo_rs2=0xAA)
    await dut_if.step()
    dut_if.clear_addr_update()

    await complete_prepared_amo(
        dut_if,
        rob_tag=0,
        address=0xA000,
        old_value=5,
        expected_write=12,
        description="dual slot-1 AMOADD",
    )
    await complete_prepared_amo(
        dut_if,
        rob_tag=1,
        address=0xA004,
        old_value=0xF0,
        expected_write=0x5A,
        description="dual slot-2 AMOXOR",
    )


# ============================================================================
# Test 37f: Rejected slot-2 AMO cannot overwrite an accepted slot-1 AMO
# ============================================================================
@cocotb.test()
async def test_rejected_slot2_amo_cannot_overwrite_slot1_kind(dut: Any) -> None:
    """A full-for-2 rejection cannot drain through an aliased staging index."""
    dut_if, _ = await setup(dut)

    from .lq_interface import AMOADD_W, AMOXOR_W

    # Leave exactly one free physical entry. The second-free encoder has no
    # valid result in this state, so its unused candidate index aliases the
    # first target. Slot 1 must be accepted and slot 2 rejected.
    for rob_tag in range(1, LQ_DEPTH):
        dut_if.drive_alloc(rob_tag=rob_tag, size=MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    # tail_ptr advances one cycle after each allocation bundle. Step once more
    # so it points at the sole free entry, where the missing second target
    # also points.
    await dut_if.step()

    assert dut_if.count == LQ_DEPTH - 1
    assert dut_if.full_for_2, "Expected capacity for only one allocation"

    dut_if.drive_alloc(
        rob_tag=0,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOADD_W,
    )
    dut_if.drive_alloc_2(
        rob_tag=LQ_DEPTH,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOXOR_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.clear_alloc_2()

    assert dut_if.count == LQ_DEPTH, "Slot 1 should consume the final free entry"
    assert dut_if.full

    dut_if.drive_addr_update(rob_tag=0, address=0xA100, amo_rs2=7)
    await dut_if.step()
    dut_if.clear_addr_update()

    # AMOADD(5, 7) is 12; the rejected AMOXOR payload would instead produce 2.
    await complete_prepared_amo(
        dut_if,
        rob_tag=0,
        address=0xA100,
        old_value=5,
        expected_write=12,
        description="slot-1 AMO with rejected aliased slot-2 candidate",
    )


# ============================================================================
# Test 37g: Full/partial flush followed by physical-entry reuse
# ============================================================================
@cocotb.test()
async def test_amo_kind_staging_survives_flush_and_entry_reuse(dut: Any) -> None:
    """Canceled or stale staged writes cannot poison a reused physical entry."""
    dut_if, _ = await setup(dut)

    from .lq_interface import AMOADD_W, AMOOR_W, AMOSWAP_W, AMOXOR_W

    # Full flush cancels a still-pending slot-1 kind write and resets the
    # allocator, so the replacement immediately reuses physical entry zero.
    dut_if.drive_alloc(
        rob_tag=2,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOSWAP_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()
    assert dut_if.empty, "Full flush did not invalidate the canceled AMO"

    dut_if.drive_alloc(
        rob_tag=0,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOOR_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_addr_update(rob_tag=0, address=0xB000, amo_rs2=0x0F)
    await dut_if.step()
    dut_if.clear_addr_update()
    await complete_prepared_amo(
        dut_if,
        rob_tag=0,
        address=0xB000,
        old_value=0x50,
        expected_write=0x5F,
        description="full-flush reused AMOOR",
    )

    # Start the partial-flush case from physical entry zero. Unlike full flush,
    # a partial flush lets the pending data-only write drain.
    await dut_if.reset_dut()
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_alloc(
        rob_tag=2,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOADD_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_partial_flush(flush_tag=1)
    await dut_if.step()
    dut_if.clear_partial_flush()
    assert dut_if.empty, "Partial flush did not invalidate the younger AMO"

    # Partial flush leaves tail_ptr unchanged. Seven non-AMO fillers consume
    # entries 1..7, forcing the replacement AMO to wrap and reuse entry zero,
    # whose stale compact kind is AMOADD.
    for filler_tag in range(8, 15):
        dut_if.drive_alloc(rob_tag=filler_tag, size=MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()
    assert dut_if.count == 7, f"Expected seven fillers, got {dut_if.count}"

    dut_if.drive_alloc(
        rob_tag=0,
        size=MEM_SIZE_WORD,
        is_amo=True,
        amo_op=AMOXOR_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    assert dut_if.full, "Replacement AMO did not wrap into the final free entry"

    dut_if.drive_addr_update(rob_tag=0, address=0xB100, amo_rs2=0x03)
    await dut_if.step()
    dut_if.clear_addr_update()
    await complete_prepared_amo(
        dut_if,
        rob_tag=0,
        address=0xB100,
        old_value=0x0F,
        expected_write=0x0C,
        description="partial-flush reused AMOXOR",
    )


# ============================================================================
# Test 38: AMO write completion invalidates L0 cache
# ============================================================================
@cocotb.test()
async def test_amo_write_invalidates_l0_cache(dut: Any) -> None:
    """After AMO write completes, L0 cache at that address is invalidated.

    Flow:
      1. Regular LW at addr fills L0 cache.
      2. Free that entry via CDB.
      3. AMOSWAP at same addr: read, write, complete.
      4. New LW at same addr should miss L0 (go to memory), proving invalidation.
    """
    dut_if, model = await setup(dut)

    from .lq_interface import AMOSWAP_W

    addr = 0x2000
    orig_data = 0xAAAA_BBBB
    amo_rs2 = 0x1111_2222

    # --- Step 1: regular LW to fill L0 cache ---
    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD)
    model.alloc(0, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=addr)
    model.addr_update(0, addr)
    await dut_if.step()
    dut_if.clear_addr_update()

    # Issue to memory (SQ says no match)
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "LW should issue to memory"
    await dut_if.step()

    # Memory response fills L0 cache
    dut_if.drive_mem_response(orig_data)
    model.mem_response(orig_data)
    await dut_if.step()
    dut_if.clear_mem_response()

    # Accept the staged LW completion
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "CDB should broadcast LW result"
    await accept_fu_complete(dut_if)

    # --- Step 2: AMOSWAP at same address ---
    dut_if.drive_alloc(rob_tag=1, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(1, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=1, address=addr, amo_rs2=amo_rs2)
    model.addr_update(1, addr, amo_rs2=amo_rs2)
    await dut_if.step()
    dut_if.clear_addr_update()

    # Issue AMO
    dut_if.drive_rob_head_tag(1)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "AMO should issue memory read"
    await dut_if.step()

    # Memory response for AMO read
    dut_if.drive_mem_response(orig_data)
    model.mem_response(orig_data)
    await dut_if.step()
    dut_if.clear_mem_response()

    await advance_normal_amo_compute(dut_if)
    model.amo_compute_complete()

    # AMO write phase
    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], "AMO write should be active"

    # AMO write done invalidates the L0 line at addr
    dut_if.drive_amo_mem_write_done(True)
    model.amo_write_done()
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)

    # Accept the staged AMO completion
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "CDB should broadcast AMO result"
    await accept_fu_complete(dut_if)

    # --- Step 3: new LW at same address must miss the L0 cache ---
    dut_if.drive_alloc(rob_tag=2, size=MEM_SIZE_WORD)
    model.alloc(2, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=2, address=addr)
    model.addr_update(2, addr)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(2)

    # With the L0 line invalidated, this load issues to memory instead of
    # taking the fast path
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "LW after AMO should miss L0 cache and issue to memory"


# ============================================================================
# Test: ROB-head MMIO load preempts a younger fenced staging-slot hog
# ============================================================================
@cocotb.test()
async def test_head_mmio_preempts_younger_fenced_hog(dut: Any) -> None:
    """ROB-head MMIO load issues despite younger loads monopolizing the slot.

    Three loads, ring order = physical slot order (head_ptr=0):
      slot 0 hog   (age 4): staged first, then held by an older store that
                            overlaps it but cannot forward (match=1,
                            can_forward=0), so it keeps the staging slot.
      slot 1 block (age 8): younger than hog, so it is the first eligible
                            stored-scan pick once hog is staged. Being
                            younger than the staged hog it cannot replace it
                            (sq_check_replace needs an older candidate), so
                            the scan stops here and never reaches the head.
      slot 2 head  (age 0): the ROB-head MMIO load, after block in ring order.
    Normal eligibility includes the head MMIO load in slot 2, but the ring
    encoder still selects the earlier candidate in slot 1. The ROB-head path
    must override that winner, after which sq_check_replace evicts the hog
    (age 4 > head age 0).
    """
    dut_if, model = await setup(dut)

    head_tag = 2  # oldest (ROB head): the MMIO load, age 0
    hog_tag = 6  # age 4: staged first, then held by the SQ match
    block_tag = 10  # age 8: younger than hog, parks the ring-order scan
    mmio_addr = 0x4000_0000  # UART region -> is_mmio

    # Allocation order == physical slot order (ring order from head_ptr=0):
    # hog -> slot 0, block -> slot 1, head -> slot 2.
    await alloc_and_addr(dut_if, model, rob_tag=hog_tag, address=0x5000)
    await alloc_and_addr(dut_if, model, rob_tag=block_tag, address=0x6000)
    await alloc_and_addr(
        dut_if, model, rob_tag=head_tag, address=mmio_addr, is_mmio=True
    )

    # The MMIO load is the ROB head. i_sq_empty stays 0 (reset default) so a
    # match/no-forward response fences the staged hog.
    dut_if.drive_rob_head_tag(head_tag)

    head_issued = False
    for _ in range(80):
        # Fence the staging slot only while the hog holds it. The head MMIO
        # load is oldest, has no older store, and issues.
        sq_check = dut_if.read_sq_check()
        dut_if.drive_sq_all_older_known(True)
        if sq_check["valid"] and sq_check["rob_tag"] == hog_tag:
            dut_if.drive_sq_forward(match=True, can_forward=False)
        else:
            dut_if.drive_sq_forward(match=False, can_forward=False)

        await Timer(1, unit="ns")
        mem_req = dut_if.read_mem_request()
        if mem_req["en"] and mem_req["addr"] == mmio_addr:
            head_issued = True
            break
        await dut_if.step()

    assert head_issued, (
        "ROB-head MMIO load never issued: it was starved behind younger loads "
        "monopolizing the sq_check staging slot / stored-scan candidate "
        "(head-priority MMIO preemption missing from head_mem_stored)"
    )


# ============================================================================
# Overlapped cached-tier loads (one slot each)
# ============================================================================
async def _launch_cached(
    dut_if: LQInterface, model: LQModel, rob_tag: int, address: int
) -> dict[str, int | bool]:
    """Allocate, resolve and launch one cached-tier load; return its launch."""
    await alloc_and_addr(dut_if, model, rob_tag=rob_tag, address=address)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], f"cached load tag {rob_tag} did not launch"
    assert mem_req["addr"] == address
    await dut_if.step()
    return mem_req


@cocotb.test()
async def test_two_cached_loads_overlap_and_complete_out_of_order(dut: Any) -> None:
    """Two cached loads launch back to back; the younger answers first."""
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_empty(True)
    dut_if.drive_mem_request_pending(False)

    first = await _launch_cached(dut_if, model, rob_tag=1, address=0x8000_1000)
    second = await _launch_cached(dut_if, model, rob_tag=2, address=0x8000_2000)
    assert first["id"] != second["id"], "both loads took the same cached slot"

    # The younger load's response lands first and completes it.
    dut_if.drive_mem_response(0x2222_2222, cached=True, slot=int(second["id"]))
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 2 and result.value == 0x2222_2222
    await accept_fu_complete(dut_if)

    dut_if.drive_mem_response(0x1111_1111, cached=True, slot=int(first["id"]))
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 1 and result.value == 0x1111_1111
    await accept_fu_complete(dut_if)
    await dut_if.step()
    assert dut_if.empty


@cocotb.test()
async def test_partial_flush_kills_only_the_younger_cached_slot(dut: Any) -> None:
    """A partial flush drains the younger slot's response and keeps the older one."""
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_empty(True)
    dut_if.drive_mem_request_pending(False)

    older = await _launch_cached(dut_if, model, rob_tag=1, address=0x8000_1100)
    younger = await _launch_cached(dut_if, model, rob_tag=6, address=0x8000_2200)

    # Flush everything younger than tag 3: tag 6 dies, tag 1 survives.
    dut_if.drive_partial_flush(flush_tag=3, early_recovery=True)
    await dut_if.step()
    dut_if.clear_partial_flush()
    await dut_if.step()

    # The dead slot's response is drained without a completion.
    dut_if.drive_mem_response(0x6666_6666, cached=True, slot=int(younger["id"]))
    await Timer(1, unit="ns")
    assert not dut_if.read_fu_complete().valid
    await dut_if.step()
    dut_if.clear_mem_response()
    assert not (await wait_for_fu_complete(dut_if, max_cycles=2)).valid

    # The survivor completes normally.
    dut_if.drive_mem_response(0x1234_5678, cached=True, slot=int(older["id"]))
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 1 and result.value == 0x1234_5678
    await accept_fu_complete(dut_if)


@cocotb.test()
async def test_flush_cycle_cached_response_does_not_hide_fast_kill(dut: Any) -> None:
    """A cached response in a partial-flush cycle must not mask the fast load's kill.

    The flush kill of the fast-tier owner is evaluated from its own launch
    snapshot, not from the response-owner mux, which a same-cycle cached
    response switches to its slot. Otherwise the flushed fast load's response
    would not be marked for draining, and the stale data would complete it.
    """
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_empty(True)
    dut_if.drive_mem_request_pending(False)

    older = await _launch_cached(dut_if, model, rob_tag=1, address=0x8000_1100)

    # A younger fast-tier load launches and is left waiting for its response.
    await alloc_and_addr(dut_if, model, rob_tag=6, address=0x0000_1100)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    fast_req = await wait_for_mem_request(dut_if)
    assert fast_req["en"] and fast_req["addr"] == 0x0000_1100
    await dut_if.step()

    # Same cycle: flush everything younger than tag 3 (kills tag 6) while the
    # older cached slot answers.
    dut_if.drive_partial_flush(flush_tag=3, early_recovery=True)
    dut_if.drive_mem_response(0x1111_1111, cached=True, slot=int(older["id"]))
    await dut_if.step()
    dut_if.clear_partial_flush()
    dut_if.clear_mem_response()
    # The kill took effect on the fast owner: no live fast request, and its
    # stale response is owed a drain (the entry may be reallocated meanwhile).
    assert not bool(dut.mem_outstanding.value), (
        "flushed fast load still counted as outstanding"
    )
    assert bool(dut.drop_mem_response_pending.value), (
        "stale fast response drain not armed"
    )
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 1 and result.value == 0x1111_1111
    await accept_fu_complete(dut_if)

    # The flushed fast load's response lands later and must be drained.
    dut_if.drive_mem_response(0x6666_6666, cached=False)
    await Timer(1, unit="ns")
    assert not dut_if.read_fu_complete().valid, (
        "stale fast-tier response completed a flushed load"
    )
    await dut_if.step()
    dut_if.clear_mem_response()
    assert not (await wait_for_fu_complete(dut_if, max_cycles=3)).valid


@cocotb.test()
async def test_full_flush_frees_the_router_canceled_cached_slot(dut: Any) -> None:
    """A cached load still parked in the router at a full flush gives its slot back.

    The router cancels an unaccepted request on the full-flush pulse, so no
    response will ever arrive for it: the slot must be freed outright (a
    drop-marked slot would wait forever and leak one of the four credits).
    """
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_empty(True)
    dut_if.drive_mem_request_pending(False)

    parked = await _launch_cached(dut_if, model, rob_tag=1, address=0x8000_1500)
    # The router holds the request unaccepted (as when a write holds the port)
    # and reports it pending.
    dut_if.drive_mem_request_pending(True)
    await dut_if.step()
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()
    dut_if.drive_mem_request_pending(False)
    await dut_if.step()

    # Every slot is available again: four cached loads launch back to back and
    # the canceled request's slot is among them.
    ids = set()
    for k in range(4):
        launch = await _launch_cached(
            dut_if, model, rob_tag=k + 1, address=0x8000_6000 + k * 0x100
        )
        ids.add(int(launch["id"]))
    assert ids == {0, 1, 2, 3}, f"cached slots after the flush: {sorted(ids)}"
    assert int(parked["id"]) in ids


@cocotb.test()
async def test_held_cached_response_skips_one_launch(dut: Any) -> None:
    """The router's held-response flag blocks exactly the next launch.

    A cached response held behind a fast beat is registered into the launch
    hold: the cycle after the flag, no load launches, so back-to-back fast
    launches cannot starve the held response, and the launch resumes the
    cycle after that.
    """
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_empty(True)
    dut_if.drive_mem_request_pending(False)

    # Stage a ready cached load, but assert the held flag as it is about to go.
    await alloc_and_addr(dut_if, model, rob_tag=1, address=0x8000_1700)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_cached_resp_held(True)
    await dut_if.step()
    dut_if.drive_cached_resp_held(False)
    await Timer(1, unit="ns")
    assert not dut_if.read_mem_request()["en"], (
        "launch not skipped after a held response"
    )
    await dut_if.step()
    await Timer(1, unit="ns")
    req = dut_if.read_mem_request()
    assert req["en"] and req["addr"] == 0x8000_1700, (
        "launch did not resume after the hold"
    )


@cocotb.test()
async def test_store_invalidation_guards_only_the_hit_slot(dut: Any) -> None:
    """A store into one in-flight line suppresses that slot's L0 fill only."""
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_empty(True)
    dut_if.drive_mem_request_pending(False)

    hit = await _launch_cached(dut_if, model, rob_tag=1, address=0x8000_1300)
    clean = await _launch_cached(dut_if, model, rob_tag=2, address=0x8000_2300)

    # A store write hits the first load's dword while both loads are in flight.
    dut_if.drive_cache_invalidate(0x8000_1300)
    await dut_if.step()
    dut_if.clear_cache_invalidate()

    # The clean slot's response fills L0; the hit slot's response must not.
    dut_if.drive_mem_response(0xC1EA_0000, cached=True, slot=int(clean["id"]))
    await Timer(1, unit="ns")
    assert bool(dut.o_l0_fill.value), "unaffected slot's response did not fill L0"
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 2
    await accept_fu_complete(dut_if)

    dut_if.drive_mem_response(0x0BAD_0000, cached=True, slot=int(hit["id"]))
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_fill.value), "stale line filled L0 after a store hit it"
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 1 and result.value == 0x0BAD_0000
    await accept_fu_complete(dut_if)


@cocotb.test()
async def test_cached_slots_full_blocks_launch_until_a_response(dut: Any) -> None:
    """With every cached slot busy, the next load waits for a slot to free."""
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(1)
    dut_if.drive_sq_empty(True)
    dut_if.drive_mem_request_pending(False)

    launches = []
    for k in range(4):
        launches.append(
            await _launch_cached(
                dut_if, model, rob_tag=k + 1, address=0x8000_4000 + k * 0x100
            )
        )
    assert len({int(m["id"]) for m in launches}) == 4, "slot ids not distinct"

    await alloc_and_addr(dut_if, model, rob_tag=5, address=0x8000_5000)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    for cycle in range(4):
        await Timer(1, unit="ns")
        assert not dut_if.read_mem_request()["en"], (
            f"cycle {cycle}: launched with no free slot"
        )
        await dut_if.step()

    # Free one slot: the fifth load launches into it (before its completion
    # is even drained from the CDB stage).
    dut_if.drive_mem_response(0xAAAA_0000, cached=True, slot=int(launches[2]["id"]))
    await dut_if.step()
    dut_if.clear_mem_response()
    mem_req = await wait_for_mem_request(dut_if, max_cycles=6)
    assert mem_req["en"] and mem_req["addr"] == 0x8000_5000
    assert int(mem_req["id"]) == int(launches[2]["id"]), "freed slot was not reused"
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 3
    await accept_fu_complete(dut_if)


async def enter_normal_amo_compute(
    dut_if: LQInterface, *, address: int = 0x8000_0104, tag: int = 5
) -> None:
    """Accept a cached upper-word AMOADD response and stop in COMPUTE."""
    from .lq_interface import AMOADD_W

    dut_if.drive_alloc(rob_tag=tag, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOADD_W)
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_addr_update(rob_tag=tag, address=address, amo_rs2=3)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.drive_rob_head_tag(tag)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    request = await wait_for_mem_request(dut_if, max_cycles=8)
    assert request["en"] and request["addr"] == address
    await dut_if.step()
    dut_if.drive_mem_response(0xFFFF_FFFE_1234_5678, dword=True)
    await dut_if.step()
    dut_if.clear_mem_response()
    assert int(dut_if.dut.amo_state.value) == 2
    assert not dut_if.read_amo_mem_write()["en"]


@cocotb.test()
async def test_normal_amo_compute_widths_and_stalls(dut: Any) -> None:
    """Every normal AMO computes from its captured W or D operands, in either W lane."""
    dut_if, _ = await setup(dut)
    from . import lq_interface as ops

    functions = {
        "SWAP": lambda old, rs2: rs2,
        "ADD": lambda old, rs2: old + rs2,
        "XOR": lambda old, rs2: old ^ rs2,
        "AND": lambda old, rs2: old & rs2,
        "OR": lambda old, rs2: old | rs2,
    }
    tag = 0
    for kind, function in functions.items():
        for size, lane in (
            (MEM_SIZE_WORD, 0),
            (MEM_SIZE_WORD, 1),
            (MEM_SIZE_DOUBLE, 0),
        ):
            is_d = size == MEM_SIZE_DOUBLE
            old = 0xFFFF_FFFF_FFFF_FFFE if is_d else 0xFFFF_FFFE
            rs2 = 0x0123_4567_89AB_CDEF if kind != "ADD" else 3
            mask = MASK64 if is_d else MASK32
            address = 0xA000 + tag * 16 + lane * 4
            response = (
                old
                if is_d
                else ((old << 32) | 0x1234_5678 if lane else (0x1234_5678 << 32) | old)
            )
            dut_if.drive_alloc(
                rob_tag=tag,
                size=size,
                is_amo=True,
                amo_op=getattr(ops, f"AMO{kind}_{'D' if is_d else 'W'}"),
            )
            await dut_if.step()
            dut_if.clear_alloc()
            dut_if.drive_addr_update(rob_tag=tag, address=address, amo_rs2=rs2)
            await dut_if.step()
            dut_if.clear_addr_update()
            await complete_prepared_amo(
                dut_if,
                rob_tag=tag,
                address=address,
                old_value=old,
                expected_write=function(old, rs2) & mask,
                size=size,
                description=f"{kind} size{size} lane{lane}",
                stall_cycles=3,
                response_beat=response,
            )
            tag += 1


@cocotb.test()
async def test_amo_compute_retains_coherence_and_ignores_premature_done(
    dut: Any,
) -> None:
    """An AMO in AMO_COMPUTE keeps DMA admission busy and cannot complete early.

    Its response slot is already free, so a repeated response and an early
    write-done must not change its result or retire it.
    """
    dut_if, _ = await setup(dut)
    address = 0x8000_0104
    dut.i_coh_query_addr.value = address
    await enter_normal_amo_compute(dut_if, address=address)
    assert int(dut.cs_valid.value) == 0, "Response slot should already be free"
    assert bool(dut.o_coh_query_busy.value), "Compute opened a DMA admission gap"
    assert not dut_if.read_fu_complete().valid
    assert not int(dut.lq_data_valid.value)
    assert not bool(dut.amo_cache_inv.value)
    assert not int(dut.dep_done_oh.value)

    # Repeat the already-consumed response with hostile data and an early done.
    # Neither has a live response/write owner, so neither may retire this AMO.
    dut_if.drive_mem_response(0x1111_2222_3333_4444, dword=True)
    dut_if.drive_amo_mem_write_done(True)
    await dut_if.step()
    dut_if.clear_mem_response()
    dut_if.drive_amo_mem_write_done(False)
    await Timer(1, unit="ns")
    write = dut_if.read_amo_mem_write()
    assert write["en"] and write["addr"] == address
    assert write["data"] == wbeat(1), "Compute used a newer response operand"
    assert not dut_if.read_fu_complete().valid
    assert not int(dut.lq_data_valid.value), "Premature done completed the AMO"
    assert bool(dut.o_coh_query_busy.value)
    for _ in range(3):
        await dut_if.step()
        assert dut_if.read_amo_mem_write() == write
        assert bool(dut.o_coh_query_busy.value)
    dut_if.drive_amo_mem_write_done(True)
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)
    result = await wait_for_fu_complete(dut_if, max_cycles=8)
    assert result.valid and result.tag == 5
    assert result.value == sign_extend_to_xlen(0xFFFF_FFFE, 32)
    await accept_fu_complete(dut_if)
    await dut_if.step()
    assert not bool(dut.o_coh_query_busy.value)


@cocotb.test()
async def test_amo_compute_canceled_before_write(dut: Any) -> None:
    """A full flush, reset, or killing partial flush cancels an AMO in AMO_COMPUTE.

    Write-done is also raised early, in the kill cycle.
    """
    dut_if, _ = await setup(dut)
    for kill in ("full", "reset", "partial", "partial_all"):
        await dut_if.reset_dut()
        await enter_normal_amo_compute(dut_if)
        dut_if.drive_amo_mem_write_done(True)
        if kill == "full":
            dut_if.drive_flush_all()
        elif kill == "reset":
            dut.i_rst_n.value = 0
        elif kill == "partial":
            # Exercise the LQ's own kill logic. In the core the AMO is at the
            # ROB head, so no partial flush reaches it.
            dut_if.drive_rob_head_tag(4)
            dut_if.drive_partial_flush(4, early_recovery=True)
        else:
            dut_if.drive_partial_flush(4)  # head 5 == flush_tag + 1: flush_all_entries
        await dut_if.step()
        dut_if.clear_flush_all()
        dut_if.clear_partial_flush()
        dut_if.drive_amo_mem_write_done(False)
        dut.i_rst_n.value = 1
        for _ in range(4):
            await Timer(1, unit="ns")
            assert not dut_if.read_amo_mem_write()["en"], f"{kill}: killed AMO wrote"
            assert not dut_if.read_fu_complete().valid, (
                f"{kill}: the killed AMO completed"
            )
            assert not bool(dut.amo_cache_inv.value)
            await dut_if.step()
        assert dut_if.empty


@cocotb.test()
async def test_amo_compute_survives_younger_partial_flush(dut: Any) -> None:
    """A partial flush of younger entries leaves an AMO in AMO_COMPUTE intact."""
    dut_if, _ = await setup(dut)
    await enter_normal_amo_compute(dut_if)
    dut_if.drive_partial_flush(6, early_recovery=True)
    await dut_if.step()
    dut_if.clear_partial_flush()
    write = dut_if.read_amo_mem_write()
    assert write["en"] and write["data"] == wbeat(1)
    dut_if.drive_amo_mem_write_done(True)
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)
    result = await wait_for_fu_complete(dut_if, max_cycles=8)
    assert result.valid and result.tag == 5
    await accept_fu_complete(dut_if)


@cocotb.test(skip=os.environ.get("FROST_TEST_PREPARE_LOAD_WHILE_BUSY", "1") != "1")
async def test_busy_port_prepares_load_without_probe_or_launch(dut: Any) -> None:
    """While the memory port is busy, a load may be staged but goes no further.

    It must not probe the SQ, complete from the L0, or launch until the port frees.
    """
    dut_if, model = await setup(dut)
    address = 0x1800
    dut_if.drive_mem_bus_busy(True)
    dut_if.drive_sq_empty(False)
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    await alloc_and_addr(dut_if, model, rob_tag=3, address=address)
    for _ in range(6):
        assert not dut_if.read_mem_request()["en"]
        assert not dut_if.read_sq_check()["valid"]
        assert not int(dut.o_sq_check_capture_valid.value)
        assert not dut_if.read_fu_complete().valid
        await dut_if.step()
    assert int(dut.sq_check_pending.value), "Busy port prevented inert load staging"
    assert int(dut.sq_check_addr_q.value) == address

    dut_if.drive_mem_bus_busy(False)
    await Timer(1, unit="ns")
    check = dut_if.read_sq_check()
    assert check["valid"] and check["addr"] == address
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await dut_if.step()
    request = dut_if.read_mem_request()
    assert request["en"] and request["addr"] == address
    await dut_if.step()
    dut_if.drive_mem_response(0x1234ABCD)
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.tag == 3 and result.value == 0x1234ABCD

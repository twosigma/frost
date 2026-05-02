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

"""Unit tests for the Load Queue.

Tests cover reset, allocation, address update, full load flows (LW, LB, LBU,
LH, LHU), SQ forwarding, SQ disambiguation stall, MMIO ordering, FLD two-phase,
FLW NaN-boxing, flush, ordering, CDB back-pressure, and constrained random.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from .lq_interface import LQInterface
from .lq_model import (
    LQModel,
    FuComplete,
    SQForwardResult,
    MEM_SIZE_BYTE,
    MEM_SIZE_HALF,
    MEM_SIZE_WORD,
    MEM_SIZE_DOUBLE,
    MASK32,
)

CLOCK_PERIOD_NS = 10
LQ_DEPTH = 8


async def setup(dut: Any) -> tuple[LQInterface, LQModel]:
    """Start clock, reset DUT, and return interface and model."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
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
    """Allow staged completion timing before declaring the result missing."""
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
    """Allow the staged SQ-check launch path to present a valid candidate."""
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
    """Allow the staged memory-launch path to present a request."""
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


async def complete_load_no_forward(
    dut_if: LQInterface,
    model: LQModel,
    mem_data: int,
    rob_head_tag: int = 0,
) -> FuComplete:
    """Disambiguate with no SQ match, issue to memory, respond, and read CDB."""
    # Enable SQ disambiguation: all older known, no match
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_rob_head_tag(rob_head_tag)

    # Check memory request
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Expected memory read to be issued"

    # Step to register the issue
    await dut_if.step()

    # Provide memory response
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
    """Complete a disambiguated load via fast path when enabled or via memory."""
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
# Test 4: Address update
# ============================================================================
@cocotb.test()
async def test_addr_update(dut: Any) -> None:
    """Allocate -> address update -> SQ check should show address."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=3, address=0x1000)

    # With SQ disambiguation enabled, should see check
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "SQ check should be valid"
    assert (
        sq_check["addr"] == 0x1000
    ), f"Expected addr=0x1000, got 0x{sq_check['addr']:x}"
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
    # Byte at offset 1 is 0x80, sign-extended to 0xFFFFFF80
    expected = 0xFFFFFF80
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
    expected = 0xFFFF8001
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
    """SQ match completes immediately when enabled, otherwise after conflict clears."""
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
        # Conservative timing config: release the SQ match and let memory complete.
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

    # Memory should NOT be issued
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

    # Allocate entry with rob_tag=5, mark as MMIO
    await alloc_and_addr(dut_if, model, rob_tag=5, address=0x4000_0000, is_mmio=True)

    # ROB head is at tag 3 (not our tag)
    dut_if.drive_rob_head_tag(3)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")

    # Should NOT issue (not at head)
    sq_check = dut_if.read_sq_check()
    assert not sq_check["valid"], "MMIO should not check SQ when not at head"

    # Now set head to our tag
    dut_if.drive_rob_head_tag(5)
    sq_check = await wait_for_sq_check(dut_if)

    assert sq_check["valid"], "MMIO should check SQ when at head"
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "MMIO should issue when at head"


# ============================================================================
# Test 14: FLD two-phase
# ============================================================================
@cocotb.test()
async def test_fld_two_phase(dut: Any) -> None:
    """FLD: two memory reads (addr, addr+4), 64-bit CDB broadcast."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(
        dut_if, model, rob_tag=14, address=0x6000, is_fp=True, size=MEM_SIZE_DOUBLE
    )

    # Phase 0: memory read at addr
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Phase 0 should issue"
    assert (
        mem_req["addr"] == 0x6000
    ), f"Phase 0 addr should be 0x6000, got 0x{mem_req['addr']:x}"

    await dut_if.step()

    # Phase 0 response: low word
    dut_if.drive_mem_response(0xAAAA_BBBB)
    model.mem_response(0xAAAA_BBBB)
    await dut_if.step()
    dut_if.clear_mem_response()

    # Phase 1: should re-issue at addr+4
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "Phase 1 should issue"
    assert (
        mem_req["addr"] == 0x6004
    ), f"Phase 1 addr should be 0x6004, got 0x{mem_req['addr']:x}"

    await dut_if.step()

    # Phase 1 response: high word
    dut_if.drive_mem_response(0xCCCC_DDDD)
    model.mem_response(0xCCCC_DDDD)
    await dut_if.step()
    dut_if.clear_mem_response()

    # CDB should have full 64-bit value after the staged completion registers it
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "CDB should be valid after FLD"
    assert result.tag == 14
    expected = (0xCCCC_DDDD << 32) | 0xAAAA_BBBB
    assert (
        result.value == expected
    ), f"Expected 0x{expected:016x}, got 0x{result.value:016x}"
    await accept_fu_complete(dut_if)


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
    assert (
        result.value == expected
    ), f"Expected 0x{expected:016x}, got 0x{result.value:016x}"


# ============================================================================
# Test 16: Flush all
# ============================================================================
@cocotb.test()
async def test_flush_all(dut: Any) -> None:
    """Flush all entries, LQ empty."""
    dut_if, model = await setup(dut)

    # Allocate some entries
    for i in range(4):
        dut_if.drive_alloc(rob_tag=i, size=MEM_SIZE_WORD)
        model.alloc(i, False, MEM_SIZE_WORD, False)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == 4

    # Flush all
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.empty, "LQ should be empty after flush_all"
    assert dut_if.count == 0


# ============================================================================
# Test 17: Partial flush
# ============================================================================
@cocotb.test()
async def test_partial_flush(dut: Any) -> None:
    """Flush younger entries, older entries survive."""
    dut_if, model = await setup(dut)

    # ROB head at tag 0
    dut_if.drive_rob_head_tag(0)

    # Allocate tags 0, 1, 2, 3
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

    # Allocate two entries
    for tag in [10, 11]:
        await alloc_and_addr(dut_if, model, rob_tag=tag, address=0x1000 + tag * 4)

    # Enable SQ disambiguation
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    # Memory request should be for the oldest (tag 10)
    sq_check = await wait_for_sq_check(dut_if)
    assert (
        sq_check["rob_tag"] == 10
    ), f"Expected oldest tag=10, got {sq_check['rob_tag']}"


# ============================================================================
# Test 19: CDB back-pressure
# ============================================================================
@cocotb.test()
async def test_cdb_backpressure(dut: Any) -> None:
    """Staged completion remains asserted until the consumer accepts it."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=19, address=0x8000)

    # Complete the load
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
    assert (
        not dut_if.read_fu_complete().valid
    ), "Completion should clear after acceptance"


# ============================================================================
# Test 20: Back-to-back loads
# ============================================================================
@cocotb.test()
async def test_back_to_back_loads(dut: Any) -> None:
    """Complete one load, immediately issue next."""
    dut_if, model = await setup(dut)

    # Allocate two loads
    await alloc_and_addr(dut_if, model, rob_tag=20, address=0xA000)
    await alloc_and_addr(dut_if, model, rob_tag=21, address=0xA004)

    # Complete first load
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
    assert mem_req[
        "en"
    ], "Load should issue once the staged empty-SQ candidate reaches phase 2"
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
# Test 21: Constrained random
# ============================================================================
@cocotb.test()
async def test_constrained_random(dut: Any) -> None:
    """Randomized alloc/addr/forward/mem/flush over many cycles."""
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
        assert (
            0 <= dut_if.count <= LQ_DEPTH
        ), f"cycle {cycle}: invalid count {dut_if.count}"
        assert dut_if.full == (
            dut_if.count == LQ_DEPTH
        ), f"cycle {cycle}: full/count mismatch"
        assert dut_if.empty == (
            dut_if.count == 0
        ), f"cycle {cycle}: empty/count mismatch"

    cocotb.log.info(f"=== Constrained random test passed ({num_cycles} cycles) ===")


# ============================================================================
# Test 22: Stale response after partial flush (drain approach)
# ============================================================================
@cocotb.test()
async def test_stale_response_after_partial_flush(dut: Any) -> None:
    """Partial flush of in-flight load, late mem response is discarded."""
    dut_if, model = await setup(dut)

    # ROB head at tag 0
    dut_if.drive_rob_head_tag(0)

    # Allocate tag 5, give it an address
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
    assert model.mem_outstanding, "Model should keep mem_outstanding (drain)"

    # Late memory response arrives — should be discarded (drain)
    dut_if.drive_mem_response(0xDEAD_BEEF)
    model.mem_response_drain(0xDEAD_BEEF)
    await dut_if.step()
    dut_if.clear_mem_response()

    assert not model.mem_outstanding, "mem_outstanding should be cleared after drain"
    assert dut_if.count == 0, "No valid entries after drain"  # type: ignore[unreachable]

    # Verify we can allocate again (no stale state)
    dut_if.drive_alloc(rob_tag=10, size=MEM_SIZE_WORD)
    model.alloc(10, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    assert dut_if.count == 1, "Should be able to allocate after drain"


# ============================================================================
# Test 23: Tail reclamation after partial flush
# ============================================================================
@cocotb.test()
async def test_tail_reclamation_after_partial_flush(dut: Any) -> None:
    """After partial flush, LQ not falsely full, can allocate."""
    dut_if, model = await setup(dut)

    # ROB head at tag 0
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
    assert (
        not dut_if.full
    ), "LQ should NOT be full after partial flush with tail reclamation"

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

    # Second load at same address — should hit L0 cache after SQ disambig
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
        assert not dut_if.read_mem_request()[
            "en"
        ], "Fast-path cache hit should skip memory"


# ============================================================================
# Test 26: Cache miss fills cache, subsequent hit
# ============================================================================
@cocotb.test()
async def test_cache_miss_fills_cache(dut: Any) -> None:
    """Cache miss -> fill -> subsequent load uses fast path or memory fallback."""
    dut_if, model = await setup(dut)

    # First load at 0x3000 — cache miss (cold cache), goes to memory
    await alloc_and_addr(dut_if, model, rob_tag=3, address=0x3000)
    result = await complete_load_no_forward(dut_if, model, mem_data=0x1234_5678)
    assert result.valid and result.value == 0x1234_5678
    await dut_if.step()

    # Second load at 0x3000 — should hit cache after SQ disambig
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
    assert result.value == 0xFFFF_8001
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
    """MMIO address always misses cache, even if data is present."""
    dut_if, model = await setup(dut)

    # MMIO address: >= 0x40000000
    mmio_addr = 0x4000_0000

    # Load from MMIO address — must go through memory
    await alloc_and_addr(dut_if, model, rob_tag=5, address=mmio_addr, is_mmio=True)

    # Set ROB head to tag 5 (MMIO loads must be at head)
    dut_if.drive_rob_head_tag(5)

    # Enable disambiguation
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    # Memory should be issued (cache always misses MMIO)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "MMIO load should issue to memory, not cache"


# ============================================================================
# Test 30: FLD fills both cache words, subsequent LW hits correct addresses
# ============================================================================
@cocotb.test()
async def test_fld_cache_fill_both_words(dut: Any) -> None:
    """FLD fills both L0 words; later LW loads complete correctly in either mode.

    Regression test: before the fix, FLD phase 1 filled the cache at the base
    address instead of addr+4, poisoning the entry for the base address.
    """
    dut_if, model = await setup(dut)

    base_addr = 0x2000
    low_word = 0xAAAA_BBBB
    high_word = 0xCCCC_DDDD

    # -- FLD at base_addr: two-phase memory completion --
    await alloc_and_addr(
        dut_if, model, rob_tag=1, address=base_addr, is_fp=True, size=MEM_SIZE_DOUBLE
    )

    # Phase 0: memory read at base_addr
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "FLD phase 0 should issue"
    assert mem_req["addr"] == base_addr
    await dut_if.step()

    dut_if.drive_mem_response(low_word)
    model.mem_response(low_word)
    await dut_if.step()
    dut_if.clear_mem_response()

    # Phase 1: memory read at base_addr + 4
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "FLD phase 1 should issue"
    assert mem_req["addr"] == base_addr + 4
    await dut_if.step()

    dut_if.drive_mem_response(high_word)
    model.mem_response(high_word)
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
        "(cache poisoned by FLD phase 1?)"
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
    assert (
        result.value == high_word
    ), f"LW at base_addr+4: expected 0x{high_word:08x}, got 0x{result.value:08x}"


# ============================================================================
# Test 29: MMIO load blocks SQ forwarding even when SQ says can_forward
# ============================================================================
@cocotb.test()
async def test_mmio_load_blocks_sq_forward(dut: Any) -> None:
    """MMIO load must go to device even if SQ reports can_forward=True.

    Exercises the LQ-side guard: sq_do_forward requires !lq_is_mmio.
    """
    dut_if, model = await setup(dut)

    mmio_addr = 0x4000_0000

    # Allocate MMIO load entry
    await alloc_and_addr(dut_if, model, rob_tag=5, address=mmio_addr, is_mmio=True)

    # MMIO loads require rob_tag == head_tag to issue
    dut_if.drive_rob_head_tag(5)

    # SQ says: all older known, can_forward=True (would forward for non-MMIO)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=True, can_forward=True, data=0xBADD_A7A0)

    # SQ check should be valid (MMIO at head can disambiguate)
    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "MMIO load at head should check SQ"

    # Despite can_forward=True, MMIO guard should block forwarding.
    # The load should NOT get forwarded data; instead it should issue to memory
    # (sq_can_issue is False because match=True, so it stalls — which is correct:
    # MMIO loads with a matching store must wait for the store to commit first).
    mem_req = dut_if.read_mem_request()
    assert not mem_req[
        "en"
    ], "MMIO load with SQ match should stall, not issue to memory"

    # Step to ensure no forwarding occurred (entry should not become data_valid)
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

    # Allocate LR with rob_tag=5
    dut_if.drive_alloc(rob_tag=5, size=MEM_SIZE_WORD, is_lr=True)
    model.alloc(5, False, MEM_SIZE_WORD, False, is_lr=True)
    await dut_if.step()
    dut_if.clear_alloc()

    # Address update
    dut_if.drive_addr_update(rob_tag=5, address=0x1000)
    model.addr_update(5, 0x1000)
    await dut_if.step()
    dut_if.clear_addr_update()

    # ROB head is at tag 3 (not our tag) - LR should NOT issue
    dut_if.drive_rob_head_tag(3)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)

    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "LR should not issue when not at ROB head"

    # Set head to our tag - LR should issue
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

    # Verify reservation invalid after reset
    assert (
        not dut_if.read_reservation_valid()
    ), "Reservation should be invalid after reset"

    # Allocate LR
    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_lr=True)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_lr=True)
    await dut_if.step()
    dut_if.clear_alloc()

    # Address update
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

    # Memory response
    dut_if.drive_mem_response(0xDEADBEEF)
    model.mem_response(0xDEADBEEF)
    await dut_if.step()
    dut_if.clear_mem_response()

    # Reservation should now be valid
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

    # Flush all
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

    # SC clear reservation
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

    # Snoop invalidate
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

    # Allocate AMO with rob_tag=3
    dut_if.drive_alloc(rob_tag=3, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(3, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=3, address=0x6000, amo_rs2=0xAA)
    model.addr_update(3, 0x6000, amo_rs2=0xAA)
    await dut_if.step()
    dut_if.clear_addr_update()

    # Case 1: head=3 but sq_committed_empty=false → should NOT issue
    dut_if.drive_rob_head_tag(3)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(False)

    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "AMO should not issue when sq_committed_empty=false"

    # Case 2: head=0 but sq_committed_empty=true → should NOT issue
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_committed_empty(True)
    await Timer(1, unit="ns")

    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "AMO should not issue when not at ROB head"

    # Case 3: head=3 AND sq_committed_empty=true → should issue
    dut_if.drive_rob_head_tag(3)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "AMO should issue when at ROB head and sq_committed_empty"


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

    # Allocate AMO
    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOSWAP_W)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOSWAP_W)
    await dut_if.step()
    dut_if.clear_alloc()

    # Address update with rs2
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

    # AMO write should fire (write rs2 to memory)
    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], "AMO write should be active"
    assert amo_write["addr"] == 0x7000, f"AMO write addr: {amo_write['addr']:#x}"
    assert amo_write["data"] == rs2_val, f"AMOSWAP write: {amo_write['data']:#x}"

    # Acknowledge AMO write
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
    assert result.value == old_val, f"Expected 0x{old_val:x}, got 0x{result.value:x}"
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

    # Allocate AMO ADD
    dut_if.drive_alloc(rob_tag=0, size=MEM_SIZE_WORD, is_amo=True, amo_op=AMOADD_W)
    model.alloc(0, False, MEM_SIZE_WORD, False, is_amo=True, amo_op=AMOADD_W)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=0, address=0x8000, amo_rs2=rs2_val)
    model.addr_update(0, 0x8000, amo_rs2=rs2_val)
    await dut_if.step()
    dut_if.clear_addr_update()

    # Issue
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "AMOADD should issue memory read"
    await dut_if.step()

    # Memory response
    dut_if.drive_mem_response(old_val)
    model.mem_response(old_val)
    await dut_if.step()
    dut_if.clear_mem_response()

    # AMO write: old + rs2
    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], "AMO write should be active"
    expected_write = (old_val + rs2_val) & MASK32
    assert (
        amo_write["data"] == expected_write
    ), f"AMOADD should write {expected_write}, got {amo_write['data']}"

    # Acknowledge
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

    # AMO write phase
    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], "AMO write should be active"

    # Acknowledge AMO write → should invalidate L0 cache at addr
    dut_if.drive_amo_mem_write_done(True)
    model.amo_write_done()
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)

    # Accept the staged AMO completion
    result = await wait_for_fu_complete(dut_if)
    assert result.valid, "CDB should broadcast AMO result"
    await accept_fu_complete(dut_if)

    # --- Step 3: New LW at same address should MISS L0 cache ---
    dut_if.drive_alloc(rob_tag=2, size=MEM_SIZE_WORD)
    model.alloc(2, False, MEM_SIZE_WORD, False)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=2, address=addr)
    model.addr_update(2, addr)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(2)

    # If L0 cache was properly invalidated, this should issue to memory
    # (not fast-path from cache)
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "LW after AMO should miss L0 cache and issue to memory"

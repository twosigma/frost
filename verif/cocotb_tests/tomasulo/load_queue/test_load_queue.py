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
LH, LHU), SQ forwarding, SQ disambiguation stall, MMIO ordering (ROB-head
and all-committed-store drain gating), single-beat FLD, FLW NaN-boxing,
flush, AMO dependency ordering, .W/.D MIN/MAX width and stall semantics,
CDB back-pressure, and constrained random.

Bus contract (docs/rv64/m1_data_tier.md): memory responses are aligned
64-bit beats; the LQ extracts by addr[2:0]. drive_mem_response replicates a
word across both beat lanes (correct at either addr[2]) unless dword=True.
"""

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
    """Word write data replicated across the 64-bit beat ({2{word}})."""
    word &= MASK32
    return (word << 32) | word


AMO_RESCUE_THRESHOLD = 16384


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
) -> None:
    """Issue one prepared AMO and check next-cycle writeback, stalls, and CDB."""
    is_dword = size == MEM_SIZE_DOUBLE
    dut_if.drive_rob_head_tag(rob_tag)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_sq_committed_empty(True)

    mem_req = await wait_for_mem_request(dut_if, max_cycles=8)
    assert mem_req["en"], f"{description}: AMO read did not issue"
    assert (
        mem_req["addr"] == address
    ), f"{description}: expected read address 0x{address:08x}, got 0x{mem_req['addr']:08x}"
    await dut_if.step()

    dut_if.drive_mem_response(old_value, dword=is_dword)
    await dut_if.step()
    dut_if.clear_mem_response()

    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], f"{description}: AMO write did not become active"
    assert (
        amo_write["addr"] == address
    ), f"{description}: expected write address 0x{address:08x}, got 0x{amo_write['addr']:08x}"
    assert amo_write["is_dword"] == is_dword, (
        f"{description}: expected is_dword={is_dword}, " f"got {amo_write['is_dword']}"
    )
    # .W rides the beat replicated ({2{result}}), with router word strobes
    # selecting the addressed half. .D writes the complete beat.
    expected_beat = (
        expected_write & MASK64
        if is_dword
        else ((expected_write & MASK32) << 32) | (expected_write & MASK32)
    )
    assert amo_write["data"] == expected_beat, (
        f"{description}: expected write beat 0x{expected_beat:016x}, "
        f"got 0x{amo_write['data']:016x}"
    )

    # With write_done withheld, the active request must hold exactly. This
    # checks that MIN/MAX depends only on response-captured predicate/operands,
    # not on live issued-entry state, and that the split added no pulse behavior.
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
    assert (
        result.tag == rob_tag
    ), f"{description}: expected CDB tag {rob_tag}, got {result.tag}"
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

    # Distinct dwords: with dword-granule L0 lines, a same-dword pair would
    # let the second load hit the line filled by the first response instead
    # of exercising the ordered memory-issue path this test locks.
    dut_if.drive_addr_update(rob_tag=10, address=0x1100)
    model.addr_update(10, 0x1100)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_addr_update(rob_tag=11, address=0x1108)
    model.addr_update(11, 0x1108)
    await dut_if.step()
    dut_if.clear_addr_update()

    first = await complete_load_no_forward(dut_if, model, mem_data=0xAAAA_0001)
    assert (
        first.valid and first.tag == 10
    ), f"Expected first completion tag=10, got {first}"
    assert first.value == 0xAAAA_0001

    second = await complete_load_no_forward(dut_if, model, mem_data=0xBBBB_0002)
    assert (
        second.valid and second.tag == 11
    ), f"Expected second completion tag=11, got {second}"
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
# Test 13b: MMIO load waits for all committed stores to drain
# ============================================================================
@cocotb.test()
async def test_mmio_load_waits_for_committed_store_drain(dut: Any) -> None:
    """MMIO load at ROB head waits until i_sq_committed_empty.

    Device read-after-write ordering: a committed MMIO store's effect exists
    only at the device until the SQ drains it, and address disambiguation
    cannot order aliased device registers (the SiFive CLINT window aliases
    the native timer registers at second addresses), so being at ROB head is
    not sufficient. The shared status conservatively waits for unrelated
    committed stores as well.
    """
    dut_if, model = await setup(dut)

    mmio_addr = 0x4000_0000

    # Allocate an MMIO load and bring it to ROB head
    await alloc_and_addr(dut_if, model, rob_tag=5, address=mmio_addr, is_mmio=True)
    dut_if.drive_rob_head_tag(5)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    # At least one committed store is pending drain.
    dut_if.drive_sq_committed_empty(False)

    # The entry may stage and precompute its side-effect-free SQ check, but it
    # must not launch to memory while any committed store is undrained.
    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "MMIO should precompute SQ state while the store drains"
    for cycle in range(6):
        assert dut_if.read_sq_check()[
            "valid"
        ], f"cycle {cycle}: held MMIO stopped refreshing its SQ probe"
        mem_req = dut_if.read_mem_request()
        assert not mem_req[
            "en"
        ], f"cycle {cycle}: MMIO load at head issued before committed-store drain"
        await dut_if.step()

    # Change the SQ result after phase 2 has already armed. When the committed
    # queue drains, the newly blocking match must win over the old no-match
    # snapshot at the LQ boundary; no stale probe result may leak a memory
    # request.
    dut_if.drive_sq_forward(match=True, can_forward=False)
    await dut_if.step()
    assert dut_if.read_sq_check()[
        "valid"
    ], "held MMIO stopped refreshing its SQ probe after the result changed"
    dut_if.drive_sq_committed_empty(True)
    for cycle in range(2):
        await Timer(1, unit="ns")
        assert dut_if.read_sq_check()[
            "valid"
        ], f"cycle {cycle}: blocked MMIO stopped refreshing its SQ probe"
        assert not dut_if.read_mem_request()[
            "en"
        ], f"cycle {cycle}: stale SQ no-match escaped after committed-store drain"
        await dut_if.step()

    # Once the live SQ result clears, the held head MMIO load must progress.
    dut_if.clear_sq_forward()
    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "MMIO should issue once committed stores drain"
    assert (
        mem_req["addr"] == mmio_addr
    ), f"Expected MMIO addr 0x{mmio_addr:08x}, got 0x{mem_req['addr']:08x}"


# ============================================================================
# Test 13c: Misaligned MMIO completion also waits for committed-store drain
# ============================================================================
@cocotb.test()
async def test_misaligned_mmio_waits_for_committed_store_drain(dut: Any) -> None:
    """A misaligned MMIO trap is held by the same final-effect drain gate."""
    dut_if, model = await setup(dut)

    mmio_addr = 0x4000_0002
    await alloc_and_addr(dut_if, model, rob_tag=6, address=mmio_addr, is_mmio=True)
    dut_if.drive_rob_head_tag(6)
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    dut_if.drive_trap_misaligned_accesses(True)
    dut_if.drive_sq_committed_empty(False)

    for cycle in range(6):
        await Timer(1, unit="ns")
        assert not dut_if.read_mem_request()[
            "en"
        ], f"cycle {cycle}: misaligned MMIO unexpectedly launched a memory read"
        assert (
            not dut_if.read_fu_complete().valid
        ), f"cycle {cycle}: misaligned MMIO completed before committed-store drain"
        await dut_if.step()

    dut_if.drive_sq_committed_empty(True)
    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    for cycle in range(6):
        assert not dut_if.read_mem_request()[
            "en"
        ], f"cycle {cycle}: misaligned MMIO launched a read as the drain gate opened"
        if result.valid:
            break
        await dut_if.step()
        result = dut_if.read_fu_complete()
    assert (
        result.valid
    ), "misaligned MMIO did not complete once committed stores drained"
    assert result.tag == 6
    assert result.exception, "misaligned MMIO completion must be exceptional"
    assert result.exc_cause == 4, "expected load-address-misaligned cause"
    assert result.value == mmio_addr, "faulting MMIO address must be carried as mtval"
    assert not dut_if.read_mem_request()[
        "en"
    ], "misaligned MMIO must not access the device"


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

    # Single issue: memory read at addr
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)

    mem_req = await wait_for_mem_request(dut_if)
    assert mem_req["en"], "FLD should issue"
    assert (
        mem_req["addr"] == 0x6000
    ), f"FLD addr should be 0x6000, got 0x{mem_req['addr']:x}"

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
    assert (
        result.value == fld_beat
    ), f"Expected 0x{fld_beat:016x}, got 0x{result.value:016x}"
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
    assert not dut_if.mem_outstanding, "Killed response owner remained live after flush"
    assert model.mem_outstanding, "Model should keep mem_outstanding (drain)"

    # Late memory response arrives — should be discarded (drain)
    dut_if.drive_mem_response(0xDEAD_BEEF)
    model.mem_response_drain(0xDEAD_BEEF)
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_fill.value), "Late stale response refilled L0"
    assert (
        not dut_if.read_fu_complete().valid
    ), "Late stale response completed a killed load"
    await dut_if.step()
    dut_if.clear_mem_response()

    assert not dut_if.mem_outstanding
    assert not model.mem_outstanding, "mem_outstanding should be cleared after drain"
    assert dut_if.count == 0, "No valid entries after drain"  # type: ignore[unreachable]

    # Verify we can allocate again (no stale state)
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
    ordinary non-MMIO response remains a valid cache image.  Its speculative
    LQ owner must nevertheless be removed without producing an FU completion.
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
    assert bool(
        dut.o_l0_fill.value
    ), "Safe ordinary response did not fill L0 on the coincident partial flush"
    assert (
        not dut_if.read_fu_complete().valid
    ), "Killed load completed while its response was being drained"

    await dut_if.step()
    dut_if.clear_partial_flush()
    dut_if.clear_mem_response()
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()

    assert dut_if.empty, "Partial flush did not remove the response owner"
    assert dut_if.count == 0
    assert not (
        await wait_for_fu_complete(dut_if, max_cycles=2)
    ).valid, "Drained response produced a delayed FU completion"

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


@cocotb.test()
async def test_cache_hit_blocked_while_mem_bus_busy(dut: Any) -> None:
    """A warm L0 hit must wait while SQ/AMO owns the memory bus.

    Regression: a phase-2 SQ-checked load could complete from L0 while
    i_mem_bus_busy was high, one cycle before the matching store invalidation
    reached the cache.
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
    # candidate reaches phase 2 through the explicit SQ-check response path,
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
    assert (
        not dut_if.read_fu_complete().valid
    ), "Load completed from stale L0 during SQ write"
    assert not dut_if.read_mem_request()[
        "en"
    ], "Busy memory bus should block memory issue"

    await dut_if.step()
    assert not (await wait_for_fu_complete(dut_if, max_cycles=1)).valid

    dut_if.drive_mem_bus_busy(False)
    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()


@cocotb.test()
async def test_cache_hit_blocked_until_delayed_store_invalidation(dut: Any) -> None:
    """A warm L0 line must die at the store's write launch, never hit stale.

    Cached-tier stores keep their write in flight for cycles after the SQ write
    pulse drops; a younger same-address load must never consume the stale L0
    line in that gap (the window that exposed the parser failure on
    hardware).

    Contract: the SQ fires the L0 invalidate in the write LAUNCH cycle, so
    the line is dead before the flight even starts — the launch cycle
    itself is covered by i_mem_bus_busy plus the L0's same-cycle
    invalidate suppress. In the flight gap the load simply MISSES and may
    issue to memory; ordering the read behind the in-flight write is the
    router's job (test_load_queued_behind_cached_write_inflight).
    (Earlier designs blocked the gap in the LQ instead — first by
    stretching busy a trailing cycle, which taxed every BRAM store drain
    ~2% CoreMark, then via a routed busy term that broke timing closure.)
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

    # Capture another load to the same warm line through the explicit SQ-check
    # path so it models a younger load behind a draining store.
    dut_if.drive_sq_empty(False)
    await alloc_and_addr(dut_if, model, rob_tag=2, address=addr)

    sq_check = await wait_for_sq_check(dut_if)
    assert sq_check["valid"], "Expected LQ to present SQ check"
    assert sq_check["addr"] == addr

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await dut_if.step()

    # Store launch cycle: the memory port is busy AND the SQ fires the L0
    # invalidate for the written address in this same cycle. The warm line
    # must not hit (busy gate + same-cycle invalidate suppress).
    dut_if.drive_mem_bus_busy(True)
    dut_if.drive_cache_invalidate(addr)
    await Timer(1, unit="ns")
    assert not bool(
        dut.o_l0_hit.value
    ), "L0 fast path fired while SQ write owned the bus"
    assert (
        not dut_if.read_fu_complete().valid
    ), "Load completed from stale L0 during SQ write"
    assert not dut_if.read_mem_request()[
        "en"
    ], "Busy memory bus should block memory issue"
    await dut_if.step()
    dut_if.clear_cache_invalidate()

    # Cached-tier delayed-write gap: the write pulse (and busy) are gone while the
    # store is still in its write pipeline — but the line was already
    # invalidated at launch, so the load must MISS (no stale hit, no stale
    # completion). Issuing to memory here is fine: the router orders the
    # read behind the in-flight write.
    dut_if.drive_mem_bus_busy(False)
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_hit.value), (
        "L0 fast path fired in the write-flight gap despite the launch-time "
        "invalidation"
    )
    assert (
        not dut_if.read_fu_complete().valid
    ), "Load completed from stale L0 in the write-flight gap"
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
    assert (
        result.value == fresh_word
    ), f"Expected fresh value 0x{fresh_word:x}, got 0x{result.value:x}"

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()
    await accept_fu_complete(dut_if)


@cocotb.test()
async def test_cached_response_after_invalidate_does_not_refill_l0(dut: Any) -> None:
    """A delayed cached-tier response must not refill L0 after a same-word store.

    A multi-cycle cached-tier load can be older than a later committed store. If that
    store invalidates the L0 line before the load response returns, the response
    must still complete the older load but must not repopulate L0 with the
    pre-store word. Otherwise a still-younger load can hit stale data.
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

    # A younger store to the same word commits before the delayed cached response.
    dut_if.drive_cache_invalidate(addr)
    await dut_if.step()
    dut_if.clear_cache_invalidate()

    # The older load still completes with the pre-store value.
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

    assert not bool(
        dut.o_l0_hit.value
    ), "Stale cached response refilled L0 after invalidation"
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
# Test 35b: ROB-head AMO ignores a physically earlier younger AMO
# ============================================================================
@cocotb.test()
async def test_head_amo_ignores_physically_earlier_younger_amo(dut: Any) -> None:
    """Physical queue order does not make a younger AMO block the ROB-head AMO."""
    dut_if, model = await setup(dut)

    from .lq_interface import AMOSWAP_W

    # Physical order: younger pending AMO, then the true ROB-head AMO. Exact
    # ROB-age dependency rows must not mistake that physical order for age, so
    # the head AMO remains eligible.
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
    assert (
        mem_req["addr"] == 0x9004
    ), f"Expected head AMO addr=0x9004, got 0x{mem_req['addr']:x}"


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
    assert (
        mem_req["addr"] == 0xA008
    ), f"Expected head AMO addr=0xA008 (younger load fenced), got 0x{mem_req['addr']:x}"


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
    assert mem_req[
        "en"
    ], "Head AMO read should issue once the fenced load releases staging"
    assert (
        mem_req["addr"] == 0xB008
    ), f"Expected head AMO addr=0xB008 (fenced load evicted), got 0x{mem_req['addr']:x}"


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
        assert (
            not dut_if.mem_outstanding
        ), "Younger load launched after only one of two older AMOs completed"
        assert not dut_if.read_mem_request()[
            "en"
        ], "Younger load was released while the second older AMO was pending"
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
    # AMO 0 completes so it cannot launch before slot 0 is deliberately reused.
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
    assert (
        mem_req["addr"] == 0xD100
    ), f"Expected older load addr=0xD100, got 0x{mem_req['addr']:x}"


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
        assert (
            not dut_if.mem_outstanding
        ), "Slot-2 load launched through its simultaneous older slot-1 AMO"
        assert not dut_if.read_mem_request()[
            "en"
        ], "Slot-2 load did not capture the simultaneous slot-1 AMO dependency"
        await dut_if.step()


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
    assert amo_write["data"] == wbeat(rs2_val), f"AMOSWAP write: {amo_write['data']:#x}"

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
    expected_old_value = sign_extend_to_xlen(old_val, 32)
    assert (
        result.value == expected_old_value
    ), f"Expected 0x{expected_old_value:x}, got 0x{result.value:x}"
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
        amo_write["data"] == wbeat(expected_write)
    ), f"AMOADD should write beat {wbeat(expected_write):#x}, got {amo_write['data']:#x}"

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
# Test 37b: Slot-2-only AMO uses the compact staged operation kind
# ============================================================================
@cocotb.test()
async def test_slot2_only_amo_uses_compact_staged_kind(dut: Any) -> None:
    """A slot-2-only AMO uses its compact kind after one-cycle write staging."""
    dut_if, model = await setup(dut)

    from .lq_interface import AMOADD_W

    # Allocate through slot 2 only, then send the earliest normal address
    # update. The compact-kind request drains on this address-update edge,
    # before SQ-check phase 2 can launch the AMO read.
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

    await Timer(1, unit="ns")
    amo_write = dut_if.read_amo_mem_write()
    assert amo_write["en"], "Slot-2-only AMO write should be active"
    assert amo_write["addr"] == 0x8080
    assert amo_write["data"] == wbeat(old_val + rs2_val), (
        f"Expected compact AMOADD result beat {wbeat(old_val + rs2_val):#x}, "
        f"got {amo_write['data']:#x}"
    )
    assert amo_write["data"] != wbeat(
        rs2_val
    ), "AMO operation unexpectedly decoded as AMOSWAP"

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
# Test 37c: Every compact AMO kind preserves the original arithmetic
# ============================================================================
@cocotb.test()
async def test_all_compact_amo_kinds_preserve_arithmetic(dut: Any) -> None:
    """Exercise all nine compact kinds, including signed/unsigned edge cases."""
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
        )


# ============================================================================
# Test 37d: MIN/MAX predicate split preserves W/D width and stall semantics
# ============================================================================
@cocotb.test()
async def test_amo_minmax_predicate_split_width_extrema_and_stall(dut: Any) -> None:
    """Check every MIN/MAX kind, both choices, W/D extrema, and active stalls."""
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

    # Deliberately hostile RV64 upper halves catch an accidental XLEN-wide
    # implementation of AMO*.W.
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

    # The tail update is intentionally deferred until the prior allocation's
    # physical-generation pulse drains. Advance once more so tail points at the
    # sole free entry and the missing second target defaults to that same index.
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
    # a partial flush deliberately lets the pending data-only write drain.
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


# ============================================================================
# Test: ROB-head MMIO load preempts a younger fenced staging-slot hog
# ============================================================================
@cocotb.test()
async def test_head_mmio_preempts_younger_fenced_hog(dut: Any) -> None:
    """ROB-head MMIO load issues despite younger loads monopolizing the slot.

    call_stress UART poll-load liveness wedge in miniature. Three loads, ring
    order = physical slot order (head_ptr=0):
      slot 0 hog   (age 4): staged first, then fenced behind a non-forwardable
                            older store (match=1, can_forward=0) -> camps forever.
      slot 1 block (age 8): younger than hog, so it is the first *eligible*
                            stored-scan pick once hog is in-flight, but being
                            younger than the staged hog it cannot replace it
                            (sq_check_replace needs an OLDER candidate) -> the
                            scan parks here and never advances to the head.
      slot 2 head  (age 0): the ROB-head MMIO poll load, ring-AFTER block.
    Normal eligibility contains the head MMIO in slot 2, but the ring encoder
    still selects the earlier candidate in slot 1. The dedicated head path must
    override that normal winner, after which sq_check_replace evicts the hog
    (age 4 > head age 0). The second younger load keeps the competing
    normal-scan winner present, making head-path dominance explicit while
    preserving the original call_stress topology.
    """
    dut_if, model = await setup(dut)

    head_tag = 2  # oldest (ROB head): the MMIO poll load, age 0
    hog_tag = 6  # age 4: staged first, fenced, camps
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
    # match/no-forward response genuinely fences the staged hog.
    dut_if.drive_rob_head_tag(head_tag)

    head_issued = False
    for _ in range(80):
        # Fence whichever entry holds the staging slot iff it is the hog; the
        # head MMIO load -- being oldest -- has no older store and issues.
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

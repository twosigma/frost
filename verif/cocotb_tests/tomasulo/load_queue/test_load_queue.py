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
    await Timer(1, unit="ns")

    # Check memory request
    mem_req = dut_if.read_mem_request()
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

    # Now CDB should have the result
    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    return result


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
    await Timer(1, unit="ns")

    sq_check = dut_if.read_sq_check()
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
    """SQ forwards data, no memory access, CDB gets forwarded value."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=10, address=0x3000)

    # SQ says: match, can forward, data = 0xCAFEBABE
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=True, can_forward=True, data=0xCAFE_BABE)
    model.apply_forward(SQForwardResult(match=True, can_forward=True, data=0xCAFE_BABE))
    await Timer(1, unit="ns")

    # Memory should NOT be issued
    mem_req = dut_if.read_mem_request()
    assert not mem_req["en"], "Should not issue memory read when SQ forwards"

    # Step to register the forward
    await dut_if.step()
    dut_if.clear_sq_forward()
    dut_if.drive_sq_all_older_known(False)

    # CDB should have the forwarded value
    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    assert result.valid, "CDB should be valid after forward"
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
    await Timer(1, unit="ns")

    sq_check = dut_if.read_sq_check()
    assert sq_check["valid"], "MMIO should check SQ when at head"
    mem_req = dut_if.read_mem_request()
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
    await Timer(1, unit="ns")

    mem_req = dut_if.read_mem_request()
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
    await Timer(1, unit="ns")
    mem_req = dut_if.read_mem_request()
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

    # CDB should have full 64-bit value
    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    assert result.valid, "CDB should be valid after FLD"
    assert result.tag == 14
    expected = (0xCCCC_DDDD << 32) | 0xAAAA_BBBB
    assert (
        result.value == expected
    ), f"Expected 0x{expected:016x}, got 0x{result.value:016x}"


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
    await Timer(1, unit="ns")

    # Memory request should be for the oldest (tag 10)
    mem_req = dut_if.read_mem_request()
    assert mem_req["en"]
    sq_check = dut_if.read_sq_check()
    assert (
        sq_check["rob_tag"] == 10
    ), f"Expected oldest tag=10, got {sq_check['rob_tag']}"


# ============================================================================
# Test 19: CDB back-pressure
# ============================================================================
@cocotb.test()
async def test_cdb_backpressure(dut: Any) -> None:
    """Adapter pending -> LQ holds result, presents when clear."""
    dut_if, model = await setup(dut)

    await alloc_and_addr(dut_if, model, rob_tag=19, address=0x8000)

    # Complete the load
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")
    await dut_if.step()

    dut_if.drive_mem_response(0x1234_5678)
    model.mem_response(0x1234_5678)
    await dut_if.step()
    dut_if.clear_mem_response()

    # Set adapter pending
    dut_if.drive_adapter_pending(True)
    await Timer(1, unit="ns")

    result = dut_if.read_fu_complete()
    assert not result.valid, "CDB should be suppressed when adapter pending"

    # Clear back-pressure
    dut_if.drive_adapter_pending(False)
    await Timer(1, unit="ns")

    result = dut_if.read_fu_complete()
    assert result.valid, "CDB should present when adapter clear"
    assert result.value == 0x1234_5678


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
# Test 21: Constrained random
# ============================================================================
@cocotb.test()
async def test_constrained_random(dut: Any) -> None:
    """Randomized alloc/addr/forward/mem/flush over many cycles."""
    dut_if, model = await setup(dut)

    rng = random.Random(cocotb.RANDOM_SEED)
    num_cycles = 200
    next_tag = 0

    for cycle in range(num_cycles):
        action = rng.random()

        # State machine: one operation per iteration to avoid model-DUT
        # timing divergence (the DUT handles CDB broadcast + memory issue
        # in parallel on every clock edge).

        # Priority 1: Drain any pending CDB result
        model_cdb = model.get_fu_complete()
        if model_cdb.valid:
            await Timer(1, unit="ns")
            dut_cdb = dut_if.read_fu_complete()
            assert dut_cdb.valid, f"cycle {cycle}: model CDB valid but DUT not"
            assert (
                dut_cdb.tag == model_cdb.tag
            ), f"cycle {cycle}: CDB tag DUT={dut_cdb.tag} model={model_cdb.tag}"
            model.free_cdb_entry()
            model.advance_head()
            await dut_if.step()

        # Priority 2: Provide memory response if outstanding
        elif model.mem_outstanding:
            data = rng.randint(0, MASK32)
            dut_if.drive_mem_response(data)
            model.mem_response(data)
            await dut_if.step()
            dut_if.clear_mem_response()

        # Priority 3: Random action
        elif action < 0.30 and not model.full:
            # Allocate + address update
            tag = next_tag % 32
            next_tag += 1
            size = rng.choice([MEM_SIZE_BYTE, MEM_SIZE_HALF, MEM_SIZE_WORD])
            sign_ext = rng.random() < 0.5
            dut_if.drive_alloc(rob_tag=tag, size=size, sign_ext=sign_ext)
            model.alloc(tag, False, size, sign_ext)
            await dut_if.step()
            dut_if.clear_alloc()

            addr = rng.randint(0, 0xFFFF) & ~0x3
            dut_if.drive_addr_update(tag, addr)
            model.addr_update(tag, addr)
            await dut_if.step()
            dut_if.clear_addr_update()

        elif action < 0.05:
            # Flush all
            dut_if.drive_flush_all()
            model.flush_all()
            await dut_if.step()
            dut_if.clear_flush_all()

        else:
            # Try to issue a memory read
            dut_if.drive_sq_all_older_known(True)
            dut_if.drive_sq_forward(match=False, can_forward=False)
            await Timer(1, unit="ns")

            mem_req = dut_if.read_mem_request()
            if bool(dut.cache_hit_fast_path.value):
                model.cache_hit_complete()
            elif mem_req["en"]:
                model.issue_to_memory(True, SQForwardResult())
            await dut_if.step()
            dut_if.drive_sq_all_older_known(False)
            dut_if.clear_sq_forward()

        # Check count consistency
        assert (
            dut_if.count == model.count
        ), f"cycle {cycle}: count mismatch DUT={dut_if.count} model={model.count}"

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
    await Timer(1, unit="ns")
    mem_req = dut_if.read_mem_request()
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
# Test 24: Non-contiguous tail hole — retraction must stop at valid entry
# ============================================================================
@cocotb.test()
async def test_tail_retraction_non_contiguous_hole(dut: Any) -> None:
    """Tail retraction stops at first valid entry, not skipping past holes.

    Allocate out-of-ROB-order so that a partial flush creates the pattern:
      idx 0(V) 1(V) 2(INVALID) 3(V) 4(INVALID) 5(INVALID)
    Tail must retract from 6 to 4, not past the valid entry at idx 3.
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

    # Tail should retract from 6→5→4 (skipping idx 5,4) then STOP at idx 3 (valid)
    assert dut_if.count == 3, f"Expected 3 valid entries, got {dut_if.count}"
    assert not dut_if.full, "LQ should not be full after partial flush"

    # The key check: we can allocate exactly DEPTH - (tail-head) new entries.
    # tail=4, head=0 → 4 slots used → 4 free.  Allocate 4 to fill.
    for i in range(4):
        dut_if.drive_alloc(rob_tag=10 + i, size=MEM_SIZE_WORD)
        model.alloc(10 + i, False, MEM_SIZE_WORD, False)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.full, "LQ should be full after allocating remaining slots"
    # Valid count: 3 original + 4 new = 7 (idx 2 is a hole, still invalid)
    count = dut_if.count  # type: ignore[unreachable]
    assert count == 7, f"Expected 7 valid entries (with hole), got {count}"


# ============================================================================
# Test 25: L0 cache hit delivers data after SQ disambiguation
# ============================================================================
@cocotb.test()
async def test_cache_hit_bypasses_memory(dut: Any) -> None:
    """L0 cache hit delivers data without memory issue.

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

    # Cache hit processed on this edge (SQ confirms + cache hits → data_valid)
    await dut_if.step()

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()

    # Now CDB should have the result without any memory issue
    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    assert result.valid, "CDB should be valid from cache hit"
    assert result.tag == 2
    assert result.value == 0xAAAA_BBBB, f"Expected 0xAAAABBBB, got 0x{result.value:x}"


# ============================================================================
# Test 26: Cache miss fills cache, subsequent hit
# ============================================================================
@cocotb.test()
async def test_cache_miss_fills_cache(dut: Any) -> None:
    """Cache miss -> memory -> fill -> subsequent load hits cache."""
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

    await dut_if.step()  # cache hit + SQ confirmed

    dut_if.drive_sq_all_older_known(False)
    dut_if.clear_sq_forward()

    await Timer(1, unit="ns")
    result = dut_if.read_fu_complete()
    assert result.valid, "Second load should hit cache"
    assert result.tag == 4
    assert result.value == 0x1234_5678


# ============================================================================
# Test 27: MMIO address always misses cache
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
    await Timer(1, unit="ns")

    # Memory should be issued (cache always misses MMIO)
    mem_req = dut_if.read_mem_request()
    assert mem_req["en"], "MMIO load should issue to memory, not cache"

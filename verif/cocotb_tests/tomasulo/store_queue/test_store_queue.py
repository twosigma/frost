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

"""Unit tests for the Store Queue.

Tests cover reset, allocation, address/data update, commit + memory write
(SW/SH/SB), FSD two-phase commit, FSW, store-to-load forwarding, forwarding
stall, MMIO stores, partial/full flush, and constrained random.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from .sq_interface import SQInterface
from .sq_model import (
    SQModel,
    MemWriteReq,
    MEM_SIZE_BYTE,
    MEM_SIZE_HALF,
    MEM_SIZE_WORD,
    MEM_SIZE_DOUBLE,
    MASK32,
)

CLOCK_PERIOD_NS = 10
SQ_DEPTH = 8


async def setup(dut: Any) -> tuple[SQInterface, SQModel]:
    """Start clock, reset DUT, and return interface and model."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut_if = SQInterface(dut)
    model = SQModel()
    await dut_if.reset_dut()
    return dut_if, model


async def alloc_addr_data(
    dut_if: SQInterface,
    model: SQModel,
    rob_tag: int,
    address: int,
    data: int,
    is_fp: bool = False,
    size: int = MEM_SIZE_WORD,
    is_mmio: bool = False,
) -> None:
    """Allocate an entry, step, then update address and data, step."""
    dut_if.drive_alloc(rob_tag, is_fp=is_fp, size=size)
    model.alloc(rob_tag, is_fp, size)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag, address, is_mmio=is_mmio)
    model.addr_update(rob_tag, address, is_mmio)
    dut_if.drive_data_update(rob_tag, data)
    model.data_update(rob_tag, data)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.clear_data_update()


async def commit_and_write(
    dut_if: SQInterface,
    model: SQModel,
    rob_tag: int,
) -> MemWriteReq:
    """Commit a store and complete its memory write. Returns write request."""
    # Commit
    dut_if.drive_commit(rob_tag)
    model.commit(rob_tag)
    await dut_if.step()
    dut_if.clear_commit()

    # Memory write should fire
    await Timer(1, unit="ns")
    write_req = dut_if.read_mem_write()
    assert write_req.en, "Expected memory write after commit"

    # Model tracks write initiation
    model.mem_write_initiate()

    # Acknowledge write
    await dut_if.step()
    dut_if.drive_mem_write_done()
    model.mem_write_done()
    model.advance_head()
    await dut_if.step()
    dut_if.clear_mem_write_done()

    # Extra cycle for head pointer advancement (head_advance_target is
    # computed from registered sq_valid, so the head advances one cycle
    # after the entry is freed).
    await dut_if.step()

    return write_req


# ============================================================================
# Test 1: Reset state
# ============================================================================
@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """Empty after reset, no valid outputs."""
    dut_if, _ = await setup(dut)
    await Timer(1, unit="ns")

    assert dut_if.empty, "SQ should be empty after reset"
    assert not dut_if.full, "SQ should not be full after reset"
    assert dut_if.count == 0, "Count should be 0 after reset"
    assert not dut_if.read_mem_write().en, "No memory write after reset"


# ============================================================================
# Test 2: Allocate single entry
# ============================================================================
@cocotb.test()
async def test_alloc_single(dut: Any) -> None:
    """Allocate one entry, count=1."""
    dut_if, model = await setup(dut)

    dut_if.drive_alloc(rob_tag=5, size=MEM_SIZE_WORD)
    model.alloc(5, False, MEM_SIZE_WORD)
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

    for i in range(SQ_DEPTH):
        dut_if.drive_alloc(rob_tag=i, size=MEM_SIZE_WORD)
        model.alloc(i, False, MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == SQ_DEPTH, f"Expected count={SQ_DEPTH}, got {dut_if.count}"
    assert dut_if.full, "Should be full"
    assert not dut_if.empty, "Should not be empty"


# ============================================================================
# Test 4: Address and data update
# ============================================================================
@cocotb.test()
async def test_addr_data_update(dut: Any) -> None:
    """Allocate, update address and data, verify no write (not committed)."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(dut_if, model, rob_tag=3, address=0x1000, data=0xDEADBEEF)

    await Timer(1, unit="ns")
    write_req = dut_if.read_mem_write()
    assert not write_req.en, "No memory write without commit"
    assert dut_if.count == 1


# ============================================================================
# Test 5: Simple SW commit and write
# ============================================================================
@cocotb.test()
async def test_simple_sw(dut: Any) -> None:
    """Full SW flow: alloc -> addr/data -> commit -> mem write -> done."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(dut_if, model, rob_tag=7, address=0x2000, data=0xCAFEBABE)
    write_req = await commit_and_write(dut_if, model, rob_tag=7)

    assert write_req.addr == 0x2000, f"Expected addr=0x2000, got 0x{write_req.addr:x}"
    assert (
        write_req.data == 0xCAFEBABE
    ), f"Expected data=0xCAFEBABE, got 0x{write_req.data:x}"
    assert (
        write_req.byte_en == 0xF
    ), f"Expected byte_en=0xF for SW, got 0x{write_req.byte_en:x}"
    assert dut_if.empty, "SQ should be empty after write completes"


# ============================================================================
# Test 6: SH commit and write
# ============================================================================
@cocotb.test()
async def test_sh_lower(dut: Any) -> None:
    """SH at word-aligned address: byte_en=0x3, data replicated."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(
        dut_if, model, rob_tag=1, address=0x1000, data=0x1234, size=MEM_SIZE_HALF
    )
    write_req = await commit_and_write(dut_if, model, rob_tag=1)

    assert write_req.addr == 0x1000
    assert (
        write_req.byte_en == 0x3
    ), f"Expected byte_en=0x3, got 0x{write_req.byte_en:x}"
    # Data is replicated: {data[15:0], data[15:0]}
    assert (
        write_req.data == 0x12341234
    ), f"Expected 0x12341234, got 0x{write_req.data:x}"


# ============================================================================
# Test 7: SH at upper halfword
# ============================================================================
@cocotb.test()
async def test_sh_upper(dut: Any) -> None:
    """SH at addr+2: byte_en=0xC, data replicated."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(
        dut_if, model, rob_tag=2, address=0x1002, data=0xABCD, size=MEM_SIZE_HALF
    )
    write_req = await commit_and_write(dut_if, model, rob_tag=2)

    assert write_req.addr == 0x1002
    assert (
        write_req.byte_en == 0xC
    ), f"Expected byte_en=0xC, got 0x{write_req.byte_en:x}"
    assert (
        write_req.data == 0xABCDABCD
    ), f"Expected 0xABCDABCD, got 0x{write_req.data:x}"


# ============================================================================
# Test 8: SB commit and write
# ============================================================================
@cocotb.test()
async def test_sb(dut: Any) -> None:
    """SB at byte offset 1: byte_en=0x2, data replicated."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(
        dut_if, model, rob_tag=3, address=0x1001, data=0x42, size=MEM_SIZE_BYTE
    )
    write_req = await commit_and_write(dut_if, model, rob_tag=3)

    assert write_req.addr == 0x1001
    assert (
        write_req.byte_en == 0x2
    ), f"Expected byte_en=0x2, got 0x{write_req.byte_en:x}"
    assert (
        write_req.data == 0x42424242
    ), f"Expected 0x42424242, got 0x{write_req.data:x}"


# ============================================================================
# Test 9: FSW commit and write
# ============================================================================
@cocotb.test()
async def test_fsw(dut: Any) -> None:
    """FSW stores lower 32 bits of FP register."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=4,
        address=0x3000,
        data=0x40490FDB,
        is_fp=True,
        size=MEM_SIZE_WORD,
    )
    write_req = await commit_and_write(dut_if, model, rob_tag=4)

    assert write_req.addr == 0x3000
    assert write_req.data == 0x40490FDB, f"Expected FP data, got 0x{write_req.data:x}"
    assert write_req.byte_en == 0xF


# ============================================================================
# Test 10: FSD two-phase commit
# ============================================================================
@cocotb.test()
async def test_fsd_two_phase(dut: Any) -> None:
    """FSD: phase 0 writes low word, phase 1 writes high word at addr+4."""
    dut_if, model = await setup(dut)

    fp64_data = 0x400921FB54442D18  # pi
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=5,
        address=0x4000,
        data=fp64_data,
        is_fp=True,
        size=MEM_SIZE_DOUBLE,
    )

    # Commit
    dut_if.drive_commit(5)
    model.commit(5)
    await dut_if.step()
    dut_if.clear_commit()

    # Phase 0: low word at addr
    await Timer(1, unit="ns")
    write_req = dut_if.read_mem_write()
    assert write_req.en, "Phase 0 write expected"
    assert (
        write_req.addr == 0x4000
    ), f"Phase 0 addr should be 0x4000, got 0x{write_req.addr:x}"
    assert write_req.data == (fp64_data & MASK32), "Phase 0 data mismatch"
    assert write_req.byte_en == 0xF

    model.mem_write_initiate()
    await dut_if.step()
    dut_if.drive_mem_write_done()
    model.mem_write_done()
    await dut_if.step()
    dut_if.clear_mem_write_done()

    # Phase 1: high word at addr+4
    await Timer(1, unit="ns")
    write_req = dut_if.read_mem_write()
    assert write_req.en, "Phase 1 write expected"
    assert (
        write_req.addr == 0x4004
    ), f"Phase 1 addr should be 0x4004, got 0x{write_req.addr:x}"
    assert write_req.data == ((fp64_data >> 32) & MASK32), "Phase 1 data mismatch"
    assert write_req.byte_en == 0xF

    model.mem_write_initiate()
    await dut_if.step()
    dut_if.drive_mem_write_done()
    model.mem_write_done()
    model.advance_head()
    await dut_if.step()
    dut_if.clear_mem_write_done()
    # Extra cycle for head pointer advancement
    await dut_if.step()

    assert dut_if.empty, "SQ should be empty after FSD completes"


# ============================================================================
# Test 11: Store-to-load forwarding (SW → LW same address)
# ============================================================================
@cocotb.test()
async def test_forward_sw_to_lw(dut: Any) -> None:
    """SW at addr, LW check at same addr → match, can_forward, correct data."""
    dut_if, model = await setup(dut)

    store_data = 0xDEADBEEF
    store_addr = 0x2000
    await alloc_addr_data(dut_if, model, rob_tag=3, address=store_addr, data=store_data)

    # LQ check: load at same address, younger rob_tag
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=store_addr, rob_tag=5, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    all_known = dut_if.read_all_older_addrs_known()

    assert all_known, "All older addrs should be known"
    assert fwd.match, "Should match"
    assert fwd.can_forward, "Should be able to forward"
    assert fwd.data == store_data, f"Expected 0x{store_data:x}, got 0x{fwd.data:x}"

    dut_if.clear_sq_check()


# ============================================================================
# Test 12: Forwarding - no match (different address)
# ============================================================================
@cocotb.test()
async def test_forward_no_match(dut: Any) -> None:
    """SW at addr A, LW check at addr B → no match."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(dut_if, model, rob_tag=3, address=0x2000, data=0xAAAA)

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x3000, rob_tag=5, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    all_known = dut_if.read_all_older_addrs_known()

    assert all_known, "All older addrs should be known"
    assert not fwd.match, "Should not match (different word address)"
    dut_if.clear_sq_check()


# ============================================================================
# Test 13: Forwarding stall - older store without address
# ============================================================================
@cocotb.test()
async def test_forward_stall_no_addr(dut: Any) -> None:
    """Older store without addr_valid → all_older_addrs_known = false."""
    dut_if, model = await setup(dut)

    # Allocate store without address update
    dut_if.drive_alloc(rob_tag=2, size=MEM_SIZE_WORD)
    model.alloc(2, False, MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x2000, rob_tag=5, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    all_known = dut_if.read_all_older_addrs_known()
    assert not all_known, "Should NOT have all older addrs known"
    dut_if.clear_sq_check()


# ============================================================================
# Test 14: Forwarding stall - address match but data not ready
# ============================================================================
@cocotb.test()
async def test_forward_match_no_data(dut: Any) -> None:
    """Store with addr but no data → match, can_forward=false."""
    dut_if, model = await setup(dut)

    # Allocate and update address only (no data)
    dut_if.drive_alloc(rob_tag=3, size=MEM_SIZE_WORD)
    model.alloc(3, False, MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=3, address=0x2000)
    model.addr_update(3, 0x2000)
    await dut_if.step()
    dut_if.clear_addr_update()

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x2000, rob_tag=5, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "Should match (same word address)"
    assert not fwd.can_forward, "Can't forward without data"
    dut_if.clear_sq_check()


# ============================================================================
# Test 15: Forwarding - size mismatch (SW → LB) → match, can't forward
# ============================================================================
@cocotb.test()
async def test_forward_size_mismatch(dut: Any) -> None:
    """SW at addr, LB check at same word → match, can_forward=false."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(dut_if, model, rob_tag=3, address=0x2000, data=0xAAAA)

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x2001, rob_tag=5, size=MEM_SIZE_BYTE)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "Should match (same word address)"
    assert not fwd.can_forward, "Can't forward different size/addr"
    dut_if.clear_sq_check()


# ============================================================================
# Test 15b: Disjoint halfwords in same word do not conflict
# ============================================================================
@cocotb.test()
async def test_forward_disjoint_halfwords_no_match(dut: Any) -> None:
    """SH at addr, LH at addr+2 → no match because byte lanes do not overlap."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(
        dut_if, model, rob_tag=3, address=0x2000, data=0x1234, size=MEM_SIZE_HALF
    )

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x2002, rob_tag=5, size=MEM_SIZE_HALF)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    all_known = dut_if.read_all_older_addrs_known()

    assert all_known, "All older addrs should be known"
    assert not fwd.match, "Disjoint halfwords in the same word should not conflict"
    assert not fwd.can_forward, "No match means no forward either"
    dut_if.clear_sq_check()


# ============================================================================
# Test 16: Forwarding - newer store overwrites older
# ============================================================================
@cocotb.test()
async def test_forward_newest_wins(dut: Any) -> None:
    """Two stores to same addr: newest store's data is forwarded."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(dut_if, model, rob_tag=2, address=0x2000, data=0x1111)
    await alloc_addr_data(dut_if, model, rob_tag=4, address=0x2000, data=0x2222)

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x2000, rob_tag=6, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match
    assert fwd.can_forward
    assert fwd.data == 0x2222, f"Should forward newest store data, got 0x{fwd.data:x}"
    dut_if.clear_sq_check()


# ============================================================================
# Test 17: FSD forwarding to FLD
# ============================================================================
@cocotb.test()
async def test_forward_fsd_to_fld(dut: Any) -> None:
    """FSD at addr, FLD check at same addr → forward full 64-bit data."""
    dut_if, model = await setup(dut)

    fp64_data = 0x400921FB54442D18
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=3,
        address=0x4000,
        data=fp64_data,
        is_fp=True,
        size=MEM_SIZE_DOUBLE,
    )

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x4000, rob_tag=5, size=MEM_SIZE_DOUBLE)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match
    assert fwd.can_forward
    assert fwd.data == fp64_data, f"Expected 0x{fp64_data:x}, got 0x{fwd.data:x}"
    dut_if.clear_sq_check()


# ============================================================================
# Test 18: Full flush empties SQ
# ============================================================================
@cocotb.test()
async def test_flush_all(dut: Any) -> None:
    """Full flush resets all state."""
    dut_if, model = await setup(dut)

    # Fill some entries
    for i in range(4):
        dut_if.drive_alloc(rob_tag=i, size=MEM_SIZE_WORD)
        model.alloc(i, False, MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == 4

    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.empty, "SQ should be empty after flush_all"
    assert dut_if.count == 0


# ============================================================================
# Test 19: Partial flush - uncommitted entries flushed
# ============================================================================
@cocotb.test()
async def test_partial_flush_uncommitted(dut: Any) -> None:
    """Partial flush: uncommitted younger entries are invalidated."""
    dut_if, model = await setup(dut)

    dut_if.drive_rob_head_tag(0)

    # Allocate tags 1, 2, 3
    for tag in [1, 2, 3]:
        dut_if.drive_alloc(rob_tag=tag, size=MEM_SIZE_WORD)
        model.alloc(tag, False, MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == 3

    # Partial flush at tag=1 (tags 2 and 3 are younger, should be flushed)
    dut_if.drive_partial_flush(flush_tag=1)
    model.partial_flush(1, 0)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert dut_if.count == 1, f"Expected 1 entry remaining, got {dut_if.count}"


# ============================================================================
# Test 20: Partial flush - committed entries survive
# ============================================================================
@cocotb.test()
async def test_partial_flush_committed_survives(dut: Any) -> None:
    """Committed entries survive partial flush even if younger than flush_tag."""
    dut_if, model = await setup(dut)

    dut_if.drive_rob_head_tag(0)

    # Allocate and commit tag 1
    await alloc_addr_data(dut_if, model, rob_tag=1, address=0x1000, data=0xAA)
    dut_if.drive_commit(1)
    model.commit(1)
    await dut_if.step()
    dut_if.clear_commit()

    # Allocate uncommitted tags 2, 3
    for tag in [2, 3]:
        dut_if.drive_alloc(rob_tag=tag, size=MEM_SIZE_WORD)
        model.alloc(tag, False, MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == 3

    # Flush at tag=0: all tags 1,2,3 are "younger" than 0, but tag 1 is committed
    dut_if.drive_partial_flush(flush_tag=0)
    model.partial_flush(0, 0)
    await dut_if.step()
    dut_if.clear_partial_flush()

    # Tag 1 (committed) should survive; tags 2, 3 (uncommitted) should be flushed
    assert dut_if.count == 1, f"Expected 1 committed entry, got {dut_if.count}"


# ============================================================================
# Test 21: In-order commit and write for multiple stores
# ============================================================================
@cocotb.test()
async def test_in_order_write(dut: Any) -> None:
    """Multiple stores commit and write to memory in program order."""
    dut_if, model = await setup(dut)

    # Allocate 3 stores
    addrs = [0x1000, 0x2000, 0x3000]
    datas = [0xAAAA, 0xBBBB, 0xCCCC]
    for i, (addr, data) in enumerate(zip(addrs, datas)):
        await alloc_addr_data(dut_if, model, rob_tag=i, address=addr, data=data)

    # Commit all 3 (out of order to test that writes still happen in order).
    # Commit head entry LAST to avoid prematurely setting write_outstanding.
    for tag in [1, 2, 0]:
        dut_if.drive_commit(tag)
        model.commit(tag)
        await dut_if.step()
        dut_if.clear_commit()

    # Write should happen from head (tag 0 first)
    for i, (addr, data) in enumerate(zip(addrs, datas)):
        await Timer(1, unit="ns")
        write_req = dut_if.read_mem_write()
        assert write_req.en, f"Write {i} should be active"
        assert (
            write_req.addr == addr
        ), f"Write {i}: expected addr 0x{addr:x}, got 0x{write_req.addr:x}"
        assert (
            write_req.data == data
        ), f"Write {i}: expected data 0x{data:x}, got 0x{write_req.data:x}"

        model.mem_write_initiate()
        await dut_if.step()
        dut_if.drive_mem_write_done()
        model.mem_write_done()
        model.advance_head()
        await dut_if.step()
        dut_if.clear_mem_write_done()
        # Extra cycle for head pointer advancement
        await dut_if.step()

    assert dut_if.empty, "SQ should be empty after all writes"


# ============================================================================
# Test 22: No write without commit
# ============================================================================
@cocotb.test()
async def test_no_write_without_commit(dut: Any) -> None:
    """Store with addr+data but no commit does not write to memory."""
    dut_if, model = await setup(dut)

    await alloc_addr_data(dut_if, model, rob_tag=3, address=0x1000, data=0xDEAD)

    # Wait several cycles
    for _ in range(5):
        await dut_if.step()
        await Timer(1, unit="ns")
        assert not dut_if.read_mem_write().en, "No write without commit"


# ============================================================================
# Test 23: No write without data
# ============================================================================
@cocotb.test()
async def test_no_write_without_data(dut: Any) -> None:
    """Committed store without data does not write to memory."""
    dut_if, model = await setup(dut)

    # Allocate, update address only (no data)
    dut_if.drive_alloc(rob_tag=3, size=MEM_SIZE_WORD)
    model.alloc(3, False, MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    dut_if.drive_addr_update(rob_tag=3, address=0x1000)
    model.addr_update(3, 0x1000)
    await dut_if.step()
    dut_if.clear_addr_update()

    # Commit
    dut_if.drive_commit(3)
    model.commit(3)
    await dut_if.step()
    dut_if.clear_commit()

    await Timer(1, unit="ns")
    assert not dut_if.read_mem_write().en, "No write without data"

    # Now provide data
    dut_if.drive_data_update(rob_tag=3, data=0xBEEF)
    model.data_update(3, 0xBEEF)
    await dut_if.step()
    dut_if.clear_data_update()

    # Now write should happen
    await Timer(1, unit="ns")
    write_req = dut_if.read_mem_write()
    assert write_req.en, "Write should fire once data arrives"
    assert write_req.data == 0xBEEF


# ============================================================================
# Test 24: Cache invalidation on write completion
# ============================================================================
@cocotb.test()
async def test_cache_invalidation(dut: Any) -> None:
    """Memory write completion triggers L0 cache invalidation."""
    dut_if, model = await setup(dut)

    store_addr = 0x5000
    await alloc_addr_data(dut_if, model, rob_tag=1, address=store_addr, data=0xAA)

    dut_if.drive_commit(1)
    model.commit(1)
    await dut_if.step()
    dut_if.clear_commit()

    # Write fires
    model.mem_write_initiate()
    await dut_if.step()

    # Acknowledge → should see cache invalidation
    dut_if.drive_mem_write_done()
    await Timer(1, unit="ns")

    inv = dut_if.read_cache_invalidate()
    assert inv["valid"], "Cache invalidation should be active"
    assert inv["addr"] == store_addr, f"Should invalidate at 0x{store_addr:x}"

    model.mem_write_done()
    model.advance_head()
    await dut_if.step()
    dut_if.clear_mem_write_done()


# ============================================================================
# Test 25: Forwarding - load not older than store (no forward)
# ============================================================================
@cocotb.test()
async def test_forward_load_older_than_store(dut: Any) -> None:
    """Load older than store → store is not checked (no match)."""
    dut_if, model = await setup(dut)

    # Store with tag=5
    await alloc_addr_data(dut_if, model, rob_tag=5, address=0x2000, data=0xAAAA)

    # Load with tag=3 (older than store tag=5, head=0)
    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x2000, rob_tag=3, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert not fwd.match, "Store is not older than load, should not match"
    dut_if.clear_sq_check()


# ============================================================================
# Test 26: FSD → LW overlap at +4 address
# ============================================================================
@cocotb.test()
async def test_forward_fsd_overlap_plus4(dut: Any) -> None:
    """FSD at addr A, FLW at addr A+4 → match + forward high word."""
    dut_if, model = await setup(dut)

    fp64_data = 0x1234567890ABCDEF
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=2,
        address=0x4000,
        data=fp64_data,
        is_fp=True,
        size=MEM_SIZE_DOUBLE,
    )

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x4004, rob_tag=5, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "DOUBLE store overlaps at +4"
    assert fwd.can_forward, "FLW at FSD+4 should forward high word"
    expected_hi = (fp64_data >> 32) & MASK32
    assert (
        fwd.data == expected_hi
    ), f"Expected high word 0x{expected_hi:08x}, got 0x{fwd.data:x}"
    dut_if.clear_sq_check()


# ============================================================================
# Test 27: MMIO store does not forward
# ============================================================================
@cocotb.test()
async def test_mmio_store_no_forward(dut: Any) -> None:
    """MMIO store at same address → match but can_forward=False."""
    dut_if, model = await setup(dut)

    mmio_addr = 0x40000000
    await alloc_addr_data(
        dut_if, model, rob_tag=3, address=mmio_addr, data=0xDEAD, is_mmio=True
    )

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=mmio_addr, rob_tag=5, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "Should match MMIO store address"
    assert not fwd.can_forward, "MMIO store must not forward"
    dut_if.clear_sq_check()


# ============================================================================
# Test 28: Non-MMIO store forwards when MMIO store also present
# ============================================================================
@cocotb.test()
async def test_non_mmio_forwards_over_mmio(dut: Any) -> None:
    """Newer non-MMIO store at same address forwards over older MMIO store."""
    dut_if, model = await setup(dut)

    addr = 0x40000000
    # Older MMIO store
    await alloc_addr_data(
        dut_if, model, rob_tag=2, address=addr, data=0xAAAA, is_mmio=True
    )
    # Newer non-MMIO store at same address
    await alloc_addr_data(
        dut_if, model, rob_tag=4, address=addr, data=0xBBBB, is_mmio=False
    )

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=addr, rob_tag=6, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match
    assert fwd.can_forward, "Newer non-MMIO store should forward"
    assert fwd.data == 0xBBBB, f"Expected 0xBBBB, got 0x{fwd.data:x}"
    dut_if.clear_sq_check()


# ============================================================================
# Test 29: FSD phase-2 cache invalidation at addr+4
# ============================================================================
@cocotb.test()
async def test_fsd_phase2_cache_invalidation(dut: Any) -> None:
    """FSD phase-2 write invalidates L0 cache at addr+4, not base."""
    dut_if, model = await setup(dut)

    fp64_data = 0x400921FB54442D18  # pi
    base_addr = 0x4000
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=5,
        address=base_addr,
        data=fp64_data,
        is_fp=True,
        size=MEM_SIZE_DOUBLE,
    )

    # Commit
    dut_if.drive_commit(5)
    model.commit(5)
    await dut_if.step()
    dut_if.clear_commit()

    # Phase 0: low word at base addr
    model.mem_write_initiate()
    await dut_if.step()
    dut_if.drive_mem_write_done()
    await Timer(1, unit="ns")

    inv = dut_if.read_cache_invalidate()
    assert inv["valid"], "Phase 0 cache invalidation expected"
    assert (
        inv["addr"] == base_addr
    ), f"Phase 0 should invalidate at base 0x{base_addr:x}, got 0x{inv['addr']:x}"

    model.mem_write_done()
    await dut_if.step()
    dut_if.clear_mem_write_done()

    # Phase 1: high word at addr+4
    await Timer(1, unit="ns")
    write_req = dut_if.read_mem_write()
    assert write_req.en, "Phase 1 write expected"

    model.mem_write_initiate()
    await dut_if.step()
    dut_if.drive_mem_write_done()
    await Timer(1, unit="ns")

    inv = dut_if.read_cache_invalidate()
    assert inv["valid"], "Phase 1 cache invalidation expected"
    assert (
        inv["addr"] == base_addr + 4
    ), f"Phase 1 should invalidate at 0x{base_addr + 4:x}, got 0x{inv['addr']:x}"

    model.mem_write_done()
    model.advance_head()
    await dut_if.step()
    dut_if.clear_mem_write_done()


# ============================================================================
# Test 30: FLW at FSD base → forward low word
# ============================================================================
@cocotb.test()
async def test_forward_flw_at_fsd_base(dut: Any) -> None:
    """FSD at addr, FLW at same base addr → forward low word [31:0]."""
    dut_if, model = await setup(dut)

    fp64_data = 0xDEADBEEF_CAFEBABE
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=2,
        address=0x4000,
        data=fp64_data,
        is_fp=True,
        size=MEM_SIZE_DOUBLE,
    )

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x4000, rob_tag=5, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "FLW at FSD base should match"
    assert fwd.can_forward, "FLW at FSD base should forward"
    expected_lo = fp64_data & MASK32
    assert (
        fwd.data == expected_lo
    ), f"Expected low word 0x{expected_lo:08x}, got 0x{fwd.data:x}"
    dut_if.clear_sq_check()


# ============================================================================
# Test 31: FLW at FSD addr+4 → forward high word
# ============================================================================
@cocotb.test()
async def test_forward_flw_at_fsd_plus4(dut: Any) -> None:
    """FSD at addr, FLW at addr+4 → forward high word [63:32]."""
    dut_if, model = await setup(dut)

    fp64_data = 0xDEADBEEF_CAFEBABE
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=2,
        address=0x4000,
        data=fp64_data,
        is_fp=True,
        size=MEM_SIZE_DOUBLE,
    )

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x4004, rob_tag=5, size=MEM_SIZE_WORD)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "FLW at FSD+4 should match"
    assert fwd.can_forward, "FLW at FSD+4 should forward"
    expected_hi = (fp64_data >> 32) & MASK32
    assert (
        fwd.data == expected_hi
    ), f"Expected high word 0x{expected_hi:08x}, got 0x{fwd.data:x}"
    dut_if.clear_sq_check()


# ============================================================================
# Test 32: LB at FSD base → match but can_forward=False (sub-word stalls)
# ============================================================================
@cocotb.test()
async def test_forward_lb_at_fsd_base(dut: Any) -> None:
    """LB at FSD base address → match but sub-word cannot forward."""
    dut_if, model = await setup(dut)

    fp64_data = 0xDEADBEEF_CAFEBABE
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=2,
        address=0x4000,
        data=fp64_data,
        is_fp=True,
        size=MEM_SIZE_DOUBLE,
    )

    dut_if.drive_rob_head_tag(0)
    dut_if.drive_sq_check(addr=0x4000, rob_tag=5, size=MEM_SIZE_BYTE)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "LB at FSD base should match"
    assert not fwd.can_forward, "Sub-word load from DOUBLE can't forward"
    dut_if.clear_sq_check()


# ============================================================================
# Test 33: Constrained random
# ============================================================================
@cocotb.test()
async def test_constrained_random(dut: Any) -> None:
    """Randomized allocation, addr/data, commit, write, flush sequence."""
    dut_if, model = await setup(dut)

    random.seed(42)
    allocated_tags: list[int] = []
    committed_tags: set[int] = set()
    next_tag = 0
    num_cycles = 500

    for cycle in range(num_cycles):
        action = random.random()

        # Allocate
        if action < 0.25 and not model.full and next_tag < 31:
            tag = next_tag
            next_tag += 1
            size = random.choice([MEM_SIZE_BYTE, MEM_SIZE_HALF, MEM_SIZE_WORD])
            dut_if.drive_alloc(rob_tag=tag, size=size)
            model.alloc(tag, False, size)
            allocated_tags.append(tag)
            await dut_if.step()
            dut_if.clear_alloc()

            # Immediately give addr and data
            addr = random.randint(0, 0xFFFF) & ~0x3  # word-aligned
            data = random.randint(0, MASK32)
            dut_if.drive_addr_update(rob_tag=tag, address=addr)
            model.addr_update(tag, addr)
            dut_if.drive_data_update(rob_tag=tag, data=data)
            model.data_update(tag, data)
            await dut_if.step()
            dut_if.clear_addr_update()
            dut_if.clear_data_update()

        # Commit oldest uncommitted
        elif action < 0.50 and allocated_tags:
            # Find oldest uncommitted
            uncommitted = [t for t in allocated_tags if t not in committed_tags]
            if uncommitted:
                tag = uncommitted[0]
                dut_if.drive_commit(tag)
                model.commit(tag)
                committed_tags.add(tag)
                await dut_if.step()
                dut_if.clear_commit()

        # Process memory write
        elif action < 0.75:
            await Timer(1, unit="ns")
            write_req = dut_if.read_mem_write()
            if write_req.en:
                model.mem_write_initiate()
                await dut_if.step()
                dut_if.drive_mem_write_done()
                model.mem_write_done()
                model.advance_head()
                # Remove completed tag
                if allocated_tags:
                    allocated_tags.pop(0)
                    if committed_tags:
                        committed_tags -= {min(committed_tags)}
                await dut_if.step()
                dut_if.clear_mem_write_done()
            else:
                await dut_if.step()

        else:
            await dut_if.step()

        # Periodically verify count
        if cycle % 50 == 0:
            assert (
                dut_if.count == model.count
            ), f"Cycle {cycle}: count mismatch DUT={dut_if.count} model={model.count}"

    # Drain remaining entries
    for _ in range(SQ_DEPTH + 20):
        # Commit any remaining
        uncommitted = [t for t in allocated_tags if t not in committed_tags]
        if uncommitted:
            tag = uncommitted[0]
            dut_if.drive_commit(tag)
            model.commit(tag)
            committed_tags.add(tag)
            await dut_if.step()
            dut_if.clear_commit()

        await Timer(1, unit="ns")
        write_req = dut_if.read_mem_write()
        if write_req.en:
            model.mem_write_initiate()
            await dut_if.step()
            dut_if.drive_mem_write_done()
            model.mem_write_done()
            model.advance_head()
            if allocated_tags:
                allocated_tags.pop(0)
            await dut_if.step()
            dut_if.clear_mem_write_done()
        else:
            await dut_if.step()

    assert (
        dut_if.count == model.count
    ), f"Final count mismatch DUT={dut_if.count} model={model.count}"


# ============================================================================
# Test 34: SC discard on failure
# ============================================================================
@cocotb.test()
async def test_sc_discard_on_failure(dut: Any) -> None:
    """SC entry invalidated when i_sc_discard is asserted."""
    dut_if, model = await setup(dut)

    # Allocate an SC entry
    dut_if.drive_alloc(rob_tag=5, size=MEM_SIZE_WORD, is_sc=True)
    model.alloc(5, False, MEM_SIZE_WORD, is_sc=True)
    await dut_if.step()
    dut_if.clear_alloc()

    assert dut_if.count == 1, f"Expected count=1, got {dut_if.count}"

    # Discard the SC entry (failed SC)
    dut_if.drive_sc_discard(rob_tag=5)
    model.sc_discard(5)
    await dut_if.step()
    dut_if.clear_sc_discard()

    assert dut_if.count == 0, f"SC should be discarded, count={dut_if.count}"

    # Head pointer advances past invalidated entry on next cycle
    await dut_if.step()
    assert dut_if.empty, "SQ should be empty after SC discard + head advance"


# ============================================================================
# Test 35: committed_empty signal
# ============================================================================
@cocotb.test()
async def test_committed_empty_signal(dut: Any) -> None:
    """o_committed_empty reflects only committed entries."""
    dut_if, model = await setup(dut)
    await Timer(1, unit="ns")

    # Initially committed_empty should be true (no entries)
    assert dut_if.committed_empty, "committed_empty should be true when SQ empty"

    # Allocate an uncommitted entry
    dut_if.drive_alloc(rob_tag=3, size=MEM_SIZE_WORD)
    model.alloc(3, False, MEM_SIZE_WORD)
    await dut_if.step()
    dut_if.clear_alloc()

    # Give it addr and data
    dut_if.drive_addr_update(rob_tag=3, address=0x1000)
    model.addr_update(3, 0x1000)
    dut_if.drive_data_update(rob_tag=3, data=0xAA)
    model.data_update(3, 0xAA)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.clear_data_update()

    await Timer(1, unit="ns")
    # Entry exists but is uncommitted → committed_empty stays true
    assert (
        dut_if.committed_empty
    ), "committed_empty should be true with only uncommitted entries"

    # Commit the entry
    dut_if.drive_commit(3)
    model.commit(3)
    await dut_if.step()
    dut_if.clear_commit()

    await Timer(1, unit="ns")
    # Now there is a committed entry → committed_empty should be false
    assert (
        not dut_if.committed_empty
    ), "committed_empty should be false with committed entry"

    # Complete the write
    model.mem_write_initiate()  # type: ignore[unreachable]
    await dut_if.step()
    dut_if.drive_mem_write_done()
    model.mem_write_done()
    model.advance_head()
    await dut_if.step()
    dut_if.clear_mem_write_done()
    await dut_if.step()

    await Timer(1, unit="ns")
    assert (
        dut_if.committed_empty
    ), "committed_empty should be true after write completes"


# ============================================================================
# FP64 Forwarding Edge-Case Tests (Fix #4)
# ============================================================================


@cocotb.test()
async def test_forward_fld_from_fsw_stalls(dut: Any) -> None:
    """FSW at addr, FLD at same addr → match=1, can_forward=0 (size mismatch).

    The store is WORD (FSW), but the load is DOUBLE (FLD). The SQ cannot
    forward a 32-bit store to satisfy a 64-bit load, so it stalls.
    """
    dut_if, model = await setup(dut)

    # FSW: single-precision FP store (MEM_SIZE_WORD, is_fp=True)
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=1,
        address=0x5000,
        data=0x3F800000,  # 1.0f
        is_fp=True,
        size=MEM_SIZE_WORD,
    )

    dut_if.drive_rob_head_tag(0)
    # FLD check: 64-bit load at the same address
    dut_if.drive_sq_check(addr=0x5000, rob_tag=5, size=MEM_SIZE_DOUBLE)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "FLD at FSW address should match"
    assert (
        not fwd.can_forward
    ), "WORD store cannot forward to DOUBLE load (size mismatch)"
    dut_if.clear_sq_check()


@cocotb.test()
async def test_forward_lh_from_fsd_stalls(dut: Any) -> None:
    """FSD at addr, LH at same addr → match=1, can_forward=0.

    Store is DOUBLE (FSD), load is HALF (LH). Sub-word loads from a 64-bit
    FP store cannot be forwarded (no partial forwarding from FP64).
    """
    dut_if, model = await setup(dut)

    fp64_data = 0xDEADBEEF_CAFEBABE
    await alloc_addr_data(
        dut_if,
        model,
        rob_tag=3,
        address=0x7000,
        data=fp64_data,
        is_fp=True,
        size=MEM_SIZE_DOUBLE,
    )

    dut_if.drive_rob_head_tag(0)
    # LH at FSD base: sub-word load from DOUBLE store
    dut_if.drive_sq_check(addr=0x7000, rob_tag=5, size=MEM_SIZE_HALF)
    await Timer(1, unit="ns")

    fwd = dut_if.read_sq_forward()
    assert fwd.match, "LH at FSD base should match"
    assert not fwd.can_forward, "Sub-word load from DOUBLE store cannot forward"
    dut_if.clear_sq_check()


# ============================================================================
# Test 38: Non-contiguous hole — pointer-full with fewer than DEPTH valid
# ============================================================================
@cocotb.test()
async def test_pointer_full_with_hole(dut: Any) -> None:
    """Partial flush creates a hole; pointer-full fires with < DEPTH valid entries.

    Allocate out-of-ROB-order so partial flush creates:
      idx 0(V:tag0) 1(V:tag1) 2(I:tag5) 3(V:tag2) 4(I:tag6) 5(I:tag7)
    Tail retracts from 6→4 (stops at valid idx 3).  Then allocate 4 more
    to exhaust pointer space: pointer-full with only 7 valid entries.
    Pointer-based full in the model must agree with the DUT.
    """
    dut_if, model = await setup(dut)
    dut_if.drive_rob_head_tag(0)

    # Allocate 6 entries with tags that create a hole after flush.
    # Tags 5, 6, 7 are younger than flush_tag=4; tags 0, 1, 2 are not.
    for tag in [0, 1, 5, 2, 6, 7]:
        dut_if.drive_alloc(rob_tag=tag, size=MEM_SIZE_WORD)
        model.alloc(tag, False, MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    assert dut_if.count == 6, f"Expected 6 entries, got {dut_if.count}"
    assert model.count == 6

    # Partial flush: tags 5, 6, 7 flushed (younger than 4 relative to head 0)
    dut_if.drive_partial_flush(flush_tag=4)
    model.partial_flush(4, 0)
    await dut_if.step()
    dut_if.clear_partial_flush()

    assert dut_if.count == 3, f"Expected 3 valid entries, got {dut_if.count}"
    assert model.count == 3
    assert not dut_if.full, "SQ should not be full after partial flush"
    assert not model.full, "Model should not be full after partial flush"

    # Allocate 4 more entries to exhaust pointer space (tail wraps to head)
    for i in range(4):
        dut_if.drive_alloc(rob_tag=10 + i, size=MEM_SIZE_WORD)
        model.alloc(10 + i, False, MEM_SIZE_WORD)
        await dut_if.step()
        dut_if.clear_alloc()

    # Pointer-full with 7 valid entries (idx 2 is a hole)
    assert dut_if.full, "SQ should be pointer-full after filling remaining slots"
    assert model.full, "Model pointer-full must agree with DUT"  # type: ignore[unreachable]
    assert (
        dut_if.count == 7
    ), f"Expected 7 valid entries (with hole), got {dut_if.count}"
    assert model.count == 7, f"Model count must match DUT (got {model.count})"

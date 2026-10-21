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

"""Uncached stores complete precisely at the ROB head after their AXI reply."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from ..load_queue.lq_interface import unpack_fu_complete
from .test_store_queue import setup, alloc_addr_data


async def no_write(dut_if: Any, cycles: int = 5) -> None:
    """Check that no store reaches memory during these cycles."""
    for _ in range(cycles):
        await dut_if.step()
        assert not dut_if.read_mem_write().en


async def wait_write(dut_if: Any, address: int, size: int = 2) -> Any:
    """Wait for a store and check its address and transfer size."""
    for _ in range(20):
        await Timer(1, unit="ns")
        req = dut_if.read_mem_write()
        if req.en:
            assert req.addr == address
            assert int(dut_if.dut.o_mem_write_size.value) == size
            await dut_if.step()
            return req
        await dut_if.step()
    raise AssertionError("No memory write")


async def reply(dut_if: Any, tag: int, error: bool = False) -> None:
    """Return a delayed completion and check its owner."""
    dut = dut_if.dut
    assert not unpack_fu_complete(int(dut.o_uncached_store_complete.value)).valid
    dut.i_mem_write_error.value = int(error)
    dut_if.drive_mem_write_done()
    await dut_if.step()
    dut_if.clear_mem_write_done()
    dut.i_mem_write_error.value = 0
    result = unpack_fu_complete(int(dut.o_uncached_store_complete.value))
    assert result.valid and result.tag == tag
    assert result.exception == error and result.value == 0
    assert result.exc_cause == (7 if error else 0)
    for _ in range(8):
        await dut_if.step()
        assert unpack_fu_complete(int(dut.o_uncached_store_complete.value)) == result
        assert not dut_if.read_mem_write().en
    dut.i_uncached_store_result_ready.value = 1
    await dut_if.step()
    dut.i_uncached_store_result_ready.value = 0
    assert not unpack_fu_complete(int(dut.o_uncached_store_complete.value)).valid


@cocotb.test()
async def test_head_shield_delayed_completion_and_fault(dut: Any) -> None:
    """Check head shield delayed completion and fault."""
    dut_if, model = await setup(dut)
    for size in range(4):
        await dut_if.reset_dut()
        address = 0x40000008
        await alloc_addr_data(
            dut_if, model, 2, address, 0x12345678, size=size, is_mmio=True
        )
        await no_write(dut_if)  # Younger than ROB head, cannot cause a side effect.
        dut_if.drive_rob_head_tag(2)
        await no_write(dut_if)  # No interrupt/debug shield yet.
        assert bool(dut.o_uncached_store_pending.value)
        dut.i_uncached_store_shield.value = 1
        await no_write(dut_if)  # Trap/retirement controller still holds permission.
        dut.i_head_side_effects_allowed.value = 1
        req = await wait_write(dut_if, address, size)
        assert req.byte_en == (1 << (1 << size)) - 1
        await no_write(dut_if, 20)
        assert not dut_if.empty
        await reply(dut_if, 2, error=bool(size & 1))
        assert dut_if.empty


@cocotb.test()
async def test_flush_cancels_unarmed_store(dut: Any) -> None:
    """Check flush cancels unarmed store."""
    dut_if, model = await setup(dut)
    await alloc_addr_data(dut_if, model, 1, 0x40000000, 0x55, is_mmio=True)
    dut_if.drive_rob_head_tag(1)
    await no_write(dut_if, 2)
    dut.i_uncached_store_shield.value = 1
    dut.i_head_side_effects_allowed.value = 1
    dut_if.drive_flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()
    await no_write(dut_if, 12)
    assert dut_if.empty


@cocotb.test()
async def test_store_order_and_no_speculative_younger_write(dut: Any) -> None:
    """Check store order and no speculative younger write."""
    dut_if, model = await setup(dut)
    await alloc_addr_data(dut_if, model, 0, 0x80002000, 0xAA)
    await alloc_addr_data(dut_if, model, 1, 0x40000000, 0xBB, is_mmio=True)
    dut_if.drive_commit(0)
    await dut_if.step()
    dut_if.clear_commit()
    await wait_write(dut_if, 0x80002000)
    dut_if.drive_rob_head_tag(1)
    dut.i_uncached_store_shield.value = 1
    dut.i_head_side_effects_allowed.value = 1
    await no_write(dut_if, 12)  # Old cached store must finish first.
    dut_if.drive_mem_write_done()
    await dut_if.step()
    dut_if.clear_mem_write_done()
    await wait_write(dut_if, 0x40000000)
    await alloc_addr_data(dut_if, model, 2, 0x40000004, 0xCC, is_mmio=True)
    await no_write(dut_if, 8)
    await reply(dut_if, 1)
    await no_write(dut_if, 8)  # Bus completion alone is not retirement.
    dut_if.drive_rob_head_tag(2)
    await wait_write(dut_if, 0x40000004)
    await reply(dut_if, 2, error=True)


@cocotb.test()
async def test_uncached_sc_requires_success_permission(dut: Any) -> None:
    """Check uncached sc requires success permission."""
    dut_if, _ = await setup(dut)
    for success in (False, True):
        await dut_if.reset_dut()
        dut_if.drive_alloc(1, is_sc=True)
        await dut_if.step()
        dut_if.clear_alloc()
        dut_if.drive_addr_update(1, 0x1000)
        dut_if.drive_data_update(1, 0x1234)
        await dut_if.step()
        dut_if.clear_addr_update()
        dut_if.clear_data_update()
        dut_if.drive_rob_head_tag(1)
        dut.i_uncached_store_shield.value = 1
        dut.i_head_side_effects_allowed.value = 1
        await no_write(dut_if, 12)
        if success:
            dut.i_uncached_sc_success.value = 1
            dut.i_uncached_sc_tag.value = 1
            await dut_if.step()
            dut.i_uncached_sc_success.value = 0
            # A younger branch flush must preserve the older SC's permission.
            dut_if.drive_partial_flush(2)
            await dut_if.step()
            dut_if.clear_partial_flush()
            await wait_write(dut_if, 0x1000)
            await reply(dut_if, 1, error=True)
        else:
            dut_if.drive_sc_discard(1)
            await dut_if.step()
            dut_if.clear_sc_discard()
            await no_write(dut_if)
            assert dut_if.empty

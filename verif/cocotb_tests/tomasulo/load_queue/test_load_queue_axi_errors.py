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

"""External response faults must never be completed as successful loads."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from .lq_interface import AMOADD_W, LR_D
from .lq_model import MEM_SIZE_DOUBLE, MEM_SIZE_WORD
from .test_load_queue import (
    accept_fu_complete,
    setup,
    wait_for_fu_complete,
    wait_for_mem_request,
)


async def launch(
    dut_if: Any,
    tag: int,
    address: int,
    *,
    is_fp: bool = False,
    is_lr: bool = False,
    is_amo: bool = False,
) -> Any:
    """Issue the operation and retain its response owner."""
    dut_if.drive_rob_head_tag(tag)
    dut_if.drive_alloc(
        tag,
        is_fp=is_fp,
        size=MEM_SIZE_DOUBLE if is_lr else MEM_SIZE_WORD,
        is_lr=is_lr,
        is_amo=is_amo,
        amo_op=LR_D if is_lr else AMOADD_W,
    )
    await dut_if.step()
    dut_if.clear_alloc()
    dut_if.drive_addr_update(tag, address, is_mmio=address == 0x40000004, amo_rs2=3)
    await dut_if.step()
    dut_if.clear_addr_update()
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    request = await wait_for_mem_request(dut_if, max_cycles=16)
    assert request["en"], f"No request for tag {tag}, address {address:#x}"
    await dut_if.step()
    return request


async def expect_fault(dut_if: Any, tag: int, cause: int) -> None:
    """Check expect fault."""
    result = await wait_for_fu_complete(dut_if, max_cycles=12)
    assert result.valid and result.tag == tag
    assert result.exception and result.exc_cause == cause
    assert result.value == 0, (
        "Bus faults report xtval=0, not data or a physical address"
    )
    for _ in range(4):
        await dut_if.step()
        assert dut_if.read_fu_complete() == result, (
            "Fault changed under CDB backpressure"
        )
    await accept_fu_complete(dut_if)


@cocotb.test()
async def test_read_errors_do_not_fill_cache(dut: Any) -> None:
    """Check read errors do not fill cache."""
    dut_if, _ = await setup(dut)
    for address, is_fp in ((0x1000, False), (0x80002000, True), (0x40000004, False)):
        await dut_if.reset_dut()
        await launch(dut_if, 1, address, is_fp=is_fp)
        for _ in range(12):
            await dut_if.step()
            assert not dut_if.read_fu_complete().valid
        dut_if.drive_mem_response(0xBADDBADD, error=True)
        await Timer(1, unit="ns")
        assert not bool(dut.o_l0_fill.value)
        await dut_if.step()
        dut_if.clear_mem_response()
        await expect_fault(dut_if, 1, 5)
        # A later access to the same location must reach memory again.
        await launch(dut_if, 2, address)
        dut_if.drive_mem_response(0x12345678)
        await dut_if.step()
        dut_if.clear_mem_response()
        result = await wait_for_fu_complete(dut_if)
        assert result.valid and not result.exception and result.value == 0x12345678
        await accept_fu_complete(dut_if)


@cocotb.test()
async def test_lr_error_does_not_create_reservation(dut: Any) -> None:
    """Check lr error does not create reservation."""
    dut_if, _ = await setup(dut)
    await launch(dut_if, 1, 0x80003000, is_lr=True)
    dut_if.drive_mem_response(0xDEADBEEF, error=True)
    await dut_if.step()
    dut_if.clear_mem_response()
    await expect_fault(dut_if, 1, 5)
    assert not bool(dut.o_reservation_valid.value)


@cocotb.test()
async def test_amo_read_error_never_writes(dut: Any) -> None:
    """Check amo read error never writes."""
    dut_if, _ = await setup(dut)
    await launch(dut_if, 1, 0x1200, is_amo=True)
    dut_if.drive_mem_response(0xDEADBEEF, error=True)
    await dut_if.step()
    dut_if.clear_mem_response()
    for _ in range(8):
        assert not dut_if.read_amo_mem_write()["en"]
        await dut_if.step()
    await expect_fault(dut_if, 1, 7)
    await launch(dut_if, 2, 0x1208)
    dut_if.drive_mem_response(0x1234)
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert result.valid and result.value == 0x1234 and not result.exception


@cocotb.test()
async def test_amo_write_error_is_store_access_fault(dut: Any) -> None:
    """Check amo write error is store access fault."""
    dut_if, _ = await setup(dut)
    await launch(dut_if, 1, 0x80003000, is_amo=True)
    dut_if.drive_mem_response(0xABCD)
    await dut_if.step()
    dut_if.clear_mem_response()
    for _ in range(8):
        if dut_if.read_amo_mem_write()["en"]:
            break
        await dut_if.step()
    assert dut_if.read_amo_mem_write()["en"]
    for _ in range(10):
        await dut_if.step()
        assert not dut_if.read_fu_complete().valid
    dut.i_amo_mem_write_error.value = 1
    dut_if.drive_amo_mem_write_done()
    await dut_if.step()
    dut_if.drive_amo_mem_write_done(False)
    dut.i_amo_mem_write_error.value = 0
    await expect_fault(dut_if, 1, 7)
    assert not dut_if.read_amo_mem_write()["en"]


@cocotb.test()
async def test_error_after_flush_does_not_fault_reused_entry(dut: Any) -> None:
    """Check error after flush does not fault reused entry."""
    dut_if, _ = await setup(dut)
    old = await launch(dut_if, 1, 0x80004000)
    dut_if.drive_flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()
    new = await launch(dut_if, 2, 0x80004080)
    dut_if.drive_mem_response(0xDEADBEEF, cached=True, slot=int(old["id"]), error=True)
    await Timer(1, unit="ns")
    assert not bool(dut.o_l0_fill.value)
    await dut_if.step()
    dut_if.clear_mem_response()
    for _ in range(5):
        await dut_if.step()
        assert not dut_if.read_fu_complete().valid
    dut_if.drive_mem_response(0x4567, cached=True, slot=int(new["id"]))
    await dut_if.step()
    dut_if.clear_mem_response()
    result = await wait_for_fu_complete(dut_if)
    assert (
        result.valid
        and result.tag == 2
        and not result.exception
        and result.value == 0x4567
    )

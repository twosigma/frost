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

"""CPU retirement integration for variable-latency uncached bus responses."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from .test_tomasulo_wrapper import (
    setup_test,
    make_store_req,
    issue_sw_via_mem_rs,
    OP_LR_W,
    OP_LW,
    OP_SC_W,
    OP_SW,
    AllocationRequest,
    RS_MEM,
)


async def no_commit(dut_if: Any, cycles: int) -> None:
    """Check that retirement remains blocked."""
    for _ in range(cycles):
        await dut_if.step()
        assert not dut_if.read_commit()["valid"]
        assert not dut_if.read_commit_2()["valid"]


async def wait_write(dut_if: Any, address: int) -> None:
    """Wait for a store and check its address and transfer size."""
    for _ in range(40):
        await Timer(1, unit="ns")
        req = dut_if.read_sq_mem_write()
        if req["en"]:
            assert req["addr"] == address
            assert not dut_if.read_commit()["valid"]
            await dut_if.step()
            return
        assert not dut_if.read_commit()["valid"]
        await dut_if.step()
    raise AssertionError("Uncached store did not issue")


async def finish(dut_if: Any, tag: int, error: bool) -> None:
    """Complete the operation and check retirement."""
    dut = dut_if.dut
    dut.i_sq_mem_write_error.value = int(error)
    dut_if.drive_sq_mem_write_done()
    await dut_if.step()
    dut_if.clear_sq_mem_write_done()
    dut.i_sq_mem_write_error.value = 0
    for _ in range(20):
        commit = dut_if.read_commit()
        if error:
            assert not commit["valid"], "Faulting store retired"
            if bool(dut.o_trap_pending.value):
                assert int(dut.o_head_tag.value) == tag
                assert int(dut.o_trap_cause.value) == 7
                assert int(dut.o_trap_value.value) == 0
                return
        elif commit["valid"]:
            assert commit["tag"] == tag
            assert commit["value"] == 0
            return
        await dut_if.step()
    raise AssertionError("No retirement or precise store access fault")


@cocotb.test()
async def test_uncached_store_waits_for_bus_response(dut: Any) -> None:
    """Check uncached store waits for bus response."""
    dut_if, _ = await setup_test(dut)
    for address, error in ((0x40000000, False), (0x40000008, True), (0x1000, True)):
        await dut_if.reset_dut()
        dut_if.set_fu_ready(RS_MEM, True)
        tag = await dut_if.dispatch(make_store_req(pc=0x100))
        await issue_sw_via_mem_rs(dut_if, tag, address, 0x12345678)
        await no_commit(dut_if, 6)
        assert bool(dut.o_uncached_store_pending.value)
        assert not dut_if.read_sq_mem_write()["en"]
        dut.i_uncached_store_shield.value = 1
        await wait_write(dut_if, address)
        await no_commit(dut_if, 25)
        await finish(dut_if, tag, error)


async def start_memory_op(
    dut_if: Any, req: Any, op: Any, address: int, data: int = 0
) -> Any:
    """Dispatch a memory operation with its address and data."""
    tag = await dut_if.dispatch(req)
    dut_if.drive_rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag,
        op=op,
        src1_ready=True,
        src1_value=address,
        src2_ready=True,
        src2_value=data,
        src3_ready=True,
        imm=0,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
        mem_needs_sq=op in (OP_SW, OP_SC_W),
        mem_needs_lq=op in (OP_LR_W, OP_LW),
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()
    return tag


@cocotb.test()
async def test_successful_uncached_sc_waits_for_write_response(dut: Any) -> None:
    """Check successful uncached sc waits for write response."""
    dut_if, _ = await setup_test(dut)
    for error in (False, True):
        await dut_if.reset_dut()
        dut_if.set_fu_ready(RS_MEM, True)
        lr = await start_memory_op(
            dut_if,
            AllocationRequest(pc=0x100, dest_reg=5, dest_valid=True, is_lr=True),
            OP_LR_W,
            0x1000,
        )
        for _ in range(30):
            if dut_if.read_lq_mem_request()["en"]:
                break
            await dut_if.step()
        assert dut_if.read_lq_mem_request()["en"]
        await dut_if.step()
        dut_if.drive_lq_mem_response(0x1234)
        await dut_if.step()
        dut_if.clear_lq_mem_response()
        for _ in range(20):
            if dut_if.read_commit()["valid"]:
                assert dut_if.read_commit()["tag"] == lr
                break
            await dut_if.step()
        else:
            raise AssertionError("LR did not retire")
        await dut_if.step()
        sc = await start_memory_op(
            dut_if,
            AllocationRequest(
                pc=0x104, dest_reg=6, dest_valid=True, is_sc=True, is_store=True
            ),
            OP_SC_W,
            0x1000,
            0x5678,
        )
        dut.i_uncached_store_shield.value = 1
        await wait_write(dut_if, 0x1000)
        await no_commit(dut_if, 20)
        await finish(dut_if, sc, error)


@cocotb.test()
async def test_store_response_contends_with_staged_load(dut: Any) -> None:
    """A store B response owns MEM before a simultaneous cached-load result."""
    dut_if, _ = await setup_test(dut)
    dut_if.set_fu_ready(RS_MEM, True)
    st = await dut_if.dispatch(make_store_req(pc=0x100))
    await issue_sw_via_mem_rs(dut_if, st, 0x40000000, 0x12)
    ld = await start_memory_op(
        dut_if,
        AllocationRequest(pc=0x104, dest_reg=5, dest_valid=True),
        OP_LW,
        0x80001000,
    )
    for _ in range(40):
        if dut_if.read_lq_mem_request()["en"]:
            break
        await dut_if.step()
    else:
        raise AssertionError("Younger cached load did not issue")
    slot = dut_if.read_lq_mem_request()["id"]
    await dut_if.step()
    dut.i_uncached_store_shield.value = 1
    await wait_write(dut_if, 0x40000000)
    dut_if.drive_lq_mem_response(0x5A, cached=True, slot=slot)
    dut_if.drive_sq_mem_write_done()
    await dut_if.step()
    dut_if.clear_lq_mem_response()
    dut_if.clear_sq_mem_write_done()
    broadcasts = []
    collisions = 0
    for _ in range(25):
        await Timer(1, unit="ns")
        store_result = int(dut.uncached_store_complete.value)
        store_valid = store_result >> (len(dut.uncached_store_complete) - 1)
        if store_valid and int(dut.lq_fu_complete_staged.value):
            collisions += 1
            assert not int(dut.mem_rs_early_load_injected.value)
            assert not int(dut.lq_result_accepted.value)
        cdb = dut_if.read_cdb_output()
        if cdb.valid:
            broadcasts.append((cdb.tag, cdb.value))
        await dut_if.step()
    assert collisions, "Test did not overlap the two completion sources"
    assert broadcasts == [(st, 0), (ld, 0x5A)]

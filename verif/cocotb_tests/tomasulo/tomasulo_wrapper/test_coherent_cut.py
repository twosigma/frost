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

"""The coherent cut covers returned observations and delayed cached responses."""

from typing import Any

import cocotb

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import AllocationRequest
from cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_coherence import (
    LINE,
    SLOT,
    WORD,
    _mem_rs,
    _admit_now,
    _invalidate_now,
    _release,
)
from cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper import (
    OP_LR_W,
    OP_LW,
    OP_SW,
    RS_MEM,
    make_int_req,
    make_store_req,
    setup_test,
    wait_for_cdb,
)
from cocotb_tests.tomasulo.tomasulo_wrapper.tomasulo_interface import TomasuloInterface


async def issue(
    dut_if: TomasuloInterface, tag: int, op: int, address: int, value: int = 0
) -> None:
    """Send a memory operation with ready operands to the reservation station."""
    dut_if.drive_rs_dispatch(**_mem_rs(tag, op, address, value))
    await dut_if.step()
    dut_if.clear_rs_dispatch()


async def request(dut_if: TomasuloInterface) -> dict:
    """Return the launched read and its cached slot after a bounded wait."""
    for _ in range(30):
        req = dut_if.read_lq_mem_request()
        if req["en"]:
            return req
        await dut_if.step()
    raise AssertionError("read did not launch")


async def cut(dut: Any, dut_if: TomasuloInterface) -> None:
    """Capture hold precedes admission and remains asserted through invalidation."""
    dut.i_coherent_cut_hold.value = 1
    await _admit_now(dut, dut_if)
    assert int(dut.i_coherent_cut_hold.value)
    await _invalidate_now(dut, dut_if, require_cut_hold=True)
    dut.i_coherent_cut_hold.value = 0
    await _release(dut, dut_if)


@cocotb.test()
async def returned_l1_and_l0_observations(dut: Any) -> None:
    """Both returned L1 values and L0 hits remain replayable after LQ release."""
    dut_if, _ = await setup_test(dut)
    dut.i_coherent_store_ready.value = 1
    dut_if.set_fu_ready(RS_MEM, True)
    dut_if.set_commit_hold(True)
    first = await dut_if.dispatch(make_int_req(pc=0x3000, rd=5))
    await issue(dut_if, first, OP_LW, WORD)
    req = await request(dut_if)
    await dut_if.step()
    dut_if.drive_lq_mem_response(0x11223344, cached=True, slot=req["id"])
    cdb = await wait_for_cdb(dut_if)
    assert cdb.tag == first and cdb.value == 0x11223344
    dut_if.clear_lq_mem_response()
    for _ in range(5):
        await dut_if.step()
    second = await dut_if.dispatch(make_int_req(pc=0x3004, rd=6))
    await issue(dut_if, second, OP_LW, WORD)
    for _ in range(30):
        assert not dut_if.read_lq_mem_request()["en"]
        cdb = dut_if.read_cdb_output()
        if cdb.valid and cdb.tag == second:
            assert cdb.value == 0x11223344
            break
        await dut_if.step()
    else:
        raise AssertionError("L0 hit did not return")
    for _ in range(5):
        await dut_if.step()
    assert int(dut.o_lq_count.value) == 0
    await cut(dut, dut_if)
    replay = int(dut.u_rob.rob_replay.value)
    assert replay & (1 << first) and replay & (1 << second)


@cocotb.test()
async def returned_forward_observation(dut: Any) -> None:
    """Check the coherent cut of a returned SQ forwarding value."""
    dut_if, _ = await setup_test(dut)
    dut.i_coherent_store_ready.value = 1
    dut_if.set_fu_ready(RS_MEM, True)
    dut_if.set_commit_hold(True)
    store = await dut_if.dispatch(make_store_req(pc=0x4000))
    await issue(dut_if, store, OP_SW, WORD, 0x55667788)
    for _ in range(8):
        await dut_if.step()
    load = await dut_if.dispatch(make_int_req(pc=0x4004, rd=7))
    await issue(dut_if, load, OP_LW, WORD)
    for _ in range(30):
        assert not dut_if.read_lq_mem_request()["en"]
        cdb = dut_if.read_cdb_output()
        if cdb.valid and cdb.tag == load:
            assert cdb.value == 0x55667788
            break
        await dut_if.step()
    else:
        raise AssertionError("forwarded value did not return")
    await cut(dut, dut_if)
    assert int(dut.u_rob.rob_replay.value) & (1 << load)


@cocotb.test()
async def delayed_lr_cannot_reserve_or_fill_after_cut(dut: Any) -> None:
    """Check reservation and L0 suppression for delayed LR responses."""
    dut_if, _ = await setup_test(dut)
    for delay in (0, 1, 4, 11):
        await dut_if.reset_dut()
        dut.i_coherent_store_ready.value = 1
        dut.i_coherent_cut_hold.value = 0
        dut_if.set_fu_ready(RS_MEM, True)
        dut_if.set_commit_hold(True)
        lr = await dut_if.dispatch(
            AllocationRequest(pc=0x5000, dest_reg=5, dest_valid=True, is_lr=True)
        )
        await issue(dut_if, lr, OP_LR_W, WORD)
        req = await request(dut_if)
        await dut_if.step()
        await cut(dut, dut_if)
        for _ in range(delay):
            await dut_if.step()
        dut_if.drive_lq_mem_response(0x12345678, cached=True, slot=req["id"])
        await dut_if.step()
        dut_if.clear_lq_mem_response()
        for _ in range(8):
            await dut_if.step()
            assert not int(dut.o_coherent_reservation_valid.value)
        assert int(dut.u_rob.rob_replay.value) & (1 << lr)
        load = await dut_if.dispatch(make_int_req(pc=0x5004, rd=6))
        await issue(dut_if, load, OP_LW, WORD)
        fresh = await request(dut_if)
        assert fresh["addr"] == WORD
        await dut_if.step()
        dut_if.drive_lq_mem_response(0xCAFEBABE, cached=True, slot=fresh["id"])
        await wait_for_cdb(dut_if)
        dut_if.clear_lq_mem_response()


@cocotb.test()
async def responses_cross_each_cut_edge(dut: Any) -> None:
    """Responses at capture, invalidation, compare and replay cannot escape poison."""
    dut_if, _ = await setup_test(dut)
    for is_lr in (False, True):
        for response_phase in (0, 1, 2, 3):
            await dut_if.reset_dut()
            dut.i_coherent_store_ready.value = 1
            dut.i_coherent_cut_hold.value = 0
            dut_if.set_fu_ready(RS_MEM, True)
            dut_if.set_commit_hold(True)
            tag = await dut_if.dispatch(
                AllocationRequest(pc=0x5800, dest_reg=5, dest_valid=True, is_lr=is_lr)
            )
            await issue(dut_if, tag, OP_LR_W if is_lr else OP_LW, WORD)
            req = await request(dut_if)
            await dut_if.step()
            dut.i_coherent_cut_hold.value = 1
            if response_phase == 0:
                dut_if.drive_lq_mem_response(0x12345678, cached=True, slot=req["id"])
            await dut_if.step()
            dut_if.clear_lq_mem_response()
            await _admit_now(dut, dut_if)
            dut.i_coh_inval_valid.value = 1
            dut.i_coh_inval_slot.value = SLOT
            returned = response_phase == 0
            for _ in range(12):
                phase = int(dut.u_coherence_port.inval_phase_q.value)
                if response_phase != 0 and phase == response_phase:
                    dut_if.drive_lq_mem_response(
                        0x12345678, cached=True, slot=req["id"]
                    )
                    returned = True
                await dut_if.step()
                dut_if.clear_lq_mem_response()
                if phase == 3:
                    break
            else:
                raise AssertionError("invalidation did not reach the replay edge")
            dut.i_coh_inval_valid.value = 0
            await dut_if.step()
            assert returned
            assert int(dut.u_rob.rob_replay.value) & (1 << tag)
            dut.i_coherent_cut_hold.value = 0
            await _release(dut, dut_if)
            for _ in range(8):
                await dut_if.step()
                assert not int(dut.o_coherent_reservation_valid.value)
                assert int(dut.u_rob.rob_replay.value) & (1 << tag)
            following = await dut_if.dispatch(make_int_req(pc=0x5804, rd=6))
            await issue(dut_if, following, OP_LW, WORD)
            fresh = await request(dut_if)
            assert fresh["addr"] == WORD
            await dut_if.step()
            dut_if.drive_lq_mem_response(0xCAFEBABE, cached=True, slot=fresh["id"])
            cdb = await wait_for_cdb(dut_if)
            assert cdb.tag == following and cdb.value == 0xCAFEBABE
            dut_if.clear_lq_mem_response()


@cocotb.test()
async def pending_store_blocks_same_sector_but_not_other_reads(dut: Any) -> None:
    """Check the pending-store interlock and unrelated-load progress."""
    dut_if, _ = await setup_test(dut)
    dut.i_coherent_store_ready.value = 0
    dut.i_coherent_store_pending.value = 1
    dut.i_coherent_block_valid.value = 1
    dut.i_coherent_block_addr.value = LINE
    dut_if.set_fu_ready(RS_MEM, True)
    dut_if.set_commit_hold(True)
    blocked = await dut_if.dispatch(make_int_req(pc=0x6000, rd=5))
    await issue(dut_if, blocked, OP_LW, WORD)
    for _ in range(8):
        await dut_if.step()
        assert not dut_if.read_lq_mem_request()["en"]
    other = await dut_if.dispatch(make_int_req(pc=0x6004, rd=6))
    await issue(dut_if, other, OP_LW, LINE + 64)
    req = await request(dut_if)
    assert req["addr"] == LINE + 64
    assert not int(dut.o_sq_committed_empty_trap.value)
    dut.i_coherent_store_pending.value = 0
    dut.i_coherent_block_valid.value = 0
    dut.i_coherent_store_ready.value = 1


@cocotb.test()
async def device_publication_waits_for_coherent_writes(dut: Any) -> None:
    """Check Device publication against both coherent write-drain owners."""
    dut_if, _ = await setup_test(dut)
    for sc_pending in (0, 1):
        await dut_if.reset_dut()
        dut.i_coherent_store_ready.value = 1
        dut.i_coherent_store_pending.value = 1 - sc_pending
        dut.i_coherent_sc_pending.value = sc_pending
        dut.i_coherent_block_valid.value = 0
        dut_if.set_fu_ready(RS_MEM, True)
        tag = await dut_if.dispatch(make_store_req(pc=0x7000))
        await issue(dut_if, tag, OP_SW, 0x40000010, 0x12345678)
        for _ in range(6):
            await dut_if.step()
        for _ in range(20):
            assert not dut_if.read_sq_mem_write()["en"]
            assert not dut_if.sq_committed_empty
            assert not int(dut.o_sq_committed_empty_trap.value)
            await dut_if.step()
        dut.i_coherent_store_pending.value = 0
        dut.i_coherent_sc_pending.value = 0
        for _ in range(30):
            write = dut_if.read_sq_mem_write()
            if write["en"]:
                assert write["addr"] == 0x40000010
                assert write["data"] & 0xFFFFFFFF == 0x12345678
                break
            await dut_if.step()
        else:
            raise AssertionError(
                "Device write did not drain after coherent publication"
            )
        await dut_if.step()
        dut_if.drive_sq_mem_write_done()
        await dut_if.step()
        dut_if.clear_sq_mem_write_done()

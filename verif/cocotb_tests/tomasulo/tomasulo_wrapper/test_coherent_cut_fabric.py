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

"""Private P/R service composes with CPU observations, reservations and replay."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack
from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import AllocationRequest
from cocotb_tests.tomasulo.tomasulo_wrapper.test_coherent_cut import issue, request
from cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_coherence import LINE, WORD
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


class Fabric:
    """Drive a real private probe slot and the CPU's independent read responses."""

    def __init__(self, dut: Any, interface: TomasuloInterface) -> None:
        """Record the two endpoints and the next probe identity."""
        self.dut = dut
        self.interface = interface
        self.tid = 1

    def get(self, name: str) -> int:
        """Read a top-level signal."""
        return int(getattr(self.dut, name).value)

    async def wait(self, name: str) -> None:
        """Wait for a ready or valid signal with a fixed bound."""
        for _ in range(100):
            await Timer(1, unit="ps")
            if self.get(name):
                return
            assert not self.get("o_cache_fatal")
            await self.interface.step()
        raise AssertionError(f"{name} did not assert")

    async def seed(self) -> int:
        """Install a modified line through its full request and completion lifetime."""
        d = self.dut
        b = self.interface
        pattern = int.from_bytes(bytes(range(32)), "little")
        stored = 0xFEDCBA9876543210
        d.i_seed_addr.value = LINE
        d.i_seed_mask.value = 255
        d.i_seed_data.value = stored
        await b.step()
        d.i_seed_mask.value = 0
        await self.wait("o_cache_d_valid")
        demand = unpack(self.get("o_cache_d"), (4, 9, 32, 5, 3, 32, 1, 1, 1, 256))
        d.i_cache_d_ready.value = 1
        await b.step()
        d.i_cache_d_ready.value = 0
        d.i_cache_g.value = pack(
            (3, 2), (9, demand[1]), (6, 0), (32, LINE), (256, pattern), (1, 0)
        )
        d.i_cache_g_valid.value = 1
        await self.wait("o_cache_g_ready")
        await b.step()
        d.i_cache_g_valid.value = 0
        await self.wait("o_cache_c_valid")
        d.i_cache_c_ready.value = 1
        await b.step()
        d.i_cache_c_ready.value = 0
        d.i_cache_u.value = pack((9, demand[1]), (6, 0), (32, LINE))
        d.i_cache_u_valid.value = 1
        await self.wait("o_cache_u_ready")
        await b.step()
        d.i_cache_u_valid.value = 0
        for _ in range(4):
            await b.step()
        assert not self.get("o_cache_pending")
        return (pattern & ~((1 << 64) - 1)) | stored

    async def cut(
        self, response: dict | None = None, phase: int = -1, replay_mask: int = 0
    ) -> tuple[int, ...]:
        """Invalidate through P/R, with delayed cut service and a held complete reply."""
        d = self.dut
        b = self.interface
        d.i_probe_delay_admit.value = 1
        d.i_probe_delay_inval.value = 1
        d.i_reply_ready.value = 0
        d.i_probe.value = pack(
            (2, 1),
            (6, self.tid),
            (1, 0),
            (32, LINE),
            (2, 2),
            (2, 1),
            (9, 0),
            (5, 0),
            (3, 0),
        )
        d.i_probe_valid.value = 1
        await self.wait("o_probe_ready")
        assert self.get("o_probe_cut_hold")
        assert self.get("o_probe_cut_addr") == LINE
        returned = False
        if response is not None and phase == 0:
            b.drive_lq_mem_response(0x12345678, cached=True, slot=response["id"])
            returned = True
        await b.step()
        b.clear_lq_mem_response()
        d.i_probe_valid.value = 0
        for _ in range(5):
            assert self.get("o_probe_cut_hold") and not self.get("o_reply_valid")
            if response is not None:
                assert not self.get("o_coherent_reservation_valid")
            await b.step()
        d.i_probe_delay_admit.value = 0
        await self.wait("o_probe_cut_inval")
        for _ in range(5):
            assert self.get("o_probe_cut_hold") and not self.get("o_reply_valid")
            if response is not None:
                assert not self.get("o_coherent_reservation_valid")
            await b.step()
        d.i_probe_delay_inval.value = 0
        for _ in range(30):
            cut_phase = int(d.core.u_coherence_port.inval_phase_q.value)
            if response is not None and phase == cut_phase and not returned:
                b.drive_lq_mem_response(0x12345678, cached=True, slot=response["id"])
                returned = True
            if self.get("o_reply_valid"):
                break
            await b.step()
            b.clear_lq_mem_response()
        else:
            raise AssertionError("probe reply did not follow invalidation")
        assert returned == (response is not None)
        assert int(d.core.u_rob.rob_replay.value) & replay_mask == replay_mask
        payload = self.get("o_reply")
        fields = unpack(payload, (2, 6, 1, 1, 32, 2, 1, 1, 256, 1, 1, 1, 1, 1))
        assert fields[1] == self.tid and fields[4] == LINE and not fields[-1]
        for _ in range(8):
            assert self.get("o_reply_valid") and self.get("o_reply") == payload
            assert not self.get("o_probe_ready") and not self.get("o_probe_cut_release")
            await b.step()
        d.i_reply_ready.value = 1
        await b.step()
        assert self.get("o_probe_cut_release")
        d.i_reply_ready.value = 0
        await b.step()
        self.tid += 1
        return fields


async def prepare(dut: Any) -> tuple[TomasuloInterface, Fabric]:
    """Reset both endpoints with empty protocol channels."""
    for name in (
        "i_probe_valid",
        "i_probe",
        "i_reply_ready",
        "i_probe_delay_admit",
        "i_probe_delay_inval",
        "i_seed_addr",
        "i_seed_mask",
        "i_seed_data",
        "i_cache_d_ready",
        "i_cache_g_valid",
        "i_cache_g",
        "i_cache_c_ready",
        "i_cache_u_valid",
        "i_cache_u",
    ):
        getattr(dut, name).value = 0
    interface, _ = await setup_test(dut)
    dut.i_coherent_store_ready.value = 1
    interface.set_fu_ready(RS_MEM, True)
    interface.set_commit_hold(True)
    for _ in range(25):
        await interface.step()
    return interface, Fabric(dut, interface)


@cocotb.test()
async def dirty_invalidate_replays_returned_l1_and_l0(dut: Any) -> None:
    """Check that a dirty reply waits for two returned observations."""
    b, f = await prepare(dut)
    expected = await f.seed()
    first = await b.dispatch(make_int_req(pc=0x3000, rd=5))
    await issue(b, first, OP_LW, WORD)
    req = await request(b)
    await b.step()
    b.drive_lq_mem_response(0x11223344, cached=True, slot=req["id"])
    cdb = await wait_for_cdb(b)
    assert cdb.tag == first and cdb.value == 0x11223344
    b.clear_lq_mem_response()
    for _ in range(5):
        await b.step()
    second = await b.dispatch(make_int_req(pc=0x3004, rd=6))
    await issue(b, second, OP_LW, WORD)
    for _ in range(30):
        assert not b.read_lq_mem_request()["en"]
        cdb = b.read_cdb_output()
        if cdb.valid and cdb.tag == second:
            assert cdb.value == 0x11223344
            break
        await b.step()
    else:
        raise AssertionError("L0 hit did not return")
    for _ in range(5):
        await b.step()
    assert int(dut.o_lq_count.value) == 0
    reply = await f.cut(replay_mask=(1 << first) | (1 << second))
    assert reply[7] and reply[8] == expected
    replay = int(dut.core.u_rob.rob_replay.value)
    assert replay & (1 << first) and replay & (1 << second)
    reply = await f.cut()
    assert not reply[7]


@cocotb.test()
async def returned_forward_and_flushed_tag_reuse(dut: Any) -> None:
    """Cut a returned SQ observation and check a flushed tag replacement."""
    b, f = await prepare(dut)
    store = await b.dispatch(make_store_req(pc=0x4000))
    await issue(b, store, OP_SW, WORD, 0x55667788)
    for _ in range(8):
        await b.step()
    load = await b.dispatch(make_int_req(pc=0x4004, rd=7))
    await issue(b, load, OP_LW, WORD)
    for _ in range(30):
        assert not b.read_lq_mem_request()["en"]
        cdb = b.read_cdb_output()
        if cdb.valid and cdb.tag == load:
            assert cdb.value == 0x55667788
            break
        await b.step()
    else:
        raise AssertionError("forwarded value did not return")
    await f.cut(replay_mask=1 << load)
    assert int(dut.core.u_rob.rob_replay.value) & (1 << load)
    b.drive_flush_en(store)
    await b.step()
    b.clear_flush_en()
    await b.step()
    replacement = await b.dispatch(make_int_req(pc=0x4008, rd=8))
    assert replacement == load
    await f.cut()
    assert not int(dut.core.u_rob.rob_replay.value) & (1 << replacement)


@cocotb.test()
async def response_edges_and_delayed_lr(dut: Any) -> None:
    """Check reservation and L0 suppression across every response edge."""
    b, f = await prepare(dut)
    for is_lr in (False, True):
        for phase in (0, 1, 2, 3, 4):
            await b.reset_dut()
            dut.i_coherent_store_ready.value = 1
            b.set_fu_ready(RS_MEM, True)
            b.set_commit_hold(True)
            for _ in range(25):
                await b.step()
            expected = await f.seed()
            tag = await b.dispatch(
                AllocationRequest(pc=0x5000, dest_reg=5, dest_valid=True, is_lr=is_lr)
            )
            await issue(b, tag, OP_LR_W if is_lr else OP_LW, WORD)
            req = await request(b)
            await b.step()
            reply = await f.cut(
                req if phase < 4 else None,
                phase,
                replay_mask=(1 << tag) if phase < 4 else 0,
            )
            assert reply[7] and reply[8] == expected
            if phase == 4:
                for _ in range(11):
                    await b.step()
                b.drive_lq_mem_response(0x12345678, cached=True, slot=req["id"])
                await b.step()
                b.clear_lq_mem_response()
            for _ in range(8):
                await b.step()
                assert not int(dut.o_coherent_reservation_valid.value)
            assert int(dut.core.u_rob.rob_replay.value) & (1 << tag)
            following = await b.dispatch(make_int_req(pc=0x5004, rd=6))
            await issue(b, following, OP_LW, WORD)
            fresh = await request(b)
            assert fresh["addr"] == WORD
            await b.step()
            b.drive_lq_mem_response(0xCAFEBABE, cached=True, slot=fresh["id"])
            cdb = await wait_for_cdb(b)
            assert cdb.tag == following and cdb.value == 0xCAFEBABE
            b.clear_lq_mem_response()


@cocotb.test()
async def both_retire_lanes_clear_observations(dut: Any) -> None:
    """Check that both retirement lanes clear their load observations."""
    b, f = await prepare(dut)
    tags = []
    for index in range(2):
        tag = await b.dispatch(make_int_req(pc=0x6000 + 4 * index, rd=5 + index))
        tags.append(tag)
        await issue(b, tag, OP_LW, WORD + 32 * index)
        req = await request(b)
        await b.step()
        b.drive_lq_mem_response(0x12345678, cached=True, slot=req["id"])
        cdb = await wait_for_cdb(b)
        assert cdb.tag == tag
        b.clear_lq_mem_response()
        for _ in range(5):
            await b.step()
    observed = int(dut.core.u_coherence_port.obs_valid_q.value)
    assert all(observed & (1 << tag) for tag in tags)
    b.set_widen_commit_ok(True)
    b.set_commit_hold(False)
    for _ in range(10):
        await Timer(1, unit="ps")
        commits = (b.read_commit(), b.read_commit_2())
        if all(c["valid"] for c in commits):
            assert [c["tag"] for c in commits] == tags
            await b.step()
            break
        await b.step()
    else:
        raise AssertionError("both retirement lanes did not fire")
    b.set_commit_hold(True)
    for _ in range(5):
        await b.step()
    observed = int(dut.core.u_coherence_port.obs_valid_q.value)
    assert all(not observed & (1 << tag) for tag in tags)
    await f.cut()
    replay = int(dut.core.u_rob.rob_replay.value)
    assert all(not replay & (1 << tag) for tag in tags)

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

"""Compose speculative private fills with architectural load observations."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack
from cocotb_tests.tomasulo.tomasulo_wrapper.test_coherent_cut import issue
from cocotb_tests.tomasulo.tomasulo_wrapper.test_coherent_cut_fabric import Fabric
from cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper import (
    OP_LW,
    RS_MEM,
    make_int_req,
)
from cocotb_tests.tomasulo.tomasulo_wrapper.tomasulo_interface import TomasuloInterface


class StreamInterface(TomasuloInterface):
    """Observe real cache requests and CDB values while stepping the CPU fixture."""

    def __init__(self, dut: Any) -> None:
        """Initialize transaction and architectural response records."""
        super().__init__(dut)
        self.requests: list[tuple[int, tuple[int, ...]]] = []
        self.values: dict[int, int] = {}
        self.commits: list[dict[str, Any]] = []

    async def step(self) -> None:
        """Sample offers before the edge and advance one CPU cycle."""
        await Timer(1, unit="ps")
        d = self.dut
        if int(d.i_rst_n.value):
            valid = int(d.o_cache_d_valid.value) & int(d.i_cache_d_ready.value)
            for ep in range(len(d.o_cache_d_valid)):
                if valid >> ep & 1:
                    bits = (int(d.o_cache_d.value) >> (344 * ep)) & ((1 << 344) - 1)
                    self.requests.append(
                        (ep, unpack(bits, (4, 9, 32, 5, 3, 32, 1, 1, 1, 256)))
                    )
            cdb = self.read_cdb_output()
            if cdb.valid:
                self.values[cdb.tag] = cdb.value
            for commit in (self.read_commit(), self.read_commit_2()):
                if commit["valid"]:
                    self.commits.append(commit)
        await super().step()

    async def wait_request(self, address: int, after: int = -1) -> int:
        """Find the accepted request for a sector within a bounded interval."""
        for _ in range(150):
            for index, (_, fields) in enumerate(self.requests):
                if index > after and fields[2] == address:
                    return index
            await self.step()
        raise AssertionError(f"No request for {address:x}: {self.requests}")

    async def complete(self, index: int, value: int) -> None:
        """Supply G and complete C/U before ordering a writer to the same sector."""
        d = self.dut
        ep, fields = self.requests[index]
        d.i_cache_g.value = pack(
            (3, 0), (9, fields[1]), (6, index), (32, fields[2]), (256, value), (1, 0)
        )
        d.i_cache_g_valid.value = 1
        for _ in range(100):
            await Timer(1, unit="ps")
            if int(d.o_cache_g_ready.value):
                break
            await self.step()
        else:
            raise AssertionError("Grant did not become ready")
        await self.step()
        d.i_cache_g_valid.value = 0
        for _ in range(100):
            if int(d.o_cache_c_valid.value) >> ep & 1:
                break
            await self.step()
        else:
            raise AssertionError("Grant did not complete")
        d.i_cache_c_ready.value = 1 << ep
        await self.step()
        d.i_cache_c_ready.value = 0
        d.i_cache_u.value = pack((9, fields[1]), (6, index), (32, fields[2]))
        d.i_cache_u_valid.value = 1
        for _ in range(100):
            await Timer(1, unit="ps")
            if int(d.o_cache_u_ready.value):
                break
            await self.step()
        else:
            raise AssertionError("Completion did not release")
        await self.step()
        d.i_cache_u_valid.value = 0

    async def wait_value(self, tag: int, value: int) -> None:
        """Require a CDB response from the requested load."""
        for _ in range(100):
            if tag in self.values:
                assert self.values[tag] == value
                return
            await self.step()
        raise AssertionError(f"No CDB response for {tag}")


async def prepare_stream(dut: Any) -> tuple[StreamInterface, Fabric, list[int]]:
    """Reset the connected cache and train a stream with three real CPU loads."""
    for signal in dut:
        if signal._name.startswith(("i_cache_", "i_probe_", "i_seed_", "i_reply_")):
            signal.value = 0
    b = StreamInterface(dut)
    await b.reset_dut()
    b.set_fu_ready(RS_MEM, True)
    b.set_commit_hold(True)
    dut.i_coherent_store_ready.value = 1
    dut.i_cache_d_ready.value = 255
    for _ in range(25):
        await b.step()
    tags = []
    for n in range(3):
        tag = await b.dispatch(make_int_req(pc=0x3000 + 4 * n, rd=5 + n))
        tags.append(tag)
        await issue(b, tag, OP_LW, 0x80004000 + n * 32)
    await b.wait_request(0x80004060)
    return b, Fabric(dut, b), tags


@cocotb.test()
async def speculative_residency_is_invalidated_by_clean_cut(dut: Any) -> None:
    """Invalidate a purely speculative Shared line even when the CPU answers clean."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b, f, _ = await prepare_stream(dut)
    address = 0x80004060
    hint = await b.wait_request(address)
    assert int(dut.cache.ld_prefetch_q.value) >> b.requests[hint][0] & 1
    await b.complete(hint, 0)
    reply = await f.cut(address=address, clean=True)
    assert reply[5] == 0 and not reply[7]
    tag = await b.dispatch(make_int_req(pc=0x300C, rd=8))
    await issue(b, tag, OP_LW, address)
    demand = await b.wait_request(address, after=hint)
    await b.complete(demand, 1)
    await b.wait_value(tag, 1)


@cocotb.test()
async def younger_old_and_older_new_replay(dut: Any) -> None:
    """Replay a younger old observation before it can retire after an older fresh load."""
    Clock(dut.i_clk, 10, unit="ns").start()
    for held in (False, True):
        b, f, seeds = await prepare_stream(dut)
        address = 0x80004060
        hint = await b.wait_request(address)
        older = await b.dispatch(make_int_req(pc=0x4000, rd=8))
        younger = await b.dispatch(make_int_req(pc=0x4004, rd=9))
        await issue(b, younger, OP_LW, address)
        for _ in range(20):
            await b.step()
        assert int(dut.cache.rd_wait_q.value)
        dut.i_cache_read_hold.value = int(held)
        await b.complete(hint, 0)
        if not held:
            await b.wait_value(younger, 0)
        else:
            for _ in range(40):
                if int(dut.cache_read_valid.value):
                    break
                await b.step()
            assert int(dut.cache_read_valid.value)
        reply = await f.cut(address=address, replay_mask=1 << younger, clean=False)
        assert reply[5] == 0
        await issue(b, older, OP_LW, address)
        dut.i_cache_read_hold.value = 0
        demand = await b.wait_request(address, after=hint)
        await b.complete(demand, 1)
        await b.wait_value(older, 1)
        assert int(dut.core.u_rob.rob_replay.value) & (1 << younger)
        for index, tag in enumerate(seeds):
            seed = await b.wait_request(0x80004000 + 32 * index)
            await b.complete(seed, index + 3)
            await b.wait_value(tag, index + 3)
        b.set_commit_hold(False)
        for _ in range(30):
            await b.step()
        assert any(c["tag"] == older for c in b.commits)
        assert all(c["tag"] != younger for c in b.commits)
        b.set_commit_hold(True)
        b.drive_flush_all()
        await b.step()
        b.clear_flush_all()
        await b.step()
        for n in range(8):
            replacement = await b.dispatch(make_int_req(pc=0x5000 + 4 * n, rd=10 + n))
            if replacement == younger:
                break
        else:
            raise AssertionError("Flushed observation tag was not reused")
        await f.cut(address=address, clean=False)
        assert not int(dut.core.u_rob.rob_replay.value) & (1 << replacement)

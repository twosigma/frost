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
    OP_LR_W,
    OP_LW,
    RS_MEM,
    _INSTR_OPS,
    make_branch_req,
    make_int_req,
)
from cocotb_tests.tomasulo.tomasulo_wrapper.tomasulo_interface import (
    AllocationRequest,
    TomasuloInterface,
)


class StreamInterface(TomasuloInterface):
    """Observe real cache requests and CDB values while stepping the CPU fixture."""

    def __init__(self, dut: Any) -> None:
        """Initialize transaction and architectural response records."""
        super().__init__(dut)
        self.requests: list[tuple[int, tuple[int, ...]]] = []
        self.values: dict[int, int] = {}
        self.commits: list[dict[str, Any]] = []
        self.merged_attaches = 0
        self.grant_answers = 0

    async def step(self) -> None:
        """Sample offers before the edge and advance one CPU cycle."""
        await Timer(1, unit="ps")
        d = self.dut
        if int(d.i_rst_n.value):
            self.merged_attaches |= int(d.cache.merge_attach_slots.value)
            self.grant_answers |= int(d.cache.grant_answer_slots.value)
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


@cocotb.test()
async def attached_lr_response_cut_suppresses_reservation(dut: Any) -> None:
    """Suppress an LR reservation when a cut overtakes its held speculative fill response."""
    Clock(dut.i_clk, 10, unit="ns").start()
    b, f, seeds = await prepare_stream(dut)
    address = 0x80004060
    hint = await b.wait_request(address)
    for index, seed_tag in enumerate(seeds):
        seed = await b.wait_request(0x80004000 + 32 * index)
        await b.complete(seed, index + 3)
        await b.wait_value(seed_tag, index + 3)
    b.set_commit_hold(False)
    for _ in range(30):
        if all(any(c["tag"] == seed for c in b.commits) for seed in seeds):
            break
        await b.step()
    else:
        raise AssertionError("Training loads did not retire before LR admission")
    b.set_commit_hold(True)
    tag = await b.dispatch(
        AllocationRequest(pc=0x6000, dest_reg=8, dest_valid=True, is_lr=True)
    )
    await issue(b, tag, OP_LR_W, address)
    for _ in range(20):
        await b.step()
    assert int(dut.cache.rd_wait_q.value)
    dut.i_cache_read_hold.value = 1
    await b.complete(hint, 0x11223344)
    for _ in range(40):
        if int(dut.cache_read_valid.value):
            break
        await b.step()
    else:
        raise AssertionError("Attached LR response was not held")
    await f.cut(address=address, replay_mask=1 << tag, clean=False)
    assert not int(dut.o_coherent_reservation_valid.value)
    dut.i_cache_read_hold.value = 0
    for _ in range(12):
        await b.step()
        assert not int(dut.o_coherent_reservation_valid.value)
    assert int(dut.core.u_rob.rob_replay.value) & (1 << tag)


async def prepare_loads(dut: Any) -> StreamInterface:
    """Reset the real LQ and cache without training a speculative stream."""
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
    return b


@cocotb.test()
async def attached_loads_extract_signed_and_unsigned_values(dut: Any) -> None:
    """Extract signed and unsigned values from attached loads of every aligned offset."""
    Clock(dut.i_clk, 10, unit="ns").start()
    image = bytes((0x80 + 13 * lane) & 255 for lane in range(32))
    load_op = _INSTR_OPS["LOAD"]
    cases = [
        (size, signed, offset)
        for size, signed in (
            (0, True),
            (0, False),
            (1, True),
            (1, False),
            (2, True),
            (2, False),
            (3, False),
        )
        for offset in range(0, 32, 1 << size)
    ]
    for first in range(0, len(cases), 7):
        b = await prepare_loads(dut)
        address = 0x80008000
        owner = await b.dispatch(make_int_req(pc=0x6000, rd=5))
        await issue(b, owner, OP_LW, address)
        request = await b.wait_request(address)
        expected = {}
        batch = cases[first : first + 7]
        tags = [
            await b.dispatch(make_int_req(pc=0x6004 + 4 * n, rd=6 + n))
            for n in range(len(batch))
        ]
        for tag, (size, signed, offset) in zip(tags, batch, strict=True):
            b.drive_rs_dispatch(
                rs_type=RS_MEM,
                rob_tag=tag,
                op=load_op,
                src1_ready=True,
                src1_value=address + offset,
                src2_ready=True,
                src2_value=0,
                src3_ready=True,
                imm=0,
                use_imm=True,
                mem_size=size,
                mem_signed=signed,
            )
            await b.step()
            b.clear_rs_dispatch()
            raw = int.from_bytes(
                image[offset : offset + (1 << size)], "little", signed=signed
            )
            expected[tag] = raw & ((1 << 64) - 1)
        for _ in range(100):
            if int(dut.cache.rd_wait_q.value).bit_count() == len(expected):
                break
            await b.step()
        else:
            raise AssertionError("The same-sector loads did not attach")
        assert len(b.requests) == 1
        assert b.merged_attaches, "No same-sector lookup merged another load"
        await b.complete(request, int.from_bytes(image, "little"))
        for tag, value in expected.items():
            await b.wait_value(tag, value)
        assert b.grant_answers.bit_count() == len(expected) + 1
        assert len(b.requests) == 1


@cocotb.test()
async def flush_attached_loads_before_the_grant(dut: Any) -> None:
    """Drain attached answers after full flush or branch recovery without a killed CDB result."""
    Clock(dut.i_clk, 10, unit="ns").start()
    for partial in (False, True):
        for held_answer in (False, True):
            b = await prepare_loads(dut)
            address = 0x80009000
            owner = await b.dispatch(make_int_req(pc=0x7000, rd=5))
            await issue(b, owner, OP_LW, address)
            request = await b.wait_request(address)
            checkpoint = b.checkpoint_alloc_id
            branch = await b.dispatch(make_branch_req(pc=0x7004), checkpoint_save=True)
            killed = await b.dispatch(make_int_req(pc=0x7008, rd=6))
            await issue(b, killed, OP_LW, address + 8)
            for _ in range(80):
                if int(dut.cache.rd_wait_q.value):
                    break
                await b.step()
            else:
                raise AssertionError("The younger load did not attach")
            assert killed not in b.values
            dut.i_cache_read_hold.value = 1
            if held_answer:
                await b.complete(request, 0x88776655 << 64 | 0x11223344)
            if partial:
                b.drive_flush_en(branch)
                b.drive_checkpoint_restore(checkpoint)
            else:
                b.drive_flush_all()
            await b.step()
            b.clear_flush_en()
            b.clear_flush_all()
            if partial:
                b.clear_checkpoint_restore()
            await b.step()
            if not held_answer:
                await b.complete(request, 0x88776655 << 64 | 0x11223344)
            dut.i_cache_read_hold.value = 0
            for _ in range(50):
                await b.step()
                assert killed not in b.values
                assert not int(dut.o_coherent_reservation_valid.value)
            if partial:
                await b.wait_value(owner, 0x11223344)
            else:
                assert owner not in b.values
            assert int(dut.core.u_lq.cs_valid.value) == 0


@cocotb.test()
async def vector_hold_delays_same_sector_loads(dut: Any) -> None:
    """Release vector-held loads before or after a grant without answering them early."""
    Clock(dut.i_clk, 10, unit="ns").start()
    address = 0x8000A000
    tag_width = len(dut.o_head_tag)
    entry_width = len(dut.i_vmt) // 4
    segment_width = (entry_width - 3 - tag_width) // 2
    ppn_width = segment_width - 15
    for range_known in (False, True):
        for release_before_grant in (False, True):
            b = await prepare_loads(dut)
            owner = await b.dispatch(make_int_req(pc=0x8000, rd=5))
            await issue(b, owner, OP_LW, address)
            request = await b.wait_request(address)
            vector = await b.dispatch(make_int_req(pc=0x8004, rd=6))
            sector = (address >> 5) & 127
            segment = (
                (1 << (14 + ppn_width))
                | ((address >> 12) << 14)
                | (sector << 7)
                | sector
            )
            dut.i_vmt.value = (
                (1 << (entry_width - 1))
                | (vector << (1 + 2 * segment_width))
                | (int(range_known) << (2 * segment_width))
                | segment
            )
            younger = []
            for n in range(2):
                tag = await b.dispatch(make_int_req(pc=0x8008 + 4 * n, rd=7 + n))
                younger.append(tag)
                await issue(b, tag, OP_LW, address + 8 * (n + 1))
            for _ in range(40):
                await b.step()
                assert all(tag not in b.values for tag in younger)
                assert int(dut.cache.rd_wait_q.value) == 0
            assert len(b.requests) == 1
            data = 0x55667788 << 128 | 0x33445566 << 64 | 0x11223344
            if release_before_grant:
                dut.i_vmt.value = 0
                for _ in range(100):
                    if int(dut.cache.rd_wait_q.value).bit_count() == 2:
                        break
                    await b.step()
                else:
                    raise AssertionError("Released vector-held loads did not attach")
            await b.complete(request, data)
            await b.wait_value(owner, 0x11223344)
            if not release_before_grant:
                for _ in range(20):
                    await b.step()
                    assert all(tag not in b.values for tag in younger)
                dut.i_vmt.value = 0
            for tag, value in zip(younger, (0x33445566, 0x55667788), strict=True):
                await b.wait_value(tag, value)
            assert len(b.requests) == 1

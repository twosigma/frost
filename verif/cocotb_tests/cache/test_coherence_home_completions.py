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

"""Completion credits and pins are independent of result presentation."""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_endpoints import Bench, pack
from cocotb_tests.cache.test_coherence_home import unpack


class Completions(Bench):
    """Drive admissions, execution results and delayed requesters."""

    def __init__(self, dut: Any) -> None:
        """Record the interface geometry."""
        self.dut = dut
        self.p = len(dut.i_d) - 312
        self.images: dict[int, int] = {}
        self.buffers: dict[int, int] = {}

    async def tick(self, count: int = 1) -> None:
        """Supply the selected image bank before each clock edge."""
        for _ in range(count):
            await self.set(i_clk=0)
            await self.set(i_image_data=self.images.get(self.get("o_image_index"), 0))
            await self.set(i_clk=1)
            await self.set(i_clk=0)

    async def reset(self, epoch: int = 0, cycles: int = 2) -> None:
        """Reset every ownership record together."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1)
        await self.tick(cycles)
        await self.set(i_rst=0)

    async def wait(self, signal: str) -> None:
        """Wait for a bounded local handshake."""
        for _ in range(100):
            if self.get(signal):
                return
            await self.tick()
        raise AssertionError(f"{signal} did not progress")

    def request(self, q: int, address: int, op: int = 0) -> int:
        """Encode an immutable request identity."""
        return pack(
            (4, op),
            (9, q),
            (self.p, address),
            (5, 0),
            (3, 3),
            (32, 0),
            (1, 0),
            (1, 0),
            (1, 0),
            (256, 0),
        )

    async def admit(self, q: int, address: int, op: int = 0) -> None:
        """Queue an immutable request identity."""
        await self.set(i_d_valid=1, i_d=self.request(q, address, op))
        await self.wait("o_d_ready")
        await self.tick()
        await self.set(i_d_valid=0)

    async def dispatch(self) -> tuple[int, int, int]:
        """Reserve a result credit for one eligible request."""
        await self.wait("o_work_valid")
        fields = unpack(self.get("o_work"), (4, 9, self.p, 5, 3, 32, 1, 1, 1, 256))
        item = (fields[1], self.get("o_work_tid"), fields[2])
        self.buffers[item[1]] = self.get("o_work_buffer")
        await self.set(i_work_ready=1)
        await self.tick()
        await self.set(i_work_ready=0)
        return item

    async def result(self, item: tuple[int, int, int], data: int) -> None:
        """Transfer an execution image into its reserved result credit."""
        q, tid, address = item
        self.images[self.buffers[tid]] = data
        packet = pack((3, 0), (9, q), (6, tid), (self.p, address), (256, data), (1, 0))
        await self.set(i_result_valid=1, i_result=packet)
        await self.wait("o_result_ready")
        await self.tick()
        await self.set(i_result_valid=0)

    async def grant(self, item: tuple[int, int, int], data: int) -> None:
        """Consume the addressed immutable result."""
        await self.wait("o_g_valid")
        fields = unpack(self.get("o_g"), (3, 9, 6, self.p, 256, 1))
        assert fields[1:4] == item and fields[4] == data
        await self.set(i_g_ready=1)
        await self.tick()
        await self.set(i_g_ready=0)

    async def complete(self, item: tuple[int, int, int]) -> None:
        """Offer Done without accepting Release."""
        q, tid, address = item
        await self.set(
            i_c_valid=1,
            i_c=pack((9, q), (6, tid), (self.p, address), (2, 0), (1, 0)),
        )
        await self.wait("o_c_ready")
        await self.tick()
        await self.set(i_c_valid=0)

    async def release(self, item: tuple[int, int, int]) -> None:
        """Release the exact identity and physical pin."""
        await self.wait("o_u_valid")
        assert unpack(self.get("o_u"), (9, 6, self.p)) == item
        await self.set(i_u_ready=1)
        await self.tick()
        await self.set(i_u_ready=0)


@cocotb.test()
async def same_sector_waits_for_release_while_other_lines_progress(dut: Any) -> None:
    """Same-sector dependencies survive G and C; unrelated identities complete."""
    b = Completions(dut)
    await b.reset()
    await b.admit(0, 0x80000000)
    first = await b.dispatch()
    await b.set(i_pin_valid=1, i_pin_tid=first[1], i_pin_way=2)
    await b.tick()
    await b.set(i_pin_valid=0, i_query_addr=0x80000000, i_next_put_addr=0x80000000)
    await b.tick()
    assert b.get("o_exclude") == 4 and b.get("o_put_busy")
    await b.admit(2, 0x80000000)
    await b.admit(4, 0x80000040)
    other = await b.dispatch()
    assert other[0] == 4
    await b.result(other, 0x1234)
    await b.grant(other, 0x1234)
    await b.complete(other)
    await b.release(other)
    await b.tick(5)
    assert not b.get("o_work_valid")
    await b.result(first, 0xCAFE)
    await b.wait("o_g_valid")
    held = b.get("o_g")
    await b.tick(10)
    assert b.get("o_g_valid") and b.get("o_g") == held
    await b.grant(first, 0xCAFE)
    await b.complete(first)
    await b.wait("o_u_valid")
    held = b.get("o_u")
    await b.tick(10)
    assert b.get("o_u_valid") and b.get("o_u") == held
    assert b.get("o_exclude") == 4 and not b.get("o_work_valid")
    await b.release(first)
    assert b.get("o_exclude") == 0
    second = await b.dispatch()
    assert second[0] == 2
    await b.result(second, 0xBEEF)
    await b.grant(second, 0xBEEF)
    await b.complete(second)
    await b.release(second)
    await b.admit(0, 0x80000100)
    reused = await b.dispatch()
    assert reused[0] == 0


@cocotb.test()
async def single_cycle_reset_with_every_channel_offered(dut: Any) -> None:
    """One reset cycle frees every slot and credit, whatever fires on its edge."""
    b = Completions(dut)
    await b.reset()
    base = 0x80000000
    await b.admit(0, base)
    released = await b.dispatch()
    await b.result(released, 1)
    await b.grant(released, 1)
    await b.complete(released)
    await b.wait("o_u_valid")
    await b.admit(2, base + 64)
    granted = await b.dispatch()
    await b.result(granted, 2)
    await b.wait("o_g_valid")
    await b.admit(4, base + 128)
    running = await b.dispatch()
    await b.admit(6, base + 192)
    await b.wait("o_work_valid")
    assert b.get("buffer_live_q")

    await b.set(
        i_rst=1,
        i_d_valid=1,
        i_d=b.request(8, base + 256),
        i_work_ready=1,
        i_g_ready=1,
        i_u_ready=1,
        i_result_valid=1,
        i_result=pack(
            (3, 0),
            (9, running[0]),
            (6, running[1]),
            (b.p, running[2]),
            (256, 3),
            (1, 0),
        ),
    )
    await b.tick()
    await b.set(
        i_rst=0,
        i_d_valid=0,
        i_work_ready=0,
        i_g_ready=0,
        i_u_ready=0,
        i_result_valid=0,
    )

    assert not b.get("o_work_valid") and not b.get("o_g_valid")
    assert not b.get("o_u_valid") and not b.get("o_put_busy")
    assert not b.get("o_accepted") and not b.get("released_q")
    assert not b.get("buffer_live_q") and not b.get("buffer_owned_q")
    await b.tick(4)
    assert not b.get("o_work_valid") and not b.get("o_g_valid")
    assert not b.get("o_u_valid")

    # Every identity is free again.
    for q in (0, 2, 4, 6):
        await b.admit(q, base + 32 * q)
        item = await b.dispatch()
        await b.result(item, q + 1)
        await b.grant(item, q + 1)
        await b.complete(item)
        await b.release(item)
    assert not b.get("buffer_live_q")


@cocotb.test()
async def result_pool_backpressure_and_retry(dut: Any) -> None:
    """Eight held results leave independent admission and metadata credits."""
    b = Completions(dut)
    await b.reset()
    # Every legal identity of one hart: eight data, two instruction and two
    # page-walk requests, eight DMA credits and four prefetches.
    identities = [(2 * index, 0) for index in range(8)]
    identities += [(32 + 2 * index, 5) for index in range(2)]
    identities += [(64 + 2 * index, 6) for index in range(2)]
    identities += [(352 + 2 * index, 7) for index in range(8)]
    identities += [(480 + 2 * index, 9) for index in range(4)]
    for index, (q, op) in enumerate(identities):
        await b.admit(q, 0x80000000 + 32 * index, op)
    assert not b.get("o_d_ready")
    active = []
    for index in range(8):
        item = await b.dispatch()
        active.append(item)
        await b.result(item, index + 1)
    await b.tick(4)
    assert not b.get("o_work_valid")
    await b.set(i_next_put_addr=0x90000000)
    await b.tick()
    assert not b.get("o_put_busy")
    await b.grant(active[0], 1)
    retry = await b.dispatch()
    await b.set(i_retry_valid=1, i_retry_tid=retry[1])
    await b.tick()
    await b.set(i_retry_valid=0)
    following = await b.dispatch()
    assert following[0] != retry[0]
    await b.result(following, 0x5555)
    for index in range(1, 8):
        await b.grant(active[index], index + 1)
    await b.grant(following, 0x5555)
    # Pins and admission remain owned after all result credits return.
    assert not b.get("o_d_ready")
    for item in reversed(active):
        await b.complete(item)
        await b.release(item)
    await b.reset()
    await b.set(i_d=0)
    assert b.get("o_d_ready") and not b.get("o_g_valid") and not b.get("o_u_valid")


@cocotb.test()
async def simultaneous_work_grant_and_retry_use_distinct_credits(dut: Any) -> None:
    """Allocate one image and release two images on the same acceptance edge."""
    for reserved in (0, 5):
        b = Completions(dut)
        await b.reset()
        prefix = []
        for index in range(reserved):
            await b.admit(2 * index, 0x80000000 + 64 * index)
            prefix.append(await b.dispatch())
        for index in range(reserved, reserved + 3):
            await b.admit(2 * index, 0x80000000 + 64 * index)
        granted = await b.dispatch()
        retried = await b.dispatch()
        await b.result(granted, 0xA123)
        await b.wait("o_g_valid")
        await b.wait("o_work_valid")
        fields = unpack(b.get("o_work"), (4, 9, b.p, 5, 3, 32, 1, 1, 1, 256))
        allocated = (fields[1], b.get("o_work_tid"), fields[2])
        b.buffers[allocated[1]] = b.get("o_work_buffer")
        credits = [b.buffers[item[1]] for item in (granted, retried, allocated)]
        assert len(set(credits)) == 3
        before = b.get("buffer_live_q")
        assert before & (1 << credits[0]) and before & (1 << credits[1])
        assert not before & (1 << credits[2])
        assert unpack(b.get("o_g"), (3, 9, 6, b.p, 256, 1))[1:4] == granted
        await b.set(
            i_work_ready=1, i_g_ready=1, i_retry_valid=1, i_retry_tid=retried[1]
        )
        assert b.get("accept_work") and b.get("accept_grant")
        assert b.get("i_retry_valid")
        await b.tick()
        await b.set(i_work_ready=0, i_g_ready=0, i_retry_valid=0)
        expected = (before | (1 << credits[2])) & ~(
            (1 << credits[0]) | (1 << credits[1])
        )
        assert b.get("buffer_live_q") == expected
        owned = b.get("buffer_owned_q")
        assert owned & (1 << allocated[1])
        assert not owned & ((1 << granted[1]) | (1 << retried[1]))
        await b.complete(granted)
        await b.release(granted)
        await b.result(allocated, 0xC345)
        await b.grant(allocated, 0xC345)
        await b.complete(allocated)
        await b.release(allocated)
        retry = await b.dispatch()
        assert retry == retried
        await b.result(retry, 0xB234)
        await b.grant(retry, 0xB234)
        await b.complete(retry)
        await b.release(retry)
        for item in prefix:
            await b.result(item, item[1] + 1)
            await b.grant(item, item[1] + 1)
            await b.complete(item)
            await b.release(item)
        assert b.get("buffer_live_q") == 0


@cocotb.test()
async def predecessor_release_and_slot_reuse_do_not_alias(dut: Any) -> None:
    """Clear a predecessor on U while admitting a successor and reusing its slot."""
    b = Completions(dut)
    await b.reset()
    address = 0x80000000
    await b.admit(0, address)
    first = await b.dispatch()
    await b.admit(2, address)
    await b.admit(4, address)
    await b.result(first, 11)
    await b.grant(first, 11)
    await b.complete(first)
    await b.wait("o_u_valid")
    await b.set(i_u_ready=1)
    await b.admit(6, address)
    await b.set(i_u_ready=0)
    await b.admit(0, address + 64)
    second = await b.dispatch()
    reused = await b.dispatch()
    assert second[0] == 2 and reused[0] == 0 and reused[1] == first[1]
    await b.result(reused, 22)
    await b.grant(reused, 22)
    await b.set(
        i_c_valid=1,
        i_c=pack((9, first[0]), (6, first[1]), (b.p, first[2]), (2, 0), (1, 0)),
    )
    assert not b.get("o_c_ready")
    await b.tick()
    await b.set(i_c_valid=0)
    await b.complete(reused)
    await b.release(reused)
    await b.tick(5)
    assert not b.get("o_work_valid")
    await b.result(second, 33)
    await b.grant(second, 33)
    await b.complete(second)
    await b.release(second)
    for q, data in ((4, 44), (6, 55)):
        item = await b.dispatch()
        assert item[0] == q
        await b.result(item, data)
        await b.grant(item, data)
        await b.complete(item)
        await b.release(item)


@cocotb.test()
async def dma_result_hands_its_sector_to_successors(dut: Any) -> None:
    """Hold a sector behind a DMA request until its result, behind a hart one until U."""
    b = Completions(dut)
    await b.reset()
    address = 0x80000000
    first_dma = pack((2, 2), (2, 3), (4, 5), (1, 0))
    second_dma = pack((2, 2), (2, 3), (4, 6), (1, 0))
    await b.admit(first_dma, address, op=8)
    first = await b.dispatch()
    await b.admit(0, address)
    await b.tick(3)
    assert not b.get("o_work_valid")
    await b.result(first, 0x11)
    # The hart request starts before the DMA request's G, C and U.
    hart = await b.dispatch()
    assert hart[0] == 0
    # A request admitted now waits for the hart request alone.
    await b.admit(second_dma, address, op=7)
    await b.grant(first, 0x11)
    await b.result(hart, 0x22)
    await b.grant(hart, 0x22)
    await b.complete(hart)
    await b.tick(5)
    assert not b.get("o_work_valid")
    await b.release(hart)
    second = await b.dispatch()
    assert second[0] == second_dma
    await b.complete(first)
    await b.release(first)
    await b.result(second, 0x33)
    await b.grant(second, 0x33)
    await b.complete(second)
    await b.release(second)


@cocotb.test()
async def idle_grant_captures_result_edge(dut: Any) -> None:
    """Capture an unopposed result into G and hold its full packet through stalls."""
    b = Completions(dut)
    for opcode, error in ((0, 0), (4, 0), (0, 1)):
        await b.reset()
        q = pack((2, 2), (2, 3), (4, 9), (1, 0))
        address = 0x80000000
        await b.admit(q, address, op=8 if opcode == 4 else 7)
        item = await b.dispatch()
        data = int.from_bytes(bytes((i * 37) & 255 for i in range(32)), "little")
        b.images[b.buffers[item[1]]] = data
        packet = pack(
            (3, opcode), (9, q), (6, item[1]), (b.p, address), (256, data), (1, error)
        )
        await b.set(i_result_valid=1, i_result=packet)
        await b.wait("o_result_ready")
        await b.tick()
        await b.set(i_result_valid=0, i_result=0)
        assert b.get("o_g_valid"), "idle G selection missed the result capture edge"
        held = b.get("o_g")
        fields = unpack(held, (3, 9, 6, b.p, 256, 1))
        assert fields == (
            opcode,
            q,
            item[1],
            address,
            0 if error or opcode == 4 else data,
            error,
        )
        for _ in range(16):
            assert b.get("o_g_valid") and b.get("o_g") == held
            await b.tick()
        await b.set(i_g_ready=1)
        await b.tick()
        await b.set(
            i_g_ready=0,
            i_c_valid=1,
            i_c=pack(
                (9, q), (6, item[1]), (b.p, address), (2, 2 if error else 0), (1, 0)
            ),
        )
        await b.wait("o_c_ready")
        await b.tick()
        await b.set(i_c_valid=0)
        await b.release(item)


@cocotb.test()
async def selection_crossing_park_allocates_no_image(dut: Any) -> None:
    """Cancel a selected waiter when the same edge transfers it to a fill."""
    b = Completions(dut)
    await b.reset()
    await b.admit(0, 0x80000000)
    assert b.get("o_waiting") == 1
    await b.set(i_park=1, i_work_ready=1)
    await b.tick()
    await b.set(i_park=0)
    for _ in range(8):
        assert not b.get("o_work_valid")
        assert b.get("buffer_live_q") == 0
        assert b.get("buffer_owned_q") == 0
        await b.tick()
    await b.set(i_work_ready=0, i_wake=1)
    await b.tick()
    await b.set(i_wake=0)
    item = await b.dispatch()
    assert item == (0, 0, 0x80000000)
    await b.result(item, 0xBADCAFE)
    await b.grant(item, 0xBADCAFE)
    await b.complete(item)
    await b.release(item)


async def dispatch_with_flag(b: Completions) -> tuple[tuple[int, int, int], int]:
    """Dispatch one request and report its no-fill flag."""
    await b.wait("o_work_valid")
    flag = b.get("o_work_nofill")
    return await b.dispatch(), flag


@cocotb.test()
async def prefetch_slots_keep_their_own_capacity(dut: Any) -> None:
    """Prefetches and every other identity fill separate slot partitions."""
    b = Completions(dut)
    await b.reset()
    for index in range(4):
        await b.admit(480 + 2 * index, 0x80000000 + 64 * index, 9)
    identities = [(2 * index, 0) for index in range(8)]
    identities += [(32 + 2 * index, 5) for index in range(2)]
    identities += [(64 + 2 * index, 6) for index in range(2)]
    identities += [(352 + 2 * index, 7) for index in range(8)]
    for index, (q, op) in enumerate(identities):
        await b.admit(q, 0x80010000 + 64 * index, op)
    assert b.get("live") == (1 << len(b.dut.live)) - 1


@cocotb.test()
async def prefetch_no_fill_flag_follows_live_demand(dut: Any) -> None:
    """Dispatch a Prefetch with no fill while a demand for its block is live."""
    b = Completions(dut)
    await b.reset()
    # A live GetS of the block before the Prefetch's admission.
    await b.admit(0, 0x80000000)
    await b.admit(480, 0x80000020, 9)
    first, flag = await dispatch_with_flag(b)
    assert first[0] == 0 and not flag
    second, flag = await dispatch_with_flag(b)
    assert second[0] == 480 and flag
    # No demand for the block.
    await b.admit(482, 0x80001000, 9)
    third, flag = await dispatch_with_flag(b)
    assert third[0] == 482 and not flag
    # A GetM of the block admitted after the Prefetch, before its dispatch.
    await b.admit(484, 0x80002000, 9)
    await b.admit(2, 0x80002020, 1)
    items = [await dispatch_with_flag(b) for _ in range(2)]
    flags = {item[0]: flag for item, flag in items}
    assert flags == {484: 1, 2: 0}


@cocotb.test()
async def prefetches_take_no_place_in_sector_order_or_put_waits(dut: Any) -> None:
    """Keep Prefetches out of the sector order and out of PutM waits."""
    b = Completions(dut)
    await b.reset()
    address = 0x80000000
    await b.set(i_next_put_addr=address)
    await b.admit(480, address, 9)
    await b.tick(2)
    assert not b.get("o_put_busy")
    await b.admit(0, address)
    await b.tick(2)
    assert b.get("o_put_busy")
    # The GetS dispatches before the Prefetch has a result, and a second
    # Prefetch of the sector dispatches while the GetS is live.
    first = await b.dispatch()
    second = await b.dispatch()
    assert {first[0], second[0]} == {480, 0}
    await b.admit(482, address, 9)
    third = await b.dispatch()
    assert third[0] == 482
    # The table takes a prefetch slot's G when it is presented.
    await b.set(i_g_ready=1)
    for item in (first, second, third):
        if item[0] != 0:
            await b.result(item, 0)
    for _ in range(10):
        if not b.get("result_valid_q"):
            break
        await b.tick()
    assert not b.get("result_valid_q")
    await b.set(i_g_ready=0)
    for item in (first, second, third):
        if item[0] != 0:
            await b.complete(item)
            await b.release(item)
    demand = first if first[0] == 0 else second
    await b.result(demand, 0x1234)
    await b.grant(demand, 0x1234)
    await b.complete(demand)
    await b.release(demand)


@cocotb.test()
async def forwarded_primary_takes_the_forward_buffer_beside_engine_results(
    dut: Any,
) -> None:
    """Give a parked primary its pin, result and the forward buffer at once.

    The forward buffer holds one forwarded grant from its forward until its
    G; engine results keep their own buffers, and an engine result accepted
    on the forward's edge goes to its buffer.
    """
    b = Completions(dut)
    await b.reset()
    # The forward buffer follows the engines' buffers.
    forward = len(dut.buffer_live_q) - 1
    address = 0x80000000
    # The primary misses: dispatched, then retried with a park.
    await b.admit(0, address, op=1)
    primary = await b.dispatch()
    await b.set(i_retry_valid=1, i_retry_tid=primary[1], i_retry_park=1)
    await b.tick()
    await b.set(i_retry_valid=0, i_retry_park=0)
    assert b.get("parked_q") >> primary[1] & 1
    assert not b.get("buffer_live_q") >> forward & 1
    # Another request takes an engine result on the forward's edge.
    await b.admit(2, address + 64)
    other = await b.dispatch()
    b.images[forward] = 0xF0F0
    b.images[b.buffers[other[1]]] = 0x0F0F
    packet = pack(
        (3, 0), (9, other[0]), (6, other[1]), (b.p, other[2]), (256, 0x0F0F), (1, 0)
    )
    await b.set(i_result_valid=1, i_result=packet)
    assert b.get("o_forward_ready") and b.get("o_result_ready")
    forward_packet = pack(
        (3, 2), (9, primary[0]), (6, primary[1]), (b.p, primary[2]), (256, 0), (1, 0)
    )
    await b.set(
        i_forward_valid=1,
        i_forward_slots=1 << primary[1],
        i_forward_way=1,
        i_forward=forward_packet,
    )
    assert b.get("accept_forward") and b.get("accept_result")
    await b.tick()
    await b.set(i_forward_valid=0, i_forward_slots=0, i_forward=0, i_result_valid=0)
    assert not b.get("o_forward_ready")
    assert not b.get("parked_q") >> primary[1] & 1
    assert b.get("pin_valid_q") >> primary[1] & 1
    await b.set(i_query_addr=address)
    await b.tick()
    assert b.get("o_exclude") == 2
    # Both grants come out, each with its own data; GetM forwards as GrantM.
    grants = {}
    for _ in range(2):
        await b.wait("o_g_valid")
        fields = unpack(b.get("o_g"), (3, 9, 6, b.p, 256, 1))
        grants[fields[1]] = fields
        await b.set(i_g_ready=1)
        await b.tick()
        await b.set(i_g_ready=0)
    assert grants[primary[0]] == (2, primary[0], primary[1], address, 0xF0F0, 0)
    assert grants[other[0]] == (0, other[0], other[1], address + 64, 0x0F0F, 0)
    assert b.get("o_forward_ready")
    # The GetM's Done reports its write.
    q, tid, address = primary
    await b.set(i_c_valid=1, i_c=pack((9, q), (6, tid), (b.p, address), (2, 0), (1, 1)))
    await b.wait("o_c_ready")
    await b.tick()
    await b.set(i_c_valid=0)
    await b.release(primary)
    await b.complete(other)
    await b.release(other)
    assert b.get("o_exclude") == 0 and b.get("buffer_live_q") == 0

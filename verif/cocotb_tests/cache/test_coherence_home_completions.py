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

    async def reset(self, epoch: int = 0) -> None:
        """Reset every ownership record together."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1)
        await self.tick(2)
        await self.set(i_rst=0)

    async def wait(self, signal: str) -> None:
        """Wait for a bounded local handshake."""
        for _ in range(100):
            if self.get(signal):
                return
            await self.tick()
        raise AssertionError(f"{signal} did not progress")

    async def admit(self, q: int, address: int, op: int = 0) -> None:
        """Queue an immutable request identity."""
        request = pack(
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
        await self.set(i_d_valid=1, i_d=request)
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
    await b.set(i_pin_valid=0, i_query_addr=0x80000000, i_put_addr=0x80000000)
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
async def result_pool_backpressure_and_retry(dut: Any) -> None:
    """Eight held results leave independent admission and metadata credits."""
    b = Completions(dut)
    await b.reset()
    identities = [(2 * index, 0) for index in range(8)]
    identities += [(32 + 2 * index, 5) for index in range(2)]
    identities += [(64, 6)]
    identities += [(352 + 2 * index, 7) for index in range(4)]
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
    await b.set(i_put_addr=0x90000000)
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

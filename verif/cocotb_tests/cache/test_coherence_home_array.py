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

"""Check independent tag decisions and physical-row data hazards."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


class Array:
    """Track accepted operations and their token-addressed responses."""

    def __init__(self, dut: Any) -> None:
        """Create the row-value and response scoreboards."""
        self.dut = dut
        self.line = len(dut.i_update_mask)
        self.rows: dict[tuple[int, int], int] = {}
        self.reads: dict[int, int] = {}
        self.read_done: list[int] = []
        self.updated: list[int] = []
        self.tags: list[tuple[int, ...]] = []
        self.overlap = 0

    def get(self, name: str) -> int:
        """Sample a signal."""
        return int(getattr(self.dut, name).value)

    async def set(self, **values: int) -> None:
        """Drive the falling phase."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    async def tick(self, count: int = 1) -> None:
        """Check every accepted read against the masked-write reference."""
        for _ in range(count):
            await self.set(i_clk=0)
            if self.get("o_read_valid"):
                token = self.get("o_read_token")
                assert token in self.reads
                assert self.get("o_read_data") == self.reads.pop(token)
                self.read_done.append(token)
            if self.get("o_updated"):
                self.updated.append(self.get("o_updated_token"))
            if self.get("o_resp_valid") and self.get("i_resp_ready"):
                self.tags.append(
                    tuple(
                        self.get(name)
                        for name in (
                            "o_resp_token",
                            "o_resp_hit",
                            "o_resp_available",
                            "o_resp_way",
                            "o_resp_addr",
                            "o_resp_state",
                        )
                    )
                )
            rf = self.get("i_read_valid") and self.get("o_read_ready")
            wf = self.get("i_update_valid") and self.get("o_update_ready")
            if rf:
                row = self.get("i_read_addr"), self.get("i_read_way")
                token = self.get("i_read_token")
                assert token not in self.reads
                self.reads[token] = self.rows[row]
            if wf:
                row = self.get("i_update_addr"), self.get("i_update_way")
                value = self.rows.get(row, 0)
                for byte in range(self.line):
                    if self.get("i_update_mask") & (1 << byte):
                        value = (value & ~(255 << (8 * byte))) | (
                            self.get("i_update_data") & (255 << (8 * byte))
                        )
                self.rows[row] = value
            self.overlap += bool(rf and wf)
            await self.set(i_clk=1)
            await self.set(i_clk=0)

    async def reset(self) -> None:
        """Reset ownership and wait for the tag sweep."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1)
        await self.set(i_clk=1)
        await self.set(i_clk=0, i_rst=0, i_resp_ready=1, i_resp_claim=1)
        self.reads.clear()
        self.read_done.clear()
        self.updated.clear()
        self.tags.clear()
        for _ in range(64):
            if self.get("o_init_done"):
                return
            await self.tick()
        raise AssertionError("tag initialization did not finish")

    async def wait(self, signal: str) -> None:
        """Bound every service wait."""
        for _ in range(80):
            if self.get(signal):
                return
            await self.tick()
        raise AssertionError(signal)

    async def update(
        self,
        address: int,
        way: int,
        data: int,
        mask: int,
        token: int,
        tag: int = 1,
        state: int = 3,
    ) -> None:
        """Present one update through its acceptance edge."""
        await self.set(
            i_update_valid=1,
            i_update_addr=address,
            i_update_way=way,
            i_update_tag=tag,
            i_update_state=state,
            i_update_data=data,
            i_update_mask=mask,
            i_update_token=token,
        )
        await self.wait("o_update_ready")
        await self.tick()
        await self.set(i_update_valid=0)

    async def lookup(self, address: int, token: int) -> tuple[int, ...]:
        """Present a lookup and collect its selected way."""
        count = len(self.tags)
        await self.set(i_req_valid=1, i_req_addr=address, i_req_token=token)
        await self.wait("o_req_ready")
        await self.tick()
        await self.set(i_req_valid=0)
        for _ in range(80):
            if len(self.tags) > count:
                return self.tags[-1]
            await self.tick()
        raise AssertionError("tag response missing")


@cocotb.test()
async def overlapping_ports_preserve_masked_bytes(dut: Any) -> None:
    """Read and update different rows concurrently, including partial writes."""
    b = Array(dut)
    await b.reset()
    full = (1 << b.line) - 1
    a, z = 0, b.line
    await b.update(a, 0, int.from_bytes(bytes(range(b.line)), "little"), full, 0)
    await b.update(
        z, 0, int.from_bytes(bytes(range(128, 128 + b.line)), "little"), full, 1
    )
    await b.tick(12)
    assert (await b.lookup(a, 2))[1:4] == (1, 1, 0)
    assert (await b.lookup(z, 3))[1:4] == (1, 1, 0)
    rng = random.Random(0xC041)
    for turn in range(32):
        read_addr, write_addr = (a, z) if turn % 2 else (z, a)
        token = turn % 16
        await b.set(
            i_read_valid=1,
            i_read_addr=read_addr,
            i_read_way=0,
            i_read_token=token,
            i_update_valid=1,
            i_update_addr=write_addr,
            i_update_way=0,
            i_update_tag=0,
            i_update_data=rng.getrandbits(8 * b.line),
            i_update_mask=rng.getrandbits(b.line),
            i_update_token=token,
        )
        reading, writing = True, True
        for _ in range(40):
            rf = reading and bool(b.get("o_read_ready"))
            wf = writing and bool(b.get("o_update_ready"))
            await b.tick()
            if rf:
                reading = False
                await b.set(i_read_valid=0)
            if wf:
                writing = False
                await b.set(i_update_valid=0)
            if not reading and not writing:
                break
        assert not reading and not writing
    await b.tick(16)
    assert not b.reads and len(b.read_done) == 32 and b.overlap > 0
    for address in (a, z):
        await b.set(i_read_valid=1, i_read_addr=address, i_read_token=15)
        await b.wait("o_read_ready")
        await b.tick()
        await b.set(i_read_valid=0)
        await b.tick(12)


@cocotb.test()
async def held_tag_blocks_colliding_updates_and_reset_cancels_reads(dut: Any) -> None:
    """Keep the packed tag row stable and suppress pre-reset response debt."""
    b = Array(dut)
    await b.reset()
    full = (1 << b.line) - 1
    await b.update(0, 0, 0x1234, full, 0)
    await b.tick(12)
    await b.set(i_resp_ready=0, i_req_valid=1, i_req_addr=0, i_req_token=4)
    await b.wait("o_req_ready")
    await b.tick()
    await b.set(i_req_valid=0)
    await b.wait("o_resp_valid")
    signature = tuple(
        b.get(name)
        for name in (
            "o_resp_token",
            "o_resp_hit",
            "o_resp_available",
            "o_resp_way",
            "o_resp_addr",
            "o_resp_state",
        )
    )
    await b.set(
        i_update_valid=1,
        i_update_addr=0,
        i_update_way=0,
        i_update_tag=1,
        i_update_state=0,
        i_update_mask=0,
    )
    for _ in range(7):
        assert not b.get("o_update_ready")
        assert signature == tuple(
            b.get(name)
            for name in (
                "o_resp_token",
                "o_resp_hit",
                "o_resp_available",
                "o_resp_way",
                "o_resp_addr",
                "o_resp_state",
            )
        )
        await b.tick()
    await b.set(i_resp_ready=1)
    await b.tick()
    await b.wait("o_update_ready")
    await b.tick()
    await b.set(i_update_valid=0)
    assert (await b.lookup(0, 5))[1] == 0
    await b.set(i_read_valid=1, i_read_addr=0, i_read_way=0, i_read_token=7)
    await b.wait("o_read_ready")
    await b.tick()
    await b.reset()
    await b.tick(16)
    assert not b.read_done
    assert (await b.lookup(0, 8))[1] == 0


@cocotb.test()
async def tag_row_alias_and_live_exclusions(dut: Any) -> None:
    """Packed sibling sets share a tag guard; current exclusions select victims."""
    b = Array(dut)
    await b.reset()
    await b.set(
        i_req_valid=1, i_req_addr=0, i_req_token=5, i_resp_ready=0, i_resp_claim=0
    )
    await b.wait("o_req_ready")
    await b.tick()
    await b.set(i_req_valid=0, i_exclude=1)
    await b.wait("o_resp_valid")
    assert b.get("o_resp_hit") == 0
    if len(dut.i_exclude) == 1:
        assert not b.get("o_resp_available")
        await b.set(
            i_update_valid=1,
            i_update_addr=b.line,
            i_update_way=0,
            i_update_tag=1,
            i_update_state=2,
            i_update_mask=0,
        )
        for _ in range(5):
            assert not b.get("o_update_ready")
            await b.tick()
        await b.set(i_resp_ready=1)
        await b.tick()
        await b.wait("o_update_ready")
        await b.tick()
        await b.set(i_update_valid=0, i_exclude=0)
        assert (await b.lookup(b.line, 6))[1] == 1
    else:
        assert b.get("o_resp_available") and b.get("o_resp_way") != 0
        await b.set(i_resp_ready=1)
        await b.tick()


@cocotb.test()
async def continuous_row_contention_services_both_ports(dut: Any) -> None:
    """Check bounded service for continuous read and write contenders."""
    b = Array(dut)
    await b.reset()
    await b.update(0, 0, 0, (1 << b.line) - 1, 0)
    await b.tick(12)
    reads = writes = read_wait = write_wait = 0
    await b.set(
        i_read_valid=1,
        i_read_addr=0,
        i_read_way=0,
        i_read_token=0,
        i_update_valid=1,
        i_update_addr=0,
        i_update_way=0,
        i_update_tag=0,
        i_update_mask=1,
        i_update_data=1,
        i_update_token=0,
    )
    for _ in range(200):
        rf, wf = b.get("o_read_ready"), b.get("o_update_ready")
        await b.tick()
        reads += rf
        writes += wf
        read_wait = 0 if rf else read_wait + 1
        write_wait = 0 if wf else write_wait + 1
        assert read_wait < 24 and write_wait < 24
        if rf:
            await b.set(i_read_token=reads % 16)
        if wf:
            await b.set(i_update_token=writes % 16, i_update_data=(writes + 1) % 256)
    await b.set(i_read_valid=0, i_update_valid=0)
    await b.tick(16)
    assert reads >= 8 and writes >= 8 and not b.reads


@cocotb.test()
async def pending_tag_update_interrupts_repeated_lookups(dut: Any) -> None:
    """Give a pending packed-row update a bounded opportunity to commit."""
    b = Array(dut)
    await b.reset()
    await b.set(
        i_req_valid=1, i_req_addr=0, i_req_token=1, i_resp_ready=1, i_resp_claim=0
    )
    for _ in range(30):
        if b.get("o_resp_valid"):
            break
        await b.tick()
    else:
        raise AssertionError("lookup did not reach its response")
    await b.set(
        i_update_valid=1,
        i_update_addr=0,
        i_update_way=0,
        i_update_tag=1,
        i_update_state=2,
        i_update_mask=0,
        i_update_data=0,
        i_update_token=2,
    )
    for _ in range(12):
        fired = b.get("o_update_ready")
        await b.tick()
        if fired:
            break
    else:
        raise AssertionError("continuous lookups starved the tag update")
    await b.set(i_update_valid=0, i_req_valid=0)
    await b.tick(12)
    tag = await b.lookup(0, 3)
    assert tag[1]

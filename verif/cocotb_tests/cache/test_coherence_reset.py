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

"""Check metadata reset, replacement touches and preservation of row data."""

import os
from typing import Any

import cocotb
from cocotb.triggers import Timer


class ResetArray:
    """Drive either coherent array through its external service ports."""

    def __init__(self, dut: Any) -> None:
        """Use four sets and four ways in both storage implementations."""
        self.dut = dut
        self.home = hasattr(dut, "i_read_valid")
        self.line = len(dut.i_update_mask)
        self.sets = 4
        self.ways = 4
        self.fast = int(os.environ["FROST_TEST_ARRAY_FAST"])
        self.ultra = int(os.environ["FROST_TEST_ARRAY_ULTRA"])
        self.write_latency = int(
            os.environ.get("FROST_TEST_ARRAY_WRITE_LATENCY", str(1 + self.ultra))
        )

    def get(self, name: str) -> int:
        """Sample one output."""
        return int(getattr(self.dut, name).value)

    async def drive(self, **values: int) -> None:
        """Drive between rising edges."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    async def tick(self) -> None:
        """Advance one cycle."""
        await self.drive(i_clk=1)
        await self.drive(i_clk=0)

    async def wait(self, name: str) -> None:
        """Bound service latency."""
        for _ in range(32):
            if self.get(name):
                return
            await self.tick()
        raise AssertionError(f"{name} did not assert")

    async def reset(self) -> None:
        """Check the sweep length and the write drain before readiness."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.drive(i_rst=1)
        await self.tick()
        assert not self.get("o_req_ready") and not self.get("o_update_ready")
        await self.drive(i_rst=0, i_resp_ready=1)
        sweep = 1 if self.fast else self.sets
        drain = 1 if self.home else 1 + self.write_latency
        if self.home and self.fast:
            drain = max(1, self.write_latency - 1)
        for cycle in range(sweep + drain):
            assert not self.get("o_req_ready"), cycle
            assert not self.get("o_update_ready"), cycle
            await self.tick()
        assert self.get("o_req_ready") and self.get("o_update_ready")

    async def update(
        self, address: int, way: int, data: int, drain: bool = True
    ) -> None:
        """Install a complete Modified row without touching replacement state."""
        fields = dict(
            i_update_addr=address,
            i_update_way=way,
            i_update_state=3,
            i_update_mask=(1 << self.line) - 1,
            i_update_data=data,
        )
        if self.home:
            fields.update(i_update_tag=1, i_update_has_data=1)
        else:
            fields.update(i_update_insert=0)
        await self.drive(**fields)
        await self.wait("o_update_ready")
        await self.drive(i_update_valid=1)
        await self.tick()
        await self.drive(i_update_valid=0)
        for _ in range(self.write_latency + 1 if drain else 0):
            await self.tick()

    async def lookup(
        self,
        address: int,
        exclude: int = 0,
        visit: int | None = None,
        claim: int = 0,
        skip: bool = False,
        hold: int = 0,
    ) -> tuple[int, int, int, int, int]:
        """Read one selected tag, optionally as a private maintenance visit."""
        fields = dict(i_req_addr=address, i_resp_ready=int(not hold))
        if self.home:
            fields.update(i_exclude=exclude, i_resp_claim=claim)
        else:
            fields.update(
                i_req_exclude=exclude,
                i_req_visit=int(visit is not None),
                i_req_way=visit or 0,
                i_req_skip_data_on_hit=int(skip),
            )
        await self.drive(**fields)
        await self.wait("o_req_ready")
        await self.drive(i_req_valid=1)
        await self.tick()
        await self.drive(i_req_valid=0)
        await self.wait("o_resp_valid")
        result = (
            self.get("o_resp_hit"),
            self.get("o_resp_way"),
            self.get("o_resp_addr"),
            self.get("o_resp_state"),
        )
        payload = self.get("o_resp_tags" if self.home else "o_resp_data")
        for _ in range(hold):
            await self.tick()
            assert self.get("o_resp_valid")
            assert self.get("o_resp_way") == result[1]
            assert self.get("o_resp_tags" if self.home else "o_resp_data") == payload
        await self.drive(i_resp_ready=1)
        await self.tick()
        return (*result, payload)

    async def read(self, address: int, way: int) -> int:
        """Read a home row independently of its invalid tag."""
        await self.drive(i_read_addr=address, i_read_way=way, i_read_offer=1)
        await self.wait("o_read_ready")
        await self.drive(i_read_valid=1)
        await self.tick()
        await self.drive(i_read_valid=0, i_read_offer=0)
        await self.wait("o_read_valid")
        result = self.get("o_read_data")
        await self.tick()
        return result


@cocotb.test()
async def reset_clears_metadata_and_preserves_data(dut: Any) -> None:
    """Clear every tag/state and PLRU bit at cold and populated reset."""
    b = ResetArray(dut)
    for signal in dut:
        if signal._name.startswith("i_"):
            signal.value = 0
    # Select an unwitnessed Init state even if the simulator's initial edge
    # sampled a randomized reset input before the bench gained control.
    dut.sim_reset_seen_q.value = 0
    dut.phase_q.value = 0
    await b.drive(i_clk=0)
    for _ in range(3):
        assert b.get("sim_reset_seen_q") == 0
        assert b.get("init_bulk_clear") == 0
        await b.tick()
    contents: dict[tuple[int, int], int] = {}
    for populated in (False, True):
        await b.reset()
        if populated and b.home:
            assert await b.read(0, 0) == contents[0, 0]
        for index in range(b.sets):
            address = index * b.line
            for way in range(b.ways):
                hit, selected, old_address, state, payload = await b.lookup(
                    address, exclude=15 ^ (1 << way), visit=None if b.home else way
                )
                assert (hit, selected, old_address, state) == (0, way, address, 0)
                if b.home:
                    assert payload == 0
                if populated:
                    data = await b.read(address, way) if b.home else payload
                    assert data == contents[index, way]
            for way in range(b.ways):
                tag_address = address + (way + 1) * b.sets * b.line
                data = int.from_bytes(
                    bytes(
                        (index * 67 + way * 29 + byte) % 256 for byte in range(b.line)
                    ),
                    "little",
                )
                await b.update(tag_address, way, data)
                contents[index, way] = data
            # An all-zero PLRU tree chooses the first eligible way. Every
            # exclusion mask exposes each decision bit without updating it.
            for exclude in range(15):
                hit, selected, _, _, _ = await b.lookup(address, exclude=exclude)
                assert hit == 0
                assert selected == next(
                    way for way in range(4) if not exclude >> way & 1
                )
            # Touch both subtrees and the root before the populated reset.
            for way in (0, 2, 0):
                tag_address = address + (way + 1) * b.sets * b.line
                assert (await b.lookup(tag_address, claim=1))[0] == 1
        # Reset on the edge after acceptance, while a pipelined write is live.
        contents[0, 0] ^= (1 << (8 * b.line)) - 1
        await b.update(b.sets * b.line, 0, contents[0, 0], drain=False)


@cocotb.test()
async def hit_touches_precede_following_lookups(dut: Any) -> None:
    """Observe each private hit's replacement update at the next lookup."""
    b = ResetArray(dut)
    if b.home:
        return
    await b.reset()
    for index in (0, 1):
        for way in range(b.ways):
            address = (index + (way + 1) * b.sets) * b.line
            await b.update(address, way, (way + 1) * 0x01010101)
    # These touches alternate the root and both children of the PLRU tree.
    for step, (way, victim) in enumerate(
        ((0, 2), (2, 1), (1, 3), (3, 0), (3, 0), (0, 2))
    ):
        address = (way + 1) * b.sets * b.line
        assert (await b.lookup(address, skip=bool(step % 2), hold=step % 3))[0] == 1
        hit, selected, _, _, _ = await b.lookup(0)
        assert (hit, selected) == (0, victim)
        hit, selected, _, _, _ = await b.lookup(b.line)
        assert (hit, selected) == (0, 0)

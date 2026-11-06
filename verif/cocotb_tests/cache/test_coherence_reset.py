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

"""Check metadata reset, replacement touches and conditional row-data service."""

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

    async def wait(self, name: str) -> int:
        """Return the bounded cycle count until an output asserts."""
        for cycle in range(32):
            if self.get(name):
                return cycle
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
        self, address: int, way: int, data: int, drain: bool = True, state: int = 3
    ) -> None:
        """Write a complete row without touching replacement state."""
        fields = dict(
            i_update_addr=address,
            i_update_way=way,
            i_update_state=state,
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
        modified: bool = False,
        no_touch: bool = False,
        data_valid: bool | None = None,
        available: bool | None = None,
        latency: int | None = None,
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
                i_req_data_if_modified=int(modified),
                i_req_no_touch=int(no_touch),
            )
        await self.drive(**fields)
        await self.wait("o_req_ready")
        await self.drive(i_req_valid=1)
        await self.tick()
        await self.drive(i_req_valid=0)
        elapsed = await self.wait("o_resp_valid")
        if latency is not None:
            assert elapsed == latency, (elapsed, latency)
        result = (
            self.get("o_resp_hit"),
            self.get("o_resp_way"),
            self.get("o_resp_addr"),
            self.get("o_resp_state"),
        )
        payload = self.get("o_resp_tags" if self.home else "o_resp_data")
        captured_available = self.get("o_resp_available")
        valid = None if self.home else self.get("o_resp_data_valid")
        if data_valid is not None:
            assert valid == int(data_valid)
        if available is not None:
            assert captured_available == int(available)
        for _ in range(hold):
            await self.tick()
            assert self.get("o_resp_valid")
            assert (
                tuple(
                    self.get(name)
                    for name in (
                        "o_resp_hit",
                        "o_resp_way",
                        "o_resp_addr",
                        "o_resp_state",
                    )
                )
                == result
            )
            assert self.get("o_resp_available") == captured_available
            assert self.get("o_resp_tags" if self.home else "o_resp_data") == payload
            if not self.home:
                assert self.get("o_resp_data_valid") == valid
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
    """Observe each hit's replacement update, or none for a no-touch hit."""
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
    # A no-touch hit on way 2 keeps it the next victim; a touching hit does not.
    for no_touch, victim in ((True, 2), (False, 1)):
        assert (await b.lookup(3 * b.sets * b.line, no_touch=no_touch))[0] == 1
        hit, selected, _, _, _ = await b.lookup(0)
        assert (hit, selected) == (0, victim)


@cocotb.test()
async def data_selection_uses_highest_matching_way(dut: Any) -> None:
    """Check duplicate tags, modified-only reads, skip flags and visit priority."""
    b = ResetArray(dut)
    if b.home:
        return
    await b.reset()
    address = b.sets * b.line
    values = [int.from_bytes(bytes([way + 1]) * b.line, "little") for way in range(4)]
    tag_latency, data_latency = (3, 6) if b.ultra else (1, 2)
    for way in range(4):
        await b.update(address, way, values[way], state=0)
    for lower, higher in ((3, 1), (1, 3), (3, 3), (3, 0), (0, 0)):
        await b.update(address, 0, values[0], state=lower)
        await b.update(address, 3, values[3], state=higher)
        states = [lower, 0, 0, higher]
        for miss in (False, True):
            request_address = address * (3 if miss else 1)
            matched = not miss and bool(lower or higher)
            hit_way = 3 if higher else 0
            hit_modified = matched and states[hit_way] == 3
            for skip, modified in (
                (False, False),
                (True, False),
                (False, True),
                (True, True),
            ):
                for visit in (None, 0, 3):
                    expected_data = visit is not None or (
                        not (matched and skip) and (not modified or hit_modified)
                    )
                    prior = b.get("o_resp_data")
                    # Exclusions affect replacement; a matching excluded way wins.
                    hit, way, returned_address, state, payload = await b.lookup(
                        request_address,
                        exclude=8,
                        visit=visit,
                        skip=skip,
                        modified=modified,
                        hold=2,
                        data_valid=expected_data,
                        available=True,
                        latency=tag_latency + (data_latency if expected_data else 0),
                    )
                    assert hit == int(matched and visit is None)
                    if visit is not None:
                        assert way == visit
                    elif matched:
                        assert way == hit_way
                    assert state == states[way]
                    assert returned_address == address
                    assert payload == (values[way] if expected_data else prior)
    addresses = [(way + 1) * address for way in range(4)]
    for way in range(4):
        await b.update(addresses[way], way, values[way])
    for skip, modified in ((False, False), (True, False), (False, True), (True, True)):
        prior = b.get("o_resp_data")
        hit, way, returned_address, state, payload = await b.lookup(
            7 * address,
            skip=skip,
            modified=modified,
            hold=2,
            data_valid=not modified,
            available=True,
            latency=tag_latency + (0 if modified else data_latency),
        )
        assert hit == 0 and state == 3
        assert returned_address == addresses[way]
        assert payload == (prior if modified else values[way])

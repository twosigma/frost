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

"""Check per-way NRU hit-port touches beside controller no-op writes."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


class NruPortArray:
    """Drive coherence_array with BIMODAL_INSERT=1 and HIT_PORT=1."""

    def __init__(self, dut: Any) -> None:
        """Bind a 4-set, 4-way bimodal hit-port array under test."""
        self.dut = dut
        self.line = len(dut.i_update_mask)
        self.sets = 4
        self.ways = 4

    def get(self, name: str) -> int:
        """Sample an output port as an integer."""
        return int(getattr(self.dut, name).value)

    async def drive(self, **values: int) -> None:
        """Drive input ports between clock edges."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    async def tick(self) -> None:
        """Advance the clock by one full cycle."""
        await self.drive(i_clk=1)
        await self.drive(i_clk=0)

    def addr(self, set_idx: int, tag: int) -> int:
        """Build a line-aligned byte address for the given set and tag."""
        return ((tag * self.sets) + set_idx) * self.line

    async def reset(self) -> None:
        """Reset the array and wait until initialization completes."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.drive(i_rst=1)
        await self.tick()
        await self.drive(i_rst=0, i_resp_ready=1)
        for _ in range(32):
            if self.get("o_req_ready") and self.get("o_update_ready"):
                return
            await self.tick()
        raise AssertionError("array did not leave Init")

    async def write_line(
        self,
        address: int,
        way: int,
        state: int = 3,
        data: int = 0x55,
        insert: int = 0,
        touch: int = 0,
        mask: int | None = None,
    ) -> None:
        """Issue one controller update and wait until ready."""
        if mask is None:
            mask = (1 << self.line) - 1
        while not self.get("o_update_ready"):
            await self.tick()
        await self.drive(
            i_update_valid=1,
            i_update_addr=address,
            i_update_way=way,
            i_update_state=state,
            i_update_insert=insert,
            i_update_touch=touch,
            i_update_mask=mask,
            i_update_data=data,
        )
        await self.tick()
        await self.drive(i_update_valid=0, i_update_insert=0, i_update_touch=0)
        while not self.get("o_update_ready"):
            await self.tick()

    async def lookup(
        self,
        address: int,
        exclude: int = 0,
        skip: bool = True,
        no_bank: bool = True,
    ) -> tuple[int, int, int]:
        """Issue one controller lookup and return (hit, way, state)."""
        while not self.get("o_req_ready"):
            await self.tick()
        await self.drive(
            i_req_valid=1,
            i_req_addr=address,
            i_req_exclude=exclude,
            i_req_skip_data_on_hit=int(skip),
            i_req_no_bank=int(no_bank),
            i_resp_ready=1,
        )
        await self.tick()
        await self.drive(i_req_valid=0)
        for _ in range(16):
            if self.get("o_resp_valid"):
                res = (
                    self.get("o_resp_hit"),
                    self.get("o_resp_way"),
                    self.get("o_resp_state"),
                )
                await self.tick()
                return res
            await self.tick()
        raise AssertionError("lookup response timed out")

    async def populate_two_sets(self, set0_state: int = 3) -> None:
        """Install four resident lines in set 0 and four in set 1 with NRU=0."""
        for way in range(self.ways):
            await self.write_line(
                self.addr(0, way + 1), way, state=set0_state, data=0x10 + way
            )
            await self.write_line(self.addr(1, way + 1), way, state=1, data=0x20 + way)

    async def check_way_nru_is_one(self, set_idx: int, way: int) -> None:
        """Verify way's NRU bit in set_idx is 1 via external victim selection."""
        if way < self.ways - 1:
            other = way + 1
            exclude = 0xF ^ ((1 << way) | (1 << other))
            expected_victim = other
        else:
            # Way 0 was pre-touched to 1; when way 3 is also 1, fallback is 0.
            exclude = 0xF ^ ((1 << 0) | (1 << way))
            expected_victim = 0
        hit, victim, _ = await self.lookup(self.addr(set_idx, 9), exclude=exclude)
        assert hit == 0, f"expected miss in set {set_idx}"
        assert victim == expected_victim, (
            f"set {set_idx} way {way} load touch was dropped: "
            f"miss picked victim way {victim}, expected {expected_victim}"
        )


@cocotb.test()
async def redundant_store_hit_does_not_drop_load_touch(dut: Any) -> None:
    """Keep concurrent load touch when a store hits an already-hot way."""
    arr = NruPortArray(dut)
    for way in range(arr.ways):
        await arr.reset()
        await arr.populate_two_sets(set0_state=3)
        # Touch set 0 way so its NRU bit is already 1 before the store hit.
        hit, hit_way, _ = await arr.lookup(arr.addr(0, way + 1))
        assert (hit, hit_way) == (1, way)
        # For way 3, pre-touch set 1 way 0 so way 3's NRU=1 forces fallback to 0.
        if way == arr.ways - 1:
            hit, hit_way, _ = await arr.lookup(arr.addr(1, 1))
            assert (hit, hit_way) == (1, 0)

        # Launch a Modified store hit to set 0 way and a hit-port load to set 1
        # way on the same cycle: the store reaches Reply (where plru_hit_q would
        # fire) on the exact cycle the load reaches stage 3 (o_hp_hit=1).
        assert arr.get("o_req_ready") == 1 and arr.get("o_hp_ready") == 1
        await arr.drive(
            i_req_valid=1,
            i_req_addr=arr.addr(0, way + 1),
            i_req_skip_data_on_hit=1,
            i_req_no_bank=1,
            i_resp_ready=1,
            i_hp_valid=1,
            i_hp_addr=arr.addr(1, way + 1),
        )
        await arr.tick()
        await arr.drive(i_req_valid=0, i_hp_valid=0)
        await arr.tick()
        # Cycle t+2: store hit is in Reply AND hit-port load is in stage 3.
        assert arr.get("o_resp_valid") == 1 and arr.get("o_resp_hit") == 1
        assert arr.get("o_resp_way") == way
        assert arr.get("o_hp_hit") == 1
        await arr.tick()

        await arr.check_way_nru_is_one(1, way)


@cocotb.test()
async def redundant_upgrade_insert_does_not_drop_load_touch(dut: Any) -> None:
    """Keep concurrent load touch when an S->M upgrade writes an already-hot way."""
    arr = NruPortArray(dut)
    for way in range(arr.ways):
        await arr.reset()
        await arr.populate_two_sets(set0_state=1)
        if way == arr.ways - 1:
            hit, hit_way, _ = await arr.lookup(arr.addr(1, 1))
            assert (hit, hit_way) == (1, 0)
        # Upgrade lookup hits set 0 way in Shared state, leaving o_resp_hit=1
        # and set 0 way's NRU bit set to 1.
        hit, hit_way, state = await arr.lookup(arr.addr(0, way + 1))
        assert (hit, hit_way, state) == (1, way, 1)

        # Launch hit-port load to set 1 way; two cycles later (stage 3) drive
        # the S->M upgrade update (i_update_insert=1, o_resp_hit=1 => promote).
        assert arr.get("o_hp_ready") == 1
        await arr.drive(i_hp_valid=1, i_hp_addr=arr.addr(1, way + 1))
        await arr.tick()
        await arr.drive(i_hp_valid=0)
        await arr.tick()
        assert arr.get("o_hp_hit") == 1 and arr.get("o_update_ready") == 1
        await arr.drive(
            i_update_valid=1,
            i_update_addr=arr.addr(0, way + 1),
            i_update_way=way,
            i_update_state=3,
            i_update_insert=1,
            i_update_touch=0,
            i_update_mask=0,
        )
        await arr.tick()
        await arr.drive(i_update_valid=0, i_update_insert=0)

        await arr.check_way_nru_is_one(1, way)


@cocotb.test()
async def promoted_full_set_clear_preserves_target_way_load_touch(dut: Any) -> None:
    """Keep target-way load touch free during a promoted full-set NRU clear."""
    arr = NruPortArray(dut)
    await arr.reset()
    await arr.populate_two_sets(set0_state=3)
    # Set all four NRU bits in set 0 so a miss arms nru_clear_q on victim way 0.
    for way in range(arr.ways):
        hit, hit_way, _ = await arr.lookup(arr.addr(0, way + 1))
        assert (hit, hit_way) == (1, way)
    hit, victim, _ = await arr.lookup(arr.addr(0, 9), skip=False, no_bank=False)
    assert (hit, victim) == (0, 0)

    # Launch hit-port load to set 1 way 0; two cycles later install set 0 way 0
    # with i_update_touch=1 (promoted). Ways 1..3 clear 1->0, while way 0 is a
    # no-op 1->1 and must leave way 0's NRU port free for set 1's load touch.
    assert arr.get("o_hp_ready") == 1
    await arr.drive(i_hp_valid=1, i_hp_addr=arr.addr(1, 1))
    await arr.tick()
    await arr.drive(i_hp_valid=0)
    await arr.tick()
    assert arr.get("o_hp_hit") == 1 and arr.get("o_update_ready") == 1
    await arr.drive(
        i_update_valid=1,
        i_update_addr=arr.addr(0, 9),
        i_update_way=0,
        i_update_state=1,
        i_update_insert=1,
        i_update_touch=1,
        i_update_mask=(1 << arr.line) - 1,
        i_update_data=0x99,
    )
    await arr.tick()
    await arr.drive(i_update_valid=0, i_update_insert=0, i_update_touch=0)
    while not arr.get("o_req_ready"):
        await arr.tick()

    # Set 1 way 0's load touch succeeded (victim is way 1, not way 0).
    await arr.check_way_nru_is_one(1, 0)
    # Set 0 ways 1..3 were still cleared to 0 while way 0 stayed 1 (victim is 1).
    hit, set0_victim, _ = await arr.lookup(arr.addr(0, 10))
    assert (hit, set0_victim) == (0, 1)

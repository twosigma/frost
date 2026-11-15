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

"""Check shared-link reads against four independently written reference banks."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def test_allocation_overrides_and_reused_addresses(dut: Any) -> None:
    """Sweep every read address through allocation, drain and CDB collisions."""
    rng = random.Random(298)
    address_width = len(dut.i_read_address)
    data_width = len(dut.o_read_data)
    link_width = len(dut.i_alloc_link) // 2
    depth = 1 << address_width
    banks = [[0] * depth for _ in range(4)]
    lvt = [0] * depth
    staged: list[tuple[int, int]] = []
    dut.i_clk.value = 0
    dut.i_check_enable.value = 0
    dut.i_read_address.value = 0
    dut.i_read_onehot.value = 1

    for cycle in range(depth + 300):
        # Initialize every row before observing it, including random startup.
        initializing = cycle < depth
        enables = [1, 0] if initializing else [rng.randrange(2), rng.randrange(2)]
        addresses = (
            [cycle, 0] if initializing else [rng.randrange(depth) for _ in range(2)]
        )
        branches = [0, 0] if initializing else [rng.randrange(2) for _ in range(2)]
        if branches[0]:
            enables[1] = 0
        links = [rng.getrandbits(link_width) for _ in range(2)]
        cdb_enables = [0, 0] if initializing else [rng.randrange(2) for _ in range(2)]
        # Frequently collide with live and staged allocations and the other CDB.
        candidates = addresses + [address for address, _ in staged]
        cdb_addresses = [rng.choice(candidates) for _ in range(2)]
        cdb_values = [rng.getrandbits(data_width) for _ in range(2)]

        def packed(values: list[int], width: int) -> int:
            return values[0] | (values[1] << width)

        dut.i_alloc_enable.value = packed(enables, 1)
        dut.i_alloc_address.value = packed(addresses, address_width)
        dut.i_alloc_branch.value = packed(branches, 1)
        dut.i_alloc_link.value = packed(links, link_width)
        dut.i_cdb_enable.value = packed(cdb_enables, 1)
        dut.i_cdb_address.value = packed(cdb_addresses, address_width)
        dut.i_cdb_data.value = packed(cdb_values, data_width)
        await Timer(1, unit="ns")
        dut.i_clk.value = 1

        for address, bank in staged:
            lvt[address] = bank
        for lane in range(2):
            if cdb_enables[lane]:
                banks[lane + 2][cdb_addresses[lane]] = cdb_values[lane]
                lvt[cdb_addresses[lane]] = lane + 2
        staged = []
        for slot in range(2):
            if enables[slot]:
                banks[slot][addresses[slot]] = links[slot] if branches[slot] else 0
                staged.append((addresses[slot], slot))

        await Timer(1, unit="ns")
        dut.i_check_enable.value = 1
        dut.i_clk.value = 0
        if initializing:
            continue
        for address in range(depth):
            dut.i_read_address.value = address
            dut.i_read_onehot.value = 1 << address
            await Timer(100, unit="ps")
            bank = lvt[address]
            for staged_address, staged_bank in staged:
                if staged_address == address:
                    bank = staged_bank
            assert int(dut.o_read_data.value) == banks[bank][address], (
                f"cycle={cycle}, address={address}, bank={bank}"
            )

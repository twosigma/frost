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

"""Check local atomics beside unrelated acquisition endpoints."""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack
from cocotb_tests.cache.test_coherence_l1d import Private, getm, local_atomic, store


@cocotb.test()
async def local_atomic_finishes_with_uninstalled_load_grant(dut: Any) -> None:
    """Complete the tagged write with an unrelated same-set grant and held P."""
    for sc in (False, True):
        b = Private(dut)
        await b.reset()
        address = 0x80000000
        old = 0x123456789ABCDEF0
        await store(b, address, old)
        await getm(b, address, old)
        # With the one-way geometry, this grant must replace the atomic's way.
        other = address + 512
        await b.set(
            i_read_valid=1, i_read_id=1, i_address=other, i_read_kind=0, i_read_size=3
        )
        await b.tick()
        await b.set(i_read_valid=0)
        for _ in range(100):
            if b.get("o_d_valid"):
                break
            await b.tick()
        demand_mask = b.get("o_d_valid")
        assert demand_mask and not demand_mask & 1
        endpoint = demand_mask.bit_length() - 1
        demand = unpack(
            (b.get("o_d") >> (endpoint * (b.p + 312))) & ((1 << (b.p + 312)) - 1),
            (4, 9, b.p, 5, 3, 32, 1, 1, 1, 256),
        )
        await b.set(i_d_ready=demand_mask)
        await b.tick()
        await b.set(i_d_ready=0)
        grant = pack(
            (3, 1),
            (9, demand[1]),
            (6, 7),
            (b.p, other),
            (256, 0x1122334455667788),
            (1, 0),
        )
        updated = old + 1
        actual = await local_atomic(
            b, address, old, updated, sc=sc, pending_grant=grant
        )
        assert actual == updated
        assert b.get("live") & demand_mask
        await b.wait("o_read_valid")
        assert b.get("o_read_id") == 1 and b.get("o_read_data") == 0x1122334455667788
        await b.set(i_read_ready=1)
        await b.tick()
        await b.set(i_read_ready=0)
        for _ in range(100):
            if b.get("o_c_valid") & demand_mask:
                break
            await b.tick()
        assert b.get("o_c_valid") & demand_mask
        await b.set(i_c_ready=demand_mask)
        await b.tick()
        await b.set(i_c_ready=0)
        # U remains held after the local atomic and the load have both completed.
        await b.tick(10)
        assert b.get("live") & demand_mask
        assert not b.get("o_atomic_live") and not b.get("o_fatal")
        await b.set(i_u_valid=1, i_u=pack((9, demand[1]), (6, 7), (b.p, other)))
        await b.wait("o_u_ready")
        await b.tick()
        await b.set(i_u_valid=0)
        assert not b.get("live")

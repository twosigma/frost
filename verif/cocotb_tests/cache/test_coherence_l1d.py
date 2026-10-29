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

"""Exercise private service with independently held home channels."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack


class Private:
    """Step the private cache without coupling probe and grant receivers."""

    def __init__(self, dut: Any) -> None:
        """Record the cache interface."""
        self.dut = dut
        self.p = len(dut.i_address)

    def get(self, name: str) -> int:
        """Read a packed signal."""
        return int(getattr(self.dut, name).value)

    async def set(self, **values: int) -> None:
        """Set inputs and settle combinational logic."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    async def tick(self, count: int = 1) -> None:
        """Advance the requested clock edges."""
        for _ in range(count):
            await self.set(i_clk=1)
            await self.set(i_clk=0)

    async def wait(self, name: str, value: int = 1) -> None:
        """Bound a protocol wait."""
        for _ in range(200):
            if self.get(name) == value:
                return
            await self.tick()
        raise AssertionError(f"{name} did not become {value}")

    async def reset(self) -> None:
        """Clear ownership and finish tag initialization."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1)
        await self.tick(2)
        await self.set(i_rst=0)
        await self.tick(20)


@cocotb.test()
async def held_probe_reply_defers_grant_application(dut: Any) -> None:
    """Apply a grant once after the preceding probe reply is accepted."""
    for store in (False, True):
        b = Private(dut)
        await b.reset()
        address = 0x80000000
        await b.set(
            i_address=address,
            i_write_mask=255 if store else 0,
            i_write_data=0xAABBCCDD,
            i_read_valid=int(not store),
        )
        await b.tick()
        await b.set(i_read_valid=0, i_write_mask=0)
        await b.wait("o_d_valid")
        demand = unpack(b.get("o_d"), (4, 9, b.p, 5, 3, 32, 1, 1, 1, 256))
        await b.set(i_d_ready=1)
        await b.tick()
        await b.set(i_d_ready=0)
        probe = pack(
            (2, 0),
            (6, 8),
            (1, 0),
            (b.p, address + 128),
            (2, 2),
            (2, 0),
            (9, 0),
            (5, 0),
            (3, 0),
        )
        await b.set(i_p_valid=1, i_p=probe)
        await b.wait("o_p_ready")
        await b.tick()
        await b.set(i_p_valid=0)
        grant = pack(
            (3, 2 if store else 0),
            (9, demand[1]),
            (6, 0),
            (b.p, address),
            (256, 0x12345678),
            (1, int(not store)),
        )
        await b.set(i_g_valid=1, i_g=grant)
        await b.wait("o_g_ready")
        await b.tick()
        await b.set(i_g_valid=0)
        await b.wait("o_r_valid")
        for _ in range(24):
            assert not b.get("grant_ready")
            assert not b.get("done_q") and not b.get("o_read_valid")
            if store:
                assert b.get("o_pending_store")
            await b.tick()
        await b.set(i_r_ready=1)
        await b.tick()
        await b.set(i_r_ready=0)
        if store:
            await b.wait("o_store_ready")
            await b.set(
                i_address=address + 8, i_write_mask=255, i_write_data=0x99887766
            )
            await b.tick()
            await b.set(i_write_mask=0)
        else:
            await b.wait("o_read_valid")
            assert b.get("o_read_error")
        await b.wait("o_c_valid")
        completion = unpack(b.get("o_c"), (9, 6, b.p, 2, 1))
        assert completion[0:3] == (demand[1], 0, address)
        assert completion[3] == (0 if store else 2)
        await b.set(i_c_ready=1)
        await b.tick()
        await b.set(
            i_c_ready=0, i_u_valid=1, i_u=pack((9, demand[1]), (6, 0), (b.p, address))
        )
        await b.wait("o_u_ready")
        await b.tick()
        await b.set(i_u_valid=0)
        if store:
            await b.wait("o_write_done")
            await b.tick()
            await b.set(i_read_valid=1, i_read_id=0, i_address=address + 8)
            await b.tick()
            await b.set(i_read_valid=0)
            await b.wait("o_read_valid")
            assert b.get("o_read_data") == 0x99887766
        assert not b.get("o_fatal")

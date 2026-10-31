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

"""Check DMA queue ownership against independently delayed home responses."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack


class Ingress:
    """Step the line requester and home without sharing transaction identities."""

    def __init__(self, dut: Any) -> None:
        """Use high addresses and four-bit IDs on the elaborated interface."""
        self.dut = dut
        self.p = len(dut.i_req_addr)
        self.base = (1 << (self.p - 1)) + 0x100
        self.responses: list[tuple[int, int, int]] = []
        self.completions: list[tuple[int, ...]] = []

    def get(self, name: str) -> int:
        """Read a signal after combinational settlement."""
        return int(getattr(self.dut, name).value)

    async def set(self, **values: int) -> None:
        """Drive inputs between rising edges."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    async def tick(self, count: int = 1) -> None:
        """Advance bounded clock edges."""
        for _ in range(count):
            await self.set(i_clk=0)
            if not self.get("i_rst"):
                if self.get("o_resp_valid"):
                    self.responses.append(
                        (
                            self.get("o_resp_id"),
                            self.get("o_resp_data"),
                            self.get("o_resp_error"),
                        )
                    )
                if self.get("o_c_valid") and self.get("i_c_ready"):
                    self.completions.append(
                        unpack(self.get("o_c"), (9, 6, self.p, 2, 1))
                    )
            await self.set(i_clk=1)
            await self.set(i_clk=0)

    async def reset(self) -> None:
        """Discard both requester and home ownership in one reset epoch."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1)
        await self.tick(2)
        await self.set(i_rst=0)
        self.responses.clear()
        self.completions.clear()

    async def wait(self, signal: str, limit: int = 100) -> None:
        """Bound every local protocol wait."""
        for _ in range(limit):
            if self.get(signal):
                return
            await self.tick()
        raise AssertionError(f"{signal} did not progress")

    def q(self, ident: int) -> int:
        """Keep source and class separate from the opaque ingress identity."""
        return pack((2, 2), (2, 3), (4, ident), (1, 0))

    def address(self, ident: int) -> int:
        """Make adjacent requests share sectors without changing their identity."""
        return self.base + 32 * (ident // 4)

    async def enqueue(self, ident: int) -> None:
        """Admit one request with distinguishable data and byte enables."""
        await self.set(
            i_req_valid=1,
            i_req_id=ident,
            i_req_addr=self.address(ident),
            i_req_write=ident & 1,
            i_req_data=(1 << (16 * ident)) | ident,
            i_req_mask=0x80000001 | (1 << ident),
        )
        assert self.get("o_req_ready")
        await self.tick()
        await self.set(i_req_valid=0)

    async def demand(self, ident: int) -> None:
        """Verify the oldest complete payload, including a stalled presentation."""
        assert self.get("o_d_valid")
        expected = pack(
            (4, 8 if ident & 1 else 7),
            (9, self.q(ident)),
            (self.p, self.address(ident)),
            (5, 0),
            (3, 5),
            (32, 0x80000001 | (1 << ident)),
            (1, 0),
            (1, 0),
            (1, 0),
            (256, (1 << (16 * ident)) | ident),
        )
        for _ in range(3):
            assert self.get("o_d") == expected
            assert not self.get("o_resp_valid")
            await self.tick()
        await self.set(i_d_ready=1)
        await self.tick()
        await self.set(i_d_ready=0)

    async def grant(self, ident: int, error: int = 0) -> None:
        """Reject a wrong identity and preserve a delayed valid grant."""
        grant = pack(
            (3, 4 if ident & 1 else 3),
            (9, self.q(ident)),
            (6, ident + 19),
            (self.p, self.address(ident)),
            (256, (1 << (ident * 16)) | 0xA55A),
            (1, error),
        )
        for bit in (self.p + 257 + 6 + 1, 257 + 5):
            await self.set(i_g_valid=1, i_g=grant ^ (1 << bit))
            assert not self.get("o_g_ready")
            await self.tick()
            assert not self.get("o_c_valid")
        await self.set(i_g=grant)
        assert self.get("o_g_ready")
        await self.tick()
        await self.set(i_g_valid=0)
        assert self.get("o_c_valid")
        expected = (
            self.q(ident),
            ident + 19,
            self.address(ident),
            2 if error else 0,
            1,
        )
        for _ in range(4):
            assert self.get("o_c_valid")
            assert unpack(self.get("o_c"), (9, 6, self.p, 2, 1)) == expected
            assert not self.get("o_resp_valid")
            await self.tick()

    async def complete(self, ident: int, error: int = 0) -> None:
        """Require matching release before external completion and ID reuse."""
        await self.set(i_c_ready=1)
        await self.tick()
        await self.set(i_c_ready=0)
        release = pack(
            (9, self.q(ident)), (6, ident + 19), (self.p, self.address(ident))
        )
        for bit in (self.p, self.p + 6 + 1, 5):
            await self.set(i_u_valid=1, i_u=release ^ (1 << bit))
            assert not self.get("o_u_ready")
            await self.tick()
            assert not self.get("o_resp_valid")
        await self.set(i_u_valid=0, i_u=release, i_req_id=ident)
        await self.tick(4)
        assert not self.get("o_req_ready") and not self.get("o_resp_valid")
        await self.set(i_u_valid=1)
        assert self.get("o_u_ready")
        await self.tick()
        await self.set(i_u_valid=0)
        assert self.get("o_resp_valid")
        assert self.get("o_resp_id") == ident
        assert self.get("o_resp_data") == (1 << (ident * 16)) | 0xA55A
        assert self.get("o_resp_error") == error
        assert not self.get("o_req_ready")
        await self.tick()
        assert self.get("o_req_ready") and not self.get("o_resp_valid")


@cocotb.test()
async def all_ids_and_completion_delay(dut: Any) -> None:
    """Every credit in use holds back the next ID across all sixteen identities."""
    b = Ingress(dut)
    await b.reset()
    slots = len(dut.c_valid)
    for start in range(0, 16, slots):
        for ident in range(start, start + slots):
            await b.enqueue(ident)
        await b.set(i_req_valid=1, i_req_id=(start + slots) % 16)
        assert not b.get("o_req_ready")
        await b.tick(3)
        await b.set(i_req_valid=0)
        for ident in range(start, start + slots):
            await b.demand(ident)
            await b.grant(ident, error=ident % 3 == 0)
            await b.complete(ident, error=ident % 3 == 0)
    assert not b.get("o_d_valid")


@cocotb.test()
async def reset_at_each_home_stage(dut: Any) -> None:
    """Reset clears queued, granted and unreleased ownership without a response."""
    b = Ingress(dut)
    for stage in range(6):
        await b.reset()
        for ident in (15, 8, 0, 7):
            await b.enqueue(ident)
        if stage >= 1:
            await b.demand(15)
        if stage >= 2:
            await b.grant(15)
        if stage >= 3:
            await b.set(i_c_ready=1)
            await b.tick()
            await b.set(i_c_ready=0)
        if stage >= 4:
            await b.set(
                i_u_valid=1, i_u=pack((9, b.q(15)), (6, 34), (b.p, b.address(15)))
            )
            await b.wait("o_u_ready")
            await b.tick()
            await b.set(i_u_valid=0)
        if stage >= 5:
            await b.wait("o_resp_valid")
        await b.reset()
        assert not b.get("o_d_valid") and not b.get("o_resp_valid")
        await b.set(i_fatal_stop=1, i_req_valid=1, i_req_id=15)
        assert not b.get("o_req_ready")
        await b.tick(3)
        await b.set(i_fatal_stop=0, i_req_valid=0)
        await b.enqueue(15)
        await b.demand(15)
        await b.grant(15)
        await b.complete(15)


@cocotb.test()
async def issue_all_credits_and_complete_out_of_order(dut: Any) -> None:
    """Issue four requests before any grant and match reordered G/C/U by full identity."""
    b = Ingress(dut)
    await b.reset()
    ids = (0, 1, 8, 15)
    for ident in ids:
        await b.enqueue(ident)
    for ident in ids:
        await b.demand(ident)
    assert not b.get("o_d_valid") and not b.get("o_resp_valid")
    held = None
    for ident in (8, 1, 15, 0):
        grant = pack(
            (3, 4 if ident & 1 else 3),
            (9, b.q(ident)),
            (6, ident + 19),
            (b.p, b.address(ident)),
            (256, (1 << (ident * 16)) | 0xA55A),
            (1, int(ident == 15)),
        )
        await b.set(i_g_valid=1, i_g=grant)
        assert b.get("o_g_ready")
        await b.tick()
        await b.set(i_g_valid=0)
        await b.wait("o_c_valid")
        if held is None:
            held = b.get("o_c")
        assert b.get("o_c") == held
    await b.tick(10)
    assert b.get("o_c") == held and not b.responses
    await b.set(i_c_ready=1)
    for _ in range(30):
        if len(b.completions) == 4:
            break
        await b.tick()
    await b.set(i_c_ready=0)
    assert len(b.completions) == 4
    assert {c[0] for c in b.completions} == {b.q(ident) for ident in ids}
    for q, tid, address, status, written in b.completions:
        ident = (q >> 1) & 15
        assert (tid, address, status, written) == (
            ident + 19,
            b.address(ident),
            2 if ident == 15 else 0,
            1,
        )
    assert not b.responses
    for ident in (1, 0, 15, 8):
        await b.set(
            i_u_valid=1,
            i_u=pack((9, b.q(ident)), (6, ident + 19), (b.p, b.address(ident))),
        )
        assert b.get("o_u_ready")
        await b.tick()
        assert b.get("o_resp_valid") and b.get("o_resp_id") == ident
        await b.set(i_u_valid=0)
    for _ in range(30):
        if len(b.responses) == 4:
            break
        await b.tick()
    assert len(b.responses) == 4
    assert {r[0] for r in b.responses} == set(ids)
    for ident, data, error in b.responses:
        assert data == (1 << (ident * 16)) | 0xA55A
        assert error == int(ident == 15)
    for ident in ids:
        await b.enqueue(ident)
    for ident in ids:
        await b.demand(ident)


@cocotb.test()
async def younger_response_reuses_credit_before_oldest_grant(dut: Any) -> None:
    """Complete and reuse a younger ID while the oldest request waits for G."""
    b = Ingress(dut)
    await b.reset()
    for ident in (0, 4, 8, 12):
        await b.enqueue(ident)
    for ident in (0, 4, 8, 12):
        await b.demand(ident)
    await b.grant(4, error=1)
    await b.complete(4, error=1)
    assert [response[0] for response in b.responses] == [4]
    await b.enqueue(4)
    await b.demand(4)
    await b.grant(4)
    await b.complete(4)
    assert [response[0] for response in b.responses] == [4, 4]
    for ident in (8, 12, 0):
        await b.grant(ident)
        await b.complete(ident)
    assert [response[0] for response in b.responses] == [4, 4, 8, 12, 0]

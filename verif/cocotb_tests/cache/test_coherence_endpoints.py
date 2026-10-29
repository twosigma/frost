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

"""Exercise independent coherent endpoint slots with programmable peers."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


def pack(*fields: tuple[int, int]) -> int:
    """Pack fields in wire order, most significant field first."""
    value = 0
    for bits, field in fields:
        assert 0 <= field < (1 << bits)
        value = (value << bits) | field
    return value


class Bench:
    """Drive endpoint peers with a manually stepped clock."""

    def __init__(self, dut: Any) -> None:
        """Record the elaborated address width and deterministic data source."""
        self.dut = dut
        self.p = len(dut.i_req_request) - 312
        self.addr = (1 << (self.p - 1)) + 0x100
        self.rng = random.Random(20261025)

    def get(self, name: str) -> int:
        """Read a scalar or packed payload."""
        return int(getattr(self.dut, name).value)

    async def set(self, **values: int) -> None:
        """Drive inputs and let combinational outputs settle."""
        for name, value in values.items():
            getattr(self.dut, name).value = value
        await Timer(1, unit="ns")

    async def tick(self, count: int = 1) -> None:
        """Advance the requested number of clock edges."""
        for _ in range(count):
            await self.set(i_clk=0)
            await self.set(i_clk=1)
            await self.set(i_clk=0)

    async def reset(self, epoch: int = 0) -> None:
        """Reset every endpoint and select a cluster epoch."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.set(i_rst=1, i_epoch=epoch)
        await self.tick(2)
        await self.set(i_rst=0)

    def d(self, q: int = 0, op: int = 0) -> int:
        """Encode an acquisition request."""
        return pack(
            (4, op),
            (9, q),
            (self.p, self.addr),
            (5, 0),
            (3, 6 if op == 9 else (5 if op in (5, 6, 7, 8) else 3)),
            (32, 0xFF if op in (1, 3, 4, 8) else 0),
            (1, 0),
            (1, 0),
            (1, 0),
            (256, 0),
        )

    def g(self, q: int = 0, tid: int = 0, op: int = 0, error: int = 0) -> int:
        """Encode a grant with a full sector image."""
        return pack(
            (3, op),
            (9, q),
            (6, tid),
            (self.p, self.addr),
            (256, self.rng.getrandbits(256)),
            (1, error),
        )

    def c(self, q: int = 0, tid: int = 0, status: int = 0, written: int = 0) -> int:
        """Encode a completion."""
        return pack((9, q), (6, tid), (self.p, self.addr), (2, status), (1, written))

    def u(self, q: int = 0, tid: int = 0) -> int:
        """Encode a final release."""
        return pack((9, q), (6, tid), (self.p, self.addr))

    def w(self, slot: int = 0, epoch: int = 0) -> int:
        """Encode a frozen dirty sector."""
        return pack(
            (1, 0),
            (1, slot),
            (1, epoch),
            (self.p, self.addr),
            (256, self.rng.getrandbits(256)),
            (1, 1),
        )

    def wa(
        self,
        slot: int = 0,
        absorbed: int = 0,
        tid: int = 0,
        epoch: int = 0,
        error: int = 0,
        addr: int | None = None,
    ) -> int:
        """Encode an ordinary or absorbed PutAck."""
        return pack(
            (1, 0),
            (1, slot),
            (1, epoch),
            (self.p, self.addr if addr is None else addr),
            (1, absorbed),
            (6, tid),
            (1, error),
        )

    def r(self, slot: int = 0) -> int:
        """Encode a dirty probe reply that absorbs a frozen slot."""
        return pack(
            (2, 1),
            (6, 0),
            (1, 0),
            (1, 0),
            (self.p, self.addr),
            (2, 0),
            (1, 1),
            (1, 1),
            (256, 0xDEADBEEF),
            (1, 1),
            (1, slot),
            (1, 0),
            (1, 0),
            (1, 0),
        )

    async def held(self, valid: str, payload: str, value: int, count: int = 7) -> None:
        """Check valid and every payload bit while the receiver stalls."""
        for _ in range(count):
            assert self.get(valid) == 1
            assert self.get(payload) == value
            await self.tick()


@cocotb.test()
async def widths_and_independent_queues(dut: Any) -> None:
    """Check every channel width and independent demand and probe storage."""
    b = Bench(dut)
    await b.reset()
    expected = [b.p + n for n in (312, 30, 275, 260, 11, 275, 18, 15)]
    assert b.get("o_widths") == pack(*[(32, n) for n in expected])
    layout = b.get("o_layout")
    completions, fills, puts, count = [
        (layout >> shift) & 127 for shift in (21, 14, 7, 0)
    ]
    assert completions in (19, 30)
    assert fills == completions
    assert puts - fills in (4, 16)
    assert count == puts + (2 if completions == 19 else 4)
    await b.set(
        i_req_request=b.d(),
        i_req_request_valid=1,
        i_ptw_request=b.d(q=64, op=6),
        i_ptw_request_valid=1,
    )
    await b.tick()
    await b.set(i_req_request_valid=0, i_ptw_request_valid=0, i_ptw_d_ready=1)
    await b.tick()
    assert b.get("o_req_d_valid") == 1
    assert b.get("o_ptw_d_valid") == 0
    for name, width in (("probe", b.p + 30), ("reply", b.p + 275)):
        payload = b.rng.getrandbits(width)
        await b.set(**{f"i_{name}_valid": 1, f"i_{name}_payload": payload})
        assert b.get(f"o_{name}_ready") == 1
        await b.tick()
        await b.set(**{f"i_{name}_valid": 0, f"i_{name}_payload": 0})
        assert b.get(f"o_{name}_ready") == 0
        await b.held(f"o_{name}_valid", f"o_{name}_payload", payload)
        await b.set(**{f"i_{name}_ready": 1})
        await b.tick()
        assert b.get(f"o_{name}_valid") == 0
    assert b.get("o_req_live") == 1


@cocotb.test()
async def request_identity_and_reuse(dut: Any) -> None:
    """Delay each phase and reject identity reuse and premature completion."""
    b = Bench(dut)
    await b.reset()
    for iteration in range(24):
        op = (0, 1, 2, 3, 4)[iteration % 5]
        await b.set(i_req_request=b.d(q=1, op=op), i_req_request_valid=1)
        assert b.get("o_req_request_ready") == 0
        request = b.d(op=op)
        await b.set(i_req_request=request)
        assert b.get("o_req_request_ready") == 1
        await b.tick()
        await b.set(i_req_request=b.d(op=9))
        await b.held("o_req_d_valid", "o_req_d", request, b.rng.randrange(1, 8))
        assert b.get("o_req_request_ready") == 0
        await b.set(i_req_d_ready=1)
        await b.tick()
        await b.set(i_req_d_ready=0, i_req_g_valid=1, i_req_g=b.g(q=1))
        await b.tick(3)
        assert b.get("o_req_g_ready") == 0
        assert b.get("o_req_grant_valid") == 0
        failed_sc = op == 4 and iteration % 2 == 0
        grant = b.g(tid=17, op=5 if failed_sc else (2 if op in (1, 3, 4) else 0))
        await b.set(i_req_g=grant)
        assert b.get("o_req_g_ready") == 1
        await b.tick()
        await b.set(i_req_g=0, i_req_u_valid=1, i_req_u=b.u(tid=17))
        assert b.get("o_req_g_ready") == 0
        assert b.get("o_req_u_ready") == 0
        await b.held("o_req_grant_valid", "o_req_grant", grant, b.rng.randrange(1, 8))
        await b.set(i_req_grant_ready=1)
        await b.tick()
        await b.set(
            i_req_grant_ready=0,
            i_req_done_valid=1,
            i_req_done_status=1,
            i_req_write_done=0,
        )
        if op in (1, 3, 4):
            assert b.get("o_req_done_ready") == 0
            await b.set(i_req_done_status=0)
            assert b.get("o_req_done_ready") == int(failed_sc)
        status = int(op == 0 and iteration % 2 == 0)
        written = int(not failed_sc)
        await b.set(i_req_done_status=status, i_req_write_done=written)
        assert b.get("o_req_done_ready") == 1
        await b.tick()
        completion = b.c(tid=17, status=status, written=written)
        await b.held("o_req_c_valid", "o_req_c", completion, b.rng.randrange(1, 8))
        await b.set(i_req_c_ready=1)
        await b.tick()
        await b.set(i_req_u=b.u(tid=16), i_req_c_ready=0)
        assert b.get("o_req_u_ready") == 0
        assert b.get("o_req_request_ready") == 0
        await b.tick(4)
        await b.set(i_req_u=b.u(tid=17))
        assert b.get("o_req_u_ready") == 1
        await b.tick()
        assert b.get("o_req_live") == 0
        await b.set(
            i_req_request_valid=0, i_req_done_valid=0, i_req_u_valid=0, i_req_g_valid=0
        )


@cocotb.test()
async def home_grant_and_absorbed_cancellation(dut: Any) -> None:
    """Release a completion only after its exact frozen slot is cancelled."""
    b = Bench(dut)
    await b.reset()
    await b.set(i_home_d_valid=1, i_home_d=b.d(), i_home_c_valid=1, i_home_c=b.c())
    await b.tick()
    assert b.get("o_home_c_ready") == 0
    assert b.get("o_home_d_ready") == 0
    for slot in (0, 1):
        await b.set(
            **{f"i_put{slot}_freeze_valid": 1, f"i_put{slot}_freeze": b.w(slot)}
        )
    await b.tick()
    await b.set(
        i_put0_freeze_valid=0,
        i_put1_freeze_valid=0,
        i_put0_absorb_valid=1,
        i_put0_absorb_tid=0,
        i_put0_absorb_addr=b.addr,
        i_put0_absorb_epoch=0,
        i_home_absorb_valid=1,
        i_home_absorb=b.r(),
    )
    assert b.get("o_put0_absorb_ready") == 1
    assert b.get("o_home_absorb_ready") == 1
    await b.tick()
    await b.set(i_put0_absorb_valid=0, i_home_absorb_valid=0)
    assert b.get("o_home_pending") == 1
    frozen = b.get("o_put0_w")
    grant = b.g()
    await b.set(i_home_result_valid=1, i_home_result=grant)
    await b.tick()
    await b.held("o_home_g_valid", "o_home_g", grant, 19)
    assert b.get("o_home_c_ready") == 0
    await b.set(i_home_g_ready=1)
    await b.tick()
    assert b.get("o_home_c_ready") == 1
    await b.tick()
    await b.set(i_home_c_valid=0)
    await b.tick(5)
    assert b.get("o_home_u_valid") == 0
    for bad in (
        b.wa(absorbed=1, slot=1),
        b.wa(absorbed=1, epoch=1),
        b.wa(absorbed=1, tid=1),
        b.wa(absorbed=1, addr=b.addr + 32),
        b.wa(absorbed=0),
    ):
        await b.set(
            i_put0_wa_valid=1, i_put0_wa=bad, i_home_cancel_valid=1, i_home_cancel=bad
        )
        assert b.get("o_put0_wa_ready") == 0
        await b.tick()
        assert b.get("o_home_pending") == 1
        assert b.get("o_home_u_valid") == 0
        assert b.get("o_put0_w") == frozen
    ack = b.wa(absorbed=1)
    await b.set(i_put0_wa=ack, i_home_cancel=ack)
    assert b.get("o_put0_cancel_valid") == 1
    await b.tick()
    assert b.get("o_put0_live") == 0
    assert b.get("o_put1_w_valid") == 1
    assert b.get("o_home_pending") == 0
    await b.set(i_put0_wa_valid=0, i_home_cancel_valid=0)
    await b.tick()
    await b.held("o_home_u_valid", "o_home_u", b.u(), 11)
    assert b.get("o_home_d_ready") == 0
    await b.set(i_home_u_ready=1)
    await b.tick()
    assert b.get("o_home_live") == 0
    assert b.get("o_put1_w_valid") == 1


@cocotb.test()
async def home_release_after_completed_cleanup(dut: Any) -> None:
    """C presents U on the following cycle when no cancellation is pending."""
    b = Bench(dut)
    await b.reset()
    await b.set(i_home_d_valid=1, i_home_d=b.d())
    await b.tick()
    await b.set(i_home_d_valid=0, i_home_result_valid=1, i_home_result=b.g())
    assert b.get("o_home_g_valid")
    await b.tick(4)
    assert not b.get("o_home_u_valid")
    await b.set(i_home_g_ready=1)
    await b.tick()
    await b.set(i_home_result_valid=0, i_home_c_valid=1, i_home_c=b.c())
    assert b.get("o_home_c_ready")
    await b.tick()
    await b.set(i_home_c_valid=0)
    assert b.get("o_home_u_valid")
    await b.held("o_home_u_valid", "o_home_u", b.u(), 5)
    await b.set(i_home_u_ready=1)
    await b.tick()
    assert not b.get("o_home_live")


@cocotb.test()
async def put_selection_error_and_reset(dut: Any) -> None:
    """Arbitrate selection against absorption and preserve failed dirty data."""
    b = Bench(dut)
    await b.reset()
    frozen = b.w()
    await b.set(i_put0_freeze_valid=1, i_put0_freeze=frozen)
    await b.tick()
    await b.set(
        i_put0_freeze_valid=0,
        i_put0_absorb_valid=1,
        i_put0_absorb_addr=b.addr,
        i_put0_w_ready=1,
    )
    assert b.get("o_put0_absorb_ready") == 0
    await b.tick()
    await b.set(
        i_put0_w_ready=0,
        i_put0_absorb_valid=0,
        i_put0_wa_valid=1,
        i_put0_wa=b.wa(absorbed=1),
    )
    assert b.get("o_put0_wa_ready") == 0
    await b.tick(3)
    await b.set(i_put0_wa=b.wa(error=1))
    assert b.get("o_put0_wa_ready") == 1
    await b.tick()
    assert b.get("o_put0_fatal") == 1
    assert b.get("o_put0_live") == 1
    assert b.get("o_put0_w") == frozen
    await b.set(i_put0_wa=b.wa(), i_put0_freeze_valid=1)
    await b.tick(5)
    assert b.get("o_put0_fatal") == 1
    assert b.get("o_put0_freeze_ready") == 0
    await b.reset(epoch=1)
    await b.set(i_put0_freeze_valid=1, i_put0_freeze=b.w(epoch=0))
    assert b.get("o_put0_freeze_ready") == 0
    await b.set(i_put0_freeze=b.w(epoch=1))
    await b.tick()
    await b.set(i_put0_freeze_valid=0, i_put0_w_ready=1)
    await b.tick()
    await b.set(i_put0_w_ready=0, i_put0_wa_valid=1, i_put0_wa=b.wa(epoch=0))
    assert b.get("o_put0_wa_ready") == 0
    await b.set(i_put0_wa=b.wa(epoch=1))
    await b.tick()
    assert b.get("o_put0_live") == 0


@cocotb.test()
async def dma_identity_and_reset_with_live_grants(dut: Any) -> None:
    """Preserve opaque DMA IDs and discard all endpoint state on reset."""
    b = Bench(dut)
    for phase in range(6):
        await b.reset()
        q = pack((2, 2), (2, 3), (4, 15), (1, 0))
        demand = b.d(q=q, op=7)
        await b.set(
            i_home_d_valid=1,
            i_home_d=demand,
            i_req_request_valid=1,
            i_req_request=b.d(),
        )
        await b.tick()
        await b.set(i_home_d_valid=0, i_req_request_valid=0)
        if phase >= 1:
            await b.set(i_req_d_ready=1, i_home_result_valid=1, i_home_result=b.g(q=q))
            await b.tick()
        if phase >= 2:
            await b.set(i_req_g_valid=1, i_req_g=b.g(), i_home_g_ready=1)
            await b.tick()
        if phase >= 3:
            await b.set(i_req_grant_ready=1, i_home_c_valid=1, i_home_c=b.c(q=q))
            await b.tick()
        if phase >= 4:
            await b.set(i_req_done_valid=1, i_req_done_status=0)
            await b.tick()
        if phase >= 5:
            await b.set(i_req_c_ready=1)
            await b.tick()
        await b.reset(epoch=1)
        assert b.get("o_home_live") == 0
        assert b.get("o_req_live") == 0
        await b.set(
            i_home_d_valid=1,
            i_home_d=demand,
            i_req_request_valid=1,
            i_req_request=b.d(),
            i_req_g_valid=1,
            i_req_g=b.g(),
            i_req_u_valid=1,
            i_req_u=b.u(),
        )
        await b.tick(3)
        assert b.get("o_home_d_ready") == 0
        assert b.get("o_req_request_ready") == 0
        assert b.get("o_req_grant_valid") == 0


@cocotb.test()
async def error_disposition_and_coincident_cancel(dut: Any) -> None:
    """Keep error ownership until disposal and accept cancellation with a reply."""
    b = Bench(dut)
    await b.reset()
    await b.set(
        i_req_request_valid=1, i_req_request=b.d(), i_home_d_valid=1, i_home_d=b.d()
    )
    await b.tick()
    await b.set(
        i_req_request_valid=0,
        i_home_d_valid=0,
        i_req_d_ready=1,
        i_home_result_valid=1,
        i_home_result=b.g(error=1),
        i_home_g_ready=1,
        i_home_absorb_valid=1,
        i_home_absorb=b.r(),
        i_home_cancel_valid=1,
        i_home_cancel=b.wa(absorbed=1),
    )
    await b.tick()
    assert b.get("o_home_pending") == 0
    await b.set(
        i_req_g_valid=1,
        i_req_g=b.g(error=1),
        i_home_absorb_valid=0,
        i_home_cancel_valid=0,
        i_home_c_valid=1,
        i_home_c=b.c(status=2),
    )
    await b.tick()
    await b.set(i_req_grant_ready=1)
    await b.tick()
    await b.set(i_req_done_valid=1, i_req_done_status=0)
    assert b.get("o_req_done_ready") == 0
    await b.set(i_req_done_status=1, i_home_c=b.c(status=1))
    assert b.get("o_req_done_ready") == 0
    assert b.get("o_home_c_ready") == 0
    await b.tick(3)
    assert b.get("o_home_u_valid") == 0
    await b.set(i_req_done_status=2, i_home_c=b.c(status=2))
    assert b.get("o_req_done_ready") == 0
    assert b.get("o_home_c_ready") == 0
    await b.tick(12)
    assert b.get("o_req_live") == 1
    assert b.get("o_home_u_valid") == 0
    await b.set(i_req_error_disposed=1, i_home_error_disposed=1)
    assert b.get("o_req_done_ready") == 1
    assert b.get("o_home_c_ready") == 1
    await b.tick()
    await b.tick()
    assert b.get("o_req_c") == b.c(status=2)
    assert b.get("o_home_u_valid") == 1


@cocotb.test()
async def cancellation_before_absorption_notification(dut: Any) -> None:
    """Remember a consumed PutAck across a delayed absorption notification."""
    b = Bench(dut)
    await b.reset()
    await b.set(i_home_d_valid=1, i_home_d=b.d())
    await b.tick()
    await b.set(i_home_d_valid=0, i_home_cancel_valid=1, i_home_cancel=b.wa(absorbed=1))
    await b.tick()
    await b.set(i_home_cancel_valid=0)
    await b.tick(4)
    await b.set(i_home_absorb_valid=1, i_home_absorb=b.r())
    assert b.get("o_home_absorb_ready") == 1
    await b.tick()
    assert b.get("o_home_pending") == 0
    await b.set(
        i_home_absorb_valid=0,
        i_home_result_valid=1,
        i_home_result=b.g(),
        i_home_g_ready=1,
    )
    await b.tick()
    await b.set(i_home_result_valid=0, i_home_c_valid=1, i_home_c=b.c())
    await b.tick(2)
    assert b.get("o_home_u_valid") == 1
    await b.set(i_home_u_ready=1)
    await b.tick()
    assert b.get("o_home_live") == 0


@cocotb.test()
async def complete_request_identity_space(dut: Any) -> None:
    """Check all source, class, slot and epoch encodings at home admission."""
    b = Bench(dut)
    await b.reset()
    harts = 1 if (b.get("o_layout") >> 21) == 19 else 2
    allowed: set[int] = set()
    for hart in range(harts):
        for port_class, count in ((0, 8), (1, 2), (2, 1)):
            allowed.update(
                pack((2, hart), (2, port_class), (4, slot), (1, 0))
                for slot in range(count)
            )
    allowed.update(pack((2, 2), (2, 3), (4, slot), (1, 0)) for slot in range(16))
    allowed.update(pack((2, 3), (2, 3), (4, slot), (1, 0)) for slot in range(4))
    for q in range(512):
        source, port_class = q >> 7, (q >> 5) & 3
        op = (0, 5, 6, 9 if source == 3 else 7)[port_class]
        await b.set(i_home_d=b.d(q=q, op=op))
        assert b.get("o_home_d_ready") == int(q in allowed), q
        await b.set(i_home_d=b.d(q=q, op=15))
        assert b.get("o_home_d_ready") == 0
    await b.set(i_home_d=b.d())
    assert b.get("o_home_d_ready") == 1

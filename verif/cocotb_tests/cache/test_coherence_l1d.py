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


@cocotb.test()
async def probe_reply_waits_for_cut_and_preserves_dirty_bytes(dut: Any) -> None:
    """Finish state updates and the observation cut before exposing a held reply."""
    b = Private(dut)
    await b.reset()
    address = 0x80000000
    pattern = int.from_bytes(bytes(range(32)), "little")
    stored = 0xFEDCBA9876543210
    await b.set(i_address=address, i_write_mask=255, i_write_data=stored)
    await b.tick()
    await b.set(i_write_mask=0)
    await b.wait("o_d_valid")
    demand = unpack(b.get("o_d"), (4, 9, b.p, 5, 3, 32, 1, 1, 1, 256))
    await b.set(i_d_ready=1)
    await b.tick()
    await b.set(
        i_d_ready=0,
        i_g_valid=1,
        i_g=pack(
            (3, 2), (9, demand[1]), (6, 0), (b.p, address), (256, pattern), (1, 0)
        ),
    )
    await b.wait("o_g_ready")
    await b.tick()
    await b.set(i_g_valid=0)
    await b.wait("o_c_valid")
    await b.set(i_c_ready=1)
    await b.tick()
    await b.set(
        i_c_ready=0, i_u_valid=1, i_u=pack((9, demand[1]), (6, 0), (b.p, address))
    )
    await b.wait("o_u_ready")
    await b.tick()
    await b.set(i_u_valid=0)
    expected = (pattern & ~((1 << 64) - 1)) | stored
    for tid, opcode in enumerate((0, 0, 1, 0), start=1):
        probe = pack(
            (2, opcode),
            (6, tid),
            (1, 0),
            (b.p, address),
            (2, 2),
            (2, int(opcode == 1)),
            (9, 0),
            (5, 0),
            (3, 0),
        )
        await b.set(i_p_valid=1, i_p=probe)
        await b.wait("o_p_ready")
        if opcode == 1:
            assert b.get("o_cut_hold") and b.get("o_cut_address") == address
            assert b.get("o_cut_admit_valid")
        await b.tick()
        await b.set(i_p_valid=0)
        if opcode == 1:
            for _ in range(8):
                assert b.get("o_cut_hold") and not b.get("o_r_valid")
                await b.tick()
            await b.set(i_cut_admit_ready=1)
            await b.wait("o_cut_inval_valid")
            for _ in range(8):
                assert b.get("o_cut_hold") and not b.get("o_r_valid")
                await b.tick()
            await b.set(i_cut_inval_done=1)
        await b.wait("o_r_valid")
        held = b.get("o_r")
        reply = unpack(held, (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
        assert reply[1] == tid and reply[4] == address and not reply[-1]
        assert reply[7] == int(tid == 1)
        if tid == 1:
            assert reply[8] == expected and reply[5] == 2
        if opcode == 1 or tid == 4:
            assert reply[5] == 0
        for _ in range(8):
            assert b.get("o_r_valid") and b.get("o_r") == held
            assert not b.get("o_p_ready")
            await b.tick()
        await b.set(i_r_ready=1)
        await b.tick()
        assert b.get("o_cut_release") == int(opcode == 1)
        await b.set(i_r_ready=0, i_cut_admit_ready=0, i_cut_inval_done=0)
    assert not b.get("o_fatal")


@cocotb.test()
async def continuous_probes_yield_to_ready_local_work(dut: Any) -> None:
    """Install grants and finish committed writes while unrelated probes stay offered."""
    for kind in ("store", "amo", "sc"):
        b = Private(dut)
        await b.reset()
        address = 0x80000000
        await b.set(i_atomic_protected=1, i_address=address)
        if kind == "sc":
            await b.set(
                i_sc_valid=1,
                i_sc_address=address,
                i_sc_size=3,
                i_sc_tag=3,
                i_reservation_valid=1,
                i_reservation_addr=address,
                i_reservation_size=3,
            )
            await b.wait("o_sc_ready")
            await b.tick()
            await b.set(i_sc_valid=0)
        else:
            await b.set(
                i_read_valid=int(kind == "amo"),
                i_read_kind=2,
                i_read_size=3,
                i_read_tag=3,
                i_write_mask=255 if kind == "store" else 0,
                i_write_data=0x12345678,
            )
            await b.tick()
            await b.set(i_read_valid=0, i_write_mask=0)
        await b.wait("o_d_valid")
        demand = unpack(b.get("o_d"), (4, 9, b.p, 5, 3, 32, 1, 1, 1, 256))
        await b.set(i_d_ready=1)
        await b.tick()
        await b.set(i_d_ready=0, i_r_ready=1)
        if kind == "sc":
            for opcode in (2, 0):
                await b.set(
                    i_p_valid=1,
                    i_p=pack(
                        (2, opcode),
                        (6, 0),
                        (1, 0),
                        (b.p, address),
                        (2, 0),
                        (2, 3 if opcode == 2 else 0),
                        (9, demand[1]),
                        (5, 0),
                        (3, 3),
                    ),
                )
                await b.wait("o_p_ready")
                await b.tick()
                await b.set(i_p_valid=0)
                await b.wait("o_r_valid")
                fields = unpack(
                    b.get("o_r"), (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1)
                )
                assert not fields[-1]
                if opcode == 2:
                    assert fields[0] == 2 and fields[12]
                await b.tick()
        accepted = 0
        replied = 0

        async def offer() -> None:
            await b.set(
                i_p_valid=1,
                i_p=pack(
                    (2, 0),
                    (6, accepted % 64),
                    (1, 0),
                    (b.p, address + 128),
                    (2, 2),
                    (2, 0),
                    (9, 0),
                    (5, 0),
                    (3, 0),
                ),
            )

        async def step() -> None:
            nonlocal accepted, replied
            take = b.get("o_p_ready") and b.get("i_p_valid")
            replied += b.get("o_r_valid")
            await b.tick()
            if take:
                accepted += 1
                await offer()
            assert not b.get("o_fatal")

        await offer()
        for _ in range(20):
            if accepted:
                break
            await step()
        assert accepted
        await b.set(
            i_g_valid=1,
            i_g=pack(
                (3, 2),
                (9, demand[1]),
                (6, 0),
                (b.p, address),
                (256, 0xAABBCCDD),
                (1, 0),
            ),
        )
        await b.wait("o_g_ready")
        await step()
        await b.set(i_g_valid=0)
        for _ in range(100):
            installed = (
                not b.get("o_pending_store")
                if kind == "store"
                else (
                    b.get("o_sc_result_valid")
                    if kind == "sc"
                    else b.get("o_read_valid")
                )
            )
            if installed:
                break
            await step()
        else:
            raise AssertionError(f"{kind} grant starved behind probes")
        before = replied
        for _ in range(40):
            await step()
        assert replied >= before + 3
        if kind == "sc":
            assert b.get("o_sc_success") and not b.get("o_sc_error")
            await b.set(i_sc_commit=1)
            await step()
            await b.set(i_sc_commit=0)
        if kind == "store":
            await b.set(i_c_ready=1)
            for _ in range(20):
                if b.get("o_c_valid"):
                    await step()
                    break
                await step()
            else:
                raise AssertionError("store completion did not progress")
            await b.set(
                i_c_ready=0,
                i_u_valid=1,
                i_u=pack((9, demand[1]), (6, 0), (b.p, address)),
            )
            assert b.get("o_u_ready")
            await step()
            await b.set(i_u_valid=0)
            assert b.get("o_store_ready")
        await b.set(
            i_write_mask=255,
            i_write_data=0xFEDCBA9876543210,
            i_write_atomic=int(kind != "store"),
            i_write_sc=int(kind == "sc"),
            i_write_tag=3,
        )
        await step()
        await b.set(i_write_mask=0)
        for _ in range(100):
            if b.get("o_write_done"):
                break
            await step()
        else:
            raise AssertionError(f"{kind} write starved behind probes")
        assert b.get("o_sc_write_done") == int(kind == "sc")
        before = replied
        for _ in range(40):
            await step()
        assert replied >= before + 3
        assert accepted - replied <= 1


@cocotb.test()
async def check_sc_samples_after_capture(dut: Any) -> None:
    """Sample the reservation on the edge after P and preserve the complete held R."""
    b = Private(dut)
    address = 0x80000000
    for before, sampled in ((0, 1), (1, 0)):
        await b.reset()
        await b.set(
            i_atomic_protected=1,
            i_sc_valid=1,
            i_sc_address=address,
            i_sc_size=3,
            i_sc_tag=3,
            i_reservation_valid=before,
            i_reservation_addr=address,
            i_reservation_size=3,
        )
        await b.wait("o_sc_ready")
        await b.tick()
        await b.set(i_sc_valid=0)
        await b.wait("o_d_valid")
        demand = unpack(b.get("o_d"), (4, 9, b.p, 5, 3, 32, 1, 1, 1, 256))
        await b.set(i_d_ready=1)
        await b.tick()
        await b.set(
            i_d_ready=0,
            i_p_valid=1,
            i_p=pack(
                (2, 2),
                (6, 9),
                (1, 0),
                (b.p, address),
                (2, 0),
                (2, 3),
                (9, demand[1]),
                (5, 0),
                (3, 3),
            ),
        )
        await b.wait("o_p_ready")
        await b.tick()
        assert not b.get("o_r_valid")
        await b.set(i_p_valid=0, i_reservation_valid=sampled)
        await b.tick()
        await b.set(i_reservation_valid=before)
        await b.wait("o_r_valid")
        held = b.get("o_r")
        fields = unpack(held, (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
        assert fields[0] == 2 and fields[12] == sampled and not fields[-1]
        for _ in range(12):
            assert b.get("o_r_valid") and b.get("o_r") == held
            await b.tick()


@cocotb.test()
async def continuous_probes_allow_read_acquisition(dut: Any) -> None:
    """Reserve a read turn within four completed probes and apply its grant."""
    b = Private(dut)
    await b.reset()
    address = 0x80000000
    await b.set(
        i_p_valid=1,
        i_r_ready=1,
        i_p=pack(
            (2, 0),
            (6, 8),
            (1, 0),
            (b.p, address + 128),
            (2, 2),
            (2, 0),
            (9, 0),
            (5, 0),
            (3, 0),
        ),
        i_read_valid=1,
        i_address=address,
    )
    await b.tick()
    await b.set(i_read_valid=0)
    replies = 0
    for _ in range(100):
        if b.get("o_d_valid"):
            break
        replies += b.get("o_r_valid")
        await b.tick()
    else:
        raise AssertionError("read acquisition starved behind probes")
    assert 1 <= replies <= 5
    demand = unpack(b.get("o_d"), (4, 9, b.p, 5, 3, 32, 1, 1, 1, 256))
    await b.set(i_d_ready=1)
    await b.tick()
    await b.set(
        i_d_ready=0,
        i_g_valid=1,
        i_g=pack(
            (3, 1), (9, demand[1]), (6, 0), (b.p, address), (256, 0x12345678), (1, 0)
        ),
    )
    await b.wait("o_g_ready")
    await b.tick()
    await b.set(i_g_valid=0)
    await b.wait("o_read_valid")
    assert b.get("o_read_data") == 0x12345678 and not b.get("o_read_error")
    for _ in range(12):
        assert b.get("o_read_valid") and b.get("o_read_data") == 0x12345678
        await b.tick()

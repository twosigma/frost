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
        self.acknowledged = 0
        self.installed = 0
        self.cycles = 0

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
            self.acknowledged += self.get("o_write_done")
            self.installed += self.get("store_pop")
            self.cycles += 1
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
        self.acknowledged = 0
        self.installed = 0


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
            await b.wait("o_pending_store", 0)
            await b.tick()
            assert b.acknowledged == 2 and b.installed == 2
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
        if kind == "store":
            for _ in range(100):
                if not b.get("o_pending_store"):
                    break
                await step()
            else:
                raise AssertionError(
                    "accepted store installation starved behind probes"
                )
            assert b.installed == 2
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


async def store(b: Private, address: int, data: int, mask: int = 255) -> None:
    """Use a launch credit on the edge before presenting the write."""
    await b.wait("o_store_ready")
    await b.tick()
    await b.set(i_address=address, i_write_mask=mask, i_write_data=data)
    await b.tick()
    await b.set(i_write_mask=0)
    assert b.get("o_write_done")


async def getm(b: Private, address: int, data: int, error: bool = False) -> None:
    """Supply the oldest store's grant and retain its identity through release."""
    await b.wait("o_d_valid")
    demand = unpack(b.get("o_d"), (4, 9, b.p, 5, 3, 32, 1, 1, 1, 256))
    assert demand[0] == 1 and demand[2] == address
    await b.set(i_d_ready=1)
    await b.tick()
    await b.set(
        i_d_ready=0,
        i_g_valid=1,
        i_g=pack(
            (3, 2), (9, demand[1]), (6, 0), (b.p, address), (256, data), (1, error)
        ),
    )
    await b.wait("o_g_ready")
    await b.tick()
    await b.set(i_g_valid=0)
    if error:
        await b.wait("o_fatal")
        return
    await b.wait("o_c_valid")
    await b.set(i_c_ready=1)
    await b.tick()
    await b.set(
        i_c_ready=0, i_u_valid=1, i_u=pack((9, demand[1]), (6, 0), (b.p, address))
    )
    await b.wait("o_u_ready")
    await b.tick()
    await b.set(i_u_valid=0)


async def snapshot(b: Private, address: int, *, invalidate: bool = False) -> int:
    """Read a dirty sector through the probe channel, including every byte."""
    await b.set(
        i_p_valid=1,
        i_p=pack(
            (2, int(invalidate)),
            (6, 1),
            (1, 0),
            (b.p, address),
            (2, 2),
            (2, 0),
            (9, 0),
            (5, 0),
            (3, 0),
        ),
        i_cut_admit_ready=1,
        i_cut_admit_clean=1,
    )
    await b.wait("o_p_ready")
    await b.tick()
    await b.set(i_p_valid=0)
    await b.wait("o_r_valid")
    reply = unpack(b.get("o_r"), (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
    assert reply[0] == 1 and reply[7] == 1
    held = b.get("o_r")
    for _ in range(8):
        await b.tick()
        assert b.get("o_r_valid") and b.get("o_r") == held
    await b.set(i_r_ready=1)
    await b.tick()
    await b.set(i_r_ready=0)
    return reply[8]


@cocotb.test()
async def buffered_masked_hits_preserve_order_and_cadence(dut: Any) -> None:
    """Install overlapping and disjoint bytes with two accepted sectors held."""
    b = Private(dut)
    await b.reset()
    base = 0x80000000
    pattern = int.from_bytes(bytes(range(32)), "little")
    expected = {base: pattern, base + 32: pattern}
    for address in expected:
        await store(b, address, pattern & ((1 << 64) - 1))
        await getm(b, address, pattern)
    # Both lines have Modified permission. Each write has a distinct payload.
    writes = [
        (
            base + (index % 2) * 32 + ((index // 2) % 4) * 8,
            0x1020304050607080 + index,
            (255, 1, 3, 15, 128)[index % 5],
        )
        for index in range(32)
    ]
    accepted = 0
    install_cycles = []
    two_sectors = False
    for _ in range(400):
        if b.get("store_pop"):
            install_cycles.append(b.cycles)
        if b.get("o_block_valid").bit_count() == 2:
            holds = b.get("o_block_addr")
            sectors = {
                ((holds >> (slot * b.p)) & ((1 << b.p) - 1)) >> 5
                for slot in range(4)
                if b.get("o_block_valid") & (1 << slot)
            }
            two_sectors |= len(sectors) == 2
        launch = accepted < len(writes) and b.get("o_store_ready")
        await b.tick()
        if launch:
            address, data, mask = writes[accepted]
            accepted += 1
            await b.set(i_address=address, i_write_data=data, i_write_mask=mask)
            sector = address & ~31
            for byte in range(8):
                if mask & (1 << byte):
                    shift = ((address & 24) + byte) * 8
                    expected[sector] = (expected[sector] & ~(255 << shift)) | (
                        ((data >> (byte * 8)) & 255) << shift
                    )
        else:
            await b.set(i_write_mask=0)
        if accepted == len(writes) and not b.get("o_pending_store"):
            break
    else:
        raise AssertionError("buffered hit burst did not drain")
    assert len(install_cycles) == len(writes)
    assert {b - a for a, b in zip(install_cycles, install_cycles[1:])} == {6}
    assert two_sectors and b.acknowledged == 34 and b.installed == 34
    # Probe launch directly follows StoreOp and must read the full dirty image.
    for address, data in expected.items():
        assert await snapshot(b, address) == data
    assert not b.get("o_fatal")


@cocotb.test()
async def buffered_hit_burst_yields_to_waiting_reads(dut: Any) -> None:
    """Serve an unrelated read between buffered hits and preserve both writes."""
    b = Private(dut)
    await b.reset()
    base = 0x80000000
    pattern = int.from_bytes(bytes(range(32)), "little")
    for address in (base, base + 32):
        await store(b, address, pattern & ((1 << 64) - 1))
        await getm(b, address, pattern)
    await store(b, base, 0x1122334455667788)
    await store(b, base + 8, 0x99AABBCCDDEEFF00)
    assert b.get("o_block_valid").bit_count() == 2
    await b.set(i_read_valid=1, i_read_id=0, i_address=base + 32)
    await b.tick()
    await b.set(i_read_valid=0)
    events = []
    for _ in range(80):
        if b.get("store_pop"):
            events.append("store")
        # The hit path answers the read beside the installations; the
        # controller answers it only if the hit path refused it.
        if b.get("read_hit") or b.get("s4_valid_q"):
            events.append("read")
            assert b.get("o_pending_store")
        assert not b.get("o_d_valid") and not b.get("o_fatal")
        await b.tick()
        if b.get("o_read_valid") and not b.get("o_pending_store"):
            break
    else:
        raise AssertionError("mixed read and buffered hits did not drain")
    assert sorted(events) == ["read", "store", "store"] and events[-1] == "store"
    assert b.get("o_read_data") == pattern & ((1 << 64) - 1)
    assert not b.get("o_read_error")
    assert b.acknowledged == 4 and b.installed == 4
    expected = (pattern & ~((1 << 128) - 1)) | (0x99AABBCCDDEEFF00 << 64)
    expected |= 0x1122334455667788
    assert await snapshot(b, base) == expected


@cocotb.test()
async def buffered_tail_reacquires_after_probe_and_delayed_getm(dut: Any) -> None:
    """Require a queued hit to recheck permission after an intervening probe."""
    for invalidate in (False, True):
        b = Private(dut)
        await b.reset()
        base = 0x80000000
        pattern = int.from_bytes(bytes(range(32)), "little")
        await store(b, base, pattern & ((1 << 64) - 1))
        await getm(b, base, pattern)
        await store(b, base + 32, 0x1234)
        await b.wait("o_d_valid")
        await store(b, base + 8, 0xAABBCCDD, 15)
        assert b.get("o_block_valid").bit_count() == 2
        before = b.installed
        assert await snapshot(b, base, invalidate=invalidate) == pattern
        assert b.installed == before and b.get("o_block_valid").bit_count() == 2
        await getm(b, base + 32, pattern)
        assert b.get("o_pending_store")
        await getm(b, base, pattern)
        await b.wait("o_pending_store", 0)
        expected = (pattern & ~(0xFFFFFFFF << 64)) | (0xAABBCCDD << 64)
        assert await snapshot(b, base) == expected
        assert b.acknowledged == 3 and b.installed == 3
        assert not b.get("o_fatal")


@cocotb.test()
async def store_error_stops_younger_installation_and_reset_clears_credit(
    dut: Any,
) -> None:
    """Keep the younger hit uninstalled after the oldest acquisition fails."""
    b = Private(dut)
    await b.reset()
    base = 0x80000000
    await store(b, base, 0x1122)
    await getm(b, base, 0)
    await store(b, base + 32, 0x3344)
    await b.wait("o_d_valid")
    await store(b, base, 0x5566)
    assert b.get("o_block_valid").bit_count() == 2
    before = b.installed
    await getm(b, base + 32, 0, error=True)
    assert b.get("o_fatal_addr") == base + 32
    await b.tick(30)
    assert b.installed == before and b.get("o_block_valid").bit_count() == 2
    assert not b.get("o_store_ready")
    await b.reset()
    assert not b.get("o_pending_store") and not b.get("o_write_done")
    assert not b.get("o_block_valid") and not b.get("o_fatal")
    await store(b, base, 0x7788)
    await getm(b, base, 0)
    assert await snapshot(b, base) == 0x7788


@cocotb.test()
async def fatal_stop_holds_the_controller_from_the_next_cycle(dut: Any) -> None:
    """Service stops one cycle after a stop rises and returns after reset."""
    b = Private(dut)
    await b.reset()
    await b.set(i_fatal_stop=1)
    assert b.get("o_p_ready") and b.get("o_store_ready")
    await b.tick()
    assert not b.get("o_p_ready") and not b.get("o_store_ready")
    await b.tick(4)
    assert not b.get("o_p_ready") and not b.get("o_store_ready")
    await b.set(i_fatal_stop=0, i_rst=1)
    await b.tick()
    await b.set(i_rst=0)
    assert b.get("o_p_ready") and b.get("o_store_ready")


@cocotb.test()
async def frozen_writeback_blocks_buffered_tail_until_ack(dut: Any) -> None:
    """Preserve frozen bytes across tail promotion, accepted W and absorbed W."""
    for absorbed in (False, True):
        b = Private(dut)
        await b.reset()
        base = 0x80000000
        # Five sectors compete for the four ways of one set.
        images = {}
        for index in range(5):
            address = base + index * 128
            data = 0x1020304050607000 + index
            images[address] = data
            await store(b, address, data)
            await getm(b, address, 0)
        await b.wait("o_w_valid")
        frozen = b.get("o_w")
        put = unpack(frozen, (1, 1, 1, b.p, 256, 1))
        victim = put[3]
        assert put[4] == images[victim]
        resident = base + 4 * 128
        assert victim != resident
        await store(b, resident + 8, 0x88776655, 15)
        await store(b, victim + 8, 0xAABBCCDD, 15)
        assert b.get("o_block_valid").bit_count() == 2
        before = b.installed
        if absorbed:
            assert await snapshot(b, victim) == images[victim]
            reply = unpack(b.get("o_r"), (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
            assert reply[9] and reply[10] == put[1]
        else:
            await b.set(i_w_ready=1)
            await b.tick()
            await b.set(i_w_ready=0)
        await b.tick(30)
        assert b.installed == before + 1
        assert b.get("o_pending_store") and b.get("o_block_valid").bit_count() == 1
        assert not b.get("o_d_valid") and b.get("o_w") == frozen
        await b.set(
            i_wa_valid=1,
            i_wa=pack(
                (1, put[0]),
                (1, put[1]),
                (1, put[2]),
                (b.p, victim),
                (1, absorbed),
                (6, 1 if absorbed else 0),
                (1, 0),
            ),
        )
        await b.wait("o_wa_ready")
        await b.tick()
        await b.set(i_wa_valid=0)
        await getm(b, victim, images[victim])
        assert await snapshot(b, victim) == images[victim] | (0xAABBCCDD << 64)
        assert not b.get("o_fatal")


@cocotb.test()
async def reserved_store_credit_survives_maintenance_offer(dut: Any) -> None:
    """Capture an already launched store when maintenance closes admission."""
    b = Private(dut)
    await b.reset()
    base = 0x80000000
    await store(b, base, 0x1122)
    await getm(b, base, 0)
    await b.wait("o_store_ready")
    await b.tick()
    await b.set(
        i_maint_valid=1,
        i_maint_line=1,
        i_maint_address=base,
        i_address=base + 8,
        i_write_mask=255,
        i_write_data=0x3344,
    )
    assert not b.get("o_store_ready")
    await b.tick()
    await b.set(i_write_mask=0)
    assert b.get("o_write_done") and b.get("o_pending_store")
    await b.wait("o_w_valid")
    put = unpack(b.get("o_w"), (1, 1, 1, b.p, 256, 1))
    assert put[3] == base and put[4] == 0x1122 | (0x3344 << 64)
    assert put[5] and not b.get("o_maint_done")
    await b.set(i_w_ready=1)
    await b.tick()
    await b.set(i_w_ready=0)
    await b.tick(12)
    assert not b.get("o_maint_done")
    await b.set(
        i_wa_valid=1,
        i_wa=pack(
            (1, put[0]), (1, put[1]), (1, put[2]), (b.p, base), (1, 0), (6, 0), (1, 0)
        ),
    )
    await b.wait("o_wa_ready")
    await b.tick()
    await b.set(i_wa_valid=0)
    await b.wait("o_maint_done")
    assert b.acknowledged == 2 and b.installed == 2
    assert not b.get("o_pending_store") and not b.get("o_fatal")


async def local_atomic(
    b: Private,
    address: int,
    old: int,
    data: int,
    *,
    sc: bool = False,
    size: int = 3,
    reservation: int = 1,
    probe_stage: int | None = 11,
    probe_opcode: int = 1,
    reservation_offset: int = 0,
    reservation_size: int | None = None,
    lose_reservation_stage: int | None = None,
    pending_grant: int | None = None,
) -> int:
    """Hold a selected probe across a tagged local update or failed SC."""
    success = bool(
        reservation
        and reservation_offset == 0
        and reservation_size in (None, size)
        and lose_reservation_stage is None
    )
    await b.set(
        i_atomic_protected=1,
        i_address=address,
        i_read_kind=2,
        i_read_size=size,
        i_read_tag=3,
        i_read_id=4,
        i_sc_address=address,
        i_sc_size=size,
        i_sc_tag=3,
        i_reservation_valid=reservation,
        i_reservation_addr=address + reservation_offset,
        i_reservation_size=size if reservation_size is None else reservation_size,
    )
    start = b.cycles
    if sc:
        await b.set(i_sc_valid=1)
        await b.wait("o_sc_ready")
        await b.tick()
        await b.set(i_sc_valid=0)
    else:
        await b.set(i_read_valid=1)
        await b.tick()
        await b.set(i_read_valid=0)
    offered = False
    for _ in range(60):
        assert not b.get("o_d_valid"), "resident M atomic allocated a home identity"
        if b.get("phase_q") == lose_reservation_stage:
            await b.set(i_reservation_valid=0)
        if b.get("phase_q") == probe_stage and not offered:
            await b.set(
                i_p_valid=1,
                i_p=pack(
                    (2, probe_opcode),
                    (6, 9),
                    (1, 0),
                    (b.p, address & ~31),
                    (2, 0),
                    (2, 1),
                    (9, 0),
                    (5, 0),
                    (3, size),
                ),
                i_cut_admit_ready=1,
                i_cut_admit_clean=1,
            )
            offered = True
        if b.get("o_sc_result_valid" if sc else "o_read_valid"):
            break
        await b.tick()
    else:
        raise AssertionError("local atomic did not produce a result")
    if sc:
        assert b.get("o_sc_success") == success and not b.get("o_sc_error")
    else:
        assert b.get("o_read_data") == old and b.get("o_read_id") == 4
    if pending_grant is not None:
        await b.set(i_g_valid=1, i_g=pending_grant)
        await b.wait("o_g_ready")
        await b.tick()
        await b.set(i_g_valid=0)
        assert not b.get("grant_ready")
    for _ in range(7):
        assert b.get("o_atomic_live") and not b.get("o_p_ready")
        assert not b.get("o_cut_hold") and not b.get("o_d_valid")
        await b.tick()
    await b.set(i_sc_result_ready=int(sc), i_read_ready=int(not sc))
    await b.tick()
    await b.set(i_sc_result_ready=0, i_read_ready=0)
    if sc and not success:
        assert not b.get("o_sc_write_pending")
    else:
        if sc:
            await b.set(i_sc_commit=1)
            await b.tick()
            await b.set(i_sc_commit=0)
        mask = 255 if size == 3 else 15 << (address & 7)
        await b.set(
            i_write_atomic=1,
            i_write_sc=int(sc),
            i_write_tag=3,
            i_write_mask=mask,
            i_write_data=data,
        )
        await b.tick()
        await b.set(i_write_mask=0)
        for _ in range(30):
            if b.get("phase_q") == probe_stage and not offered:
                await b.set(
                    i_p_valid=1,
                    i_p=pack(
                        (2, probe_opcode),
                        (6, 9),
                        (1, 0),
                        (b.p, address & ~31),
                        (2, 0),
                        (2, 1),
                        (9, 0),
                        (5, 0),
                        (3, size),
                    ),
                    i_cut_admit_ready=1,
                    i_cut_admit_clean=1,
                )
                offered = True
            if b.get("o_write_done"):
                break
            assert b.get("o_atomic_live") and not b.get("o_p_ready")
            assert not b.get("o_cut_hold") and not b.get("o_d_valid")
            await b.tick()
        else:
            raise AssertionError("protected write stalled behind offered probe")
        assert b.get("o_sc_write_done") == int(sc)
        assert b.get("o_atomic_live")
    if probe_stage == 13 and not offered:
        await b.set(
            i_p_valid=1,
            i_p=pack(
                (2, probe_opcode),
                (6, 9),
                (1, 0),
                (b.p, address & ~31),
                (2, 0),
                (2, 1),
                (9, 0),
                (5, 0),
                (3, size),
            ),
            i_cut_admit_ready=1,
            i_cut_admit_clean=1,
        )
        offered = True
    await b.wait("o_atomic_live", 0)
    elapsed = b.cycles - start
    assert not b.get("o_c_valid") and not b.get("o_d_valid")
    assert not b.get("o_fatal")
    if offered:
        await b.wait("o_p_ready")
        await b.tick()
        await b.set(i_p_valid=0)
        await b.wait("o_r_valid")
        reply = unpack(b.get("o_r"), (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
        if probe_opcode == 2:
            assert reply[0] == 2 and not reply[7]
        else:
            assert reply[7] and reply[5] == (2 if probe_opcode == 0 else 0)
        await b.set(i_r_ready=1)
        await b.tick()
        await b.set(i_r_ready=0, i_write_atomic=0, i_write_sc=0)
        return reply[8]
    if probe_stage is None:
        await b.set(i_write_atomic=0, i_write_sc=0)
        return 0
    raise AssertionError(
        f"probe stage {probe_stage} was not reached in {elapsed} cycles"
    )


@cocotb.test()
async def local_modified_atomics_hold_service_through_installation(dut: Any) -> None:
    """Defer probes at lookup, result, merge, update and release boundaries."""
    pattern = int.from_bytes(bytes(range(32)), "little")
    for sc in (False, True):
        for stage in (
            (1, 2, 9, 11, 12, 5, 6, 13) if sc else (1, 2, 9, 10, 11, 12, 5, 6, 13)
        ):
            for size, offset in ((3, 16), (2, 4)):
                b = Private(dut)
                await b.reset()
                address = 0x80000000
                await store(b, address, pattern & ((1 << 64) - 1))
                await getm(b, address, pattern)
                old = (pattern >> (8 * (offset & ~7))) & ((1 << 64) - 1)
                data = 0xFEDCBA9876543210
                actual = await local_atomic(
                    b, address + offset, old, data, sc=sc, size=size, probe_stage=stage
                )
                mask = ((1 << (64 if size == 3 else 32)) - 1) << (8 * offset)
                shifted = data << (8 * (offset & ~7))
                assert actual == (pattern & ~mask) | (shifted & mask)


@cocotb.test()
async def local_sc_reservation_failure_has_no_write(dut: Any) -> None:
    """Check failed selected SC returns once without modifying bytes."""
    b = Private(dut)
    await b.reset()
    address = 0x80000000
    pattern = int.from_bytes(bytes(range(32)), "little")
    await store(b, address, pattern & ((1 << 64) - 1))
    await getm(b, address, pattern)
    actual = await local_atomic(b, address, 0, 0, sc=True, reservation=0, probe_stage=9)
    assert actual == pattern


@cocotb.test()
async def local_sc_rechecks_exact_reservation_before_success(dut: Any) -> None:
    """Reject address, size and preauthorization reservation losses without a write."""
    cases = [
        {"reservation_offset": 8},
        {"reservation_size": 2},
        *({"lose_reservation_stage": stage} for stage in (1, 2, 9)),
    ]
    for case in cases:
        b = Private(dut)
        await b.reset()
        address = 0x80000000
        pattern = int.from_bytes(bytes(range(32)), "little")
        await store(b, address, pattern & ((1 << 64) - 1))
        await getm(b, address, pattern)
        actual = await local_atomic(b, address, 0, 0, sc=True, probe_stage=14, **case)
        assert actual == pattern


@cocotb.test()
async def local_owner_defers_read_and_check_sc_probes(dut: Any) -> None:
    """Read and reservation probes wait for installation at every local phase."""
    address = 0x80000000
    for sc in (False, True):
        stages = (1, 2, 9, 11, 12, 5, 6, 13) if sc else (1, 2, 9, 10, 11, 12, 5, 6, 13)
        for opcode in (0, 2):
            for stage in stages:
                b = Private(dut)
                await b.reset()
                await store(b, address, 11)
                await getm(b, address, 11)
                actual = await local_atomic(
                    b, address, 11, 99, sc=sc, probe_stage=stage, probe_opcode=opcode
                )
                if opcode == 0:
                    assert actual == 99
                else:
                    assert await snapshot(b, address) == 99


@cocotb.test()
async def local_write_survives_dirty_eviction(dut: Any) -> None:
    """Preserve the installed atomic bytes in accepted and absorbed PutM records."""
    address = 0x80000000
    for sc in (False, True):
        for absorbed in (False, True):
            b = Private(dut)
            await b.reset()
            await store(b, address, 11)
            await getm(b, address, 11)
            await local_atomic(b, address, 11, 99, sc=sc, probe_stage=None)
            images = {address: 99}
            evicted = False
            for index in range(1, 17):
                other = address + index * 128
                images[other] = index
                await store(b, other, index)
                await getm(b, other, 0)
                await b.set(i_read_valid=1, i_read_kind=0, i_read_id=0, i_address=other)
                await b.tick()
                await b.set(i_read_valid=0)
                await b.wait("o_read_valid")
                assert b.get("o_read_data") == index
                await b.set(i_read_ready=1)
                await b.tick()
                await b.set(i_read_ready=0)
                if not b.get("o_w_valid"):
                    continue
                frozen = b.get("o_w")
                put = unpack(frozen, (1, 1, 1, b.p, 256, 1))
                victim = put[3]
                assert put[4] == images[victim]
                absorb_this = absorbed and victim == address
                if absorb_this:
                    assert await snapshot(b, victim) == 99
                else:
                    await b.set(i_w_ready=1)
                    await b.tick()
                    await b.set(i_w_ready=0)
                await b.tick(8)
                assert b.get("o_w") == frozen
                await b.set(
                    i_wa_valid=1,
                    i_wa=pack(
                        (1, put[0]),
                        (1, put[1]),
                        (1, put[2]),
                        (b.p, victim),
                        (1, absorb_this),
                        (6, 1 if absorb_this else 0),
                        (1, 0),
                    ),
                )
                await b.wait("o_wa_ready")
                await b.tick()
                await b.set(i_wa_valid=0)
                if victim == address:
                    evicted = True
                    break
            assert evicted and not b.get("o_fatal")

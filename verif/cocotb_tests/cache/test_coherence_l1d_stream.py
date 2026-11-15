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

"""Hold coherent channels independently while speculative reads share the cache."""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack
from cocotb_tests.cache.test_coherence_l1d import Private


class StreamPrivate(Private):
    """Record accepted requests and responses without completing endpoints implicitly."""

    def __init__(self, dut: Any) -> None:
        """Initialize independent channel records."""
        super().__init__(dut)
        self.endpoints = len(dut.o_d_valid)
        self.requests: list[tuple[int, tuple[int, ...]]] = []
        self.responses: list[tuple[int, int, int]] = []
        self.completed: set[int] = set()
        self.completion_accepted: set[int] = set()
        self.resident_hints_while_held: list[int] = []
        self.install_touches: list[int] = []

    async def tick(self, count: int = 1) -> None:
        """Record handshakes before each active edge."""
        for _ in range(count):
            if not self.get("i_rst"):
                # A grant's Update phase, with the array ready for it.
                if (
                    self.get("active")
                    and self.get("phase_q") == 5
                    and self.get("operation_q") == 2
                    and self.get("update_ready")
                ):
                    self.install_touches.append(self.get("grant_touch_q"))
                if (
                    self.get("phase_q") == 2
                    and self.get("array_valid")
                    and self.get("operation_q") == 7
                    and self.get("array_hit")
                    and self.get("o_read_valid")
                    and not self.get("i_read_ready")
                ):
                    self.resident_hints_while_held.append(self.get("lookup_addr_q"))
                for ep in range(self.endpoints):
                    if (self.get("o_d_valid") & self.get("i_d_ready")) >> ep & 1:
                        bits = (self.get("o_d") >> (ep * (self.p + 312))) & (
                            (1 << (self.p + 312)) - 1
                        )
                        self.requests.append(
                            (ep, unpack(bits, (4, 9, self.p, 5, 3, 32, 1, 1, 1, 256)))
                        )
                if self.get("o_read_valid") and self.get("i_read_ready"):
                    self.responses.append(
                        (
                            self.get("o_read_id"),
                            self.get("o_read_data"),
                            self.get("o_read_error"),
                        )
                    )
            await super().tick()

    async def reset(self) -> None:
        """Reset all protocol peers and enable request acceptance."""
        await super().reset()
        self.requests.clear()
        self.responses.clear()
        self.completed.clear()
        self.completion_accepted.clear()
        self.resident_hints_while_held.clear()
        await self.set(i_d_ready=(1 << self.endpoints) - 1, i_atomic_protected=1)

    async def issue(
        self, slot: int, address: int, kind: int = 0, size: int = 3
    ) -> None:
        """Present one independent CPU read."""
        await self.set(
            i_read_valid=1,
            i_read_id=slot,
            i_address=address,
            i_read_kind=kind,
            i_read_size=size,
        )
        await self.tick()
        await self.set(i_read_valid=0)

    async def seed_before(self, address: int) -> None:
        """Complete the first training sector before occupying the demand slots."""
        await self.issue(7, address - 32)
        await self.drain(1)
        await self.set(i_read_ready=0)
        self.requests.clear()
        self.responses.clear()
        self.completed.clear()
        self.completion_accepted.clear()

    async def requests_at_least(self, count: int) -> None:
        """Wait for accepted D messages with a fixed cycle bound."""
        for _ in range(400):
            if len(self.requests) >= count:
                return
            await self.tick()
        raise AssertionError(f"Only {len(self.requests)} requests, expected {count}")

    @staticmethod
    def word(address: int) -> int:
        """Give each dword a distinct deterministic value."""
        return address ^ 0x13579BDF01234567

    async def send_grant(self, index: int, error: bool = False) -> None:
        """Transfer G into an endpoint without waiting for local service."""
        ep, request = self.requests[index]
        data = sum(self.word(request[2] + 8 * word) << (64 * word) for word in range(4))
        await self.set(
            i_g_valid=1,
            i_g=pack(
                (3, 2 if request[0] in (1, 3, 4) else 0),
                (9, request[1]),
                (6, ep),
                (self.p, request[2]),
                (256, data),
                (1, int(error)),
            ),
        )
        await self.wait("o_g_ready")
        await self.tick()
        await self.set(i_g_valid=0)

    async def grant(self, index: int, error: bool = False) -> None:
        """Grant one recorded request and wait for its C offer."""
        await self.send_grant(index, error)
        ep, _ = self.requests[index]
        for _ in range(250):
            if self.get("o_c_valid") >> ep & 1:
                return
            await self.tick()
        raise AssertionError(f"No completion for endpoint {ep}")

    def completion(self, index: int) -> tuple[int, ...]:
        """Decode one endpoint's completion identity, status and write acknowledgement."""
        ep, _ = self.requests[index]
        bits = (self.get("o_c") >> (ep * (self.p + 18))) & ((1 << (self.p + 18)) - 1)
        return unpack(bits, (9, 6, self.p, 2, 1))

    async def accept_completion(self, index: int) -> None:
        """Accept C while leaving its endpoint waiting for U."""
        ep, _ = self.requests[index]
        assert self.get("o_c_valid") >> ep & 1
        await self.set(i_c_ready=1 << ep)
        await self.tick()
        await self.set(i_c_ready=0)
        self.completion_accepted.add(index)

    async def release(self, index: int) -> None:
        """Accept any pending C and return U for the matching transaction."""
        ep, request = self.requests[index]
        if index not in self.completion_accepted:
            await self.accept_completion(index)
        await self.set(
            i_c_ready=0,
            i_u_valid=1,
            i_u=pack((9, request[1]), (6, ep), (self.p, request[2])),
        )
        await self.wait("o_u_ready")
        await self.tick()
        await self.set(i_u_valid=0)
        self.completed.add(index)

    async def probe(
        self,
        address: int,
        opcode: int = 0,
        check_q: int = 0,
        tid: int = 17,
        requester: int = 2,
    ) -> None:
        """Capture a probe and hold its reply for explicit acceptance."""
        await self.set(
            i_p_valid=1,
            i_p=pack(
                (2, opcode),
                (6, tid),
                (1, 0),
                (self.p, address),
                (2, requester),
                (2, 3 if opcode == 2 else 0),
                (9, check_q),
                (5, 0),
                (3, 3),
            ),
        )
        await self.wait("o_p_ready")
        await self.tick()
        await self.set(i_p_valid=0)
        await self.wait("o_r_valid")

    async def finish_atomic(self, index: int, sc: bool = False) -> None:
        """Complete endpoint-zero acquisition, CPU write, C and delayed U."""
        ep, request = self.requests[index]
        assert ep == 0 and not self.get("live") & ~1
        if sc:
            await self.set(
                i_reservation_valid=1,
                i_reservation_addr=request[2],
                i_reservation_size=3,
            )
            await self.probe(
                request[2],
                opcode=2,
                check_q=request[1],
                tid=ep,
                requester=request[1] >> 7,
            )
            reply = unpack(
                self.get("o_r"), (2, 6, 1, 1, self.p, 2, 1, 1, 256, 1, 1, 1, 1, 1)
            )
            assert reply[0] == 2 and reply[1] == ep and reply[4] == request[2]
            assert reply[12] and not reply[13]
            await self.set(i_r_ready=1)
            await self.tick()
            await self.set(i_r_ready=0)
            await self.probe(request[2], tid=ep, requester=request[1] >> 7)
            reply = unpack(
                self.get("o_r"), (2, 6, 1, 1, self.p, 2, 1, 1, 256, 1, 1, 1, 1, 1)
            )
            assert reply[1] == ep and reply[4] == request[2] and not reply[13]
            await self.set(i_r_ready=1)
            await self.tick()
            await self.set(i_r_ready=0)
        await self.send_grant(index)
        await self.wait("atomic_granted_q")
        await self.tick(12)
        assert not self.get("o_c_valid") and self.get("live") == 1
        if sc:
            assert self.get("o_sc_result_valid") and self.get("o_sc_success")
            assert not self.get("o_sc_error")
            await self.set(i_sc_commit=1, i_sc_result_ready=1)
            await self.tick()
            await self.set(i_sc_commit=0)
        else:
            await self.wait("o_read_valid")
            assert self.get("o_read_data") == self.word(request[2])
            assert not self.get("o_read_error")
        await self.set(
            i_address=request[2],
            i_write_mask=255,
            i_write_data=0xFEDCBA9876543210,
            i_write_atomic=1,
            i_write_sc=int(sc),
            i_write_tag=7 if sc else 0,
        )
        await self.tick()
        await self.set(i_write_mask=0)
        await self.wait("o_c_valid")
        expected = (request[1], ep, request[2], 0, 1)
        for _ in range(12):
            assert self.completion(index) == expected and self.get("o_c_valid") == 1
            assert self.get("live") == 1 and self.get("atomic_q")
            await self.tick()
        await self.accept_completion(index)
        await self.tick(12)
        assert self.get("live") == 1 and self.get("atomic_q")
        await self.release(index)
        assert not self.get("atomic_q") and not self.get("live")

    async def drain(self, count: int) -> None:
        """Complete requests until all expected demand responses arrive."""
        await self.set(i_read_ready=1)
        index = 0
        for _ in range(300):
            if len(self.responses) == count:
                return
            if index < len(self.requests):
                if index not in self.completed:
                    await self.grant(index)
                    await self.release(index)
                index += 1
            else:
                await self.tick()
        raise AssertionError(
            f"Only {len(self.responses)} CPU responses, expected {count}"
        )


class MergeCount(StreamPrivate):
    """Count read lookups, hit-path answers and the L1D's access events."""

    # cache_instance_perf_events_t, least significant field first.
    PERF_PATH_HIT, PERF_ACCESS, PERF_HIT, PERF_MISS = 13, 11, 10, 9

    def __init__(self, dut: Any) -> None:
        """Start empty counts."""
        super().__init__(dut)
        self.lookups = 0
        self.shadows = 0
        self.path_hits = 0
        self.events = [0, 0, 0]

    async def tick(self, count: int = 1) -> None:
        """Count a read lookup at its response and each registered event.

        A shadow lookup, of a read the hit path holds, counts apart. A
        hit-path answer counts as an access and a hit.
        """
        for _ in range(count):
            if not self.get("i_rst"):
                if (
                    self.get("phase_q") == 2
                    and self.get("array_valid")
                    and self.get("operation_q") == 0
                ):
                    if self.get("shadow_q"):
                        self.shadows += 1
                    else:
                        self.lookups += 1
                perf = self.get("o_perf_events")
                path_hit = perf >> self.PERF_PATH_HIT & 1
                self.path_hits += path_hit
                self.events[0] += (perf >> self.PERF_ACCESS & 1) + path_hit
                self.events[1] += (perf >> self.PERF_HIT & 1) + path_hit
                self.events[2] += perf >> self.PERF_MISS & 1
            await super().tick()

    def clear_counts(self) -> None:
        """Restart the counts and the recorded traffic."""
        self.lookups = 0
        self.shadows = 0
        self.path_hits = 0
        self.events = [0, 0, 0]
        self.requests.clear()
        self.responses.clear()
        self.completed.clear()
        self.completion_accepted.clear()


class AttachedMemory(StreamPrivate):
    """Check every response against byte memory sampled in program order."""

    def __init__(self, dut: Any) -> None:
        """Keep separate program bytes, home bytes and outstanding load values."""
        super().__init__(dut)
        self.memory: dict[int, int] = {}
        self.home: dict[int, int] = {}
        self.expected: dict[int, int] = {}
        self.attachments: list[tuple[int, int, int]] = []
        self.grant_answers = 0
        self.replay_answers = 0
        self.sc_results: list[tuple[int, int]] = []

    def image(self, address: int, count: int, *, home: bool = False) -> int:
        """Read little-endian bytes, with a distinct initial value per dword."""
        memory = self.home if home else self.memory
        return sum(
            memory.get(byte, (self.word(byte & ~7) >> (8 * (byte & 7))) & 255)
            << (8 * offset)
            for offset, byte in enumerate(range(address, address + count))
        )

    def write(self, address: int, data: int, mask: int, *, home: bool = False) -> None:
        """Apply byte strobes to the reference or to the external home image."""
        memory = self.home if home else self.memory
        for offset in range(mask.bit_length()):
            if mask >> offset & 1:
                memory[address + offset] = (data >> (8 * offset)) & 255

    async def tick(self, count: int = 1) -> None:
        """Check uniqueness and data at each handshake, and record path witnesses."""
        for _ in range(count):
            if not self.get("i_rst"):
                if self.get("o_read_valid") and self.get("i_read_ready"):
                    slot = self.get("o_read_id")
                    assert slot in self.expected, f"Unexpected or duplicate load {slot}"
                    expected = self.expected.pop(slot)
                    assert not self.get("o_read_error")
                    assert self.get("o_read_data") == expected, (
                        f"Load {slot}: {self.get('o_read_data'):#x} != {expected:#x}"
                    )
                if self.get("wait_attach") and self.get("wait_attach_live"):
                    self.attachments.append(
                        (
                            self.get("same_line_ep"),
                            1 << self.get("selected_read_q"),
                            self.get("merge_attach_slots"),
                        )
                    )
                self.grant_answers |= self.get("grant_answer_slots")
                if self.get("read_hit"):
                    self.replay_answers |= 1 << self.get("selected_read_q")
                self.replay_answers |= self.get("merge_hit_slots")
                if self.get("o_sc_result_valid") and self.get("i_sc_result_ready"):
                    self.sc_results.append(
                        (self.get("o_sc_success"), self.get("o_sc_error"))
                    )
            await super().tick()

    async def reset(self) -> None:
        """Discard the reset generation's loads and clear observations."""
        self.expected.clear()
        self.attachments.clear()
        self.grant_answers = self.replay_answers = 0
        self.sc_results.clear()
        await super().reset()

    async def issue(
        self, slot: int, address: int, kind: int = 0, size: int = 3
    ) -> None:
        """Snapshot a load's value before presenting it to the cache."""
        assert slot not in self.expected
        self.expected[slot] = self.image(address & ~7, 8)
        await super().issue(slot, address, kind, size)

    async def send_grant(
        self, index: int, error: bool = False, *, opcode: int | None = None
    ) -> None:
        """Return home bytes without pre-applying a pending cache store."""
        ep, request = self.requests[index]
        if opcode is None:
            opcode = 2 if request[0] in (1, 3, 4) else 0
        await self.set(
            i_g_valid=1,
            i_g=pack(
                (3, opcode),
                (9, request[1]),
                (6, ep),
                (self.p, request[2]),
                (256, self.image(request[2], 32, home=True)),
                (1, int(error)),
            ),
        )
        await self.wait("o_g_ready")
        await self.tick()
        await self.set(i_g_valid=0)

    async def store(self, address: int, data: int, mask: int = 255) -> None:
        """Order a store after all previously issued reference loads."""
        await self.wait("o_store_ready")
        await self.tick()
        self.write(address, data, mask)
        await self.set(i_address=address, i_write_mask=mask, i_write_data=data)
        await self.tick()
        await self.set(i_write_mask=0)

    async def attached(self, mask: int, ep: int, *, merged: bool = True) -> None:
        """Require an actual attachment to the specified live endpoint."""
        for _ in range(100):
            if self.get("rd_wait_q") & mask == mask:
                break
            await self.tick()
        else:
            raise AssertionError(f"Loads {mask:#x} did not attach to endpoint {ep}")
        selected = combined = 0
        for target, one, others in self.attachments:
            if target == ep:
                selected |= one | others
                combined |= others
        assert selected & mask == mask, self.attachments
        if merged:
            assert combined & mask, "No same-sector load used merge attachment"

    async def complete(self, index: int) -> None:
        """Finish an already supplied grant, preserving independent C and U."""
        ep, _ = self.requests[index]
        for _ in range(250):
            if self.get("o_c_valid") >> ep & 1:
                await self.release(index)
                return
            await self.tick()
        raise AssertionError(f"No completion for request {index}")

    async def checked(self) -> None:
        """Consume every expected load and leave a window that detects duplicates."""
        await self.set(i_read_ready=1)
        for _ in range(250):
            if not self.expected:
                break
            await self.tick()
        assert not self.expected, f"Missing load responses: {self.expected}"
        await self.tick(24)
        assert not self.get("rd_valid_q") and not self.get("rd_wait_q")
        assert not self.get("o_read_valid") and not self.get("o_fatal")

    async def invalidate(self, address: int) -> tuple[int, ...]:
        """Complete an invalidation and return its independently held reply."""
        await self.set(i_cut_admit_ready=1, i_cut_admit_clean=1, i_cut_inval_done=1)
        await self.probe(address, opcode=1)
        reply = unpack(
            self.get("o_r"), (2, 6, 1, 1, self.p, 2, 1, 1, 256, 1, 1, 1, 1, 1)
        )
        assert reply[4] == address and reply[5] == 0 and not reply[-1]
        await self.set(i_r_ready=1)
        await self.tick()
        await self.set(i_r_ready=0)
        return reply


@cocotb.test()
async def same_sector_loads_share_a_lookup(dut: Any) -> None:
    """Answer a sector's waiting loads from one lookup's row or one attachment.

    The hit path answers loads of a resident sector itself; a merge takes only
    the loads it does not hold. Loads of a missing sector miss the hit path,
    and the grant answers every load attached to the endpoint.
    """
    b = MergeCount(dut)
    base = 0x80006000
    # A resident sector: the hit path and at most one lookup's row answer the
    # loads, each once, as hits.
    await b.reset()
    await b.issue(0, base + 24)
    await b.drain(1)
    await b.set(i_read_ready=0)
    await b.tick(10)
    b.clear_counts()
    for slot in range(1, 4):
        await b.issue(slot, base + 8 * (slot - 1))
    await b.tick(20)
    await b.set(i_read_ready=1)
    await b.tick(20)
    assert sorted(b.responses) == [
        (slot, b.word(base + 8 * (slot - 1)), 0) for slot in range(1, 4)
    ]
    dut._log.info(
        "resident: lookups %d shadows %d path hits %d events %s",
        b.lookups,
        b.shadows,
        b.path_hits,
        b.events,
    )
    assert b.lookups <= 1, b.lookups
    assert b.events == [3, 3, 0], b.events
    assert not b.requests
    if b.endpoints < 2:
        return
    # A missing sector: the first attachment attaches the loads behind it,
    # and the grant answers every one.
    await b.reset()
    b.clear_counts()
    await b.set(i_read_ready=0)
    await b.issue(0, base + 0x100)
    await b.requests_at_least(1)
    for slot in range(1, 4):
        await b.issue(slot, base + 0x100 + 8 * slot)
    await b.tick(20)
    assert b.get("rd_wait_q") & 0b1110 == 0b1110
    dut._log.info(
        "missing: lookups %d shadows %d before the grant", b.lookups, b.shadows
    )
    assert b.lookups <= 4, b.lookups
    lookups = b.lookups
    await b.drain(4)
    assert sorted(b.responses) == [
        (slot, b.word(base + 0x100 + 8 * slot), 0) for slot in range(4)
    ]
    assert len(b.requests) == 1
    assert b.lookups == lookups
    await b.tick(10)
    assert b.events == [4, 0, 4], b.events


@cocotb.test()
async def reset_discards_captured_merge_credits(dut: Any) -> None:
    """Reset between event capture and accumulation, then reuse the read IDs."""
    b = MergeCount(dut)
    if b.endpoints < 2:
        return
    await b.reset()
    base = 0x80006000
    await b.issue(0, base)
    await b.requests_at_least(1)
    for slot in range(1, 8):
        await b.issue(slot, base + 8 * (slot % 4))
        if b.get("perf_merge_miss_q"):
            break
    for _ in range(40):
        if b.get("perf_merge_miss_q"):
            break
        await b.tick()
    else:
        raise AssertionError("No merged event reached the capture stage")
    assert b.get("perf_merge_miss_q") & b.get("perf_read_seen_q")
    await b.reset()
    assert not b.get("perf_merge_hit_q") and not b.get("perf_merge_miss_q")
    assert not b.get("perf_owed_hit_q") and not b.get("perf_owed_miss_q")
    b.clear_counts()
    for slot in range(3):
        await b.issue(slot, base + 8 * slot)
    await b.drain(3)
    await b.tick(20)
    assert sorted(b.responses) == [
        (slot, b.word(base + 8 * slot), 0) for slot in range(3)
    ]
    assert b.events == [3, 0, 3], b.events


@cocotb.test()
async def demand_payloads_in_every_load_endpoint(dut: Any) -> None:
    """Preserve size and offset while ordinary reads occupy every load endpoint."""
    b = StreamPrivate(dut)
    if b.endpoints < 2:
        return
    for turn in range(4):
        await b.reset()
        await b.set(i_d_ready=0)
        expected = {}
        for slot in range(b.endpoints - 1):
            size = (turn + slot) % 4
            offset = 8 * (slot % 4) + (1 << size if size < 3 else 0)
            address = 0x80000000 + turn * 0x10000 + slot * 0x1000 + offset
            if b.p > 32:
                address |= 1 << (b.p - 1)
            expected[address & ~31] = (slot, address, size)
            await b.issue(slot, address, size=size)
        for _ in range(300):
            if b.get("o_d_valid").bit_count() == b.endpoints - 1:
                break
            await b.tick()
        else:
            raise AssertionError("Demand did not occupy every nonzero endpoint")
        assert b.get("o_d_valid") == (1 << b.endpoints) - 2
        assert not b.get("ld_prefetch_q")
        held = b.get("o_d")
        for _ in range(8):
            await b.tick()
            assert b.get("o_d") == held
        await b.set(i_d_ready=(1 << b.endpoints) - 1)
        await b.requests_at_least(b.endpoints - 1)
        assert {ep for ep, _ in b.requests} == set(range(1, b.endpoints))
        for ep, request in b.requests:
            _, address, size = expected[request[2]]
            assert request == (
                0,
                ep << 1,
                address & ~31,
                address & 31,
                size,
                0,
                0,
                0,
                0,
                0,
            )
        await b.drain(b.endpoints - 1)
        assert sorted(b.responses) == [
            (slot, b.word(address & ~7), 0)
            for slot, address, _ in sorted(expected.values())
        ]
        assert len(b.requests) == b.endpoints - 1
        assert not b.get("live") and not b.get("o_fatal")


@cocotb.test()
async def read_id_reuse_before_endpoint_release(dut: Any) -> None:
    """Reuse a consumed CPU read ID while its first endpoint waits for U."""
    b = StreamPrivate(dut)
    for kind in (0, 1):
        await b.reset()
        base = 0x80004000
        await b.issue(0, base)
        await b.requests_at_least(1)
        await b.grant(0)
        await b.set(i_read_ready=1)
        for _ in range(80):
            if len(b.responses) == 1:
                break
            await b.tick()
        else:
            raise AssertionError("First CPU read response did not drain")
        await b.accept_completion(0)
        await b.tick(12)
        old_ep = b.requests[0][0]
        assert b.get("live") == 1 << old_ep
        assert not b.get("rd_valid_q") & 1
        await b.issue(0, base + 512, kind=kind)
        parallel = b.endpoints >= (2 if kind else 3)
        if parallel:
            await b.requests_at_least(2)
            assert b.get("live") >> old_ep & 1
            assert b.requests[1][0] != old_ep
        else:
            await b.tick(20)
            assert len(b.requests) == 1 and b.get("rd_valid_q") & 1
            await b.release(0)
            await b.requests_at_least(2)
        assert b.requests[1][1][0] == (2 if kind else 0)
        if kind:
            assert b.requests[1][0] == 0
        await b.grant(1)
        await b.release(1)
        if parallel:
            await b.release(0)
        await b.drain(2)
        assert b.responses == [
            (0, b.word(base), 0),
            (0, b.word(base + 512), 0),
        ]
        assert not b.get("live") and not b.get("o_fatal")


@cocotb.test()
async def lookahead_and_occupied_read_ids(dut: Any) -> None:
    """Fill all demand IDs, hold their responses, and install speculative data."""
    b = StreamPrivate(dut)
    await b.reset()
    base = 0x80000020
    await b.seed_before(base)
    for slot in range(8):
        await b.issue(slot, base + slot * 8)
    speculative = 2 if b.endpoints >= 4 else int(b.endpoints == 3)
    await b.requests_at_least(2 if b.endpoints > 2 else 1)
    if b.endpoints in (3, 4):
        await b.grant(1)
        await b.release(1)
    await b.requests_at_least(2 + speculative if b.endpoints > 2 else 1)
    await b.tick(90)
    assert b.get("ld_prefetch_q").bit_count() == speculative
    assert (b.get("live") & b.get("ld_prefetch_q")).bit_count() == speculative
    if b.endpoints >= 4:
        assert {r[2] for _, r in b.requests} == {base, base + 32, base + 64, base + 96}
        assert all(r[0] == 0 and r[4] == 3 and r[5] == 0 for _, r in b.requests)
        demand = [i for i, (_, r) in enumerate(b.requests) if r[2] < base + 64]
        hints = [i for i, (_, r) in enumerate(b.requests) if r[2] >= base + 64]
        for index in demand:
            if index not in b.completed:
                await b.grant(index)
        await b.tick(100)
        held = (b.get("o_read_id"), b.get("o_read_data"), b.get("o_read_error"))
        for index in hints:
            await b.grant(index, error=index == hints[-1])
        await b.tick(50)
        assert held == (b.get("o_read_id"), b.get("o_read_data"), b.get("o_read_error"))
        assert (b.get("live") & b.get("ld_prefetch_q")).bit_count() == speculative
        for index in range(len(b.requests)):
            if index not in b.completed:
                await b.release(index)
    await b.drain(8)
    assert sorted(b.responses) == [
        (slot, b.word(base + slot * 8), 0) for slot in range(8)
    ]
    for slot, address in ((0, base + 64), (7, base + 96)):
        await b.issue(slot, address)
    await b.drain(10)
    assert sorted(b.responses[8:]) == [
        (0, b.word(base + 64), 0),
        (7, b.word(base + 96), 0),
    ]
    assert not b.get("o_fatal")


@cocotb.test()
async def speculative_attachment_and_retry(dut: Any) -> None:
    """Release a failed hint through U before its attached demand reacquires."""
    b = StreamPrivate(dut)
    if b.endpoints < 4:
        return
    await b.reset()
    base = 0x80001020
    await b.seed_before(base)
    await b.issue(0, base)
    await b.issue(1, base + 32)
    await b.requests_at_least(3)
    target = next(i for i, (_, r) in enumerate(b.requests) if r[2] == base + 64)
    ep = b.requests[target][0]
    await b.issue(2, base + 64)
    await b.tick(40)
    assert b.get("rd_wait_q") & 4
    assert b.get("ld_prefetch_q") >> ep & 1
    await b.grant(target, error=True)
    await b.tick(40)
    assert not b.get("o_read_valid")
    assert len([r for _, r in b.requests if r[2] == base + 64]) == 1
    assert b.get("rd_wait_release_q") & 4
    await b.release(target)
    for _ in range(100):
        if len([r for _, r in b.requests if r[2] == base + 64]) == 2:
            break
        await b.tick()
    else:
        raise AssertionError("Demand did not retry after speculative error")
    await b.drain(3)
    assert sorted(b.responses) == [
        (slot, b.word(base + 32 * slot), 0) for slot in range(3)
    ]


@cocotb.test()
async def stream_page_end_and_atomic_cancellation(dut: Any) -> None:
    """Check page-end saturation and queued-hint cancellation by pending LR."""
    b = StreamPrivate(dut)
    if b.endpoints < 4:
        return
    for cancellation in (False, True):
        await b.reset()
        base = 0x80000FA0
        await b.seed_before(base)
        await b.issue(0, base)
        await b.issue(1, base + 32)
        await b.requests_at_least(3)
        assert b.requests[-1][1][2] == base + 64
        if cancellation:
            await b.issue(2, base + 64, kind=1)
        await b.tick(90)
        assert all((r[2] & -4096) == (base & -4096) for _, r in b.requests)
        assert len(b.requests) == 3
        if cancellation:
            assert not b.get("hint_valid_q") and not b.get("stream_confirmed")
        await b.drain(3 if cancellation else 2)
        assert not b.get("o_fatal")


@cocotb.test()
async def resident_hint_preserves_waiting_data(dut: Any) -> None:
    """Discard a resident hint without overwriting a held demand word."""
    b = StreamPrivate(dut)
    if b.endpoints < 4:
        return
    await b.reset()
    base = 0x80000020
    await b.issue(7, base + 64)
    await b.drain(1)
    b.requests.clear()
    b.responses.clear()
    b.completed.clear()
    b.completion_accepted.clear()
    await b.seed_before(base)
    await b.issue(7, base + 64)
    await b.wait("o_read_valid")
    held = (b.get("o_read_id"), b.get("o_read_data"), b.get("o_read_error"))
    for slot in range(7):
        await b.issue(slot, base + 8 * slot)
    for address in (base, base + 32):
        for _ in range(150):
            matching = [
                i for i, (_, request) in enumerate(b.requests) if request[2] == address
            ]
            if matching:
                break
            await b.tick()
        else:
            raise AssertionError("Demand acquisition did not arrive")
        await b.grant(matching[0])
        await b.release(matching[0])
    await b.tick(100)
    assert base + 64 in b.resident_hints_while_held
    assert held == (b.get("o_read_id"), b.get("o_read_data"), b.get("o_read_error"))
    assert not any(request[2] == base + 64 for _, request in b.requests)
    await b.drain(8)
    assert sorted(b.responses) == [
        *((slot, b.word(base + 8 * slot), 0) for slot in range(7)),
        (7, b.word(base + 64), 0),
    ]


@cocotb.test()
async def cancellation_at_each_unaccepted_stage(dut: Any) -> None:
    """Cancel unaccepted hints after LR/AMO admission and on direct cancellation."""
    b = StreamPrivate(dut)
    if b.endpoints < 4:
        return
    for stage in range(5):
        for cancel in ("lr", "amo", "sc", "maintenance", "fatal", "reset"):
            if stage == 4 and cancel in ("lr", "amo"):
                continue
            await b.reset()
            await b.seed_before(0x80001020)
            await b.issue(0, 0x80001020)
            await b.issue(1, 0x80001040)
            for _ in range(150):
                phase = b.get("phase_q")
                hint = b.get("hint_valid_q") and not b.get("hint_checked_q")
                checked = b.get("hint_valid_q") and b.get("hint_checked_q")
                selected = b.get("operation_q") == 7
                reached = (
                    hint,
                    checked and phase == 0,
                    selected and phase == 1,
                    selected and phase == 2 and b.get("array_valid"),
                    selected and phase == 3,
                )[stage]
                if reached:
                    break
                await b.tick()
            else:
                raise AssertionError(f"Hint stage {stage} was not reached")
            assert not b.get("live") & b.get("ld_prefetch_q")
            if cancel in ("lr", "amo"):
                await b.set(
                    i_read_valid=1,
                    i_read_id=2,
                    i_read_kind=1 if cancel == "lr" else 2,
                    i_address=0x80001080,
                    i_read_size=3,
                )
            elif cancel == "sc":
                await b.set(i_sc_valid=1, i_sc_address=0x80001080, i_sc_size=3)
            elif cancel == "maintenance":
                await b.set(i_maint_valid=1, i_maint_line=1, i_maint_address=0x80001000)
            elif cancel == "fatal":
                await b.set(i_fatal_stop=1)
            else:
                await b.set(i_rst=1)
            # Reset acts at the flops and a fatal stop takes effect a cycle
            # after it rises, so a selected hint stays offered on this edge.
            if stage == 4:
                assert bool(b.get("ep_request_valid")) == (cancel in ("fatal", "reset"))
            await b.tick()
            await b.set(i_read_valid=0)
            if cancel in ("lr", "amo"):
                assert b.get("rd_valid_q") & 4 and b.get("atomic_read_waiting")
                assert b.get("prefetch_cancel")
            await b.tick()
            assert not b.get("hint_valid_q") and not b.get("hint_checked_q")
            assert not b.get("stream_confirmed")
            await b.tick(11)
            accepted = stage == 4 and cancel == "fatal"
            assert bool(b.get("live") & b.get("ld_prefetch_q")) == accepted


@cocotb.test()
async def live_conflicts_on_hint_acceptance(dut: Any) -> None:
    """Block a selected hint on a probe; a store on that edge waits for the hint."""
    b = StreamPrivate(dut)
    if b.endpoints < 3:
        return
    base = 0x80001020
    for conflict in ("store", "probe"):
        await b.reset()
        await b.seed_before(base)
        await b.issue(0, base)
        await b.issue(1, base + 32)
        if b.endpoints == 3:
            await b.requests_at_least(2)
            await b.grant(1)
            await b.release(1)
        for _ in range(150):
            if b.get("operation_q") == 7 and b.get("phase_q") == 3:
                break
            await b.tick()
        else:
            raise AssertionError("Hint did not reach internal acceptance")
        selected = b.get("ep_request_valid") & b.get("ep_request_ready")
        assert selected.bit_count() == 1 and len(b.requests) == 2
        address = b.get("lookup_addr_q")
        if conflict == "store":
            assert b.get("o_store_ready")
            await b.set(
                i_address=address, i_write_mask=255, i_write_data=b.word(address)
            )
            assert b.get("store_push")
            assert not b.get("lookup_conflict")
            assert b.get("ep_request_valid") == selected
            await b.tick()
            await b.set(i_write_mask=0)
            assert b.get("live") & selected and b.get("ld_prefetch_q") == selected
            assert b.get("pending_q")
            await b.requests_at_least(3)
            index = next(
                i for i, entry in enumerate(b.requests) if entry[1][2] == address
            )
            await b.tick(20)
            assert not any(entry[1][0] == 1 for entry in b.requests)
            await b.grant(index)
            await b.release(index)
            for _ in range(100):
                if any(entry[1][0] == 1 for entry in b.requests):
                    break
                await b.tick()
            ep, request = next(entry for entry in b.requests if entry[1][0] == 1)
            assert ep == 0 and request[2] == address
            assert not b.get("o_fatal")
            continue
        await b.set(
            i_p_valid=1,
            i_p=pack(
                (2, 0),
                (6, 17),
                (1, 0),
                (b.p, address),
                (2, 2),
                (2, 0),
                (9, 0),
                (5, 0),
                (3, 3),
            ),
        )
        assert b.get("lookup_conflict") and not b.get("ep_request_valid")
        await b.tick()
        assert not b.get("live") & selected
        assert not b.get("ld_prefetch_q") and len(b.requests) == 2
        await b.wait("o_p_ready")
        await b.tick()
        await b.set(i_p_valid=0)
        assert b.get("probe_valid_q")
        assert not b.get("o_fatal")


@cocotb.test()
async def accepted_hints_drain_for_exclusive_work(dut: Any) -> None:
    """Hold speculative ownership through U while home atomics and maintenance wait."""
    b = StreamPrivate(dut)
    if b.endpoints < 8:
        return
    for waiting in ("amo", "sc", "maintenance", "lr"):
        await b.reset()
        await b.seed_before(0x80001020)
        await b.issue(0, 0x80001020)
        await b.issue(1, 0x80001040)
        await b.requests_at_least(4)
        assert (b.get("live") & b.get("ld_prefetch_q")).bit_count() == 2
        assert b.get("stream_confirmed")
        if waiting == "amo":
            await b.issue(2, 0x80001080, kind=2)
        elif waiting == "lr":
            await b.issue(2, 0x80001060, kind=1)
        elif waiting == "sc":
            # SC acceptance needs only endpoint 0 idle; its home acquisition
            # waits for every endpoint.
            await b.set(i_sc_valid=1, i_sc_address=0x80001080, i_sc_size=3, i_sc_tag=7)
            await b.wait("o_sc_ready")
            await b.tick()
            await b.set(i_sc_valid=0)
            assert b.get("atomic_q")
        else:
            await b.set(i_maint_valid=1, i_maint_line=1, i_maint_address=0x80001000)
        await b.tick(10)
        assert not b.get("hint_valid_q") and not b.get("stream_confirmed")
        for index in range(4):
            await b.grant(index)
        for index in (2, 3):
            await b.accept_completion(index)
        for index in range(2):
            await b.release(index)
        await b.set(i_read_ready=1)
        await b.tick(50)
        assert (b.get("live") & b.get("ld_prefetch_q")).bit_count() == 2
        assert not b.get("o_c_valid") & b.get("ld_prefetch_q")
        assert len(b.requests) == 4 and not b.get("o_maint_done")
        if waiting == "lr":
            assert (2, b.word(0x80001060), 0) in b.responses
        await b.release(2)
        await b.tick(20)
        assert len(b.requests) == 4 and not b.get("o_maint_done")
        await b.release(3)
        if waiting == "amo":
            await b.requests_at_least(5)
            assert b.requests[4][0] == 0 and b.requests[4][1][0] == 3
            await b.set(i_read_ready=0)
            await b.finish_atomic(4)
        elif waiting == "sc":
            await b.requests_at_least(5)
            assert b.requests[4][0] == 0 and b.requests[4][1][0] == 4
            await b.finish_atomic(4, sc=True)
        elif waiting == "maintenance":
            await b.wait("o_maint_done")
        else:
            await b.tick(20)
            assert not b.get("live") and len(b.requests) == 4


@cocotb.test()
async def demand_turn_between_buffered_grants(dut: Any) -> None:
    """Answer a fill waiter with its grant and serve a read before the next grant."""
    b = StreamPrivate(dut)
    if b.endpoints < 3:
        return
    base = 0x80003000
    for error in (False, True):
        await b.reset()
        await b.set(i_read_ready=0)
        await b.issue(0, base)
        await b.issue(1, base + 512)
        await b.issue(2, base + 8)
        await b.requests_at_least(2)
        await b.tick(40)
        assert b.get("rd_wait_q") & 4
        await b.send_grant(0)
        await b.send_grant(1, error=error)
        # The first grant answers its own read and the waiter in read 2. The
        # installation's turn serves the read that arrives during it.
        await b.issue(3, base + 16)
        for _ in range(100):
            if b.get("phase_q") == 0 and b.get("grant_read_yield"):
                assert b.get("grant_pick") == b.requests[1][0]
                assert not b.get("grant_ready") and not b.get("read_failure")
                assert not b.get("rd_ready_q") & 2
                # Read 0's answer occupies the held response register.
                assert b.get("rd_ready_q") & 4
                await b.tick()
                assert b.get("operation_q") == 0 and b.get("selected_read_q") == 3
                break
            await b.tick()
        else:
            raise AssertionError("No demand turn between the buffered grants")
        for _ in range(100):
            if b.get("phase_q") == 0 and b.get("grant_valid") and b.get("grant_ready"):
                assert not b.get("grant_read_turn_q")
                assert b.get("rd_ready_q") & 8
                await b.tick()
                break
            await b.tick()
        else:
            raise AssertionError("The next grant did not follow the demand turn")
        mask = sum(1 << ep for ep, _ in b.requests)
        for _ in range(100):
            if b.get("o_c_valid") & mask == mask:
                break
            await b.tick()
        else:
            raise AssertionError("A buffered grant failed to complete")
        await b.release(0)
        await b.release(1)
        await b.drain(4)
        assert sorted(b.responses) == [
            (0, b.word(base), 0),
            (1, 0 if error else b.word(base + 512), int(error)),
            (2, b.word(base + 8), 0),
            (3, b.word(base + 16), 0),
        ]
        assert not b.get("o_fatal")


@cocotb.test()
async def credited_miss_waits_for_buffered_grant(dut: Any) -> None:
    """Prevent a credited miss from acquiring ahead of a buffered grant."""
    b = StreamPrivate(dut)
    if b.endpoints < 3:
        return
    for kind, arrival in (
        (0, "none"),
        (1, "lookup"),
        (1, "selection"),
        (2, "selection"),
    ):
        incoming_atomic = arrival != "none"
        await b.reset()
        await b.set(i_read_ready=0)
        base = 0x80004000
        await b.issue(0, base)
        await b.issue(1, base + 512)
        await b.issue(2, base + 8)
        await b.requests_at_least(2)
        await b.tick(20)
        await b.send_grant(0)
        await b.send_grant(1)
        await b.issue(3, base + 1024)
        for _ in range(100):
            if b.get("phase_q") == 0 and b.get("grant_read_yield"):
                assert b.get("rd_pick") == 3
                if arrival == "selection":
                    await b.issue(4, base + 1536, kind=kind)
                    assert b.get("phase_q") == 1 and b.get("grant_retry_q")
                else:
                    await b.tick()
                if arrival == "lookup":
                    await b.issue(4, base + 1536, kind=kind)
                if incoming_atomic:
                    assert b.get("prefetch_cancel") and b.get("grant_retry_q")
                break
            await b.tick()
        else:
            raise AssertionError("The fresh demand did not receive the credited turn")
        for _ in range(100):
            if b.get("phase_q") == 2 and b.get("array_valid"):
                assert b.get("operation_q") == 0 and b.get("selected_read_q") == 3
                assert not b.get("array_hit") and b.get("load_acquire_block")
                await b.tick()
                assert b.get("phase_q") == 0 and len(b.requests) == 2
                assert b.get("grant_valid") and b.get("grant_ready")
                await b.tick()
                break
            await b.tick()
        else:
            raise AssertionError(
                "The credited miss did not yield to its buffered grant"
            )
        mask = sum(1 << ep for ep, _ in b.requests)
        for _ in range(100):
            if b.get("o_c_valid") & mask == mask:
                break
            await b.tick()
        else:
            raise AssertionError("The buffered grant did not complete")
        await b.release(0)
        await b.release(1)
        await b.requests_at_least(3)
        if kind == 2:
            assert b.requests[2][0] == 0 and b.requests[2][1][0] == 3
            await b.set(i_read_ready=1)
            await b.tick(10)
            await b.set(i_read_ready=0)
            await b.finish_atomic(2)
        await b.drain(5 if incoming_atomic else 4)
        expected = [
            (0, b.word(base), 0),
            (1, b.word(base + 512), 0),
            (2, b.word(base + 8), 0),
            (3, b.word(base + 1024), 0),
        ]
        if incoming_atomic:
            expected.append((4, b.word(base + 1536), 0))
        assert sorted(b.responses) == expected
        assert not b.get("o_fatal")


@cocotb.test()
async def credited_miss_keeps_its_turn(dut: Any) -> None:
    """Keep the circular read pointer at a credited miss for the next selection."""
    b = StreamPrivate(dut)
    if b.endpoints < 4:
        return
    await b.reset()
    await b.set(i_read_ready=0)
    base = 0x80005000
    await b.issue(0, base)
    await b.issue(1, base + 512)
    await b.issue(2, base + 8)
    await b.requests_at_least(2)
    await b.tick(20)
    await b.send_grant(0)
    await b.send_grant(1)
    await b.issue(3, base + 1024)
    for _ in range(100):
        if b.get("phase_q") == 0 and b.get("grant_read_yield"):
            assert b.get("rd_pick") == 3
            pointer = b.get("rd_rr_q")
            await b.tick()
            assert b.get("selected_read_q") == 3 and b.get("rd_rr_q") == pointer
            break
        await b.tick()
    else:
        raise AssertionError("The fresh demand did not receive the credited turn")
    # The credited lookup misses beside the buffered grant. The next ordinary
    # selection returns to read 3 before the waiter in read 2.
    for _ in range(100):
        await b.tick()
        if b.get("phase_q") == 0:
            break
    for _ in range(200):
        if b.get("phase_q") == 1 and b.get("operation_q") == 0:
            assert b.get("selected_read_q") == 3
            break
        await b.tick()
    else:
        raise AssertionError("No ordinary read selection followed the credited miss")
    await b.requests_at_least(3)
    assert b.requests[2][1][2] == base + 1024
    mask = (1 << b.requests[0][0]) | (1 << b.requests[1][0])
    for _ in range(100):
        if b.get("o_c_valid") & mask == mask:
            break
        await b.tick()
    else:
        raise AssertionError("The buffered grants did not complete")
    await b.release(0)
    await b.release(1)
    await b.drain(4)
    assert sorted(b.responses) == [
        (0, b.word(base), 0),
        (1, b.word(base + 512), 0),
        (2, b.word(base + 8), 0),
        (3, b.word(base + 1024), 0),
    ]
    assert not b.get("o_fatal")


@cocotb.test()
async def empty_turn_and_probe_local_turn(dut: Any) -> None:
    """Consume one empty opportunity and preserve unused credit across held R."""
    b = StreamPrivate(dut)
    if b.endpoints < 3:
        return
    for mode in ("store", "probe", "cancel"):
        for error in (False, True):
            await b.reset()
            base = 0x80003000
            await b.issue(0, base)
            await b.issue(1, base + 512)
            await b.issue(2, base + 8)
            await b.requests_at_least(2)
            await b.tick(40)
            await b.send_grant(0)
            await b.send_grant(1, error=error)
            # The first grant answers read 2, its waiter; read 3 arrives
            # during the installation and stays unanswered through the turn.
            await b.issue(3, base + 16)
            if mode == "store":
                await b.set(i_address=base, i_write_mask=255, i_write_data=123)
                await b.tick()
                await b.set(i_write_mask=0)
            for _ in range(100):
                if b.get("phase_q") == 0 and b.get("grant_read_hold"):
                    break
                await b.tick()
            else:
                raise AssertionError("No unused grant-deferral opportunity")
            assert not b.get("prefetch_cancel")
            assert not b.get("grant_ready") and not b.get("read_failure")
            if mode == "probe":
                await b.probe(base + 2048)
                for _ in range(12):
                    assert b.get("grant_read_turn_q") and not b.get("grant_ready")
                    assert not b.get("rd_ready_q") & 2 and not b.get("read_failure")
                    await b.tick()
                await b.set(i_r_ready=1)
                await b.tick()
                await b.set(i_r_ready=0)
                assert b.get("local_turn_q") and b.get("grant_ready")
            else:
                if mode == "cancel":
                    assert b.get("rd_candidate")
                    await b.set(
                        i_maint_valid=1, i_maint_line=1, i_maint_address=base + 2048
                    )
                    assert b.get("prefetch_cancel") and b.get("grant_read_hold")
                    assert b.get("rd_candidate") and not b.get("grant_read_yield")
                    assert not b.get("grant_ready") and not b.get("read_failure")
                else:
                    assert not b.get("rd_candidate") and not b.get("grant_read_yield")
                await b.tick()
                assert b.get("rd_ready_q") & 12 == 4
                assert b.get("phase_q") == 0 and not b.get("grant_read_turn_q")
                assert b.get("grant_ready")
            assert b.get("read_failure") == int(error)
            await b.tick()
            assert not b.get("grant_read_turn_q")
            await b.tick(30)
            assert b.get("o_c_valid") >> b.requests[1][0] & 1
            assert not b.get("o_fatal")


@cocotb.test()
async def atomic_admission_on_hint_acceptance(dut: Any) -> None:
    """Overlap LR/AMO admission with one hint and drain held D, C and U."""
    b = StreamPrivate(dut)
    if b.endpoints < 4:
        return
    base = 0x80001020
    for kind in (1, 2):
        for error in (False, True):
            await b.reset()
            await b.seed_before(base)
            await b.issue(0, base)
            await b.issue(1, base + 32)
            for _ in range(150):
                if b.get("operation_q") == 7 and b.get("phase_q") == 3:
                    break
                await b.tick()
            else:
                raise AssertionError("Hint did not reach internal acceptance")
            assert len(b.requests) == 2
            await b.set(
                i_d_ready=0,
                i_read_valid=1,
                i_read_id=2,
                i_read_kind=kind,
                i_read_size=3,
                i_address=base + 64,
            )
            accepted = b.get("ep_request_valid") & b.get("ep_request_ready")
            assert accepted.bit_count() == 1 and not b.get("prefetch_cancel")
            await b.tick()
            await b.set(i_read_valid=0)
            assert b.get("atomic_read_waiting") and b.get("prefetch_cancel")
            assert b.get("rd_valid_q") & 4
            payload = b.get("rd_payload_flat") >> (
                2 * (b.p + 2 + 3 + len(dut.i_read_tag))
            )
            assert (payload >> (3 + len(dut.i_read_tag))) & 3 == kind
            assert b.get("live") & b.get("ld_prefetch_q") == accepted
            held_d = b.get("o_d")
            await b.tick()
            assert not b.get("hint_valid_q") and not b.get("hint_checked_q")
            assert not b.get("stream_confirmed")
            for _ in range(11):
                assert b.get("o_d_valid") == accepted and b.get("o_d") == held_d
                assert not b.get("ep_request_valid")
                assert not b.get("o_read_valid")
                await b.tick()
            assert not b.get("hint_valid_q") and not b.get("stream_confirmed")
            await b.set(i_d_ready=(1 << b.endpoints) - 1)
            await b.requests_at_least(3)
            assert b.requests[2][1][2] == base + 64
            await b.grant(2, error=error)
            ep, request = b.requests[2]
            expected = (request[1], ep, request[2], 2 if error else 0, 0)
            for _ in range(20):
                assert b.completion(2) == expected and b.get("o_c_valid") & accepted
                assert b.get("live") & b.get("ld_prefetch_q") == accepted
                assert len(b.requests) == 3
                if kind == 2 or error:
                    assert not b.get("rd_ready_q") & 4
                await b.tick()
            await b.accept_completion(2)
            await b.tick(12)
            assert b.get("live") & b.get("ld_prefetch_q") == accepted
            assert not b.get("o_c_valid") & accepted
            if kind == 1 and not error:
                assert b.get("o_read_valid") and b.get("o_read_id") == 2
                assert b.get("o_read_data") == b.word(base + 64)
                assert not b.get("o_read_error")
            else:
                assert not b.get("o_read_valid")
            for index in range(2):
                await b.grant(index)
                await b.release(index)
            await b.tick(12)
            assert len(b.requests) == 3
            await b.release(2)
            if kind == 2:
                await b.requests_at_least(4)
                assert b.requests[3][0] == 0 and b.requests[3][1][0] == 3
                await b.set(i_read_ready=1)
                await b.tick(10)
                await b.set(i_read_ready=0)
                await b.finish_atomic(3)
            await b.drain(3)
            assert sorted(b.responses) == [
                (slot, b.word(base + 32 * slot), 0) for slot in range(3)
            ]
            if kind == 1 and error:
                assert b.requests[3][0] == 0 and b.requests[3][1][0] == 2
            assert not b.get("o_fatal")


@cocotb.test()
async def endpoint_zero_bypasses_unused_credit(dut: Any) -> None:
    """Accept a buffered store grant ahead of an unused ordinary-read opportunity."""
    b = StreamPrivate(dut)
    if b.endpoints < 3:
        return
    await b.reset()
    base = 0x80003000
    await b.issue(0, base)
    await b.issue(1, base + 512)
    await b.issue(2, base + 8)
    await b.requests_at_least(2)
    await b.tick(40)
    await b.set(i_address=base + 1024, i_write_mask=255, i_write_data=123)
    await b.tick()
    await b.set(i_write_mask=0)
    await b.requests_at_least(3)
    assert b.requests[2][0] == 0 and b.requests[2][1][0] == 1
    for index in range(3):
        await b.send_grant(index)
    for _ in range(100):
        if b.get("phase_q") == 0 and b.get("grant_read_turn_q"):
            break
        await b.tick()
    else:
        raise AssertionError("No credit beside the buffered endpoint-zero grant")
    assert b.get("ep_grant_valid") & 1 and b.get("grant_pick") == 0
    assert b.get("grant_ready") and not b.get("grant_read_hold")
    await b.tick()
    assert b.get("operation_q") == 2 and b.get("grant_ep_q") == 0
    assert not b.get("grant_read_turn_q")
    await b.tick(40)
    for index in range(3):
        await b.release(index)
    await b.drain(3)
    assert sorted(b.responses) == [
        (0, b.word(base), 0),
        (1, b.word(base + 512), 0),
        (2, b.word(base + 8), 0),
    ]
    assert not b.get("o_pending_store") and not b.get("o_fatal")


@cocotb.test()
async def miss_of_a_set_keeps_a_fill_from_the_next_fill(dut: Any) -> None:
    """Update replacement state for a fill with a waiting read or a same-set miss."""
    b = StreamPrivate(dut)
    if b.endpoints < 3:
        return
    await b.reset()
    # The bench's 512-byte cache has 128-byte ways. The set's four ways hold
    # valid sectors, so replacement state picks each victim from here on.
    way_bytes = 128
    base = 0x80005000
    for way in range(4):
        await b.issue(0, base + way * way_bytes)
        await b.drain(way + 1)
    await b.set(i_read_ready=0)
    b.install_touches.clear()

    async def fill(index: int) -> None:
        await b.grant(index)
        await b.release(index)

    async def responded(count: int) -> None:
        for _ in range(60):
            if len(b.responses) == count:
                return
            await b.tick()
        raise AssertionError(f"Only {len(b.responses)} CPU responses, expected {count}")

    async def resident(slot: int, address: int) -> bool:
        """Read an address, finish any miss, and report whether it hit."""
        before = len(b.requests)
        count = len(b.responses) + 1
        await b.issue(slot, address)
        await b.set(i_read_ready=1)
        for _ in range(60):
            if len(b.responses) == count or len(b.requests) > before:
                break
            await b.tick()
        hit = len(b.requests) == before
        if not hit:
            await fill(before)
        await responded(count)
        await b.set(i_read_ready=0)
        return hit

    # Two misses of one set are in flight together: the first fill updates
    # replacement state and keeps its sector from the second fill. Nothing
    # is left in flight behind the second fill.
    first = base + 4 * way_bytes
    second = base + 5 * way_bytes
    await b.issue(1, first)
    await b.issue(2, second)
    await b.requests_at_least(6)
    await fill(4)
    await fill(5)
    await b.set(i_read_ready=1)
    await responded(6)
    await b.set(i_read_ready=0)
    assert b.install_touches == [1, 0]
    assert await resident(3, first + 8)
    assert await resident(3, second + 8)

    # One read at a time, no fill has a waiting read or a miss beside it.
    b.install_touches.clear()
    assert not await resident(4, base + 6 * way_bytes)
    assert not await resident(5, base + 7 * way_bytes)
    assert b.install_touches == [0, 0]

    # A read attached to the fill's endpoint updates replacement state too.
    b.install_touches.clear()
    third = base + 8 * way_bytes
    count = len(b.responses) + 2
    await b.issue(6, third)
    await b.issue(7, third + 8)
    await b.requests_at_least(len(b.requests) + 1)
    for _ in range(40):
        if b.get("rd_wait_q") >> 7 & 1:
            break
        await b.tick()
    else:
        raise AssertionError("The second read did not attach to the endpoint")
    await fill(len(b.requests) - 1)
    await b.set(i_read_ready=1)
    await responded(count)
    await b.set(i_read_ready=0)
    assert sorted(b.responses[-2:]) == [
        (6, b.word(third), 0),
        (7, b.word(third + 8), 0),
    ]
    assert b.install_touches == [1]
    assert not b.get("o_fatal")


@cocotb.test()
async def answered_read_id_reuse_during_installation(dut: Any) -> None:
    """Reuse an answered read ID while its grant installs over a clean or dirty victim."""
    b = StreamPrivate(dut)
    if b.endpoints < 2:
        return
    ways = len(dut.exclude)
    for dirty, same_line in (
        (False, False),
        (False, True),
        (True, False),
        (True, True),
    ):
        await b.reset()
        base = 0x80006000
        # Modified lines fill the set, so the load's installation freezes one.
        for way in range(ways if dirty else 0):
            await b.wait("o_store_ready")
            await b.set(
                i_address=base + 0x200 * (way + 1),
                i_write_mask=255,
                i_write_data=0x1111 * (way + 1),
            )
            await b.tick()
            await b.set(i_write_mask=0)
            await b.requests_at_least(way + 1)
            await b.grant(way)
            await b.release(way)
        first = len(b.requests)
        await b.issue(0, base)
        await b.requests_at_least(first + 1)
        ep = b.requests[first][0]
        assert ep != 0
        await b.set(i_read_ready=1)
        await b.send_grant(first)
        for _ in range(40):
            if b.responses:
                break
            await b.tick()
        else:
            raise AssertionError("The grant did not answer its read")
        # The grant owns the array service when its read is answered.
        assert b.get("operation_q") == 2 and b.get("phase_q") != 0
        assert not b.get("installed_q") >> ep & 1
        second = base + 8 if same_line else base + 0x1000
        await b.issue(0, second)
        for _ in range(60):
            if b.get("installed_q") >> ep & 1:
                break
            assert b.get("rd_valid_q") & 1 and not b.get("rd_ready_q") & 1
            await b.tick()
        else:
            raise AssertionError("The answered grant did not install")
        # The installation completes no read: slot 0 holds the second read.
        assert b.get("rd_valid_q") & 1 and not b.get("rd_ready_q") & 1
        if dirty:
            await b.wait("o_w_valid")
            put = unpack(b.get("o_w"), (1, 1, 1, b.p, 256, 1))
            way = (put[3] - base) // 0x200 - 1
            assert put[3] == base + 0x200 * (way + 1) and way in range(ways)
            # The frozen victim holds its store over the grant that filled it.
            assert put[4] == (0x1111 * (way + 1)) | sum(
                b.word(put[3] + 8 * word) << (64 * word) for word in range(1, 4)
            )
        for _ in range(100):
            if b.get("o_c_valid") >> ep & 1:
                break
            await b.tick()
        else:
            raise AssertionError("The answered endpoint offered no completion")
        await b.release(first)
        await b.drain(2)
        assert b.responses == [(0, b.word(base), 0), (0, b.word(second), 0)]
        assert len(b.requests) == first + (1 if same_line else 2)
        assert not b.get("o_fatal")


@cocotb.test()
async def attached_sizes_and_offsets(dut: Any) -> None:
    """Select each attached load's dword for every aligned size and sector offset."""
    b = StreamPrivate(dut)
    if b.endpoints < 2:
        return
    cases = [(size, offset) for size in range(4) for offset in range(0, 32, 1 << size)]
    for first in range(0, len(cases), 7):
        await b.reset()
        base = 0x80006000 + first * 256
        await b.issue(0, base)
        await b.requests_at_least(1)
        batch = cases[first : first + 7]
        for slot, (size, offset) in enumerate(batch, 1):
            await b.issue(slot, base + offset, size=size)
        await b.tick(25)
        mask = ((1 << (len(batch) + 1)) - 1) & ~1
        assert b.get("rd_wait_q") & mask == mask
        await b.drain(len(batch) + 1)
        assert sorted(b.responses) == [(0, b.word(base), 0)] + [
            (slot, b.word((base + offset) & ~7), 0)
            for slot, (_, offset) in enumerate(batch, 1)
        ]
        assert len(b.requests) == 1


@cocotb.test()
async def attached_answers_bound_a_ready_hit(dut: Any) -> None:
    """Serve a ready hit within seven competing transfers, including reused IDs."""
    b = StreamPrivate(dut)
    if b.endpoints < 2:
        return
    for stalled in (False, True):
        await b.reset()
        resident, missing = 0x80004000, 0x80004080
        await b.issue(7, resident)
        await b.drain(1)
        await b.tick(10)
        b.requests.clear()
        b.responses.clear()
        b.completed.clear()
        b.completion_accepted.clear()
        await b.set(i_read_ready=0)
        await b.issue(0, missing)
        await b.requests_at_least(1)
        for slot in range(1, 7):
            await b.issue(slot, missing + 8 * (slot % 4))
        await b.tick(25)
        assert b.get("rd_wait_q") & 0x7E == 0x7E
        await b.send_grant(0)
        await b.issue(7, resident + 8)
        take = hit = None
        for _ in range(80):
            if b.get("path_take") and b.get("path_id_q") == 7:
                take = b.cycles
            if b.get("s4_valid_q") and b.get("s4_slot_q") == 7:
                hit = b.cycles
            if b.get("rd_ready_q") & 128:
                break
            await b.tick()
        else:
            raise AssertionError("Unrelated hit did not become ready")
        assert take is not None and hit == take + 3
        await b.tick(17 if stalled else 0)
        ahead = []
        reuse = None
        for cycle in range(160):
            await b.set(
                i_read_ready=int(not stalled or cycle % 3 == 0),
                i_read_valid=int(reuse is not None),
                i_read_id=reuse if reuse is not None else 0,
                i_address=resident + 16,
                i_read_kind=0,
                i_read_size=3,
            )
            accepted = b.get("o_read_valid") and b.get("i_read_ready")
            slot = b.get("o_read_id") if accepted else -1
            if accepted and slot == 7:
                assert b.get("o_read_data") == b.word(resident + 8)
                assert not b.get("o_read_error")
                break
            if accepted:
                ahead.append(slot)
                assert len(ahead) <= 7
                assert b.get("o_read_data") == b.word(missing + 8 * (slot % 4))
                assert not b.get("o_read_error")
            await b.tick()
            # Reuse on the next edge, while observing every response transfer.
            reuse = slot if accepted else None
        else:
            raise AssertionError("Competing responses starved a ready hit")
        assert ahead == list(range(7)), ahead
        dut._log.info(
            "ready hit: %d competing transfers, stalled=%s", len(ahead), stalled
        )


@cocotb.test()
async def stores_between_request_and_attached_load(dut: Any) -> None:
    """Order byte stores on either side of a load beside an outstanding sector request."""
    b = StreamPrivate(dut)
    if b.endpoints < 3:
        return
    base = 0x80006000
    stored = 0xFEDCBA9876543210
    for store_first in (False, True):
        for size in range(4):
            for offset in range(0, 8, 1 << size):
                await b.reset()
                await b.set(i_read_ready=1)
                await b.issue(0, base)
                await b.requests_at_least(1)
                if not store_first:
                    await b.issue(1, base + 8 + offset, size=size)
                    await b.tick(25)
                    assert b.get("rd_wait_q") & 2
                mask = ((1 << (1 << size)) - 1) << offset
                await b.wait("o_store_ready")
                await b.set(i_address=base + 8, i_write_mask=mask, i_write_data=stored)
                await b.tick()
                await b.set(i_write_mask=0)
                if store_first:
                    await b.issue(1, base + 8 + offset, size=size)
                    await b.tick(25)
                    assert not b.get("rd_wait_q") & 2
                    assert not any(slot == 1 for slot, _, _ in b.responses)
                await b.grant(0)
                await b.release(0)
                await b.requests_at_least(2)
                assert b.requests[1][1][0] == 1
                await b.grant(1)
                await b.release(1)
                await b.tick(60)
                byte_mask = sum(
                    255 << (8 * lane) for lane in range(8) if mask >> lane & 1
                )
                merged = (b.word(base + 8) & ~byte_mask) | (stored & byte_mask)
                expected = merged if store_first else b.word(base + 8)
                assert sorted(b.responses) == [(0, b.word(base), 0), (1, expected, 0)]
                await b.issue(2, base + 8 + offset, size=size)
                await b.tick(40)
                assert b.responses[-1] == (2, merged, 0)


@cocotb.test()
async def attached_grant_beside_probe(dut: Any) -> None:
    """Serialize probe service and attached grant answers at each arrival skew."""
    b = StreamPrivate(dut)
    if b.endpoints < 2:
        return
    base = 0x80007000
    for opcode in (0, 1):
        for skew in range(-3, 4):
            await b.reset()
            await b.set(i_cut_admit_ready=1, i_cut_admit_clean=1, i_cut_inval_done=1)
            await b.issue(0, base)
            await b.requests_at_least(1)
            await b.issue(1, base + 8)
            await b.issue(2, base + 24, size=0)
            await b.tick(25)
            assert b.get("rd_wait_q") & 6 == 6
            probe = pack(
                (2, opcode),
                (6, 17),
                (1, 0),
                (b.p, base),
                (2, 2),
                (2, 0),
                (9, 0),
                (5, 0),
                (3, 3),
            )
            if skew < 0:
                await b.set(i_p_valid=1, i_p=probe)
                await b.wait("o_p_ready")
                await b.tick()
                await b.set(i_p_valid=0)
                await b.tick(-skew)
                await b.send_grant(0)
            else:
                await b.send_grant(0)
                await b.tick(skew)
                await b.set(i_p_valid=1, i_p=probe)
                await b.wait("o_p_ready")
                await b.tick()
                await b.set(i_p_valid=0)
            await b.wait("o_r_valid")
            await b.tick(5)
            await b.set(i_r_ready=1)
            await b.tick()
            await b.set(i_r_ready=0)
            ep = b.requests[0][0]
            for _ in range(100):
                if b.get("o_c_valid") >> ep & 1:
                    break
                await b.tick()
            else:
                raise AssertionError("Grant did not finish beside the probe")
            await b.release(0)
            await b.set(i_read_ready=1)
            await b.tick(40)
            assert sorted(b.responses) == [
                (0, b.word(base), 0),
                (1, b.word(base + 8), 0),
                (2, b.word(base + 24), 0),
            ]
            assert not b.get("o_fatal")


@cocotb.test()
async def attached_loads_retry_after_demand_error(dut: Any) -> None:
    """Return an owner's error once and let attached loads acquire their own result."""
    b = StreamPrivate(dut)
    if b.endpoints < 2:
        return
    await b.reset()
    base = 0x80007800
    await b.set(i_read_ready=1)
    await b.issue(0, base)
    await b.requests_at_least(1)
    await b.issue(1, base + 8, size=1)
    await b.issue(2, base + 16, size=2)
    await b.tick(25)
    assert b.get("rd_wait_q") & 6 == 6
    await b.grant(0, error=True)
    await b.tick(30)
    assert b.responses == [(0, 0, 1)]
    assert len(b.requests) == 1
    await b.release(0)
    await b.drain(3)
    assert sorted(b.responses) == [
        (0, 0, 1),
        (1, b.word(base + 8), 0),
        (2, b.word(base + 16), 0),
    ]
    assert len(b.requests) == 2
    assert not b.get("o_fatal")


@cocotb.test()
async def attached_answers_from_consecutive_grants(dut: Any) -> None:
    """Keep two sectors' attached answers distinct while their grants overlap."""
    if len(dut.o_d_valid) < 3:
        return
    for wait_for_answers in (False, True):
        b = AttachedMemory(dut)
        await b.reset()
        first, second = 0x80008000, 0x80008100
        await b.issue(0, first)
        await b.issue(1, second)
        await b.requests_at_least(2)
        assert b.requests[0][0] != b.requests[1][0]
        for slot, address in (
            (2, first + 8),
            (3, first + 24),
            (4, second),
            (5, second + 16),
        ):
            await b.issue(slot, address)
        await b.attached(0x0C, b.requests[0][0], merged=False)
        await b.attached(0x30, b.requests[1][0], merged=False)
        await b.send_grant(0)
        first_cycle = b.cycles
        if wait_for_answers:
            await b.wait("o_read_valid")
            ready = b.get("rd_ready_q") | (1 << b.get("o_read_id"))
            assert ready & 0x0D == 0x0D and not b.responses
        await b.send_grant(1)
        if not wait_for_answers:
            assert b.cycles == first_cycle + 1
        await b.complete(0)
        await b.complete(1)
        await b.tick(17)
        assert not b.responses and b.grant_answers & 0x3F == 0x3F
        await b.checked()
        assert len(b.responses) == 6 and len(b.requests) == 2


@cocotb.test()
async def attached_loads_replay_after_endpoint_zero_lr(dut: Any) -> None:
    """Merge loads onto an LR acquisition and answer them by lookup after installation."""
    b = AttachedMemory(dut)
    if b.endpoints < 2:
        return
    await b.reset()
    base = 0x80009000
    await b.issue(0, base, kind=1)
    await b.requests_at_least(1)
    assert b.requests[0][0] == 0 and b.requests[0][1][0] == 2
    for slot in range(1, 4):
        await b.issue(slot, base + 8 * slot)
    await b.attached(0x0E, 0)
    await b.send_grant(0)
    await b.complete(0)
    await b.checked()
    assert len(b.responses) == 4 and len(b.requests) == 1
    assert not b.grant_answers and b.replay_answers & 0x0E == 0x0E


@cocotb.test()
async def attached_loads_replay_after_store_release(dut: Any) -> None:
    """Replay loads behind endpoint-zero and borrowed store acquisitions after a cut."""
    if len(dut.o_d_valid) < 2:
        return
    for borrowed in (False, True):
        b = AttachedMemory(dut)
        if borrowed and b.endpoints < 3:
            continue
        await b.reset()
        base, head = 0x8000A000, 0x8000A040
        # These older reads snapshot the original bytes before the store exists.
        await b.issue(6, base + 8)
        await b.requests_at_least(1)
        await b.issue(7, base + 24)
        await b.attached(0x80, b.requests[0][0], merged=False)
        await b.send_grant(0)
        await b.complete(0)
        await b.checked()
        await b.set(i_read_ready=0)
        first_store = len(b.requests)
        if borrowed:
            await b.store(head, 0x1020304050607080)
            await b.requests_at_least(first_store + 1)
        await b.store(base + 8, 0xFEDCBA9876543210, mask=0x3C)
        target = first_store + int(borrowed)
        await b.requests_at_least(target + 1)
        ep, request = b.requests[target]
        assert request[0] == 1 and request[2] == base
        assert (ep != 0) == borrowed
        if borrowed:
            assert b.get("ld_store_q") >> ep & 1
        # Store holders exclude pre-installation lookup and merge attachment.
        await b.issue(0, base + 8)
        await b.issue(1, base + 24)
        await b.tick(24)
        assert b.get("rd_valid_q") & 3 == 3 and not b.get("rd_wait_q") & 3
        assert not b.get("rd_ready_q") & 3 and not b.grant_answers & 3
        await b.send_grant(target)
        if borrowed:
            await b.tick(12)
            assert not b.get("o_c_valid") >> ep & 1
            await b.send_grant(first_store)
            await b.complete(first_store)
        for _ in range(200):
            if b.get("o_c_valid") >> ep & 1:
                break
            await b.tick()
        assert b.get("o_c_valid") >> ep & 1
        await b.checked()
        assert not b.grant_answers & 3
        # C may reach the home before U returns. A cut in that interval removes
        # the installed line, leaving later misses attached until release.
        await b.accept_completion(target)
        await b.set(i_read_ready=0)
        reply = await b.invalidate(base)
        assert reply[7] and reply[8] == b.image(base, 32)
        b.write(base, reply[8], 0xFFFFFFFF, home=True)
        for slot in range(2, 5):
            await b.issue(slot, base + 8 * (slot - 1))
        await b.attached(0x1C, ep)
        assert b.get("rd_wait_release_q") & 0x1C == 0x1C
        assert not b.get("rd_ready_q") & 0x1C and not b.grant_answers & 0x1C
        before = len(b.requests)
        await b.tick(17)
        assert len(b.requests) == before and not b.get("o_read_valid")
        await b.release(target)
        await b.requests_at_least(before + 1)
        assert b.requests[before][1][0] == 0 and b.requests[before][1][2] == base
        await b.send_grant(before)
        await b.complete(before)
        await b.checked()
        assert len(b.responses) == 7 and len(b.requests) == before + 1


@cocotb.test()
async def speculative_grant_answers_attached_loads(dut: Any) -> None:
    """Answer several merged loads directly from a successful speculative grant."""
    b = AttachedMemory(dut)
    if b.endpoints < 4:
        return
    await b.reset()
    base = 0x8000B020
    await b.seed_before(base)
    await b.issue(0, base)
    await b.issue(1, base + 32)
    await b.requests_at_least(3)
    target = next(
        i for i, (_, request) in enumerate(b.requests) if request[2] == base + 64
    )
    ep = b.requests[target][0]
    assert b.get("ld_prefetch_q") >> ep & 1
    for slot in range(2, 6):
        await b.issue(slot, base + 64 + 8 * (slot - 2))
    await b.attached(0x3C, ep)
    await b.send_grant(target)
    await b.complete(target)
    assert b.grant_answers & 0x3C == 0x3C and not b.responses
    for index in range(2):
        await b.send_grant(index)
        await b.complete(index)
    await b.checked()
    assert len(b.responses) == 6
    assert sum(request[2] == base + 64 for _, request in b.requests) == 1


@cocotb.test()
async def atomic_admission_with_attached_loads(dut: Any) -> None:
    """Keep older attached values before an admitted AMO or successful or failed SC."""
    if len(dut.o_d_valid) < 2:
        return
    for operation in ("amo", "sc", "failed_sc"):
        b = AttachedMemory(dut)
        await b.reset()
        base, address = 0x8000C000, 0x8000C008
        await b.issue(0, base)
        await b.requests_at_least(1)
        for slot in range(1, 4):
            await b.issue(slot, base + 8 * slot)
        await b.attached(0x0E, b.requests[0][0])
        sc = operation != "amo"
        success = operation != "failed_sc"
        if sc:
            await b.set(
                i_sc_valid=1,
                i_sc_address=address,
                i_sc_size=3,
                i_sc_tag=0,
                i_reservation_valid=int(success),
                i_reservation_addr=address,
                i_reservation_size=3,
            )
            await b.wait("o_sc_ready")
            assert b.get("rd_wait_q") & 0x0E == 0x0E
            await b.tick()
            await b.set(i_sc_valid=0)
        else:
            await b.issue(4, address, kind=2)
            assert b.get("rd_wait_q") & 0x0E == 0x0E
        await b.send_grant(0)
        await b.complete(0)
        await b.set(i_read_ready=1)
        await b.requests_at_least(2)
        ep, request = b.requests[1]
        assert ep == 0 and request[0] == (4 if sc else 3)
        for _ in range(80):
            if len(b.responses) == 4:
                break
            await b.tick()
        assert [slot for slot, _, _ in b.responses] == [0, 1, 2, 3]
        if sc:
            await b.probe(
                base, opcode=2, check_q=request[1], tid=ep, requester=request[1] >> 7
            )
            reply = unpack(b.get("o_r"), (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
            assert reply[0] == 2 and reply[12] == success and not reply[13]
            await b.set(i_r_ready=1)
            await b.tick()
            await b.set(i_r_ready=0)
            if success:
                await b.probe(base, tid=ep, requester=request[1] >> 7)
                await b.set(i_r_ready=1)
                await b.tick()
                await b.set(i_r_ready=0)
        await b.send_grant(1, opcode=2 if success else 5)
        if sc:
            await b.wait("o_sc_result_valid")
            assert b.get("o_sc_success") == success and not b.get("o_sc_error")
            await b.set(i_sc_result_ready=1)
            await b.tick()
            await b.set(i_sc_result_ready=0)
            if success:
                await b.set(i_sc_commit=1)
                await b.tick()
                await b.set(i_sc_commit=0)
        else:
            for _ in range(80):
                if 4 not in b.expected:
                    break
                await b.tick()
            assert 4 not in b.expected and b.responses[-1][0] == 4
        if success:
            updated = (b.image(address, 8) + 0x12345) & ((1 << 64) - 1)
            b.write(address, updated, 255)
            await b.set(
                i_address=address,
                i_write_mask=255,
                i_write_data=updated,
                i_write_atomic=1,
                i_write_sc=int(sc),
                i_write_tag=0,
            )
            await b.tick()
            await b.set(i_write_mask=0)
        await b.complete(1)
        await b.set(i_write_atomic=0, i_write_sc=0)
        await b.issue(5, address)
        await b.issue(6, base + 24)
        await b.checked()
        assert len(b.responses) == (6 if sc else 7)
        assert b.sc_results == ([(int(success), 0)] if sc else [])
        assert not b.get("o_atomic_live") and not b.get("o_sc_write_pending")


async def discard_attached_on_reset(dut: Any, *, fatal: bool) -> None:
    """Discard an attached generation and reuse its IDs with distinct home data."""
    b = AttachedMemory(dut)
    if b.endpoints < 2:
        return
    await b.reset()
    base = 0x8000D000
    await b.issue(0, base)
    await b.requests_at_least(1)
    for slot in range(1, 4):
        await b.issue(slot, base + 8 * slot)
    await b.attached(0x0E, b.requests[0][0])
    if fatal:
        await b.set(i_fatal_stop=1)
        await b.tick()
        assert not b.get("active")
        await b.send_grant(0)
        await b.tick(24)
        assert not b.get("o_read_valid") and not b.responses
        assert not b.get("o_c_valid") and b.get("rd_wait_q") & 0x0E == 0x0E
    # Fatal stop is held until reset; lowering it alone is not a recovery protocol.
    await b.reset()
    await b.set(i_read_ready=1)
    await b.tick(24)
    assert not b.responses and not b.get("o_read_valid")
    assert not b.get("rd_wait_q") and not b.get("rd_valid_q") and not b.get("live")
    replacement = int.from_bytes(bytes(range(32, 64)), "little")
    b.write(base, replacement, 0xFFFFFFFF)
    b.write(base, replacement, 0xFFFFFFFF, home=True)
    await b.set(i_read_ready=0)
    await b.issue(0, base)
    await b.requests_at_least(1)
    for slot in range(1, 4):
        await b.issue(slot, base + 8 * slot)
    await b.attached(0x0E, b.requests[0][0])
    await b.send_grant(0)
    await b.complete(0)
    await b.checked()
    assert len(b.responses) == 4 and len(b.requests) == 1


@cocotb.test()
async def reset_discards_attached_loads(dut: Any) -> None:
    """Reset before a grant kills attached slots and permits fresh same-sector reads."""
    await discard_attached_on_reset(dut, fatal=False)


@cocotb.test()
async def fatal_stop_holds_attached_loads_until_reset(dut: Any) -> None:
    """Hold an arriving grant during fatal stop and discard it on reset."""
    await discard_attached_on_reset(dut, fatal=True)


@cocotb.test()
async def invalidation_preserves_held_attached_answers(dut: Any) -> None:
    """Keep grant values through a later cut while a fresh load reacquires new bytes."""
    b = AttachedMemory(dut)
    if b.endpoints < 2:
        return
    await b.reset()
    base = 0x8000E000
    await b.issue(0, base)
    await b.requests_at_least(1)
    for slot in range(1, 4):
        await b.issue(slot, base + 8 * slot)
    await b.attached(0x0E, b.requests[0][0])
    await b.send_grant(0)
    await b.complete(0)
    assert b.grant_answers & 15 == 15 and not b.responses
    held = (b.get("o_read_id"), b.get("o_read_data"), b.get("o_read_error"))
    await b.invalidate(base)
    assert b.get("o_read_valid") and held == (
        b.get("o_read_id"),
        b.get("o_read_data"),
        b.get("o_read_error"),
    )
    replacement = int.from_bytes(bytes(range(64, 96)), "little")
    b.write(base, replacement, 0xFFFFFFFF)
    b.write(base, replacement, 0xFFFFFFFF, home=True)
    await b.issue(4, base + 8)
    await b.requests_at_least(2)
    assert b.requests[1][1][2] == base and not b.responses
    await b.send_grant(1)
    await b.complete(1)
    await b.checked()
    assert len(b.responses) == 5 and len(b.requests) == 2

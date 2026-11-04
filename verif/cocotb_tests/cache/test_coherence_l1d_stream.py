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

    async def tick(self, count: int = 1) -> None:
        """Record handshakes before each active edge."""
        for _ in range(count):
            if not self.get("i_rst"):
                if (
                    self.get("phase_q") == 2
                    and self.get("array_valid")
                    and self.get("operation_q") == 6
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

    async def issue(self, slot: int, address: int, kind: int = 0) -> None:
        """Present one independent CPU read."""
        await self.set(
            i_read_valid=1,
            i_read_id=slot,
            i_address=address,
            i_read_kind=kind,
            i_read_size=3,
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
                selected = b.get("operation_q") == 6
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
            if stage == 4:
                assert not b.get("ep_request_valid")
            await b.tick()
            await b.set(i_read_valid=0)
            if cancel in ("lr", "amo"):
                assert b.get("rd_valid_q") & 4 and b.get("atomic_read_waiting")
                assert b.get("prefetch_cancel")
            await b.tick()
            assert not b.get("hint_valid_q") and not b.get("hint_checked_q")
            assert not b.get("stream_confirmed")
            await b.tick(11)
            assert not b.get("live") & b.get("ld_prefetch_q")


@cocotb.test()
async def live_conflicts_on_hint_acceptance(dut: Any) -> None:
    """Block a selected hint on a matching store or probe at its acceptance edge."""
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
            if b.get("operation_q") == 6 and b.get("phase_q") == 3:
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
        else:
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
        await b.set(i_write_mask=0)
        assert not b.get("live") & selected
        assert not b.get("ld_prefetch_q") and len(b.requests) == 2
        if conflict == "probe":
            await b.wait("o_p_ready")
            await b.tick()
            await b.set(i_p_valid=0)
        assert b.get("pending_q" if conflict == "store" else "probe_valid_q")
        assert not b.get("o_fatal")


@cocotb.test()
async def accepted_hints_drain_for_exclusive_work(dut: Any) -> None:
    """Keep speculative ownership through delayed U while AMO, SC and maintenance wait."""
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
            await b.set(i_sc_valid=1, i_sc_address=0x80001080, i_sc_size=3, i_sc_tag=7)
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
        assert (
            len(b.requests) == 4
            and not b.get("o_sc_ready")
            and not b.get("o_maint_done")
        )
        if waiting == "lr":
            assert (2, b.word(0x80001060), 0) in b.responses
        await b.release(2)
        await b.tick(20)
        assert (
            len(b.requests) == 4
            and not b.get("o_sc_ready")
            and not b.get("o_maint_done")
        )
        await b.release(3)
        if waiting == "amo":
            await b.requests_at_least(5)
            assert b.requests[4][0] == 0 and b.requests[4][1][0] == 3
            await b.set(i_read_ready=0)
            await b.finish_atomic(4)
        elif waiting == "sc":
            await b.requests_at_least(5)
            assert b.requests[4][0] == 0 and b.requests[4][1][0] == 4
            await b.set(i_sc_valid=0)
            await b.finish_atomic(4, sc=True)
        elif waiting == "maintenance":
            await b.wait("o_maint_done")
        else:
            await b.tick(20)
            assert not b.get("live") and len(b.requests) == 4


@cocotb.test()
async def demand_turn_between_buffered_grants(dut: Any) -> None:
    """Serve a fill waiter before accepting the next successful or failed grant."""
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
        for _ in range(100):
            if b.get("phase_q") == 0 and b.get("grant_read_yield"):
                assert b.get("grant_pick") == b.requests[1][0]
                assert not b.get("grant_ready") and not b.get("read_failure")
                assert not b.get("rd_ready_q") & 2
                await b.tick()
                assert b.get("operation_q") == 0 and b.get("selected_read_q") == 2
                break
            await b.tick()
        else:
            raise AssertionError("No demand turn between the buffered grants")
        for _ in range(100):
            if b.get("phase_q") == 0 and b.get("grant_valid") and b.get("grant_ready"):
                assert not b.get("grant_read_turn_q")
                assert b.get("rd_ready_q") & 4
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
        await b.drain(3)
        assert sorted(b.responses) == [
            (0, b.word(base), 0),
            (1, 0 if error else b.word(base + 512), int(error)),
            (2, b.word(base + 8), 0),
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
                assert not b.get("rd_ready_q") & 4
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
                if b.get("operation_q") == 6 and b.get("phase_q") == 3:
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

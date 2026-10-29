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

"""Delayed home peer for the connected AXI bridge and DMA ingress."""

from dataclasses import dataclass
from typing import Any
import random

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly

from cocotb_tests.axi.axi_models import LineIngress
from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack


@dataclass
class HomeRequest:
    """One admitted home identity with a held result and release."""

    opcode: int
    q: int
    tid: int
    address: int
    mask: int
    value: int
    order: int
    phase: str = "queued"
    due: int = 0
    data: int = 0
    error: int = 0


class CoherentHome(LineIngress):
    """Check line ownership while servicing the ingress's coherent channels."""

    def __init__(
        self,
        dut: Any,
        clk: Any,
        mem: dict[int, int],
        region: tuple[int, int],
        rng: random.Random,
        ready_bias: float = 0.7,
        max_latency: int = 12,
    ) -> None:
        """Start independent home peers with ordered same-sector execution."""
        self._dut, self._clk = dut, clk
        self.mem, self.region, self.rng = mem, region, rng
        self.ready_bias, self.max_latency = ready_bias, max_latency
        self.error_lines: set[int] = set()
        self.log: list[tuple[int, bool, int, int, int]] = []
        self.violations: list[str] = []
        self.outstanding: dict[int, int] = {}
        self.accepted: dict[int, tuple[int, int, int, int]] = {}
        self.released: dict[int, tuple[int, int, int]] = {}
        self.cycle = self.max_occupied = self.completions = 0
        self.pending: dict[int, HomeRequest] = {}
        self.grant_order: list[int] = []
        self.release_order: list[int] = []
        self.max_active = 0
        self.phase = "d"
        self.pause: str | None = None
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self._dut
        width = len(dut.o_line_req_addr)
        grant_slot: int | None = None
        release_slot: int | None = None
        tid = order = 0
        while True:
            await FallingEdge(self._clk)
            self.cycle += 1
            reset = int(dut.i_rst.value)
            if grant_slot is None and self.pause != "g":
                ready = [
                    rid
                    for rid, req in self.pending.items()
                    if req.phase == "g" and req.due <= self.cycle
                ]
                if ready:
                    grant_slot = self.rng.choice(ready)
            if release_slot is None and self.pause != "u":
                ready = [
                    rid
                    for rid, req in self.pending.items()
                    if req.phase == "u" and req.due <= self.cycle
                ]
                if ready:
                    release_slot = self.rng.choice(ready)
            dut.i_d_ready.value = int(
                not reset
                and self.pause != "d"
                and len(self.pending) < 4
                and self.rng.random() < self.ready_bias
            )
            dut.i_c_ready.value = int(
                not reset and self.pause != "c" and self.rng.random() < self.ready_bias
            )
            dut.i_g_valid.value = int(not reset and grant_slot is not None)
            dut.i_g.value = 0
            if grant_slot is not None:
                req = self.pending[grant_slot]
                dut.i_g.value = pack(
                    (3, 3 if req.opcode == 7 else 4),
                    (9, req.q),
                    (6, req.tid),
                    (width, req.address),
                    (256, req.data),
                    (1, req.error),
                )
            dut.i_u_valid.value = int(not reset and release_slot is not None)
            dut.i_u.value = 0
            if release_slot is not None:
                req = self.pending[release_slot]
                dut.i_u.value = pack((9, req.q), (6, req.tid), (width, req.address))
            await ReadOnly()
            if reset:
                self.phase = "d"
                self.outstanding.clear()
                self.accepted.clear()
                self.released.clear()
                self.pending.clear()
                grant_slot = release_slot = None
                continue
            if int(dut.i_line_resp_valid.value):
                rid = int(dut.i_line_resp_id.value)
                assert rid in self.released, "external response preceded Release"
                value, fault, released_at = self.released.pop(rid)
                assert self.cycle > released_at
                assert int(dut.i_line_resp_rdata.value) == value
                assert int(dut.i_line_resp_error.value) == fault
                del self.outstanding[rid]
                del self.accepted[rid]
                del self.pending[rid]
                self.completions += 1
            if int(dut.o_line_req_valid.value) and int(dut.i_line_req_ready.value):
                rid = int(dut.o_line_req_id.value)
                address = int(dut.o_line_req_addr.value)
                write = int(dut.o_line_req_write.value)
                mask = int(dut.o_line_req_wstrb.value)
                payload = int(dut.o_line_req_wdata.value)
                assert rid not in self.outstanding
                assert address % 32 == 0
                assert self.region[0] <= address < sum(self.region)
                assert not write or mask
                self.outstanding[rid] = address
                self.accepted[rid] = (write, address, mask, payload)
                self.log.append(
                    (self.cycle, bool(write), address, mask if write else 0, rid)
                )
                self.max_occupied = max(self.max_occupied, len(self.outstanding))
                assert len(self.outstanding) <= 4
            if int(dut.o_d_valid.value) and int(dut.i_d_ready.value):
                op, q, addr, offset, size, mask, aq, rl, maintenance, value = unpack(
                    int(dut.o_d.value), (4, 9, width, 5, 3, 32, 1, 1, 1, 256)
                )
                rid = (q >> 1) & 15
                assert q >> 5 == 0b1011 and q & 1 == 0 and rid not in self.pending
                assert self.accepted[rid] == (int(op == 8), addr, mask, value)
                assert (
                    op in (7, 8)
                    and size == 5
                    and not (aq or rl or offset or maintenance)
                )
                live_tids = {
                    req.tid for req in self.pending.values() if req.phase != "released"
                }
                tid = next(
                    (tid + step) % 19
                    for step in range(1, 20)
                    if (tid + step) % 19 not in live_tids
                )
                self.pending[rid] = HomeRequest(op, q, tid, addr, mask, value, order)
                order += 1
                self.max_active = max(self.max_active, len(self.pending))
            if int(dut.i_g_valid.value) and int(dut.o_g_ready.value):
                assert grant_slot is not None
                req = self.pending[grant_slot]
                assert req.phase == "g"
                req.phase = "c"
                self.grant_order.append(req.order)
                grant_slot = None
            if int(dut.o_c_valid.value) and int(dut.i_c_ready.value):
                completion = unpack(int(dut.o_c.value), (9, 6, width, 2, 1))
                rid = (completion[0] >> 1) & 15
                req = self.pending[rid]
                assert req.phase == "c"
                assert completion == (
                    req.q,
                    req.tid,
                    req.address,
                    2 if req.error else 0,
                    1,
                )
                req.phase = "u"
                req.due = self.cycle + self.rng.randint(2, self.max_latency)
            if int(dut.i_u_valid.value) and int(dut.o_u_ready.value):
                assert release_slot is not None
                req = self.pending[release_slot]
                assert req.phase == "u"
                req.phase = "released"
                self.released[release_slot] = (req.data, req.error, self.cycle)
                self.release_order.append(req.order)
                release_slot = None
            for req in self.pending.values():
                if req.phase != "queued":
                    continue
                if any(
                    older.order < req.order
                    and older.address == req.address
                    and older.phase != "released"
                    for older in self.pending.values()
                ):
                    continue
                if req.opcode == 8:
                    for byte in range(32):
                        if req.mask & (1 << byte):
                            self.mem[req.address + byte] = (
                                req.value >> (8 * byte)
                            ) & 255
                req.data = self.read_line(req.address) if req.opcode == 7 else 0
                req.error = int(req.address in self.error_lines)
                req.phase = "g"
                delay = (
                    64 if req.order % 4 == 0 else self.rng.randint(2, self.max_latency)
                )
                req.due = max(self.cycle, 80) + delay
            phases = {req.phase for req in self.pending.values()}
            self.phase = (
                self.pause
                if self.pause is not None and self.pause in phases
                else next((phase for phase in ("u", "c", "g") if phase in phases), "d")
            )

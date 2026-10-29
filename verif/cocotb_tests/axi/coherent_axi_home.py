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

from typing import Any
import random

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly

from cocotb_tests.axi.axi_models import LineIngress
from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack


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
        """Start a serial peer with independent grant and release delays."""
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
        self.phase = "d"
        self.pause: str | None = None
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self._dut
        width = len(dut.o_line_req_addr)
        due = packet = release = q = tid = addr = data = error = 0
        while True:
            await FallingEdge(self._clk)
            self.cycle += 1
            reset = int(dut.i_rst.value)
            enabled = not reset and self.cycle >= due and self.pause != self.phase
            dut.i_d_ready.value = int(
                enabled and self.phase == "d" and self.rng.random() < self.ready_bias
            )
            dut.i_g_valid.value = int(enabled and self.phase == "g")
            dut.i_g.value = packet
            dut.i_c_ready.value = int(enabled and self.phase == "c")
            dut.i_u_valid.value = int(enabled and self.phase == "u")
            dut.i_u.value = release
            await ReadOnly()
            if reset:
                self.phase = "d"
                self.outstanding.clear()
                self.accepted.clear()
                self.released.clear()
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
                assert q >> 5 == 0b1011 and q & 1 == 0
                assert self.accepted[rid] == (int(op == 8), addr, mask, value)
                assert (
                    op in (7, 8)
                    and size == 5
                    and not aq
                    and not rl
                    and not offset
                    and not maintenance
                )
                if op == 8:
                    for byte in range(32):
                        if mask & (1 << byte):
                            self.mem[addr + byte] = (value >> (8 * byte)) & 255
                data = self.read_line(addr) if op == 7 else 0
                error = int(addr in self.error_lines)
                tid = (tid + 1) & 63
                packet = pack(
                    (3, 3 if op == 7 else 4),
                    (9, q),
                    (6, tid),
                    (width, addr),
                    (256, data),
                    (1, error),
                )
                release = pack((9, q), (6, tid), (width, addr))
                self.phase = "g"
                due = self.cycle + self.rng.randint(2, self.max_latency)
            elif int(dut.i_g_valid.value) and int(dut.o_g_ready.value):
                self.phase = "c"
                due = self.cycle + self.rng.randint(2, self.max_latency)
            elif int(dut.o_c_valid.value) and int(dut.i_c_ready.value):
                assert unpack(int(dut.o_c.value), (9, 6, width, 2, 1)) == (
                    q,
                    tid,
                    addr,
                    2 if error else 0,
                    1,
                )
                self.phase = "u"
                due = self.cycle + self.rng.randint(2, self.max_latency)
            elif int(dut.i_u_valid.value) and int(dut.o_u_ready.value):
                self.released[(q >> 1) & 15] = (data, error, self.cycle)
                self.phase = "d"
                due = self.cycle + 1

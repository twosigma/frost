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

"""The DMA front-end as one engine sees it, over a byte-addressable memory.

Requests are accepted with random ready gaps up to a cap of three in
flight; responses come back after a random latency and out of order (the
port's behaviour); reads return the line, writes apply their strobes.
The model also records the order of events so a test can check that a
status write was issued only after every data write of its engine had
been answered, and that at most one status write is in flight.
"""

import random
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, Timer

LINE = 32
KIND_DATA = 0
KIND_DESC = 1
KIND_STATUS = 2


class Memory:
    """Bytes at addresses; unset bytes read as a hash of the address."""

    def __init__(self) -> None:
        """Start empty."""
        self.bytes: dict[int, int] = {}

    def read(self, addr: int) -> int:
        """Read one byte."""
        return self.bytes.get(addr, (addr * 0x9E37 + 0x5A) & 0xFF)

    def write(self, addr: int, value: int) -> None:
        """Write one byte."""
        self.bytes[addr] = value & 0xFF

    def read_line(self, addr: int) -> int:
        """Read a 32-byte line as a little-endian integer."""
        return int.from_bytes(bytes(self.read(addr + i) for i in range(LINE)), "little")

    def write_word32(self, addr: int, value: int) -> None:
        """Write a little-endian 32-bit word."""
        for i in range(4):
            self.write(addr + i, (value >> (8 * i)) & 0xFF)

    def read_word32(self, addr: int) -> int:
        """Read a little-endian 32-bit word."""
        return int.from_bytes(bytes(self.read(addr + i) for i in range(4)), "little")

    def write_bytes(self, addr: int, data: bytes) -> None:
        """Write a byte string."""
        for i, b in enumerate(data):
            self.write(addr + i, b)

    def read_bytes(self, addr: int, n: int) -> bytes:
        """Read a byte string."""
        return bytes(self.read(addr + i) for i in range(n))


class DmaModel:
    """The front-end's engine-side port over a Memory, driven from the bench."""

    def __init__(
        self,
        dut: Any,
        mem: Memory,
        seed: int = 0,
        latency: tuple[int, int] = (2, 14),
        gap: float = 0.2,
        cap: int = 3,
        status_latency: tuple[int, int] | None = None,
    ) -> None:
        """Start the driver; latencies are inclusive cycle ranges."""
        self.dut = dut
        self.mem = mem
        self.rng = random.Random(seed)
        self.latency = latency
        self.status_latency = status_latency or latency
        self.gap = gap
        self.cap = cap
        self.hold = False
        self.withdraw_status = (
            False  # answer status writes with the error flag, unapplied
        )
        self.pending: list[
            list[Any]
        ] = []  # [cycles_left, kind, tag, error, rdata, counted]
        self.log: list[dict[str, Any]] = []  # accepted requests in order
        self.violations: list[str] = []
        self.status_inflight = 0
        self.data_inflight = 0
        self.cycle = 0
        self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        """Cancel the driver task."""
        self._task.cancel()

    async def _run(self) -> None:
        dut = self.dut
        dut.i_req_ready.value = 0
        dut.i_resp_valid.value = 0
        while True:
            await FallingEdge(dut.i_clk)
            self.cycle += 1
            dut.i_resp_valid.value = 0
            if not self.hold:
                ready_ones = [p for p in self.pending if p[0] <= 0]
                if ready_ones:
                    p = self.rng.choice(ready_ones)
                    self.pending.remove(p)
                    _, kind, tag, error, rdata, counted = p
                    dut.i_resp_valid.value = 1
                    dut.i_resp_kind.value = kind
                    dut.i_resp_tag.value = tag
                    dut.i_resp_error.value = error
                    dut.i_resp_rdata.value = rdata
                    if counted and kind == KIND_STATUS:
                        self.status_inflight -= 1
                    elif counted and kind == KIND_DATA:
                        self.data_inflight -= 1
            for p in self.pending:
                p[0] -= 1
            # Decide on the request after every falling-edge write of the bench
            # has settled: a level the test changes at this edge (abort, stop)
            # may withdraw the request, as a registered level would in hardware.
            await Timer(1, unit="ps")
            accept = (
                int(dut.o_req_valid.value) == 1
                and len(self.pending) < self.cap
                and self.rng.random() >= self.gap
            )
            if not accept:
                dut.i_req_ready.value = 0
                continue
            dut.i_req_ready.value = 1
            kind = int(dut.o_req_kind.value)
            tag = int(dut.o_req_tag.value)
            addr = int(dut.o_req_addr.value)
            write = int(dut.o_req_write.value) == 1
            rec = {
                "cycle": self.cycle,
                "kind": kind,
                "tag": tag,
                "addr": addr,
                "write": write,
            }
            rdata = 0
            error = 0
            counted = True  # the request counts toward the in-flight checks
            if not (0x8000_0000 <= addr < 0xC000_0000):
                error = 1
                counted = False
                self.violations.append(f"request outside the aperture: {addr:#x}")
            elif write and kind == KIND_STATUS and self.withdraw_status:
                error = 1  # the drain withdrew it: no write, an error response
                counted = False
                rec["withdrawn"] = True
            elif write:
                wdata = int(dut.o_req_wdata.value)
                wstrb = int(dut.o_req_wstrb.value)
                rec["wstrb"] = wstrb
                for b in range(LINE):
                    if (wstrb >> b) & 1:
                        self.mem.write(addr + b, (wdata >> (8 * b)) & 0xFF)
                if kind == KIND_STATUS:
                    if self.data_inflight:
                        self.violations.append(
                            f"status write at cycle {self.cycle} with {self.data_inflight} data writes unanswered"
                        )
                    if self.status_inflight:
                        self.violations.append(
                            f"second status write in flight at cycle {self.cycle}"
                        )
                    self.status_inflight += 1
                elif kind == KIND_DATA:
                    self.data_inflight += 1
            else:
                rdata = self.mem.read_line(addr)
                if kind == KIND_DATA:
                    self.data_inflight += 1
            self.log.append(rec)
            lat = self.status_latency if kind == KIND_STATUS else self.latency
            self.pending.append(
                [self.rng.randint(*lat), kind, tag, error, rdata, counted]
            )


# Descriptor helpers (16 bytes: word0 address, word1 length/flags, word2 status).
DD = 1 << 16
TRUNC = 1 << 17
ERR = 1 << 18
ABORT = 1 << 19
SOP = 1 << 16
EOP = 1 << 17


def desc_addr(base: int, index: int) -> int:
    """Return the byte address of descriptor `index` in the ring at `base`."""
    return base + 16 * index


def post_desc(mem: Memory, base: int, index: int, buf_addr: int, word1: int) -> None:
    """Write a descriptor the way software posts it: words 0/1, word 2 zeroed."""
    a = desc_addr(base, index)
    mem.write_word32(a, buf_addr)
    mem.write_word32(a + 4, word1)
    mem.write_word32(a + 8, 0)
    mem.write_word32(a + 12, 0)


def desc_status(mem: Memory, base: int, index: int) -> int:
    """Return the descriptor's status word (word 2)."""
    return mem.read_word32(desc_addr(base, index) + 8)

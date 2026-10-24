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

"""AXI4 bus models for the cocotb benches.

Signals are found by name prefix, so one model serves any port naming:
AxiMaster drives a DUT's AXI4 slave port, AxiSlaveMemory answers a DUT's AXI4
master port, and LineIngress plays cpu_top's coherent ingress for a DUT's
line-port master. Every model drives at the falling edge and samples after
ReadOnly, before the rising edge that completes the cycle's handshakes.
"""

import random
from collections import deque
from dataclasses import dataclass, field
from typing import Any

import cocotb
from cocotb.triggers import Event, FallingEdge, ReadOnly

FIXED, INCR, WRAP = 0, 1, 2
OKAY, EXOKAY, SLVERR, DECERR = 0, 1, 2, 3
PAGE_BYTES = 4096
LINE_BYTES = 32


def beat_addresses(addr: int, length: int, size: int, burst: int) -> list[int]:
    """Return the address of every beat of a burst (IHI0022 A3.4.1)."""
    nbytes = 1 << size
    beats = length + 1
    aligned = addr - addr % nbytes
    out = []
    for n in range(beats):
        if burst == FIXED:
            out.append(addr)
        elif burst == INCR:
            out.append(addr if n == 0 else aligned + n * nbytes)
        else:
            total = beats * nbytes
            base = addr - addr % total
            out.append(base + (addr - base + n * nbytes) % total)
    return out


def beat_lanes(addr: int, size: int, bus_bytes: int) -> range:
    """Return the bus byte lanes a beat at addr carries."""
    nbytes = 1 << size
    low = addr % bus_bytes
    high = (addr - addr % nbytes) % bus_bytes + nbytes - 1
    return range(low, high + 1)


def burst_is_legal(
    addr: int, length: int, size: int, burst: int, bus_bytes: int
) -> bool:
    """Return whether an AW or AR form is legal AXI4 on a bus of bus_bytes."""
    nbytes = 1 << size
    if nbytes > bus_bytes or burst == 3:
        return False
    if burst == FIXED:
        return length <= 15
    if burst == WRAP:
        return length in (1, 3, 7, 15) and addr % nbytes == 0
    start = addr % PAGE_BYTES - (addr % PAGE_BYTES) % nbytes
    return start + (length + 1) * nbytes <= PAGE_BYTES


def apply_write(
    mem: dict[int, int],
    addr: int,
    length: int,
    size: int,
    burst: int,
    beats: list[tuple[int, int]],
    bus_bytes: int,
) -> None:
    """Apply a write burst to a byte memory in beat order, as a memory slave would."""
    for beat_addr, (data, strb) in zip(
        beat_addresses(addr, length, size, burst), beats
    ):
        word = beat_addr - beat_addr % bus_bytes
        for lane in beat_lanes(beat_addr, size, bus_bytes):
            if (strb >> lane) & 1:
                mem[word + lane] = (data >> (8 * lane)) & 0xFF


@dataclass
class AxiWrite:
    """One write burst and, once B arrives, its response."""

    id: int
    addr: int
    length: int
    size: int
    burst: int
    beats: list[tuple[int, int]]
    lock: int = 0
    resp: int | None = None
    order: int = -1
    done: Event = field(default_factory=Event)


@dataclass
class AxiRead:
    """One read burst and, beat by beat, its R data and responses."""

    id: int
    addr: int
    length: int
    size: int
    burst: int
    lock: int = 0
    beats: list[tuple[int, int]] = field(default_factory=list)  # (data, resp)
    order: int = -1
    done: Event = field(default_factory=Event)


class AxiMaster:
    """AXI4 master driving a DUT's slave port.

    `inputs` and `outputs` prefix the DUT's input and output signal names
    (for example "i_axi_" and "o_axi_"). Queued writes present AW and their W
    beats in order with random gaps; W may run ahead of its AW, as AXI4
    allows. B and R take ready with probability `ready_bias`, changed at any
    time. A response retires the oldest outstanding transaction of its id.
    Protocol errors on the DUT's outputs (B or R withdrawn or changed before
    READY, a response for nothing outstanding, RLAST on the wrong beat)
    collect in `violations`. `completions` lists write and read completions
    in order, as ("w"|"r", transaction).
    """

    def __init__(
        self,
        dut: Any,
        clk: Any,
        inputs: str,
        outputs: str,
        bus_bytes: int,
        rng: random.Random,
        ready_bias: float = 0.8,
        gap_bias: float = 0.3,
    ) -> None:
        """Start the master's driver task."""
        self._dut = dut
        self._clk = clk
        self._in = inputs
        self._out = outputs
        self.bus_bytes = bus_bytes
        self.rng = rng
        self.ready_bias = ready_bias
        self.gap_bias = gap_bias
        self.cycle = 0
        self.violations: list[str] = []
        self.completions: list[tuple[str, Any]] = []
        self._aw_queue: deque[AxiWrite] = deque()
        self._w_queue: deque[AxiWrite] = deque()
        self._ar_queue: deque[AxiRead] = deque()
        self._aw_cur: AxiWrite | None = None
        self._ar_cur: AxiRead | None = None
        self._w_cur: tuple[AxiWrite, int] | None = None  # write, beat index
        self._w_beat_next: dict[int, int] = {}
        self._b_wait: dict[int, deque[AxiWrite]] = {}
        self._r_wait: dict[int, deque[AxiRead]] = {}
        self._b_held: tuple[int, int] | None = None
        self._r_held: tuple[int, int, int, int] | None = None
        self._issued = 0
        self._idle()
        self._task = cocotb.start_soon(self._run())

    def _sig(self, prefix: str, name: str) -> Any:
        return getattr(self._dut, prefix + name)

    def _idle(self) -> None:
        for name in ("awvalid", "wvalid", "arvalid"):
            self._sig(self._in, name).value = 0
        for name in ("awlock", "arlock", "awcache", "arcache", "awprot", "arprot"):
            self._sig(self._in, name).value = 0
        for name in ("awqos", "arqos"):
            self._sig(self._in, name).value = 0
        self._sig(self._in, "bready").value = 0
        self._sig(self._in, "rready").value = 0

    def write(
        self,
        id: int,
        addr: int,
        length: int,
        size: int,
        burst: int,
        beats: list[tuple[int, int]],
        lock: int = 0,
    ) -> AxiWrite:
        """Queue a write burst; await its `done` event for the response."""
        assert len(beats) == length + 1
        txn = AxiWrite(id, addr, length, size, burst, beats, lock)
        self._aw_queue.append(txn)
        self._w_queue.append(txn)
        return txn

    def read(
        self, id: int, addr: int, length: int, size: int, burst: int, lock: int = 0
    ) -> AxiRead:
        """Queue a read burst; await its `done` event for the beats."""
        txn = AxiRead(id, addr, length, size, burst, lock)
        self._ar_queue.append(txn)
        return txn

    def busy(self) -> bool:
        """Return whether any transaction is queued or outstanding."""
        return bool(
            self._aw_queue
            or self._w_queue
            or self._ar_queue
            or self._aw_cur
            or self._ar_cur
            or self._w_cur
            or any(self._b_wait.values())
            or any(self._r_wait.values())
        )

    async def _run(self) -> None:
        dut_in = self._in
        while True:
            await FallingEdge(self._clk)
            self.cycle += 1
            rng = self.rng
            if (
                self._aw_cur is None
                and self._aw_queue
                and rng.random() >= self.gap_bias
            ):
                self._aw_cur = self._aw_queue.popleft()
            if (
                self._ar_cur is None
                and self._ar_queue
                and rng.random() >= self.gap_bias
            ):
                self._ar_cur = self._ar_queue.popleft()
            if self._w_cur is None and self._w_queue and rng.random() >= self.gap_bias:
                head = self._w_queue[0]
                self._w_cur = (head, self._w_beat_next.get(id(head), 0))
            aw = self._aw_cur
            self._sig(dut_in, "awvalid").value = int(aw is not None)
            if aw is not None:
                self._sig(dut_in, "awid").value = aw.id
                self._sig(dut_in, "awaddr").value = aw.addr
                self._sig(dut_in, "awlen").value = aw.length
                self._sig(dut_in, "awsize").value = aw.size
                self._sig(dut_in, "awburst").value = aw.burst
                self._sig(dut_in, "awlock").value = aw.lock
            ar = self._ar_cur
            self._sig(dut_in, "arvalid").value = int(ar is not None)
            if ar is not None:
                self._sig(dut_in, "arid").value = ar.id
                self._sig(dut_in, "araddr").value = ar.addr
                self._sig(dut_in, "arlen").value = ar.length
                self._sig(dut_in, "arsize").value = ar.size
                self._sig(dut_in, "arburst").value = ar.burst
                self._sig(dut_in, "arlock").value = ar.lock
            w = self._w_cur
            self._sig(dut_in, "wvalid").value = int(w is not None)
            if w is not None:
                data, strb = w[0].beats[w[1]]
                self._sig(dut_in, "wdata").value = data
                self._sig(dut_in, "wstrb").value = strb
                self._sig(dut_in, "wlast").value = int(w[1] == w[0].length)
            bready = rng.random() < self.ready_bias
            rready = rng.random() < self.ready_bias
            self._sig(dut_in, "bready").value = int(bready)
            self._sig(dut_in, "rready").value = int(rready)

            await ReadOnly()
            out = self._out
            if aw is not None and int(self._sig(out, "awready").value):
                self._b_wait.setdefault(aw.id, deque()).append(aw)
                self._aw_cur = None
            if ar is not None and int(self._sig(out, "arready").value):
                ar.order = self._issued
                self._issued += 1
                self._r_wait.setdefault(ar.id, deque()).append(ar)
                self._ar_cur = None
            if w is not None and int(self._sig(out, "wready").value):
                txn, beat = w
                if beat == txn.length:
                    self._w_queue.popleft()
                    self._w_beat_next.pop(id(txn), None)
                else:
                    self._w_beat_next[id(txn)] = beat + 1
                self._w_cur = None
            self._sample_b(bready)
            self._sample_r(rready)

    def _sample_b(self, bready: bool) -> None:
        out = self._out
        bvalid = int(self._sig(out, "bvalid").value)
        if self._b_held is not None:
            if (
                not bvalid
                or (
                    int(self._sig(out, "bid").value),
                    int(self._sig(out, "bresp").value),
                )
                != self._b_held
            ):
                self.violations.append(
                    f"cycle {self.cycle}: B dropped or changed before BREADY"
                )
        self._b_held = None
        if not bvalid:
            return
        bid = int(self._sig(out, "bid").value)
        bresp = int(self._sig(out, "bresp").value)
        if not bready:
            self._b_held = (bid, bresp)
            return
        queue = self._b_wait.get(bid)
        if not queue:
            self.violations.append(
                f"cycle {self.cycle}: B for id {bid} with no write outstanding"
            )
            return
        txn = queue.popleft()
        txn.resp = bresp
        txn.order = len(self.completions)
        self.completions.append(("w", txn))
        txn.done.set()

    def _sample_r(self, rready: bool) -> None:
        out = self._out
        rvalid = int(self._sig(out, "rvalid").value)
        if self._r_held is not None:
            if (
                not rvalid
                or (
                    int(self._sig(out, "rid").value),
                    int(self._sig(out, "rdata").value),
                    int(self._sig(out, "rresp").value),
                    int(self._sig(out, "rlast").value),
                )
                != self._r_held
            ):
                self.violations.append(
                    f"cycle {self.cycle}: R dropped or changed before RREADY"
                )
        self._r_held = None
        if not rvalid:
            return
        rid = int(self._sig(out, "rid").value)
        rdata = int(self._sig(out, "rdata").value)
        rresp = int(self._sig(out, "rresp").value)
        rlast = int(self._sig(out, "rlast").value)
        if not rready:
            self._r_held = (rid, rdata, rresp, rlast)
            return
        queue = self._r_wait.get(rid)
        if not queue:
            self.violations.append(
                f"cycle {self.cycle}: R for id {rid} with no read outstanding"
            )
            return
        txn = queue[0]
        txn.beats.append((rdata, rresp))
        last_expected = len(txn.beats) == txn.length + 1
        if bool(rlast) != last_expected:
            self.violations.append(
                f"cycle {self.cycle}: RLAST {rlast} on beat {len(txn.beats)} of {txn.length + 1}"
            )
        if rlast or last_expected:
            queue.popleft()
            self.completions.append(("r", txn))
            txn.done.set()


class LineIngress:
    """cpu_top's coherent ingress, seen from a line-port master.

    Applies a write to `mem` when it accepts it and reads `mem` then, which
    is where the ingress orders requests; answers each accepted request once,
    after 1 to `max_latency` cycles and in any order, with at most one
    response per cycle; and answers with the error flag for lines in
    `error_lines`. It checks the ingress's preconditions (line alignment,
    the region, a strobe on every write, ids unique among requests in flight)
    and that a presented request is held until accepted. `log` records each
    accepted request as (cycle, write, addr, strb, id).
    """

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
        """Start the model's task."""
        self._dut = dut
        self._clk = clk
        self.mem = mem
        self.region = region
        self.rng = rng
        self.ready_bias = ready_bias
        self.max_latency = max_latency
        self.error_lines: set[int] = set()
        self.log: list[tuple[int, bool, int, int, int]] = []
        self.violations: list[str] = []
        self.cycle = 0
        self.outstanding: dict[int, int] = {}  # id -> line address
        self._due: list[tuple[int, int, int, int]] = []  # (cycle, id, data, error)
        self._held: tuple[int, ...] | None = None
        dut.i_line_req_ready.value = 0
        dut.i_line_resp_valid.value = 0
        dut.i_line_resp_id.value = 0
        dut.i_line_resp_rdata.value = 0
        dut.i_line_resp_error.value = 0
        self._task = cocotb.start_soon(self._run())

    def read_line(self, addr: int) -> int:
        """Return the 32-byte line at addr from the model's memory."""
        return sum(self.mem.get(addr + b, 0) << (8 * b) for b in range(LINE_BYTES))

    async def _run(self) -> None:
        dut = self._dut
        while True:
            await FallingEdge(self._clk)
            self.cycle += 1
            ready = self.rng.random() < self.ready_bias
            dut.i_line_req_ready.value = int(ready)
            due = [entry for entry in self._due if entry[0] <= self.cycle]
            if due:
                entry = self.rng.choice(due)
                self._due.remove(entry)
                _, rid, rdata, rerror = entry
                self.outstanding.pop(rid, None)
                dut.i_line_resp_valid.value = 1
                dut.i_line_resp_id.value = rid
                dut.i_line_resp_rdata.value = rdata
                dut.i_line_resp_error.value = rerror
            else:
                dut.i_line_resp_valid.value = 0
            await ReadOnly()
            in_reset = int(dut.i_rst.value)
            valid = int(dut.o_line_req_valid.value)
            if in_reset:
                if valid:
                    self.violations.append(f"cycle {self.cycle}: line request in reset")
                self._held = None
                self._due.clear()
                self.outstanding.clear()
                continue
            if not valid:
                if self._held is not None:
                    self.violations.append(
                        f"cycle {self.cycle}: line request withdrawn"
                    )
                self._held = None
                continue
            write = int(dut.o_line_req_write.value)
            addr = int(dut.o_line_req_addr.value)
            rid = int(dut.o_line_req_id.value)
            strb = int(dut.o_line_req_wstrb.value) if write else 0
            wdata = int(dut.o_line_req_wdata.value) if write else 0
            payload = (write, addr, rid, strb, wdata)
            if self._held is not None and payload != self._held:
                self.violations.append(
                    f"cycle {self.cycle}: line request changed before ready"
                )
            if not ready:
                self._held = payload
                continue
            self._held = None
            base, size = self.region
            if addr % LINE_BYTES or not base <= addr < base + size:
                self.violations.append(
                    f"cycle {self.cycle}: bad line address {addr:#x}"
                )
            if write and strb == 0:
                self.violations.append(f"cycle {self.cycle}: write with no strobes")
            if rid in self.outstanding:
                self.violations.append(
                    f"cycle {self.cycle}: id {rid} reused while in flight"
                )
            self.outstanding[rid] = addr
            self.log.append((self.cycle, bool(write), addr, strb, rid))
            if write:
                for b in range(LINE_BYTES):
                    if (strb >> b) & 1:
                        self.mem[addr + b] = (wdata >> (8 * b)) & 0xFF
                rdata = 0
            else:
                rdata = self.read_line(addr)
            error = int(addr in self.error_lines)
            self._due.append(
                (self.cycle + self.rng.randint(1, self.max_latency), rid, rdata, error)
            )


class AxiSlaveMemory:
    """AXI4 slave memory answering a DUT's master port.

    `inputs` and `outputs` prefix the DUT's input and output names (for
    example "i_dma_axi_" and "o_dma_axi_"). AW, W and AR take ready with
    probability `ready_bias`, with W waiting for a queued AW. Writes apply
    to `mem` in AW order once all their beats are in, and reads read `mem`
    when their AR is accepted. B and R come back after 1 to `max_latency`
    cycles; with `reorder`, responses of
    different ids may pass each other. Lines (32-byte addresses) in
    `error_lines` answer SLVERR. VALID and payload stability on the DUT's
    channels, WLAST, and legal burst forms are checked into `violations`.
    """

    def __init__(
        self,
        dut: Any,
        clk: Any,
        inputs: str,
        outputs: str,
        bus_bytes: int,
        mem: dict[int, int],
        rng: random.Random,
        ready_bias: float = 0.8,
        max_latency: int = 12,
        reorder: bool = True,
    ) -> None:
        """Start the slave's task."""
        self._dut = dut
        self._clk = clk
        self._in = inputs
        self._out = outputs
        self.bus_bytes = bus_bytes
        self.mem = mem
        self.rng = rng
        self.ready_bias = ready_bias
        self.max_latency = max_latency
        self.reorder = reorder
        self.error_lines: set[int] = set()
        self.violations: list[str] = []
        self.writes: list[
            tuple[int, int, int, int, int]
        ] = []  # (id, addr, len, size, burst)
        self.reads: list[tuple[int, int, int, int, int]] = []
        self.cycle = 0
        self._aw: deque[tuple[int, int, int, int, int]] = deque()
        self._w: list[tuple[int, int]] = []
        self._b: list[tuple[int, int, int]] = []  # (due, id, resp)
        self._r: list[
            tuple[int, int, list[tuple[int, int, int]]]
        ] = []  # (due, id, beats)
        self._held: dict[str, tuple[int, ...] | None] = {
            "aw": None,
            "w": None,
            "ar": None,
        }
        self._r_cur: tuple[int, list[tuple[int, int, int]]] | None = None
        self._b_cur: tuple[int, int] | None = None
        for name in ("awready", "wready", "arready", "bvalid", "rvalid"):
            self._sig(self._in, name).value = 0
        self._task = cocotb.start_soon(self._run())

    def _sig(self, prefix: str, name: str) -> Any:
        return getattr(self._dut, prefix + name)

    def _fields(
        self, prefix: str, names: tuple[str, ...]
    ) -> tuple[int, int, int, int, int]:
        """Read an address channel's id, address, length, size and burst."""
        a, b, c, d, e = (int(self._sig(prefix, name).value) for name in names)
        return a, b, c, d, e

    def _pick(self, entries: list[Any]) -> Any:
        if self.reorder:
            # Any id may pass another, but each id stays in order (AXI4).
            oldest: dict[int, Any] = {}
            for entry in entries:
                oldest.setdefault(entry[1], entry)
            due = [entry for entry in oldest.values() if entry[0] <= self.cycle]
            return self.rng.choice(due) if due else None
        # In order: the oldest accepted transaction, once it is due.
        return entries[0] if entries and entries[0][0] <= self.cycle else None

    async def _run(self) -> None:
        while True:
            await FallingEdge(self._clk)
            self.cycle += 1
            rng = self.rng
            awready = rng.random() < self.ready_bias
            wready = rng.random() < self.ready_bias and bool(self._aw)
            arready = rng.random() < self.ready_bias
            self._sig(self._in, "awready").value = int(awready)
            self._sig(self._in, "wready").value = int(wready)
            self._sig(self._in, "arready").value = int(arready)
            if self._b_cur is None:
                entry = self._pick(self._b)
                if entry is not None:
                    self._b.remove(entry)
                    self._b_cur = (entry[1], entry[2])
            self._sig(self._in, "bvalid").value = int(self._b_cur is not None)
            if self._b_cur is not None:
                self._sig(self._in, "bid").value = self._b_cur[0]
                self._sig(self._in, "bresp").value = self._b_cur[1]
            if self._r_cur is None:
                entry = self._pick(self._r)
                if entry is not None:
                    self._r.remove(entry)
                    self._r_cur = (entry[1], list(entry[2]))
            self._sig(self._in, "rvalid").value = int(self._r_cur is not None)
            if self._r_cur is not None:
                data, resp, last = self._r_cur[1][0]
                self._sig(self._in, "rid").value = self._r_cur[0]
                self._sig(self._in, "rdata").value = data
                self._sig(self._in, "rresp").value = resp
                self._sig(self._in, "rlast").value = last

            await ReadOnly()
            out = self._out
            self._check(
                "aw",
                awready,
                ("awvalid", "awid", "awaddr", "awlen", "awsize", "awburst"),
            )
            self._check("w", wready, ("wvalid", "wdata", "wstrb", "wlast"))
            self._check(
                "ar",
                arready,
                ("arvalid", "arid", "araddr", "arlen", "arsize", "arburst"),
            )
            if int(self._sig(out, "awvalid").value) and awready:
                aw = self._fields(out, ("awid", "awaddr", "awlen", "awsize", "awburst"))
                if not burst_is_legal(aw[1], aw[2], aw[3], aw[4], self.bus_bytes):
                    self.violations.append(f"cycle {self.cycle}: illegal AW {aw}")
                self._aw.append(aw)
                self.writes.append(aw)
            if int(self._sig(out, "wvalid").value) and wready:
                self._w.append(
                    (
                        int(self._sig(out, "wdata").value),
                        int(self._sig(out, "wstrb").value),
                    )
                )
                wlast = int(self._sig(out, "wlast").value)
                if self._aw:
                    expected = self._aw[0][2] + 1
                    if bool(wlast) != (len(self._w) == expected):
                        self.violations.append(
                            f"cycle {self.cycle}: WLAST on beat {len(self._w)}"
                        )
                    if len(self._w) == expected:
                        self._finish_write(self._aw.popleft())
                else:
                    self.violations.append(f"cycle {self.cycle}: W before its AW")
            if int(self._sig(out, "arvalid").value) and arready:
                ar = self._fields(out, ("arid", "araddr", "arlen", "arsize", "arburst"))
                if not burst_is_legal(ar[1], ar[2], ar[3], ar[4], self.bus_bytes):
                    self.violations.append(f"cycle {self.cycle}: illegal AR {ar}")
                self.reads.append(ar)
                self._start_read(ar)
            if self._b_cur is not None and int(self._sig(out, "bready").value):
                self._b_cur = None
            if self._r_cur is not None and int(self._sig(out, "rready").value):
                self._r_cur[1].pop(0)
                if not self._r_cur[1]:
                    self._r_cur = None

    def _check(self, channel: str, ready: bool, names: tuple[str, ...]) -> None:
        values = tuple(int(self._sig(self._out, name).value) for name in names)
        held = self._held[channel]
        if held is not None and values != held:
            self.violations.append(
                f"cycle {self.cycle}: {channel} dropped or changed early"
            )
        self._held[channel] = values if (values[0] and not ready) else None

    def _line_error(self, addr: int, length: int, size: int, burst: int) -> bool:
        return any(
            beat - beat % LINE_BYTES in self.error_lines
            for beat in beat_addresses(addr, length, size, burst)
        )

    def _finish_write(self, aw: tuple[int, int, int, int, int]) -> None:
        wid, addr, length, size, burst = aw
        beats, self._w = self._w, []
        error = self._line_error(addr, length, size, burst)
        if not error:
            apply_write(self.mem, addr, length, size, burst, beats, self.bus_bytes)
        due = self.cycle + self.rng.randint(1, self.max_latency)
        self._b.append((due, wid, SLVERR if error else OKAY))

    def _start_read(self, ar: tuple[int, int, int, int, int]) -> None:
        rid, addr, length, size, burst = ar
        beats = []
        for n, beat in enumerate(beat_addresses(addr, length, size, burst)):
            word = beat - beat % self.bus_bytes
            data = sum(
                self.mem.get(word + b, 0) << (8 * b) for b in range(self.bus_bytes)
            )
            error = beat - beat % LINE_BYTES in self.error_lines
            beats.append((data, SLVERR if error else OKAY, int(n == length)))
        due = self.cycle + self.rng.randint(1, self.max_latency)
        self._r.append((due, rid, beats))

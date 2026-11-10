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

"""Unit tests for nic_tx_engine (hw/rtl/peripherals/nic/nic_tx_engine.sv).

The engine runs against the DMA model of dma_model.py (a memory with
out-of-order responses) and a beat sink standing in for the TX FIFO. A
buffer at any byte offset must come out as contiguous beats with the right
final count and last flag, and the engine must read exactly the lines the
buffer covers.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.nic.dma_model import (
    ABORT,
    DONE,
    ERR,
    FIRST,
    KIND_DATA,
    LAST,
    DmaModel,
    Memory,
    desc_status,
    post_desc,
)

RING = 0x8010_0000
SIZE_LOG2 = 4
ENTRIES = 1 << SIZE_LOG2
BUF = 0x8020_0000


class _Sink:
    """Takes beats with random backpressure and reassembles frames."""

    def __init__(self, dut: Any, rng: random.Random, gap: float) -> None:
        self.dut = dut
        self.rng = rng
        self.gap = gap
        self.frames: list[bytes] = []
        self.first_csum: list[int] = []  # o_fifo_csum on each frame's first beat
        self.csums: list[int] = []  # request on every accepted beat
        self.cut: list[bytes] = []
        self.aborted: list[bytes] = []  # frames closed by an abort beat
        self.current = bytearray()
        self.beats = 0
        self.stall = False
        self._task = cocotb.start_soon(self._run())

    async def _run(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_clk)
            if (
                int(dut.o_fifo_valid.value) == 1
                and not self.stall
                and self.rng.random() >= self.gap
            ):
                code = int(dut.o_fifo_code.value)
                n = (code & 7) + 1
                last = (code >> 3) & 1
                abort = int(dut.o_fifo_abort.value)
                assert last or not abort
                data = int(dut.o_fifo_data.value).to_bytes(8, "little")
                assert last or n == 8, "a nonfinal beat must carry 8 bytes"
                if not self.current:
                    self.first_csum.append(int(dut.o_fifo_csum.value))
                self.csums.append(int(dut.o_fifo_csum.value))
                self.current += data[:n]
                self.beats += 1
                dut.i_fifo_ready.value = 1
                await RisingEdge(dut.i_clk)
                await FallingEdge(dut.i_clk)
                dut.i_fifo_ready.value = 0
                if last and abort:
                    self.aborted.append(bytes(self.current))
                    self.current = bytearray()
                elif last:
                    self.frames.append(bytes(self.current))
                    self.current = bytearray()
            else:
                dut.i_fifo_ready.value = 0

    def cut_frame(self) -> None:
        self.cut.append(bytes(self.current))
        self.current = bytearray()

    def stop(self) -> None:
        self._task.cancel()


class _Env:
    def __init__(
        self,
        dut: Any,
        seed: int,
        latency: tuple[int, int],
        sink_gap: float,
        status_latency: tuple[int, int] | None = None,
    ) -> None:
        self.dut = dut
        self.rng = random.Random(seed)
        self.mem = Memory()
        self.model = DmaModel(
            dut,
            self.mem,
            seed=seed + 100,
            latency=latency,
            status_latency=status_latency,
        )
        self.sink = _Sink(dut, self.rng, sink_gap)
        self.completions: list[tuple[int, int]] = []
        self._task = cocotb.start_soon(self._collect())

    async def _collect(self) -> None:
        dut = self.dut
        while True:
            await FallingEdge(dut.i_clk)
            if int(dut.o_complete.value):
                self.completions.append(
                    (int(dut.o_complete_flags.value), int(dut.o_complete_bytes.value))
                )

    def stop(self) -> None:
        self._task.cancel()
        self.sink.stop()
        self.model.stop()

    def place(
        self, index: int, addr: int, length: int, word1_flags: int = FIRST | LAST
    ) -> bytes:
        payload = bytes(self.rng.getrandbits(8) for _ in range(length))
        self.mem.write_bytes(addr, payload)
        post_desc(self.mem, RING, index, addr, (length & 0xFFFF) | word1_flags)
        return payload

    async def doorbell(self, tail: int) -> None:
        await FallingEdge(self.dut.i_clk)
        self.dut.i_tail.value = tail % ENTRIES

    async def wait_completions(self, n: int, limit: int = 40000) -> None:
        for _ in range(limit):
            await FallingEdge(self.dut.i_clk)
            if len(self.completions) >= n:
                return
        raise AssertionError(f"{len(self.completions)} of {n} completions")

    async def wait_idle(self, limit: int = 2000) -> None:
        for _ in range(limit):
            await FallingEdge(self.dut.i_clk)
            if int(self.dut.o_idle.value) == 1:
                return
        raise AssertionError("engine never idle")

    def lines_read(self) -> list[int]:
        return [r["addr"] for r in self.model.log if r["kind"] == KIND_DATA]


async def _setup(
    dut: Any,
    seed: int,
    latency: tuple[int, int] = (2, 14),
    sink_gap: float = 0.2,
    status_latency: tuple[int, int] | None = None,
) -> _Env:
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_enable,
        dut.i_wide_mode,
        dut.i_base,
        dut.i_size_log2,
        dut.i_tail,
        dut.i_restart,
        dut.i_stop,
        dut.i_abort,
        dut.i_fifo_ready,
        dut.i_req_ready,
        dut.i_resp_valid,
        dut.i_resp_kind,
        dut.i_resp_tag,
        dut.i_resp_error,
        dut.i_resp_rdata,
    ):
        sig.value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    dut.i_base.value = RING
    dut.i_size_log2.value = SIZE_LOG2
    env = _Env(dut, seed, latency, sink_gap, status_latency)
    await FallingEdge(dut.i_clk)
    dut.i_enable.value = 1
    return env


def _expected_lines(addr: int, length: int) -> list[int]:
    first = addr & ~31
    last = (addr + length - 1) & ~31
    return list(range(first, last + 1, 32))


@cocotb.test()
async def test_frames_out(dut: Any) -> None:
    """Buffers at random byte offsets come out byte-exact, reading exactly their lines."""
    env = await _setup(dut, 1)
    lengths = [1, 8, 9, 31, 32, 33, 60, 64, 65, 100, 1518, 1500, 9216, 4000, 7]
    plan = []
    for i, length in enumerate(lengths):
        addr = BUF + i * 0x3000 + env.rng.randrange(64)
        plan.append((addr, length, env.place(i, addr, length)))
    await env.doorbell(len(plan))
    await env.wait_completions(len(plan))
    await env.wait_idle()
    assert env.sink.frames == [p[2] for p in plan]
    for i, (addr, length, _) in enumerate(plan):
        assert desc_status(env.mem, RING, i) == DONE, (
            f"desc {i}: {desc_status(env.mem, RING, i):#x}"
        )
    assert env.completions == [(0, p[1]) for p in plan]
    expected = [
        line for addr, length, _ in plan for line in _expected_lines(addr, length)
    ]
    assert sorted(env.lines_read()) == sorted(expected), (
        "the lines read are not exactly the buffers' lines"
    )
    assert int(dut.o_head.value) == len(plan)
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_frame_checksum_survives_a_stalled_merge_tail(dut: Any) -> None:
    """A later FIRST cannot replace the request on the preceding frame's tail."""
    env = await _setup(dut, 194, latency=(1, 2), sink_gap=0)
    env.sink.stall = True
    flags = (6 << 25) | (3 << 18)
    head = env.place(0, BUF, 1, FIRST | flags)
    tail = env.place(1, BUF + 0x100, 16, LAST)
    next_frame = env.place(2, BUF + 0x200, 16)
    await env.doorbell(3)
    await env.wait_completions(2)
    # The previous frame's two full beats fill the segment stage's input FIFO.
    # Its merge tail waits while the next descriptor is available for admission.
    for _ in range(100):
        await FallingEdge(dut.i_clk)
    env.sink.stall = False
    await env.wait_completions(3)
    for _ in range(2000):
        await FallingEdge(dut.i_clk)
        if len(env.sink.frames) == 2:
            break
    assert env.sink.frames == [head + tail, next_frame]
    request = (6 << 8) | (3 << 1) | 1
    assert env.sink.csums == [request] * 3 + [0] * 2
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_rejected_frame_preserves_earlier_completed_frames(dut: Any) -> None:
    """Aborting a later chain cannot flush a valid frame still waiting in the segment stage."""
    env = await _setup(dut, 195, latency=(1, 2), sink_gap=0)
    env.sink.stall = True
    earlier = env.place(0, BUF, 16)
    env.place(1, BUF + 0x100, 5, FIRST)
    env.place(2, 0x1000, 8, LAST)  # rejected continuation outside the aperture
    later = env.place(3, BUF + 0x200, 16)
    await env.doorbell(4)
    await env.wait_completions(1)
    # Allow a broken implementation to admit and abort the next frame while the
    # preceding completed frame is retained entirely inside the segment stage.
    for _ in range(100):
        await FallingEdge(dut.i_clk)
    env.sink.stall = False
    await env.wait_completions(4)
    for _ in range(2000):
        await FallingEdge(dut.i_clk)
        if len(env.sink.frames) == 2:
            break
    assert env.sink.frames == [earlier, later]
    assert desc_status(env.mem, RING, 2) == DONE | ERR | ABORT
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_rejected_frame_preserves_segmented_output(dut: Any) -> None:
    """Retain the tail of a completed segmented frame when the following chain is rejected."""
    from cocotb_tests.nic.test_nic_tx_segment import Packet

    env = await _setup(dut, 196, latency=(1, 1), sink_gap=0, status_latency=(1, 1))
    pkt = Packet(env.rng, payload_len=3500, mss=1200)
    word0, word1 = _param_words(pkt)
    post_desc(env.mem, RING, 0, word0, word1)
    env.mem.write_bytes(BUF, pkt.frame)
    post_desc(env.mem, RING, 1, BUF, len(pkt.frame) | FIRST | LAST)
    env.place(2, BUF + 0x10000, 5, FIRST)
    env.place(3, 0x1000, 8, LAST)
    later = env.place(4, BUF + 0x20000, 16)
    await env.doorbell(5)
    await env.wait_completions(2)
    env.sink.stall = True
    expected = pkt.segments()
    assert len(env.sink.frames) < len(expected), (
        "the test must stall pending segmented output"
    )
    for _ in range(100):
        await FallingEdge(dut.i_clk)
    env.sink.stall = False
    await env.wait_completions(5)
    for _ in range(4000):
        await FallingEdge(dut.i_clk)
        if len(env.sink.frames) == len(expected) + 1:
            break
    assert env.sink.frames == expected + [later]
    assert desc_status(env.mem, RING, 3) == DONE | ERR | ABORT
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_reorder_under_slow_memory(dut: Any) -> None:
    """Widely reordered responses and a stalling sink: data still comes out in order."""
    env = await _setup(dut, 2, latency=(1, 40), sink_gap=0.6)
    plan = []
    for i in range(6):
        addr = BUF + i * 0x3000 + env.rng.randrange(64)
        length = env.rng.choice([200, 1500, 9216, 333])
        plan.append((addr, length, env.place(i, addr, length)))
    await env.doorbell(len(plan))
    await env.wait_completions(len(plan), limit=80000)
    assert env.sink.frames == [p[2] for p in plan]
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_one_status_write_in_flight(dut: Any) -> None:
    """With slow status responses, each status write waits for the previous one's response."""
    env = await _setup(dut, 7, latency=(1, 4), sink_gap=0.0, status_latency=(150, 150))
    plan = [env.place(i, BUF + i * 0x1000 + 3, 64) for i in range(4)]
    await env.doorbell(4)
    await env.wait_completions(4)
    assert env.sink.frames == plan
    status_cycles = [r["cycle"] for r in env.model.log if r["kind"] == 2]
    assert len(status_cycles) == 4
    assert all(b - a >= 150 for a, b in zip(status_cycles, status_cycles[1:])), (
        status_cycles
    )
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_invalid_descriptors(dut: Any) -> None:
    """Invalid descriptors complete with DONE|ERR and send nothing.

    The cases: length 0, oversize, LAST with no frame open, and a buffer outside
    the aperture or straddling its end. A segment that starts or continues a
    frame is valid (see test_chained_frames).
    """
    env = await _setup(dut, 3)
    env.place(0, BUF + 1, 0)
    env.place(1, BUF + 0x3000, 9217)
    env.place(2, BUF + 0x6000, 100, word1_flags=LAST)
    post_desc(env.mem, RING, 3, 0x1000_0000, 100 | FIRST | LAST)
    post_desc(env.mem, RING, 4, 0xBFFF_FFF0, 100 | FIRST | LAST)
    post_desc(env.mem, RING, 5, BUF + 0x20000, 0 | FIRST | LAST)
    good = env.place(6, BUF + 0xC000 + 17, 77)
    await env.doorbell(7)
    await env.wait_completions(7)
    await env.wait_idle()
    for i in range(6):
        assert desc_status(env.mem, RING, i) == DONE | ERR, (
            f"desc {i}: {desc_status(env.mem, RING, i):#x}"
        )
    assert desc_status(env.mem, RING, 6) == DONE
    assert env.sink.frames == [good]
    assert [c[0] for c in env.completions] == [2] * 6 + [0]
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_chained_frames(dut: Any) -> None:
    """Frames of several segments come out as one frame, byte-exact.

    Segment lengths are random, so most segment ends fall mid-beat; the merge
    stage must carry those bytes into the next segment. Each segment completes
    on its own, and the lines read are exactly each segment's lines.
    """
    env = await _setup(dut, 11, latency=(1, 8), sink_gap=0.3)
    frames: list[bytes] = []
    index = 0
    plan: list[tuple[int, int]] = []
    for _ in range(4):
        segs = env.rng.randrange(2, 4)
        payload = bytearray()
        for s in range(segs):
            length = env.rng.choice([1, 2, 3, 5, 7, 8, 9, 15, 17, 31, 33, 100, 333])
            addr = BUF + 0x10000 + index * 0x800 + env.rng.randrange(64)
            flags = (FIRST if s == 0 else 0) | (LAST if s == segs - 1 else 0)
            payload += env.place(index, addr, length, word1_flags=flags)
            plan.append((addr, length))
            index += 1
        frames.append(bytes(payload))
    await env.doorbell(index)
    await env.wait_completions(index, limit=80000)
    await env.wait_idle()
    assert env.sink.frames == frames
    for i in range(index):
        assert desc_status(env.mem, RING, i) == DONE, (
            f"desc {i}: {desc_status(env.mem, RING, i):#x}"
        )
    assert env.completions == [(0, length) for _, length in plan]
    expected = [line for addr, length in plan for line in _expected_lines(addr, length)]
    assert sorted(env.lines_read()) == sorted(expected)
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_checksum_request_follows_the_first_descriptor(dut: Any) -> None:
    """o_fifo_csum carries {offset/2, start/2, enable} from the FIRST descriptor.

    The request sits in word 1 bits [31:18] (start/2 in [24:18], offset/2 in
    [31:25]); offset 0 means off. Continuation and LAST descriptors carry junk
    in those bits, which the engine must ignore. The request is on a frame's
    first beat even when the first segment ends mid-beat.
    """
    env = await _setup(dut, 21, latency=(1, 6), sink_gap=0.3)
    wanted: list[int] = []
    index = 0
    for start, off, segs in [
        (7, 8, 3),
        (17, 8, 2),
        (0, 0, 2),
        (3, 1, 1),
        (60, 63, 4),
        (0, 0, 1),
    ]:
        request = (off << 8) | (start << 1) | int(off != 0)
        wanted.append(request)
        for s in range(segs):
            length = env.rng.choice([1, 3, 5, 9, 17, 33, 100])
            addr = BUF + 0x10000 + index * 0x800 + env.rng.randrange(64)
            flags = (FIRST if s == 0 else 0) | (LAST if s == segs - 1 else 0)
            if s == 0:
                flags |= (start << 18) | (off << 25)
            else:
                flags |= (
                    env.rng.getrandbits(14) << 18
                )  # junk: must not change the request
            env.place(index, addr, length, word1_flags=flags)
            index += 1
    await env.doorbell(index)
    await env.wait_completions(index, limit=80000)
    await env.wait_idle()
    assert env.sink.first_csum == wanted, (env.sink.first_csum, wanted)
    for i in range(index):
        assert desc_status(env.mem, RING, i) == DONE
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_abort_mid_frame(dut: Any) -> None:
    """A MAC-domain reset mid-frame: DONE|ERR|ABORT, no more beats, the next frame is whole."""
    env = await _setup(dut, 4, sink_gap=0.3)
    env.place(0, BUF + 5, 6000)
    second = env.place(1, BUF + 0x3000 + 9, 150)
    await env.doorbell(2)
    while env.sink.beats < 100:
        await FallingEdge(dut.i_clk)
    dut.i_abort.value = 1
    beats_at_abort = env.sink.beats
    await env.wait_completions(1)
    assert env.sink.beats <= beats_at_abort + 1
    assert env.completions[0][0] & 0b110 == 0b110
    assert desc_status(env.mem, RING, 0) == DONE | ERR | ABORT
    for _ in range(60):
        await FallingEdge(dut.i_clk)
    env.sink.cut_frame()
    dut.i_abort.value = 0
    await env.wait_completions(2)
    assert env.sink.frames == [second]
    assert desc_status(env.mem, RING, 1) == DONE
    assert int(dut.o_head.value) == 2
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_withdrawn_status_write_completes_nothing(dut: Any) -> None:
    """A status write the drain withdrew (an error response) reports no completion.

    It still frees the status-write slot, so the next frame's completion is
    reported.
    """
    env = await _setup(dut, 8, latency=(1, 4))
    env.model.withdraw_status = True
    env.place(0, BUF + 1, 64)
    await env.doorbell(1)
    for _ in range(4000):
        await FallingEdge(dut.i_clk)
        if any(r.get("withdrawn") for r in env.model.log):
            break
    for _ in range(40):
        await FallingEdge(dut.i_clk)
    assert env.completions == [], (
        f"a withdrawn status write completed: {env.completions}"
    )
    env.model.withdraw_status = False
    second = env.place(1, BUF + 0x3000 + 5, 70)
    await env.doorbell(2)
    await env.wait_completions(1)
    assert env.completions == [(0, 70)]
    assert env.sink.frames[-1] == second
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_stop_drains_without_completion(dut: Any) -> None:
    """The RESET drain mid-frame: idle with every read answered, no DONE written."""
    env = await _setup(dut, 5, latency=(10, 30), sink_gap=0.5)
    env.place(0, BUF + 3, 6000)
    await env.doorbell(1)
    while env.sink.beats < 50:
        await FallingEdge(dut.i_clk)
    dut.i_stop.value = 1
    await env.wait_idle(limit=600)
    assert not env.model.pending
    assert env.completions == []
    assert desc_status(env.mem, RING, 0) == 0
    for _ in range(50):
        await FallingEdge(dut.i_clk)
    assert int(dut.o_fifo_valid.value) == 0
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_empty_ring_reads_nothing(dut: Any) -> None:
    """With HEAD == TAIL the engine issues no request at all."""
    env = await _setup(dut, 6)
    for _ in range(300):
        await FallingEdge(dut.i_clk)
    assert env.model.log == []
    assert int(dut.o_idle.value) == 1
    env.stop()


@cocotb.test()
async def test_disable_in_the_admit_cycle_sends_nothing(dut: Any) -> None:
    """A disable in the cycle the engine moves to S_ADMIT cancels the admission.

    Nothing is read or sent and HEAD stays put. After re-enable descriptor 0
    is sent once, then descriptor 1, and HEAD counts both.
    """
    env = await _setup(dut, 9)
    first = env.place(0, BUF + 3, 200)
    second = env.place(1, BUF + 0x3000 + 5, 90)
    await env.doorbell(1)
    # state_q becomes S_ADMIT (1) on a rising edge; clearing the enable at the
    # next falling edge makes the S_ADMIT cycle see it disabled.
    for _ in range(400):
        await FallingEdge(dut.i_clk)
        if int(dut.state_q.value) == 1:
            dut.i_enable.value = 0
            break
    else:
        raise AssertionError("the engine never reached S_ADMIT")
    for _ in range(200):
        await FallingEdge(dut.i_clk)
    assert env.lines_read() == [], "the buffer was read after the disable"
    assert env.sink.beats == 0 and env.completions == []
    assert int(dut.o_head.value) == 0
    dut.i_enable.value = 1
    await env.doorbell(2)
    await env.wait_completions(2)
    await env.wait_idle()
    assert env.sink.frames == [first, second]
    assert desc_status(env.mem, RING, 0) == DONE
    assert desc_status(env.mem, RING, 1) == DONE
    assert int(dut.o_head.value) == 2
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_tx_rate_against_memory_latency(dut: Any) -> None:
    """Characterise the engine's sustained bytes per cycle against a fixed read latency.

    An unconstrained memory model (no gaps, deep acceptance) answers every read after
    the same latency and the sink takes a beat every cycle, so the rate shown is the
    engine's own. The 64-bit datapath tops out at 8 bytes per cycle (6.4 Gb/s at 100 MHz).
    """
    rates = {}
    for latency in (8, 24, 48, 96):
        env = await _setup(dut, 40 + latency, latency=(latency, latency), sink_gap=0.0)
        env.model.gap = 0.0
        env.model.cap = 6  # the DMA front-end admits at most SIDE_CAP (6) per engine
        env.sink.stop()  # a sink that takes one beat every cycle, not every other cycle
        dut.i_fifo_ready.value = 1
        frames = 6
        for i in range(frames):
            env.place(i, BUF + i * 0x3000, 1514)
        start = cocotb.utils.get_sim_time("ns")
        await env.doorbell(frames)
        await env.wait_completions(frames, limit=200000)
        elapsed = (cocotb.utils.get_sim_time("ns") - start) / 10.0
        rates[latency] = frames * 1514 / elapsed
        env.stop()
        dut.i_rst.value = 1
        for _ in range(4):
            await RisingEdge(dut.i_clk)
    dut._log.info(
        "TX engine bytes/cycle by read latency: "
        + ", ".join(
            f"{lat} cycles -> {r:.2f} B/cycle ({r * 0.8:.2f} Gb/s at 100 MHz)"
            for lat, r in rates.items()
        )
    )


def _param_words(pkt: Any) -> tuple[int, int]:
    """Return the two words of a parameter descriptor for a packet."""
    cfg = pkt.config()
    word0 = cfg["mss"] | (cfg["payload"] << 16)
    word1 = (
        (1 << 18)
        | (cfg["l4off2"] << 19)
        | (cfg["tcphl4"] << 26)
        | (cfg["ip6"] << 30)
        | (cfg["vlan"] << 31)
    )
    return word0, word1


@cocotb.test()
async def test_segment_parameter_descriptor(dut: Any) -> None:
    """A parameter descriptor ahead of a frame turns it into TCP segments; later frames are plain.

    The parameter descriptor completes with DONE and no error and sends nothing. The frame that follows it is
    cut at the MSS with exact headers whatever the segment boundaries of its chain. The frame
    after that has no parameter descriptor, so it passes through with the checksum request of its own FIRST
    descriptor.
    """
    from cocotb_tests.nic.test_nic_tx_segment import Packet

    env = await _setup(dut, 31, latency=(1, 8), sink_gap=0.2)
    rng = env.rng
    expected: list[bytes] = []
    csums: list[int] = []
    index = 0
    done = 0
    cases: list[dict[str, Any]] = [
        dict(payload_len=3000, mss=1000, splits=lambda h: [h, 3000]),
        dict(
            ip6=True,
            vlan=True,
            tcp_opt_words=2,
            payload_len=2500,
            mss=777,
            splits=lambda h: [37, h - 37 + 5, 400],
        ),
        dict(ip_opt_words=2, payload_len=1999, mss=1460, splits=lambda h: [h + 3, 7]),
    ]
    for case in cases:
        splits = case.pop("splits")
        pkt = Packet(rng, **case)
        w0, w1 = _param_words(pkt)
        post_desc(env.mem, RING, index % ENTRIES, w0, w1)
        first = index
        index += 1
        cuts = splits(pkt.hdr_len)
        rest = len(pkt.frame) - sum(cuts)
        cuts = [x for x in cuts if x] + ([rest] if rest > 0 else [])
        pos = 0
        for k, n in enumerate(cuts):
            if k == len(cuts) - 1:
                n = len(pkt.frame) - pos
            addr = BUF + 0x10000 + (index % ENTRIES) * 0x4000 + rng.randrange(64)
            env.mem.write_bytes(addr, pkt.frame[pos : pos + n])
            flags = (FIRST if k == 0 else 0) | (LAST if k == len(cuts) - 1 else 0)
            post_desc(env.mem, RING, index % ENTRIES, addr, n | flags)
            pos += n
            index += 1
        assert pos == len(pkt.frame)
        await env.doorbell(index)
        done = index
        await env.wait_completions(done, limit=200000)
        segs = pkt.segments()
        # DONE means the buffers were read; the stage then still has segments to send.
        for _ in range(100000):
            if len(env.sink.frames) >= len(expected) + len(segs):
                break
            await FallingEdge(dut.i_clk)
        await env.wait_idle()
        for i in range(first, index):
            assert desc_status(env.mem, RING, i % ENTRIES) == DONE, f"desc {i}"
        expected += segs
        csums += [pkt.csum_request()] * len(segs)
        assert env.sink.frames == expected, (
            f"case {case}: {len(env.sink.frames)} frames"
        )
        assert env.sink.first_csum == csums
    # A frame with no parameter descriptor passes untouched, with its own checksum request.
    body = bytes(rng.getrandbits(8) for _ in range(300))
    addr = BUF + 0x10000 + (index % ENTRIES) * 0x4000
    env.mem.write_bytes(addr, body)
    request = (5 << 25) | (17 << 18)
    post_desc(env.mem, RING, index % ENTRIES, addr, 300 | FIRST | LAST | request)
    index += 1
    await env.doorbell(index)
    await env.wait_completions(index, limit=200000)
    await env.wait_idle()
    assert env.sink.frames == expected + [body]
    assert env.sink.first_csum[-1] == (5 << 8) | (17 << 1) | 1
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_rejected_segment_aborts_the_open_frame(dut: Any) -> None:
    """A rejected segment inside a frame aborts it: no splice, an abort beat, a counted abort.

    The first frame's bytes already in the FIFO are closed by an abort beat (the MAC drops the
    frame); the segment that was rejected completes with DONE|ERR|ABORT; the next frame is whole.
    """
    env = await _setup(dut, 21)
    first = env.place(0, BUF + 0x1000, 100, word1_flags=FIRST)
    post_desc(env.mem, RING, 1, 0x1000_0000, 40)  # a continuation outside the aperture
    good = env.place(2, BUF + 0x2000 + 3, 77)
    await env.doorbell(3)
    await env.wait_completions(3)
    await env.wait_idle()
    for _ in range(40):
        await FallingEdge(dut.i_clk)
    assert desc_status(env.mem, RING, 0) == DONE
    assert desc_status(env.mem, RING, 1) == DONE | ERR | ABORT
    assert desc_status(env.mem, RING, 2) == DONE
    assert env.sink.frames == [good]
    assert len(env.sink.aborted) == 1
    cut = env.sink.aborted[0]
    assert len(cut) % 8 == 1  # whole beats, then the one-byte abort beat
    assert first.startswith(cut[: len(cut) - 1])
    assert [c[0] for c in env.completions] == [0, 6, 0]
    assert not env.model.violations, env.model.violations
    env.stop()


@cocotb.test()
async def test_rejected_segment_with_nothing_downstream(dut: Any) -> None:
    """When the open frame has put no beat in the FIFO yet, the flush alone suffices."""
    env = await _setup(dut, 22)
    env.place(0, BUF + 0x1000, 5, word1_flags=FIRST)  # less than one beat
    post_desc(env.mem, RING, 1, BUF + 0x4000, 0)  # a zero-length continuation
    good = env.place(2, BUF + 0x2000, 60)
    await env.doorbell(3)
    await env.wait_completions(3)
    await env.wait_idle()
    for _ in range(40):
        await FallingEdge(dut.i_clk)
    assert desc_status(env.mem, RING, 1) == DONE | ERR | ABORT
    assert env.sink.frames == [good] and not env.sink.aborted
    env.stop()


@cocotb.test()
async def test_long_continuation_segments(dut: Any) -> None:
    """Segments after a frame's first take up to 65535 bytes; a first segment stays at 9216."""
    env = await _setup(dut, 23, latency=(1, 4), sink_gap=0.05)
    head = env.place(0, BUF + 0x1000, 54, word1_flags=FIRST)
    body = env.place(1, BUF + 0x10000 + 5, 40000, word1_flags=0)
    tail = env.place(2, BUF + 0x40000, 65535 - 2, word1_flags=LAST)
    await env.doorbell(3)
    await env.wait_completions(3, limit=400000)
    await env.wait_idle(limit=400000)
    for _ in range(40):
        await FallingEdge(dut.i_clk)
    assert env.sink.frames == [head + body + tail]
    assert [desc_status(env.mem, RING, i) for i in range(3)] == [DONE, DONE, DONE]
    # A first segment over 9216 is still refused.
    env.place(3, BUF + 0x60000, 9217)
    await env.doorbell(4)
    await env.wait_completions(4)
    assert desc_status(env.mem, RING, 3) == DONE | ERR
    assert not env.model.violations, env.model.violations
    env.stop()

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

"""Unit tests for nic_byte_pack (hw/rtl/peripherals/nic/nic_byte_pack.sv).

The byte-level invariant: input byte j of the frame lands at address A + j
for j below min(frame length, limit), and no other strobe is set; every
line is issued once. Swept over every start offset in a two-line window,
frame lengths 1..100 and a set of long ones, a byte limit below the length
(truncation), random stalls on the write output, and the review's
falsifiers: offset 31 with length 2 (two one-byte writes), a limit of 1
under a 60-byte frame, length 33, offset 63 with length 2, and a stall at a
line crossing that coincides with the last beat.
The input queue must sustain one beat per cycle and discard queued beats
along with a stalled write on flush or reset.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

LINE = 32
BASE = 0x8000_0000


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_flush,
        dut.i_start,
        dut.i_addr,
        dut.i_limit,
        dut.i_beat_valid,
        dut.i_beat_data,
        dut.i_beat_bytes,
        dut.i_beat_last,
        dut.i_wr_ready,
    ):
        sig.value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.i_clk)


async def _collect(
    dut: Any,
    writes: list[tuple[int, int, int]],
    gap_prob: float,
    rng: random.Random,
    stop: list[bool],
) -> None:
    """Accept line writes with random ready gaps; record (addr, wdata, wstrb)."""
    while not stop[0]:
        await FallingEdge(dut.i_clk)
        if int(dut.o_wr_valid.value) == 1 and rng.random() >= gap_prob:
            dut.i_wr_ready.value = 1
            writes.append(
                (
                    int(dut.o_wr_addr.value),
                    int(dut.o_wr_wdata.value),
                    int(dut.o_wr_wstrb.value),
                )
            )
            await RisingEdge(dut.i_clk)
            await FallingEdge(dut.i_clk)
            dut.i_wr_ready.value = 0
        else:
            dut.i_wr_ready.value = 0


async def _run_frame(
    dut: Any,
    addr: int,
    length: int,
    limit: int,
    payload: bytes,
    rng: random.Random,
    gap_prob: float = 0.3,
    beat_gap: float = 0.2,
    max_beat_wait: int = 2000,
) -> list[tuple[int, int, int]]:
    writes: list[tuple[int, int, int]] = []
    stop = [False]
    coll = cocotb.start_soon(_collect(dut, writes, gap_prob, rng, stop))
    dut.i_start.value = 1
    dut.i_addr.value = addr
    dut.i_limit.value = limit
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 0
    pos = 0
    while pos < length:
        n = min(8, length - pos)
        while rng.random() < beat_gap:
            await FallingEdge(dut.i_clk)
        chunk = payload[pos : pos + n] + bytes(8 - n)
        dut.i_beat_data.value = int.from_bytes(chunk, "little")
        dut.i_beat_bytes.value = n
        dut.i_beat_last.value = 1 if pos + n == length else 0
        dut.i_beat_valid.value = 1
        for _ in range(max_beat_wait):
            await RisingEdge(dut.i_clk)
            if int(dut.o_beat_ready.value) == 1:
                break
        else:
            raise AssertionError("beat never accepted")
        await FallingEdge(dut.i_clk)
        dut.i_beat_valid.value = 0
        pos += n
    # Wait for the packer to finish.
    for _ in range(2000):
        await FallingEdge(dut.i_clk)
        if int(dut.o_busy.value) == 0:
            break
    else:
        raise AssertionError("packer never went idle")
    for _ in range(4):
        await FallingEdge(dut.i_clk)
    stop[0] = True
    await coll
    return writes


def _check(
    addr: int,
    length: int,
    limit: int,
    payload: bytes,
    writes: list[tuple[int, int, int]],
) -> None:
    kept = min(length, limit)
    expected = {addr + j: payload[j] for j in range(kept)}
    seen: dict[int, int] = {}
    lines = [w[0] for w in writes]
    assert len(lines) == len(
        set(lines)
    ), f"a line was issued twice: {[hex(a) for a in lines]}"
    for line_addr, wdata, wstrb in writes:
        assert line_addr % LINE == 0
        assert wstrb != 0, f"empty write at {line_addr:#x}"
        for b in range(LINE):
            if (wstrb >> b) & 1:
                a = line_addr + b
                assert a not in seen, f"byte {a:#x} written twice"
                seen[a] = (wdata >> (8 * b)) & 0xFF
    assert seen.keys() == expected.keys(), (
        f"strobed bytes differ: extra {sorted(hex(a) for a in seen.keys() - expected.keys())[:6]} "
        f"missing {sorted(hex(a) for a in expected.keys() - seen.keys())[:6]}"
    )
    for a, v in expected.items():
        assert seen[a] == v, f"byte {a:#x}: got {seen[a]:#x} expected {v:#x}"


@cocotb.test()
async def test_every_offset_short_lengths(dut: Any) -> None:
    """Every start offset in the two-line window with lengths 1..100."""
    await _setup(dut)
    rng = random.Random(1)
    for offset in range(64):
        for length in list(range(1, 20)) + [31, 32, 33, 40, 63, 64, 65, 100]:
            addr = BASE + 0x1000 * (offset + 1) + offset
            payload = bytes(rng.getrandbits(8) for _ in range(length))
            writes = await _run_frame(
                dut, addr, length, 0xFFFF, payload, rng, gap_prob=0.1, beat_gap=0.0
            )
            _check(addr, length, 0xFFFF, payload, writes)


@cocotb.test()
async def test_long_frames_with_stalls(dut: Any) -> None:
    """Jumbo-sized frames at odd offsets under heavy output stalls."""
    await _setup(dut)
    rng = random.Random(2)
    for offset, length in [(2, 1518), (31, 1500), (17, 9216), (0, 4096)]:
        addr = BASE + 0x20000 + offset
        payload = bytes(rng.getrandbits(8) for _ in range(length))
        writes = await _run_frame(
            dut, addr, length, 0xFFFF, payload, rng, gap_prob=0.6, beat_gap=0.3
        )
        _check(addr, length, 0xFFFF, payload, writes)


@cocotb.test()
async def test_truncation(dut: Any) -> None:
    """Bytes beyond the limit are dropped; the last kept byte closes the last write."""
    await _setup(dut)
    rng = random.Random(3)
    for offset, length, limit in [
        (31, 60, 1),
        (2, 1518, 100),
        (5, 200, 64),
        (30, 40, 3),
        (0, 9, 8),
    ]:
        addr = BASE + 0x40000 + offset
        payload = bytes(rng.getrandbits(8) for _ in range(length))
        writes = await _run_frame(dut, addr, length, limit, payload, rng)
        _check(addr, length, limit, payload, writes)


@cocotb.test()
async def test_review_falsifiers(dut: Any) -> None:
    """Offset 31 length 2, length 33, offset 63 length 2, a stall at the crossing with last."""
    await _setup(dut)
    rng = random.Random(4)
    cases = [(31, 2), (31, 33), (63, 2), (24, 9), (25, 8), (57, 8), (56, 8)]
    for offset, length in cases:
        addr = BASE + 0x60000 + offset
        payload = bytes(rng.getrandbits(8) for _ in range(length))
        writes = await _run_frame(
            dut, addr, length, 0xFFFF, payload, rng, gap_prob=0.8, beat_gap=0.0
        )
        _check(addr, length, 0xFFFF, payload, writes)
        if (offset, length) == (31, 2):
            assert len(writes) == 2 and all(bin(w[2]).count("1") == 1 for w in writes)


@cocotb.test()
async def test_sustained_beat_rate(dut: Any) -> None:
    """Every beat fires on its first cycle when line writes keep flowing."""
    await _setup(dut)
    rng = random.Random(5)
    for offset in (0, 1, 7, 31):
        addr = BASE + 0x80000 + offset
        payload = bytes(rng.getrandbits(8) for _ in range(1024))
        writes = await _run_frame(
            dut,
            addr,
            len(payload),
            0xFFFF,
            payload,
            rng,
            gap_prob=0.0,
            beat_gap=0.0,
            max_beat_wait=1,
        )
        _check(addr, len(payload), 0xFFFF, payload, writes)


@cocotb.test()
async def test_flush_and_reset_discard_queued_beats(dut: Any) -> None:
    """A full input queue and stalled line leave no data behind after flush/reset."""
    await _setup(dut)
    rng = random.Random(6)
    for control in (dut.i_flush, dut.i_rst):
        dut.i_start.value = 1
        dut.i_addr.value = BASE + 0xA001F
        dut.i_limit.value = 512
        dut.i_wr_ready.value = 0
        await FallingEdge(dut.i_clk)
        dut.i_start.value = 0
        dut.i_beat_valid.value = 1
        dut.i_beat_bytes.value = 8
        dut.i_beat_last.value = 0
        for beat in range(20):
            dut.i_beat_data.value = 0xA5A5_A5A5_A5A5_A500 + beat
            await RisingEdge(dut.i_clk)
            blocked = int(dut.o_beat_ready.value) == 0
            await FallingEdge(dut.i_clk)
            if blocked:
                break
        else:
            raise AssertionError("input never backpressured behind stalled writes")
        dut.i_beat_valid.value = 0
        assert int(dut.o_wr_valid.value) == 1
        assert int(dut.o_busy.value) == 1
        control.value = 1
        await FallingEdge(dut.i_clk)
        control.value = 0
        dut.i_wr_ready.value = 1
        for _ in range(6):
            assert int(dut.o_busy.value) == 0, "abandoned beats kept the packer busy"
            assert int(dut.o_wr_valid.value) == 0, "an abandoned write escaped"
            assert int(dut.o_beat_ready.value) == 0, "a frame start is still required"
            await FallingEdge(dut.i_clk)
        addr = BASE + 0xC001F
        payload = bytes(rng.getrandbits(8) for _ in range(99))
        writes = await _run_frame(dut, addr, len(payload), 0xFFFF, payload, rng)
        _check(addr, len(payload), 0xFFFF, payload, writes)

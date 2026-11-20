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

"""Unit bench for axi_register_slice and axil_register_slice.

Verifies zero combinational feedthrough across every channel, full
one-beat-per-cycle streaming throughput, random upstream/downstream stalls
across all five channels concurrently, payload integrity, and synchronous
reset clearing.
"""

from collections import deque
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


PERIOD_PS = 3000

AXI4_CHANNELS: tuple[tuple[str, str, str, tuple[str, ...]], ...] = (
    (
        "aw",
        "s",
        "m",
        (
            "awid",
            "awaddr",
            "awlen",
            "awsize",
            "awburst",
            "awlock",
            "awcache",
            "awprot",
            "awqos",
        ),
    ),
    ("w", "s", "m", ("wdata", "wstrb", "wlast")),
    ("b", "m", "s", ("bid", "bresp")),
    (
        "ar",
        "s",
        "m",
        (
            "arid",
            "araddr",
            "arlen",
            "arsize",
            "arburst",
            "arlock",
            "arcache",
            "arprot",
            "arqos",
        ),
    ),
    ("r", "m", "s", ("rid", "rdata", "rresp", "rlast")),
)

AXIL_CHANNELS: tuple[tuple[str, str, str, tuple[str, ...]], ...] = (
    ("aw", "s", "m", ("awaddr", "awprot")),
    ("w", "s", "m", ("wdata", "wstrb")),
    ("b", "m", "s", ("bresp",)),
    ("ar", "s", "m", ("araddr", "arprot")),
    ("r", "m", "s", ("rdata", "rresp")),
)


def _channels_for(dut: Any) -> tuple[tuple[str, str, str, tuple[str, ...]], ...]:
    return AXI4_CHANNELS if hasattr(dut, "i_s_awid") else AXIL_CHANNELS


def _idle_inputs(dut: Any) -> None:
    for sig in dut:
        if sig._name.startswith("i_") and sig._name not in ("i_clk", "i_rst"):
            sig.value = 0


async def _reset(dut: Any) -> None:
    _idle_inputs(dut)
    dut.i_rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)


@cocotb.test()
async def zero_comb_feedthrough_and_reset(dut: Any) -> None:
    """Confirm no combinational path from inputs to outputs and clean reset."""
    Clock(dut.i_clk, PERIOD_PS, unit="ps").start()
    channels = _channels_for(dut)
    await _reset(dut)

    # After reset release edge, READY rises on the following edge; toggle inputs
    # combinatorially without clocking and confirm every output stays steady.
    await FallingEdge(dut.i_clk)
    for ch, src, dst, fields in channels:
        v_before = int(getattr(dut, f"o_{dst}_{ch}valid").value)
        r_before = int(getattr(dut, f"o_{src}_{ch}ready").value)
        assert v_before == 0, f"{ch} valid high after reset"
        getattr(dut, f"i_{src}_{ch}valid").value = 1
        getattr(dut, f"i_{dst}_{ch}ready").value = 1
        for f in fields:
            sig = getattr(dut, f"i_{src}_{f}")
            sig.value = (1 << len(sig)) - 1
        await ReadOnly()
        assert int(getattr(dut, f"o_{dst}_{ch}valid").value) == v_before, (
            f"comb valid feedthrough on {ch}"
        )
        assert int(getattr(dut, f"o_{src}_{ch}ready").value) == r_before, (
            f"comb ready feedthrough on {ch}"
        )
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)

    # Reset mid-flight must drop buffered VALID and READY on the next edge.
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await ReadOnly()
    for ch, src, dst, _ in channels:
        assert int(getattr(dut, f"o_{dst}_{ch}valid").value) == 0
        assert int(getattr(dut, f"o_{src}_{ch}ready").value) == 0


@cocotb.test()
async def full_rate_streaming_and_random_stalls(dut: Any) -> None:
    """Stream 1 beat/cycle with zero bubbles, then stress all channels with stalls."""
    Clock(dut.i_clk, PERIOD_PS, unit="ps").start()
    channels = _channels_for(dut)
    rng = random.Random(20261119)
    await _reset(dut)

    # Phase 1: full-throughput streaming (20 beats in 20 consecutive push cycles).
    stream_beats = 20
    expected: dict[str, deque[tuple[int, ...]]] = {ch: deque() for ch, *_ in channels}
    sent: dict[str, int] = {ch: 0 for ch, *_ in channels}
    got: dict[str, int] = {ch: 0 for ch, *_ in channels}
    widths = {
        (ch, f): len(getattr(dut, f"i_{src}_{f}"))
        for ch, src, _, fields in channels
        for f in fields
    }
    next_payload: dict[str, tuple[int, ...]] = {}
    for ch, _, _, fields in channels:
        next_payload[ch] = tuple(rng.randrange(1 << widths[(ch, f)]) for f in fields)

    await RisingEdge(dut.i_clk)  # READY is now high on every channel.
    for cycle in range(stream_beats + 4):
        await FallingEdge(dut.i_clk)
        for ch, src, dst, fields in channels:
            drive = sent[ch] < stream_beats
            getattr(dut, f"i_{src}_{ch}valid").value = int(drive)
            getattr(dut, f"i_{dst}_{ch}ready").value = 1
            for f, val in zip(fields, next_payload[ch], strict=True):
                getattr(dut, f"i_{src}_{f}").value = val
        await ReadOnly()
        for ch, src, dst, fields in channels:
            s_ready = int(getattr(dut, f"o_{src}_{ch}ready").value)
            if sent[ch] < stream_beats:
                assert s_ready == 1, f"{ch} stalled at stream cycle {cycle}"
                expected[ch].append(next_payload[ch])
                sent[ch] += 1
                next_payload[ch] = tuple(
                    rng.randrange(1 << widths[(ch, f)]) for f in fields
                )
            if int(getattr(dut, f"o_{dst}_{ch}valid").value):
                obs = tuple(int(getattr(dut, f"o_{dst}_{f}").value) for f in fields)
                assert obs == expected[ch].popleft(), f"{ch} payload mismatch in stream"
                got[ch] += 1
        await RisingEdge(dut.i_clk)
    for ch, *_ in channels:
        assert got[ch] == stream_beats and not expected[ch], (ch, got[ch])

    # Phase 2: 200 random-stall beats per channel concurrently, verifying hold rules.
    target = 200
    expected = {ch: deque() for ch, *_ in channels}
    sent = {ch: 0 for ch, *_ in channels}
    got = {ch: 0 for ch, *_ in channels}
    held_valid: dict[str, bool] = {ch: False for ch, *_ in channels}
    held_payload: dict[str, tuple[int, ...] | None] = {ch: None for ch, *_ in channels}
    in_valid: dict[str, bool] = {ch: False for ch, *_ in channels}
    in_payload: dict[str, tuple[int, ...]] = {
        ch: tuple(rng.randrange(1 << widths[(ch, f)]) for f in fields)
        for ch, _, _, fields in channels
    }

    for _ in range(target * 6):
        if all(got[ch] == target for ch, *_ in channels):
            break
        await FallingEdge(dut.i_clk)
        out_ready: dict[str, bool] = {}
        for ch, src, dst, fields in channels:
            if not in_valid[ch] and sent[ch] < target and rng.randrange(3) != 0:
                in_valid[ch] = True
                in_payload[ch] = tuple(
                    rng.randrange(1 << widths[(ch, f)]) for f in fields
                )
            out_ready[ch] = rng.randrange(3) != 0
            getattr(dut, f"i_{src}_{ch}valid").value = int(in_valid[ch])
            getattr(dut, f"i_{dst}_{ch}ready").value = int(out_ready[ch])
            for f, val in zip(fields, in_payload[ch], strict=True):
                getattr(dut, f"i_{src}_{f}").value = val
        await ReadOnly()
        for ch, src, dst, fields in channels:
            o_v = bool(int(getattr(dut, f"o_{dst}_{ch}valid").value))
            o_r = bool(int(getattr(dut, f"o_{src}_{ch}ready").value))
            obs = tuple(int(getattr(dut, f"o_{dst}_{f}").value) for f in fields)
            if held_valid[ch]:
                assert o_v, f"{ch} dropped VALID while stalled"
                assert obs == held_payload[ch], f"{ch} mutated payload while stalled"
            if in_valid[ch] and o_r:
                expected[ch].append(in_payload[ch])
                sent[ch] += 1
                in_valid[ch] = False
            if o_v and out_ready[ch]:
                assert obs == expected[ch].popleft(), f"{ch} payload mismatch"
                got[ch] += 1
                held_valid[ch] = False
                held_payload[ch] = None
            else:
                held_valid[ch] = o_v
                held_payload[ch] = obs if o_v else None
        await RisingEdge(dut.i_clk)

    for ch, *_ in channels:
        assert got[ch] == target and not expected[ch], (ch, got[ch], len(expected[ch]))

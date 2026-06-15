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

"""Unit tests for the high-address fetch_provider (fetch buffer, fills).

The bench plays both of the provider's neighbours: the core (driving i_pc
like pc_controller would and consuming valid windows) and the L1I line port
slave (accepting fill requests and returning patterned lines). Covered: low
addresses staying out of the provider, DDR fills with the sequential walk
across a line boundary (straddle + next-line prefetch), ask retargeting when a
redirect lands while unserved, and the invalidate-discard of an in-flight fill.
"""

import importlib.util
from pathlib import Path
from types import ModuleType
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

CLOCK_PERIOD_NS = 10
LINE_BYTES = 32
DDR_BASE = 0x8000_0000
TIMEOUT = 2_000


def _load_generator() -> ModuleType:
    """Import the offline predecode generator as the sideband golden model."""
    path = (
        Path(__file__).resolve().parents[3]
        / "sw"
        / "common"
        / "generate_imem_predecode_init.py"
    )
    spec = importlib.util.spec_from_file_location("generate_imem_predecode_init", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_GENERATOR = _load_generator()


def _word_at(addr: int) -> int:
    """Deterministic 32-bit pattern for any word address."""
    return (addr * 0x01000193 + 0x5BD1E995) & 0xFFFF_FFFF


def _line_at(line_addr: int) -> int:
    """Build the 256-bit line whose byte address is line_addr."""
    value = 0
    for w in range(LINE_BYTES // 4):
        value |= _word_at(line_addr + 4 * w) << (32 * w)
    return value


def _clear_inputs(dut: Any) -> None:
    dut.i_pc.value = 0
    dut.i_fetch_replay_consume.value = 0
    dut.i_pipeline_stall.value = 0
    dut.i_line_req_ready.value = 0
    dut.i_line_resp_valid.value = 0
    dut.i_line_resp_rdata.value = 0
    dut.i_invalidate.value = 0


async def _setup(dut: Any) -> None:
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.i_clk)


async def _line_slave(dut: Any, latency: int, log: list[int]) -> None:
    """Single-outstanding line-port slave returning patterned lines."""
    while True:
        await FallingEdge(dut.i_clk)
        if int(dut.o_line_req_valid.value) == 1:
            addr = int(dut.o_line_req_addr.value)
            log.append(addr)
            dut.i_line_req_ready.value = 1
            await FallingEdge(dut.i_clk)
            dut.i_line_req_ready.value = 0
            for _ in range(latency):
                await FallingEdge(dut.i_clk)
            dut.i_line_resp_valid.value = 1
            dut.i_line_resp_rdata.value = _line_at(addr)
            await FallingEdge(dut.i_clk)
            dut.i_line_resp_valid.value = 0


async def _wait_valid(dut: Any) -> None:
    for _ in range(TIMEOUT):
        await FallingEdge(dut.i_clk)
        if int(dut.o_instr_valid.value) == 1:
            return
    raise AssertionError("o_instr_valid never asserted")


async def _wait_window(dut: Any, addr: int) -> None:
    """Wait until the valid window for addr is presented, then verify it.

    Used for initial alignment after a pc jump: per the contract, valid
    cycles for the PREVIOUS owed ask (e.g. the post-reset ask 0, or the
    stale post-redirect window) may pass first -- the core squashes those
    with its holdoff; the bench just skips them.
    """
    base = addr & ~0x3
    want0 = _word_at(base)
    want1 = _word_at(base + 4)
    want = (want1 << 32) | want0
    for _ in range(TIMEOUT):
        await FallingEdge(dut.i_clk)
        if int(dut.o_instr_valid.value) == 1 and int(dut.o_instr.value) == want:
            _check_window(dut, addr)
            return
    raise AssertionError(f"window for 0x{addr:08x} never presented")


def _check_window(dut: Any, addr: int) -> None:
    """Assert the presented window is the two words at addr (word-aligned)."""
    base = addr & ~0x3
    want0 = _word_at(base)
    want1 = _word_at(base + 4)
    got = int(dut.o_instr.value)
    assert got == ((want1 << 32) | want0), (
        f"window @0x{addr:08x}: got 0x{got:016x} "
        f"want 0x{((want1 << 32) | want0):016x}"
    )
    sb = int(dut.o_instr_sideband.value)
    want_sb = (_GENERATOR.make_sideband(want1) << 8) | _GENERATOR.make_sideband(want0)
    assert sb == want_sb, f"sideband @0x{addr:08x}: got 0x{sb:04x} want 0x{want_sb:04x}"
    assert int(dut.o_instr_bank_sel_r.value) == ((base >> 2) & 1)


@cocotb.test()
async def test_low_addresses_stay_idle(dut: Any) -> None:
    """Low BRAM fetches are handled outside this provider."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=2, log=reqs))

    for pc in (0x100, 0x104, 0x108, 0x10C, 0x200):
        dut.i_pc.value = pc
        await FallingEdge(dut.i_clk)
        assert int(dut.o_instr_valid.value) == 0
        assert int(dut.o_line_req_valid.value) == 0

    assert reqs == []


@cocotb.test()
async def test_ddr_fill_walk_and_straddle(dut: Any) -> None:
    """DDR quadrant: fill, sequential walk, line straddle, prefetch."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=6, log=reqs))

    await FallingEdge(dut.i_clk)
    dut.i_pc.value = DDR_BASE
    await _wait_window(dut, DDR_BASE)
    # The straddle rule requires word DDR_BASE+4 too (same line here), and
    # the prefetch should already be chasing the next line.
    assert reqs[0] == DDR_BASE

    # Walk the whole first line; the boundary window (offset 0x1C) needs the
    # prefetched second line and must simply stay valid once it arrives.
    pc = DDR_BASE
    for _ in range(7):
        pc += 4
        dut.i_pc.value = pc
        await _wait_valid(dut)
        _check_window(dut, pc)
    assert DDR_BASE + 32 in reqs  # next-line prefetch happened

    # Continue into the second line and the third (prefetch keeps ahead).
    for _ in range(8):
        pc += 4
        dut.i_pc.value = pc
        await _wait_valid(dut)
        _check_window(dut, pc)
    assert DDR_BASE + 64 in reqs


@cocotb.test()
async def test_redirect_while_unserved_retargets(dut: Any) -> None:
    """A redirect during a miss abandons the old ask for the new target."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=20, log=reqs))

    await FallingEdge(dut.i_clk)
    dut.i_pc.value = DDR_BASE  # miss; fill takes 20+ cycles
    for _ in range(5):
        await FallingEdge(dut.i_clk)
    for _ in range(3):
        await FallingEdge(dut.i_clk)
        assert int(dut.o_instr_valid.value) == 0

    # Redirect while unserved: the core moves the PC once (then holds).
    target = DDR_BASE + 0x1000
    dut.i_pc.value = target
    await _wait_window(dut, target)
    assert DDR_BASE in reqs and target in reqs


@cocotb.test()
async def test_invalidate_discards_inflight_fill(dut: Any) -> None:
    """i_invalidate mid-fill: the completing line must not validate a slot."""
    await _setup(dut)
    reqs: list[int] = []
    cocotb.start_soon(_line_slave(dut, latency=12, log=reqs))

    await FallingEdge(dut.i_clk)
    dut.i_pc.value = DDR_BASE
    # Let the fill launch, then invalidate mid-flight.
    for _ in range(4):
        await FallingEdge(dut.i_clk)
    assert len(reqs) >= 1
    dut.i_invalidate.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_invalidate.value = 0

    # The discarded fill completes; valid may only come from a FRESH fill of
    # the line, i.e. a second request for DDR_BASE must be observed before
    # (or by the time) the window turns valid.
    await _wait_valid(dut)
    _check_window(dut, DDR_BASE)
    assert reqs.count(DDR_BASE) >= 2, f"expected a refill of the line, reqs={reqs}"

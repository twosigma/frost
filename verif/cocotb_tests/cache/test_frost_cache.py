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

"""Unit tests for the frost_cache hierarchy (frost_cache_test_harness DUT).

The harness wires the same backside topology the CPU integration uses:
frost_cache_hierarchy (L1, optional L2) -> line_port_axi_bridge ->
axi_behavioral_memory. The bench drives raw line-port transactions and checks
every read against a byte-granular reference model. The harness defaults make
the caches tiny (L1 1 KiB / L2 4 KiB) so evictions and thrash are constantly
exercised; the registry runs the same tests in both board shapes via
-GHAS_L2={0,1}.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

CLOCK_PERIOD_NS = 10
LINE_BYTES = 32
BASE_ADDR = 0x8000_0000

# Address window for the randomized tests: 1024 lines = 32 KiB, comfortably
# larger than L1 (1 KiB) and L2 (4 KiB) so both levels evict constantly.
WINDOW_LINES = 1024

# Each test gets a disjoint 256 KiB region: the behavioral DDR persists across
# the in-run resets between cocotb tests (like real DDR), so a fresh
# zero-default reference model is only valid in untouched address space.
SMOKE_BASE = BASE_ADDR + 0x00000
PARTIAL_BASE = BASE_ADDR + 0x40000
EVICT_BASE = BASE_ADDR + 0x80000
STROBE_BASE = BASE_ADDR + 0xC0000
THRASH_BASE = BASE_ADDR + 0x100000
RANDOM_BASE = BASE_ADDR + 0x140000

RESP_TIMEOUT_CYCLES = 20_000
SWEEP_TIMEOUT_CYCLES = 200_000


def _clear_inputs(dut: Any) -> None:
    dut.i_up_req_valid.value = 0
    dut.i_up_req_write.value = 0
    dut.i_up_req_addr.value = 0
    dut.i_up_req_wdata.value = 0
    dut.i_up_req_wstrb.value = 0


async def _setup(dut: Any) -> None:
    """Start the clock, reset, and wait out the tag-invalidate sweep."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(SWEEP_TIMEOUT_CYCLES):
        await FallingEdge(dut.i_clk)
        if int(dut.o_up_req_ready.value) == 1:
            return
    raise AssertionError("cache never became ready after reset (sweep stuck?)")


async def _line_transaction(
    dut: Any, *, write: bool, addr: int, wdata: int = 0, wstrb: int = 0
) -> int:
    """Run one line transaction; returns the 256-bit read data (0 for writes).

    Inputs are driven at falling edges so they are stable across the rising
    edge that samples them; o_up_req_ready / o_up_resp_valid are likewise
    sampled mid-cycle at falling edges.
    """
    await FallingEdge(dut.i_clk)
    dut.i_up_req_valid.value = 1
    dut.i_up_req_write.value = 1 if write else 0
    dut.i_up_req_addr.value = addr
    dut.i_up_req_wdata.value = wdata
    dut.i_up_req_wstrb.value = wstrb

    # Hold valid until a cycle where ready is high: that rising edge fires.
    for _ in range(RESP_TIMEOUT_CYCLES):
        if int(dut.o_up_req_ready.value) == 1:
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError(f"request never accepted (addr=0x{addr:08x})")

    await FallingEdge(dut.i_clk)  # now in the cycle after the fire
    dut.i_up_req_valid.value = 0

    for _ in range(RESP_TIMEOUT_CYCLES):
        if int(dut.o_up_resp_valid.value) == 1:
            return int(dut.o_up_resp_rdata.value)
        await FallingEdge(dut.i_clk)
    raise AssertionError(f"no response (addr=0x{addr:08x}, write={write})")


class ReferenceModel:
    """Byte-granular reference: backing memory defaults to zero."""

    def __init__(self) -> None:
        """Start with an empty (all-zero) backing store."""
        self._bytes: dict[int, int] = {}

    def write_line(self, addr: int, wdata: int, wstrb: int) -> None:
        """Apply a strobed 32-byte line write at addr."""
        for b in range(LINE_BYTES):
            if (wstrb >> b) & 1:
                self._bytes[addr + b] = (wdata >> (8 * b)) & 0xFF

    def read_line(self, addr: int) -> int:
        """Return the 32-byte line at addr as a little-endian integer."""
        value = 0
        for b in range(LINE_BYTES):
            value |= self._bytes.get(addr + b, 0) << (8 * b)
        return value


def _line_int(data: bytes) -> int:
    return int.from_bytes(data, "little")


async def _check_read(dut: Any, model: ReferenceModel, addr: int) -> None:
    got = await _line_transaction(dut, write=False, addr=addr)
    expected = model.read_line(addr)
    assert (
        got == expected
    ), f"read mismatch @0x{addr:08x}: got 0x{got:064x} expected 0x{expected:064x}"


@cocotb.test()
async def test_smoke_write_read(dut: Any) -> None:
    """Whole-line write then read back (allocate-without-fetch + read hit)."""
    await _setup(dut)
    model = ReferenceModel()
    addr = SMOKE_BASE + 0x40
    wdata = _line_int(bytes(range(32)))
    model.write_line(addr, wdata, (1 << LINE_BYTES) - 1)
    await _line_transaction(
        dut, write=True, addr=addr, wdata=wdata, wstrb=(1 << LINE_BYTES) - 1
    )
    await _check_read(dut, model, addr)


@cocotb.test()
async def test_partial_write_merges_on_miss(dut: Any) -> None:
    """A sparse-strobe write miss must fetch and merge (unwritten bytes = 0)."""
    await _setup(dut)
    model = ReferenceModel()
    addr = PARTIAL_BASE + 5 * LINE_BYTES
    wdata = _line_int(bytes([0xAB] * 32))
    wstrb = 0x0000_F00F  # bytes 0-3 and 12-15
    model.write_line(addr, wdata, wstrb)
    await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=wstrb)
    await _check_read(dut, model, addr)


@cocotb.test()
async def test_dirty_eviction_roundtrip(dut: Any) -> None:
    """Two lines aliasing the same L1 index: dirty victim must survive."""
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    # 1 KiB L1 = 32 lines; stride by L1 size to alias index 3 with many tags.
    addrs = [EVICT_BASE + 3 * LINE_BYTES + tag * 1024 for tag in range(12)]
    for i, addr in enumerate(addrs):
        wdata = _line_int(bytes([(i * 7 + b) & 0xFF for b in range(32)]))
        model.write_line(addr, wdata, full)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)
    for addr in addrs:
        await _check_read(dut, model, addr)


@cocotb.test()
async def test_word_strobe_writes(dut: Any) -> None:
    """4-byte strobe groups in every lane (the adapter's store pattern)."""
    await _setup(dut)
    model = ReferenceModel()
    addr = STROBE_BASE + 64 * LINE_BYTES
    for lane in range(8):
        word = 0x1111_0000 * 0 + (0xC0DE_0000 | lane)
        wdata = word << (32 * lane)
        wstrb = 0xF << (4 * lane)
        model.write_line(addr, wdata, wstrb)
        await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=wstrb)
    await _check_read(dut, model, addr)


@cocotb.test()
async def test_random_traffic_vs_model(dut: Any) -> None:
    """Randomized reads/writes over a window far larger than both caches."""
    await _setup(dut)
    model = ReferenceModel()
    rng = random.Random(random.getrandbits(32))
    full = (1 << LINE_BYTES) - 1

    for _ in range(1200):
        line = rng.randrange(WINDOW_LINES)
        addr = RANDOM_BASE + line * LINE_BYTES
        if rng.random() < 0.55:
            wdata = rng.getrandbits(256)
            style = rng.random()
            if style < 0.4:
                wstrb = full  # whole line (eviction-shaped)
            elif style < 0.8:
                wstrb = 0xF << (4 * rng.randrange(8))  # one word (CPU store shape)
            else:
                wstrb = rng.getrandbits(32)  # arbitrary sparse bytes
                if wstrb == 0:
                    wstrb = 1
            model.write_line(addr, wdata, wstrb)
            await _line_transaction(
                dut, write=True, addr=addr, wdata=wdata, wstrb=wstrb
            )
        else:
            await _check_read(dut, model, addr)

    # Final sweep: every line the model knows about must read back exactly.
    for line in range(0, WINDOW_LINES, 7):
        await _check_read(dut, model, RANDOM_BASE + line * LINE_BYTES)


@cocotb.test()
async def test_thrash_same_index(dut: Any) -> None:
    """Alternating tags on one index: continuous evict/fill at both levels."""
    await _setup(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    index_addr = THRASH_BASE + 9 * LINE_BYTES
    tags = [index_addr + t * 1024 for t in range(6)]
    for rep in range(8):
        for t, addr in enumerate(tags):
            wdata = _line_int(bytes([(rep * 31 + t * 5 + b) & 0xFF for b in range(32)]))
            model.write_line(addr, wdata, full)
            await _line_transaction(dut, write=True, addr=addr, wdata=wdata, wstrb=full)
        for addr in tags:
            await _check_read(dut, model, addr)

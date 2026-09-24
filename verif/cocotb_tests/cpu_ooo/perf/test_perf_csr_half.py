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

"""Cycle-exact tests of the performance-counter CSR half select.

The harness feeds the real commit-bus register and aggregator into two csr_file
instances. One returns the aggregator's preselected 32-bit half
(UsePerfCsrHalf); the reference selects the half from the full 64-bit counter.
Their outputs must match on every cycle.
"""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer

MPERF_SEL = 0x7C0
MPERF_CTL = 0x7C1
MPERF_DATA = 0xFC0
MPERF_DATAH = 0xFC1
MASK32 = (1 << 32) - 1


class Seam:
    """Drive raw commit inputs; compare both CSR paths before and after every clock edge."""

    def __init__(self, dut: Any) -> None:
        """Bind the harness and start the diagnostic cycle counter."""
        self.dut = dut
        self.cycles = 0

    async def step(self, **inputs: int) -> int:
        """Apply inputs, check both paths, clock one edge, and return the pre-edge data."""
        d = self.dut
        d.i_clk.value = 0
        for name, value in inputs.items():
            getattr(d, "i_" + name).value = value
        await Timer(2, unit="ns")
        before = int(d.o_reference_comb.value)
        assert int(d.o_candidate_comb.value) == before
        if int(d.o_read_enable.value):
            address = int(d.o_commit_address.value)
            full = int(d.o_perf_data.value)
            if address in (MPERF_DATA, MPERF_DATAH):
                expected = (full >> (32 if address == MPERF_DATAH else 0)) & MASK32
                assert before == expected, (self.cycles, address, before, expected)
        d.i_clk.value = 1
        await Timer(2, unit="ns")
        self.cycles += 1
        # CSR output capture is unconditional, including reset, in both paths.
        assert int(d.o_reference.value) == before
        assert int(d.o_candidate.value) == before
        assert int(d.o_candidate_comb.value) == int(d.o_reference_comb.value)
        full = int(d.o_perf_data.value)
        address = int(d.o_commit_address.value)
        expected_half = (full >> (32 if address == MPERF_DATAH else 0)) & MASK32
        assert int(d.o_perf_half.value) == expected_half
        return before

    async def idle(self, count: int = 1, **inputs: int) -> None:
        """Advance with no new valid commit while preserving other inputs."""
        for _ in range(count):
            await self.step(raw_valid=0, **inputs)

    async def access(self, address: int, value: int = 0, op: int = 2) -> int:
        """Launch one raw CSR access and collect its next-cycle read capture."""
        await self.step(
            raw_address=address,
            raw_value=value,
            raw_op=op,
            raw_valid=1,
            raw_is_csr=1,
            raw_exception=0,
        )
        return await self.step(raw_valid=0)


async def setup(dut: Any) -> Seam:
    """Reset both CSR implementations and their shared upstream pipeline."""
    for name in (
        "clk",
        "rst",
        "flush",
        "raw_valid",
        "raw_is_csr",
        "raw_exception",
        "raw_address",
        "raw_op",
        "raw_value",
        "wrapper_data",
        "dispatch_event",
        "cache_access",
        "fp_flags",
        "fp_flags_valid",
        "mtime",
    ):
        getattr(dut, "i_" + name).value = 0
    s = Seam(dut)
    await s.step(rst=1)
    await s.step(rst=1)
    await s.step(rst=0)
    return s


@cocotb.test()
async def test_consecutive_halves_use_same_edge_payload_and_address(dut: Any) -> None:
    """Each half read pairs data and address from the same edge, even when both change."""
    s = await setup(dut)
    await s.access(MPERF_SEL, 42, 1)  # Wrapper block has controllable 64-bit data.
    await s.idle(3)
    assert int(dut.o_selector.value) == 42
    for n in range(32):
        word = ((0xA5000000 + n) << 32) | (0x5A00FF00 ^ n)
        await s.step(
            raw_address=MPERF_DATAH if n & 1 else MPERF_DATA,
            raw_valid=1,
            raw_is_csr=1,
            raw_op=2,
            raw_value=0,
            wrapper_data=word,
        )
        assert int(dut.o_perf_data.value) == word
    await s.idle(2)


@cocotb.test()
async def test_snapshot_selector_and_previous_cache_bank_phase(dut: Any) -> None:
    """CSR writes drive the selector, the snapshot capture, and the previous-bank select."""
    s = await setup(dut)
    await s.idle(7, dispatch_event=1, cache_access=1)
    await s.idle(2, dispatch_event=0, cache_access=0)
    await s.access(MPERF_CTL, 1, 1)
    await s.idle(3)
    assert await s.access(MPERF_DATA) == 7
    assert await s.access(MPERF_DATAH) == 0
    await s.access(MPERF_SEL, 106, 1)
    await s.idle(3)
    assert await s.access(MPERF_DATA) == 7
    await s.idle(3, dispatch_event=1, cache_access=1)
    await s.idle(2, dispatch_event=0, cache_access=0)
    await s.access(MPERF_CTL, 1, 1)
    await s.idle(3)
    assert await s.access(MPERF_DATA) == 10
    await s.access(MPERF_CTL, 2, 1)
    await s.idle(3)
    assert int(dut.o_previous.value) == 1
    assert await s.access(MPERF_DATA) == 7
    # Back-to-back accesses change the selector and the half address on
    # adjacent cycles. Read data lags the selector (perf README, "CSR
    # interface"), and both paths must return the same value.
    for address, value, op in (
        (MPERF_SEL, 42, 1),
        (MPERF_DATAH, 0, 2),
        (MPERF_SEL, 130, 1),
        (MPERF_DATA, 0, 2),
        (MPERF_CTL, 1, 1),
        (MPERF_DATAH, 0, 2),
    ):
        await s.step(
            raw_address=address,
            raw_value=value,
            raw_op=op,
            raw_valid=1,
            raw_is_csr=1,
            wrapper_data=0xFEDCBA9876543210,
        )
    await s.idle(4)
    assert await s.access(MPERF_DATA) == 0  # Out-of-range selector.


@cocotb.test()
async def test_flush_exception_bubbles_and_reset_keep_current_qualification(
    dut: Any,
) -> None:
    """A captured half cannot revive a killed read; reset does not clear the CSR output."""
    s = await setup(dut)
    await s.access(MPERF_SEL, 42, 1)
    await s.idle(3, wrapper_data=0xA5A5A5A55A5A5A5A)
    await s.step(
        raw_valid=1, raw_is_csr=1, raw_address=MPERF_DATAH, raw_value=0, raw_op=2
    )
    assert int(dut.o_reference_comb.value) == 0xA5A5A5A5
    # Immediate flush after commit capture masks valid before the next edge.
    dut.i_flush.value = 1
    await Timer(1, unit="ns")
    assert int(dut.o_read_enable.value) == 0
    assert int(dut.o_candidate_comb.value) == 0
    assert await s.step(raw_valid=0, flush=1) == 0
    await s.idle(1, flush=0)
    for valid, is_csr, exception in ((0, 1, 0), (1, 0, 0), (1, 1, 1)):
        await s.step(
            raw_valid=valid,
            raw_is_csr=is_csr,
            raw_exception=exception,
            raw_address=MPERF_DATA,
        )
        assert int(dut.o_read_enable.value) == 0
        assert await s.step(raw_valid=0) == 0
    await s.step(raw_valid=1, raw_is_csr=1, raw_exception=0, raw_address=MPERF_DATAH)
    assert await s.step(rst=1, raw_valid=0) == 0xA5A5A5A5
    assert int(dut.o_perf_data.value) == 0
    assert int(dut.o_perf_half.value) == 0
    await s.idle(1, rst=0)
    assert int(dut.o_candidate.value) == 0


@cocotb.test()
async def test_ordinary_csr_and_same_cycle_fp_forwarding_unchanged(dut: Any) -> None:
    """Only the two performance-data arms consume the optional half hint."""
    s = await setup(dut)
    await s.access(0x340, 0x0123456789ABCDEF, 1)  # mscratch
    assert await s.access(0x340) == 0x0123456789ABCDEF
    await s.step(raw_address=0xC01, raw_valid=1, raw_is_csr=1, raw_op=2, raw_value=0)
    assert await s.step(raw_valid=0, mtime=0xDEADBEEF87654321) == 0xDEADBEEF87654321
    await s.access(0x001, 0, 1)  # Clear fflags.
    await s.step(raw_address=0x001, raw_valid=1, raw_is_csr=1, raw_op=2, raw_value=0)
    assert await s.step(raw_valid=0, fp_flags=0b10001, fp_flags_valid=1) == 0b10001
    await s.idle(1, fp_flags_valid=0)
    # The CSRRS write has priority over the same-cycle flag accumulation and
    # takes its value from the stored fflags (zero), while the read forwards
    # 10001; the next-cycle replay is suppressed.
    assert await s.access(0x003) == 0
    # A distinct FP commit without a CSR write still accumulates normally.
    await s.idle(1, fp_flags=0b00110, fp_flags_valid=1)
    await s.idle(1, fp_flags_valid=0)
    assert await s.access(0x003) == 0b00110  # fcsr, frm still zero.
    assert await s.access(0x7FF) == 0


@cocotb.test()
async def test_random_raw_commit_and_snapshot_histories(dut: Any) -> None:
    """Both paths agree under random back-to-back commits, flushes, resets, and snapshots."""
    s = await setup(dut)
    rng = random.Random(0xC5A32)
    addresses = (
        MPERF_DATA,
        MPERF_DATAH,
        MPERF_SEL,
        MPERF_CTL,
        0x340,
        0x001,
        0x003,
        0xC01,
        0x7FF,
    )
    for _ in range(1024):
        address = rng.choice(addresses)
        value, op = 0, 2
        if address == MPERF_SEL:
            value, op = rng.choice((0, 7, 42, 49, 106, 129, 130, 255)), 1
        elif address == MPERF_CTL:
            value, op = rng.randrange(4), 1
        elif address == 0x340:
            value, op = rng.getrandbits(64), 1
        await s.step(
            raw_address=address,
            raw_value=value,
            raw_op=op,
            raw_valid=int(rng.random() < 0.8),
            raw_is_csr=int(rng.random() < 0.9),
            raw_exception=int(rng.random() < 0.08),
            flush=int(rng.random() < 0.07),
            rst=int(rng.random() < 0.015),
            wrapper_data=rng.getrandbits(64),
            dispatch_event=rng.randrange(2),
            cache_access=rng.randrange(2),
            fp_flags=rng.randrange(32),
            fp_flags_valid=int(rng.random() < 0.15),
            mtime=rng.getrandbits(64),
        )
    await s.idle(2, rst=0, flush=0)

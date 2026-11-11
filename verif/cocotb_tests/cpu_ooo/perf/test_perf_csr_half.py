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


class CsrPathChecker:
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

    async def access(self, address: int, value: int = 0, op: int = 0) -> int:
        """Launch one raw CSR access (a csrr by default); return its next-cycle read capture."""
        await self.step(
            raw_address=address,
            raw_value=value,
            raw_op=op,
            raw_valid=1,
            raw_is_csr=1,
            raw_exception=0,
        )
        return await self.step(raw_valid=0)


async def setup(dut: Any) -> CsrPathChecker:
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
        "hpm_branches",
        "hpm_mispredicts",
        "hpm_events",
        "hpm_translation_events",
        "hpm_instret",
        "mret",
        "sret",
        "trap",
    ):
        getattr(dut, "i_" + name).value = 0
    s = CsrPathChecker(dut)
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
            raw_op=0,
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
        (MPERF_DATAH, 0, 0),
        (MPERF_SEL, 134, 1),
        (MPERF_DATA, 0, 0),
        (MPERF_CTL, 1, 1),
        (MPERF_DATAH, 0, 0),
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
async def test_mperfctl_read_keeps_previous_bank_select(dut: Any) -> None:
    """A read of mperfctl leaves the bank select; only a write sets or clears it."""
    s = await setup(dut)
    await s.access(MPERF_CTL, 2, 1)  # csrrw: select the preceding bank
    await s.idle(3)
    assert int(dut.o_previous.value) == 1
    # A csrr, or a set/clear with rs1 = x0 (dispatch clears op[1:0]): mperfctl
    # reads 0, so a write-back of the read value would clear the select.
    await s.access(MPERF_CTL)
    await s.idle(3)
    assert int(dut.o_previous.value) == 1, "a read of mperfctl cleared the bank select"
    await s.access(MPERF_CTL, 2, 3)  # csrrc with bit 1: a write, so it clears
    await s.idle(3)
    assert int(dut.o_previous.value) == 0


@cocotb.test()
async def test_flush_exception_bubbles_and_reset_keep_current_qualification(
    dut: Any,
) -> None:
    """A captured half cannot revive a killed read; reset does not clear the CSR output."""
    s = await setup(dut)
    await s.access(MPERF_SEL, 42, 1)
    await s.idle(3, wrapper_data=0xA5A5A5A55A5A5A5A)
    await s.step(
        raw_valid=1, raw_is_csr=1, raw_address=MPERF_DATAH, raw_value=0, raw_op=0
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
    await s.step(raw_address=0xC01, raw_valid=1, raw_is_csr=1, raw_op=0, raw_value=0)
    assert await s.step(raw_valid=0, mtime=0xDEADBEEF87654321) == 0xDEADBEEF87654321
    await s.access(0x001, 0, 1)  # Clear fflags.
    await s.step(raw_address=0x001, raw_valid=1, raw_is_csr=1, raw_op=0, raw_value=0)
    assert await s.step(raw_valid=0, fp_flags=0b10001, fp_flags_valid=1) == 0b10001
    await s.idle(1, fp_flags_valid=0)
    # The read's write-back (csr_file writes every committed CSR access) has
    # priority over the same-cycle flag accumulation and takes its value from
    # the stored fflags (zero), while the read forwards 10001; the next-cycle
    # replay is suppressed.
    assert await s.access(0x003) == 0
    # A distinct FP commit without a CSR write still accumulates normally.
    await s.idle(1, fp_flags=0b00110, fp_flags_valid=1)
    await s.idle(1, fp_flags_valid=0)
    assert await s.access(0x003) == 0b00110  # fcsr, frm still zero.
    assert await s.access(0x7FF) == 0


@cocotb.test()
async def test_hpmcounter_5_to_8_access(dut: Any) -> None:
    """HPM counters 5..8 and their event registers read/write exact values."""
    s = await setup(dut)
    test_data = [
        (0xB05, 0xC05, 0x325, 0x1234_5678_ABCD_0005, 5),
        (0xB06, 0xC06, 0x326, 0x2345_6789_BCDE_0006, 6),
        (0xB07, 0xC07, 0x327, 0x3456_789A_CDEF_0007, 7),
        (0xB08, 0xC08, 0x328, 0x4567_89AB_DEF0_0008, 8),
    ]
    for mcounter, ucounter, mevent, val, event_val in test_data:
        # Write machine counter
        await s.access(mcounter, val, 1)
        # Read back via machine CSR
        assert await s.access(mcounter) == val
        # Read back via user alias
        assert await s.access(ucounter) == val
        # Write and read event CSR
        await s.access(mevent, event_val, 1)
        assert await s.access(mevent) == event_val


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
        value, op = 0, 0
        if address == MPERF_SEL:
            value, op = rng.choice((0, 7, 42, 49, 106, 129, 133, 134, 255)), 1
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


@cocotb.test()
async def test_hpm_event_selection_inhibit_and_aliases(dut: Any) -> None:
    """Counter selection, inhibition and aliases agree with supplied event counts."""
    s = await setup(dut)
    await s.access(0x320, (1 << 64) - 1, 1)
    assert await s.access(0x320) == 0x7FD
    await s.access(0x320, 0, 1)
    await s.idle(4, hpm_branches=2, hpm_mispredicts=1, hpm_events=15)
    await s.idle(3, hpm_branches=0, hpm_mispredicts=0, hpm_events=0)
    for n in range(3, 9):
        assert await s.access(0xB00 + n) == 0
        await s.access(0x320 + n, n, 1)
        assert await s.access(0x320 + n) == n
    await s.idle(5, hpm_branches=2, hpm_mispredicts=1, hpm_events=15)
    await s.idle(3, hpm_branches=0, hpm_mispredicts=0, hpm_events=0)
    for n in range(3, 9):
        expected = 10 if n == 3 else 5
        assert await s.access(0xB00 + n) == expected
        assert await s.access(0xC00 + n) == expected
    for blocked in range(3, 9):
        await s.access(0x320, 1 << blocked, 1)
        assert await s.access(0x320) == 1 << blocked
        before = [await s.access(0xB00 + n) for n in range(3, 9)]
        await s.idle(3, hpm_branches=2, hpm_mispredicts=1, hpm_events=15)
        await s.idle(3, hpm_branches=0, hpm_mispredicts=0, hpm_events=0)
        for n in range(3, 9):
            delta = 0 if n == blocked else (6 if n == 3 else 3)
            assert await s.access(0xB00 + n) == before[n - 3] + delta
    await s.access(0x320, 0, 1)
    for n in range(3, 9):
        await s.access(0x320 + n, n + 1, 1)
        assert await s.access(0x320 + n) == 0
        await s.access(0xB00 + n, 0xFFFF_FFFF_FFFF_FFFE, 1)
    await s.idle(4, hpm_branches=2, hpm_mispredicts=1, hpm_events=15)
    await s.idle(3, hpm_branches=0, hpm_mispredicts=0, hpm_events=0)
    for n in range(3, 9):
        assert await s.access(0xC00 + n) == 0xFFFF_FFFF_FFFF_FFFE
        await s.access(0x320 + n, n, 1)
    await s.idle(3, hpm_branches=2, hpm_mispredicts=1, hpm_events=15)
    await s.idle(3, hpm_branches=0, hpm_mispredicts=0, hpm_events=0)
    for n in range(3, 9):
        assert await s.access(0xC00 + n) == (4 if n == 3 else 1)


@cocotb.test()
async def test_hpm_translation_event_selectors(dut: Any) -> None:
    """Selectors 16, 17 and 18 count walker busy cycles and TLB invalidates."""
    s = await setup(dut)
    off = dict(
        hpm_branches=0, hpm_mispredicts=0, hpm_events=0, hpm_translation_events=0
    )
    for counter, selector in ((8, 16), (7, 17), (4, 18)):
        await s.access(0x320 + counter, selector, 1)
        assert await s.access(0x320 + counter) == selector
        await s.access(0xB00 + counter, 0, 1)
    # The fixed events no longer reach the reselected counters.
    await s.idle(4, hpm_branches=2, hpm_mispredicts=1, hpm_events=15)
    await s.idle(3, **off)
    for counter in (8, 7, 4):
        assert await s.access(0xB00 + counter) == 0
    # Walker busy for five cycles, two SFENCE.VMA invalidate starts.
    await s.idle(5, hpm_translation_events=1)
    await s.idle(1, hpm_translation_events=2)
    await s.idle(1, hpm_translation_events=0)
    await s.idle(1, hpm_translation_events=2)
    await s.idle(3, **off)
    assert await s.access(0xB08) == 5
    assert await s.access(0xB07) == 2
    assert await s.access(0xB04) == 0
    # Every satp access, a read included, requests one CSR invalidate.
    await s.access(0x180, 0, 1)
    await s.access(0x180)
    await s.idle(3)
    assert await s.access(0xB04) == 2
    # An sstatus SUM toggle is not a translation invalidate.
    await s.access(0x100, 1 << 18, 2)
    await s.access(0x100, 1 << 18, 3)
    await s.idle(3)
    assert await s.access(0xB04) == 2
    # An MPRV change is.
    await s.access(0x300, 1 << 17, 2)
    await s.access(0x300, 1 << 17, 3)
    await s.idle(3)
    assert await s.access(0xB04) == 4
    # Translation selectors are counter-specific: elsewhere they disable.
    # Counters 9 and 10 own the selectors 9 and 10, so the translation events
    # never alias a counter number.
    for counter in (3, 5, 6, 9, 10):
        for selector in (16, 17, 18):
            await s.access(0x320 + counter, selector, 1)
            assert await s.access(0x320 + counter) == 0
    await s.access(0x328, 9, 1)
    assert await s.access(0x328) == 0
    await s.access(0x328, 10, 1)
    assert await s.access(0x328) == 0
    # Counter 8 keeps accepting only its own number and its translation selector.
    for selector in (17, 18):
        await s.access(0x328, selector, 1)
        assert await s.access(0x328) == 0
    # Restoring the fixed selector restores the fixed event.
    await s.access(0x328, 8, 1)
    await s.access(0xB08, 0, 1)
    await s.idle(3, hpm_events=8, hpm_translation_events=1)
    await s.idle(3, **off)
    assert await s.access(0xB08) == 3


@cocotb.test()
async def test_hpm_privilege_enable_masks(dut: Any) -> None:
    """M bypasses counter enables, S needs mcounteren and U needs both masks."""
    s = await setup(dut)
    for priv, mcounteren, scounteren, expected in (
        (3, 0, 0, 0),
        (1, 0x7FF, 0, 0),
        (1, 7, 0x7FF, 0x7F8),
        (0, 0x7FF, 0x555, 0x2AA),
        (0, 0x2AA, 0x7FF, 0x555),
    ):
        await s.idle(trap=1)
        await s.idle(3, trap=0)
        await s.access(0x306, mcounteren, 1)
        await s.access(0x106, scounteren, 1)
        if priv != 3:
            await s.access(0x300, priv << 11, 1)
            await s.idle(mret=1)
            await s.idle(3, mret=0)
        assert int(dut.o_counter_blocked.value) == expected


@cocotb.test()
async def test_hpm_event_identity_and_pending_writes(dut: Any) -> None:
    """Distinct events, RMW writes and inhibit/selector edges preserve exact counts."""
    s = await setup(dut)
    off = dict(hpm_branches=0, hpm_mispredicts=0, hpm_events=0)
    for n in range(3, 9):
        await s.access(0x320 + n, n, 1)
    for n in range(3, 9):
        on = dict(off)
        if n == 3:
            on["hpm_branches"] = 2
        elif n == 4:
            on["hpm_mispredicts"] = 1
        else:
            on["hpm_events"] = 1 << (n - 5)
        increment = 2 if n == 3 else 1
        for counter in range(3, 9):
            await s.access(0xB00 + counter, 0, 1)
        await s.idle(n, **on)
        await s.idle(3, **off)
        for counter in range(3, 9):
            assert await s.access(0xB00 + counter) == (
                n * increment if counter == n else 0
            )

        # A counter write replaces a nonzero pending increment.
        await s.idle(2, **on)
        await s.access(0xB00 + n, 0x40, 1)
        await s.idle(1, **off)
        assert await s.access(0xB00 + n) == 0x40
        await s.access(0xB00 + n, 3, 2)
        assert await s.access(0xB00 + n) == 0x43
        await s.access(0xB00 + n, 0x41, 3)
        assert await s.access(0xB00 + n) == 2

        for control, stop_value, stop_op, start_value, start_op in (
            (0x320, 1 << n, 2, 1 << n, 3),
            (0x320 + n, 0, 1, n, 1),
        ):
            await s.access(0xB00 + n, 0, 1)
            await s.idle(2, **on)
            await s.access(control, stop_value, stop_op)
            await s.idle(3, **off)
            assert await s.access(0xB00 + n) == 4 * increment
            await s.idle(5, **on)
            assert await s.access(0xB00 + n) == 4 * increment
            await s.access(control, start_value, start_op)
            await s.idle(1, **on)
            await s.idle(3, **off)
            assert await s.access(0xB00 + n) == 5 * increment


# Sscofpmf (privileged spec, "Count Overflow and Mode-Based Filtering").
MIP, SIP, MIE, SIE, MIDELEG, MVIP = 0x344, 0x144, 0x304, 0x104, 0x303, 0x309
MTOPI, STOPI, SCOUNTOVF, MCOUNTEREN = 0xFB0, 0xDB0, 0xDA0, 0x306
OF, MINH, SINH, UINH = 1 << 63, 1 << 62, 1 << 61, 1 << 60
LCOF = 1 << 13
MASK64 = (1 << 64) - 1
EVENTS_OFF = dict(hpm_branches=0, hpm_mispredicts=0, hpm_events=0, hpm_instret=0)


def event_on(n: int) -> dict[str, int]:
    """Return inputs that raise only counter n's event (counter 9 counts every cycle)."""
    on = dict(EVENTS_OFF)
    if n == 3:
        on["hpm_branches"] = 2
    elif n == 4:
        on["hpm_mispredicts"] = 1
    elif 5 <= n <= 8:
        on["hpm_events"] = 1 << (n - 5)
    elif n == 10:
        on["hpm_instret"] = 1
    return on


def event_increment(n: int) -> int:
    """Return the per-cycle increment event_on(n) supplies."""
    return 2 if n == 3 else 1


async def enter_priv(s: CsrPathChecker, priv: int) -> None:
    """Trap to M, then MRET to priv through mstatus.MPP."""
    await s.idle(trap=1)
    await s.idle(3, trap=0)
    if priv != 3:
        await s.access(0x300, priv << 11, 1)
        await s.idle(mret=1)
        await s.idle(3, mret=0)
    assert int(s.dut.o_priv.value) == priv


@cocotb.test()
async def test_sscofpmf_event_fields_warl(dut: Any) -> None:
    """OF and MINH/SINH/UINH are writable; VSINH, VUINH, WPRI and other selectors read 0."""
    s = await setup(dut)
    for n in range(3, 11):
        await s.access(0x320 + n, MASK64, 1)
        assert await s.access(0x320 + n) == OF | MINH | SINH | UINH
        await s.access(0x320 + n, (0xF << 56) | n, 1)
        assert await s.access(0x320 + n) == n
        await s.access(0x320 + n, OF | SINH | n, 1)
        assert await s.access(0x320 + n) == OF | SINH | n
        await s.access(0x320 + n, (1 << 40) | n, 1)
        assert await s.access(0x320 + n) == 0
        await s.access(0x320 + n, 0, 1)
    # The counters above 10 and their selectors stay read-only zero.
    await s.access(0x32B, MASK64, 1)
    assert await s.access(0x32B) == 0
    await s.access(0xB0B, MASK64, 1)
    assert await s.access(0xB0B) == 0


@cocotb.test()
async def test_sscofpmf_wrap_sets_of_and_lcofip(dut: Any) -> None:
    """A wrap sets OF and raises LCOFIP only from OF=0; writes never overflow."""
    s = await setup(dut)
    for n in (3, 4, 5, 6, 7, 8, 10):
        on, inc = event_on(n), event_increment(n)
        await s.access(0x320 + n, n, 1)
        await s.access(0xB00 + n, MASK64 - 1, 1)
        await s.idle(2, **on)
        await s.idle(3, **EVENTS_OFF)
        assert await s.access(0xB00 + n) == (MASK64 - 1 + 2 * inc) & MASK64
        assert await s.access(0x320 + n) == OF | n
        assert await s.access(MIP) & LCOF
        assert await s.access(SCOUNTOVF) == 1 << n
        # Software clears LCOFIP; a second wrap with OF set raises nothing.
        await s.access(MIP, LCOF, 3)
        assert not await s.access(MIP) & LCOF
        await s.access(0xB00 + n, MASK64 - 1, 1)
        await s.idle(2, **on)
        await s.idle(3, **EVENTS_OFF)
        assert not await s.access(MIP) & LCOF
        assert await s.access(0x320 + n) == OF | n
        # Clearing OF re-arms the counter and clears its scountovf bit.
        await s.access(0x320 + n, n, 1)
        assert await s.access(SCOUNTOVF) == 0
        await s.access(0x320 + n, 0, 1)
    # Counter 9 counts cycles.
    await s.access(0x329, 9, 1)
    await s.access(0xB09, MASK64 - 19, 1)
    await s.idle(30)
    assert await s.access(0xB09) < 40
    assert await s.access(0x329) == OF | 9
    assert await s.access(MIP) & LCOF
    await s.access(0x329, 0, 1)
    await s.access(MIP, LCOF, 3)
    # Counter writes never overflow, even from all ones to zero.
    await s.access(0x324, 4, 1)
    await s.access(0xB04, MASK64, 1)
    await s.access(0xB04, 0, 1)
    await s.idle(3)
    assert await s.access(0x324) == 4
    assert not await s.access(MIP) & LCOF


@cocotb.test()
async def test_sscofpmf_mode_filtering(dut: Any) -> None:
    """Each xINH bit stops counting in its privilege only, for retire and cycle events."""
    s = await setup(dut)
    for priv in (3, 1, 0):
        await enter_priv(s, priv)
        for n in (3, 5, 10):
            on, inc = event_on(n), event_increment(n)
            for inh, inh_priv in ((0, None), (MINH, 3), (SINH, 1), (UINH, 0)):
                await s.access(0x320 + n, inh | n, 1)
                await s.access(0xB00 + n, 0, 1)
                await s.idle(4, **on)
                await s.idle(3, **EVENTS_OFF)
                expected = 0 if inh_priv == priv else 4 * inc
                assert await s.access(0xB00 + n) == expected, (priv, n, inh)
            await s.access(0x320 + n, 0, 1)


@cocotb.test()
async def test_sscofpmf_sret_retirement_uses_previous_privilege(dut: Any) -> None:
    """Count SRET in S and following retirements in U across the delayed input."""
    s = await setup(dut)
    for inhibit, expected in ((MINH | UINH, 1), (MINH | SINH, 2)):
        await enter_priv(s, 3)
        await s.access(0x32A, inhibit | 10, 1)
        await s.access(0xB0A, 0, 1)
        await enter_priv(s, 1)
        # The core reports SRET's retirement one cycle after the return
        # changes privilege. A following U pair arrives one cycle later.
        await s.step(raw_valid=0, sret=1, hpm_instret=0)
        assert int(dut.o_priv.value) == 0
        await s.step(raw_valid=0, sret=0, hpm_instret=1)
        await s.step(raw_valid=0, hpm_instret=2)
        await s.idle(3, hpm_instret=0)
        assert await s.access(0xC0A) == expected, (inhibit, expected)


@cocotb.test()
async def test_sscofpmf_scountovf_counter_enable_mask(dut: Any) -> None:
    """M reads every scountovf bit; S reads only those mcounteren enables."""
    s = await setup(dut)
    await s.access(0x326, OF | 6, 1)
    await s.access(0x32A, OF | 10, 1)
    await s.access(MCOUNTEREN, 0x7FF & ~(1 << 6), 1)
    assert await s.access(SCOUNTOVF) == (1 << 6) | (1 << 10)
    await enter_priv(s, 1)
    assert await s.access(SCOUNTOVF) == 1 << 10
    await s.access(MCOUNTEREN, 0, 1)
    assert await s.access(SCOUNTOVF) == 0
    await s.access(MCOUNTEREN, 0x7FF, 1)
    assert await s.access(SCOUNTOVF) == (1 << 6) | (1 << 10)
    # scountovf is read-only: a write leaves the OF bits.
    await s.access(SCOUNTOVF, 0, 1)
    assert await s.access(SCOUNTOVF) == (1 << 6) | (1 << 10)


@cocotb.test()
async def test_sscofpmf_lcofi_delegation_and_topi(dut: Any) -> None:
    """LCOFI uses mideleg/mie/mip bit 13, the sip/sie aliases, and the lowest topi priority."""
    s = await setup(dut)
    await s.access(MIDELEG, MASK64, 1)
    assert await s.access(MIDELEG) == 0x2222
    await s.access(MIDELEG, 0, 1)
    await s.access(MIE, LCOF, 1)
    assert int(dut.o_mie.value) & LCOF
    await s.access(MIP, LCOF, 2)
    assert await s.access(MIP) & LCOF
    assert await s.access(MTOPI) == 0x000D_0001
    assert await s.access(STOPI) == 0
    assert await s.access(SIP) == 0 and await s.access(SIE) == 0
    await s.access(SIP, 0, 1)  # Not delegated: no effect.
    assert int(dut.o_lcof_pending.value) == 1
    await s.access(MIDELEG, LCOF, 1)
    assert int(dut.o_mideleg_lcof.value) == 1
    assert await s.access(SIP) == LCOF and await s.access(SIE) == LCOF
    assert await s.access(MTOPI) == 0
    assert await s.access(STOPI) == 0x000D_0001
    # SSI outranks LCOFI in both files.
    await s.access(MIP, 1 << 1, 2)
    await s.access(MIE, LCOF | (1 << 1), 1)
    assert await s.access(MTOPI) == 0x0001_0001
    assert await s.access(STOPI) == 0x000D_0001
    await s.access(MIDELEG, LCOF | (1 << 1), 1)
    assert await s.access(STOPI) == 0x0001_0001
    await s.access(MIP, 1 << 1, 3)
    # S clears LCOFIP through sip, and LCOFIE through sie, while delegated.
    await s.access(SIP, LCOF, 3)
    assert int(dut.o_lcof_pending.value) == 0
    await s.access(SIP, LCOF, 2)
    assert int(dut.o_lcof_pending.value) == 1
    await s.access(SIE, 0, 1)
    assert not int(dut.o_mie.value) & LCOF
    # mvien bit 13 is read-only zero, so mvip bit 13 reads zero and its
    # writes leave LCOFIP alone.
    assert not await s.access(MVIP) & LCOF
    await s.access(MVIP, 0, 1)
    assert int(dut.o_lcof_pending.value) == 1
    # A hardware set wins over a coincident software clear. The event stages
    # on edge t, wraps the counter on edge t+1, and its registered request
    # sets LCOFIP on edge t+2, where the mip clear launched at t+1 commits.
    for clear_delay, expected in ((0, 1), (1, 0)):
        await s.access(MIP, LCOF, 3)
        await s.access(0x325, 5, 1)
        await s.access(0xB05, MASK64, 1)
        await s.step(raw_valid=0, hpm_events=1)
        await s.idle(clear_delay, hpm_events=0)
        await s.step(
            raw_address=MIP,
            raw_value=LCOF,
            raw_op=3,
            raw_valid=1,
            raw_is_csr=1,
            hpm_events=0,
        )
        await s.idle(3)
        assert int(dut.o_lcof_pending.value) == expected, clear_delay
    await s.access(0x325, 0, 1)

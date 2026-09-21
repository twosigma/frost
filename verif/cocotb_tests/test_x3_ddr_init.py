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

"""Unit bench for x3_ddr_init, the board's power-up DDR4 region writer.

The module exists so no read of the ECC-checked array precedes a write of
it, and the board top trusts three things about it: that it covers the whole
region, that every write is a full controller word so the controller never
reads the array to recompute a check code, and that o_done means finished
rather than started. An AXI write slave here records what the module asks
for and the tests hold it to those three, under an accepting slave and under
one that stalls both channels and delays responses. A fourth test holds the
module past o_done and requires the channels to stay quiet, since the board
top hands them back to the CPU there.

The region is shrunk to a few kibibytes with -GREGION_BYTES so a run covers
it completely; on the board it is a gibibyte.
"""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

CLOCK_PERIOD_NS = 10

# The registry passes the same values as -G parameters and as environment, so
# one bench covers every shape it registers. The defaults are the module's own
# where it has one, so a bare run still describes a real configuration.
REGION_BYTES = int(os.environ.get("DDR_INIT_REGION_BYTES", "4096"))
MAX_OUTSTANDING = int(os.environ.get("DDR_INIT_MAX_OUTSTANDING", "4"))
DATA_BITS = 256
BEATS_PER_BURST = 2

BYTES_PER_BEAT = DATA_BITS // 8
BYTES_PER_BURST = BYTES_PER_BEAT * BEATS_PER_BURST
TOTAL_BURSTS = REGION_BYTES // BYTES_PER_BURST
# The module clamps its cap to the burst count, which is what keeps the cap
# representable in the counters.
OUTSTANDING_CAP = min(MAX_OUTSTANDING, TOTAL_BURSTS)
FULL_STRB = (1 << BYTES_PER_BEAT) - 1
AW_SIZE = (BYTES_PER_BEAT - 1).bit_length()
RESP_OKAY = 0

# Generous: the ideal run is about TOTAL_BURSTS * BEATS_PER_BURST cycles.
RUN_TIMEOUT_CYCLES = 200 * TOTAL_BURSTS + 1000


class WriteSlave:
    """AXI4 write slave that records the bursts and beats it accepts.

    ``aw_ready_p`` and ``w_ready_p`` are per-cycle acceptance probabilities
    and ``b_delay`` the cycles a response waits behind its burst, so one
    class covers both the accepting and the stalling slave.

    ``address_waits_for_data`` makes it the hostile-but-legal slave: it holds
    AWREADY low until it has seen WVALID. AXI permits that, and a master that
    held WVALID back until AWREADY would deadlock against it.
    """

    def __init__(  # noqa: D107 - the class docstring covers the arguments
        self,
        dut: Any,
        rng: random.Random,
        aw_ready_p: float = 1.0,
        w_ready_p: float = 1.0,
        b_delay: int = 0,
        address_waits_for_data: bool = False,
    ) -> None:
        self._dut = dut
        self._rng = rng
        self._aw_ready_p = aw_ready_p
        self._w_ready_p = w_ready_p
        self._b_delay = b_delay
        self._address_waits_for_data = address_waits_for_data
        self.addresses: list[int] = []
        self.beats: list[tuple[int, int, int]] = []  # data, strobe, last
        self.max_outstanding = 0
        self._queued: list[int] = []  # cycles remaining before each response
        self._responses_sent = 0
        self._task = cocotb.start_soon(self._run())

    @property
    def responses_sent(self) -> int:
        """Write responses this slave has returned and seen accepted."""
        return self._responses_sent

    def stop(self) -> None:
        """Stop driving; the next test resets the module from scratch."""
        self._task.cancel()

    async def _run(self) -> None:
        dut = self._dut
        bvalid = 0
        while True:
            await FallingEdge(dut.i_clk)
            aw_ready = 1 if self._rng.random() < self._aw_ready_p else 0
            if self._address_waits_for_data and not int(dut.o_wvalid.value):
                aw_ready = 0
            dut.i_awready.value = aw_ready
            dut.i_wready.value = 1 if self._rng.random() < self._w_ready_p else 0
            # A queued response becomes visible once its delay has run out.
            if not bvalid and self._queued and self._queued[0] <= 0:
                self._queued.pop(0)
                bvalid = 1
            dut.i_bvalid.value = bvalid
            dut.i_bresp.value = RESP_OKAY

            await ReadOnly()
            aw_fire = int(dut.o_awvalid.value) and int(dut.i_awready.value)
            w_fire = int(dut.o_wvalid.value) and int(dut.i_wready.value)
            w_last = w_fire and int(dut.o_wlast.value)
            b_fire = bvalid and int(dut.o_bready.value)
            if aw_fire:
                self.addresses.append(int(dut.o_awaddr.value))
                assert int(dut.o_awlen.value) == BEATS_PER_BURST - 1, (
                    f"burst length {int(dut.o_awlen.value)} is not "
                    f"{BEATS_PER_BURST - 1} beats"
                )
                assert int(dut.o_awsize.value) == AW_SIZE, (
                    f"burst size {int(dut.o_awsize.value)} does not describe "
                    f"{BYTES_PER_BEAT}-byte beats"
                )
                assert int(dut.o_awburst.value) == 0b01, "bursts must be INCR"
            if w_fire:
                self.beats.append(
                    (
                        int(dut.o_wdata.value),
                        int(dut.o_wstrb.value),
                        int(dut.o_wlast.value),
                    )
                )
            outstanding = len(self.addresses) - self._responses_sent
            self.max_outstanding = max(self.max_outstanding, outstanding)

            await RisingEdge(dut.i_clk)
            self._queued = [max(0, delay - 1) for delay in self._queued]
            # A response only exists once the burst's write data is complete,
            # which is what the protocol requires and what the module's own
            # completion rule must not depend on the timing of.
            if w_last:
                self._queued.append(self._b_delay)
            if b_fire:
                self._responses_sent += 1
                bvalid = 0


def _idle_inputs(dut: Any) -> None:
    dut.i_rst_n.value = 0
    dut.i_start.value = 0
    dut.i_awready.value = 0
    dut.i_wready.value = 0
    dut.i_bvalid.value = 0
    dut.i_bresp.value = RESP_OKAY


async def _reset(dut: Any) -> None:
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _idle_inputs(dut)
    for _ in range(5):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst_n.value = 1
    await FallingEdge(dut.i_clk)


async def _run_to_done(dut: Any) -> int:
    """Start the module and wait for o_done; returns the cycles it took."""
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 1
    for cycle in range(RUN_TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        if int(dut.o_done.value):
            return cycle
    raise AssertionError(f"o_done never asserted within {RUN_TIMEOUT_CYCLES} cycles")


def _check_coverage(slave: WriteSlave) -> None:
    """Every burst of the region, once, in order, with every byte written."""
    expected = [i * BYTES_PER_BURST for i in range(TOTAL_BURSTS)]
    if slave.addresses != expected:
        mismatch = next(
            (i for i, (a, e) in enumerate(zip(slave.addresses, expected)) if a != e),
            min(len(slave.addresses), len(expected)),
        )
        raise AssertionError(
            f"the region was not covered once in order: {len(slave.addresses)} "
            f"bursts of {TOTAL_BURSTS}, first difference at burst {mismatch}"
        )
    assert len(slave.beats) == TOTAL_BURSTS * BEATS_PER_BURST, (
        f"{len(slave.beats)} beats for {TOTAL_BURSTS} bursts of " f"{BEATS_PER_BURST}"
    )
    for index, (data, strobe, last) in enumerate(slave.beats):
        assert strobe == FULL_STRB, (
            f"beat {index} wrote strobe 0x{strobe:x}, not the full "
            f"0x{FULL_STRB:x}: the controller would read the array to "
            f"recompute its check code"
        )
        assert data == 0, f"beat {index} wrote 0x{data:x}, not zero"
        expected_last = (index % BEATS_PER_BURST) == BEATS_PER_BURST - 1
        assert bool(last) == expected_last, f"beat {index} marked last={last}"


@cocotb.test()
async def test_covers_region_once(dut: Any) -> None:
    """Against an always-ready slave, the whole region is written once."""
    await _reset(dut)
    slave = WriteSlave(dut, random.Random(1))
    await _run_to_done(dut)
    _check_coverage(slave)
    assert slave.responses_sent == TOTAL_BURSTS, (
        f"o_done asserted with {TOTAL_BURSTS - slave.responses_sent} writes "
        f"still unacknowledged"
    )
    assert not int(dut.o_busy.value), "o_busy is still set at o_done"
    slave.stop()


@cocotb.test()
async def test_covers_region_under_backpressure(dut: Any) -> None:
    """Stalled channels and delayed responses change nothing but the time."""
    await _reset(dut)
    slave = WriteSlave(dut, random.Random(7), aw_ready_p=0.4, w_ready_p=0.35, b_delay=6)
    await _run_to_done(dut)
    _check_coverage(slave)
    assert slave.responses_sent == TOTAL_BURSTS, "o_done with writes unacknowledged"
    assert slave.max_outstanding <= OUTSTANDING_CAP, (
        f"{slave.max_outstanding} writes were outstanding, above the "
        f"{OUTSTANDING_CAP} the module allows"
    )
    slave.stop()


@cocotb.test()
async def test_idle_before_start(dut: Any) -> None:
    """Nothing is driven until calibration is reported."""
    await _reset(dut)
    slave = WriteSlave(dut, random.Random(3))
    for _ in range(50):
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        assert not int(dut.o_awvalid.value), "a write address before i_start"
        assert not int(dut.o_wvalid.value), "write data before i_start"
    assert int(dut.o_busy.value), "o_busy dropped before the region was written"
    assert not slave.addresses, "the slave saw a burst before i_start"
    slave.stop()


@cocotb.test()
async def test_quiet_after_done(dut: Any) -> None:
    """After o_done the write channels stay idle: the board hands them back."""
    await _reset(dut)
    slave = WriteSlave(dut, random.Random(11))
    await _run_to_done(dut)
    bursts_at_done = len(slave.addresses)
    for _ in range(200):
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        assert not int(dut.o_awvalid.value), "a write address after o_done"
        assert not int(dut.o_wvalid.value), "write data after o_done"
        assert int(dut.o_done.value), "o_done did not stay set"
    assert len(slave.addresses) == bursts_at_done, "a burst was issued after o_done"
    slave.stop()


@cocotb.test()
async def test_starts_with_the_default_outstanding_cap(dut: Any) -> None:
    """The cap must not truncate against the counters and stall the start.

    The cap is compared at the counter width, which is sized by the burst
    count, so a region small enough for a narrow counter and a cap wider than
    it would leave the comparison reading zero: the address channel would
    never assert and nothing would be written. The registry runs this bench
    once in exactly that shape.
    """
    await _reset(dut)
    slave = WriteSlave(dut, random.Random(23))
    await _run_to_done(dut)
    _check_coverage(slave)
    slave.stop()


@cocotb.test()
async def test_address_may_wait_for_data(dut: Any) -> None:
    """A slave that holds AWREADY until it sees WVALID must still be served.

    AXI allows that ordering, so write data may not wait on the address
    handshake. If it did, both sides would wait for the other and no burst
    would ever be issued.
    """
    await _reset(dut)
    slave = WriteSlave(dut, random.Random(31), address_waits_for_data=True, b_delay=2)
    await _run_to_done(dut)
    _check_coverage(slave)
    assert slave.responses_sent == TOTAL_BURSTS, "o_done with writes unacknowledged"
    slave.stop()

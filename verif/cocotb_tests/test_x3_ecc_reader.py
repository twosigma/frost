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

"""Check x3_ecc_reader, the poller of the X3 DDR4 controller's ECC registers.

A model of the controller's register bank answers the reader's AXI4-Lite
transactions with random stalls while the bench injects corrected and
uncorrectable errors. The model follows the generated IP's
ddr4_v2_2_axi_ctrl_reg_bank.sv and ddr4_v2_2_axi_ctrl_reg.sv, one bench cycle
standing for one controller cycle:
- a status bit latches the capture (CE_FFA or UE_FFA) of the first error after
  it was last cleared, and CE_CNT counts one per error and stops at 255;
- a register write wins over the controller's own update in the same cycle;
- a status write that leaves a bit clear clears that bit's capture register in
  the next cycle, over a capture in that cycle.

The bench builds each capture the way the controller does, from the AXI
address through its ROW_COLUMN_BANK mapping (ddr4_v2_2_ui_cmd.sv) to the
register's packing (ddr4_v2_2_mc_ecc_dec_fix.sv), and expects the reader to
report the physical address of the captured 64-byte line, and no address for
an error whose capture was cleared. The reader may write only ECC_STATUS's CE
bit and CE_CNT back to 1, so the closing JTAG check still finds every run with
an error.
"""

import os
import random
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

CLOCK_PERIOD_NS = 10
# Must match the registry's -GPOLL_CYCLES.
POLL_CYCLES = int(os.environ.get("ECC_READER_POLL_CYCLES", "64"))
CTRL_BASE = 0x4000_0000
DDR_BASE = 0x8000_0000

ECC_STATUS = 0x000
ECC_ON_OFF = 0x008
CE_CNT = 0x00C
CE_FFA_LO = 0x1C0
CE_FFA_HI = 0x1C4
UE_FFA_LO = 0x2C0
UE_FFA_HI = 0x2C4
READ_OFFSETS = {
    ECC_STATUS,
    ECC_ON_OFF,
    CE_CNT,
    CE_FFA_LO,
    CE_FFA_HI,
    UE_FFA_LO,
    UE_FFA_HI,
}
STATUS_UE = 0x1
STATUS_CE = 0x2
CE_CNT_MAX = 255
RESP_OKAY = 0
RESP_SLVERR = 2

# The X3 controller's geometry (fpga/build/x3_ddr_bd.tcl): one rank, 17 row,
# 10 column, 2 bank and 1 bank-group bits, 8 bytes per beat, 8 beats a burst.
ROW_BITS = 17
DDR_BYTES = 8 << 30


def failing_address_register(phys: int, words: int) -> int:
    """Return the CE_FFA or UE_FFA value the controller captures for a burst.

    ``words`` flags the burst's failing ECC words.
    """
    app = ((phys - DDR_BASE) & ~63) >> 3
    column = (((app >> 6) & 0x7F) << 3) | (app & 0x7)
    group = (app >> 3) & 0x1
    bank = (app >> 4) & 0x3
    row = (app >> 13) & ((1 << ROW_BITS) - 1)
    return (words << 56) | (row << 24) | (column << 8) | (group << 2) | bank


def line_address(ffa: int) -> int:
    """Return the physical address of a capture's 64-byte line, as the bench built it."""
    row = (ffa >> 24) & ((1 << ROW_BITS) - 1)
    column = (ffa >> 8) & 0x3FF
    bank = ffa & 0x3
    group = (ffa >> 2) & 0x1
    app = (row << 13) | ((column >> 3) << 6) | (bank << 4) | (group << 3)
    return DDR_BASE + (app << 3)


@dataclass
class EccRegisters:
    """The controller's ECC registers, cycle by cycle, and what they recorded.

    Errors and the reader's writes in one cycle are pending until tick() ends
    the cycle and resolves them together, as the register bank does: a write
    wins over the cycle's own updates. Reads see the registers as the last
    cycle left them. The bench may put several error bursts in one cycle; each
    counts.
    """

    on_off: int = 1
    status: int = 0
    ce_cnt: int = 0
    ce_ffa: int = 0
    ue_ffa: int = 0
    cycle: int = 0
    pending_errors: list[tuple[int, int]] = field(default_factory=list)  # bit, capture
    pending_status_write: int | None = None
    pending_cnt_write: int | None = None
    # Capture clears that land at the end of a later cycle: cycle -> status bits.
    clears: dict[int, int] = field(default_factory=dict)
    # Each status bit's rise as the reader will see it: the capture, or None
    # when the capture register was cleared over it.
    ce_events: list[int | None] = field(default_factory=list)
    ue_events: list[int | None] = field(default_factory=list)
    counted: int = 0  # corrected errors CE_CNT counted
    lost: int = 0  # counted, then overwritten by the reader's CE_CNT write
    cnt_at_last_read: int = 0
    cnt_writes: list[int] = field(default_factory=list)
    # Callbacks run as the reader writes or reads a register, and actions to
    # run at the start of a later cycle: (cycle, function).
    on_write: list[Callable[["EccRegisters", int], None]] = field(default_factory=list)
    on_read: list[Callable[["EccRegisters", int], None]] = field(default_factory=list)
    scheduled: list[tuple[int, Callable[[], None]]] = field(default_factory=list)

    def corrected(self, ffa: int) -> None:
        """Add a read burst with a corrected error to this cycle."""
        self.pending_errors.append((STATUS_CE, ffa))

    def uncorrectable(self, ffa: int) -> None:
        """Add a read burst with an uncorrectable error to this cycle."""
        self.pending_errors.append((STATUS_UE, ffa))

    def _set_capture(self, bit: int, ffa: int) -> None:
        if bit == STATUS_CE:
            self.ce_ffa = ffa
        else:
            self.ue_ffa = ffa

    def tick(self) -> None:
        """End this cycle, resolving its writes and errors, and start the next."""
        clearing = self.clears.pop(self.cycle, 0)
        if self.pending_cnt_write is not None:
            self.lost += self.ce_cnt - self.cnt_at_last_read
            self.cnt_writes.append(self.cnt_at_last_read)
            self.ce_cnt = self.pending_cnt_write
        elif self.on_off:
            for bit, _ in self.pending_errors:
                if bit == STATUS_CE and self.ce_cnt < CE_CNT_MAX:
                    self.ce_cnt += 1
                    self.counted += 1
        if self.pending_status_write is not None:
            # The cycle's errors do not reach the status, but one of a kind
            # whose bit was clear still captures, for the one cycle until the
            # write's capture clear lands.
            for bit, ffa in self.pending_errors:
                if self.on_off and not self.status & bit:
                    self._set_capture(bit, ffa)
            self.status &= ~self.pending_status_write
            for bit in (STATUS_CE, STATUS_UE):
                if not self.status & bit:
                    self.clears[self.cycle + 1] = (
                        self.clears.get(self.cycle + 1, 0) | bit
                    )
        elif self.on_off:
            for bit, ffa in self.pending_errors:
                if self.status & bit:
                    continue
                self.status |= bit
                events = self.ce_events if bit == STATUS_CE else self.ue_events
                if clearing & bit:
                    events.append(None)
                else:
                    self._set_capture(bit, ffa)
                    events.append(ffa)
        for bit in (STATUS_CE, STATUS_UE):
            if clearing & bit:
                self._set_capture(bit, 0)
        self.pending_errors = []
        self.pending_status_write = None
        self.pending_cnt_write = None
        self.cycle += 1
        due = [action for when, action in self.scheduled if when == self.cycle]
        self.scheduled = [(w, a) for w, a in self.scheduled if w != self.cycle]
        for action in due:
            action()

    def jtag_clear(self) -> None:
        """Clear as ddr_ecc_status.py --clear does: CE_CNT to 0, both status bits."""
        self.ce_cnt = 0
        self.status = 0
        self.ce_ffa = 0
        self.ue_ffa = 0

    def external_capture(self, bit: int, ffa: int) -> None:
        """Latch an error at once, as one right after a JTAG clear would."""
        self.status |= bit
        self._set_capture(bit, ffa)
        if bit == STATUS_CE:
            self.ce_cnt += 1
            self.counted += 1

    def read(self, offset: int) -> int:
        """Return a register's value."""
        if offset == CE_CNT:
            self.cnt_at_last_read = self.ce_cnt
        value = {
            ECC_STATUS: self.status,
            ECC_ON_OFF: self.on_off,
            CE_CNT: self.ce_cnt,
            CE_FFA_LO: self.ce_ffa & 0xFFFF_FFFF,
            CE_FFA_HI: self.ce_ffa >> 32,
            UE_FFA_LO: self.ue_ffa & 0xFFFF_FFFF,
            UE_FFA_HI: self.ue_ffa >> 32,
        }[offset]
        for callback in list(self.on_read):
            callback(self, offset)
        return value

    def write(self, offset: int, value: int) -> None:
        """Add one of the two writes the reader may make to this cycle."""
        if offset == ECC_STATUS:
            assert value == STATUS_CE, (
                f"the reader wrote ECC_STATUS 0x{value:x}; it may clear only the CE bit"
            )
            self.pending_status_write = value
        elif offset == CE_CNT:
            assert value == 1, (
                f"the reader wrote CE_CNT {value}; it may only write it back to 1"
            )
            self.pending_cnt_write = value
        else:
            raise AssertionError(f"the reader wrote offset 0x{offset:03x}")
        for callback in list(self.on_write):
            callback(self, offset)


class AxiLiteSlave:
    """Serve the reader's transactions from an EccRegisters model.

    Ready signals rise with probability ``ready_p`` each cycle, and a response
    follows the request by up to ``max_delay`` cycles. ``fail_read`` makes
    that read (counting from 0) answer SLVERR.
    """

    def __init__(  # noqa: D107 - the class docstring covers the arguments
        self,
        dut: Any,
        model: EccRegisters,
        rng: random.Random,
        ready_p: float = 0.6,
        max_delay: int = 4,
        fail_read: int | None = None,
    ) -> None:
        self._dut = dut
        self._model = model
        self._rng = rng
        self._ready_p = ready_p
        self._max_delay = max_delay
        self._fail_read = fail_read
        self.reads = 0
        self._held: dict[str, tuple[int, ...] | None] = {
            "ar": None,
            "aw": None,
            "w": None,
        }
        self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        """Stop driving the bus."""
        self._task.cancel()

    def _check_persistence(self) -> None:
        dut = self._dut
        for channel, valid, ready, payload in (
            ("ar", dut.o_arvalid, dut.i_arready, (dut.o_araddr,)),
            ("aw", dut.o_awvalid, dut.i_awready, (dut.o_awaddr,)),
            ("w", dut.o_wvalid, dut.i_wready, (dut.o_wdata, dut.o_wstrb)),
        ):
            held = self._held[channel]
            now = tuple(int(signal.value) for signal in payload)
            if held is not None:
                assert int(valid.value), f"{channel.upper()}VALID dropped before ready"
                assert now == held, (
                    f"the {channel.upper()} payload changed before ready"
                )
            self._held[channel] = (
                now if int(valid.value) and not int(ready.value) else None
            )

    def _offset(self, address: int) -> int:
        offset = address - CTRL_BASE
        assert 0 <= offset < 0x8000, (
            f"address 0x{address:08x} is outside the ECC window"
        )
        return offset

    async def _run(self) -> None:
        dut = self._dut
        open_read = False  # an AR taken, its R not yet taken
        aw_address: int | None = None
        w_data: int | None = None
        response: tuple[str, int, int, int] | None = None  # channel, data, resp, delay
        rvalid = bvalid = 0
        rdata = rresp = bresp = 0
        while True:
            await FallingEdge(dut.i_clk)
            idle = (
                not open_read and aw_address is None and w_data is None and not response
            )
            write_open = aw_address is not None or w_data is not None
            take = self._rng.random() < self._ready_p
            dut.i_arready.value = int(take and idle)
            dut.i_awready.value = int(take and aw_address is None and not open_read)
            dut.i_wready.value = int(take and w_data is None and not open_read)
            if response is not None and response[3] <= 0 and not (rvalid or bvalid):
                channel, data, resp, _ = response
                if channel == "r":
                    rvalid, rdata, rresp = 1, data, resp
                else:
                    bvalid, bresp = 1, resp
            dut.i_rvalid.value = rvalid
            dut.i_rdata.value = rdata
            dut.i_rresp.value = rresp
            dut.i_bvalid.value = bvalid
            dut.i_bresp.value = bresp

            await ReadOnly()
            self._check_persistence()
            ar_fire = int(dut.o_arvalid.value) and int(dut.i_arready.value)
            aw_fire = int(dut.o_awvalid.value) and int(dut.i_awready.value)
            w_fire = int(dut.o_wvalid.value) and int(dut.i_wready.value)
            if not idle:
                assert not int(dut.o_arvalid.value), (
                    "a read was requested with one open"
                )
            if open_read:
                assert not (int(dut.o_awvalid.value) or int(dut.o_wvalid.value)), (
                    "a write was requested with a read open"
                )
            if write_open:
                assert not int(dut.o_arvalid.value), (
                    "a read was requested with a write open"
                )
            r_fire = rvalid and int(dut.o_rready.value)
            b_fire = bvalid and int(dut.o_bready.value)
            araddr = int(dut.o_araddr.value)
            awaddr = int(dut.o_awaddr.value)
            wdata = int(dut.o_wdata.value)
            wstrb = int(dut.o_wstrb.value)

            await RisingEdge(dut.i_clk)
            self._model.tick()
            if response is not None:
                response = (*response[:3], response[3] - 1)
            if ar_fire:
                offset = self._offset(araddr)
                assert offset in READ_OFFSETS, f"the reader read offset 0x{offset:03x}"
                failed = self.reads == self._fail_read
                value = 0 if failed else self._model.read(offset)
                resp = RESP_SLVERR if failed else RESP_OKAY
                self.reads += 1
                open_read = True
                response = ("r", value, resp, self._rng.randint(0, self._max_delay))
            if aw_fire:
                aw_address = awaddr
            if w_fire:
                assert wstrb == 0xF, f"the reader wrote with strobes 0x{wstrb:x}"
                w_data = wdata
            if aw_address is not None and w_data is not None and response is None:
                self._model.write(self._offset(aw_address), w_data)
                response = ("b", 0, RESP_OKAY, self._rng.randint(0, self._max_delay))
            if r_fire:
                rvalid = 0
                open_read = False
                response = None
            if b_fire:
                bvalid = 0
                aw_address = w_data = None
                response = None


class Reports:
    """Collect the reader's report pulses."""

    def __init__(self, dut: Any) -> None:  # noqa: D107
        self._dut = dut
        self.polls = 0
        self.ce_total = 0
        self.ce_addresses: list[int] = []
        self.ue_count = 0
        self.ue_addresses: list[int] = []
        self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        """Stop collecting."""
        self._task.cancel()

    async def _run(self) -> None:
        dut = self._dut
        while True:
            await RisingEdge(dut.i_clk)
            await ReadOnly()
            if int(dut.o_poll.value):
                self.polls += 1
            if int(dut.o_ce_valid.value):
                count = int(dut.o_ce_count.value)
                assert count > 0, "o_ce_valid reported no corrected errors"
                self.ce_total += count
            if int(dut.o_ce_addr_valid.value):
                self.ce_addresses.append(int(dut.o_ce_addr.value))
            if int(dut.o_ue_valid.value):
                self.ue_count += 1
            if int(dut.o_ue_addr_valid.value):
                assert int(dut.o_ue_valid.value), "a UE address without its error"
                self.ue_addresses.append(int(dut.o_ue_addr.value))


async def _start(dut: Any, enable: bool = True) -> None:
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_enable.value = 0
    for name in ("i_arready", "i_awready", "i_wready", "i_rvalid", "i_bvalid"):
        getattr(dut, name).value = 0
    dut.i_rdata.value = 0
    dut.i_rresp.value = 0
    dut.i_bresp.value = 0
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    if enable:
        dut.i_enable.value = 1


async def _wait_polls(dut: Any, reports: Reports, polls: int) -> None:
    target = reports.polls + polls
    for _ in range(polls * (POLL_CYCLES + 400)):
        await RisingEdge(dut.i_clk)
        if reports.polls >= target:
            return
    raise AssertionError(f"the reader did not finish {polls} more polls")


def _random_capture(rng: random.Random) -> int:
    phys = DDR_BASE + rng.randrange(DDR_BYTES)
    return failing_address_register(phys, rng.randrange(1, 256))


def _check(model: EccRegisters, reports: Reports) -> None:
    """Compare the reports with the model once the reader has caught up."""
    assert reports.ce_total == model.counted - model.lost, (
        f"reported {reports.ce_total} corrected errors; the controller counted "
        f"{model.counted} and the reader's CE_CNT writes overwrote {model.lost}"
    )
    expected_ce = [line_address(ffa) for ffa in model.ce_events if ffa is not None]
    assert reports.ce_addresses == expected_ce, (
        f"corrected-error addresses {[hex(a) for a in reports.ce_addresses]}, "
        f"expected {[hex(a) for a in expected_ce]}"
    )
    assert reports.ue_count == len(model.ue_events), (
        f"reported {reports.ue_count} uncorrectable errors, the controller "
        f"latched {len(model.ue_events)}"
    )
    expected_ue = [line_address(ffa) for ffa in model.ue_events if ffa is not None]
    assert reports.ue_addresses == expected_ue, (
        f"uncorrectable-error addresses {[hex(a) for a in reports.ue_addresses]}, "
        f"expected {[hex(a) for a in expected_ue]}"
    )
    if model.counted:
        assert model.ce_cnt != 0, "CE_CNT reads 0 after corrected errors"


@cocotb.test()
async def test_idle_before_enable(dut: Any) -> None:
    """The reader leaves the bus idle until i_enable."""
    await _start(dut, enable=False)
    for _ in range(3 * POLL_CYCLES):
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        assert not int(dut.o_arvalid.value), "a read before i_enable"
        assert not int(dut.o_awvalid.value), "a write before i_enable"
        assert not int(dut.o_active.value), "active before i_enable"


@cocotb.test()
async def test_random_errors(dut: Any) -> None:
    """Counts and addresses of random corrected and uncorrectable errors.

    At this rate some errors land in a status write's cycle or the next, so
    the register bank's priority and its delayed capture clears come up too.
    """
    rng = random.Random(0xECC1)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 1)
    assert int(dut.o_active.value), "the reader is not active with checking on"

    for cycle in range(60 * POLL_CYCLES):
        await FallingEdge(dut.i_clk)
        roll = rng.random()
        if roll < 0.04:
            model.corrected(_random_capture(rng))
        elif roll < 0.042 or (cycle == 40 * POLL_CYCLES and not model.ue_events):
            model.uncorrectable(_random_capture(rng))
    await _wait_polls(dut, reports, 3)
    slave.stop()
    reports.stop()

    assert len([e for e in model.ce_events if e is not None]) > 20, (
        "too few corrected-error captures to judge"
    )
    assert len(model.ue_events) == 1, "the reader cleared the UE status"
    assert model.status & STATUS_UE, "the UE status bit was cleared"
    _check(model, reports)


@cocotb.test()
async def test_status_write_races(dut: Any) -> None:
    """Errors in a CE clear's cycle and the next follow the register bank.

    A UE in the write's cycle never sets its bit. An error in the cycle after
    sets its bit over a cleared capture, which the reader reports without an
    address, rather than as the address of capture zero.
    """
    rng = random.Random(0xECC7)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 1)

    def race(registers: EccRegisters, offset: int) -> None:
        if offset != ECC_STATUS:
            return
        registers.on_write.remove(race)
        registers.uncorrectable(_random_capture(rng))  # the write's cycle: lost
        after = registers.cycle + 1
        registers.scheduled.append(
            (after, lambda: registers.corrected(_random_capture(rng)))
        )
        registers.scheduled.append(
            (after, lambda: registers.uncorrectable(_random_capture(rng)))
        )

    model.on_write.append(race)
    await FallingEdge(dut.i_clk)
    model.corrected(_random_capture(rng))
    await _wait_polls(dut, reports, 4)
    slave.stop()
    reports.stop()

    assert model.ce_events[1:] == [None], f"CE events {model.ce_events}"
    assert model.ue_events == [None], f"UE events {model.ue_events}"
    assert reports.ue_count == 1, "the uncorrectable error after the clear was lost"
    assert not reports.ue_addresses, "an empty capture was reported as an address"
    _check(model, reports)


@cocotb.test()
async def test_count_written_back(dut: Any) -> None:
    """CE_CNT is written back to 1 past 128, and saturation drops the excess."""
    rng = random.Random(0xECC2)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng, ready_p=0.9, max_delay=1)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 1)

    # Bursts of errors between polls: one under the threshold, two over it,
    # and one past the controller's saturation.
    bursts = (100, 60, 200, 400, 5)
    for count in bursts:
        await FallingEdge(dut.i_clk)
        for _ in range(count):
            model.corrected(_random_capture(rng))
        await _wait_polls(dut, reports, 2)
    slave.stop()
    reports.stop()

    assert model.cnt_writes, "the reader never wrote CE_CNT back"
    assert all(value >= 128 for value in model.cnt_writes), (
        f"CE_CNT written back after reading {model.cnt_writes}"
    )
    assert model.counted < sum(bursts), "saturation never dropped any"
    _check(model, reports)


@cocotb.test()
async def test_jtag_clear(dut: Any) -> None:
    """After the JTAG check's clear, new errors count and capture again."""
    rng = random.Random(0xECC3)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 1)

    await FallingEdge(dut.i_clk)
    for _ in range(10):
        model.corrected(_random_capture(rng))
    model.uncorrectable(_random_capture(rng))
    await _wait_polls(dut, reports, 2)
    assert reports.ce_total == model.counted == 10

    await FallingEdge(dut.i_clk)
    model.jtag_clear()
    await _wait_polls(dut, reports, 2)
    await FallingEdge(dut.i_clk)
    for _ in range(3):
        model.corrected(_random_capture(rng))
    model.uncorrectable(_random_capture(rng))
    await _wait_polls(dut, reports, 2)
    slave.stop()
    reports.stop()

    assert len(model.ue_events) == 2
    _check(model, reports)


@cocotb.test()
async def test_address_corners(dut: Any) -> None:
    """Directed addresses at the corners of each field, one per poll."""
    rng = random.Random(0xECC4)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 1)

    corners = [
        (DDR_BASE, 0x01),
        (DDR_BASE + 0x38, 0x80),  # inside the first line
        (DDR_BASE + DDR_BYTES - 64, 0xFF),
        (DDR_BASE + (1 << 6), 0x02),  # bank group
        (DDR_BASE + (3 << 7), 0x04),  # bank
        (DDR_BASE + (0x7F << 9), 0x10),  # column 9:3
        (DDR_BASE + (1 << 16), 0x20),  # row 0
        (DDR_BASE + (1 << 32), 0x40),  # row 16
        (DDR_BASE + 0x3FFF_FFC0, 0x08),  # top of the CPU's 1 GiB
    ]
    for phys, words in corners:
        await FallingEdge(dut.i_clk)
        model.corrected(failing_address_register(phys, words))
        await _wait_polls(dut, reports, 2)
    slave.stop()
    reports.stop()

    assert reports.ce_addresses == [phys & ~63 for phys, _ in corners]
    _check(model, reports)


@cocotb.test()
async def test_checking_off(dut: Any) -> None:
    """With checking off the reader is inactive but keeps polling."""
    rng = random.Random(0xECC5)
    await _start(dut)
    model = EccRegisters(on_off=0)
    slave = AxiLiteSlave(dut, model, rng)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 3)
    slave.stop()
    reports.stop()
    assert not int(dut.o_active.value), "active with checking off"


@cocotb.test()
async def test_error_response_stops(dut: Any) -> None:
    """A response other than OKAY stops the reader, its polls and o_active."""
    rng = random.Random(0xECC6)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng, fail_read=5)
    reports = Reports(dut)
    for _ in range(20 * POLL_CYCLES):
        await RisingEdge(dut.i_clk)
        if slave.reads > 5:
            break
    assert slave.reads == 6, "the failing read never happened"
    for _ in range(5 * POLL_CYCLES):
        await RisingEdge(dut.i_clk)
    polls = reports.polls
    for _ in range(3 * POLL_CYCLES):
        await RisingEdge(dut.i_clk)
    slave.stop()
    reports.stop()
    assert slave.reads == 6, "the reader kept reading after an error response"
    assert not int(dut.o_active.value), "still active after an error response"
    assert reports.polls == polls, "a stopped reader still reports polls"


@cocotb.test()
async def test_a_stopped_poll_keeps_its_count(dut: Any) -> None:
    """A count read before a failing transaction is still reported."""
    rng = random.Random(0xECC8)
    await _start(dut)
    model = EccRegisters()
    # Reads: 0 ECC_ON_OFF, then the first poll's 1 ECC_STATUS, 2 CE_CNT and
    # 3 CE_FFA_HI, which fails.
    slave = AxiLiteSlave(dut, model, rng, fail_read=3)
    reports = Reports(dut)
    for _ in range(7):
        model.corrected(_random_capture(rng))
    for _ in range(4 * POLL_CYCLES):
        await RisingEdge(dut.i_clk)
    slave.stop()
    reports.stop()
    assert slave.reads == 4
    assert reports.ce_total == 7, f"reported {reports.ce_total} of 7"
    assert not reports.ce_addresses


@cocotb.test()
async def test_count_write_cycle(dut: Any) -> None:
    """A corrected error in the cycle of the CE_CNT write-back goes uncounted."""
    rng = random.Random(0xECC9)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 1)

    def same_cycle(registers: EccRegisters, offset: int) -> None:
        if offset != CE_CNT:
            return
        registers.on_write.remove(same_cycle)
        registers.corrected(_random_capture(rng))

    model.on_write.append(same_cycle)
    await FallingEdge(dut.i_clk)
    for _ in range(130):
        model.corrected(_random_capture(rng))
    await _wait_polls(dut, reports, 3)
    slave.stop()
    reports.stop()

    assert model.cnt_writes == [130], f"CE_CNT written back after {model.cnt_writes}"
    assert model.counted == 130, "the write-back's cycle counted its error"
    _check(model, reports)


@cocotb.test()
async def test_a_failure_keeps_a_seen_uncorrectable_error(dut: Any) -> None:
    """An uncorrectable error seen before a failing read is still reported."""
    rng = random.Random(0xECCA)
    await _start(dut)
    model = EccRegisters()
    # Reads: 0 ECC_ON_OFF, then the first poll's 1 ECC_STATUS, with the UE bit
    # set, and 2 CE_CNT, which fails.
    slave = AxiLiteSlave(dut, model, rng, fail_read=2)
    reports = Reports(dut)
    model.uncorrectable(_random_capture(rng))
    for _ in range(4 * POLL_CYCLES):
        await RisingEdge(dut.i_clk)
    slave.stop()
    reports.stop()
    assert slave.reads == 3
    assert reports.ue_count == 1, "the seen uncorrectable error was dropped"
    assert not reports.ue_addresses, "an address from a read that never happened"
    assert not int(dut.o_active.value)


@cocotb.test()
async def test_a_capture_replaced_mid_read_gives_no_address(dut: Any) -> None:
    """A JTAG clear and a new capture between a capture's reads give no address.

    The two captures' halves would combine into an address that is neither's.
    """
    rng = random.Random(0xECCB)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 1)

    first = failing_address_register(DDR_BASE + 0x0001_0040, 0x01)
    second = failing_address_register(DDR_BASE + 0x0102_0080, 0x02)
    assert first >> 32 != second >> 32
    assert first & 0xFFFF_FFFF != second & 0xFFFF_FFFF

    def replace(registers: EccRegisters, offset: int) -> None:
        if offset != CE_FFA_HI:
            return
        registers.on_read.remove(replace)
        registers.jtag_clear()
        registers.external_capture(STATUS_CE, second)

    model.on_read.append(replace)
    await FallingEdge(dut.i_clk)
    model.corrected(first)
    await _wait_polls(dut, reports, 3)
    slave.stop()
    reports.stop()
    assert not reports.ce_addresses, (
        f"reported {[hex(a) for a in reports.ce_addresses]} from a torn capture"
    )


@cocotb.test()
async def test_a_capture_cleared_then_replaced_gives_no_address(dut: Any) -> None:
    """A capture read across its clear and a new capture with the same high half.

    The register goes from the first capture to zero to the second between
    the reads, and the halves would combine into an address that is neither's.
    """
    rng = random.Random(0xECCC)
    await _start(dut)
    model = EccRegisters()
    slave = AxiLiteSlave(dut, model, rng)
    reports = Reports(dut)
    await _wait_polls(dut, reports, 1)

    first = failing_address_register(DDR_BASE + 0x0001_0040, 0x01)
    second = failing_address_register(DDR_BASE + 0x0002_0080, 0x01)
    assert first >> 32 == second >> 32
    assert first & 0xFFFF_FFFF != second & 0xFFFF_FFFF

    def clear_after_high(registers: EccRegisters, offset: int) -> None:
        if offset != CE_FFA_HI:
            return
        registers.on_read.remove(clear_after_high)
        registers.jtag_clear()
        registers.on_read.append(capture_after_low)

    def capture_after_low(registers: EccRegisters, offset: int) -> None:
        if offset != CE_FFA_LO:
            return
        registers.on_read.remove(capture_after_low)
        registers.external_capture(STATUS_CE, second)

    model.on_read.append(clear_after_high)
    await FallingEdge(dut.i_clk)
    model.corrected(first)
    await _wait_polls(dut, reports, 3)
    slave.stop()
    reports.stop()
    assert not reports.ce_addresses, (
        f"reported {[hex(a) for a in reports.ce_addresses]} from a torn capture"
    )

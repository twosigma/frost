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

"""Drive the real VCU118 board's MMCM, subsystem and DDR block-design ports."""

from collections import deque
from typing import Any

import cocotb
from cocotb.triggers import Timer

WORDS = 4
WORD_BYTES = 64
FULL_STRB = (1 << WORD_BYTES) - 1
OKAY, SLVERR, DECERR = 0, 2, 3


class Board:
    """Clock and AXI peers for the board's reset shifters and S00 multiplexer."""

    def __init__(self, dut: Any) -> None:
        """Connect at the IP boundaries used on the board."""
        self.dut = dut
        self.clk = dut.u_clock_gen
        self.cpu = dut.u_frost_subsystem
        self.ddr = dut.gen_real_ddr.ddr_subsystem
        self.init = dut.gen_real_ddr.u_ddr_init
        self.cycle = 0
        self.epoch = 0
        self.in_reset = False
        self.core_shift = self.jtag_shift = 0
        self.hold_b = False
        self.refuse_one = False
        self.ecc_faults = 0
        self.aw: deque[tuple[int, int, bool]] = deque()
        self.w: deque[tuple[int, int, bool]] = deque()
        self.b: deque[tuple[int, int, bool]] = deque()
        self.r: deque[tuple[int, int, int]] = deque()
        self.cpu_b: list[tuple[int, int]] = []
        self.cpu_r: list[tuple[int, int, int]] = []
        self.scrub_writes: list[int] = []
        self.scrub_b: list[int] = []
        self.data: list[int] = []
        self.ecc_valid: list[bool] = []

    def _controller_reset(self) -> None:
        # SmartConnect discards both halves of a write and all pending replies.
        self.aw.clear()
        self.w.clear()
        self.b.clear()
        self.r.clear()
        self.scrub_writes.clear()
        self.scrub_b.clear()
        self.epoch += 1
        self.ecc_valid = [False] * WORDS
        self.data = [self.epoch * 0xFEED if n % 2 else 0 for n in range(WORDS)]
        self.hold_b = self.refuse_one = False

    async def pins(self, button: int, locked: int, ready: int) -> None:
        """Change asynchronous sources without advancing either clock."""
        self.dut.cpu_reset.value = button
        self.clk.o_locked.value = locked
        self.ddr.mem_ok.value = ready
        await Timer(1, unit="ns")
        reset = bool(button or not locked)
        assert int(self.clk.i_rst.value) == button
        assert int(self.ddr.sys_reset.value) == reset
        assert int(self.ddr.cpu_aresetn.value) == (not reset)
        assert int(self.cpu.i_ddr_axi_rst_n.value) == (not reset)
        if reset:
            self.core_shift = self.jtag_shift = 0
            if not self.in_reset:
                self._controller_reset()
        self.in_reset = reset
        self._drive_slave()

    def _drive_slave(self) -> None:
        d = self.ddr
        ready = int(d.cpu_aresetn.value) and int(d.mem_ok.value)
        d.S00_AXI_awready.value = ready
        d.S00_AXI_wready.value = ready
        d.S00_AXI_arready.value = ready
        bid, bresp, _ = self.b[0] if self.b else (0, OKAY, False)
        d.S00_AXI_bid.value = bid
        d.S00_AXI_bresp.value = bresp
        d.S00_AXI_bvalid.value = int(bool(self.b) and not self.hold_b)
        rid, data, rresp = self.r[0] if self.r else (0, 0, OKAY)
        d.S00_AXI_rvalid.value = int(bool(self.r))
        d.S00_AXI_rid.value = rid
        d.S00_AXI_rdata.value = data
        d.S00_AXI_rresp.value = rresp
        d.S00_AXI_rlast.value = 1

    def _sample_axi(self) -> None:
        d = self.ddr
        c = self.cpu
        init = bool(self.init.o_busy.value)
        if d.S00_AXI_bvalid.value and d.S00_AXI_bready.value:
            bid, resp, owner = self.b.popleft()
            assert owner == init, "S00 changed owner with a response outstanding"
            if owner:
                self.scrub_b.append(resp)
            else:
                assert c.i_ddr_axi_bvalid.value
                self.cpu_b.append(
                    (int(c.i_ddr_axi_bid.value), int(c.i_ddr_axi_bresp.value))
                )
                assert self.cpu_b[-1] == (bid, resp)
        if d.S00_AXI_rvalid.value and d.S00_AXI_rready.value:
            assert c.i_ddr_axi_rvalid.value and c.i_ddr_axi_rlast.value
            self.cpu_r.append(
                (
                    int(c.i_ddr_axi_rid.value),
                    int(c.i_ddr_axi_rdata.value),
                    int(c.i_ddr_axi_rresp.value),
                )
            )
            assert self.cpu_r[-1] == self.r.popleft()
        if d.S00_AXI_awvalid.value and d.S00_AXI_awready.value:
            assert int(d.S00_AXI_awlen.value) == 0
            assert (
                int(d.S00_AXI_awsize.value) == 6 and int(d.S00_AXI_awburst.value) == 1
            )
            addr = int(d.S00_AXI_awaddr.value)
            assert addr % WORD_BYTES == 0 and addr < WORDS * WORD_BYTES
            self.aw.append((addr, int(d.S00_AXI_awid.value), init))
        if d.S00_AXI_wvalid.value and d.S00_AXI_wready.value:
            assert d.S00_AXI_wlast.value
            self.w.append(
                (int(d.S00_AXI_wdata.value), int(d.S00_AXI_wstrb.value), init)
            )
        if self.aw and self.w:
            addr, bid, aw_owner = self.aw.popleft()
            data, strobe, w_owner = self.w.popleft()
            assert aw_owner == w_owner, "S00 changed owner between AW and W"
            index = addr // WORD_BYTES
            resp = OKAY
            if aw_owner:
                assert (bid, data, strobe) == (0, 0, FULL_STRB)
                assert addr == len(self.scrub_writes) * WORD_BYTES, (
                    "scrub gap or replay"
                )
                self.scrub_writes.append(addr)
            if self.refuse_one:
                resp = DECERR
                self.refuse_one = False
            elif strobe == FULL_STRB:
                self.data[index] = data
                self.ecc_valid[index] = True
            elif not self.ecc_valid[index]:
                self.ecc_faults += 1
                resp = SLVERR
            else:
                mask = sum(
                    0xFF << (8 * n) for n in range(WORD_BYTES) if strobe & (1 << n)
                )
                self.data[index] = (self.data[index] & ~mask) | (data & mask)
            self.b.append((bid, resp, aw_owner))
        if d.S00_AXI_arvalid.value and d.S00_AXI_arready.value:
            addr = int(d.S00_AXI_araddr.value)
            assert addr % WORD_BYTES == 0 and addr < WORDS * WORD_BYTES
            assert int(d.S00_AXI_arlen.value) == 0
            assert (
                int(d.S00_AXI_arsize.value) == 6 and int(d.S00_AXI_arburst.value) == 1
            )
            index = addr // WORD_BYTES
            resp = OKAY if self.ecc_valid[index] else SLVERR
            self.ecc_faults += int(resp == SLVERR)
            self.r.append((int(d.S00_AXI_arid.value), self.data[index], resp))

    async def tick(self) -> None:
        """Sample the channel handshakes before the main rising edge."""
        self._drive_slave()
        await Timer(4, unit="ns")
        qualified = bool(self.dut.mem_ok_synced.value and self.init.o_done.value)
        self.core_shift = (
            ((self.core_shift << 1 | qualified) & 15) if not self.in_reset else 0
        )
        div_rise = self.cycle % 4 == 0
        if div_rise:
            self.jtag_shift = (
                ((self.jtag_shift << 1 | qualified) & 3) if not self.in_reset else 0
            )
        self._sample_axi()
        self.clk.o_clk_cpu.value = 1
        self.clk.o_clk_div4.value = int(self.cycle % 4 < 2)
        await Timer(5, unit="ns")
        assert int(self.cpu.i_rst_n.value) == self.core_shift >> 3, (
            f"core at edge {self.cycle}"
        )
        assert int(self.ddr.jtag_aresetn.value) == self.jtag_shift >> 1, (
            f"JTAG at edge {self.cycle}"
        )
        self.clk.o_clk_cpu.value = 0
        await Timer(1, unit="ns")
        self.cycle += 1

    def reset_quiet(self) -> None:
        """Check the asynchronous reset at the pins before any clock edge."""
        assert not self.cpu.i_rst_n.value and not self.ddr.jtag_aresetn.value
        assert not self.init.i_rst_n.value and self.init.o_busy.value
        assert not self.ddr.S00_AXI_awvalid.value and not self.ddr.S00_AXI_wvalid.value
        assert not self.ddr.S00_AXI_bready.value
        for name in (
            "o_done",
            "o_awvalid",
            "o_wvalid",
            "o_bready",
            "started_q",
            "addr_q",
            "aw_q",
            "w_q",
            "b_q",
            "beat_q",
            "resp_error_q",
        ):
            assert not int(getattr(self.init, name).value), name

    async def release_controller(self, *, check_edges: bool = True) -> None:
        """Hold calibration low for 24 clocks and check the three release stages."""
        await self.pins(0, 1, 0)
        for edge in range(1, 25):
            if check_edges:
                assert int(self.init.i_rst_n.value) == int(edge > 3)
            await self.tick()
            if check_edges:
                assert int(self.init.i_rst_n.value) == int(edge >= 3)
            assert not self.init.started_q.value and not self.init.o_done.value
            assert (
                not self.ddr.S00_AXI_awvalid.value and not self.ddr.S00_AXI_wvalid.value
            )
            assert not self.cpu.i_rst_n.value and not self.ddr.jtag_aresetn.value
        assert not self.scrub_writes and not self.scrub_b and not any(self.ecc_valid)

    async def sweep(self) -> None:
        """Delay the final B and count each requester's release edges from DONE."""
        await self.pins(0, 1, 1)
        self.hold_b = True
        for _ in range(32):
            await self.tick()
            if len(self.scrub_writes) == WORDS:
                break
        assert self.scrub_writes == list(range(0, WORDS * WORD_BYTES, WORD_BYTES))
        assert len(self.b) == WORDS and not self.scrub_b
        self.hold_b = False
        for _ in range(WORDS - 1):
            await self.tick()
        assert self.scrub_b == [OKAY] * (WORDS - 1)
        self.hold_b = True
        for _ in range(4):
            await self.tick()
            assert not self.init.o_done.value
            assert not self.cpu.i_rst_n.value and not self.ddr.jtag_aresetn.value
        self.hold_b = False
        await self.tick()
        assert self.scrub_b == [OKAY] * WORDS and not self.init.o_done.value
        await self.tick()
        assert self.init.o_done.value and not self.init.o_busy.value
        assert all(self.ecc_valid) and self.data == [0] * WORDS
        done_edge = self.cycle
        jtag_edges = 0
        jtag_release = 0
        for offset in range(1, 9):
            jtag_edges += int(self.cycle % 4 == 0)
            await self.tick()
            assert bool(self.cpu.i_rst_n.value) == (offset >= 4)
            assert bool(self.ddr.jtag_aresetn.value) == (jtag_edges >= 2)
            if self.ddr.jtag_aresetn.value and not jtag_release:
                jtag_release = self.cycle
        self.dut._log.info(
            "sweep %d: offsets %s, %d OKAY responses, DONE edge %d, core edge %d, JTAG edge %d (two div4 edges)",
            self.epoch,
            self.scrub_writes,
            len(self.scrub_b),
            done_edge,
            done_edge + 4,
            jtag_release,
        )

    async def read(self, index: int, expected: int) -> None:
        """Read a full word through the CPU's actual S00 read and response pins."""
        c = self.cpu
        count = len(self.cpu_r)
        c.o_ddr_axi_araddr.value = index * WORD_BYTES
        c.o_ddr_axi_arvalid.value = 1
        await self.tick()
        c.o_ddr_axi_arvalid.value = 0
        await self.tick()
        assert self.cpu_r[count:] == [(7, expected, OKAY)]

    async def first_accesses(self) -> None:
        """Read all four scrubbed words, then partially overwrite and read each."""
        c = self.cpu
        for index in range(WORDS):
            await self.read(index, 0)
        for index in range(WORDS):
            data = 0x1234_5678_90AB_CDEF ^ index
            c.o_ddr_axi_awaddr.value = index * WORD_BYTES
            c.o_ddr_axi_wdata.value = (0xBAD << 64) | data
            c.o_ddr_axi_awvalid.value = c.o_ddr_axi_wvalid.value = 1
            count = len(self.cpu_b)
            await self.tick()
            c.o_ddr_axi_awvalid.value = c.o_ddr_axi_wvalid.value = 0
            await self.tick()
            assert self.cpu_b[count:] == [(5, OKAY)]
            await self.read(index, data)
        assert self.ecc_faults == 0
        self.dut._log.info(
            "sweep %d: first reads returned zero; four partial writes and readbacks OKAY",
            self.epoch,
        )

    async def boot(self, *, check_edges: bool = False) -> None:
        """Start from a controller reset and exercise the initially released ports."""
        assert int(self.init.REGION_BYTES.value) == WORDS * WORD_BYTES
        self.clk.o_clk_cpu.value = self.clk.o_clk_div4.value = 0
        c = self.cpu
        c.o_ddr_axi_awvalid.value = c.o_ddr_axi_wvalid.value = (
            c.o_ddr_axi_arvalid.value
        ) = 0
        c.o_ddr_axi_rready.value = c.o_ddr_axi_bready.value = 1
        c.o_ddr_axi_awlen.value = c.o_ddr_axi_arlen.value = 0
        c.o_ddr_axi_awsize.value = c.o_ddr_axi_arsize.value = 6
        c.o_ddr_axi_awburst.value = c.o_ddr_axi_arburst.value = 1
        c.o_ddr_axi_awid.value, c.o_ddr_axi_arid.value = 5, 7
        c.o_ddr_axi_wlast.value, c.o_ddr_axi_wstrb.value = 1, 0xFF
        await self.pins(0, 1, 0)
        await self.pins(1, 0, 0)
        for _ in range(4):
            await self.tick()
        self.reset_quiet()
        # Warm-reset cases start from a completed cold sweep. The cold-release
        # case checks the edge count on that first pass as well.
        await self.release_controller(check_edges=check_edges)
        await self.sweep()
        await self.first_accesses()

    async def pulse(self, form: str) -> None:
        """Reset while clocks run, between rising edges, or with both clocks frozen."""
        keep_lock = form.startswith("button_")
        edge_before = self.cycle
        await self.pins(1, int(keep_lock), 0)
        self.reset_quiet()
        if form == "button_leads_lock":
            await self.tick()
            await self.tick()
            await self.pins(1, 0, 0)
        if form in ("sampled", "button_leads_lock"):
            for _ in range(3):
                await self.tick()
                self.reset_quiet()
        elif form in ("stopped", "button_stopped"):
            await Timer(120, unit="ns")
            self.reset_quiet()
        else:
            await Timer(1, unit="ns")
        self.dut._log.info(
            "%s: lock at assertion %d, core/JTAG/init held before next edge %d, %d main edges during pulse",
            form,
            keep_lock,
            edge_before + 1,
            self.cycle - edge_before,
        )
        await self.release_controller()


@cocotb.test(timeout_time=10, timeout_unit="us")
async def test_cold_release(dut: Any) -> None:
    """Switch from reset to the first full scrub and both qualified releases."""
    await Board(dut).boot(check_edges=True)


@cocotb.test(timeout_time=10, timeout_unit="us")
@cocotb.parametrize(
    form=(
        "sampled",
        "button_leads_lock",
        "between_edges",
        "button_between_edges",
        "stopped",
        "button_stopped",
        "loss_of_lock",
    )
)
async def test_controller_reset(dut: Any, form: str) -> None:
    """Controller resets invalidate ECC and start a second complete sweep."""
    board = Board(dut)
    await board.boot()
    if form == "loss_of_lock":
        await board.pins(0, 0, 0)
        board.reset_quiet()
        await board.release_controller()
    else:
        await board.pulse(form)
    await board.sweep()
    await board.first_accesses()


@cocotb.test(timeout_time=10, timeout_unit="us")
@cocotb.parametrize(form=("sampled", "between_edges", "stopped"))
async def test_reset_outstanding_writes(dut: Any, form: str) -> None:
    """Discard an incomplete pass with both write VALIDs and a B outstanding."""
    board = Board(dut)
    await board.boot()
    await board.pulse("sampled")
    board.hold_b = True
    await board.pins(0, 1, 1)
    for _ in range(16):
        await board.tick()
        if board.b and board.init.o_awvalid.value and board.init.o_wvalid.value:
            break
    assert 0 < int(board.init.aw_q.value) < WORDS
    assert len(board.b) == int(board.init.aw_q.value) - int(board.init.b_q.value) > 0
    assert board.init.o_awvalid.value and board.init.o_wvalid.value
    dut._log.info(
        "%s: aborting %d unacknowledged writes with AWVALID and WVALID high",
        form,
        len(board.b),
    )
    await board.pulse(form)
    await board.sweep()
    await board.first_accesses()


@cocotb.test(timeout_time=10, timeout_unit="us")
async def test_reset_after_decerr(dut: Any) -> None:
    """A refused write withholds release until another controller reset."""
    board = Board(dut)
    await board.boot()
    await board.pulse("sampled")
    board.refuse_one = True
    await board.pins(0, 1, 1)
    for _ in range(32):
        await board.tick()
    assert board.scrub_b == [DECERR] + [OKAY] * (WORDS - 1)
    assert board.init.resp_error_q.value and not board.init.o_done.value
    assert not board.cpu.i_rst_n.value and not board.ddr.jtag_aresetn.value
    await board.pulse("stopped")
    await board.sweep()
    await board.first_accesses()


@cocotb.test(timeout_time=10, timeout_unit="us")
async def test_calibration_only(dut: Any) -> None:
    """Preserve ECC and the S00 owner with an accepted AW waiting for data."""
    board = Board(dut)
    await board.boot()
    c, d = board.cpu, board.ddr
    data_before = board.data.copy()
    c.o_ddr_axi_awaddr.value, c.o_ddr_axi_awvalid.value = WORD_BYTES, 1
    await board.tick()
    c.o_ddr_axi_awvalid.value = 0
    assert list(board.aw) == [(WORD_BYTES, 5, False)]
    await board.pins(0, 1, 0)
    c.o_ddr_axi_wdata.value, c.o_ddr_axi_wvalid.value = 0x7654, 1
    for _ in range(24):
        await board.tick()
        assert board.init.o_done.value and not board.init.o_busy.value
        assert d.cpu_aresetn.value and not d.sys_reset.value
        assert d.S00_AXI_wvalid.value and int(d.S00_AXI_wdata.value) == 0x7654
        assert not d.S00_AXI_wready.value and board.data == data_before
    assert not c.i_rst_n.value and not d.jtag_aresetn.value
    count = len(board.cpu_b)
    await board.pins(0, 1, 1)
    await board.tick()
    c.o_ddr_axi_wvalid.value = 0
    for _ in range(10):
        await board.tick()
    assert c.i_rst_n.value and d.jtag_aresetn.value
    assert board.cpu_b[count:] == [(5, OKAY)]
    data_before[1] = 0x7654
    for index, expected in enumerate(data_before):
        await board.read(index, expected)
    assert board.epoch == 1 and len(board.scrub_writes) == len(board.scrub_b) == WORDS
    assert all(board.ecc_valid) and not board.ecc_faults
    dut._log.info(
        "24 calibration-low edges: both requesters held, one sweep, split AW/W completed OKAY, all words retained"
    )

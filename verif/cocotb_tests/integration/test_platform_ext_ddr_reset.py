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

"""Exercise external DMA and AXI4-Lite traffic across a DDR interconnect reset."""

from typing import Any, NamedTuple

import cocotb
from cocotb.handle import Immediate
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

from cocotb_tests.axi.axi_models import AxiSlaveMemory
from cocotb_tests.axi.test_soc_ext_plugins import DDR_BASE, PackedExtDmaDriver
from cocotb_tests.integration.test_platform_dma_reset import _start_dma
from encoders.instruction_encode import enc_i, enc_i_load, enc_j, enc_lui, enc_s


async def _boot(dut: Any, words: list[int], initial: dict[int, int]) -> AxiSlaveMemory:
    for port, pins in (
        (
            "dma",
            "awvalid awid awaddr awlen awsize awburst awlock awcache awprot awqos "
            "wvalid wdata wstrb wlast bready arvalid arid araddr arlen arsize arburst "
            "arlock arcache arprot arqos rready",
        ),
        ("axil", "awready wready bvalid bresp arready rvalid rdata rresp"),
        (
            "mac",
            "tx_tready rx_tvalid rx_tdata rx_tkeep rx_tlast ready link "
            "raw_loopback_en rx_fifo_limit_busy totals",
        ),
    ):
        for pin in pins.split():
            getattr(dut, f"i_ext_{port}_{pin}").value = Immediate(0)
    image = [(4 * pc, word) for pc, word in enumerate(words)]
    ram = await _start_dma(dut, dut.i_cpu_clk, image=image, reset_ddr=True)
    ram.mem.clear()
    ram.mem.update(initial)
    await ClockCycles(dut.i_clk, 8)
    assert not int(dut.o_soc_rst.value)
    return ram


class ResetEdge(NamedTuple):
    """Inputs sampled by the flops on one rising edge."""

    resets: tuple[int, int, int, int]  # o_soc_rst, o_ext_mac_rst, transport, CPU
    ready: tuple[int, int, int]  # packed AR, AW and W READY for both DMA ports
    owners: tuple[int, int, int]  # outstanding bridge reads, writes and ingress slots


async def _ddr_pulse(dut: Any, *, offer: bool = False) -> list[ResetEdge]:
    tier = dut.soc.gen_cached_tier
    ports = tier.gen_ext_dma.gen_port
    window = dut.soc.gen_ext_axil.u_ext_axil_slice
    bridge = tier.dma_bridge
    ingress = dut.cpu.cluster_memory.gen_coherent_tier.gen_dma_ingress.ingress
    common_pins = (
        ports[0].u_slice.i_rst,
        ports[1].u_slice.i_rst,
        window.i_rst,
        tier.dma_interconnect.i_rst,
        bridge.i_rst,
    )
    edges = []
    dut.i_ddr_axi_rst.value = 1
    for n in range(1, 5):
        await RisingEdge(dut.i_clk)
        assert not int(dut.i_rst.value) and not int(dut.i_power_on_rst.value)
        assert int(dut.i_ddr_axi_rst.value) == int(n == 1)
        soc = int(dut.o_soc_rst.value)
        cpu = int(dut.cpu_rst.value)
        common = tuple(int(pin.value) for pin in common_pins)
        edge = ResetEdge(
            (soc, int(dut.o_ext_mac_rst.value), int(dut.soc.soc_axi_rst.value), cpu),
            (
                int(dut.o_ext_dma_arready.value),
                int(dut.o_ext_dma_awready.value),
                int(dut.o_ext_dma_wready.value),
            ),
            (
                int(bridge.r_id_busy_q.value),
                int(bridge.w_id_busy_q.value),
                int(ingress.occupied_q.value),
            ),
        )
        dut._log.info(
            "E%d resets=%s slices/mux/bridge=%s ready=%s owners=%s",
            n,
            edge.resets,
            common,
            edge.ready,
            edge.owners,
        )
        assert common == (soc,) * len(common_pins), (
            f"E{n} common reset pins {common}, o_soc_rst={soc}"
        )
        assert int(ingress.i_rst.value) == cpu
        edges.append(edge)
        if n == 1:
            if offer:
                assert int(dut.i_ext_dma_arvalid.value) == 1 and edge.ready[0] & 1
                assert int(dut.i_ext_dma_arid.value) == 5
            await FallingEdge(dut.i_clk)
            dut.i_ddr_axi_rst.value = 0
            if offer:
                dut.i_ext_dma_arvalid.value = 0
        if n == 2:
            if offer:
                assert int(ports[0].u_slice.o_m_arvalid.value)
                assert int(ports[0].u_slice.o_m_arid.value) == 5
            if soc:
                # The external master drops its old response handshakes on the slice reset edge.
                await Timer(1, unit="ns")
                dut.i_ext_dma_rready.value = 0
                dut.i_ext_dma_bready.value = 0
        if n == 3 and edges[1].resets[0]:
            assert not int(dut.o_ext_dma_rvalid.value)
            assert not int(dut.o_ext_dma_bvalid.value)
            assert not int(ports[0].u_slice.o_m_arvalid.value)
    return edges


def _check_edges(edges: list[ResetEdge]) -> None:
    expected = ((0, 0, 1, 0), (1, 1, 0, 1), (0, 0, 0, 1), (0, 0, 0, 0))
    for n, (edge, resets) in enumerate(zip(edges, expected, strict=True), start=1):
        assert edge.resets == resets, (
            f"E{n} (o_soc_rst, MAC, transport, CPU) = {edge.resets}, expected {resets}"
        )
    assert edges[2].ready == (0, 0, 0), f"E3 DMA READY = {edges[2].ready}"
    assert edges[3].ready == (3, 3, 3), f"E4 DMA READY = {edges[3].ready}"
    assert edges[2].owners == (0, 0, 0), f"E3 outstanding DMA state = {edges[2].owners}"


def _offer_read(dma: PackedExtDmaDriver, rid: int) -> None:
    dma.set_lane("i_ext_dma_arid", 0, rid)
    dma.set_lane("i_ext_dma_araddr", 0, DDR_BASE)
    dma.set_lane("i_ext_dma_arsize", 0, 5)
    dma.set_lane("i_ext_dma_arburst", 0, 1)
    dma.set_lane("i_ext_dma_arvalid", 0, 1)
    dma.set_lane("i_ext_dma_rready", 0, 1)


async def _wait_for_ddr_owner(dut: Any, *, write: bool) -> None:
    bridge = dut.soc.gen_cached_tier.dma_bridge
    busy = bridge.w_id_busy_q if write else bridge.r_id_busy_q
    ingress = dut.cpu.cluster_memory.gen_coherent_tier.gen_dma_ingress.ingress
    master = dut.cpu.cluster_memory.memory_fabric.master
    for _ in range(400):
        if (
            int(busy.value)
            and int(ingress.occupied_q.value)
            and int(master.pending_q.value)
        ):
            return
        await FallingEdge(dut.i_clk)
    raise AssertionError("Accepted external DMA request did not reach the DDR master")


async def _fresh_read(
    dut: Any, dma: PackedExtDmaDriver, ram: AxiSlaveMemory, addr: int, rid: int
) -> None:
    data = await dma.read_burst(0, rid, addr, 1)
    assert data[0] == 0xA5, f"Fresh RID {rid} at {addr:#x} returned {data[0]:#x}"
    # A read may return its data before the coherence release reaches the ingress.
    ingress = dut.cpu.cluster_memory.gen_coherent_tier.gen_dma_ingress.ingress
    for _ in range(16):
        if not int(ingress.occupied_q.value):
            break
        await RisingEdge(dut.i_clk)
    assert not int(ingress.occupied_q.value)
    bridge = dut.soc.gen_cached_tier.dma_bridge
    assert not int(bridge.r_id_busy_q.value) and not int(bridge.w_id_busy_q.value)
    assert not ram.violations, ram.violations
    dut._log.info("Fresh DMA port 0 RID=%d addr=%#x byte=%#x", rid, addr, data[0])


@cocotb.test()
async def test_ext_dma_accepted_read_ddr_reset(dut: Any) -> None:
    """Reuse a read ID after its accepted DDR request is discarded."""
    ram = await _boot(dut, [enc_j(0, 0)], {0: 0x39})
    dma = PackedExtDmaDriver(dut)
    await FallingEdge(dut.i_clk)
    _offer_read(dma, 2)
    for _ in range(400):
        await RisingEdge(dut.i_clk)
        if int(dut.o_ext_dma_arready.value) & 1:
            break
    else:
        raise AssertionError("External port 0 did not take AR")
    await FallingEdge(dut.i_clk)
    dma.set_lane("i_ext_dma_arvalid", 0, 0)
    await _wait_for_ddr_owner(dut, write=False)
    ram.mem[0] = 0xA5
    _check_edges(await _ddr_pulse(dut))
    await _fresh_read(dut, dma, ram, DDR_BASE, 2)


@cocotb.test()
async def test_ext_dma_accepted_write_ddr_reset(dut: Any) -> None:
    """Reuse a write ID and read its data back through the other DMA port."""
    ram = await _boot(dut, [enc_j(0, 0)], {64: 0xEE})
    dma = PackedExtDmaDriver(dut)
    addr = DDR_BASE + 64
    dma.set_lane("i_ext_dma_bready", 1, 1)
    await dma.write_burst(
        1, 3, addr, [(0x55).to_bytes(32, "little")], [0xFF], cache=0, wait_b=False
    )
    await _wait_for_ddr_owner(dut, write=True)
    pulse = cocotb.start_soon(_ddr_pulse(dut))
    await ClockCycles(dut.i_clk, 3)
    fresh = cocotb.start_soon(
        dma.write_burst(
            1, 3, addr, [(0xA5).to_bytes(32, "little")], [0xFFFF_FFFF], cache=0
        )
    )
    _check_edges(await pulse)
    await fresh
    dut._log.info("Fresh DMA port 1 BID=3 addr=%#x", addr)
    await _fresh_read(dut, dma, ram, addr, 1)


@cocotb.test()
async def test_ext_dma_e1_offer_ddr_reset(dut: Any) -> None:
    """Accept AR on the transport reset edge and discard it on the slice reset."""
    ram = await _boot(dut, [enc_j(0, 0)], {0: 0x39})
    dma = PackedExtDmaDriver(dut)
    await FallingEdge(dut.i_clk)
    _offer_read(dma, 5)
    ram.mem[0] = 0xA5
    pulse = cocotb.start_soon(_ddr_pulse(dut, offer=True))
    await ClockCycles(dut.i_clk, 3)
    fresh = cocotb.start_soon(_fresh_read(dut, dma, ram, DDR_BASE, 5))
    _check_edges(await pulse)
    await fresh


def _window_program(write: bool) -> list[int]:
    # Load from the external window and report the byte through UART.
    # The write case first stores 0x5a at offset 8 and loads it back.
    base, value, uart = 5, 6, 7
    words = [enc_lui(base, 0x40024)]
    if write:
        words.extend((enc_i(0x5A, 0, 0, value), enc_s(value, base, 3, 8)))
    words.extend(
        (
            enc_i_load(8 if write else 0, base, 3, value),
            enc_lui(uart, 0x40000),
            enc_s(value, uart, 0, 0),
            enc_j(0, 0),
        )
    )
    return words


class WindowSlave:
    """Withhold the first response and service the rebooted CPU's window access."""

    def __init__(self, dut: Any, write: bool) -> None:
        """Record the slave's external handshakes on both sides of the reset."""
        self.dut = dut
        self.write = write
        self.before_pulse = True
        self.accepted = False
        self.reset_count = 0
        self.replies: list[str] = []

    async def run(self) -> None:
        """Sample o_soc_rst and the five AXI4-Lite channels at the slave flops."""
        dut = self.dut
        aw = w = read_pending = False
        wdata = word = 0
        rvalid = bvalid = False
        while True:
            await RisingEdge(dut.i_clk)
            reset = int(dut.o_soc_rst.value)
            if reset:
                assert self.accepted
                self.reset_count += 1
                aw = w = read_pending = False
                rvalid = bvalid = False
                wdata = word = 0
            else:
                if bvalid and int(dut.o_ext_axil_bready.value):
                    self.replies.append("B")
                    bvalid = False
                if rvalid and int(dut.o_ext_axil_rready.value):
                    self.replies.append("R")
                    read_pending = rvalid = False
                if int(dut.o_ext_axil_awvalid.value) and int(
                    dut.i_ext_axil_awready.value
                ):
                    assert self.write and int(dut.o_ext_axil_awaddr.value) == 8
                    aw = True
                if int(dut.o_ext_axil_wvalid.value) and int(
                    dut.i_ext_axil_wready.value
                ):
                    assert self.write and int(dut.o_ext_axil_wstrb.value) == 0xFF
                    wdata = int(dut.o_ext_axil_wdata.value)
                    assert wdata == 0x5A
                    w = True
                if aw and w:
                    aw = w = False
                    if self.before_pulse:
                        self.accepted = True
                    else:
                        word = wdata
                        bvalid = True
                if int(dut.o_ext_axil_arvalid.value) and int(
                    dut.i_ext_axil_arready.value
                ):
                    assert int(dut.o_ext_axil_araddr.value) == (8 if self.write else 0)
                    read_pending = True
                    if self.before_pulse:
                        assert not self.write
                        self.accepted = True
                    else:
                        rvalid = True

            await Timer(1, unit="ns")
            dut.i_ext_axil_awready.value = int(
                self.write and not reset and not aw and not bvalid
            )
            dut.i_ext_axil_wready.value = int(
                self.write and not reset and not w and not bvalid
            )
            dut.i_ext_axil_arready.value = int(not reset and not read_pending)
            dut.i_ext_axil_bvalid.value = int(bvalid)
            dut.i_ext_axil_rvalid.value = int(rvalid)
            if rvalid:
                dut.i_ext_axil_rdata.value = word if self.write else 0xA5


async def _window_reset(dut: Any, *, write: bool) -> None:
    ram = await _boot(dut, _window_program(write), {0: 0x11})
    slave = WindowSlave(dut, write)
    task = cocotb.start_soon(slave.run())
    try:
        for _ in range(1500):
            await FallingEdge(dut.i_clk)
            if slave.accepted and int(dut.soc.local_state_q.value) == 5:
                break
        else:
            raise AssertionError(
                "CPU access did not reach the external AXI4-Lite slave"
            )
        assert not slave.replies
        slave.before_pulse = False
        edges = await _ddr_pulse(dut)
        uart = None
        for _ in range(2500):
            await RisingEdge(dut.i_clk)
            if int(dut.o_uart_wr_en.value):
                uart = int(dut.o_uart_wr_data.value)
                break
        dut._log.info(
            "External AXI4-Lite reset count=%d replies=%s UART=%s",
            slave.reset_count,
            slave.replies,
            hex(uart) if uart is not None else None,
        )
        assert slave.reset_count == 1, (
            "In-flight external AXI4-Lite slave missed o_soc_rst"
        )
        _check_edges(edges)
        assert slave.replies == (["B", "R"] if write else ["R"])
        assert uart == (0x5A if write else 0xA5)
        assert not ram.violations, ram.violations
    finally:
        task.cancel()


@cocotb.test()
async def test_ext_axil_inflight_read_ddr_reset(dut: Any) -> None:
    """Hold an external R response and serve fresh data after reset."""
    await _window_reset(dut, write=False)


@cocotb.test()
async def test_ext_axil_inflight_write_ddr_reset(dut: Any) -> None:
    """Hold an external B response and read back the restarted write."""
    await _window_reset(dut, write=True)

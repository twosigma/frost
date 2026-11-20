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

"""Integration tests for soc_top external DMA, MAC and AXI4-Lite plug-in ports."""

import os
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.handle import Immediate
from cocotb.triggers import FallingEdge, ReadWrite, RisingEdge, Timer

DDR_BASE = 0x8000_0000
DMA_BASE = 0x4002_0000
NIC_1G_BASE = 0x4002_2000
EXT_AXIL_BASE = 0x4002_4000
NIC_BASE = 0x4003_0000
APLIC_BASE = 0x4400_0000

DMA_CTRL = 0x00
DMA_ACK = 0x04
DMA_SRC = 0x08
DMA_DST = 0x0C
DMA_LEN = 0x10
DMA_MODE = 0x14

NIC_ID = 0x000
NIC_CTRL = 0x004
NIC_STATUS = 0x008
NIC_MAC_LO = 0x00C
NIC_MAC_HI = 0x010
NIC_PAUSE_CTRL = 0x01C
NIC_RX_BASE = 0x020
NIC_RX_SIZE = 0x024
NIC_RX_TAIL = 0x028
NIC_RX_HEAD = 0x02C
NIC_TX_BASE = 0x030
NIC_TX_SIZE = 0x034
NIC_TX_TAIL = 0x038
NIC_TX_HEAD = 0x03C
NIC_IRQ_STATUS = 0x040
NIC_IRQ_MASK = 0x044
NIC_LINK = 0x060
NIC_PHY_CTRL = 0x064
NIC_CNT_RX_OVERFLOW = 0x0D0
NIC_CNT_RX_BAD_FRAME = 0x0D8
NIC_PAUSE_INTERVAL = 0x138

# External MAC ready bit assignment in nic_engine: i_ext_mac_ready = {rx_ready, tx_ready}.
MAC_READY_TX = 1 << 0
MAC_READY_RX = 1 << 1


class CoherentLineMemory:
    """Line-addressed memory model behind soc_top's coherent ingress port."""

    def __init__(self, dut: Any, base: int = DDR_BASE, size: int = 65536) -> None:
        """Initialize the backing byte array and response queue."""
        self.dut = dut
        self.base = base
        self.mem = bytearray(size)
        self.requests: list[tuple[bool, int, int, int]] = []
        self._pending: list[tuple[int, int, int, int]] = []
        self._cycle = 0

    def write_bytes(self, addr: int, data: bytes) -> None:
        """Write raw bytes into the backing store at a physical address."""
        off = addr - self.base
        self.mem[off : off + len(data)] = data

    def read_bytes(self, addr: int, length: int) -> bytes:
        """Read raw bytes from the backing store at a physical address."""
        off = addr - self.base
        return bytes(self.mem[off : off + length])

    def write_u32(self, addr: int, value: int) -> None:
        """Write a little-endian 32-bit word into the backing store."""
        self.write_bytes(addr, value.to_bytes(4, "little"))

    def read_u32(self, addr: int) -> int:
        """Read a little-endian 32-bit word from the backing store."""
        return int.from_bytes(self.read_bytes(addr, 4), "little")

    async def run(self) -> None:
        """Serve coherent ingress line requests with periodic backpressure."""
        dut = self.dut
        dut.i_coherent_req_ready.value = 1
        dut.i_coherent_resp_valid.value = 0
        dut.i_coherent_resp_id.value = 0
        dut.i_coherent_resp_rdata.value = 0
        dut.i_coherent_resp_error.value = 0
        while True:
            await RisingEdge(dut.i_clk)
            self._cycle += 1
            if int(dut.o_soc_rst.value):
                self._pending.clear()
                dut.i_coherent_resp_valid.value = 0
                dut.i_coherent_req_ready.value = 1
                continue
            if int(dut.o_coherent_req_valid.value) and int(
                dut.i_coherent_req_ready.value
            ):
                is_write = bool(int(dut.o_coherent_req_write.value))
                addr = int(dut.o_coherent_req_addr.value)
                req_id = int(dut.o_coherent_req_id.value)
                non_alloc = int(dut.o_coherent_req_non_alloc.value)
                self.requests.append((is_write, addr, req_id, non_alloc))
                off = addr - self.base
                assert 0 <= off and off + 32 <= len(self.mem), (
                    f"coherent line request out of model range: 0x{addr:x}"
                )
                if is_write:
                    wdata = int(dut.o_coherent_req_wdata.value)
                    wstrb = int(dut.o_coherent_req_wstrb.value)
                    for i in range(32):
                        if (wstrb >> i) & 1:
                            self.mem[off + i] = (wdata >> (8 * i)) & 0xFF
                    rdata = 0
                else:
                    rdata = int.from_bytes(self.mem[off : off + 32], "little")
                self._pending.append((self._cycle + 2, req_id, rdata, 0))
            await FallingEdge(dut.i_clk)
            # Backpressure one cycle in five.
            dut.i_coherent_req_ready.value = int((self._cycle % 5) != 0)
            if self._pending and self._pending[0][0] <= self._cycle:
                _, resp_id, rdata, err = self._pending.pop(0)
                dut.i_coherent_resp_valid.value = 1
                dut.i_coherent_resp_id.value = resp_id
                dut.i_coherent_resp_rdata.value = rdata
                dut.i_coherent_resp_error.value = err
            else:
                dut.i_coherent_resp_valid.value = 0


class SocCpuBus:
    """Drive CPU-side AXI4 single-beat reads and writes into soc_top."""

    def __init__(self, dut: Any) -> None:
        """Record DUT handle and AXI data bus width."""
        self.dut = dut
        self.bus_bytes = len(dut.i_axi_wstrb)

    async def init_and_reset(self) -> None:
        """Zero all DUT inputs, start clocks, and pulse synchronous reset."""
        dut = self.dut
        for signal in dut:
            if signal._name.startswith("i_"):
                signal.value = Immediate(0)
        await ReadWrite()
        Clock(dut.i_clk, 10, unit="ns").start()
        Clock(dut.i_clk_div4, 40, unit="ns").start()
        dut.i_rst.value = 1
        dut.i_ddr_axi_rst.value = 1
        dut.i_power_on_rst.value = 1
        for _ in range(6):
            await RisingEdge(dut.i_clk)
        assert int(dut.o_soc_rst.value) == 1
        if int(dut.EXT_DMA_PORTS.value) > 0:
            assert int(dut.o_ext_dma_awready.value) == 0
            assert int(dut.o_ext_dma_wready.value) == 0
            assert int(dut.o_ext_dma_arready.value) == 0
        dut.i_rst.value = 0
        dut.i_ddr_axi_rst.value = 0
        dut.i_power_on_rst.value = 0
        dut.i_axi_awburst.value = 1
        dut.i_axi_arburst.value = 1
        dut.i_axi_wlast.value = 1
        dut.i_axi_awid.value = 3
        dut.i_axi_arid.value = 5
        for _ in range(4):
            await RisingEdge(dut.i_clk)
        assert int(dut.o_soc_rst.value) == 0

    async def write(
        self,
        addr: int,
        data: int,
        size: int = 2,
        strb: int | None = None,
        expect_resp: int = 0,
    ) -> None:
        """Issue one CPU-side AXI4 write and check its BRESP code."""
        dut = self.dut
        lane = addr & (self.bus_bytes - 1)
        wdata = data << (lane * 8)
        wstrb = (((1 << (1 << size)) - 1) if strb is None else strb) << lane
        dut.i_axi_awvalid.value = 1
        dut.i_axi_awaddr.value = addr
        dut.i_axi_awsize.value = size
        dut.i_axi_wvalid.value = 1
        dut.i_axi_wdata.value = wdata
        dut.i_axi_wstrb.value = wstrb
        dut.i_axi_wlast.value = 1
        aw_done = False
        w_done = False
        for _ in range(80):
            await RisingEdge(dut.i_clk)
            if not aw_done and int(dut.o_axi_awready.value):
                aw_done = True
            if not w_done and int(dut.o_axi_wready.value):
                w_done = True
            await Timer(1, unit="ns")
            if aw_done:
                dut.i_axi_awvalid.value = 0
            if w_done:
                dut.i_axi_wvalid.value = 0
            if aw_done and w_done:
                break
        else:
            raise AssertionError(f"CPU AXI write AW/W timed out at 0x{addr:x}")
        dut.i_axi_bready.value = 1
        for _ in range(120):
            await RisingEdge(dut.i_clk)
            if int(dut.o_axi_bvalid.value):
                resp = int(dut.o_axi_bresp.value)
                assert resp == expect_resp, (
                    f"CPU write 0x{addr:x}: BRESP={resp}, expected {expect_resp}"
                )
                await Timer(1, unit="ns")
                dut.i_axi_bready.value = 0
                return
        raise AssertionError(f"CPU AXI write B timed out at 0x{addr:x}")

    async def read(self, addr: int, size: int = 2, expect_resp: int = 0) -> int:
        """Issue one CPU-side AXI4 read and return the addressed lane data."""
        dut = self.dut
        lane = addr & (self.bus_bytes - 1)
        dut.i_axi_arvalid.value = 1
        dut.i_axi_araddr.value = addr
        dut.i_axi_arsize.value = size
        for _ in range(80):
            await RisingEdge(dut.i_clk)
            if int(dut.o_axi_arready.value):
                await Timer(1, unit="ns")
                dut.i_axi_arvalid.value = 0
                break
        else:
            raise AssertionError(f"CPU AXI read AR timed out at 0x{addr:x}")
        dut.i_axi_rready.value = 1
        for _ in range(120):
            await RisingEdge(dut.i_clk)
            if int(dut.o_axi_rvalid.value):
                resp = int(dut.o_axi_rresp.value)
                assert resp == expect_resp, (
                    f"CPU read 0x{addr:x}: RRESP={resp}, expected {expect_resp}"
                )
                raw = int(dut.o_axi_rdata.value)
                await Timer(1, unit="ns")
                dut.i_axi_rready.value = 0
                return (raw >> (8 * lane)) & ((1 << (8 << size)) - 1)
        raise AssertionError(f"CPU AXI read R timed out at 0x{addr:x}")


class PackedExtDmaDriver:
    """Drive flat packed external AXI4 DMA vectors across all EXT_DMA_PORTS lanes."""

    def __init__(self, dut: Any) -> None:
        """Initialize per-port shadow state matching EXT_DMA_PORTS and EXT_DMA_ID_BITS."""
        self.dut = dut
        self.num_ports = int(dut.EXT_DMA_PORTS.value)
        self.id_bits = int(dut.EXT_DMA_ID_BITS.value)
        self.id_mask = (1 << self.id_bits) - 1
        self._in_fields: dict[str, tuple[int, list[int]]] = {
            "i_ext_dma_awvalid": (1, [0] * self.num_ports),
            "i_ext_dma_awid": (self.id_bits, [0] * self.num_ports),
            "i_ext_dma_awaddr": (64, [0] * self.num_ports),
            "i_ext_dma_awlen": (8, [0] * self.num_ports),
            "i_ext_dma_awsize": (3, [0] * self.num_ports),
            "i_ext_dma_awburst": (2, [0] * self.num_ports),
            "i_ext_dma_awlock": (1, [0] * self.num_ports),
            "i_ext_dma_awcache": (4, [0] * self.num_ports),
            "i_ext_dma_awprot": (3, [0] * self.num_ports),
            "i_ext_dma_awqos": (4, [0] * self.num_ports),
            "i_ext_dma_wvalid": (1, [0] * self.num_ports),
            "i_ext_dma_wdata": (256, [0] * self.num_ports),
            "i_ext_dma_wstrb": (32, [0] * self.num_ports),
            "i_ext_dma_wlast": (1, [0] * self.num_ports),
            "i_ext_dma_bready": (1, [0] * self.num_ports),
            "i_ext_dma_arvalid": (1, [0] * self.num_ports),
            "i_ext_dma_arid": (self.id_bits, [0] * self.num_ports),
            "i_ext_dma_araddr": (64, [0] * self.num_ports),
            "i_ext_dma_arlen": (8, [0] * self.num_ports),
            "i_ext_dma_arsize": (3, [0] * self.num_ports),
            "i_ext_dma_arburst": (2, [0] * self.num_ports),
            "i_ext_dma_arlock": (1, [0] * self.num_ports),
            "i_ext_dma_arcache": (4, [0] * self.num_ports),
            "i_ext_dma_arprot": (3, [0] * self.num_ports),
            "i_ext_dma_arqos": (4, [0] * self.num_ports),
            "i_ext_dma_rready": (1, [0] * self.num_ports),
        }

    def set_lane(self, name: str, port: int, value: int) -> None:
        """Update one port's packed slice on an external DMA input vector."""
        width, lanes = self._in_fields[name]
        mask = (1 << width) - 1
        lanes[port] = value & mask
        packed = 0
        for idx, lane_val in enumerate(lanes):
            packed |= lane_val << (idx * width)
        getattr(self.dut, name).value = packed

    def get_lane(self, name: str, port: int, width: int) -> int:
        """Read one port's packed slice from an external DMA output vector."""
        raw = int(getattr(self.dut, name).value)
        return (raw >> (port * width)) & ((1 << width) - 1)

    async def write_burst(
        self,
        port: int,
        wid: int,
        addr: int,
        beats: list[bytes],
        strobes: list[int],
        cache: int = 0b1111,
        expect_resp: int = 0,
        wait_b: bool = True,
    ) -> None:
        """Issue an INCR write burst on one packed external DMA port."""
        assert len(beats) == len(strobes) and len(beats) >= 1
        await FallingEdge(self.dut.i_clk)
        self.set_lane("i_ext_dma_awvalid", port, 1)
        self.set_lane("i_ext_dma_awid", port, wid)
        self.set_lane("i_ext_dma_awaddr", port, addr)
        self.set_lane("i_ext_dma_awlen", port, len(beats) - 1)
        self.set_lane("i_ext_dma_awsize", port, 5)
        self.set_lane("i_ext_dma_awburst", port, 1)
        self.set_lane("i_ext_dma_awcache", port, cache)
        self.set_lane("i_ext_dma_wvalid", port, 1)
        self.set_lane("i_ext_dma_wdata", port, int.from_bytes(beats[0], "little"))
        self.set_lane("i_ext_dma_wstrb", port, strobes[0])
        self.set_lane("i_ext_dma_wlast", port, int(len(beats) == 1))
        if wait_b:
            self.set_lane("i_ext_dma_bready", port, 1)

        aw_accepted = False
        beat_idx = 0
        for _ in range(200):
            await RisingEdge(self.dut.i_clk)
            if not aw_accepted and self.get_lane("o_ext_dma_awready", port, 1):
                aw_accepted = True
            if beat_idx < len(beats) and self.get_lane("o_ext_dma_wready", port, 1):
                beat_idx += 1
            await FallingEdge(self.dut.i_clk)
            if aw_accepted:
                self.set_lane("i_ext_dma_awvalid", port, 0)
            if beat_idx < len(beats):
                self.set_lane("i_ext_dma_wvalid", port, 1)
                self.set_lane(
                    "i_ext_dma_wdata", port, int.from_bytes(beats[beat_idx], "little")
                )
                self.set_lane("i_ext_dma_wstrb", port, strobes[beat_idx])
                self.set_lane("i_ext_dma_wlast", port, int(beat_idx == len(beats) - 1))
            else:
                self.set_lane("i_ext_dma_wvalid", port, 0)
                self.set_lane("i_ext_dma_wlast", port, 0)
            if aw_accepted and beat_idx == len(beats):
                break
        else:
            raise AssertionError(
                f"External DMA port {port} write AW/W timed out at 0x{addr:x}"
            )

        if not wait_b:
            return

        for _ in range(240):
            await RisingEdge(self.dut.i_clk)
            if self.get_lane("o_ext_dma_bvalid", port, 1) and self.get_lane(
                "i_ext_dma_bready", port, 1
            ):
                bid = self.get_lane("o_ext_dma_bid", port, self.id_bits)
                bresp = self.get_lane("o_ext_dma_bresp", port, 2)
                assert bid == (wid & self.id_mask), (
                    f"port {port}: BID={bid:#x}, expected {wid & self.id_mask:#x}"
                )
                assert bresp == expect_resp, (
                    f"port {port}: BRESP={bresp}, expected {expect_resp}"
                )
                await FallingEdge(self.dut.i_clk)
                self.set_lane("i_ext_dma_bready", port, 0)
                return
        raise AssertionError(
            f"External DMA port {port} write B timed out at 0x{addr:x}"
        )

    async def read_burst(
        self,
        port: int,
        rid: int,
        addr: int,
        num_beats: int,
        cache: int = 0b0000,
        expect_resp: int = 0,
        stall_after_beat: int = 0,
        stall_cycles: int = 0,
    ) -> bytes:
        """Issue an INCR read burst on one packed port and return concatenated data."""
        await FallingEdge(self.dut.i_clk)
        self.set_lane("i_ext_dma_arvalid", port, 1)
        self.set_lane("i_ext_dma_arid", port, rid)
        self.set_lane("i_ext_dma_araddr", port, addr)
        self.set_lane("i_ext_dma_arlen", port, num_beats - 1)
        self.set_lane("i_ext_dma_arsize", port, 5)
        self.set_lane("i_ext_dma_arburst", port, 1)
        self.set_lane("i_ext_dma_arcache", port, cache)
        self.set_lane("i_ext_dma_rready", port, 1)

        for _ in range(120):
            await RisingEdge(self.dut.i_clk)
            if self.get_lane("o_ext_dma_arready", port, 1):
                await FallingEdge(self.dut.i_clk)
                self.set_lane("i_ext_dma_arvalid", port, 0)
                break
        else:
            raise AssertionError(
                f"External DMA port {port} read AR timed out at 0x{addr:x}"
            )

        received = bytearray()
        stalled = False
        for _ in range(300):
            await RisingEdge(self.dut.i_clk)
            if self.get_lane("o_ext_dma_rvalid", port, 1) and self.get_lane(
                "i_ext_dma_rready", port, 1
            ):
                got_rid = self.get_lane("o_ext_dma_rid", port, self.id_bits)
                got_resp = self.get_lane("o_ext_dma_rresp", port, 2)
                got_last = self.get_lane("o_ext_dma_rlast", port, 1)
                raw = self.get_lane("o_ext_dma_rdata", port, 256)
                assert got_rid == (rid & self.id_mask), (
                    f"port {port}: RID={got_rid:#x}, expected {rid & self.id_mask:#x}"
                )
                assert got_resp == expect_resp, (
                    f"port {port}: RRESP={got_resp}, expected {expect_resp}"
                )
                received.extend(raw.to_bytes(32, "little"))
                beat_no = len(received) // 32
                assert got_last == int(beat_no == num_beats), (
                    f"port {port}: RLAST={got_last} on beat {beat_no}/{num_beats}"
                )
                if beat_no == num_beats:
                    await FallingEdge(self.dut.i_clk)
                    self.set_lane("i_ext_dma_rready", port, 0)
                    return bytes(received)
                if stall_after_beat > 0 and beat_no == stall_after_beat and not stalled:
                    stalled = True
                    await FallingEdge(self.dut.i_clk)
                    self.set_lane("i_ext_dma_rready", port, 0)
                    for _ in range(stall_cycles):
                        await RisingEdge(self.dut.i_clk)
                    await FallingEdge(self.dut.i_clk)
                    self.set_lane("i_ext_dma_rready", port, 1)
        raise AssertionError(f"External DMA port {port} read R timed out at 0x{addr:x}")


async def _start_internal_dma_copy(
    bus: SocCpuBus, src: int, dst: int, length: int
) -> None:
    """Program and launch an internal DMA test engine copy."""
    await bus.write(DMA_BASE + DMA_SRC, src)
    await bus.write(DMA_BASE + DMA_DST, dst)
    await bus.write(DMA_BASE + DMA_LEN, length)
    await bus.write(DMA_BASE + DMA_MODE, 0)
    await bus.write(DMA_BASE + DMA_CTRL, 1)


async def _wait_internal_dma_done(bus: SocCpuBus) -> None:
    """Poll the internal DMA test engine until DONE without ERROR, then acknowledge."""
    for _ in range(400):
        status = await bus.read(DMA_BASE + DMA_CTRL)
        if (status & 1) == 0:
            assert (status & 2) != 0, f"Internal DMA did not set DONE: 0x{status:x}"
            assert (status & 4) == 0, f"Internal DMA reported ERROR: 0x{status:x}"
            await bus.write(DMA_BASE + DMA_ACK, 1)
            return
    raise AssertionError("Internal DMA engine copy timed out")


@cocotb.test()
async def ext_dma_coherent_bursts(dut: Any) -> None:
    """Exercise all packed external DMA ports concurrently with internal DMA contention."""
    num_ports = int(dut.EXT_DMA_PORTS.value)
    assert num_ports > 0, "ext_dma_coherent_bursts requires EXT_DMA_PORTS > 0"
    bus = SocCpuBus(dut)
    await bus.init_and_reset()
    mem = CoherentLineMemory(dut)
    mem_task = cocotb.start_soon(mem.run())
    dma = PackedExtDmaDriver(dut)
    all_ports_mask = (1 << num_ports) - 1
    try:
        # After reset, every port's register slice opens AW, W and AR READY from flops.
        assert int(dut.o_ext_dma_awready.value) == all_ports_mask
        assert int(dut.o_ext_dma_wready.value) == all_ports_mask
        assert int(dut.o_ext_dma_arready.value) == all_ports_mask

        # Pre-fill distinct 128-byte regions per external port and a 512-byte
        # source buffer for concurrent internal DMA engine contention.
        port_bases = [DDR_BASE + 0x1000 + p * 0x200 for p in range(num_ports)]
        port_expected: list[bytes] = []
        port_beats: list[list[bytes]] = []
        port_strobes: list[list[int]] = []
        for p in range(num_ports):
            init_bytes = bytes(
                ((0xA0 + p * 0x11 + (i & 0x3F)) & 0xFF) for i in range(128)
            )
            mem.write_bytes(port_bases[p], init_bytes)
            beats = [
                bytes(((p * 53 + b * 37 + i * 3 + 1) & 0xFF) for i in range(32))
                for b in range(4)
            ]
            mid_strb = 0x0F0F_F0F0 if (p % 2) == 0 else 0xF0F0_0F0F
            strobes = [0xFFFF_FFFF, mid_strb, 0xFFFF_FFFF, 0xFFFF_FFFF]
            expected = bytearray(init_bytes)
            for b in range(4):
                for i in range(32):
                    if (strobes[b] >> i) & 1:
                        expected[b * 32 + i] = beats[b][i]
            port_beats.append(beats)
            port_strobes.append(strobes)
            port_expected.append(bytes(expected))

        int_src0 = DDR_BASE + 0x2000
        int_dst0 = DDR_BASE + 0x2400
        int_payload0 = bytes(((i * 19 + 7) & 0xFF) for i in range(512))
        mem.write_bytes(int_src0, int_payload0)
        mem.write_bytes(int_dst0, bytes(512))

        # Launch internal DMA copy and concurrent 4-beat INCR writes across every
        # external port using the same colliding AXI ID on all external ports.
        shared_wr_id = max(0, (1 << dma.id_bits) - 2)
        await _start_internal_dma_copy(bus, int_src0, int_dst0, 512)
        wr_tasks = [
            cocotb.start_soon(
                dma.write_burst(
                    port=p,
                    wid=shared_wr_id,
                    addr=port_bases[p],
                    beats=port_beats[p],
                    strobes=port_strobes[p],
                    cache=0b1111 if (p % 2) == 0 else 0b0000,
                )
            )
            for p in range(num_ports)
        ]
        for task in wr_tasks:
            await task
        await _wait_internal_dma_done(bus)

        for p in range(num_ports):
            assert mem.read_bytes(port_bases[p], 128) == port_expected[p]
        assert mem.read_bytes(int_dst0, 512) == int_payload0
        write_non_alloc = {na for is_wr, _, _, na in mem.requests if is_wr}
        assert 0 in write_non_alloc
        if num_ports >= 2:
            assert 1 in write_non_alloc

        # Launch a second concurrent 512-byte internal DMA copy alongside
        # concurrent 4-beat INCR reads on every external port (same colliding ID,
        # independent RREADY stalls, mixed streaming/allocating ARCACHE).
        mem.requests.clear()
        int_src1 = DDR_BASE + 0x2800
        int_dst1 = DDR_BASE + 0x2C00
        int_payload1 = bytes(((i * 29 + 13) & 0xFF) for i in range(512))
        mem.write_bytes(int_src1, int_payload1)
        mem.write_bytes(int_dst1, bytes(512))

        shared_rd_id = max(0, (1 << dma.id_bits) - 3)
        await _start_internal_dma_copy(bus, int_src1, int_dst1, 512)
        rd_tasks = [
            cocotb.start_soon(
                dma.read_burst(
                    port=p,
                    rid=shared_rd_id,
                    addr=port_bases[p],
                    num_beats=4,
                    cache=0b0000 if (p % 2) == 0 else 0b1111,
                    stall_after_beat=1 + (p % 2),
                    stall_cycles=2 + p,
                )
            )
            for p in range(num_ports)
        ]
        for p, rd_task in enumerate(rd_tasks):
            got_bytes = await rd_task
            assert got_bytes == port_expected[p]
        await _wait_internal_dma_done(bus)
        assert mem.read_bytes(int_dst1, 512) == int_payload1
        read_non_alloc = {na for is_wr, _, _, na in mem.requests if not is_wr}
        assert 1 in read_non_alloc
        if num_ports >= 2:
            assert 0 in read_non_alloc

        # Out-of-aperture write (port 0) and 2-beat read (top port) must return
        # DECERR (2'b11) with zero data on reads and zero coherent line requests.
        mem.requests.clear()
        err_wr_id = 0x5 & dma.id_mask
        err_rd_id = 0x6 & dma.id_mask
        err_wr = cocotb.start_soon(
            dma.write_burst(
                port=0,
                wid=err_wr_id,
                addr=0x1000_0000,
                beats=[(0xDEAD_BEEF).to_bytes(32, "little")],
                strobes=[0xFFFF_FFFF],
                expect_resp=3,
            )
        )
        err_rd = cocotb.start_soon(
            dma.read_burst(
                port=num_ports - 1,
                rid=err_rd_id,
                addr=0x1000_0040,
                num_beats=2,
                expect_resp=3,
            )
        )
        await err_wr
        err_data = await err_rd
        assert err_data == bytes(64), "DECERR read beats must carry zero data"
        assert len(mem.requests) == 0

        # Back-to-back writes with BREADY held low across every port verify
        # per-port slice B-channel buffering and in-order ID delivery.
        await FallingEdge(dut.i_clk)
        for p in range(num_ports):
            dma.set_lane("i_ext_dma_bready", p, 0)

        port_ids = [
            ((0x9 + p) & dma.id_mask, (0xE - p) & dma.id_mask) for p in range(num_ports)
        ]

        async def issue_two_stalled(port: int) -> None:
            for idx, wid in enumerate(port_ids[port]):
                addr = DDR_BASE + 0x3000 + port * 0x100 + idx * 0x20
                await dma.write_burst(
                    port=port,
                    wid=wid,
                    addr=addr,
                    beats=[(wid * 0x0101_0101).to_bytes(32, "little")],
                    strobes=[0xF],
                    wait_b=False,
                )

        stalled_tasks = [
            cocotb.start_soon(issue_two_stalled(p)) for p in range(num_ports)
        ]
        for task in stalled_tasks:
            await task
        for _ in range(30):
            await RisingEdge(dut.i_clk)

        assert int(dut.o_ext_dma_bvalid.value) == all_ports_mask
        for p in range(num_ports):
            assert dma.get_lane("o_ext_dma_bid", p, dma.id_bits) == port_ids[p][0]

        await FallingEdge(dut.i_clk)
        for p in range(num_ports):
            dma.set_lane("i_ext_dma_bready", p, 1)

        seen_bids: list[list[int]] = [[] for _ in range(num_ports)]
        for _ in range(80):
            await RisingEdge(dut.i_clk)
            for p in range(num_ports):
                if (
                    len(seen_bids[p]) < 2
                    and dma.get_lane("o_ext_dma_bvalid", p, 1)
                    and dma.get_lane("i_ext_dma_bready", p, 1)
                ):
                    assert dma.get_lane("o_ext_dma_bresp", p, 2) == 0
                    seen_bids[p].append(dma.get_lane("o_ext_dma_bid", p, dma.id_bits))
            if all(len(b) == 2 for b in seen_bids):
                break
        for p in range(num_ports):
            assert seen_bids[p] == list(port_ids[p]), (
                f"port {p}: seen_bids={seen_bids[p]}, expected {list(port_ids[p])}"
            )
    finally:
        mem_task.cancel()


@cocotb.test()
async def ext_mac_axis_and_sideband(dut: Any) -> None:
    """Loop back a frame through soc_top's exported external MAC AXI4-Stream port."""
    assert int(dut.EXTERNAL_MAC.value) != 0, (
        "ext_mac_axis_and_sideband requires EXTERNAL_MAC != 0"
    )
    bus = SocCpuBus(dut)
    await bus.init_and_reset()
    mem = CoherentLineMemory(dut)
    mem_task = cocotb.start_soon(mem.run())

    # Drive MAC sideband status and two counter totals into the exported port.
    dut.i_ext_mac_ready.value = MAC_READY_TX | MAC_READY_RX
    dut.i_ext_mac_link.value = 0xF1
    dut.i_ext_mac_raw_loopback_en.value = 1
    dut.i_ext_mac_rx_fifo_limit_busy.value = 0
    cnt0 = 0x1122_3344_5566_7788
    cnt1 = 0x99AA_BBCC_DDEE_FF01
    dut.i_ext_mac_totals.value = cnt0 | (cnt1 << 64)
    dut.i_ext_mac_tx_tready.value = 0
    dut.i_ext_mac_rx_tvalid.value = 0

    captured_beats: list[tuple[int, int, int, int]] = []

    async def axis_loopback() -> None:
        """Capture TX AXI4-Stream beats with backpressure and replay them on RX."""
        cycle = 0
        while True:
            await RisingEdge(dut.i_clk)
            cycle += 1
            if int(dut.o_ext_mac_tx_tvalid.value) and int(
                dut.i_ext_mac_tx_tready.value
            ):
                tdata = int(dut.o_ext_mac_tx_tdata.value)
                tkeep = int(dut.o_ext_mac_tx_tkeep.value)
                tlast = int(dut.o_ext_mac_tx_tlast.value)
                tuser = int(dut.o_ext_mac_tx_tuser.value)
                captured_beats.append((tdata, tkeep, tlast, tuser))
                if tlast:
                    await Timer(1, unit="ns")
                    dut.i_ext_mac_tx_tready.value = 0
                    break
            await Timer(1, unit="ns")
            dut.i_ext_mac_tx_tready.value = int((cycle % 2) == 0)

        # Replay captured frame back on i_ext_mac_rx_* respecting o_ext_mac_rx_tready.
        for tdata, tkeep, tlast, _ in captured_beats:
            await Timer(1, unit="ns")
            dut.i_ext_mac_rx_tvalid.value = 1
            dut.i_ext_mac_rx_tdata.value = tdata
            dut.i_ext_mac_rx_tkeep.value = tkeep
            dut.i_ext_mac_rx_tlast.value = tlast
            for _ in range(80):
                await RisingEdge(dut.i_clk)
                if int(dut.o_ext_mac_rx_tready.value):
                    break
            else:
                raise AssertionError("External MAC RX beat stalled")
        await Timer(1, unit="ns")
        dut.i_ext_mac_rx_tvalid.value = 0
        dut.i_ext_mac_rx_tlast.value = 0

    loop_task = cocotb.start_soon(axis_loopback())
    try:
        for _ in range(3):
            await RisingEdge(dut.i_clk)
        assert int(dut.o_nic_rx_block_lock.value) == 1
        assert await bus.read(NIC_BASE + NIC_ID) == 0x4E49_4301

        status = await bus.read(NIC_BASE + NIC_STATUS)
        assert (status & (1 << 4)) and (status & (1 << 5)), f"STATUS=0x{status:x}"
        link = await bus.read(NIC_BASE + NIC_LINK)
        assert link & (1 << 8), f"LINK=0x{link:x}"

        # Verify sideband controls flow from NIC CSRs out to o_ext_mac_*.
        await bus.write(NIC_BASE + NIC_MAC_LO, 0x3322_1100)
        await bus.write(NIC_BASE + NIC_MAC_HI, 0x0000_5544)
        await bus.write(NIC_BASE + NIC_PAUSE_CTRL, 0b11)
        await bus.write(NIC_BASE + NIC_PAUSE_INTERVAL, 0x1234)
        await bus.write(NIC_BASE + NIC_PHY_CTRL, 0x1)
        assert int(dut.o_ext_mac_station_addr.value) == 0x5544_3322_1100
        assert int(dut.o_ext_mac_pause_ctrl.value) == 0b11
        assert int(dut.o_ext_mac_pause_interval.value) == 0x1234
        assert int(dut.o_ext_mac_loopback.value) == 1

        # Verify MAC totals flow from i_ext_mac_totals into NIC counter CSRs.
        assert await bus.read(NIC_BASE + NIC_CNT_RX_OVERFLOW) == (cnt0 & 0xFFFF_FFFF)
        assert await bus.read(NIC_BASE + NIC_CNT_RX_OVERFLOW + 4) == (cnt0 >> 32)
        assert await bus.read(NIC_BASE + NIC_CNT_RX_BAD_FRAME) == (cnt1 & 0xFFFF_FFFF)
        assert await bus.read(NIC_BASE + NIC_CNT_RX_BAD_FRAME + 4) == (cnt1 >> 32)

        # Program a 4-entry RX ring and 4-entry TX ring in coherent memory and send a 72-byte frame.
        rx_ring = DDR_BASE + 0x4000
        tx_ring = DDR_BASE + 0x4100
        rx_buf = DDR_BASE + 0x5000
        tx_buf = DDR_BASE + 0x6000
        frame = bytes(
            [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB]
            + [0x08, 0x00]
            + [((i * 7 + 5) & 0xFF) for i in range(58)]
        )
        assert len(frame) == 72
        mem.write_bytes(tx_buf, frame)

        # 16-byte descriptors: addr32 / len|flags / status32 / reserved32.
        mem.write_u32(rx_ring + 0, rx_buf)
        mem.write_u32(rx_ring + 4, 256)
        mem.write_u32(rx_ring + 8, 0)
        mem.write_u32(rx_ring + 12, 0)
        mem.write_u32(tx_ring + 0, tx_buf)
        mem.write_u32(tx_ring + 4, len(frame) | (1 << 16) | (1 << 17))
        mem.write_u32(tx_ring + 8, 0)
        mem.write_u32(tx_ring + 12, 0)

        await bus.write(NIC_BASE + NIC_RX_BASE, rx_ring)
        await bus.write(NIC_BASE + NIC_RX_SIZE, 2)  # 4 entries
        await bus.write(NIC_BASE + NIC_TX_BASE, tx_ring)
        await bus.write(NIC_BASE + NIC_TX_SIZE, 2)  # 4 entries
        await bus.write(NIC_BASE + NIC_CTRL, 0x7)  # RX_EN | TX_EN | PROMISC
        await bus.write(NIC_BASE + NIC_RX_TAIL, 1)
        await bus.write(NIC_BASE + NIC_TX_TAIL, 1)

        for _ in range(400):
            if (mem.read_u32(tx_ring + 8) & (1 << 16)) != 0 and (
                mem.read_u32(rx_ring + 8) & (1 << 16)
            ) != 0:
                break
            await RisingEdge(dut.i_clk)
        else:
            raise AssertionError("NIC external MAC loopback did not complete rings")

        await loop_task
        assert await bus.read(NIC_BASE + NIC_TX_HEAD) == 1
        assert await bus.read(NIC_BASE + NIC_RX_HEAD) == 1
        assert len(captured_beats) == 9
        assert all(tuser == 0 for _, _, _, tuser in captured_beats)
        assert mem.read_bytes(rx_buf, len(frame)) == frame
        rx_desc_status = mem.read_u32(rx_ring + 8)
        assert (rx_desc_status & (1 << 16)) != 0
        assert (rx_desc_status & 0xFFFF) == len(frame)
        tx_desc_status = mem.read_u32(tx_ring + 8)
        assert tx_desc_status == (1 << 16)
    finally:
        loop_task.cancel()
        mem_task.cancel()


@cocotb.test()
async def ext_mac_independent_ready_bits(dut: Any) -> None:
    """Drive i_ext_mac_ready one-hot ({rx_ready, tx_ready}) and isolate each direction."""
    assert int(dut.EXTERNAL_MAC.value) != 0, (
        "ext_mac_independent_ready_bits requires EXTERNAL_MAC != 0"
    )
    bus = SocCpuBus(dut)
    await bus.init_and_reset()
    mem = CoherentLineMemory(dut)
    mem_task = cocotb.start_soon(mem.run())

    swap_ready = os.environ.get("FROST_EXT_MAC_SWAP_READY") == "1"
    tx_only_mask = MAC_READY_RX if swap_ready else MAC_READY_TX
    rx_only_mask = MAC_READY_TX if swap_ready else MAC_READY_RX

    dut.i_ext_mac_link.value = 0xF1
    dut.i_ext_mac_raw_loopback_en.value = 1
    dut.i_ext_mac_rx_fifo_limit_busy.value = 0
    dut.i_ext_mac_tx_tready.value = 1

    rx_ring = DDR_BASE + 0x4000
    tx_ring = DDR_BASE + 0x4100
    rx_buf = DDR_BASE + 0x5000
    tx_buf0 = DDR_BASE + 0x6000
    tx_buf1 = DDR_BASE + 0x6200

    rx_frame = bytes(((17 + i * 13) & 0xFF) for i in range(69))
    tx_frames_exp = [
        bytes(((38 + i * 7) & 0xFF) for i in range(69)),
        bytes(((74 + i * 7) & 0xFF) for i in range(69)),
    ]
    mem.write_bytes(tx_buf0, tx_frames_exp[0])
    mem.write_bytes(tx_buf1, tx_frames_exp[1])

    def write_desc(addr: int, buf: int, len_flags: int) -> None:
        mem.write_u32(addr + 0, buf)
        mem.write_u32(addr + 4, len_flags)
        mem.write_u32(addr + 8, 0)
        mem.write_u32(addr + 12, 0)

    write_desc(rx_ring, rx_buf, 256)
    write_desc(tx_ring, tx_buf0, len(tx_frames_exp[0]) | (3 << 16))
    write_desc(tx_ring + 16, tx_buf1, len(tx_frames_exp[1]) | (3 << 16))

    rx_beats_accepted: list[bytes] = []
    tx_frames_seen: list[bytes] = []
    tx_keeps_seen: list[int] = []

    async def drive_held_rx() -> None:
        """Offer a valid 69-byte RX frame continuously until every beat is accepted."""
        for off in range(0, len(rx_frame), 8):
            chunk = rx_frame[off : off + 8]
            await FallingEdge(dut.i_clk)
            dut.i_ext_mac_rx_tvalid.value = 1
            dut.i_ext_mac_rx_tdata.value = int.from_bytes(chunk, "little")
            dut.i_ext_mac_rx_tkeep.value = (1 << len(chunk)) - 1
            dut.i_ext_mac_rx_tlast.value = int(off + len(chunk) == len(rx_frame))
            for _ in range(1200):
                await RisingEdge(dut.i_clk)
                if int(dut.o_ext_mac_rx_tready.value):
                    rx_beats_accepted.append(chunk)
                    break
            else:
                raise AssertionError("Held external MAC RX beat was never accepted")
        await FallingEdge(dut.i_clk)
        dut.i_ext_mac_rx_tvalid.value = 0
        dut.i_ext_mac_rx_tlast.value = 0

    async def capture_tx() -> None:
        """Collect transmitted frames and check final partial-beat TKEEP."""
        buf = bytearray()
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_ext_mac_tx_tvalid.value) and int(
                dut.i_ext_mac_tx_tready.value
            ):
                keep = int(dut.o_ext_mac_tx_tkeep.value)
                tx_keeps_seen.append(keep)
                assert keep in (0xFF, 0x1F) and not int(dut.o_ext_mac_tx_tuser.value)
                beat_bytes = int(dut.o_ext_mac_tx_tdata.value).to_bytes(8, "little")
                buf.extend(beat_bytes[: keep.bit_count()])
                if int(dut.o_ext_mac_tx_tlast.value):
                    tx_frames_seen.append(bytes(buf))
                    buf.clear()

    # Phase 1: TX ready only (bit 0 = 1, bit 1 = 0). TX completes while RX stalls.
    dut.i_ext_mac_ready.value = tx_only_mask
    rx_task = cocotb.start_soon(drive_held_rx())
    tx_task = cocotb.start_soon(capture_tx())
    try:
        for _ in range(4):
            await RisingEdge(dut.i_clk)
        st_tx_only = await bus.read(NIC_BASE + NIC_STATUS)

        await bus.write(NIC_BASE + NIC_RX_BASE, rx_ring)
        await bus.write(NIC_BASE + NIC_RX_SIZE, 2)
        await bus.write(NIC_BASE + NIC_TX_BASE, tx_ring)
        await bus.write(NIC_BASE + NIC_TX_SIZE, 2)
        await bus.write(NIC_BASE + NIC_CTRL, 0x7)
        await bus.write(NIC_BASE + NIC_RX_TAIL, 1)
        await bus.write(NIC_BASE + NIC_TX_TAIL, 1)

        for _ in range(240):
            await RisingEdge(dut.i_clk)
        cocotb.log.info(
            "TX-only mask=%s STATUS=0x%x: TX frames=%d tx_desc0=0x%x RX beats=%d rx_desc0=0x%x",
            f"0b{tx_only_mask:02b}",
            st_tx_only,
            len(tx_frames_seen),
            mem.read_u32(tx_ring + 8),
            len(rx_beats_accepted),
            mem.read_u32(rx_ring + 8),
        )
        assert (st_tx_only & (1 << 5)) != 0 and (st_tx_only & (1 << 4)) == 0, (
            f"TX-only ready (mask={tx_only_mask:#b}) expected TX_READY=1 RX_READY=0, "
            f"got STATUS=0x{st_tx_only:x} (TX frames={len(tx_frames_seen)}, "
            f"RX beats={len(rx_beats_accepted)}, rx_desc0=0x{mem.read_u32(rx_ring + 8):x})"
        )
        assert tx_frames_seen == tx_frames_exp[:1], (
            "TX-only ready failed to send frame 0"
        )
        assert mem.read_u32(tx_ring + 8) == 0x10000
        assert len(rx_beats_accepted) == 0 and mem.read_u32(rx_ring + 8) == 0, (
            "RX progressed while RX ready bit was low"
        )

        # Phase 2: RX ready only (bit 1 = 1, bit 0 = 0). RX completes while TX stalls.
        await FallingEdge(dut.i_clk)
        dut.i_ext_mac_ready.value = rx_only_mask
        for _ in range(12):
            await RisingEdge(dut.i_clk)
        st_rx_only = await bus.read(NIC_BASE + NIC_STATUS)
        await bus.write(NIC_BASE + NIC_CTRL, 0x7)
        await bus.write(NIC_BASE + NIC_TX_TAIL, 2)

        for _ in range(240):
            await RisingEdge(dut.i_clk)
        cocotb.log.info(
            "RX-only mask=%s STATUS=0x%x: TX frames=%d tx_desc1=0x%x RX beats=%d rx_desc0=0x%x",
            f"0b{rx_only_mask:02b}",
            st_rx_only,
            len(tx_frames_seen),
            mem.read_u32(tx_ring + 24),
            len(rx_beats_accepted),
            mem.read_u32(rx_ring + 8),
        )
        assert (st_rx_only & (1 << 4)) != 0 and (st_rx_only & (1 << 5)) == 0, (
            f"RX-only ready (mask={rx_only_mask:#b}) expected RX_READY=1 TX_READY=0, "
            f"got STATUS=0x{st_rx_only:x}"
        )
        assert len(tx_frames_seen) == 1 and mem.read_u32(tx_ring + 24) == 0, (
            "TX progressed while TX ready bit was low"
        )
        assert len(rx_beats_accepted) == 9
        assert b"".join(rx_beats_accepted) == rx_frame
        assert mem.read_bytes(rx_buf, len(rx_frame)) == rx_frame
        assert (mem.read_u32(rx_ring + 8) & 0x1FFFF) == (0x10000 | len(rx_frame))

        # Phase 3: restore TX ready only and confirm queued TX frame 1 completes.
        await FallingEdge(dut.i_clk)
        dut.i_ext_mac_ready.value = tx_only_mask
        for _ in range(12):
            await RisingEdge(dut.i_clk)
        await bus.write(NIC_BASE + NIC_CTRL, 0x7)
        for _ in range(240):
            await RisingEdge(dut.i_clk)
        assert tx_frames_seen == tx_frames_exp
        assert tx_keeps_seen == ([0xFF] * 8 + [0x1F]) * 2
        assert mem.read_u32(tx_ring + 24) == 0x10000
        assert await bus.read(NIC_BASE + NIC_TX_HEAD) == 2
        assert await bus.read(NIC_BASE + NIC_RX_HEAD) == 1
    finally:
        rx_task.cancel()
        tx_task.cancel()
        mem_task.cancel()


@cocotb.test()
async def ext_aplic_source2_sharing(dut: Any) -> None:
    """Verify APLIC source 2 responds to i_external_interrupt and 1G NIC wired-OR."""
    bus = SocCpuBus(dut)
    await bus.init_and_reset()

    # Configure APLIC source 2 as active-high level (sourcecfg[2] = 6).
    await bus.write(APLIC_BASE + 8, 6)
    assert await bus.read(APLIC_BASE + 8) == 6

    async def check_src2(expected: int) -> None:
        for _ in range(12):
            await RisingEdge(dut.i_clk)
        in_clrip = await bus.read(APLIC_BASE + 0x1D00)
        level = (in_clrip >> 2) & 1
        assert level == expected, f"APLIC source 2 level={level}, expected {expected}"

    await check_src2(0)
    dut.i_external_interrupt.value = 1
    await check_src2(1)
    dut.i_external_interrupt.value = 0
    await check_src2(0)

    if int(dut.ENABLE_CACHED_TIER.value) != 0 and int(dut.ENABLE_1G_ETH.value) != 0:
        # Trigger a DESC_ERR interrupt on the secondary 1G NIC (0x4002_2000) via
        # a refused enable on an unconfigured ring, then verify wired-OR with pin.
        await bus.write(NIC_1G_BASE + NIC_IRQ_STATUS, 0x1F)
        await bus.write(NIC_1G_BASE + NIC_IRQ_MASK, 0x10)
        await bus.write(NIC_1G_BASE + NIC_CTRL, 1)
        assert (await bus.read(NIC_1G_BASE + NIC_IRQ_STATUS)) & 0x10
        await check_src2(1)

        dut.i_external_interrupt.value = 1
        await check_src2(1)

        # Clearing the 1G NIC source while holding the pin high keeps source 2 high.
        await bus.write(NIC_1G_BASE + NIC_IRQ_STATUS, 0x10)
        assert not ((await bus.read(NIC_1G_BASE + NIC_IRQ_STATUS)) & 0x10)
        await check_src2(1)

        dut.i_external_interrupt.value = 0
        await check_src2(0)


@cocotb.test()
async def ext_axil_window(dut: Any) -> None:
    """Exercise the 16 KiB external AXI4-Lite window, errors, backpressure and reset."""
    assert int(dut.EXT_AXIL_WINDOW.value) != 0, (
        "ext_axil_window requires EXT_AXIL_WINDOW != 0"
    )
    bus = SocCpuBus(dut)
    await bus.init_and_reset()

    regs: dict[int, int] = {}
    stall_mode = {"stall_resp": False, "delay": 2}
    seen_addrs: list[int] = []

    async def axil_slave() -> None:
        dut.i_ext_axil_awready.value = 0
        dut.i_ext_axil_wready.value = 0
        dut.i_ext_axil_bvalid.value = 0
        dut.i_ext_axil_bresp.value = 0
        dut.i_ext_axil_arready.value = 0
        dut.i_ext_axil_rvalid.value = 0
        dut.i_ext_axil_rdata.value = 0
        dut.i_ext_axil_rresp.value = 0
        aw_addr: int | None = None
        w_pair: tuple[int, int] | None = None
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_soc_rst.value):
                aw_addr = None
                w_pair = None
                await Timer(1, unit="ns")
                dut.i_ext_axil_awready.value = 0
                dut.i_ext_axil_wready.value = 0
                dut.i_ext_axil_bvalid.value = 0
                dut.i_ext_axil_arready.value = 0
                dut.i_ext_axil_rvalid.value = 0
                continue

            if int(dut.o_ext_axil_awvalid.value) and int(dut.i_ext_axil_awready.value):
                aw_addr = int(dut.o_ext_axil_awaddr.value)
                seen_addrs.append(aw_addr)
            if int(dut.o_ext_axil_wvalid.value) and int(dut.i_ext_axil_wready.value):
                w_pair = (
                    int(dut.o_ext_axil_wdata.value),
                    int(dut.o_ext_axil_wstrb.value),
                )
            if int(dut.i_ext_axil_bvalid.value) and int(dut.o_ext_axil_bready.value):
                await Timer(1, unit="ns")
                dut.i_ext_axil_bvalid.value = 0

            if aw_addr is not None and w_pair is not None:
                addr = aw_addr & ~0x7
                wdata, wstrb = w_pair
                aw_addr = None
                w_pair = None
                await Timer(1, unit="ns")
                dut.i_ext_axil_awready.value = 0
                dut.i_ext_axil_wready.value = 0
                if stall_mode["stall_resp"]:
                    # Hold off response until reset arrives.
                    continue
                for _ in range(stall_mode["delay"]):
                    await RisingEdge(dut.i_clk)
                    if int(dut.o_soc_rst.value):
                        break
                if int(dut.o_soc_rst.value):
                    continue
                if addr == 0x3FF8:
                    bresp = 2  # SLVERR
                else:
                    old = regs.get(addr, 0)
                    for i in range(8):
                        if (wstrb >> i) & 1:
                            old = (old & ~(0xFF << (8 * i))) | (
                                ((wdata >> (8 * i)) & 0xFF) << (8 * i)
                            )
                    regs[addr] = old
                    bresp = 0
                await Timer(1, unit="ns")
                dut.i_ext_axil_bvalid.value = 1
                dut.i_ext_axil_bresp.value = bresp
                continue

            if int(dut.o_ext_axil_arvalid.value) and int(dut.i_ext_axil_arready.value):
                raddr = int(dut.o_ext_axil_araddr.value)
                seen_addrs.append(raddr)
                await Timer(1, unit="ns")
                dut.i_ext_axil_arready.value = 0
                if stall_mode["stall_resp"]:
                    continue
                for _ in range(stall_mode["delay"]):
                    await RisingEdge(dut.i_clk)
                    if int(dut.o_soc_rst.value):
                        break
                if int(dut.o_soc_rst.value):
                    continue
                aligned = raddr & ~0x7
                await Timer(1, unit="ns")
                dut.i_ext_axil_rvalid.value = 1
                if aligned == 0x3FF8:
                    dut.i_ext_axil_rdata.value = 0
                    dut.i_ext_axil_rresp.value = 2  # SLVERR
                else:
                    dut.i_ext_axil_rdata.value = regs.get(aligned, 0)
                    dut.i_ext_axil_rresp.value = 0
                continue

            if int(dut.i_ext_axil_rvalid.value) and int(dut.o_ext_axil_rready.value):
                await Timer(1, unit="ns")
                dut.i_ext_axil_rvalid.value = 0

            # Present staggered ready when idle.
            await Timer(1, unit="ns")
            dut.i_ext_axil_awready.value = int(
                aw_addr is None and not int(dut.i_ext_axil_bvalid.value)
            )
            dut.i_ext_axil_wready.value = int(
                w_pair is None and not int(dut.i_ext_axil_bvalid.value)
            )
            dut.i_ext_axil_arready.value = int(not int(dut.i_ext_axil_rvalid.value))

    slave_task = cocotb.start_soon(axil_slave())
    try:
        # 64-bit and 32-bit writes/reads spanning all four 4 KiB pages of the 16 KiB window.
        await bus.write(EXT_AXIL_BASE + 0x0000, 0xCAFE_BABE_1234_5678, size=3)
        await bus.write(EXT_AXIL_BASE + 0x1558, 0x0123_4567_89AB_CDEF, size=3)
        await bus.write(EXT_AXIL_BASE + 0x2AB0, 0x1122_3344, size=2)
        await bus.write(EXT_AXIL_BASE + 0x2AB4, 0x5566_7788, size=2)
        await bus.write(EXT_AXIL_BASE + 0x3FF0, 0xF0E1_D2C3_B4A5_9687, size=3)

        assert await bus.read(EXT_AXIL_BASE + 0x0000, size=3) == 0xCAFE_BABE_1234_5678
        assert await bus.read(EXT_AXIL_BASE + 0x0004, size=2) == 0xCAFE_BABE
        assert await bus.read(EXT_AXIL_BASE + 0x1558, size=3) == 0x0123_4567_89AB_CDEF
        assert await bus.read(EXT_AXIL_BASE + 0x2AB0, size=3) == 0x5566_7788_1122_3344
        assert await bus.read(EXT_AXIL_BASE + 0x3FF0, size=3) == 0xF0E1_D2C3_B4A5_9687
        assert 0x0000 in seen_addrs and 0x1558 in seen_addrs and 0x3FF0 in seen_addrs

        # SLVERR propagation on both write and read at offset 0x3FF8.
        await bus.write(EXT_AXIL_BASE + 0x3FF8, 0xBAD0_0001, size=2, expect_resp=2)
        assert await bus.read(EXT_AXIL_BASE + 0x3FF8, size=2, expect_resp=2) == 0

        # Reset cancellation: stall slave response, assert i_rst (which drives o_soc_rst),
        # confirm the CPU AXI read finishes with OKAY/0, then verify recovery.
        stall_mode["stall_resp"] = True
        lane = 0
        dut.i_axi_arvalid.value = 1
        dut.i_axi_araddr.value = EXT_AXIL_BASE + 0x0000
        dut.i_axi_arsize.value = 3
        for _ in range(40):
            await RisingEdge(dut.i_clk)
            if int(dut.o_axi_arready.value):
                await Timer(1, unit="ns")
                dut.i_axi_arvalid.value = 0
                break
        for _ in range(6):
            await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        dut.i_rst.value = 1
        dut.i_axi_rready.value = 1
        saw_reset_resp = False
        for _ in range(30):
            await RisingEdge(dut.i_clk)
            if int(dut.o_axi_rvalid.value):
                assert int(dut.o_axi_rresp.value) == 0
                assert ((int(dut.o_axi_rdata.value) >> (8 * lane)) & 0xFFFF_FFFF) == 0
                saw_reset_resp = True
                break
        assert saw_reset_resp, "External AXI4-Lite read did not cancel on rst_core"
        await Timer(1, unit="ns")
        dut.i_axi_rready.value = 0
        dut.i_rst.value = 0
        stall_mode["stall_resp"] = False
        for _ in range(6):
            await RisingEdge(dut.i_clk)
        assert int(dut.o_soc_rst.value) == 0

        # Post-reset transaction works cleanly.
        await bus.write(EXT_AXIL_BASE + 0x0100, 0xA5A5_5A5A_1357_2468, size=3)
        assert await bus.read(EXT_AXIL_BASE + 0x0100, size=3) == 0xA5A5_5A5A_1357_2468
    finally:
        slave_task.cancel()

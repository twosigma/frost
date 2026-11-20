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

"""Exercise a DDR transport reset with transactions on the coherent DMA port."""

import json
import os
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from cocotb_tests.integration.test_platform_dma_reset import (
    _check_restarted_copy,
    _start_dma,
)
from encoders.instruction_encode import (
    enc_csr,
    enc_i,
    enc_i_load,
    enc_j,
    enc_lui,
    enc_r,
    enc_s,
)


LINK_STAGES = int(os.environ.get("FROST_DDR_RESET_LINK_STAGES", "0"))
WRAPPED = os.environ.get("COCOTB_TOPLEVEL") == "frost"


def _alias_program() -> list[tuple[int, int]]:
    # M-mode fetches use BRAM. MPRV=S maps data VA 0x40000000 to DDR through
    # a non-cacheable Sv39 root leaf. With MPRV clear the same VA is UART.
    va, value, mask, tmp = 5, 6, 7, 28
    words = [
        enc_i(1, 0, 0, tmp),
        enc_i(62, tmp, 1, tmp),
        enc_csr(0x30A, tmp, 2, 0),  # menvcfg.PBMTE
        enc_i(1, tmp, 1, tmp),
        enc_lui(mask, 0x80),
        enc_i(1, mask, 0, mask),  # root PPN 0x80001 in cacheable DDR
        enc_r(0, mask, tmp, 6, tmp),
        enc_csr(0x180, tmp, 1, 0),  # satp: Sv39
        0x12000073,  # sfence.vma
        enc_i(3, 0, 0, tmp),
        enc_i(11, tmp, 1, tmp),
        enc_csr(0x300, tmp, 3, 0),  # clear MPP
        enc_lui(mask, 0x20),
        enc_lui(tmp, 0x21),
        enc_i(-2048, tmp, 0, tmp),
        enc_lui(va, 0x40000),
        enc_csr(0x300, tmp, 2, 0),  # MPP=S, MPRV=1
        enc_i_load(0, va, 4, value),
        enc_s(value, va, 0, 64),
        0x0FF0000F,  # fence iorw,iorw
        enc_i_load(64, va, 4, value),
        enc_csr(0x300, mask, 3, 0),  # clear MPRV
        enc_s(value, va, 0, 0),
        enc_j(0, 0),
    ]
    return [(4 * i, word) for i, word in enumerate(words)]


class DmaPath:
    """Observe the real coherent DMA path on the platform or board wrapper."""

    def __init__(self, top: Any) -> None:
        """Locate the clock and both owners of a coherent line request."""
        self.top = top
        self.platform = top.cpu_and_memory_subsystem if WRAPPED else top
        self.soc = self.platform.soc
        self.bridge = self.soc.gen_cached_tier.dma_bridge
        self.ingress = (
            self.platform.cpu.cluster_memory.gen_coherent_tier.gen_dma_ingress.ingress
        )
        self.link = self.platform.cpu.link_dma_req
        self.clock = Clock(top.i_clk, 10, unit="ns")

    def presentation(self) -> dict[str, tuple[int, int, int, int]]:
        """Sample VALID, READY, address/data, and size or strobe at each receiver."""
        tier, soc = self.soc.gen_cached_tier, self.soc
        port = len(tier.up_awready) - 1
        result = {}
        for ch in ("ar", "aw", "w"):
            payload = getattr(tier, "up_" + ch + ("data" if ch == "w" else "addr"))
            attr = getattr(tier, "up_" + ch + ("strb" if ch == "w" else "size"))
            result["alias_" + ch] = (
                int(getattr(tier, "up_" + ch + "valid").value) >> port,
                int(getattr(tier, "up_" + ch + "ready").value) >> port,
                int(payload.value) >> (port * len(payload) // (port + 1)),
                int(attr.value) >> (port * len(attr) // (port + 1)),
            )
            # Register port 1 is the DMA engine.
            result["reg_" + ch] = (
                (int(getattr(soc, "reg_axil_" + ch + "valid").value) >> 1) & 1,
                (int(getattr(soc, "reg_axil_" + ch + "ready").value) >> 1) & 1,
                int((soc.reg_axil_wdata_q if ch == "w" else soc.reg_axil_addr_q).value),
                int((soc.reg_axil_wstrb_q if ch == "w" else soc.reg_axil_prot_q).value),
            )
        return result

    def state(self) -> dict[str, int]:
        """Sample reset pins, transfers, and live ownership at both ends."""
        b, i = self.bridge, self.ingress
        tier = self.soc.gen_cached_tier
        s = {
            "fabric": int(self.soc.soc_axi_rst.value),
            "bridge": int(b.i_rst.value),
            "cpu": int(i.i_rst.value),
            "mux": int(tier.dma_interconnect.i_rst.value),
            "engine": int(tier.dma_engine.i_rst.value),
            "engine_busy": int(tier.dma_engine.engine.busy_q.value),
            "engine_done": int(tier.dma_engine.engine.done_q.value),
            "mux_w": int(tier.dma_interconnect.wq_count_q.value),
            "offer": int(b.o_line_req_valid.value),
            "ready": int(b.i_line_req_ready.value),
            "offer_id": int(b.o_line_req_id.value),
            "ingress_accept": int(i.accept_request.value),
            "due": int(i.pick_valid.value),
            "due_id": int(i.pick_id.value),
            "response": int(b.i_line_resp_valid.value),
            "response_id": int(b.i_line_resp_id.value),
            "ingress_response": int(i.o_resp_valid.value),
            "r": int(b.o_axi_rvalid.value) & int(b.i_axi_rready.value),
            "b": int(b.o_axi_bvalid.value) & int(b.i_axi_bready.value),
            "r_busy": int(b.r_id_busy_q.value),
            "w_busy": int(b.w_id_busy_q.value),
            "w_debt": int(b.wbt_out_q[0].value),
            "rbuf": int(b.rbuf_valid_q.value),
            "segments": int(b.seg_count_q.value),
            "occupied": int(i.occupied_q.value),
            "count": int(i.count_q.value),
            "link_valid": int(self.link.o_valid.value),
        }
        if LINK_STAGES:
            s["credit"] = int(self.link.gen_credit.credits_q.value)
        return s

    async def arm(self, case: str) -> int:
        """Wait until the selected request or response will fire on the next edge."""
        ident = 0 if "write" in case else 8
        accepted = []
        for _ in range(8000):
            await FallingEdge(self.top.i_clk)
            await Timer(1, unit="ps")
            s = self.state()
            offered = s["offer"] and s["ready"]
            if case == "offer" and offered:
                assert s["offer_id"] == ident and not s["occupied"]
                return ident
            if (
                case.startswith("owned_")
                and ident in accepted
                and s["occupied"] & (1 << ident)
            ):
                assert not s["due"] and not s["response"]
                return ident
            if s["due"] and s["due_id"] == ident and case != "offer":
                assert ident in accepted and s["occupied"] & (1 << ident)
                assert s["w_debt"] == 1 if ident == 0 else s["r_busy"] & 1
                if ident == 8:
                    assert int(self.ingress.pick_data.value) & 0xFF == 0x39
                return ident
            if offered:
                accepted.append(s["offer_id"])
        raise AssertionError(f"Did not reach {case} with a live DMA owner")

    async def pulse(
        self, case: str, width: int, *, stop: bool, dual: bool = False
    ) -> None:
        """Apply the pulse and check the edges through credit recovery."""
        clk = self.top.i_clk
        pin = self.top.i_ddr_axi_rst_n if WRAPPED else self.top.i_ddr_axi_rst
        label = f"{case}.link{LINK_STAGES}.width{width}.stop{int(stop)}.dual{int(dual)}"
        before = self.state()
        if stop:
            self.clock.stop()
        pin.value = int(not WRAPPED)
        if dual:
            self.top.i_rst_n.value = 0
        await Timer(1, unit="ps")
        if stop:
            await Timer(30, unit="ns")
            during = self.state()
            assert during["fabric"] and not during["bridge"] and not during["cpu"]
            for field in ("r_busy", "w_busy", "w_debt", "occupied", "count"):
                assert during[field] == before[field], field
            pin.value = 1
            if dual:
                self.top.i_rst_n.value = 1
            await Timer(5, unit="ns")
            assert int(self.top.ddr_axi_reset.value) and not int(
                self.top.reset_synchronized.value
            )
            self.clock.start(start_high=False)
        fabric_edges = 4 if stop else width + (4 if WRAPPED else 0)
        edges = []
        for n in range(1, fabric_edges + 5):
            if not stop and n == width + 1:
                await FallingEdge(clk)
                await Timer(1, unit="ps")
                pin.value = int(WRAPPED)
                if dual:
                    self.top.i_rst_n.value = 1
            await RisingEdge(clk)
            pre = self.state()
            check_offer = n == 1 and (case.startswith("alias") or case == "reg_ar")
            offers = self.presentation() if check_offer else {}
            await Timer(1, unit="ps")
            post = self.state()
            self.top._log.info("DDR_EDGE %s E%d %s", label, n, json.dumps([pre, post]))
            if check_offer:
                after = self.presentation()
                self.top._log.info(
                    "DDR_PRESENT %s %s", label, json.dumps([offers, after])
                )
                for channel, (valid, ready, data, attr) in offers.items():
                    if valid and not ready and not pre["bridge"]:
                        assert after[channel][0] and after[channel][2:] == (
                            data,
                            attr,
                        ), channel
            edges.append((pre, post))

        first = edges[0][0]
        assert first["fabric"] and not first["cpu"] and not first["bridge"]
        if case == "offer":
            assert first["offer"] and first["ready"] and first["offer_id"] == 8
            assert bool(first["ingress_accept"]) == (LINK_STAGES == 0)
            if LINK_STAGES:
                assert (
                    edges[0][1]["link_valid"]
                    and edges[0][1]["credit"] == first["credit"] - 1
                )
            else:
                assert edges[0][1]["occupied"] & (1 << 8)
        elif case in ("read_due", "write_due"):
            assert first["due"] and first["due_id"] == (0 if case == "write_due" else 8)
            assert edges[1][0]["ingress_response"]
            assert bool(edges[1][0]["response"]) == (LINK_STAGES == 0)
        assert sum(pre["fabric"] for pre, _ in edges) == fabric_edges
        assert edges[1][0]["cpu"] and edges[1][0]["bridge"]
        if not dual or stop:
            assert sum(pre["bridge"] for pre, _ in edges) == fabric_edges
            assert sum(pre["cpu"] for pre, _ in edges) == fabric_edges + 1
        for n, (pre, post) in enumerate(edges, 1):
            assert pre["bridge"] == pre["mux"] == pre["engine"]
            if n >= 2:
                assert not any(
                    post[k]
                    for k in (
                        "r_busy",
                        "w_busy",
                        "rbuf",
                        "w_debt",
                        "segments",
                        "count",
                        "occupied",
                        "engine_busy",
                        "engine_done",
                        "mux_w",
                        "r",
                        "b",
                    )
                ), (n, post)
                assert not post["response"] and not post["link_valid"]
            if pre["cpu"] and not pre["bridge"]:
                assert not (pre["offer"] and pre["ready"])
        if LINK_STAGES:
            assert edges[-1][1]["credit"] == 2 * LINK_STAGES + 1
        self.top._log.info(
            "DDR_CANCEL %s old transaction discarded at shared E2", label
        )


@cocotb.test(skip=WRAPPED)
@cocotb.parametrize(case=["read_due", "write_due", "offer"], width=[1, 2, 3, 8])
async def first_transport_edge(dut: Any, case: str, width: int) -> None:
    """Track the old coherent transaction and reuse the ID for a fresh copy."""
    p = DmaPath(dut)
    ram = await _start_dma(dut, dut.i_clk, clock=p.clock, reset_ddr=True)
    await p.arm(case)
    ram.mem[0] = 0xA5
    await p.pulse(case, width, stop=False)
    await _check_restarted_copy(p.platform, dut.i_clk, p.bridge, p.ingress, ram)


@cocotb.test()
@cocotb.parametrize(case=["owned_read", "owned_write"])
async def discard_owned(dut: Any, case: str) -> None:
    """Interrupt a request after acceptance, before its response is due."""
    p = DmaPath(dut)
    ram = await _start_dma(dut, dut.i_clk, clock=p.clock, reset_ddr=True)
    await p.arm(case)
    ram.mem[0] = 0xA5
    await p.pulse(case, 2, stop=WRAPPED)
    await _check_restarted_copy(p.platform, dut.i_clk, p.bridge, p.ingress, ram)


@cocotb.test(skip=not WRAPPED)
@cocotb.parametrize(case=["read_due", "write_due"], dual=[False, True])
async def stopped_dma(dut: Any, case: str, dual: bool) -> None:
    """Recover an active copy after a pulse entirely within a clock stop."""
    p = DmaPath(dut)
    ram = await _start_dma(dut, dut.i_clk, clock=p.clock, reset_ddr=True)
    await p.arm(case)
    ram.mem[0] = 0xA5
    await p.pulse(case, 1, stop=True, dual=dual)
    await _check_restarted_copy(p.platform, dut.i_clk, p.bridge, p.ingress, ram)


@cocotb.test()
@cocotb.parametrize(channel=["ar", "aw", "w_after_aw", "wait_r", "wait_b"])
async def alias_reset(dut: Any, channel: str) -> None:
    """Cancel a presented alias transfer and repeat the NC load/store after reboot."""
    p = DmaPath(dut)
    ram = await _start_dma(
        dut, dut.i_clk, clock=p.clock, image=_alias_program(), reset_ddr=True
    )
    leaf = (1 << 61) | ((0x80000000 >> 12) << 10) | 0xC7
    ram.mem.update(
        {0x1008 + n: byte for n, byte in enumerate(leaf.to_bytes(8, "little"))}
    )
    for _ in range(6000):
        await FallingEdge(dut.i_clk)
        await Timer(1, unit="ps")
        offer = p.presentation()
        if channel in ("ar", "aw") and offer["alias_" + channel][0]:
            break
        if channel == "w_after_aw" and offer["alias_w"][0] and not offer["alias_aw"][0]:
            break
        if channel in ("wait_r", "wait_b") and int(
            p.soc.gen_cached_tier.alias_wait.value
        ):
            write_pending = bool(int(p.soc.local_write.value))
            if write_pending == (channel == "wait_b") and not any(
                offer["alias_" + ch][0] for ch in ("ar", "aw", "w")
            ):
                break
    else:
        raise AssertionError(f"Svpbmt {channel} did not reach the mux")
    ram.mem[0] = 0xA5
    await p.pulse("alias_" + channel, 1, stop=WRAPPED)
    requests, replies = [], []
    for _ in range(8000):
        await RisingEdge(dut.i_clk)
        i = p.ingress
        if int(i.accept_request.value):
            write = int(i.i_req_write.value)
            requests.append((write, int(i.i_req_addr.value), int(i.i_req_id.value)))
            if write:
                assert int(i.i_req_mask.value) == 1
                assert int(i.i_req_data.value) & 255 == 0xA5
        if int(i.o_resp_valid.value):
            replies.append(int(i.o_resp_id.value))
            assert not int(i.o_resp_error.value)
            if replies[-1] >= 8:
                assert int(i.o_resp_data.value) & 255 == 0xA5
        if int(p.platform.o_uart_wr_en.value):
            assert int(p.platform.o_uart_wr_data.value) == 0xA5
            break
    else:
        raise AssertionError("Alias firmware did not report the fresh byte")
    assert requests == [(0, 0x80000000, 8), (1, 0x80000040, 0), (0, 0x80000040, 9)]
    assert replies == [8, 0, 9] and not ram.violations
    assert not any(p.state()[k] for k in ("r_busy", "w_busy", "w_debt", "occupied"))
    dut._log.info(
        "DDR_ALIAS_RECOVERED %s requests=%s replies=%s byte=0xa5",
        channel,
        requests,
        replies,
    )


@cocotb.test()
async def register_offer_reset(dut: Any) -> None:
    """Reset during the engine's stalled AXI-Lite status read."""
    p = DmaPath(dut)
    ram = await _start_dma(dut, dut.i_clk, clock=p.clock, reset_ddr=True)
    for _ in range(6000):
        await FallingEdge(dut.i_clk)
        await Timer(1, unit="ps")
        if p.presentation()["reg_ar"][:2] == (1, 0):
            break
    else:
        raise AssertionError("DMA status AR did not stall at the register bridge")
    ram.mem[0] = 0xA5
    await p.pulse("reg_ar", 1, stop=WRAPPED)
    await _check_restarted_copy(p.platform, dut.i_clk, p.bridge, p.ingress, ram)


@cocotb.test(skip=not WRAPPED)
async def running_board_reset(dut: Any) -> None:
    """Sample both board reset inputs with the common clock running."""
    p = DmaPath(dut)
    ram = await _start_dma(dut, dut.i_clk, clock=p.clock, reset_ddr=True)
    await p.arm("read_due")
    ram.mem[0] = 0xA5
    await p.pulse("read_due", 8, stop=False, dual=True)
    await _check_restarted_copy(p.platform, dut.i_clk, p.bridge, p.ingress, ram)

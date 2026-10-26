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

"""Reset draining at the optional CPU clock boundary."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.handle import Immediate
from cocotb.triggers import FallingEdge, RisingEdge, Timer, with_timeout

from cocotb_tests.test_real_program import generate_divided_clock


async def _write(
    dut: Any,
    address: int,
    debug: bool,
    *,
    data: int = 0x12345678,
    transaction_id: int = 32,
    size: int = 2,
) -> None:
    await FallingEdge(dut.i_cpu_clk)
    dut.i_debug_mode.value = int(debug)
    dut.i_axi_awaddr.value = address
    dut.i_axi_awid.value = transaction_id
    dut.i_axi_awsize.value = size
    dut.i_axi_awburst.value = 1
    dut.i_axi_awprot.value = 3
    dut.i_axi_awvalid.value = 1
    dut.i_axi_wdata.value = data
    dut.i_axi_wstrb.value = (1 << (1 << size)) - 1
    dut.i_axi_wlast.value = 1
    dut.i_axi_wvalid.value = 1
    aw = w = False
    while not (aw and w):
        await RisingEdge(dut.i_cpu_clk)
        aw = aw or bool(dut.o_axi_awready.value)
        w = w or bool(dut.o_axi_wready.value)
        await FallingEdge(dut.i_cpu_clk)
        dut.i_axi_awvalid.value = int(not aw)
        dut.i_axi_wvalid.value = int(not w)


async def _response(dut: Any, expected: int) -> None:
    async def wait() -> None:
        while True:
            await RisingEdge(dut.i_cpu_clk)
            if int(dut.o_axi_bvalid.value):
                assert int(dut.o_axi_bresp.value) == expected
                assert int(dut.o_axi_bid.value) == 32
                return

    await with_timeout(wait(), 5, "us")


async def _soc_draining(dut: Any) -> None:
    dut.i_rst.value = 1
    dut.i_ddr_axi_rst.value = 1
    Clock(dut.i_clk, 3, unit="ns").start()
    cocotb.start_soon(generate_divided_clock(dut, core_clock=dut.i_cpu_clk))
    await Timer(0.7, unit="ns")
    Clock(dut.i_cpu_clk, 10, unit="ns").start()
    await Timer(250, unit="ns")
    dut.i_rst.value = 0
    dut.i_ddr_axi_rst.value = 0
    dut.i_axi_bready.value = 1
    await Timer(250, unit="ns")

    # The programming port blocks mirror completion after the data write.
    dut.i_instr_mem_en.value = 1
    await _write(dut, 0x100, True)

    async def pending_mirror() -> None:
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.local_state_q.value) == 1:
                assert not int(dut.slice_all_done.value)
                return

    await with_timeout(pending_mirror(), 5, "us")
    dut.i_rst.value = 1
    await _response(dut, 2)
    dut.i_instr_mem_en.value = 0
    dut.i_debug_mode.value = 0
    dut.i_rst.value = 0
    await Timer(250, unit="ns")

    # A presented MSI write belongs to the reset epoch and must drain.
    await _write(dut, 0x48000000, False, data=5)
    dut.i_rst.value = 1
    await _response(dut, 0)
    assert not int(dut.o_cpu_msi_valid.value)
    dut.i_rst.value = 0
    for _ in range(100):
        await RisingEdge(dut.i_cpu_clk)
        assert not int(dut.o_cpu_msi_valid.value)

    # Presented writes can execute after reset release when DDR was stalled.
    seen_msi: list[int] = []

    async def watch_msi() -> None:
        while True:
            await RisingEdge(dut.i_cpu_clk)
            if int(dut.o_cpu_msi_valid.value):
                seen_msi.append(int(dut.o_cpu_msi_id.value))

    async def responses() -> None:
        expected = {0: 0, 32: 0}
        while expected:
            await RisingEdge(dut.i_cpu_clk)
            if int(dut.o_axi_bvalid.value):
                ident = int(dut.o_axi_bid.value)
                assert ident in expected
                assert int(dut.o_axi_bresp.value) == expected.pop(ident)

    monitor = cocotb.start_soon(watch_msi())
    await _write(dut, 0x80000000, False, transaction_id=0, size=6)
    await _write(dut, 0x48000000, False, data=5)
    await Timer(150, unit="ns")
    assert int(dut.o_ddr_axi_awvalid.value)
    assert not seen_msi
    dut.i_rst.value = 1
    await Timer(150, unit="ns")
    dut.i_rst.value = 0
    await Timer(250, unit="ns")
    assert not int(dut.o_cpu_rst.value)
    assert not seen_msi
    completion = cocotb.start_soon(responses())
    await FallingEdge(dut.i_clk)
    dut.i_ddr_axi_awready.value = 1
    dut.i_ddr_axi_wready.value = 1
    await RisingEdge(dut.i_clk)
    assert int(dut.o_ddr_axi_awvalid.value)
    assert int(dut.o_ddr_axi_wvalid.value)
    await FallingEdge(dut.i_clk)
    dut.i_ddr_axi_awready.value = 0
    dut.i_ddr_axi_wready.value = 0
    dut.i_ddr_axi_bid.value = 0
    dut.i_ddr_axi_bvalid.value = 1
    while True:
        await RisingEdge(dut.i_clk)
        if int(dut.o_ddr_axi_bready.value):
            break
    await FallingEdge(dut.i_clk)
    dut.i_ddr_axi_bvalid.value = 0
    await with_timeout(completion, 5, "us")
    await Timer(250, unit="ns")
    monitor.cancel()
    assert seen_msi == [5]


async def _stopped_soc(dut: Any) -> None:
    dut.i_rst_n.value = 0
    dut.i_ddr_axi_rst_n.value = 1
    soc_clock = Clock(dut.i_clk, 3, unit="ns").start()
    cocotb.start_soon(generate_divided_clock(dut, core_clock=dut.i_cpu_clk))
    await Timer(0.7, unit="ns")
    cpu_clock = Clock(dut.i_cpu_clk, 7, unit="ns").start()
    await Timer(250, unit="ns")
    dut.i_rst_n.value = 1
    await Timer(250, unit="ns")
    platform = dut.cpu_and_memory_subsystem
    assert not int(platform.cpu.i_rst.value)
    soc_clock.cancel()
    dut.i_clk.value = 0
    await Timer(1, unit="ns")
    dut.i_rst_n.value = 0
    await Timer(1, unit="ns")
    assert int(platform.cpu.i_rst.value)
    assert int(platform.soc.debug_cpu_rst.value)
    soc = platform.soc
    dut.i_power_on_rst.value = 1
    await Timer(35, unit="ns")
    assert int(soc.power_on_rst_core.value)
    assert int(soc.power_on_rst_tck.value)
    assert int(soc.gen_jtag_tap.u_jtag_tap.o_tlr.value)
    _check_debug_ownership(soc)
    dut.i_power_on_rst.value = 0
    await Timer(35, unit="ns")
    assert not int(soc.power_on_rst_core.value)
    assert int(soc.power_on_rst_tck.value)
    dut.i_jtag_trst_n.value = 1
    tck = Clock(dut.i_jtag_tck, 14, unit="ns").start()
    await Timer(70, unit="ns")
    assert not int(soc.power_on_rst_tck.value)
    _check_debug_ownership(soc)
    tck.cancel()
    dut.i_jtag_tck.value = 0
    dut.i_rst_n.value = 1
    await Timer(250, unit="ns")
    assert int(platform.cpu.i_rst.value)
    Clock(dut.i_clk, 3, unit="ns").start()
    await Timer(250, unit="ns")
    assert not int(platform.cpu.i_rst.value)

    # The paired system reset also waits for a stopped CPU clock.
    cpu_clock.cancel()
    dut.i_cpu_clk.value = 0
    await Timer(1, unit="ns")
    dut.i_rst_n.value = 0
    await Timer(1, unit="ns")
    assert int(platform.cpu.i_rst.value)
    assert int(soc.soc_cpu_rst.value)
    dut.i_rst_n.value = 1
    await Timer(100, unit="ns")
    assert int(platform.cpu.i_rst.value)
    assert int(soc.soc_cpu_rst.value)
    Clock(dut.i_cpu_clk, 7, unit="ns").start()
    await Timer(250, unit="ns")
    assert not int(platform.cpu.i_rst.value)
    assert not int(soc.soc_cpu_rst.value)
    _check_debug_ownership(soc)


def _check_debug_ownership(soc: Any) -> None:
    """Cold reset leaves no request or response owned by the transport."""
    for name in ("req_toggle_q", "ack_toggle_q", "req_seen_q", "ack_seen_q"):
        assert int(getattr(soc.u_dtm, name).value) == 0, name
    assert not int(soc.u_dtm.o_dmi_req_valid.value)
    assert not int(soc.u_debug_module.dmi_req_pending_q.value)


@cocotb.test()
async def reset_boundary(dut: Any) -> None:
    """Reset drains old writes and reaches the CPU with a stopped SoC clock."""
    for signal in dut:
        if signal._name.startswith("i_"):
            signal.value = Immediate(0)
    await Timer(1, unit="ps")
    if hasattr(dut, "i_rst_n"):
        await _stopped_soc(dut)
    else:
        await _soc_draining(dut)


@cocotb.test()
async def power_on_waits_for_cpu(dut: Any) -> None:
    """Cold reset spans a delayed CPU clock while programming clocks continue."""
    for signal in dut:
        if signal._name.startswith("i_"):
            signal.value = Immediate(0)
    await Timer(1, unit="ps")
    is_frost = hasattr(dut, "i_rst_n")
    if is_frost:
        dut.i_rst_n.value = 0
        dut.i_ddr_axi_rst_n.value = 0
        soc = dut.cpu_and_memory_subsystem.soc
    else:
        dut.i_rst.value = 1
        dut.i_ddr_axi_rst.value = 1
        soc = dut
    Clock(dut.i_clk, 3, unit="ns").start()
    cocotb.start_soon(generate_divided_clock(dut, core_clock=dut.i_cpu_clk))
    await Timer(90, unit="ns")
    assert int(dut.i_power_on_rst.value)
    assert int(soc.power_on_rst_tck.value)
    assert int(soc.rst_div4.value)
    Clock(dut.i_cpu_clk, 101, unit="ns").start()
    await Timer(610, unit="ns")
    assert not int(dut.i_power_on_rst.value)
    assert not int(soc.power_on_rst_core.value)
    assert int(soc.power_on_rst_tck.value)
    _check_debug_ownership(soc)
    if is_frost:
        dut.i_rst_n.value = 1
        dut.i_ddr_axi_rst_n.value = 1
    else:
        dut.i_rst.value = 0
        dut.i_ddr_axi_rst.value = 0
    await Timer(610, unit="ns")
    assert not int(soc.o_cpu_rst.value)
    assert not int(soc.soc_cpu_rst.value)
    _check_debug_ownership(soc)

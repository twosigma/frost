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

"""Check the reset edge between the SoC's DMA bridge and the CPU's ingress."""

import os
import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.handle import Immediate
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from cocotb_tests.axi.axi_models import AxiSlaveMemory
from cocotb_tests.bram_programmer import program_bram_image
from encoders.instruction_encode import enc_b, enc_i, enc_i_load, enc_j, enc_lui, enc_s


CPU_PERIOD_PS = int(os.environ.get("FROST_CPU_PERIOD_PS", "0"))


def _dma_copy_program() -> list[int]:
    # Program one coherent DMA beat through the hart's MMIO port. Wait for
    # DONE before the hart loads the destination and sends its byte to UART.
    dma, src, dst, tmp = 5, 6, 7, 28
    return [
        enc_lui(dma, 0x40020),
        enc_i(1, 0, 0, src),
        enc_i(31, src, 1, src),  # slli: DDR starts at 0x8000_0000
        enc_s(src, dma, 2, 8),
        enc_i(64, src, 0, dst),
        enc_s(dst, dma, 2, 12),
        enc_i(8, 0, 0, tmp),
        enc_s(tmp, dma, 2, 16),  # LEN = 8, MODE resets to COPY
        enc_i(1, 0, 0, tmp),
        enc_s(tmp, dma, 2, 0),  # START
        enc_i_load(0, dma, 2, tmp),
        enc_i(2, tmp, 7, tmp),  # andi: DONE
        enc_b(0, tmp, 0, -8),
        enc_i_load(0, dst, 3, tmp),
        enc_lui(dst, 0x40000),
        enc_s(tmp, dst, 0, 0),
        enc_j(0, 0),
    ]


async def _start_dma(dut: Any, core_clk: Any) -> AxiSlaveMemory:
    for pin in (
        "i_clk",
        "i_cpu_clk",
        "i_clk_div4",
        "i_jtag_tck",
        "i_jtag_trst_n",
        "i_dtm_bscan_tck",
        "i_instr_mem_en",
        "i_instr_mem_we",
        "i_rst",
        "i_ddr_axi_rst",
        "i_power_on_rst",
        "i_nic_tx_clk",
        "i_nic_rx_clk",
        "i_nic_tx_clk_ok",
        "i_nic_rx_clk_ok",
        "i_uart_rx_valid",
    ):
        getattr(dut, pin).value = Immediate(0)
    await Timer(1, unit="ps")
    dut.i_uart_tx_ready.value = 1
    dut.i_rst.value = 1
    dut.i_ddr_axi_rst.value = 1
    dut.i_power_on_rst.value = 1
    await Timer(1, unit="ps")
    Clock(dut.i_clk, 10, unit="ns").start()
    Clock(dut.i_clk_div4, 40, unit="ns").start()
    if CPU_PERIOD_PS:
        await Timer(500, unit="ps")
        Clock(core_clk, CPU_PERIOD_PS, unit="ps").start()

    memory = {0: 0x39}
    ram = AxiSlaveMemory(
        dut,
        dut.i_clk,
        "i_ddr_axi_",
        "o_ddr_axi_",
        len(dut.o_ddr_axi_wstrb),
        memory,
        random.Random(21),
    )
    for _ in range(4):
        await RisingEdge(dut.i_clk_div4)
    dut.i_power_on_rst.value = 0
    for _ in range(4):
        await RisingEdge(dut.i_clk_div4)
    assert not int(dut.soc.power_on_rst_div4.value)
    await program_bram_image(
        dut, [(pc * 4, word) for pc, word in enumerate(_dma_copy_program())]
    )
    await FallingEdge(dut.i_clk)
    dut.i_ddr_axi_rst.value = 0
    dut.i_rst.value = 0

    return ram


async def _wait_for_completion(
    core_clk: Any, bridge: Any, ingress: Any, write: bool
) -> None:
    # A read becomes due after G. A write becomes due when the home
    # presents U from its registered release arbiter after C.
    # Assert the request *before* this edge so the following edge samples
    # bridge reset just as the ingress would register its response.
    for _ in range(8000):
        await FallingEdge(core_clk)
        if write:
            trigger = (
                int(bridge.w_id_busy_q.value) & 1
                and int(ingress.o_c_valid.value)
                and int(ingress.i_c_ready.value)
            )
        else:
            trigger = (
                int(bridge.r_id_busy_q.value) & 1
                and int(ingress.i_g_valid.value)
                and int(ingress.o_g_ready.value)
            )
        if trigger:
            break
    else:
        raise AssertionError("DMA did not reach its completion handshake")
    if write:
        # The home accepts C on this edge, then selects its release on the
        # next. The ingress will see U after that selection.
        await FallingEdge(core_clk)


async def _check_restarted_copy(
    dut: Any, core_clk: Any, bridge: Any, ingress: Any, ram: AxiSlaveMemory
) -> None:
    requests, replies = [], []
    for _ in range(8000):
        await RisingEdge(core_clk)
        if int(ingress.i_req_valid.value) and int(ingress.o_req_ready.value):
            requests.append(int(ingress.i_req_id.value))
            if int(ingress.i_req_write.value):
                assert int(ingress.i_req_addr.value) == 0x80000040
                assert int(ingress.i_req_mask.value) == 0xFF
                assert int(ingress.i_req_data.value) & 0xFFFFFFFFFFFFFFFF == 0xA5
            else:
                assert int(ingress.i_req_addr.value) == 0x80000000
        if int(ingress.o_resp_valid.value):
            replies.append(int(ingress.o_resp_id.value))
            assert not int(ingress.o_resp_error.value)
            if replies[-1] == 8:
                assert int(ingress.o_resp_data.value) & 0xFF == 0xA5
        if int(dut.o_uart_wr_en.value):
            assert int(dut.o_uart_wr_data.value) == 0xA5
            break
    else:
        raise AssertionError("Restarted firmware did not report its fresh data")
    assert requests == replies == [8, 0]
    assert not int(bridge.r_id_busy_q.value) and not int(bridge.w_id_busy_q.value)
    assert not int(bridge.rbuf_valid_q.value) and not int(bridge.wbt_out_q[0].value)
    assert not int(ingress.occupied_q.value) and not int(ingress.count_q.value)
    assert not ram.violations, ram.violations
    dut._log.info("Recovered request/response IDs %s, fresh UART byte 0xa5", replies)


@cocotb.test()
@cocotb.parametrize(
    write=[False, True], pulse_ps=[10000, 1] if CPU_PERIOD_PS else [10000, 2]
)
async def reset_at_response(dut: Any, write: bool, pulse_ps: int) -> None:
    """Cancel a due coherent reply and reuse its ID and credit after release."""
    core_clk = dut.i_cpu_clk if CPU_PERIOD_PS else dut.i_clk
    bridge = dut.soc.gen_cached_tier.dma_bridge
    ingress = dut.cpu.cluster_memory.gen_coherent_tier.gen_dma_ingress.ingress
    ram = await _start_dma(dut, core_clk)
    await _wait_for_completion(core_clk, bridge, ingress, write)
    # Put the request between edges of both clocks. In independent mode
    # the shortest pulse ends before either clock can sample the input.
    await Timer(4999 if not CPU_PERIOD_PS and pulse_ps == 2 else 1, unit="ps")
    assert not int(ingress.i_rst.value) and not int(bridge.i_rst.value)
    assert not int(ingress.o_resp_valid.value)
    ident = 0 if write else 8
    assert int(ingress.occupied_q.value) & (1 << ident)
    if write:
        assert int(bridge.wbt_out_q[0].value) == 1
    dut.i_rst.value = 1
    # External DDR contents survive core-only reset. The next load must
    # return this byte even if the interrupted read used the same sub-ID.
    ram.mem[0] = 0xA5
    if CPU_PERIOD_PS:
        await Timer(1, unit="ps")
        assert int(ingress.i_rst.value) and int(bridge.i_rst.value)
        assert not int(dut.cpu.i_axi_rst.value)
        if pulse_ps > 1:
            await Timer(pulse_ps - 1, unit="ps")
        dut.i_rst.value = 0
        reset_edges = 0
        for _ in range(32):
            await RisingEdge(core_clk)
            assert int(ingress.i_rst.value) == int(bridge.i_rst.value)
            assert not int(dut.cpu.i_axi_rst.value)
            if not int(ingress.i_rst.value):
                break
            reset_edges += 1
        else:
            raise AssertionError("Paired DMA resets did not release")
        assert reset_edges >= 2
        dut._log.info(
            "write=%s pulse=%d ps, both DMA resets high for %d CPU edges after release",
            write,
            pulse_ps,
            reset_edges,
        )
    else:
        await ReadOnly()
        assert not int(ingress.i_rst.value) and not int(bridge.i_rst.value)
        samples = []
        for edge in range(3):
            await RisingEdge(core_clk)
            await Timer(1, unit="ps")
            samples.append(
                (
                    int(bridge.i_rst.value),
                    int(ingress.i_rst.value),
                    int(ingress.o_resp_valid.value),
                )
            )
            assert not int(dut.cpu.i_axi_rst.value)
            if edge == 0:
                assert int(ingress.pick_valid.value), (
                    "Response must be due at the reset edge"
                )
                assert int(ingress.pick_id.value) == ident
                if not write:
                    assert int(ingress.pick_data.value) & 0xFF == 0x39
                if pulse_ps == 10000:
                    await FallingEdge(core_clk)
                    await Timer(1, unit="ps")
                dut.i_rst.value = 0
        dut._log.info(
            "write=%s pulse=%d ps post-edge (bridge reset, ingress reset, response)=%s "
            "write debt=%d read buffer=%#x read owners=%#x",
            write,
            pulse_ps,
            samples,
            int(bridge.wbt_out_q[0].value),
            int(bridge.rbuf_valid_q.value),
            int(bridge.r_id_busy_q.value),
        )
        assert samples == [(1, 1, 0), (0, 1, 0), (0, 0, 0)]
    assert int(bridge.wbt_out_q[0].value) == 0
    assert int(bridge.rbuf_valid_q.value) == 0
    assert not int(bridge.w_id_busy_q.value) and not int(bridge.r_id_busy_q.value)
    assert not int(ingress.o_resp_valid.value) and not int(ingress.count_q.value)
    assert int(ingress.occupied_q.value) == 0
    await _check_restarted_copy(dut, core_clk, bridge, ingress, ram)

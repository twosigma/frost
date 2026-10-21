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

"""Check uncached fetch takes ownership after replay changes the memory tier."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge
from cocotb_tests.predecode.test_fetch_provider import _clear_inputs


async def handoff_after_replay(dut: Any, target: int, fault: bool) -> None:
    """Leave a cached ask owed, then replay into a newly translated uncached PC."""
    Clock(dut.i_clk, 10, unit="ns").start()
    _clear_inputs(dut)
    dut.i_rst.value = 1
    dut.i_line_after_ok.value = 0
    dut.i_pc.value = 0x1FFA
    dut.i_pa0.value = 0x80054FFA
    dut.i_pa1.value = 0x80054FFC
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    dut.i_retarget.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_retarget.value = 0
    for _ in range(3):
        await FallingEdge(dut.i_clk)
        assert not int(dut.o_instr_valid.value)

    # IF consumes its replay buffer while translation of the next PC starts.
    # Replay intentionally masks the provider's ordinary PC-movement detector.
    dut.i_pc.value = target
    dut.i_pa_valid.value = 0
    dut.i_fetch_replay_consume.value = 1
    dut.i_pipeline_stall.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_fetch_replay_consume.value = 0
    dut.i_pa_valid.value = 1
    dut.i_pa0.value = target
    dut.i_pa1.value = target + 4
    dut.i_fault0.value = int(fault)
    dut.i_fault1.value = int(fault)
    dut.i_fault0_page.value = int(fault)
    dut.i_fault1_page.value = int(fault)
    dut.i_pipeline_stall.value = 0


@cocotb.test()
async def replay_to_unmapped_page_delivers_fault_without_memory_read(dut: Any) -> None:
    """Deliver the new page's fault even though the inactive provider owes cached code."""
    await handoff_after_replay(dut, 0x2000, True)
    for _ in range(32):
        await FallingEdge(dut.i_clk)
        assert not int(dut.o_line_req_valid.value)
        if int(dut.o_instr_valid.value):
            assert int(dut.o_served_word.value) == 0x2000 >> 2
            assert int(dut.o_served_fault0.value)
            assert int(dut.o_served_fault1.value)
            assert int(dut.o_served_fault0_page.value)
            assert int(dut.o_served_fault1_page.value)
            return
    raise AssertionError(
        "uncached provider never delivered the page fault after replay"
    )


@cocotb.test()
async def replay_to_uncached_code_fetches_new_address(dut: Any) -> None:
    """Accept the new tier's request under backpressure and publish its instruction pair."""
    await handoff_after_replay(dut, 0x3000, False)
    ident = None
    for _ in range(32):
        await FallingEdge(dut.i_clk)
        if int(dut.o_line_req_valid.value):
            assert int(dut.o_line_req_addr.value) == 0x3000
            ident = int(dut.o_line_req_id.value)
            break
    assert ident is not None, "uncached provider never requested the new replay PC"
    for _ in range(5):
        await FallingEdge(dut.i_clk)
        assert int(dut.o_line_req_valid.value)
        assert int(dut.o_line_req_addr.value) == 0x3000
    dut.i_line_req_ready.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_line_req_ready.value = 0
    for _ in range(7):
        await FallingEdge(dut.i_clk)
        assert not int(dut.o_instr_valid.value)
    dut.i_line_resp_valid.value = 1
    dut.i_line_resp_id.value = ident
    dut.i_line_resp_rdata.value = 0x0020011300100093
    await FallingEdge(dut.i_clk)
    dut.i_line_resp_valid.value = 0
    for _ in range(32):
        await FallingEdge(dut.i_clk)
        if int(dut.o_instr_valid.value):
            assert int(dut.o_served_word.value) == 0x3000 >> 2
            assert int(dut.o_instr.value) == 0x0020011300100093
            assert not int(dut.o_served_fault0.value)
            assert not int(dut.o_served_fault1.value)
            return
    raise AssertionError("uncached replay request never produced an instruction window")

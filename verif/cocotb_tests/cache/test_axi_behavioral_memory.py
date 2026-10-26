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

"""Check DDR image loading and reset behavior through the model's AXI port.

Dense and wide sparse storage load the image and preserve writes
across reset. TestRIG starts empty, ignores the image, and clears on reset.
"""

import os
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

LINE_BYTES = 32
FULL_STRB = (1 << LINE_BYTES) - 1
IMAGE = sum(
    word << (32 * index)
    for index, word in enumerate(
        (
            0x01234567,
            0x89ABCDEF,
            0x10203040,
            0x50607080,
            0x90A0B0C0,
            0xD0E0F001,
            0x12345678,
            0x9ABCDEF0,
        )
    )
)


async def _wait_high(dut: Any, signal: Any) -> None:
    for _ in range(100):
        await RisingEdge(dut.i_clk)
        if int(signal.value):
            return
    raise AssertionError(f"Timed out waiting for {signal._name}")


async def _reset(dut: Any) -> None:
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0


async def _read(dut: Any, address: int) -> int:
    await FallingEdge(dut.i_clk)
    dut.i_axi_araddr.value = address
    dut.i_axi_arvalid.value = 1
    await _wait_high(dut, dut.o_axi_arready)
    await FallingEdge(dut.i_clk)
    dut.i_axi_arvalid.value = 0
    await _wait_high(dut, dut.o_axi_rvalid)
    assert int(dut.o_axi_rresp.value) == 0
    assert int(dut.o_axi_rlast.value) == 1
    data = int(dut.o_axi_rdata.value)
    await FallingEdge(dut.i_clk)
    dut.i_axi_rready.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_axi_rready.value = 0
    return data


async def _write(dut: Any, address: int, data: int, strobes: int) -> None:
    await FallingEdge(dut.i_clk)
    dut.i_axi_awaddr.value = address
    dut.i_axi_awvalid.value = 1
    await _wait_high(dut, dut.o_axi_awready)
    await FallingEdge(dut.i_clk)
    dut.i_axi_awvalid.value = 0
    dut.i_axi_wdata.value = data
    dut.i_axi_wstrb.value = strobes
    dut.i_axi_wvalid.value = 1
    await _wait_high(dut, dut.o_axi_wready)
    await FallingEdge(dut.i_clk)
    dut.i_axi_wvalid.value = 0
    await _wait_high(dut, dut.o_axi_bvalid)
    assert int(dut.o_axi_bresp.value) == 0
    await FallingEdge(dut.i_clk)
    dut.i_axi_bready.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_axi_bready.value = 0


@cocotb.test()
async def image_and_writes_follow_reset_contract(dut: Any) -> None:
    """Retain the boot image and modified low/high lines except in TestRIG."""
    mode = os.environ["FROST_AXI_MEMORY_TEST_MODE"]
    for name in (
        "i_rst",
        "i_axi_awvalid",
        "i_axi_awid",
        "i_axi_awaddr",
        "i_axi_awlen",
        "i_axi_wvalid",
        "i_axi_wdata",
        "i_axi_wstrb",
        "i_axi_bready",
        "i_axi_arvalid",
        "i_axi_arid",
        "i_axi_araddr",
        "i_axi_arlen",
        "i_axi_rready",
    ):
        getattr(dut, name).value = 0
    dut.i_rst.value = 1
    Clock(dut.i_clk, 10, unit="ns").start()
    await _reset(dut)

    initial = 0 if mode == "dii" else IMAGE
    assert await _read(dut, 0) == initial, "DDR boot image missing after reset"
    words_per_line = LINE_BYTES // 4
    untouched = (
        sum(
            int(dut.memory[words_per_line + index].value) << (32 * index)
            for index in range(words_per_line)
        )
        if mode == "dense"
        else 0
    )
    assert await _read(dut, LINE_BYTES) == untouched

    # Overwrite part of the boot image. A reset must retain the modified
    # bytes, not clear the memory or reload the original image.
    await _write(dut, 0, 0xBBAA << 8, 0b110)
    updated = (initial & ~(0xFFFF << 8)) | (0xBBAA << 8)
    expected = {0: updated, LINE_BYTES: int.from_bytes(b"\x57" * LINE_BYTES, "little")}
    await _write(dut, LINE_BYTES, expected[LINE_BYTES], FULL_STRB)
    if mode != "dense":
        # Same low bits as the image, but beyond 32-bit AXI addressing.
        high = 1 << 35
        assert await _read(dut, high) == 0
        expected[high] = int.from_bytes(b"\xa3" * LINE_BYTES, "little")
        await _write(dut, high, expected[high], FULL_STRB)
    for address, data in expected.items():
        assert await _read(dut, address) == data

    await _reset(dut)
    for address, data in expected.items():
        assert await _read(dut, address) == (0 if mode == "dii" else data), (
            f"DDR reset contents wrong at {address:#x} in {mode} mode"
        )

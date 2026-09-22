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

"""Check JTAG-style BRAM programming independently of readmemh initialization.

Boot the initial image, overwrite its head with illegal zero words and require
no boot, then reload the full image and require the UART banner. Port-A writes
match file_to_bram.tcl: ascending 32-bit words on i_clk_div4, 64-word batches,
and word-zero reset rearm between batches. This covers instruction rows,
predecode regeneration, and half-row steering into 64-bit data BRAM.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    RESET_CYCLES,
    UartMonitor,
    generate_divided_clock,
)

BANNER = "Frost: Hello, world!"

# file_to_bram.tcl runs bounded 64-transaction batches and rewrites word 0
# (the image_load_reset rearm) between batches, so the hardware sees a
# non-monotonic address sequence; mirror it to keep that ordering covered.
BATCH_LIMIT = 64

BOOT_TIMEOUT_CYCLES = int(os.environ.get("COCOTB_RELOAD_BOOT_CYCLES", "800000"))
NO_BOOT_WINDOW_CYCLES = int(os.environ.get("COCOTB_RELOAD_NOBOOT_CYCLES", "300000"))
CLOBBER_WORDS = 64


def _parse_readmemh_words(path: Path) -> list[tuple[int, int]]:
    """Parse a $readmemh image into (byte_address, word) pairs."""
    words: list[tuple[int, int]] = []
    word_index = 0
    for raw_line in path.read_text().splitlines():
        line = raw_line.split("//")[0].strip()
        if not line:
            continue
        for token in line.split():
            if token.startswith("@"):
                word_index = int(token[1:], 16)
                continue
            words.append((word_index * 4, int(token, 16)))
            word_index += 1
    return words


async def _port_a_write(dut: Any, byte_address: int, word: int) -> None:
    """One programming write, one i_clk_div4 cycle (the AXI BRAM ctrl pace)."""
    dut.i_instr_mem_en.value = 1
    dut.i_instr_mem_we.value = 0xF
    dut.i_instr_mem_addr.value = byte_address
    dut.i_instr_mem_wrdata.value = word
    await RisingEdge(dut.i_clk_div4)


async def _port_a_idle(dut: Any) -> None:
    dut.i_instr_mem_en.value = 0
    dut.i_instr_mem_we.value = 0
    # Drain the imem's one-cycle registered write staging before releasing
    # reset, matching the trailing gap in the JTAG flow.
    for _ in range(4):
        await RisingEdge(dut.i_clk_div4)


async def _stream_image(dut: Any, words: list[tuple[int, int]]) -> None:
    """Stream an image through the programming port exactly like file2bram."""
    first = words[0] if words else None
    await RisingEdge(dut.i_clk_div4)
    in_batch = 0
    for byte_address, word in words:
        await _port_a_write(dut, byte_address, word)
        in_batch += 1
        if in_batch >= BATCH_LIMIT and first is not None:
            # The tcl rearms the board's image-load reset one-shot by
            # rewriting the first word between batches.
            await _port_a_write(dut, first[0], first[1])
            in_batch = 0
    await _port_a_idle(dut)


async def _hold_reset(dut: Any) -> None:
    dut.i_rst_n.value = 0
    for _ in range(RESET_CYCLES):
        await RisingEdge(dut.i_clk)


async def _wait_for_banner(
    dut: Any, uart_monitor: UartMonitor, max_cycles: int, context: str
) -> bool:
    waited = 0
    step = 10_000
    while waited < max_cycles:
        await ClockCycles(dut.i_clk, step)
        waited += step
        if uart_monitor.contains(BANNER):
            cocotb.log.info(f"{context}: banner after ~{waited} cycles")
            return True
    cocotb.log.info(f"{context}: no banner within {max_cycles} cycles")
    return False


@cocotb.test()
async def test_bram_reload(dut: Any) -> None:
    """Power-on boot, port-A clobber (must not boot), port-A reload (must boot)."""
    Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns").start()
    cocotb.start_soon(generate_divided_clock(dut))

    uart_monitor = UartMonitor(dut)
    await uart_monitor.start()

    image = _parse_readmemh_words(Path("sw.mem"))
    assert image, "sw.mem parsed to zero words"
    cocotb.log.info(f"Parsed {len(image)} words from sw.mem")

    # --- Phase 0: power-on boot from the $readmemh init image ---
    dut.i_instr_mem_en.value = 0
    dut.i_instr_mem_we.value = 0
    dut.i_instr_mem_addr.value = 0
    dut.i_instr_mem_wrdata.value = 0
    if hasattr(dut, "i_uart_rx"):
        dut.i_uart_rx.value = 1
    if hasattr(dut, "i_external_interrupt"):
        dut.i_external_interrupt.value = 0
    dut.i_rst_n.value = 0
    await Timer(2 * CLK_PERIOD_NS, unit="ns")
    await _hold_reset(dut)
    dut.i_rst_n.value = 1

    booted = await _wait_for_banner(
        dut, uart_monitor, BOOT_TIMEOUT_CYCLES, "phase 0 (power-on)"
    )
    assert booted, "power-on image did not boot: app/harness problem, not the loader"

    # --- Phase 1: clobber the image head; the core must not boot ---
    uart_monitor.clear()
    await _hold_reset(dut)
    clobber = [(addr, 0x0000_0000) for addr in range(0, CLOBBER_WORDS * 4, 4)]
    await _stream_image(dut, clobber)
    dut.i_rst_n.value = 1

    booted = await _wait_for_banner(
        dut, uart_monitor, NO_BOOT_WINDOW_CYCLES, "phase 1 (clobber)"
    )
    assert not booted, (
        "banner appeared after the clobber: port-A writes are not landing "
        "(enable/strobe path), so a reload test would false-pass"
    )

    # --- Phase 2: reload the full original image; boot again ---
    uart_monitor.clear()
    await _hold_reset(dut)
    await _stream_image(dut, image)
    dut.i_rst_n.value = 1

    booted = await _wait_for_banner(
        dut, uart_monitor, BOOT_TIMEOUT_CYCLES, "phase 2 (reload)"
    )
    assert booted, (
        "reloaded image did not boot: the port-A programming path corrupts "
        "the image (instruction rows, write-time sideband, or data-BRAM "
        "half-row steering)"
    )

    uart_monitor.stop()
    cocotb.log.info("=== bram_reload: all three phases passed ===")

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

"""Read and program the low-BRAM image through the platform programming port."""

from pathlib import Path
from typing import Any

from cocotb.triggers import RisingEdge

# Match file_to_bram.tcl's 64-word batches and word-zero reset rearm.
BATCH_LIMIT = 64


def read_bram_image(path: Path) -> list[tuple[int, int]]:
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


async def program_bram_image(dut: Any, words: list[tuple[int, int]]) -> None:
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

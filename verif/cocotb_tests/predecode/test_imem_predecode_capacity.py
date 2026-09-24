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

"""Check the full-size IMEM's predecode overlay coverage and one-cycle fetch rate.

Unlike the small fast-replica bench, this target keeps the default overlay
width, so the 256 KiB IMEM must return one-cycle metadata for every window in
its low 64 KiB. The test streams windows across each 16 KiB boundary and the
64 KiB overlay boundary, varies the high row-address bits, reprograms words,
and fetches an address that aliases word 0 on the IMEM's address pins. The
fast-replica bench covers live-write quarantine and the variable-latency
response rules in detail.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from cocotb_tests.predecode import test_imem_predecode_fast_replica as reference

IMEM_BYTES = 256 * 1024
FAST_BYTES = 64 * 1024


@cocotb.test()
async def test_default_capacity_streaming_and_boundary(dut: Any) -> None:
    """The default fast window covers 64 KiB without aliasing or bubbles."""
    dut.i_port_a_enable.value = 0
    dut.i_port_a_byte_address.value = 0
    dut.i_port_a_write_data.value = 0
    dut.i_port_a_write_enable.value = 0
    dut.i_port_b_enable.value = 0
    dut.i_port_b_byte_address.value = 0
    dut.i_port_b_next_byte_address.value = 4
    Clock(dut.i_port_a_clk, reference.PORT_A_PERIOD_NS, unit="ns").start()
    Clock(dut.i_port_b_clk, reference.PORT_B_PERIOD_NS, unit="ns").start()

    fast_addresses = (
        0,
        4,
        0x3FF8,
        0x3FFC,
        0x4000,
        0x4004,
        0x7FFC,
        0x8000,
        0x8004,
        0xBFFC,
        0xC000,
        0xFFF8,
    )
    slow_addresses = (FAST_BYTES - 4, FAST_BYTES, 0x17C00, IMEM_BYTES)
    # USE_INIT_FILE=0 initializes each word to its word index. Program only
    # the sparse windows under test, including distinct rows whose addresses
    # are equal modulo 16 KiB.
    words = list(range(IMEM_BYTES // 4))
    write_indices = {
        ((address // 4) + offset) % len(words)
        for address in fast_addresses + slow_addresses
        for offset in (0, 1)
    }
    for case, index in enumerate(sorted(write_indices)):
        word = reference._make_word(
            (0x1357_9BDF ^ (case * 0x1020_4081)) & 0xFFFF_FFFF,
            fast_raw_bits=case & 7,
            hi_rd=2 if case & 1 else 3,
            compressed_lo=bool(case & 2),
            compressed_hi=bool(case & 4),
        )
        words[index] = word
        await reference._write_word(dut, index, word)

    # Let the programming quarantine fully drain before checking latency.
    for _ in range(16):
        await RisingEdge(dut.i_port_b_clk)

    async def check_window(address: int, *, fast: bool) -> None:
        await reference._present_fetch_pair(dut, address, address + 4)
        assert int(dut.o_port_b_window_overlay_hit.value) == int(fast), (
            f"Wrong default predecode coverage at {address:#x}"
        )
        assert int(dut.o_port_b_response_ready.value) == int(fast), (
            f"Unexpected first-response latency at {address:#x}"
        )
        if not fast:
            await reference._present_fetch_pair(dut, address, address + 4)
            assert int(dut.o_port_b_response_ready.value) == 1
            assert int(dut.o_port_b_window_overlay_hit.value) == 0
        reference._check_fetch_window_outputs(
            dut, words, address // 4, label=f"capacity window {address:#x}"
        )

    # No enable gaps: every overlay request must complete on its first edge,
    # even as parity and the high row-address bits change between requests.
    for address in fast_addresses + fast_addresses[::-1]:
        await check_window(address, fast=True)
    for address in slow_addresses:
        await check_window(address, fast=False)
        await check_window(0x4004, fast=True)

    await FallingEdge(dut.i_port_b_clk)
    dut.i_port_b_enable.value = 0
    held_data = int(dut.o_port_b_read_data.value)
    held_metadata = int(dut.o_port_b_pc_metadata_by_parity.value)
    for _ in range(3):
        await RisingEdge(dut.i_port_b_clk)
        await ReadOnly()
        assert int(dut.o_port_b_read_data.value) == held_data
        assert int(dut.o_port_b_pc_metadata_by_parity.value) == held_metadata

    # Reprogram words above 16 KiB. Each write must reach its own scalar row,
    # not the row at the same offset in the first 16 KiB.
    for index in (0x4000 // 4, 0x4004 // 4, 0xC000 // 4, 0xC004 // 4):
        words[index] ^= 0xFFFF_FFFF
        await reference._write_word(dut, index, words[index])
    for _ in range(16):
        await RisingEdge(dut.i_port_b_clk)
    for address in (0, 0x4000, 0x4004, 0xC000, 0xC004):
        await check_window(address, fast=True)

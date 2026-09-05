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

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Two Sigma Open Source, LLC

"""Check gearboxes against independent bit queues, including arbitrary slips."""

from collections import deque
import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def bitstream_reference(dut: Any) -> None:
    """Exercise every phase, sparse input, resets, and continuous raw output."""
    rng = random.Random(64066)
    tx_bits: deque[int] = deque()
    rx_bits: deque[int] = deque()
    dut.i_clk.value = 0
    dut.i_rst.value = 1
    dut.i_block_valid.value = 0
    dut.i_raw_valid.value = 0
    dut.i_block.value = 0
    dut.i_raw_data.value = 0
    dut.i_slip.value = 0
    for cycle in range(7000):
        reset = cycle in (0, 1, 2801, 5101)
        continuous = cycle < 2000
        block = rng.getrandbits(66)
        raw = rng.getrandbits(64)
        block_valid = continuous or rng.random() < 0.7
        raw_valid = continuous or rng.random() < 0.7
        slip = rng.random() < 0.3
        dut.i_clk.value = 0
        dut.i_rst.value = int(reset)
        dut.i_block.value = block
        dut.i_block_valid.value = int(block_valid)
        dut.i_raw_data.value = raw
        dut.i_raw_valid.value = int(raw_valid)
        dut.i_slip.value = int(slip)
        await Timer(2, unit="ns")
        if reset:
            tx_bits.clear()
            rx_bits.clear()
            assert not int(dut.o_raw_valid.value)
            assert not int(dut.o_block_valid.value)
        else:
            if 5 < cycle < 2000:
                assert int(dut.o_raw_valid.value), "raw stream underflow"
            if int(dut.o_raw_valid.value):
                expected = sum(tx_bits.popleft() << bit for bit in range(64))
                assert int(dut.o_raw_data.value) == expected
            if block_valid and int(dut.o_block_ready.value):
                tx_bits.extend(block >> bit & 1 for bit in range(66))
            if int(dut.o_block_valid.value):
                expected = sum(rx_bits.popleft() << bit for bit in range(66))
                assert int(dut.o_block.value) == expected
                if slip:
                    rx_bits.popleft()
            if raw_valid:
                rx_bits.extend(raw >> bit & 1 for bit in range(64))
        dut.i_clk.value = 1
        await Timer(2, unit="ns")

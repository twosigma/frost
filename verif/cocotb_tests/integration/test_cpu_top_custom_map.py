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

"""Check that a CPU integration map unrelated to FROST's low BRAM and device quadrant."""

from typing import Any

import os

import cocotb
from cocotb_tests.integration.test_cpu_top import System, addi, csr, load, store

BOOT = 0x10_00001000
DEVICE = 0x14_00000000
CACHED = 0x18_00000000
UNCACHED = 0x10_00000200


def high_address(rd: int, high: int, low: int = 0) -> list[int]:
    """Construct instructions that load a physical address above 4 GiB."""
    return [
        addi(rd, 0, high),
        (32 << 20) | (rd << 15) | (1 << 12) | (rd << 7) | 0x13,
        addi(rd, rd, low),
    ]


@cocotb.test()
async def relocated_boot_memory_and_devices_preserve_full_addresses(dut: Any) -> None:
    """Check relocated boot memory and devices preserve full addresses."""
    s = System(dut, boot=BOOT)
    s.device_base = DEVICE
    s.program(
        high_address(1, 0x14)
        + high_address(4, 0x18)
        + high_address(6, 0x10, 0x200)
        + [
            load(5, 4, 0, 3),
            store(5, 1, 0x10, 3),
            load(7, 6, 0, 3),
            store(7, 1, 0x18, 3),
            load(3, 1, 4, 4),
            store(3, 1, 0x20, 0),
            addi(2, 0, 1),
            store(2, 1, 8, 0),
            0x0000006F,
        ]
    )
    for address, value in (
        (CACHED, 0x1122334455667788),
        (UNCACHED, 0xABCDEF0123456789),
    ):
        for n in range(8):
            s.memory[address + n] = (value >> (8 * n)) & 255
    await s.reset()
    assert await s.until_write(DEVICE + 8) == 1
    values = {address: value for _, address, value in s.effects}
    assert values[DEVICE + 0x10] == 0x1122334455667788
    assert values[DEVICE + 0x18] == 0xABCDEF0123456789
    assert values[DEVICE + 0x20] == 0xA5
    assert s.pops == 1
    reads = {
        address: (size, cache, prot)
        for _, kind, address, size, cache, prot in s.transactions
        if kind == "read"
    }
    assert reads[CACHED][:2] == (6, 15)
    enabled = os.environ.get("FROST_TEST_NORMAL_CACHE") == "1"
    assert reads[UNCACHED][:2] == (3, 14 if enabled else 2)
    assert reads[DEVICE + 4][:2] == (0, 0)
    assert reads[BOOT] == ((5, 14, 7) if enabled else (3, 2, 7))
    assert not any(address < 0x1_00000000 for _, _, address, *_ in s.transactions)


@cocotb.test()
async def original_frost_low_address_is_rejected_by_custom_pma(dut: Any) -> None:
    """Check original frost low address is rejected by custom pma."""
    s = System(dut, boot=BOOT)
    s.device_base = DEVICE
    s.program(
        [0x00000517, addi(10, 10, 0x100), csr(0, 10, 0x305)]
        + high_address(1, 0x14)
        + [store(0, 0, 0, 3), 0x0000006F]
    )
    s.program([csr(7, 0, 0x342, 2), store(7, 1, 0x10, 3), 0x0000006F], BOOT + 0x100)
    await s.reset()
    assert await s.until_write(DEVICE + 0x10) == 7
    assert not any(address == 0 for _, _, address, *_ in s.transactions)

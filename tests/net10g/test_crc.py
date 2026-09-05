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

"""Check the parallel CRC against Python's independently implemented zlib."""

import random
from typing import Any
import zlib

import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def crc_reference(dut: Any) -> None:
    """Exercise arbitrary seeds and sparse byte enables."""
    rng = random.Random(1001)
    for _ in range(1500):
        seed = rng.getrandbits(32)
        data = rng.randbytes(8)
        keep = rng.getrandbits(8)
        dut.i_crc.value = seed
        dut.i_data.value = int.from_bytes(data, "little")
        dut.i_keep.value = keep
        await Timer(1, unit="ns")
        included = bytes(value for lane, value in enumerate(data) if keep >> lane & 1)
        assert int(dut.o_crc.value) == (
            zlib.crc32(included, seed ^ 0xFFFFFFFF) ^ 0xFFFFFFFF
        )

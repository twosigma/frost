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

"""Check vec_xbar's byte crossbar and rotator against a Python model.

Random data, byte indices, index-valid bits and rotation amounts, one input per
cycle; both outputs are compared one cycle after the cycle that takes the
input. Runs at the BYTES the build sets (32 in the registry entry; 64 in its
512-bit variant).
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 1


def pack(values: list[int], width: int) -> int:
    """Pack values, element 0 lowest."""
    out = 0
    for i, v in enumerate(values):
        out |= v << (width * i)
    return out


@cocotb.test()
async def test_vec_xbar_random(dut: Any) -> None:
    """Random gathers and rotations, back to back."""
    nbytes = len(dut.i_idx_valid)
    ibits = (nbytes - 1).bit_length()
    rng = random.Random(2030)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in ("i_valid", "i_data", "i_idx", "i_idx_valid", "i_rot"):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    count = 4000
    pending: dict[int, tuple[int, int]] = {}
    checked = 0
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            data = [rng.getrandbits(8) for _ in range(nbytes)]
            idx = [rng.randrange(nbytes) for _ in range(nbytes)]
            valid = [int(rng.random() < 0.8) for _ in range(nbytes)]
            rot = rng.randrange(nbytes)
            dut.i_valid.value = 1
            dut.i_data.value = pack(data, 8)
            dut.i_idx.value = pack(idx, ibits)
            dut.i_idx_valid.value = pack(valid, 1)
            dut.i_rot.value = rot
            gather = [data[idx[i]] if valid[i] else 0 for i in range(nbytes)]
            rotate = [data[(i + rot) % nbytes] for i in range(nbytes)]
            pending[cycle] = (pack(gather, 8), pack(rotate, 8))
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            want_gather, want_rotate = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            assert int(dut.o_gather.value) == want_gather, (
                f"gather {int(dut.o_gather.value):#x} want {want_gather:#x}"
            )
            assert int(dut.o_rotate.value) == want_rotate, (
                f"rotate {int(dut.o_rotate.value):#x} want {want_rotate:#x}"
            )
            checked += 1
        await FallingEdge(dut.i_clk)
    assert checked == count
    dut._log.info(f"{checked} permutations checked at {nbytes} bytes")

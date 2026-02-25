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

"""DUT interface for CDB Arbiter verification.

Provides packing/unpacking for fu_complete_t array and cdb_broadcast_t output,
plus transaction helpers for driving stimulus and reading results.

Verilator exposes the unpacked array port as dut.i_fu_complete[index].
Icarus (via cdb_arbiter_tb wrapper) flattens it to individual signals
(i_fu_complete_0 .. i_fu_complete_6).  The _get_fu_signal helper detects
which convention is in use at runtime.
"""

from typing import Any
from cocotb.triggers import RisingEdge, FallingEdge

from .cdb_arbiter_model import FuComplete, CdbBroadcast, NUM_FUS

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
FLEN = 64
EXC_CAUSE_WIDTH = 5
FP_FLAGS_WIDTH = 5
FU_TYPE_WIDTH = 3

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK64 = (1 << FLEN) - 1

# fu_complete_t bit layout (packed, MSB-first in SV, pack from LSB):
# fp_flags(5) | exc_cause(5) | exception(1) | value(64) | tag(5) | valid(1)
# Total: 81 bits
FU_COMPLETE_WIDTH = FP_FLAGS_WIDTH + EXC_CAUSE_WIDTH + 1 + FLEN + ROB_TAG_WIDTH + 1

# cdb_broadcast_t bit layout (packed, MSB-first in SV, pack from LSB):
# fu_type(3) | fp_flags(5) | exc_cause(5) | exception(1) | value(64) | tag(5) | valid(1)
# Total: 84 bits


def pack_fu_complete(req: FuComplete) -> int:
    """Pack an FuComplete into a bit vector matching fu_complete_t layout."""
    val = 0
    bit = 0

    val |= (req.fp_flags & 0x1F) << bit
    bit += FP_FLAGS_WIDTH
    val |= (req.exc_cause & 0x1F) << bit
    bit += EXC_CAUSE_WIDTH
    val |= (1 if req.exception else 0) << bit
    bit += 1
    val |= (req.value & MASK64) << bit
    bit += FLEN
    val |= (req.tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if req.valid else 0) << bit

    return val


def unpack_cdb_broadcast(raw: int) -> CdbBroadcast:
    """Unpack a cdb_broadcast_t bit vector into a CdbBroadcast."""
    bit = 0

    fu_type = (raw >> bit) & 0x7
    bit += FU_TYPE_WIDTH
    fp_flags = (raw >> bit) & 0x1F
    bit += FP_FLAGS_WIDTH
    exc_cause = (raw >> bit) & 0x1F
    bit += EXC_CAUSE_WIDTH
    exception = bool((raw >> bit) & 1)
    bit += 1
    value = (raw >> bit) & MASK64
    bit += FLEN
    tag = (raw >> bit) & MASK_TAG
    bit += ROB_TAG_WIDTH
    valid = bool((raw >> bit) & 1)

    return CdbBroadcast(
        valid=valid,
        tag=tag,
        value=value,
        exception=exception,
        exc_cause=exc_cause,
        fp_flags=fp_flags,
        fu_type=fu_type,
    )


class CdbArbiterInterface:
    """Interface to the CDB arbiter DUT.

    Handles both Verilator (unpacked array) and Icarus (flattened individual ports).
    """

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    async def reset_dut(self, cycles: int = 5) -> None:
        """Reset the DUT and init all inputs."""
        self.clear_all_fu_completes()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: rising edge then falling edge."""
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _get_fu_signal(self, fu_index: int) -> Any:
        """Get the DUT signal for a specific FU complete slot.

        Verilator exposes unpacked arrays as indexable handles:
          dut.i_fu_complete[index]
        Icarus TB wrapper uses flattened individual ports:
          dut.i_fu_complete_0 .. dut.i_fu_complete_6
        """
        if hasattr(self.dut, "i_fu_complete_0"):
            return getattr(self.dut, f"i_fu_complete_{fu_index}")
        return self.dut.i_fu_complete[fu_index]

    def drive_fu_complete(
        self,
        fu_index: int,
        tag: int = 0,
        value: int = 0,
        exception: bool = False,
        exc_cause: int = 0,
        fp_flags: int = 0,
    ) -> None:
        """Drive a single FU completion request."""
        req = FuComplete(
            valid=True,
            tag=tag,
            value=value,
            exception=exception,
            exc_cause=exc_cause,
            fp_flags=fp_flags,
        )
        self._get_fu_signal(fu_index).value = pack_fu_complete(req)

    def clear_fu_complete(self, fu_index: int) -> None:
        """Clear a single FU completion slot."""
        self._get_fu_signal(fu_index).value = 0

    def clear_all_fu_completes(self) -> None:
        """Clear all FU completion slots."""
        for i in range(NUM_FUS):
            self._get_fu_signal(i).value = 0

    def read_cdb_output(self) -> CdbBroadcast:
        """Read the CDB broadcast output."""
        raw = int(self.dut.o_cdb.value)
        return unpack_cdb_broadcast(raw)

    def read_grant(self) -> list[bool]:
        """Read the o_grant vector as a list of bools."""
        raw = int(self.dut.o_grant.value)
        return [bool((raw >> i) & 1) for i in range(NUM_FUS)]

    def read_grant_raw(self) -> int:
        """Read o_grant as a raw integer."""
        return int(self.dut.o_grant.value)

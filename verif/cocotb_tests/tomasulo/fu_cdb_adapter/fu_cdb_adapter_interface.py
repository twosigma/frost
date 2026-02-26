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

"""DUT interface for FU CDB Adapter verification.

Provides packing/unpacking for fu_complete_t struct and transaction helpers
for driving stimulus and reading results.
"""

from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge

from .fu_cdb_adapter_model import FuComplete

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
FLEN = 64
EXC_CAUSE_WIDTH = 5
FP_FLAGS_WIDTH = 5

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK64 = (1 << FLEN) - 1

# fu_complete_t bit layout (packed, MSB-first in SV, pack from LSB):
# fp_flags(5) | exc_cause(5) | exception(1) | value(64) | tag(5) | valid(1)
# Total: 81 bits
FU_COMPLETE_WIDTH = FP_FLAGS_WIDTH + EXC_CAUSE_WIDTH + 1 + FLEN + ROB_TAG_WIDTH + 1


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


def unpack_fu_complete(raw: int) -> FuComplete:
    """Unpack a fu_complete_t bit vector into an FuComplete."""
    bit = 0

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

    return FuComplete(
        valid=valid,
        tag=tag,
        value=value,
        exception=exception,
        exc_cause=exc_cause,
        fp_flags=fp_flags,
    )


class FuCdbAdapterInterface:
    """Interface to the FU CDB adapter DUT."""

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    async def reset_dut(self, cycles: int = 5) -> None:
        """Reset the DUT and initialize all inputs."""
        self.clear_fu_result()
        self.clear_grant()
        self.clear_flush()
        self.clear_partial_flush()
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

    def drive_fu_result(
        self,
        tag: int = 0,
        value: int = 0,
        exception: bool = False,
        exc_cause: int = 0,
        fp_flags: int = 0,
    ) -> None:
        """Drive an FU result input (sets valid=True)."""
        req = FuComplete(
            valid=True,
            tag=tag,
            value=value,
            exception=exception,
            exc_cause=exc_cause,
            fp_flags=fp_flags,
        )
        self.dut.i_fu_result.value = pack_fu_complete(req)

    def clear_fu_result(self) -> None:
        """Clear FU result input (valid=0)."""
        self.dut.i_fu_result.value = 0

    def drive_grant(self) -> None:
        """Assert i_grant."""
        self.dut.i_grant.value = 1

    def clear_grant(self) -> None:
        """Deassert i_grant."""
        self.dut.i_grant.value = 0

    def drive_flush(self) -> None:
        """Assert i_flush (full flush)."""
        self.dut.i_flush.value = 1

    def clear_flush(self) -> None:
        """Deassert i_flush."""
        self.dut.i_flush.value = 0

    def drive_partial_flush(self, flush_tag: int, rob_head_tag: int = 0) -> None:
        """Assert i_flush_en with tag and head for age comparison."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag & MASK_TAG
        self.dut.i_rob_head_tag.value = rob_head_tag & MASK_TAG

    def clear_partial_flush(self) -> None:
        """Deassert i_flush_en."""
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0

    def read_fu_complete(self) -> FuComplete:
        """Read the o_fu_complete output."""
        raw = int(self.dut.o_fu_complete.value)
        return unpack_fu_complete(raw)

    def read_result_pending(self) -> bool:
        """Read o_result_pending."""
        return bool(int(self.dut.o_result_pending.value))

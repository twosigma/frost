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

"""DUT interface for FP Multiply Shim verification.

Provides helper methods for driving rs_issue_t input, reading fu_complete_t
output, and managing flush/reset sequences on the fp_mul_shim module.

Reuses pack_rs_issue and unpack_fu_complete from the fp_add_shim_interface
to avoid duplicating struct packing logic.
"""

from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge

from .fp_add_shim_interface import pack_rs_issue, unpack_fu_complete

# Width constants
ROB_TAG_WIDTH = 5
MASK_TAG = (1 << ROB_TAG_WIDTH) - 1


class FpMulShimInterface:
    """Interface to the fp_mul_shim DUT."""

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    def _init_inputs(self) -> None:
        """Drive all inputs to zero."""
        self.dut.i_rs_issue.value = 0
        self.dut.i_flush.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0

    async def reset(self, cycles: int = 3) -> None:
        """Reset sequence: assert i_rst_n low, hold for *cycles*, then release."""
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.dut.i_clk)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.dut.i_clk)
        await FallingEdge(self.dut.i_clk)

    def drive_issue(
        self,
        valid: bool,
        rob_tag: int,
        op: int,
        src1_value: int,
        src2_value: int,
        src3_value: int = 0,
        rm: int = 0,
    ) -> None:
        """Drive i_rs_issue with the given fields (packs into rs_issue_t)."""
        self.dut.i_rs_issue.value = pack_rs_issue(
            valid=valid,
            rob_tag=rob_tag,
            op=op,
            src1_value=src1_value,
            src2_value=src2_value,
            src3_value=src3_value,
            rm=rm,
        )

    def read_fu_complete(self) -> dict:
        """Unpack and return the o_fu_complete output as a dict."""
        raw = int(self.dut.o_fu_complete.value)
        return unpack_fu_complete(raw)

    def read_busy(self) -> bool:
        """Return the current value of o_fu_busy."""
        return bool(int(self.dut.o_fu_busy.value))

    def drive_flush(self) -> None:
        """Assert i_flush (full flush)."""
        self.dut.i_flush.value = 1

    def clear_flush(self) -> None:
        """Deassert i_flush."""
        self.dut.i_flush.value = 0

    def drive_partial_flush(self, flush_tag: int, head_tag: int) -> None:
        """Assert i_flush_en with tag and ROB head for age comparison."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag & MASK_TAG
        self.dut.i_rob_head_tag.value = head_tag & MASK_TAG

    def clear_partial_flush(self) -> None:
        """Deassert i_flush_en and clear tag signals."""
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0

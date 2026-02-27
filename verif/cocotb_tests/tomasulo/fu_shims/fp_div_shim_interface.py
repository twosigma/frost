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

"""DUT interface for FP Divide/Sqrt Shim verification.

Provides clean access to fp_div_shim signals with proper typing and
helper methods for driving stimulus and reading results.

Reuses pack_rs_issue and unpack_fu_complete from the fp_add_shim
interface, and _parse_instr_op_enum for op-code resolution.
"""

from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge

from .fp_add_shim_interface import (
    pack_rs_issue,
    unpack_fu_complete,
    _parse_instr_op_enum,
    MASK_TAG,
)

# ---------------------------------------------------------------------------
# Parse instr_op_e once at import time
# ---------------------------------------------------------------------------
_INSTR_OPS = _parse_instr_op_enum()

OP_FDIV_S = _INSTR_OPS["FDIV_S"]
OP_FDIV_D = _INSTR_OPS["FDIV_D"]
OP_FSQRT_S = _INSTR_OPS["FSQRT_S"]
OP_FSQRT_D = _INSTR_OPS["FSQRT_D"]

CLOCK_PERIOD_NS = 10


class FpDivShimInterface:
    """Interface to the fp_div_shim DUT."""

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    def _init_inputs(self) -> None:
        """Drive all inputs to zero / safe defaults."""
        self.dut.i_rs_issue.value = 0
        self.dut.i_flush.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0

    async def reset(self, cycles: int = 3) -> None:
        """Reset the DUT for *cycles* low-reset clock edges."""
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def drive_issue(
        self,
        valid: bool,
        rob_tag: int,
        op: int,
        src1_value: int,
        src2_value: int,
        rm: int = 0,
    ) -> None:
        """Drive an rs_issue_t onto i_rs_issue.

        For FP div/sqrt the only meaningful fields are valid, rob_tag, op,
        src1_value, src2_value, and rm.  All other fields are driven as 0.
        """
        self.dut.i_rs_issue.value = pack_rs_issue(
            valid=valid,
            rob_tag=rob_tag,
            op=op,
            src1_value=src1_value,
            src2_value=src2_value,
            rm=rm,
        )

    def clear_issue(self) -> None:
        """Deassert i_rs_issue (all zeros)."""
        self.dut.i_rs_issue.value = 0

    def read_fu_complete(self) -> dict:
        """Unpack o_fu_complete and return as a dict."""
        raw = int(self.dut.o_fu_complete.value)
        return unpack_fu_complete(raw)

    def read_busy(self) -> bool:
        """Return the current state of o_fu_busy."""
        return bool(int(self.dut.o_fu_busy.value))

    def drive_flush(self) -> None:
        """Assert i_flush (full pipeline flush)."""
        self.dut.i_flush.value = 1

    def clear_flush(self) -> None:
        """Deassert i_flush."""
        self.dut.i_flush.value = 0

    def drive_partial_flush(self, flush_tag: int, head_tag: int) -> None:
        """Assert i_flush_en with the given tag and ROB head tag."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag & MASK_TAG
        self.dut.i_rob_head_tag.value = head_tag & MASK_TAG

    def clear_partial_flush(self) -> None:
        """Deassert i_flush_en and clear tag fields."""
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0

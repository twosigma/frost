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

"""DUT interface for int_muldiv_shim verification.

Reuses pack_rs_issue and unpack_fu_complete from fp_add_shim_interface
to avoid duplicating struct packing logic.

The MUL/DIV shim has two output ports (o_mul_fu_complete, o_div_fu_complete)
and supports full and partial flush.
"""

from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge

from .fp_add_shim_interface import pack_rs_issue, unpack_fu_complete, MASK_TAG


class IntMulDivShimInterface:
    """Interface to the int_muldiv_shim DUT."""

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    def _init_inputs(self) -> None:
        """Drive all inputs to zero / inactive."""
        self.dut.i_rs_issue.value = 0
        self.dut.i_flush.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0
        self.dut.i_div_accepted.value = 0

    async def reset(self, cycles: int = 3) -> None:
        """Reset the DUT for the given number of cycles.

        Drives all inputs low, asserts reset (active-low), waits, then
        deasserts reset and settles on the falling edge.
        """
        self._init_inputs()
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

    def drive_issue(
        self,
        valid: bool,
        rob_tag: int,
        op: int,
        src1_value: int,
        src2_value: int,
    ) -> None:
        """Pack and drive an rs_issue_t onto i_rs_issue."""
        packed = pack_rs_issue(
            valid=valid,
            rob_tag=rob_tag,
            op=op,
            src1_value=src1_value,
            src2_value=src2_value,
        )
        self.dut.i_rs_issue.value = packed

    def clear_issue(self) -> None:
        """Clear i_rs_issue (drive to zero / invalid)."""
        self.dut.i_rs_issue.value = 0

    def read_mul_fu_complete(self) -> dict:
        """Read and unpack the o_mul_fu_complete output."""
        raw = int(self.dut.o_mul_fu_complete.value)
        return unpack_fu_complete(raw)

    def read_div_fu_complete(self) -> dict:
        """Read and unpack the o_div_fu_complete output."""
        raw = int(self.dut.o_div_fu_complete.value)
        return unpack_fu_complete(raw)

    def read_busy(self) -> bool:
        """Read o_fu_busy."""
        return bool(int(self.dut.o_fu_busy.value))

    def drive_flush(self) -> None:
        """Assert i_flush (full pipeline flush)."""
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

    def drive_div_accepted(self) -> None:
        """Assert i_div_accepted for one cycle (pop FIFO head)."""
        self.dut.i_div_accepted.value = 1

    def clear_div_accepted(self) -> None:
        """Deassert i_div_accepted."""
        self.dut.i_div_accepted.value = 0

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

"""DUT interface for int_alu_shim verification.

pack_rs_issue and unpack_fu_complete come from fp_add_shim_interface.

The ALU shim is combinational and has no flush ports. Besides rs_issue_t,
drive_issue drives the two RS-side hints: i_issue_writes_cdb_hint, which
gates o_fu_complete.valid and is low for conditional branches, and
i_shift_amount_hint, which only shifts and rotates use.
"""

from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge

from .fp_add_shim_interface import (
    _parse_instr_op_enum,
    pack_rs_issue,
    unpack_fu_complete,
)

_INSTR_OP = _parse_instr_op_enum()
_BRANCH_OPS = {
    _INSTR_OP["BEQ"],
    _INSTR_OP["BNE"],
    _INSTR_OP["BLT"],
    _INSTR_OP["BGE"],
    _INSTR_OP["BLTU"],
    _INSTR_OP["BGEU"],
}


# Barrel-shifter ops that take their amount from the immediate, listed by
# name independently of riscv_pkg::projected_shift_controls. Every other op
# either shifts by rs2 or does not use the barrel shifter, so its hint can be rs2.
_IMMEDIATE_BARREL_OPS = {
    _INSTR_OP[name]
    for name in ("SLLI", "SRLI", "SRAI", "RORI", "SLLIW", "SRLIW", "SRAIW", "RORIW")
}


class IntAluShimInterface:
    """Interface to the int_alu_shim DUT."""

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
        self.dut.i_issue_writes_cdb_hint.value = 0
        self.dut.i_shift_amount_hint.value = 0

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
        imm: int = 0,
        use_imm: bool = False,
        pc: int = 0,
        link_addr: int = 0,
    ) -> None:
        """Pack and drive an rs_issue_t onto i_rs_issue, with both RS-side hints.

        The shim consumes imm and use_imm; imm also carries the precomputed
        AUIPC value and the link address. pc and link_addr are packed for
        completeness only (the shim and ALU take no PC and read the link from
        imm). The CDB hint is low for conditional branches and high otherwise,
        as the RS predecodes it. The shift-amount hint is imm for
        _IMMEDIATE_BARREL_OPS and src2_value otherwise.
        """
        packed = pack_rs_issue(
            valid=valid,
            rob_tag=rob_tag,
            op=op,
            src1_value=src1_value,
            src2_value=src2_value,
            imm=imm,
            use_imm=use_imm,
            pc=pc,
            link_addr=link_addr,
        )
        self.dut.i_rs_issue.value = packed
        self.dut.i_shift_amount_hint.value = (
            imm if op in _IMMEDIATE_BARREL_OPS else src2_value
        ) & 0x3F
        self.dut.i_issue_writes_cdb_hint.value = 0 if op in _BRANCH_OPS else 1

    def clear_issue(self) -> None:
        """Clear i_rs_issue (drive to zero / invalid) and the CDB hint."""
        self.dut.i_rs_issue.value = 0
        self.dut.i_issue_writes_cdb_hint.value = 0

    def read_fu_complete(self) -> dict:
        """Read and unpack the o_fu_complete output."""
        raw = int(self.dut.o_fu_complete.value)
        return unpack_fu_complete(raw)

    def read_busy(self) -> bool:
        """Read o_fu_busy."""
        return bool(int(self.dut.o_fu_busy.value))

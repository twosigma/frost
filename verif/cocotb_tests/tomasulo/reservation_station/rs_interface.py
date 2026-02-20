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

"""DUT interface for Reservation Station verification.

Provides clean access to RS signals with proper typing and helper methods
for driving stimulus and reading outputs.

Note: Verilator flattens packed structs into single bit vectors.
This interface handles packing/unpacking struct fields automatically.

When running with the Icarus VPI-safe testbench wrapper
(reservation_station_tb), dispatch and issue ports are individual
scalar signals instead of wide packed struct ports. The interface
detects this automatically via ``hasattr(dut, 'i_dispatch_valid')``.
"""

from typing import Any
from cocotb.triggers import RisingEdge, FallingEdge

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
XLEN = 32
FLEN = 64

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1  # 0x1F
MASK32 = (1 << XLEN) - 1
MASK64 = (1 << FLEN) - 1

# instr_op_e: typedef enum (no explicit type) -> 32-bit int in SystemVerilog
OP_WIDTH = 32
MASK_OP = (1 << OP_WIDTH) - 1

# rs_type_e: 3 bits
RS_TYPE_WIDTH = 3

# mem_size_e: 2 bits
MEM_SIZE_WIDTH = 2

# exc_cause_t: 5 bits
EXC_CAUSE_WIDTH = 5

# fp_flags_t: 5 bits
FP_FLAGS_WIDTH = 5

# fu_type_e: 3 bits
FU_TYPE_WIDTH = 3


# =============================================================================
# Struct Packing/Unpacking
# =============================================================================
# SystemVerilog packed structs are MSB-first (first field at highest bits).
# We pack from LSB to MSB (reverse order of struct declaration).


def pack_rs_dispatch(
    valid: bool = False,
    rs_type: int = 0,
    rob_tag: int = 0,
    op: int = 0,
    src1_ready: bool = False,
    src1_tag: int = 0,
    src1_value: int = 0,
    src2_ready: bool = False,
    src2_tag: int = 0,
    src2_value: int = 0,
    src3_ready: bool = False,
    src3_tag: int = 0,
    src3_value: int = 0,
    imm: int = 0,
    use_imm: bool = False,
    rm: int = 0,
    branch_target: int = 0,
    predicted_taken: bool = False,
    predicted_target: int = 0,
    is_fp_mem: bool = False,
    mem_size: int = 0,
    mem_signed: bool = False,
    csr_addr: int = 0,
    csr_imm: int = 0,
) -> int:
    """Pack dispatch fields into a bit vector for driving i_dispatch."""
    val = 0
    bit = 0

    # Pack from LSB to MSB (reverse of struct declaration order)
    val |= (csr_imm & 0x1F) << bit
    bit += 5
    val |= (csr_addr & 0xFFF) << bit
    bit += 12
    val |= (1 if mem_signed else 0) << bit
    bit += 1
    val |= (mem_size & 0x3) << bit
    bit += MEM_SIZE_WIDTH
    val |= (1 if is_fp_mem else 0) << bit
    bit += 1
    val |= (predicted_target & MASK32) << bit
    bit += XLEN
    val |= (1 if predicted_taken else 0) << bit
    bit += 1
    val |= (branch_target & MASK32) << bit
    bit += XLEN
    val |= (rm & 0x7) << bit
    bit += 3
    val |= (1 if use_imm else 0) << bit
    bit += 1
    val |= (imm & MASK32) << bit
    bit += XLEN
    val |= (src3_value & MASK64) << bit
    bit += FLEN
    val |= (src3_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if src3_ready else 0) << bit
    bit += 1
    val |= (src2_value & MASK64) << bit
    bit += FLEN
    val |= (src2_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if src2_ready else 0) << bit
    bit += 1
    val |= (src1_value & MASK64) << bit
    bit += FLEN
    val |= (src1_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if src1_ready else 0) << bit
    bit += 1
    val |= (op & MASK_OP) << bit
    bit += OP_WIDTH
    val |= (rob_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (rs_type & 0x7) << bit
    bit += RS_TYPE_WIDTH
    val |= (1 if valid else 0) << bit
    bit += 1

    return val


def pack_cdb_broadcast(
    valid: bool = False,
    tag: int = 0,
    value: int = 0,
    exception: bool = False,
    exc_cause: int = 0,
    fp_flags: int = 0,
    fu_type: int = 0,
) -> int:
    """Pack CDB broadcast fields into a bit vector for driving i_cdb."""
    val = 0
    bit = 0

    val |= (fu_type & 0x7) << bit
    bit += FU_TYPE_WIDTH
    val |= (fp_flags & 0x1F) << bit
    bit += FP_FLAGS_WIDTH
    val |= (exc_cause & 0x1F) << bit
    bit += EXC_CAUSE_WIDTH
    val |= (1 if exception else 0) << bit
    bit += 1
    val |= (value & MASK64) << bit
    bit += FLEN
    val |= (tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if valid else 0) << bit
    bit += 1

    return val


def unpack_rs_issue(raw: int) -> dict:
    """Unpack rs_issue_t from a bit vector."""
    bit = 0
    result = {}

    result["csr_imm"] = (raw >> bit) & 0x1F
    bit += 5
    result["csr_addr"] = (raw >> bit) & 0xFFF
    bit += 12
    result["mem_signed"] = bool((raw >> bit) & 1)
    bit += 1
    result["mem_size"] = (raw >> bit) & 0x3
    bit += MEM_SIZE_WIDTH
    result["is_fp_mem"] = bool((raw >> bit) & 1)
    bit += 1
    result["predicted_target"] = (raw >> bit) & MASK32
    bit += XLEN
    result["predicted_taken"] = bool((raw >> bit) & 1)
    bit += 1
    result["branch_target"] = (raw >> bit) & MASK32
    bit += XLEN
    result["rm"] = (raw >> bit) & 0x7
    bit += 3
    result["use_imm"] = bool((raw >> bit) & 1)
    bit += 1
    result["imm"] = (raw >> bit) & MASK32
    bit += XLEN
    result["src3_value"] = (raw >> bit) & MASK64
    bit += FLEN
    result["src2_value"] = (raw >> bit) & MASK64
    bit += FLEN
    result["src1_value"] = (raw >> bit) & MASK64
    bit += FLEN
    result["op"] = (raw >> bit) & MASK_OP
    bit += OP_WIDTH
    result["rob_tag"] = (raw >> bit) & MASK_TAG
    bit += ROB_TAG_WIDTH
    result["valid"] = bool((raw >> bit) & 1)
    bit += 1

    return result


# =============================================================================
# DUT Interface Class
# =============================================================================


class RSInterface:
    """Interface to the Reservation Station DUT.

    Automatically detects whether the DUT has flattened ports (Icarus
    testbench wrapper) or packed struct ports (Verilator / direct module).
    """

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut
        # Icarus tb wrapper exposes individual dispatch/issue ports
        self._flat = hasattr(dut, "i_dispatch_valid")

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    async def reset_dut(self, cycles: int = 5) -> None:
        """Reset the DUT and init all inputs."""
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

    def _init_inputs(self) -> None:
        """Initialize all input signals to safe defaults."""
        if self._flat:
            self._clear_dispatch_flat()
        else:
            self.dut.i_dispatch.value = 0
        self.dut.i_cdb.value = 0
        self.dut.i_fu_ready.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0
        self.dut.i_flush_all.value = 0

    # =========================================================================
    # Dispatch
    # =========================================================================

    def drive_dispatch(self, **kwargs: Any) -> None:
        """Drive dispatch signals. Pass keyword args matching pack_rs_dispatch."""
        kwargs["valid"] = True
        if self._flat:
            self._drive_dispatch_flat(**kwargs)
        else:
            self.dut.i_dispatch.value = pack_rs_dispatch(**kwargs)

    def clear_dispatch(self) -> None:
        """Clear dispatch signals."""
        if self._flat:
            self._clear_dispatch_flat()
        else:
            self.dut.i_dispatch.value = 0

    def _drive_dispatch_flat(self, **kwargs: Any) -> None:
        """Drive individual dispatch ports (Icarus wrapper)."""
        d = self.dut
        d.i_dispatch_valid.value = 1 if kwargs.get("valid") else 0
        d.i_dispatch_rs_type.value = int(kwargs.get("rs_type", 0)) & 0x7
        d.i_dispatch_rob_tag.value = int(kwargs.get("rob_tag", 0)) & MASK_TAG
        d.i_dispatch_op.value = int(kwargs.get("op", 0)) & MASK_OP
        d.i_dispatch_src1_ready.value = 1 if kwargs.get("src1_ready") else 0
        d.i_dispatch_src1_tag.value = int(kwargs.get("src1_tag", 0)) & MASK_TAG
        d.i_dispatch_src1_value.value = int(kwargs.get("src1_value", 0)) & MASK64
        d.i_dispatch_src2_ready.value = 1 if kwargs.get("src2_ready") else 0
        d.i_dispatch_src2_tag.value = int(kwargs.get("src2_tag", 0)) & MASK_TAG
        d.i_dispatch_src2_value.value = int(kwargs.get("src2_value", 0)) & MASK64
        d.i_dispatch_src3_ready.value = 1 if kwargs.get("src3_ready") else 0
        d.i_dispatch_src3_tag.value = int(kwargs.get("src3_tag", 0)) & MASK_TAG
        d.i_dispatch_src3_value.value = int(kwargs.get("src3_value", 0)) & MASK64
        d.i_dispatch_imm.value = int(kwargs.get("imm", 0)) & MASK32
        d.i_dispatch_use_imm.value = 1 if kwargs.get("use_imm") else 0
        d.i_dispatch_rm.value = int(kwargs.get("rm", 0)) & 0x7
        d.i_dispatch_branch_target.value = int(kwargs.get("branch_target", 0)) & MASK32
        d.i_dispatch_predicted_taken.value = 1 if kwargs.get("predicted_taken") else 0
        d.i_dispatch_predicted_target.value = (
            int(kwargs.get("predicted_target", 0)) & MASK32
        )
        d.i_dispatch_is_fp_mem.value = 1 if kwargs.get("is_fp_mem") else 0
        d.i_dispatch_mem_size.value = int(kwargs.get("mem_size", 0)) & 0x3
        d.i_dispatch_mem_signed.value = 1 if kwargs.get("mem_signed") else 0
        d.i_dispatch_csr_addr.value = int(kwargs.get("csr_addr", 0)) & 0xFFF
        d.i_dispatch_csr_imm.value = int(kwargs.get("csr_imm", 0)) & 0x1F

    def _clear_dispatch_flat(self) -> None:
        """Clear all individual dispatch ports to zero."""
        d = self.dut
        d.i_dispatch_valid.value = 0
        d.i_dispatch_rs_type.value = 0
        d.i_dispatch_rob_tag.value = 0
        d.i_dispatch_op.value = 0
        d.i_dispatch_src1_ready.value = 0
        d.i_dispatch_src1_tag.value = 0
        d.i_dispatch_src1_value.value = 0
        d.i_dispatch_src2_ready.value = 0
        d.i_dispatch_src2_tag.value = 0
        d.i_dispatch_src2_value.value = 0
        d.i_dispatch_src3_ready.value = 0
        d.i_dispatch_src3_tag.value = 0
        d.i_dispatch_src3_value.value = 0
        d.i_dispatch_imm.value = 0
        d.i_dispatch_use_imm.value = 0
        d.i_dispatch_rm.value = 0
        d.i_dispatch_branch_target.value = 0
        d.i_dispatch_predicted_taken.value = 0
        d.i_dispatch_predicted_target.value = 0
        d.i_dispatch_is_fp_mem.value = 0
        d.i_dispatch_mem_size.value = 0
        d.i_dispatch_mem_signed.value = 0
        d.i_dispatch_csr_addr.value = 0
        d.i_dispatch_csr_imm.value = 0

    # =========================================================================
    # CDB (84 bits — always packed, small enough for Icarus VPI)
    # =========================================================================

    def drive_cdb(self, tag: int, value: int = 0, **kwargs: Any) -> None:
        """Drive CDB broadcast."""
        self.dut.i_cdb.value = pack_cdb_broadcast(
            valid=True, tag=tag, value=value, **kwargs
        )

    def clear_cdb(self) -> None:
        """Clear CDB broadcast signals."""
        self.dut.i_cdb.value = 0

    # =========================================================================
    # Issue
    # =========================================================================

    def set_fu_ready(self, ready: bool = True) -> None:
        """Set functional unit ready signal."""
        self.dut.i_fu_ready.value = 1 if ready else 0

    def read_issue(self) -> dict:
        """Read and unpack the issue output."""
        if self._flat:
            return self._read_issue_flat()
        return unpack_rs_issue(int(self.dut.o_issue.value))

    def _read_issue_flat(self) -> dict:
        """Read individual issue ports (Icarus wrapper)."""
        d = self.dut
        return {
            "valid": bool(d.o_issue_valid.value),
            "rob_tag": int(d.o_issue_rob_tag.value),
            "op": int(d.o_issue_op.value),
            "src1_value": int(d.o_issue_src1_value.value),
            "src2_value": int(d.o_issue_src2_value.value),
            "src3_value": int(d.o_issue_src3_value.value),
            "imm": int(d.o_issue_imm.value),
            "use_imm": bool(d.o_issue_use_imm.value),
            "rm": int(d.o_issue_rm.value),
            "branch_target": int(d.o_issue_branch_target.value),
            "predicted_taken": bool(d.o_issue_predicted_taken.value),
            "predicted_target": int(d.o_issue_predicted_target.value),
            "is_fp_mem": bool(d.o_issue_is_fp_mem.value),
            "mem_size": int(d.o_issue_mem_size.value),
            "mem_signed": bool(d.o_issue_mem_signed.value),
            "csr_addr": int(d.o_issue_csr_addr.value),
            "csr_imm": int(d.o_issue_csr_imm.value),
        }

    @property
    def issue_valid(self) -> bool:
        """Return whether issue output is valid."""
        if self._flat:
            return bool(self.dut.o_issue_valid.value)
        return self.read_issue()["valid"]

    # =========================================================================
    # Flush
    # =========================================================================

    def drive_flush_all(self) -> None:
        """Assert flush_all signal."""
        self.dut.i_flush_all.value = 1

    def clear_flush_all(self) -> None:
        """Deassert flush_all signal."""
        self.dut.i_flush_all.value = 0

    def drive_partial_flush(self, flush_tag: int, head_tag: int) -> None:
        """Drive partial flush with tag and ROB head."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag & MASK_TAG
        self.dut.i_rob_head_tag.value = head_tag & MASK_TAG

    def clear_partial_flush(self) -> None:
        """Deassert partial flush enable."""
        self.dut.i_flush_en.value = 0

    # =========================================================================
    # Status
    # =========================================================================

    @property
    def full(self) -> bool:
        """Return whether RS is full."""
        return bool(self.dut.o_full.value)

    @property
    def empty(self) -> bool:
        """Return whether RS is empty."""
        return bool(self.dut.o_empty.value)

    @property
    def count(self) -> int:
        """Return number of valid entries."""
        return int(self.dut.o_count.value)

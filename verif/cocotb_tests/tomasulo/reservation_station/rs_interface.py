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

"""Typed RS DUT access and packed-struct conversion helpers.

Verilator flattens packed structs into bit vectors, so this interface packs
and unpacks their fields.
"""

from typing import Any
from cocotb.triggers import RisingEdge, FallingEdge
from config import FLEN, INSTR_OP_WIDTH, MASK_XLEN, XLEN

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1  # 0x1F
MASK64 = (1 << FLEN) - 1

# instr_op_e: explicit 8-bit, two-state unsigned enum in riscv_pkg
OP_WIDTH = INSTR_OP_WIDTH
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

# checkpoint_id_t: NumCheckpoints=8 -> 3 bits
CHECKPOINT_ID_WIDTH = 3


# =============================================================================
# Struct Packing/Unpacking
# =============================================================================
# SystemVerilog packed structs are MSB-first (first field at highest bits),
# so packing walks from LSB to MSB in reverse declaration order.


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
    jalr_imm: int = 0,
    rm: int = 0,
    predicted_taken: bool = False,
    predicted_target: int = 0,
    predicted_target_ok: bool = False,
    is_compressed: bool = False,
    is_fp_mem: bool = False,
    mem_needs_lq: bool = False,
    mem_needs_sq: bool = False,
    mem_size: int = 0,
    mem_signed: bool = False,
    csr_addr: int = 0,
    csr_imm: int = 0,
    pc: int = 0,
    link_addr: int = 0,
    has_checkpoint: bool = False,
    checkpoint_id: int = 0,
    is_call: bool = False,
    is_return: bool = False,
) -> int:
    """Pack dispatch fields into a bit vector for driving i_dispatch."""
    val = 0
    bit = 0

    # Pack from LSB to MSB (reverse of struct declaration order)
    val |= (1 if is_return else 0) << bit
    bit += 1
    val |= (1 if is_call else 0) << bit
    bit += 1
    val |= (checkpoint_id & ((1 << CHECKPOINT_ID_WIDTH) - 1)) << bit
    bit += CHECKPOINT_ID_WIDTH
    val |= (1 if has_checkpoint else 0) << bit
    bit += 1
    val |= (link_addr & MASK_XLEN) << bit
    bit += XLEN
    val |= (pc & MASK_XLEN) << bit
    bit += XLEN
    val |= (csr_imm & 0x1F) << bit
    bit += 5
    val |= (csr_addr & 0xFFF) << bit
    bit += 12
    val |= (1 if mem_signed else 0) << bit
    bit += 1
    val |= (mem_size & 0x3) << bit
    bit += MEM_SIZE_WIDTH
    val |= (1 if mem_needs_sq else 0) << bit
    bit += 1
    val |= (1 if mem_needs_lq else 0) << bit
    bit += 1
    val |= (1 if is_fp_mem else 0) << bit
    bit += 1
    val |= (1 if is_compressed else 0) << bit
    bit += 1
    val |= (1 if predicted_target_ok else 0) << bit
    bit += 1
    val |= (predicted_target & MASK_XLEN) << bit
    bit += XLEN
    val |= (1 if predicted_taken else 0) << bit
    bit += 1
    val |= (rm & 0x7) << bit
    bit += 3
    val |= (jalr_imm & 0xFFF) << bit
    bit += 12
    val |= (1 if use_imm else 0) << bit
    bit += 1
    val |= (imm & MASK_XLEN) << bit
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


def unpack_rs_issue(raw: int) -> dict[str, int | bool]:
    """Unpack rs_issue_t from a bit vector."""
    bit = 0
    result: dict[str, int | bool] = {}

    # Pre-decoded branch class fields (LSB end of the struct)
    result["branch_op"] = (raw >> bit) & 0x7
    bit += 3
    result["is_jalr"] = bool((raw >> bit) & 1)
    bit += 1
    result["is_jal"] = bool((raw >> bit) & 1)
    bit += 1
    result["is_branch_class"] = bool((raw >> bit) & 1)
    bit += 1
    result["is_return"] = bool((raw >> bit) & 1)
    bit += 1
    result["is_call"] = bool((raw >> bit) & 1)
    bit += 1
    result["checkpoint_id"] = (raw >> bit) & ((1 << CHECKPOINT_ID_WIDTH) - 1)
    bit += CHECKPOINT_ID_WIDTH
    result["has_checkpoint"] = bool((raw >> bit) & 1)
    bit += 1
    result["link_addr"] = (raw >> bit) & MASK_XLEN
    bit += XLEN
    result["pc"] = (raw >> bit) & MASK_XLEN
    bit += XLEN
    result["csr_imm"] = (raw >> bit) & 0x1F
    bit += 5
    result["csr_addr"] = (raw >> bit) & 0xFFF
    bit += 12
    result["mem_signed"] = bool((raw >> bit) & 1)
    bit += 1
    result["mem_size"] = (raw >> bit) & 0x3
    bit += MEM_SIZE_WIDTH
    result["mem_needs_sq"] = bool((raw >> bit) & 1)
    bit += 1
    result["mem_needs_lq"] = bool((raw >> bit) & 1)
    bit += 1
    result["is_fp_mem"] = bool((raw >> bit) & 1)
    bit += 1
    result["is_compressed"] = bool((raw >> bit) & 1)
    bit += 1
    result["predicted_target_ok"] = bool((raw >> bit) & 1)
    bit += 1
    result["predicted_target"] = (raw >> bit) & MASK_XLEN
    bit += XLEN
    result["predicted_taken"] = bool((raw >> bit) & 1)
    bit += 1
    result["rm"] = (raw >> bit) & 0x7
    bit += 3
    result["jalr_imm"] = (raw >> bit) & 0xFFF
    bit += 12
    result["use_imm"] = bool((raw >> bit) & 1)
    bit += 1
    result["imm"] = (raw >> bit) & MASK_XLEN
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
    """Interface to the Reservation Station DUT."""

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

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
        self.dut.i_dispatch.value = 0
        # Slot-2 dispatch port; tests drive it through drive_dispatch_2.
        self.dut.i_dispatch_2.value = 0
        # Fast slot-1 intent. The RTL selects alloc_idx_2 from it regardless
        # of SPECULATIVE_DATA_WRITES, so drive_dispatch raises it together
        # with i_dispatch.
        self.dut.i_intent_1.value = 0
        self.dut.i_cdb.value = 0
        self.dut.i_cdb_2.value = 0
        self.dut.i_repair_valid_1.value = 0
        self.dut.i_repair_tag_1.value = 0
        self.dut.i_repair_value_1.value = 0
        self.dut.i_repair_valid_2.value = 0
        self.dut.i_repair_tag_2.value = 0
        self.dut.i_repair_value_2.value = 0
        self.dut.i_repair_valid_3.value = 0
        self.dut.i_repair_tag_3.value = 0
        self.dut.i_repair_value_3.value = 0
        self.dut.i_repair_valid_4.value = 0
        self.dut.i_repair_tag_4.value = 0
        self.dut.i_repair_value_4.value = 0
        self.dut.i_repair_valid_5.value = 0
        self.dut.i_repair_tag_5.value = 0
        self.dut.i_repair_value_5.value = 0
        self.dut.i_repair_valid_6.value = 0
        self.dut.i_repair_tag_6.value = 0
        self.dut.i_repair_value_6.value = 0
        self.dut.i_fu_ready.value = 0
        self.dut.i_fu_ready_2.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_rob_head_tag.value = 0
        self.dut.i_flush_all.value = 0
        self.dut.i_head_query_tag.value = 0

    # =========================================================================
    # Dispatch
    # =========================================================================

    def drive_dispatch(self, **kwargs: Any) -> None:
        """Drive dispatch signals. Pass keyword args matching pack_rs_dispatch."""
        kwargs["valid"] = True
        # The wrapper raises the fast slot-1 intent from the same per-RS
        # decode that drives i_dispatch.valid, so the bench does the same.
        # While it is high the RTL steers a simultaneous slot-2 dispatch to
        # the second free entry.
        self.set_intent_1(True)
        self.dut.i_dispatch.value = pack_rs_dispatch(**kwargs)

    def clear_dispatch(self) -> None:
        """Clear dispatch signals."""
        self.set_intent_1(False)
        self.dut.i_dispatch.value = 0

    def drive_dispatch_2(self, intent_1: bool = False, **kwargs: Any) -> None:
        """Drive slot-2 dispatch signals."""
        kwargs["valid"] = True
        self.dut.i_dispatch_2.value = pack_rs_dispatch(**kwargs)
        self.set_intent_1(intent_1)

    def clear_dispatch_2(self) -> None:
        """Clear slot-2 dispatch and slot-1 intent."""
        self.dut.i_dispatch_2.value = 0
        self.set_intent_1(False)

    def set_intent_1(self, active: bool = True) -> None:
        """Drive fast slot-1 intent used by slot-2 allocation selection."""
        self.dut.i_intent_1.value = 1 if active else 0

    # =========================================================================
    # CDB (84 bits)
    # =========================================================================

    def drive_cdb(self, tag: int, value: int = 0, **kwargs: Any) -> None:
        """Drive CDB broadcast."""
        self.dut.i_cdb.value = pack_cdb_broadcast(
            valid=True, tag=tag, value=value, **kwargs
        )

    def clear_cdb(self) -> None:
        """Clear CDB broadcast signals."""
        self.dut.i_cdb.value = 0

    def drive_cdb_2(self, tag: int, value: int = 0, **kwargs: Any) -> None:
        """Drive lane 1 of the two-wide CDB."""
        self.dut.i_cdb_2.value = pack_cdb_broadcast(
            valid=True, tag=tag, value=value, **kwargs
        )

    def clear_cdb_2(self) -> None:
        """Clear lane 1 of the two-wide CDB."""
        self.dut.i_cdb_2.value = 0

    # =========================================================================
    # Registered done-repair responses
    # =========================================================================

    def drive_repair(self, channel: int, tag: int, value: int) -> None:
        """Drive one of the six done-repair response channels."""
        if channel not in range(1, 7):
            raise ValueError(f"repair channel must be 1..6, got {channel}")
        getattr(self.dut, f"i_repair_valid_{channel}").value = 1
        getattr(self.dut, f"i_repair_tag_{channel}").value = tag & MASK_TAG
        getattr(self.dut, f"i_repair_value_{channel}").value = value & MASK64

    def clear_repairs(self) -> None:
        """Clear all done-repair response channels."""
        for channel in range(1, 7):
            getattr(self.dut, f"i_repair_valid_{channel}").value = 0
            getattr(self.dut, f"i_repair_tag_{channel}").value = 0
            getattr(self.dut, f"i_repair_value_{channel}").value = 0

    # =========================================================================
    # Issue
    # =========================================================================

    def set_fu_ready(self, ready: bool = True) -> None:
        """Set functional unit ready signal."""
        self.dut.i_fu_ready.value = 1 if ready else 0

    def read_issue(self) -> dict:
        """Read and unpack the issue output."""
        return unpack_rs_issue(int(self.dut.o_issue.value))

    @property
    def issue_valid(self) -> bool:
        """Return whether issue output is valid."""
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
    def full_for_2(self) -> bool:
        """Return whether there is not enough room for a 2-wide dispatch."""
        return bool(self.dut.o_full_for_2.value)

    @property
    def empty(self) -> bool:
        """Return whether RS is empty."""
        return bool(self.dut.o_empty.value)

    @property
    def count(self) -> int:
        """Return number of valid entries."""
        return int(self.dut.o_count.value)

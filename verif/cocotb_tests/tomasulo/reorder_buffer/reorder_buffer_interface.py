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

"""DUT interface for Reorder Buffer verification.

Provides clean access to Reorder Buffer signals with proper typing and
helper methods for driving stimulus and reading outputs.

Note: Verilator flattens packed structs into single bit vectors.
This interface handles packing/unpacking struct fields automatically.
"""

from typing import Any
from cocotb.triggers import RisingEdge, FallingEdge

from .reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
    MASK32,
    MASK64,
)


# =============================================================================
# Struct Bit Field Definitions
# =============================================================================
# These define the bit positions for fields in packed structs.
# SystemVerilog packed structs are MSB-first (first field is at highest bits).

# reorder_buffer_alloc_req_t field positions (118 bits total, MSB to LSB):
# [117]    alloc_valid
# [116:85] pc (32 bits)
# [84]     dest_rf
# [83:79]  dest_reg (5 bits)
# [78]     dest_valid
# [77]     is_store
# [76]     is_fp_store
# [75]     is_branch
# [74]     predicted_taken
# [73:42]  predicted_target (32 bits)
# [41]     is_call
# [40]     is_return
# [39:8]   link_addr (32 bits)
# [7]      is_jal
# [6]      is_jalr
# [5]      is_csr
# [4]      is_fence
# [3]      is_fence_i
# [2]      is_wfi
# [1]      is_mret
# [0]      is_amo
# Note: is_lr and is_sc are below bit 0, need to recalculate

# Let me recalculate total width:
# 1 + 32 + 1 + 5 + 1 + 1 + 1 + 1 + 1 + 32 + 1 + 1 + 32 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 = 120 bits
ALLOC_REQ_WIDTH = 120


def pack_alloc_request(req: AllocationRequest) -> int:
    """Pack AllocationRequest into a bit vector for driving i_alloc_req.

    The struct fields are packed MSB-first per SystemVerilog semantics.
    """
    val = 0
    bit = 0  # Start from LSB

    # Pack from LSB to MSB (reverse order of struct declaration)
    val |= (1 if req.is_sc else 0) << bit
    bit += 1
    val |= (1 if req.is_lr else 0) << bit
    bit += 1
    val |= (1 if req.is_amo else 0) << bit
    bit += 1
    val |= (1 if req.is_mret else 0) << bit
    bit += 1
    val |= (1 if req.is_wfi else 0) << bit
    bit += 1
    val |= (1 if req.is_fence_i else 0) << bit
    bit += 1
    val |= (1 if req.is_fence else 0) << bit
    bit += 1
    val |= (1 if req.is_csr else 0) << bit
    bit += 1
    val |= (1 if req.is_jalr else 0) << bit
    bit += 1
    val |= (1 if req.is_jal else 0) << bit
    bit += 1
    val |= (req.link_addr & MASK32) << bit
    bit += 32
    val |= (1 if req.is_return else 0) << bit
    bit += 1
    val |= (1 if req.is_call else 0) << bit
    bit += 1
    val |= (req.predicted_target & MASK32) << bit
    bit += 32
    val |= (1 if req.predicted_taken else 0) << bit
    bit += 1
    val |= (1 if req.is_branch else 0) << bit
    bit += 1
    val |= (1 if req.is_fp_store else 0) << bit
    bit += 1
    val |= (1 if req.is_store else 0) << bit
    bit += 1
    val |= (1 if req.dest_valid else 0) << bit
    bit += 1
    val |= (req.dest_reg & 0x1F) << bit
    bit += 5
    val |= (req.dest_rf & 1) << bit
    bit += 1
    val |= (req.pc & MASK32) << bit
    bit += 32
    val |= 1 << bit  # alloc_valid = 1

    return val


def pack_alloc_request_invalid() -> int:
    """Pack an invalid allocation request (alloc_valid = 0)."""
    return 0


# reorder_buffer_alloc_resp_t (7 bits total):
# [6]   alloc_ready
# [5:1] alloc_tag (5 bits)
# [0]   full
ALLOC_RESP_WIDTH = 7


def unpack_alloc_response(val: int) -> tuple[bool, int, bool]:
    """Unpack allocation response.

    Returns: (alloc_ready, alloc_tag, full)
    """
    full = bool(val & 1)
    alloc_tag = (val >> 1) & 0x1F
    alloc_ready = bool((val >> 6) & 1)
    return alloc_ready, alloc_tag, full


# reorder_buffer_cdb_write_t:
# valid (1) + tag (5) + value (64) + exception (1) + exc_cause (5) + fp_flags (5) = 81 bits
CDB_WRITE_WIDTH = 81


def pack_cdb_write(write: CDBWrite) -> int:
    """Pack CDBWrite into a bit vector."""
    val = 0
    bit = 0

    val |= (write.fp_flags & 0x1F) << bit
    bit += 5
    val |= (write.exc_cause & 0x1F) << bit
    bit += 5
    val |= (1 if write.exception else 0) << bit
    bit += 1
    val |= (write.value & MASK64) << bit
    bit += 64
    val |= (write.tag & 0x1F) << bit
    bit += 5
    val |= 1 << bit  # valid = 1

    return val


def pack_cdb_write_invalid() -> int:
    """Pack an invalid CDB write (valid = 0)."""
    return 0


# reorder_buffer_branch_update_t:
# valid (1) + tag (5) + taken (1) + target (32) + mispredicted (1) = 40 bits
BRANCH_UPDATE_WIDTH = 40


def pack_branch_update(update: BranchUpdate) -> int:
    """Pack BranchUpdate into a bit vector."""
    val = 0
    bit = 0

    val |= (1 if update.mispredicted else 0) << bit
    bit += 1
    val |= (update.target & MASK32) << bit
    bit += 32
    val |= (1 if update.taken else 0) << bit
    bit += 1
    val |= (update.tag & 0x1F) << bit
    bit += 5
    val |= 1 << bit  # valid = 1

    return val


def pack_branch_update_invalid() -> int:
    """Pack an invalid branch update (valid = 0)."""
    return 0


# reorder_buffer_commit_t (unpacking for reads):
# See tomasulo_pkg.sv for field order
# Total approximately 200+ bits
def unpack_commit(val: int) -> dict[str, Any]:
    """Unpack commit output into a dictionary."""
    bit = 0
    result: dict[str, Any] = {}

    result["is_sc"] = bool((val >> bit) & 1)
    bit += 1
    result["is_lr"] = bool((val >> bit) & 1)
    bit += 1
    result["is_amo"] = bool((val >> bit) & 1)
    bit += 1
    result["is_mret"] = bool((val >> bit) & 1)
    bit += 1
    result["is_wfi"] = bool((val >> bit) & 1)
    bit += 1
    result["is_fence_i"] = bool((val >> bit) & 1)
    bit += 1
    result["is_fence"] = bool((val >> bit) & 1)
    bit += 1
    result["is_csr"] = bool((val >> bit) & 1)
    bit += 1
    result["redirect_pc"] = (val >> bit) & MASK32
    bit += 32
    result["checkpoint_id"] = (val >> bit) & 0x3
    bit += 2
    result["has_checkpoint"] = bool((val >> bit) & 1)
    bit += 1
    result["misprediction"] = bool((val >> bit) & 1)
    bit += 1
    result["fp_flags"] = (val >> bit) & 0x1F
    bit += 5
    result["exc_cause"] = (val >> bit) & 0x1F
    bit += 5
    result["pc"] = (val >> bit) & MASK32
    bit += 32
    result["exception"] = bool((val >> bit) & 1)
    bit += 1
    result["is_fp_store"] = bool((val >> bit) & 1)
    bit += 1
    result["is_store"] = bool((val >> bit) & 1)
    bit += 1
    result["value"] = (val >> bit) & MASK64
    bit += 64
    result["dest_valid"] = bool((val >> bit) & 1)
    bit += 1
    result["dest_reg"] = (val >> bit) & 0x1F
    bit += 5
    result["dest_rf"] = (val >> bit) & 1
    bit += 1
    result["tag"] = (val >> bit) & 0x1F
    bit += 5
    result["valid"] = bool((val >> bit) & 1)

    return result


class ReorderBufferInterface:
    """Interface to Reorder Buffer DUT.

    Handles packing/unpacking of struct signals automatically since
    Verilator flattens packed structs into single bit vectors.
    """

    def __init__(self, dut: Any):
        """Initialize interface with DUT handle."""
        self.dut = dut

    # =========================================================================
    # Clock and Reset
    # =========================================================================

    @property
    def clock(self) -> Any:
        """Clock signal."""
        return self.dut.i_clk

    @property
    def reset_n(self) -> Any:
        """Active-low reset signal."""
        return self.dut.i_rst_n

    async def reset_dut(self, cycles: int = 5) -> None:
        """Reset the DUT.

        After reset completes, returns at a falling edge so that signals
        driven immediately after reset will be stable before the next rising edge.
        """
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        # Return at falling edge so signals set after reset are stable for next rising edge
        await FallingEdge(self.clock)

    async def wait_falling(self) -> None:
        """Wait for falling edge - use this before driving inputs."""
        await FallingEdge(self.clock)

    async def wait_rising(self) -> None:
        """Wait for rising edge - use this before sampling outputs."""
        await RisingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: wait for rising edge (sample outputs), then falling (drive inputs).

        Typical pattern:
            # After reset, we're at falling edge
            drive_inputs()        # Drive on falling edge
            await dut_if.step()   # Rising edge (state updates) + falling edge
            sample_outputs()      # Can sample now (after rising edge updated state)
            drive_inputs()        # Drive for next cycle
        """
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _init_inputs(self) -> None:
        """Initialize all input signals to default values."""
        self.dut.i_alloc_req.value = 0
        self.dut.i_cdb_write.value = 0
        self.dut.i_branch_update.value = 0
        self.dut.i_checkpoint_valid.value = 0
        self.dut.i_checkpoint_id.value = 0
        self.dut.i_sq_empty.value = 1
        self.dut.i_csr_done.value = 0
        self.dut.i_trap_taken.value = 0
        self.dut.i_mret_done.value = 0
        self.dut.i_mepc.value = 0
        self.dut.i_interrupt_pending.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_flush_all.value = 0
        self.dut.i_read_tag.value = 0

    # =========================================================================
    # Allocation Interface
    # =========================================================================

    def drive_alloc_request(self, req: AllocationRequest) -> None:
        """Drive allocation request signals. Call on falling edge."""
        val = pack_alloc_request(req)
        self.dut.i_alloc_req.value = val

    def clear_alloc_request(self) -> None:
        """Clear allocation request."""
        self.dut.i_alloc_req.value = 0

    def read_alloc_response(self) -> tuple[bool, int, bool]:
        """Read allocation response. Returns (ready, tag, full). Call after rising edge."""
        val = int(self.dut.o_alloc_resp.value)
        return unpack_alloc_response(val)

    async def allocate(self, req: AllocationRequest) -> int | None:
        """Perform allocation transaction.

        Drive on falling edge, wait for rising edge (allocation happens), then clear.
        Returns allocated tag or None if full.
        """
        await FallingEdge(self.clock)
        self.drive_alloc_request(req)
        await RisingEdge(self.clock)
        ready, tag, full = self.read_alloc_response()
        await FallingEdge(self.clock)
        self.clear_alloc_request()
        if ready and not full:
            return tag
        return None

    # =========================================================================
    # CDB Write Interface
    # =========================================================================

    def drive_cdb_write(self, write: CDBWrite) -> None:
        """Drive CDB write signals. Call on falling edge."""
        self.dut.i_cdb_write.value = pack_cdb_write(write)

    def clear_cdb_write(self) -> None:
        """Clear CDB write."""
        self.dut.i_cdb_write.value = 0

    async def cdb_write(self, write: CDBWrite) -> None:
        """Perform CDB write transaction."""
        await FallingEdge(self.clock)
        self.drive_cdb_write(write)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_cdb_write()

    # =========================================================================
    # Branch Update Interface
    # =========================================================================

    def drive_branch_update(self, update: BranchUpdate) -> None:
        """Drive branch update signals. Call on falling edge."""
        self.dut.i_branch_update.value = pack_branch_update(update)

    def clear_branch_update(self) -> None:
        """Clear branch update."""
        self.dut.i_branch_update.value = 0

    async def branch_update(self, update: BranchUpdate) -> None:
        """Perform branch update transaction."""
        await FallingEdge(self.clock)
        self.drive_branch_update(update)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_branch_update()

    # =========================================================================
    # Checkpoint Interface
    # =========================================================================

    def drive_checkpoint(self, checkpoint_id: int) -> None:
        """Drive checkpoint assignment signals."""
        self.dut.i_checkpoint_valid.value = 1
        self.dut.i_checkpoint_id.value = checkpoint_id

    def clear_checkpoint(self) -> None:
        """Clear checkpoint signals."""
        self.dut.i_checkpoint_valid.value = 0

    # =========================================================================
    # Commit Output Interface
    # =========================================================================

    def read_commit(self) -> dict:
        """Read commit output signals."""
        val = int(self.dut.o_commit.value)
        return unpack_commit(val)

    @property
    def commit_valid(self) -> bool:
        """Check if commit is valid this cycle."""
        commit = self.read_commit()
        return commit["valid"]

    # =========================================================================
    # External Coordination Signals
    # =========================================================================

    def set_sq_empty(self, empty: bool) -> None:
        """Set store queue empty signal."""
        self.dut.i_sq_empty.value = 1 if empty else 0

    def set_csr_done(self, done: bool) -> None:
        """Set CSR operation done signal."""
        self.dut.i_csr_done.value = 1 if done else 0

    def set_trap_taken(self, taken: bool) -> None:
        """Set trap taken acknowledgement signal."""
        self.dut.i_trap_taken.value = 1 if taken else 0

    def set_mret_done(self, done: bool) -> None:
        """Set MRET done signal."""
        self.dut.i_mret_done.value = 1 if done else 0

    def set_mepc(self, mepc: int) -> None:
        """Set MEPC value for MRET."""
        self.dut.i_mepc.value = mepc & MASK32

    def set_interrupt_pending(self, pending: bool) -> None:
        """Set interrupt pending signal for WFI."""
        self.dut.i_interrupt_pending.value = 1 if pending else 0

    @property
    def csr_start(self) -> bool:
        """CSR operation start signal."""
        return bool(self.dut.o_csr_start.value)

    @property
    def trap_pending(self) -> bool:
        """Trap pending output signal."""
        return bool(self.dut.o_trap_pending.value)

    @property
    def trap_pc(self) -> int:
        """Trap PC output."""
        return int(self.dut.o_trap_pc.value)

    @property
    def trap_cause(self) -> int:
        """Trap cause output."""
        return int(self.dut.o_trap_cause.value)

    @property
    def mret_start(self) -> bool:
        """MRET start signal."""
        return bool(self.dut.o_mret_start.value)

    @property
    def fence_i_flush(self) -> bool:
        """FENCE.I flush signal."""
        return bool(self.dut.o_fence_i_flush.value)

    # =========================================================================
    # Flush Interface
    # =========================================================================

    def drive_partial_flush(self, flush_tag: int) -> None:
        """Drive partial flush signals."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag

    def clear_partial_flush(self) -> None:
        """Clear partial flush enable."""
        self.dut.i_flush_en.value = 0

    async def partial_flush(self, flush_tag: int) -> None:
        """Perform partial flush and wait for completion."""
        await FallingEdge(self.clock)
        self.drive_partial_flush(flush_tag)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_partial_flush()

    def drive_full_flush(self) -> None:
        """Drive full flush signal."""
        self.dut.i_flush_all.value = 1

    def clear_full_flush(self) -> None:
        """Clear full flush signal."""
        self.dut.i_flush_all.value = 0

    async def full_flush(self) -> None:
        """Perform full flush and wait for completion."""
        await FallingEdge(self.clock)
        self.drive_full_flush()
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_full_flush()

    # =========================================================================
    # Status Signals
    # =========================================================================

    @property
    def full(self) -> bool:
        """Return True if buffer is full."""
        return bool(self.dut.o_full.value)

    @property
    def empty(self) -> bool:
        """Return True if buffer is empty."""
        return bool(self.dut.o_empty.value)

    @property
    def count(self) -> int:
        """Return number of entries in buffer."""
        return int(self.dut.o_count.value)

    @property
    def head_tag(self) -> int:
        """Return tag of head entry."""
        return int(self.dut.o_head_tag.value)

    @property
    def head_valid(self) -> bool:
        """Return True if head entry is valid."""
        return bool(self.dut.o_head_valid.value)

    @property
    def head_done(self) -> bool:
        """Return True if head entry is done."""
        return bool(self.dut.o_head_done.value)

    @property
    def head_ptr(self) -> int:
        """Return head pointer (with wrap bit) via debug signal."""
        return int(self.dut.dbg_head_ptr.value)

    @property
    def tail_ptr(self) -> int:
        """Return tail pointer (with wrap bit) via debug signal."""
        return int(self.dut.dbg_tail_ptr.value)

    # =========================================================================
    # Entry Read Interface
    # =========================================================================

    def set_read_tag(self, tag: int) -> None:
        """Set the tag for entry reads. Call on falling edge."""
        self.dut.i_read_tag.value = tag

    def read_entry_done(self) -> bool:
        """Read entry done status. Call after setting tag and rising edge."""
        return bool(self.dut.o_read_done.value)

    def read_entry_value(self) -> int:
        """Read entry value. Call after setting tag and rising edge."""
        return int(self.dut.o_read_value.value)

    async def read_entry(self, tag: int) -> tuple[bool, int]:
        """Read entry done status and value.

        Sets the read tag on falling edge, waits for rising edge, then reads.
        """
        await FallingEdge(self.clock)
        self.set_read_tag(tag)
        await RisingEdge(self.clock)
        done = self.read_entry_done()
        value = self.read_entry_value()
        return done, value

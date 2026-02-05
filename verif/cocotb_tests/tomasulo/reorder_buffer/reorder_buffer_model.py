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

"""Python model of the Reorder Buffer for verification.

This module provides a software model that mirrors the RTL behavior of the
Reorder Buffer. It tracks:
- Entry allocation and deallocation
- Head and tail pointers
- CDB writes marking entries as done
- Branch updates and misprediction
- Commit sequencing
- Serializing instruction state

The model is used to generate expected outputs that monitors compare against
actual DUT behavior.
"""

from dataclasses import dataclass
from enum import Enum, auto
from collections import deque

# Match RTL parameters
REORDER_BUFFER_DEPTH = 32
REORDER_BUFFER_TAG_WIDTH = 5  # $clog2(32)
XLEN = 32
FLEN = 64
MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1


class SerialState(Enum):
    """Serializing instruction state machine states."""

    IDLE = auto()
    WAIT_SQ = auto()  # Waiting for store queue to drain (FENCE, AMO)
    CSR_EXEC = auto()  # Waiting for CSR execution
    MRET_EXEC = auto()  # Waiting for MRET completion
    WFI_WAIT = auto()  # Waiting for interrupt (WFI)
    TRAP_WAIT = auto()  # Waiting for trap handling


@dataclass
class ReorderBufferEntry:
    """Model of a single Reorder Buffer entry.

    Mirrors the reorder_buffer_entry_t structure from tomasulo_pkg.sv.
    """

    # Core fields
    valid: bool = False
    done: bool = False
    exception: bool = False
    exc_cause: int = 0

    # Instruction identification
    pc: int = 0

    # Destination register
    dest_rf: int = 0  # 0=INT, 1=FP
    dest_reg: int = 0  # rd
    dest_valid: bool = False

    # Result value
    value: int = 0  # FLEN-wide

    # Store tracking
    is_store: bool = False
    is_fp_store: bool = False

    # Branch tracking
    is_branch: bool = False
    branch_taken: bool = False
    branch_target: int = 0
    predicted_taken: bool = False
    predicted_target: int = 0
    mispredicted: bool = False  # Authoritative misprediction flag from branch unit
    is_call: bool = False
    is_return: bool = False
    is_jal: bool = False
    is_jalr: bool = False

    # Checkpoint
    has_checkpoint: bool = False
    checkpoint_id: int = 0

    # FP flags
    fp_flags: int = 0

    # Serializing instruction flags
    is_csr: bool = False
    is_fence: bool = False
    is_fence_i: bool = False
    is_wfi: bool = False
    is_mret: bool = False
    is_amo: bool = False
    is_lr: bool = False
    is_sc: bool = False


@dataclass
class AllocationRequest:
    """Allocation request from dispatch."""

    pc: int = 0
    dest_rf: int = 0
    dest_reg: int = 0
    dest_valid: bool = False
    is_store: bool = False
    is_fp_store: bool = False
    is_branch: bool = False
    predicted_taken: bool = False
    predicted_target: int = 0
    is_call: bool = False
    is_return: bool = False
    link_addr: int = 0
    is_jal: bool = False
    is_jalr: bool = False
    is_csr: bool = False
    is_fence: bool = False
    is_fence_i: bool = False
    is_wfi: bool = False
    is_mret: bool = False
    is_amo: bool = False
    is_lr: bool = False
    is_sc: bool = False


@dataclass
class CDBWrite:
    """CDB write to mark entry done."""

    tag: int
    value: int
    exception: bool = False
    exc_cause: int = 0
    fp_flags: int = 0


@dataclass
class BranchUpdate:
    """Branch resolution update."""

    tag: int
    taken: bool
    target: int
    mispredicted: bool = False


@dataclass
class ExpectedCommit:
    """Expected commit output for verification."""

    valid: bool = True
    tag: int = 0
    dest_rf: int = 0
    dest_reg: int = 0
    dest_valid: bool = False
    value: int = 0
    is_store: bool = False
    is_fp_store: bool = False
    exception: bool = False
    pc: int = 0
    exc_cause: int = 0
    fp_flags: int = 0
    misprediction: bool = False
    has_checkpoint: bool = False
    checkpoint_id: int = 0
    redirect_pc: int = 0
    is_csr: bool = False
    is_fence: bool = False
    is_fence_i: bool = False
    is_wfi: bool = False
    is_mret: bool = False
    is_amo: bool = False
    is_lr: bool = False
    is_sc: bool = False


class ReorderBufferModel:
    """Software model of the Reorder Buffer.

    This model tracks the expected state of the Reorder Buffer and generates
    expected outputs for monitor verification. It models:

    - Circular buffer with head/tail pointers
    - Entry allocation and deallocation
    - CDB writes marking entries done
    - Branch updates and misprediction detection
    - In-order commit sequencing
    - Serializing instruction handling
    - Flush behavior (partial and full)

    Usage:
        model = ReorderBufferModel()

        # Allocate entry
        tag = model.allocate(request)

        # Mark done via CDB
        model.cdb_write(CDBWrite(tag=tag, value=result))

        # Check for commit
        if model.can_commit():
            expected = model.commit()
            # Compare with DUT output
    """

    def __init__(self, depth: int = REORDER_BUFFER_DEPTH):
        """Initialize reorder buffer model with given depth."""
        self.depth = depth
        self.tag_mask = depth - 1

        # Entry storage
        self.entries: list[ReorderBufferEntry] = [
            ReorderBufferEntry() for _ in range(depth)
        ]

        # Pointers (with wrap bit for full/empty detection)
        self.head_ptr: int = 0
        self.tail_ptr: int = 0

        # Serializing state
        self.serial_state: SerialState = SerialState.IDLE

        # External coordination (inputs to model)
        self.sq_empty: bool = True
        self.csr_done: bool = False
        self.mret_done: bool = False
        self.trap_taken: bool = False
        self.interrupt_pending: bool = False
        self.mepc: int = 0

        # Expected output queues
        self.expected_commits: deque[ExpectedCommit] = deque()
        self.expected_alloc_responses: deque[tuple[bool, int]] = deque()  # (ready, tag)

        # Statistics
        self.total_allocations: int = 0
        self.total_commits: int = 0
        self.total_flushes: int = 0
        self.mispredictions: int = 0

    # =========================================================================
    # Pointer and Status Properties
    # =========================================================================

    @property
    def head_idx(self) -> int:
        """Head index (without wrap bit)."""
        return self.head_ptr & self.tag_mask

    @property
    def tail_idx(self) -> int:
        """Tail index (without wrap bit)."""
        return self.tail_ptr & self.tag_mask

    @property
    def full(self) -> bool:
        """Check if buffer is full."""
        return (self.tail_ptr ^ self.head_ptr) == self.depth

    @property
    def empty(self) -> bool:
        """Check if buffer is empty."""
        return self.tail_ptr == self.head_ptr

    @property
    def count(self) -> int:
        """Number of valid entries."""
        if self.tail_ptr >= self.head_ptr:
            return self.tail_ptr - self.head_ptr
        else:
            return self.tail_ptr + 2 * self.depth - self.head_ptr

    @property
    def head_entry(self) -> ReorderBufferEntry:
        """Entry at head of buffer."""
        return self.entries[self.head_idx]

    # =========================================================================
    # Allocation
    # =========================================================================

    def can_allocate(self) -> bool:
        """Check if allocation is possible."""
        return not self.full

    def allocate(self, req: AllocationRequest) -> int | None:
        """Allocate a new entry.

        Returns the allocated tag, or None if full.
        """
        if self.full:
            self.expected_alloc_responses.append((False, 0))
            return None

        tag = self.tail_idx
        entry = self.entries[tag]

        # Initialize entry
        entry.valid = True
        entry.done = False
        entry.exception = False
        entry.exc_cause = 0
        entry.pc = req.pc & MASK32
        entry.dest_rf = req.dest_rf
        entry.dest_reg = req.dest_reg
        entry.dest_valid = req.dest_valid
        entry.value = 0
        entry.is_store = req.is_store
        entry.is_fp_store = req.is_fp_store
        entry.is_branch = req.is_branch
        entry.branch_taken = False
        entry.branch_target = 0
        entry.predicted_taken = req.predicted_taken
        entry.predicted_target = req.predicted_target & MASK32
        entry.mispredicted = False  # Set by branch_update
        entry.is_call = req.is_call
        entry.is_return = req.is_return
        entry.is_jal = req.is_jal
        entry.is_jalr = req.is_jalr
        entry.has_checkpoint = False
        entry.checkpoint_id = 0
        entry.fp_flags = 0
        entry.is_csr = req.is_csr
        entry.is_fence = req.is_fence
        entry.is_fence_i = req.is_fence_i
        entry.is_wfi = req.is_wfi
        entry.is_mret = req.is_mret
        entry.is_amo = req.is_amo
        entry.is_lr = req.is_lr
        entry.is_sc = req.is_sc

        # Handle JAL: done immediately, value is link address
        if req.is_jal:
            entry.done = True
            entry.value = req.link_addr & MASK64
        elif req.is_jalr:
            # JALR: value is link address but not done until branch resolves
            entry.value = req.link_addr & MASK64

        # Handle serializing instructions: mark done immediately at dispatch
        # (commit is gated by serialization logic)
        if req.is_wfi or req.is_fence or req.is_fence_i or req.is_mret:
            entry.done = True

        # Advance tail
        self.tail_ptr = (self.tail_ptr + 1) % (2 * self.depth)
        self.total_allocations += 1

        self.expected_alloc_responses.append((True, tag))
        return tag

    def set_checkpoint(self, tag: int, checkpoint_id: int) -> None:
        """Set checkpoint info for a branch entry."""
        if self.entries[tag].valid:
            self.entries[tag].has_checkpoint = True
            self.entries[tag].checkpoint_id = checkpoint_id

    # =========================================================================
    # CDB Write
    # =========================================================================

    def cdb_write(self, write: CDBWrite) -> None:
        """Handle CDB write to mark entry done."""
        entry = self.entries[write.tag & self.tag_mask]

        if not entry.valid:
            raise ValueError(f"CDB write to invalid entry {write.tag}")

        # Skip if already done (e.g., JAL)
        if entry.done:
            return

        entry.done = True
        entry.value = write.value & MASK64
        entry.exception = write.exception
        entry.exc_cause = write.exc_cause
        entry.fp_flags = write.fp_flags

    # =========================================================================
    # Branch Update
    # =========================================================================

    def branch_update(self, update: BranchUpdate) -> None:
        """Handle branch resolution update."""
        entry = self.entries[update.tag & self.tag_mask]

        if not entry.valid:
            raise ValueError(f"Branch update to invalid entry {update.tag}")

        if not entry.is_branch:
            raise ValueError(f"Branch update to non-branch entry {update.tag}")

        entry.branch_taken = update.taken
        entry.branch_target = update.target & MASK32
        entry.mispredicted = (
            update.mispredicted
        )  # Store authoritative flag from branch unit

        # Mark done (for conditional branches and JALR)
        # JAL is already done from allocation
        if not entry.is_jal:
            entry.done = True

        if update.mispredicted:
            self.mispredictions += 1

    # =========================================================================
    # Commit Logic
    # =========================================================================

    def _check_serial_stall(self) -> bool:
        """Check if head entry requires serialization stall.

        Returns True if commit should stall.
        """
        if self.empty:
            return False

        entry = self.head_entry
        if not entry.valid or not entry.done:
            return False

        # Handle serialization state machine
        if self.serial_state == SerialState.IDLE:
            if entry.exception:
                self.serial_state = SerialState.TRAP_WAIT
                return True
            elif entry.is_wfi:
                if not self.interrupt_pending:
                    self.serial_state = SerialState.WFI_WAIT
                    return True
            elif entry.is_csr:
                self.serial_state = SerialState.CSR_EXEC
                return True
            elif (
                entry.is_fence
                or entry.is_fence_i
                or entry.is_amo
                or entry.is_lr
                or entry.is_sc
            ):
                # FENCE, FENCE.I, AMO, LR, SC all require SQ to be empty
                if not self.sq_empty:
                    self.serial_state = SerialState.WAIT_SQ
                    return True
            elif entry.is_mret:
                self.serial_state = SerialState.MRET_EXEC
                return True

        elif self.serial_state == SerialState.WAIT_SQ:
            if not self.sq_empty:
                return True
            self.serial_state = SerialState.IDLE

        elif self.serial_state == SerialState.CSR_EXEC:
            if not self.csr_done:
                return True
            self.serial_state = SerialState.IDLE

        elif self.serial_state == SerialState.MRET_EXEC:
            if not self.mret_done:
                return True
            self.serial_state = SerialState.IDLE

        elif self.serial_state == SerialState.WFI_WAIT:
            if not self.interrupt_pending:
                return True
            self.serial_state = SerialState.IDLE

        elif self.serial_state == SerialState.TRAP_WAIT:
            if not self.trap_taken:
                return True
            self.serial_state = SerialState.IDLE

        return False

    def can_commit(self) -> bool:
        """Check if head entry can commit this cycle."""
        if self.empty:
            return False

        entry = self.head_entry
        if not entry.valid or not entry.done:
            return False

        return not self._check_serial_stall()

    def commit(self) -> ExpectedCommit:
        """Commit head entry and return expected output.

        Call only after can_commit() returns True.
        """
        if not self.can_commit():
            raise RuntimeError("Cannot commit - check can_commit() first")

        entry = self.head_entry

        # Detect misprediction
        # Use the authoritative misprediction flag from branch unit
        misprediction = entry.is_branch and entry.mispredicted
        redirect_pc = 0
        if misprediction:
            if entry.branch_taken:
                # Mispredicted as not-taken but actually taken -> go to taken target
                redirect_pc = entry.branch_target
            else:
                # Mispredicted as taken but actually not-taken -> go to pc+4
                redirect_pc = (entry.pc + 4) & MASK32

        # Build expected commit
        expected = ExpectedCommit(
            valid=True,
            tag=self.head_idx,
            dest_rf=entry.dest_rf,
            dest_reg=entry.dest_reg,
            dest_valid=entry.dest_valid,
            value=entry.value,
            is_store=entry.is_store,
            is_fp_store=entry.is_fp_store,
            exception=entry.exception,
            pc=entry.pc,
            exc_cause=entry.exc_cause,
            fp_flags=entry.fp_flags,
            misprediction=misprediction,
            has_checkpoint=entry.has_checkpoint,
            checkpoint_id=entry.checkpoint_id,
            redirect_pc=redirect_pc,
            is_csr=entry.is_csr,
            is_fence=entry.is_fence,
            is_fence_i=entry.is_fence_i,
            is_wfi=entry.is_wfi,
            is_mret=entry.is_mret,
            is_amo=entry.is_amo,
            is_lr=entry.is_lr,
            is_sc=entry.is_sc,
        )

        # Invalidate entry and advance head
        entry.valid = False
        self.head_ptr = (self.head_ptr + 1) % (2 * self.depth)
        self.total_commits += 1

        self.expected_commits.append(expected)
        return expected

    # =========================================================================
    # Flush
    # =========================================================================

    def flush_partial(self, flush_tag: int) -> int:
        """Partial flush: invalidate entries after flush_tag.

        Returns number of entries flushed.
        """
        flushed = 0

        # Invalidate entries from flush_tag+1 to tail
        idx = (flush_tag + 1) & self.tag_mask
        while idx != self.tail_idx:
            if self.entries[idx].valid:
                self.entries[idx].valid = False
                flushed += 1
            idx = (idx + 1) & self.tag_mask

        # Reset tail to flush_tag + 1 using age-based arithmetic
        # flush_age = flush_tag - head_idx (handles wrap correctly)
        # new_tail = head_ptr + flush_age + 1, wrapped to 2*depth
        flush_age = (flush_tag - self.head_idx) & self.tag_mask
        self.tail_ptr = (self.head_ptr + flush_age + 1) % (2 * self.depth)

        self.total_flushes += 1
        return flushed

    def flush_all(self) -> int:
        """Full flush: invalidate all entries.

        Returns number of entries flushed.
        """
        flushed = 0

        for entry in self.entries:
            if entry.valid:
                entry.valid = False
                flushed += 1

        # Reset tail to head
        self.tail_ptr = self.head_ptr
        self.serial_state = SerialState.IDLE

        self.total_flushes += 1
        return flushed

    # =========================================================================
    # Reset
    # =========================================================================

    def reset(self) -> None:
        """Reset model to initial state."""
        for entry in self.entries:
            entry.valid = False
            entry.done = False

        self.head_ptr = 0
        self.tail_ptr = 0
        self.serial_state = SerialState.IDLE

        self.expected_commits.clear()
        self.expected_alloc_responses.clear()

        self.total_allocations = 0
        self.total_commits = 0
        self.total_flushes = 0
        self.mispredictions = 0

    # =========================================================================
    # Debug
    # =========================================================================

    def dump_state(self) -> str:
        """Return string representation of current state."""
        lines = [
            "ReorderBufferModel State:",
            f"  head_ptr={self.head_ptr} (idx={self.head_idx})",
            f"  tail_ptr={self.tail_ptr} (idx={self.tail_idx})",
            f"  count={self.count}, full={self.full}, empty={self.empty}",
            f"  serial_state={self.serial_state.name}",
            "  Valid entries:",
        ]

        for i, entry in enumerate(self.entries):
            if entry.valid:
                lines.append(
                    f"    [{i}] pc={entry.pc:08x} rd={entry.dest_reg} "
                    f"done={entry.done} val={entry.value:016x}"
                )

        return "\n".join(lines)

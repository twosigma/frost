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

"""Golden model for the Store Queue.

Mirrors the RTL circular buffer, entry state machine, commit-ordered
memory writes, and FSD two-phase writes.
"""

from dataclasses import dataclass
from config import FLEN, XLEN

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
SQ_DEPTH = 8

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK32 = (1 << XLEN) - 1
MASK64 = (1 << FLEN) - 1

# mem_size_e values
MEM_SIZE_BYTE = 0
MEM_SIZE_HALF = 1
MEM_SIZE_WORD = 2
MEM_SIZE_DOUBLE = 3


@dataclass
class SQEntry:
    """One store queue entry."""

    valid: bool = False
    rob_tag: int = 0
    is_fp: bool = False
    addr_valid: bool = False
    address: int = 0
    data_valid: bool = False
    data: int = 0
    size: int = MEM_SIZE_WORD
    is_mmio: bool = False
    fp64_phase: int = 0
    committed: bool = False
    sent: bool = False
    is_sc: bool = False


@dataclass
class ForwardResult:
    """Store-to-load forwarding result."""

    match: bool = False
    can_forward: bool = False
    data: int = 0


@dataclass
class MemWriteReq:
    """Memory write request."""

    en: bool = False
    addr: int = 0
    data: int = 0
    byte_en: int = 0


def is_younger(entry_tag: int, flush_tag: int, head: int) -> bool:
    """Check if entry_tag is younger than flush_tag relative to head."""
    mask = MASK_TAG
    entry_age = (entry_tag - head) & mask
    flush_age = (flush_tag - head) & mask
    return entry_age > flush_age


class SQModel:
    """Golden model for the store queue."""

    def __init__(self, depth: int = SQ_DEPTH) -> None:
        """Initialize with empty state."""
        self.depth = depth
        self.entries: list[SQEntry] = [SQEntry() for _ in range(depth)]
        self.head_ptr = 0
        self.tail_ptr = 0
        self.write_outstanding = False
        self._ptr_wrap = 2 * depth  # Pointer wrapping boundary

    def reset(self) -> None:
        """Reset to empty state."""
        self.entries = [SQEntry() for _ in range(self.depth)]
        self.head_ptr = 0
        self.tail_ptr = 0
        self.write_outstanding = False

    @property
    def head_idx(self) -> int:
        """Return the head pointer index within the circular buffer."""
        return self.head_ptr % self.depth

    @property
    def tail_idx(self) -> int:
        """Return the tail pointer index within the circular buffer."""
        return self.tail_ptr % self.depth

    @property
    def count(self) -> int:
        """Return the number of valid entries."""
        return sum(1 for e in self.entries if e.valid)

    @property
    def window_occupancy(self) -> int:
        """Ring window size (tail - head); capacity consumed including holes."""
        return (self.tail_ptr - self.head_ptr) % self._ptr_wrap

    @property
    def full(self) -> bool:
        """Window-based full (matches the pure-tail-allocation RTL)."""
        return self.window_occupancy >= self.depth

    @property
    def empty(self) -> bool:
        """Return whether the store queue is empty."""
        return self.count == 0

    def alloc(
        self,
        rob_tag: int,
        is_fp: bool,
        size: int,
        is_sc: bool = False,
        addr_valid: bool = False,
        address: int = 0,
        is_mmio: bool = False,
    ) -> bool:
        """Allocate a new entry at the ring tail. Returns True if successful."""
        if self.full:
            return False
        ptr = self.tail_ptr
        idx = ptr % self.depth
        assert not self.entries[idx].valid, "tail allocation hit a valid entry"
        e = self.entries[idx]
        e.valid = True
        e.rob_tag = rob_tag & MASK_TAG
        e.is_fp = is_fp
        e.addr_valid = addr_valid
        e.address = address & MASK32
        e.data_valid = False
        e.data = 0
        e.size = size
        e.is_mmio = is_mmio
        e.fp64_phase = 0
        e.committed = False
        e.sent = False
        e.is_sc = is_sc
        self.tail_ptr = (ptr + 1) % self._ptr_wrap
        return True

    @property
    def committed_empty(self) -> bool:
        """Return whether there are no committed entries pending write."""
        return not any(e.valid and e.committed for e in self.entries)

    def sc_discard(self, rob_tag: int) -> None:
        """Discard a failed SC entry."""
        tag = rob_tag & MASK_TAG
        for e in self.entries:
            if e.valid and e.is_sc and e.rob_tag == tag:
                e.valid = False

    def addr_update(self, rob_tag: int, address: int, is_mmio: bool = False) -> None:
        """Update address for matching entry."""
        for e in self.entries:
            if e.valid and not e.addr_valid and e.rob_tag == (rob_tag & MASK_TAG):
                e.addr_valid = True
                e.address = address & MASK32
                e.is_mmio = is_mmio

    def data_update(self, rob_tag: int, data: int) -> None:
        """Update data for matching entry."""
        for e in self.entries:
            if e.valid and not e.data_valid and e.rob_tag == (rob_tag & MASK_TAG):
                e.data_valid = True
                e.data = data & MASK64

    def commit(self, rob_tag: int) -> None:
        """Mark matching entry as committed."""
        for e in self.entries:
            if e.valid and not e.committed and e.rob_tag == (rob_tag & MASK_TAG):
                e.committed = True

    def mem_write_initiate(self) -> None:
        """Mark write as outstanding (called after asserting write_en)."""
        self.write_outstanding = True

    def mem_write_done(self) -> None:
        """Handle memory write completion."""
        if not self.write_outstanding:
            return
        e = self.entries[self.head_idx]
        if e.size == MEM_SIZE_DOUBLE and not e.fp64_phase:
            # FSD phase 0 → advance to phase 1
            e.fp64_phase = 1
            self.write_outstanding = False
        else:
            # Complete: free entry
            e.valid = False
            e.sent = True
            self.write_outstanding = False

    def advance_head(self) -> None:
        """Advance head pointer past freed entries (collapse to tail when empty)."""
        while self.count and not self.entries[self.head_idx].valid:
            self.head_ptr = (self.head_ptr + 1) % self._ptr_wrap
        if self.count == 0:
            self.head_ptr = self.tail_ptr

    def flush_all(self) -> None:
        """Full flush: clear all state."""
        self.reset()

    def partial_flush(self, flush_tag: int, rob_head_tag: int) -> None:
        """Kill younger uncommitted entries, then pull back the ring tail."""
        for e in self.entries:
            if (
                e.valid
                and not e.committed
                and is_younger(e.rob_tag, flush_tag & MASK_TAG, rob_head_tag & MASK_TAG)
            ):
                e.valid = False

        last_survivor_offset = None
        for offset in range(self.depth):
            if self.entries[(self.head_idx + offset) % self.depth].valid:
                last_survivor_offset = offset
        if last_survivor_offset is None:
            self.tail_ptr = self.head_ptr
        else:
            self.tail_ptr = (self.head_ptr + last_survivor_offset + 1) % self._ptr_wrap

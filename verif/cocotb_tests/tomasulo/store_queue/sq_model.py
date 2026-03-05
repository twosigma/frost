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
memory writes, store-to-load forwarding, and FSD two-phase writes.
"""

from dataclasses import dataclass

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
XLEN = 32
FLEN = 64
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


def is_older_than(store_tag: int, load_tag: int, head: int) -> bool:
    """Check if store_tag is older than load_tag relative to head."""
    mask = MASK_TAG
    store_age = (store_tag - head) & mask
    load_age = (load_tag - head) & mask
    return store_age < load_age


def gen_byte_en(addr_offset: int, size: int) -> int:
    """Generate byte-enable mask from address offset and size."""
    offset = addr_offset & 0x3
    if size == MEM_SIZE_BYTE:
        return (1 << offset) & 0xF
    elif size == MEM_SIZE_HALF:
        return 0xC if (offset & 0x2) else 0x3
    elif size == MEM_SIZE_WORD:
        return 0xF
    elif size == MEM_SIZE_DOUBLE:
        return 0xF  # Each phase is word-width
    return 0


def gen_write_data(data: int, size: int, fp64_phase: int) -> int:
    """Generate write data with correct byte-lane positioning."""
    if size == MEM_SIZE_BYTE:
        byte_val = data & 0xFF
        return (
            byte_val | (byte_val << 8) | (byte_val << 16) | (byte_val << 24)
        ) & MASK32
    elif size == MEM_SIZE_HALF:
        half_val = data & 0xFFFF
        return (half_val | (half_val << 16)) & MASK32
    elif size == MEM_SIZE_WORD:
        return data & MASK32
    elif size == MEM_SIZE_DOUBLE:
        if fp64_phase:
            return (data >> 32) & MASK32
        else:
            return data & MASK32
    return 0


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
    def full(self) -> bool:
        """Return whether the store queue is full."""
        return self.count == self.depth

    @property
    def empty(self) -> bool:
        """Return whether the store queue is empty."""
        return self.count == 0

    def alloc(self, rob_tag: int, is_fp: bool, size: int, is_sc: bool = False) -> bool:
        """Allocate a new entry at tail. Returns True if successful."""
        if self.full:
            return False
        idx = self.tail_idx
        e = self.entries[idx]
        e.valid = True
        e.rob_tag = rob_tag & MASK_TAG
        e.is_fp = is_fp
        e.addr_valid = False
        e.address = 0
        e.data_valid = False
        e.data = 0
        e.size = size
        e.is_mmio = False
        e.fp64_phase = 0
        e.committed = False
        e.sent = False
        e.is_sc = is_sc
        self.tail_ptr = (self.tail_ptr + 1) % self._ptr_wrap
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

    def get_mem_write(self) -> MemWriteReq:
        """Get memory write request from head entry (combinational)."""
        e = self.entries[self.head_idx]
        if (
            e.valid
            and e.committed
            and e.addr_valid
            and e.data_valid
            and not e.sent
            and not self.write_outstanding
        ):
            addr = e.address
            if e.size == MEM_SIZE_DOUBLE and e.fp64_phase:
                addr = (e.address + 4) & MASK32

            return MemWriteReq(
                en=True,
                addr=addr,
                data=gen_write_data(e.data, e.size, e.fp64_phase),
                byte_en=gen_byte_en(addr & 0x3, e.size),
            )
        return MemWriteReq()

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
        """Advance head pointer past freed entries."""
        while self.head_ptr != self.tail_ptr and not self.entries[self.head_idx].valid:
            self.head_ptr = (self.head_ptr + 1) % self._ptr_wrap

    def check_forward(
        self, check_addr: int, check_rob_tag: int, check_size: int, rob_head_tag: int
    ) -> tuple[bool, ForwardResult]:
        """Check store-to-load forwarding (combinational).

        Returns (all_older_addrs_known, ForwardResult).
        Scans from oldest (head) to newest: last match wins (newest store).
        """
        all_older_known = True
        found_match = False
        can_fwd = False
        fwd_data = 0

        for i in range(self.depth):
            idx = (self.head_idx + i) % self.depth
            e = self.entries[idx]

            if e.valid and is_older_than(
                e.rob_tag, check_rob_tag & MASK_TAG, rob_head_tag & MASK_TAG
            ):
                # This entry is an older store
                if not e.addr_valid:
                    all_older_known = False

                if e.addr_valid:
                    # Check address overlap (word-aligned)
                    base_match = (e.address >> 2) == ((check_addr & MASK32) >> 2)
                    double_hi = e.size == MEM_SIZE_DOUBLE and (
                        (e.address >> 2) + 1
                    ) == ((check_addr & MASK32) >> 2)
                    load_double_hi = check_size == MEM_SIZE_DOUBLE and (
                        e.address >> 2
                    ) == (((check_addr & MASK32) >> 2) + 1)

                    if base_match or double_hi or load_double_hi:
                        found_match = True
                        if e.data_valid and not e.is_mmio:
                            # Case 1: exact addr, same size, WORD/DOUBLE
                            if (
                                e.address == (check_addr & MASK32)
                                and e.size == check_size
                                and check_size >= MEM_SIZE_WORD
                            ):
                                can_fwd = True
                                fwd_data = e.data & MASK64
                            # Case 2: FLW at FSD base → forward low word
                            elif (
                                base_match
                                and check_size == MEM_SIZE_WORD
                                and e.size == MEM_SIZE_DOUBLE
                            ):
                                can_fwd = True
                                fwd_data = e.data & MASK32
                            # Case 3: FLW at FSD addr+4 → forward high word
                            elif double_hi and check_size == MEM_SIZE_WORD:
                                can_fwd = True
                                fwd_data = (e.data >> 32) & MASK32
                            else:
                                can_fwd = False
                        else:
                            # MMIO or no data — load must wait
                            can_fwd = False

        result = ForwardResult(
            match=found_match,
            can_forward=found_match and can_fwd,
            data=fwd_data,
        )
        return all_older_known, result

    def flush_all(self) -> None:
        """Full flush: clear all state."""
        self.reset()

    def partial_flush(self, flush_tag: int, rob_head_tag: int) -> None:
        """Partial flush: invalidate uncommitted entries younger than flush_tag.

        Committed entries are never flushed. After invalidating, retract
        tail_ptr backwards past consecutive invalid entries at the tail end.
        """
        for e in self.entries:
            if (
                e.valid
                and not e.committed
                and is_younger(e.rob_tag, flush_tag & MASK_TAG, rob_head_tag & MASK_TAG)
            ):
                e.valid = False
        # Retract tail past consecutive invalid entries at tail end
        while (
            self.tail_ptr != self.head_ptr
            and not self.entries[(self.tail_ptr - 1) % self.depth].valid
        ):
            self.tail_ptr = (self.tail_ptr - 1) % self._ptr_wrap

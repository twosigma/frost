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

"""Golden model for the Load Queue.

Mirrors the RTL circular buffer, entry state machine, issue selection,
SQ disambiguation, memory response handling, and CDB broadcast logic.
"""

from dataclasses import dataclass
from config import MASK32, MASK64, MASK_XLEN, XLEN

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
LQ_DEPTH = 8

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1

# mem_size_e values
MEM_SIZE_BYTE = 0
MEM_SIZE_HALF = 1
MEM_SIZE_WORD = 2
MEM_SIZE_DOUBLE = 3


@dataclass
class LQEntry:
    """One load queue entry."""

    valid: bool = False
    rob_tag: int = 0
    is_fp: bool = False
    addr_valid: bool = False
    address: int = 0
    size: int = MEM_SIZE_WORD
    sign_ext: bool = False
    is_mmio: bool = False
    issued: bool = False
    data_valid: bool = False
    data: int = 0
    forwarded: bool = False
    is_lr: bool = False
    is_amo: bool = False
    amo_op: int = 0
    amo_rs2: int = 0


@dataclass
class FuComplete:
    """FU completion result."""

    valid: bool = False
    tag: int = 0
    value: int = 0
    exception: bool = False
    exc_cause: int = 0
    fp_flags: int = 0


@dataclass
class SQForwardResult:
    """Store-to-load forwarding result."""

    match: bool = False
    can_forward: bool = False
    data: int = 0


def sign_extend_to_xlen(val: int, width: int) -> int:
    """Sign-extend ``width`` low bits to the configured architectural XLEN."""
    assert 0 < width <= XLEN
    value_mask = (1 << width) - 1
    val &= value_mask
    if val & (1 << (width - 1)):
        val |= MASK_XLEN ^ value_mask
    return val


def sign_extend_byte(val: int, unsigned: bool) -> int:
    """Sign/zero extend a byte to XLEN bits."""
    val &= 0xFF
    return val if unsigned else sign_extend_to_xlen(val, 8)


def sign_extend_half(val: int, unsigned: bool) -> int:
    """Sign/zero extend a halfword to XLEN bits."""
    val &= 0xFFFF
    return val if unsigned else sign_extend_to_xlen(val, 16)


def load_unit_model(size: int, sign_ext: bool, address: int, raw_data: int) -> int:
    """Model the load_unit: extract from the 64-bit beat and sign extend.

    The data tier returns the aligned dword at addr[31:3]; the load unit
    selects the addressed byte/half/word by addr[2:0]
    (docs/rv64/m1_data_tier.md).
    """
    raw_data = raw_data & MASK64
    if size == MEM_SIZE_BYTE:
        byte_sel = address & 0x7
        byte_val = (raw_data >> (byte_sel * 8)) & 0xFF
        return sign_extend_byte(byte_val, not sign_ext)
    elif size == MEM_SIZE_HALF:
        half_sel = (address >> 1) & 0x3
        half_val = (raw_data >> (half_sel * 16)) & 0xFFFF
        return sign_extend_half(half_val, not sign_ext)
    else:
        word_sel = (address >> 2) & 0x1
        word_val = (raw_data >> (word_sel * 32)) & MASK32
        return sign_extend_to_xlen(word_val, 32) if sign_ext else word_val


def is_younger(entry_tag: int, flush_tag: int, head: int) -> bool:
    """Check if entry_tag is younger than flush_tag relative to head."""
    mask = MASK_TAG
    entry_age = (entry_tag - head) & mask
    flush_age = (flush_tag - head) & mask
    return entry_age > flush_age


class LQModel:
    """Golden model for the load queue."""

    def __init__(self, depth: int = LQ_DEPTH) -> None:
        """Initialize with empty state."""
        self.depth = depth
        self.entries: list[LQEntry] = [LQEntry() for _ in range(depth)]
        self.head_ptr = 0
        self.tail_ptr = 0
        self.mem_outstanding = False
        self.issued_idx = 0
        self._ptr_wrap = 2 * depth  # Pointer wrapping boundary
        self.cdb_stage = FuComplete()
        # Reservation register (LR/SC)
        self.reservation_valid = False
        self.reservation_addr = 0
        # AMO FSM
        self.amo_state = 0  # 0=IDLE, 1=WRITE_ACTIVE
        self.amo_old_value = 0
        self.amo_entry_idx = 0

    def reset(self) -> None:
        """Reset to empty state."""
        self.entries = [LQEntry() for _ in range(self.depth)]
        self.head_ptr = 0
        self.tail_ptr = 0
        self.mem_outstanding = False
        self.issued_idx = 0
        self.cdb_stage = FuComplete()
        self.reservation_valid = False
        self.reservation_addr = 0
        self.amo_state = 0
        self.amo_old_value = 0
        self.amo_entry_idx = 0

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
        n = 0
        for e in self.entries:
            if e.valid:
                n += 1
        return n

    @property
    def full(self) -> bool:
        """Count-based full (matches the sparse-hole RTL)."""
        return self.count == self.depth

    @property
    def empty(self) -> bool:
        """Return whether the load queue model is empty."""
        return self.count == 0

    def alloc(
        self,
        rob_tag: int,
        is_fp: bool,
        size: int,
        sign_ext: bool,
        is_lr: bool = False,
        is_amo: bool = False,
        amo_op: int = 0,
    ) -> bool:
        """Allocate a new entry at the next invalid slot. Returns True if successful."""
        if self.full:
            return False
        ptr = self.tail_ptr
        for _ in range(self.depth):
            if not self.entries[ptr % self.depth].valid:
                break
            ptr = (ptr + 1) % self._ptr_wrap
        idx = ptr % self.depth
        e = self.entries[idx]
        e.valid = True
        e.rob_tag = rob_tag & MASK_TAG
        e.is_fp = is_fp
        e.addr_valid = False
        e.address = 0
        e.size = size
        e.sign_ext = sign_ext
        e.is_mmio = False
        e.issued = False
        e.data_valid = False
        e.data = 0
        e.forwarded = False
        e.is_lr = is_lr
        e.is_amo = is_amo
        e.amo_op = amo_op
        e.amo_rs2 = 0
        self.tail_ptr = (ptr + 1) % self._ptr_wrap
        return True

    def addr_update(
        self,
        rob_tag: int,
        address: int,
        is_mmio: bool = False,
        amo_rs2: int = 0,
    ) -> None:
        """Update address for matching entry."""
        for e in self.entries:
            if e.valid and not e.addr_valid and e.rob_tag == (rob_tag & MASK_TAG):
                e.addr_valid = True
                e.address = address & MASK_XLEN
                e.is_mmio = is_mmio
                e.amo_rs2 = amo_rs2 & MASK_XLEN

    def _issue_scan(
        self,
        rob_head_tag: int = 0,
        sq_committed_empty: bool = True,
    ) -> tuple[int | None, int | None]:
        """Priority scan from head to tail. Returns (cdb_idx, mem_idx).

        LR entries require rob_tag == rob_head_tag.
        AMO entries require rob_tag == rob_head_tag AND sq_committed_empty.
        MMIO entries require rob_tag == rob_head_tag AND
        sq_committed_empty. This conservatively waits out every older
        committed store while enforcing device read-after-write ordering.
        """
        cdb_idx = None
        mem_idx = None
        for i in range(self.depth):
            idx = (self.head_idx + i) % self.depth
            e = self.entries[idx]
            if e.valid:
                if cdb_idx is None and e.data_valid:
                    cdb_idx = idx
        # Match the RTL head_mem_issue shortcut: a load at the ROB head can
        # bypass the normal physical-order scan so it does not starve behind
        # a younger blocked entry after sparse-hole reuse.  A head MMIO load
        # is admitted like the RTL head_mem_stored path, but issues only once
        # every committed store has drained.
        for idx, e in enumerate(self.entries):
            if (
                e.valid
                and e.rob_tag == (rob_head_tag & MASK_TAG)
                and e.addr_valid
                and not e.issued
                and not e.data_valid
                and (not e.is_mmio or sq_committed_empty)
                and not e.is_lr
                and (not e.is_amo or sq_committed_empty)
            ):
                mem_idx = idx
                break

        if mem_idx is None:
            for i in range(self.depth):
                idx = (self.head_idx + i) % self.depth
                e = self.entries[idx]
                if e.valid and e.addr_valid and not e.issued and not e.data_valid:
                    # Stored-address MMIO uses only the dedicated head loop
                    # above; the normal physical-order scan excludes it.
                    if e.is_mmio:
                        continue
                    if e.is_lr and e.rob_tag != (rob_head_tag & MASK_TAG):
                        continue
                    if e.is_amo and (
                        e.rob_tag != (rob_head_tag & MASK_TAG) or not sq_committed_empty
                    ):
                        continue
                    mem_idx = idx
                    break
        return cdb_idx, mem_idx

    def apply_forward(self, sq_forward: SQForwardResult) -> None:
        """Apply SQ forwarding result to the Phase B candidate."""
        _, mem_idx = self._issue_scan()
        if mem_idx is None:
            return
        e = self.entries[mem_idx]
        if sq_forward.can_forward and not e.is_mmio and not e.is_lr and not e.is_amo:
            e.data_valid = True
            e.forwarded = True
            e.data = sq_forward.data & MASK64

    def cache_hit_complete(self) -> None:
        """Model DUT cache-hit fast path for the current Phase B candidate.

        On an L0 cache hit, the DUT marks the candidate's data as valid without
        issuing a memory request.
        """
        _, mem_idx = self._issue_scan()
        if mem_idx is None:
            return

        e = self.entries[mem_idx]

        # Mirror load_queue.sv cache_hit_fast_path gating (every size is
        # L0-eligible on the dword-line cache, including FLD).
        if e.is_mmio:
            return
        if e.is_lr or e.is_amo:
            return

        e.data_valid = True

    def issue_to_memory(
        self, all_older_known: bool, sq_forward: SQForwardResult
    ) -> dict | None:
        """Determine if a memory read should be issued. Returns request or None."""
        _, mem_idx = self._issue_scan()
        if mem_idx is None or self.mem_outstanding:
            return None
        e = self.entries[mem_idx]
        can_issue = all_older_known and not sq_forward.match
        if not can_issue:
            return None

        e.issued = True
        self.mem_outstanding = True
        self.issued_idx = mem_idx

        return {"addr": e.address, "size": e.size}

    def mem_response(self, data: int) -> None:
        """Handle a memory response beat (aligned 64-bit dword)."""
        if not self.mem_outstanding:
            return
        idx = self.issued_idx
        e = self.entries[idx]
        data = data & MASK64

        if e.is_amo:
            # AMO.W returns its addressed word sign-extended to XLEN; AMO.D
            # returns the full architectural value unchanged.
            if e.size == MEM_SIZE_DOUBLE:
                self.amo_old_value = data & MASK_XLEN
            else:
                word_sel = (e.address >> 2) & 0x1
                old_word = (data >> (word_sel * 32)) & MASK32
                self.amo_old_value = sign_extend_to_xlen(old_word, 32)
            self.amo_entry_idx = idx
            self.amo_state = 1  # WRITE_ACTIVE
            self.mem_outstanding = False
        elif e.is_lr:
            # LR: normal data capture + set reservation
            processed = load_unit_model(e.size, e.sign_ext, e.address, data)
            e.data = processed & MASK64
            e.data_valid = True
            self.mem_outstanding = False
            self.reservation_valid = True
            self.reservation_addr = e.address
        elif e.size == MEM_SIZE_DOUBLE:
            # FLD (RV64 LD in M3): the full beat in one response
            e.data = data
            e.data_valid = True
            self.mem_outstanding = False
        else:
            # Sub-beat: run through the load unit (word/half/byte extract)
            processed = load_unit_model(e.size, e.sign_ext, e.address, data)
            e.data = processed & MASK64
            e.data_valid = True
            self.mem_outstanding = False

    def amo_write_done(self) -> None:
        """Handle AMO write completion."""
        if self.amo_state != 1:
            return
        idx = self.amo_entry_idx
        e = self.entries[idx]
        e.data = self.amo_old_value & MASK64
        e.data_valid = True
        self.amo_state = 0

    def sc_clear_reservation(self) -> None:
        """Clear reservation on SC commit."""
        self.reservation_valid = False

    def reservation_snoop_invalidate(self) -> None:
        """Invalidate reservation on snoop."""
        self.reservation_valid = False

    def _capture_ready_fu_complete(self) -> None:
        """Capture the next ready completion into the one-entry output stage."""
        if self.cdb_stage.valid:
            return
        cdb_idx, _ = self._issue_scan()
        if cdb_idx is None:
            return
        e = self.entries[cdb_idx]
        value = 0
        if e.is_fp:
            if e.size == MEM_SIZE_DOUBLE:
                value = e.data & MASK64
            else:
                value = (0xFFFFFFFF << 32) | (e.data & MASK32)
        else:
            value = e.data & MASK_XLEN
        self.cdb_stage = FuComplete(valid=True, tag=e.rob_tag, value=value & MASK64)
        self.entries[cdb_idx].valid = False

    def get_fu_complete(self, adapter_pending: bool = False) -> FuComplete:
        """Get the staged FU completion output."""
        del adapter_pending
        self._capture_ready_fu_complete()
        return FuComplete(
            valid=self.cdb_stage.valid,
            tag=self.cdb_stage.tag,
            value=self.cdb_stage.value,
            exception=self.cdb_stage.exception,
            exc_cause=self.cdb_stage.exc_cause,
            fp_flags=self.cdb_stage.fp_flags,
        )

    def free_cdb_entry(self, adapter_pending: bool = False) -> None:
        """Accept and clear the currently-presented staged completion."""
        del adapter_pending
        self.cdb_stage = FuComplete()

    def advance_head(self) -> None:
        """Advance head pointer past freed entries."""
        while self.count and not self.entries[self.head_idx].valid:
            self.head_ptr = (self.head_ptr + 1) % self._ptr_wrap

    def flush_all(self) -> None:
        """Full flush: clear all state (including reservation)."""
        self.reset()

    def mem_response_drain(self, data: int) -> None:
        """Handle memory response with drain logic.

        If the issued entry was flushed, discard the response and clear
        mem_outstanding.  Otherwise process normally.
        """
        if not self.mem_outstanding:
            return
        idx = self.issued_idx
        e = self.entries[idx]
        if not e.valid:
            # Stale response drain: entry was flushed
            self.mem_outstanding = False
            return
        # Entry still valid — process normally
        self.mem_response(data)

    def partial_flush(self, flush_tag: int, rob_head_tag: int) -> None:
        """Partial flush: invalidate entries younger than flush_tag.

        The model retains mem_outstanding as a logical response debt when the
        in-flight entry is flushed. The RTL represents the same debt with
        drop_mem_response_pending after clearing its live-owner tracker.
        mem_response_drain checks validity and discards that stale response.

        After invalidating, retract tail_ptr backwards past consecutive
        invalid entries at the tail end.
        """
        for e in self.entries:
            if e.valid and is_younger(
                e.rob_tag, flush_tag & MASK_TAG, rob_head_tag & MASK_TAG
            ):
                e.valid = False
        if self.cdb_stage.valid and is_younger(
            self.cdb_stage.tag, flush_tag & MASK_TAG, rob_head_tag & MASK_TAG
        ):
            self.cdb_stage = FuComplete()

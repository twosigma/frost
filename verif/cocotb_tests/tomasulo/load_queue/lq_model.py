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

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
XLEN = 32
FLEN = 64
LQ_DEPTH = 8

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK32 = (1 << XLEN) - 1
MASK64 = (1 << FLEN) - 1

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
    fp64_phase: int = 0
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


def sign_extend_byte(val: int, unsigned: bool) -> int:
    """Sign/zero extend a byte to 32 bits."""
    val = val & 0xFF
    if not unsigned and (val & 0x80):
        return val | 0xFFFFFF00
    return val


def sign_extend_half(val: int, unsigned: bool) -> int:
    """Sign/zero extend a halfword to 32 bits."""
    val = val & 0xFFFF
    if not unsigned and (val & 0x8000):
        return val | 0xFFFF0000
    return val


def load_unit_model(size: int, sign_ext: bool, address: int, raw_data: int) -> int:
    """Model the load_unit: extract byte/half and sign extend."""
    raw_data = raw_data & MASK32
    if size == MEM_SIZE_BYTE:
        byte_sel = address & 0x3
        byte_val = (raw_data >> (byte_sel * 8)) & 0xFF
        return sign_extend_byte(byte_val, not sign_ext) & MASK32
    elif size == MEM_SIZE_HALF:
        half_sel = (address >> 1) & 0x1
        half_val = (raw_data >> (half_sel * 16)) & 0xFFFF
        return sign_extend_half(half_val, not sign_ext) & MASK32
    else:
        return raw_data & MASK32


# instr_op_e enum values for atomics
AMOSWAP_W = 95
AMOADD_W = 96
AMOXOR_W = 97
AMOAND_W = 98
AMOOR_W = 99
AMOMIN_W = 100
AMOMAX_W = 101
AMOMINU_W = 102
AMOMAXU_W = 103


def _signed32(val: int) -> int:
    """Interpret 32-bit unsigned value as signed."""
    val = val & MASK32
    if val & 0x80000000:
        return val - 0x100000000
    return val


def amo_compute(op: int, old_val: int, rs2: int) -> int:
    """Compute AMO result (combinational)."""
    old_val = old_val & MASK32
    rs2 = rs2 & MASK32
    if op == AMOSWAP_W:
        return rs2
    elif op == AMOADD_W:
        return (old_val + rs2) & MASK32
    elif op == AMOXOR_W:
        return old_val ^ rs2
    elif op == AMOAND_W:
        return old_val & rs2
    elif op == AMOOR_W:
        return old_val | rs2
    elif op == AMOMIN_W:
        return old_val if _signed32(old_val) < _signed32(rs2) else rs2
    elif op == AMOMAX_W:
        return old_val if _signed32(old_val) > _signed32(rs2) else rs2
    elif op == AMOMINU_W:
        return old_val if old_val < rs2 else rs2
    elif op == AMOMAXU_W:
        return old_val if old_val > rs2 else rs2
    return old_val


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
        """Pointer-based full (matches RTL).

        With out-of-order frees and partial flush, holes can exist between
        head and tail.  The RTL reports full when the pointer space is
        exhausted even if some entries are invalid, so the model must too.
        """
        return (
            self.head_ptr % self.depth == self.tail_ptr % self.depth
            and self.head_ptr != self.tail_ptr
        )

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
        e.size = size
        e.sign_ext = sign_ext
        e.is_mmio = False
        e.fp64_phase = 0
        e.issued = False
        e.data_valid = False
        e.data = 0
        e.forwarded = False
        e.is_lr = is_lr
        e.is_amo = is_amo
        e.amo_op = amo_op
        e.amo_rs2 = 0
        self.tail_ptr = (self.tail_ptr + 1) % self._ptr_wrap
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
                e.address = address & MASK32
                e.is_mmio = is_mmio
                e.amo_rs2 = amo_rs2 & MASK32

    def _issue_scan(
        self,
        rob_head_tag: int = 0,
        sq_committed_empty: bool = True,
    ) -> tuple[int | None, int | None]:
        """Priority scan from head to tail. Returns (cdb_idx, mem_idx).

        LR entries require rob_tag == rob_head_tag.
        AMO entries require rob_tag == rob_head_tag AND sq_committed_empty.
        """
        cdb_idx = None
        mem_idx = None
        for i in range(self.depth):
            idx = (self.head_idx + i) % self.depth
            e = self.entries[idx]
            if e.valid:
                if cdb_idx is None and e.data_valid:
                    cdb_idx = idx
                if (
                    mem_idx is None
                    and e.addr_valid
                    and not e.issued
                    and not e.data_valid
                ):
                    # LR/AMO gating
                    if e.is_lr and e.rob_tag != (rob_head_tag & MASK_TAG):
                        continue
                    if e.is_amo and (
                        e.rob_tag != (rob_head_tag & MASK_TAG) or not sq_committed_empty
                    ):
                        continue
                    mem_idx = idx
        return cdb_idx, mem_idx

    def get_sq_check(
        self,
        rob_head_tag: int,
        sq_committed_empty: bool = True,
    ) -> dict | None:
        """Get SQ disambiguation check if Phase B candidate exists."""
        _, mem_idx = self._issue_scan(rob_head_tag, sq_committed_empty)
        if mem_idx is None or self.mem_outstanding:
            return None
        e = self.entries[mem_idx]
        if e.is_mmio and e.rob_tag != (rob_head_tag & MASK_TAG):
            return None
        return {
            "valid": True,
            "addr": e.address,
            "rob_tag": e.rob_tag,
            "size": e.size,
            "idx": mem_idx,
        }

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

        # Mirror load_queue.sv cache_hit_fast_path gating.
        if e.is_mmio:
            return
        if e.is_fp and e.size == MEM_SIZE_DOUBLE:
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

        addr = e.address
        if e.is_fp and e.size == MEM_SIZE_DOUBLE and e.fp64_phase:
            addr = (addr + 4) & MASK32

        e.issued = True
        self.mem_outstanding = True
        self.issued_idx = mem_idx

        return {"addr": addr, "size": e.size}

    def mem_response(self, data: int) -> None:
        """Handle memory response."""
        if not self.mem_outstanding:
            return
        idx = self.issued_idx
        e = self.entries[idx]
        data = data & MASK32

        if e.is_amo:
            # AMO: latch old value, start write phase
            self.amo_old_value = data
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
        elif e.is_fp and e.size == MEM_SIZE_DOUBLE and not e.fp64_phase:
            # FLD phase 0: store low word through load unit, advance to phase 1
            processed = load_unit_model(MEM_SIZE_WORD, False, e.address, data)
            e.data = (e.data & ~MASK32) | (processed & MASK32)
            e.fp64_phase = 1
            e.issued = False
            self.mem_outstanding = False
        elif e.is_fp and e.size == MEM_SIZE_DOUBLE and e.fp64_phase:
            # FLD phase 1: store high word raw
            e.data = (e.data & MASK32) | ((data & MASK32) << 32)
            e.data_valid = True
            self.mem_outstanding = False
        else:
            # Single-phase: run through load unit
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

    def get_fu_complete(self, adapter_pending: bool = False) -> FuComplete:
        """Get CDB broadcast output (combinational)."""
        if adapter_pending:
            return FuComplete()
        cdb_idx, _ = self._issue_scan()
        if cdb_idx is None:
            return FuComplete()
        e = self.entries[cdb_idx]
        value = 0
        if e.is_fp:
            if e.size == MEM_SIZE_DOUBLE:
                value = e.data & MASK64
            else:
                # FLW: NaN-box
                value = (0xFFFFFFFF << 32) | (e.data & MASK32)
        else:
            # INT: zero-extend XLEN to FLEN
            value = e.data & MASK32
        return FuComplete(valid=True, tag=e.rob_tag, value=value & MASK64)

    def free_cdb_entry(self, adapter_pending: bool = False) -> None:
        """Free the entry that was broadcast on CDB."""
        if adapter_pending:
            return
        cdb_idx, _ = self._issue_scan()
        if cdb_idx is not None:
            self.entries[cdb_idx].valid = False

    def advance_head(self) -> None:
        """Advance head pointer past freed entries."""
        while self.head_ptr != self.tail_ptr and not self.entries[self.head_idx].valid:
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

        Drain approach: do NOT clear mem_outstanding when the in-flight
        entry is flushed.  The mem_response_drain handler checks validity
        and discards stale responses.

        After invalidating, retract tail_ptr backwards past consecutive
        invalid entries at the tail end.
        """
        for e in self.entries:
            if e.valid and is_younger(
                e.rob_tag, flush_tag & MASK_TAG, rob_head_tag & MASK_TAG
            ):
                e.valid = False
        # Retract tail past consecutive invalid entries at tail end
        while (
            self.tail_ptr != self.head_ptr
            and not self.entries[(self.tail_ptr - 1) % self.depth].valid
        ):
            self.tail_ptr = (self.tail_ptr - 1) % self._ptr_wrap

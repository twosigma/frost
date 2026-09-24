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

"""Golden model for the Reservation Station.

Mirrors the RTL logic: dispatch, CDB snoop, issue selection, and flush.
"""

from dataclasses import dataclass

from config import MASK_XLEN

ROB_TAG_WIDTH = 5
MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK64 = 0xFFFF_FFFF_FFFF_FFFF


@dataclass
class RSEntry:
    """Single RS entry mirroring RTL storage."""

    valid: bool = False
    rob_tag: int = 0
    op: int = 0

    src1_ready: bool = False
    src1_tag: int = 0
    src1_value: int = 0

    src2_ready: bool = False
    src2_tag: int = 0
    src2_value: int = 0

    src3_ready: bool = False
    src3_tag: int = 0
    src3_value: int = 0

    # Deferred delivery of a CDB match in the dispatch cycle. The RTL keeps a
    # pending bit and lane select per source plus two registered lane values;
    # the model stores the pending value itself, which is equivalent at its
    # outputs.
    src1_pend: bool = False
    src1_pend_value: int = 0
    src2_pend: bool = False
    src2_pend_value: int = 0
    src3_pend: bool = False
    src3_pend_value: int = 0

    imm: int = 0
    use_imm: bool = False
    jalr_imm: int = 0
    rm: int = 0

    predicted_taken: bool = False
    predicted_target: int = 0
    predicted_target_ok: bool = False
    is_compressed: bool = False

    is_fp_mem: bool = False
    mem_size: int = 0
    mem_signed: bool = False

    csr_addr: int = 0
    csr_imm: int = 0
    pc: int = 0
    link_addr: int = 0

    def is_ready(self) -> bool:
        """Check if entry is ready to issue."""
        return self.valid and self.src1_ready and self.src2_ready and self.src3_ready


class RSModel:
    """Golden model for Reservation Station."""

    def __init__(self, depth: int = 8) -> None:
        """Initialize RS model with given depth."""
        self.depth = depth
        self.entries: list[RSEntry] = [RSEntry() for _ in range(depth)]
        # Optional cycle-exact allocation. The RTL clears an issued entry's
        # valid bit at the clock edge, so the free-slot priority encoder sees
        # that slot only in the next cycle. With this set, a slot consumed in
        # a bench cycle stays unavailable to dispatch until tick(); otherwise
        # model and DUT slot indices diverge, and when two entries wake
        # together the lowest-index rule picks different ones. Cycle-driven
        # tests set it and call tick() once per cycle; directed tests leave it
        # off and reuse slots immediately.
        self.strict_alloc_timing = False
        self._alloc_blocked: set[int] = set()
        # dispatch() runs before the RTL edge that writes the entry, so the
        # first tick() after it arms a deferred CDB delivery and the second
        # applies it, as the RTL sets the source ready on the edge after the
        # dispatch edge.
        self._pending_delivery_armed: set[tuple[int, int]] = set()

    def reset(self) -> None:
        """Reset all entries."""
        self.entries = [RSEntry() for _ in range(self.depth)]
        self._alloc_blocked.clear()
        self._pending_delivery_armed.clear()

    def tick(self) -> None:
        """Advance one cycle: free consumed slots and age deferred CDB deliveries."""
        self._alloc_blocked.clear()

        for idx, source in self._pending_delivery_armed:
            e = self.entries[idx]
            if source == 1 and e.src1_pend:
                e.src1_ready = True
                e.src1_value = e.src1_pend_value
                e.src1_pend = False
            elif source == 2 and e.src2_pend:
                e.src2_ready = True
                e.src2_value = e.src2_pend_value
                e.src2_pend = False
            elif source == 3 and e.src3_pend:
                e.src3_ready = True
                e.src3_value = e.src3_pend_value
                e.src3_pend = False

        self._pending_delivery_armed = {
            (idx, source)
            for idx, e in enumerate(self.entries)
            for source, pending in (
                (1, e.src1_pend),
                (2, e.src2_pend),
                (3, e.src3_pend),
            )
            if pending
        }

    def is_full(self) -> bool:
        """Return whether all entries are valid."""
        return all(e.valid for e in self.entries)

    def is_full_for_2(self) -> bool:
        """Return whether there is not enough room for a 2-wide dispatch."""
        return self.count() >= self.depth - 1

    def count(self) -> int:
        """Return number of valid entries."""
        return sum(1 for e in self.entries if e.valid)

    def _find_free(self) -> int | None:
        """Find lowest-index free entry (priority encoder)."""
        for i, e in enumerate(self.entries):
            if not e.valid and i not in self._alloc_blocked:
                return i
        return None

    def dispatch(
        self,
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
        mem_size: int = 0,
        mem_signed: bool = False,
        csr_addr: int = 0,
        csr_imm: int = 0,
        pc: int = 0,
        link_addr: int = 0,
        cdb_valid: bool = False,
        cdb_tag: int = 0,
        cdb_value: int = 0,
    ) -> int | None:
        """Dispatch an instruction to the RS.

        Returns the index it was placed at, or None if full.
        The cdb_* args describe a CDB broadcast in the dispatch cycle; a
        matching unready source becomes ready one cycle later (see
        deliver_pending and tick).
        """
        idx = self._find_free()
        if idx is None:
            return None

        # The slot's previous occupant, flushed or issued, may still have an
        # armed delivery. Drop it so the new entry starts clean.
        self._pending_delivery_armed.difference_update({(idx, 1), (idx, 2), (idx, 3)})
        e = self.entries[idx]
        e.valid = True
        e.rob_tag = rob_tag & MASK_TAG
        e.op = op

        # Source 1 with deferred dispatch-cycle CDB capture
        e.src1_tag = src1_tag & MASK_TAG
        e.src1_value = src1_value & MASK64
        if (
            not src1_ready
            and cdb_valid
            and (src1_tag & MASK_TAG) == (cdb_tag & MASK_TAG)
        ):
            e.src1_ready = False
            e.src1_pend = True
            e.src1_pend_value = cdb_value & MASK64
        else:
            e.src1_ready = src1_ready
            e.src1_pend = False

        # Source 2 with deferred dispatch-cycle CDB capture
        e.src2_tag = src2_tag & MASK_TAG
        e.src2_value = src2_value & MASK64
        if (
            not src2_ready
            and cdb_valid
            and (src2_tag & MASK_TAG) == (cdb_tag & MASK_TAG)
        ):
            e.src2_ready = False
            e.src2_pend = True
            e.src2_pend_value = cdb_value & MASK64
        else:
            e.src2_ready = src2_ready
            e.src2_pend = False

        # Source 3 with deferred dispatch-cycle CDB capture
        e.src3_tag = src3_tag & MASK_TAG
        e.src3_value = src3_value & MASK64
        if (
            not src3_ready
            and cdb_valid
            and (src3_tag & MASK_TAG) == (cdb_tag & MASK_TAG)
        ):
            e.src3_ready = False
            e.src3_pend = True
            e.src3_pend_value = cdb_value & MASK64
        else:
            e.src3_ready = src3_ready
            e.src3_pend = False

        e.imm = imm & MASK_XLEN
        e.use_imm = use_imm
        e.jalr_imm = jalr_imm & 0xFFF
        e.rm = rm & 0x7
        e.predicted_taken = predicted_taken
        e.predicted_target = predicted_target & MASK_XLEN
        e.predicted_target_ok = predicted_target_ok
        e.is_compressed = is_compressed
        e.is_fp_mem = is_fp_mem
        e.mem_size = mem_size & 0x3
        e.mem_signed = mem_signed
        e.csr_addr = csr_addr & 0xFFF
        e.csr_imm = csr_imm & 0x1F
        e.pc = pc & MASK_XLEN
        e.link_addr = link_addr & MASK_XLEN

        return idx

    def deliver_pending(self) -> None:
        """Apply deferred dispatch-cycle CDB deliveries (one RTL cycle later).

        As in the RTL, delivery ignores the entry's valid bit (an entry flushed
        in the meantime gets writes that nothing reads), and the pending state
        lasts only that one cycle.
        """
        for e in self.entries:
            if e.src1_pend:
                e.src1_ready = True
                e.src1_value = e.src1_pend_value
                e.src1_pend = False
            if e.src2_pend:
                e.src2_ready = True
                e.src2_value = e.src2_pend_value
                e.src2_pend = False
            if e.src3_pend:
                e.src3_ready = True
                e.src3_value = e.src3_pend_value
                e.src3_pend = False
        self._pending_delivery_armed.clear()

    def cdb_snoop(self, tag: int, value: int) -> None:
        """Apply a CDB broadcast: wake matching unready sources in valid entries."""
        tag = tag & MASK_TAG
        value = value & MASK64
        for e in self.entries:
            if not e.valid:
                continue
            if not e.src1_ready and e.src1_tag == tag:
                e.src1_ready = True
                e.src1_value = value
            if not e.src2_ready and e.src2_tag == tag:
                e.src2_ready = True
                e.src2_value = value
            if not e.src3_ready and e.src3_tag == tag:
                e.src3_ready = True
                e.src3_value = value

    @staticmethod
    def _build_issue_dict(e: RSEntry) -> dict:
        """Build issue payload from an entry."""
        return {
            "valid": True,
            "rob_tag": e.rob_tag,
            "op": e.op,
            "src1_value": e.src1_value,
            "src2_value": e.src2_value,
            "src3_value": e.src3_value,
            "imm": e.imm,
            "use_imm": e.use_imm,
            "jalr_imm": e.jalr_imm,
            "rm": e.rm,
            "predicted_taken": e.predicted_taken,
            "predicted_target": e.predicted_target,
            "predicted_target_ok": e.predicted_target_ok,
            "is_compressed": e.is_compressed,
            "is_fp_mem": e.is_fp_mem,
            "mem_size": e.mem_size,
            "mem_signed": e.mem_signed,
            "csr_addr": e.csr_addr,
            "csr_imm": e.csr_imm,
            "pc": e.pc,
            "link_addr": e.link_addr,
        }

    def peek_issue(self, fu_ready: bool = True) -> tuple[int, dict] | None:
        """Peek the lowest-index ready entry without mutating model state."""
        if not fu_ready:
            return None

        for i, e in enumerate(self.entries):
            if e.is_ready():
                return i, self._build_issue_dict(e)
        return None

    def consume_issue(self, idx: int) -> None:
        """Consume an issued entry by index."""
        self.entries[idx].valid = False
        if self.strict_alloc_timing:
            self._alloc_blocked.add(idx)

    def try_issue(self, fu_ready: bool = True) -> dict | None:
        """Try to issue the lowest-index ready entry.

        Returns issue info dict or None.
        """
        issue = self.peek_issue(fu_ready=fu_ready)
        if issue is None:
            return None

        idx, result = issue
        self.consume_issue(idx)
        return result

    def flush_all(self) -> None:
        """Clear all entries."""
        for e in self.entries:
            e.valid = False

    def _should_flush_entry(self, entry_tag: int, flush_tag: int, head: int) -> bool:
        """Check if entry_tag is younger than flush_tag relative to head."""
        entry_age = (entry_tag - head) & MASK_TAG
        flush_age = (flush_tag - head) & MASK_TAG
        return entry_age > flush_age

    def partial_flush(self, flush_tag: int, head_tag: int) -> None:
        """Invalidate entries younger than flush_tag."""
        for e in self.entries:
            if e.valid and self._should_flush_entry(e.rob_tag, flush_tag, head_tag):
                e.valid = False

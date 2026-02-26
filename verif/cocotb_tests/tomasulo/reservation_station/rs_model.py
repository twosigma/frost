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

ROB_TAG_WIDTH = 5
MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK32 = 0xFFFF_FFFF
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

    imm: int = 0
    use_imm: bool = False
    rm: int = 0

    branch_target: int = 0
    predicted_taken: bool = False
    predicted_target: int = 0

    is_fp_mem: bool = False
    mem_size: int = 0
    mem_signed: bool = False

    csr_addr: int = 0
    csr_imm: int = 0
    pc: int = 0

    def is_ready(self) -> bool:
        """Check if entry is ready to issue."""
        return (
            self.valid
            and self.src1_ready
            and (self.src2_ready or self.use_imm)
            and self.src3_ready
        )


class RSModel:
    """Golden model for Reservation Station."""

    def __init__(self, depth: int = 8) -> None:
        """Initialize RS model with given depth."""
        self.depth = depth
        self.entries: list[RSEntry] = [RSEntry() for _ in range(depth)]

    def reset(self) -> None:
        """Reset all entries."""
        self.entries = [RSEntry() for _ in range(self.depth)]

    def is_full(self) -> bool:
        """Return whether all entries are valid."""
        return all(e.valid for e in self.entries)

    def is_empty(self) -> bool:
        """Return whether no entries are valid."""
        return not any(e.valid for e in self.entries)

    def count(self) -> int:
        """Return number of valid entries."""
        return sum(1 for e in self.entries if e.valid)

    def _find_free(self) -> int | None:
        """Find lowest-index free entry (priority encoder)."""
        for i, e in enumerate(self.entries):
            if not e.valid:
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
        rm: int = 0,
        branch_target: int = 0,
        predicted_taken: bool = False,
        predicted_target: int = 0,
        is_fp_mem: bool = False,
        mem_size: int = 0,
        mem_signed: bool = False,
        csr_addr: int = 0,
        csr_imm: int = 0,
        pc: int = 0,
        cdb_valid: bool = False,
        cdb_tag: int = 0,
        cdb_value: int = 0,
    ) -> int | None:
        """Dispatch an instruction to the RS.

        Returns the index it was placed at, or None if full.
        The cdb_* args enable same-cycle CDB bypass at dispatch.
        """
        idx = self._find_free()
        if idx is None:
            return None

        e = self.entries[idx]
        e.valid = True
        e.rob_tag = rob_tag & MASK_TAG
        e.op = op

        # Source 1 with CDB bypass
        if (
            not src1_ready
            and cdb_valid
            and (src1_tag & MASK_TAG) == (cdb_tag & MASK_TAG)
        ):
            e.src1_ready = True
            e.src1_tag = src1_tag & MASK_TAG
            e.src1_value = cdb_value & MASK64
        else:
            e.src1_ready = src1_ready
            e.src1_tag = src1_tag & MASK_TAG
            e.src1_value = src1_value & MASK64

        # Source 2 with CDB bypass
        if (
            not src2_ready
            and cdb_valid
            and (src2_tag & MASK_TAG) == (cdb_tag & MASK_TAG)
        ):
            e.src2_ready = True
            e.src2_tag = src2_tag & MASK_TAG
            e.src2_value = cdb_value & MASK64
        else:
            e.src2_ready = src2_ready
            e.src2_tag = src2_tag & MASK_TAG
            e.src2_value = src2_value & MASK64

        # Source 3 with CDB bypass
        if (
            not src3_ready
            and cdb_valid
            and (src3_tag & MASK_TAG) == (cdb_tag & MASK_TAG)
        ):
            e.src3_ready = True
            e.src3_tag = src3_tag & MASK_TAG
            e.src3_value = cdb_value & MASK64
        else:
            e.src3_ready = src3_ready
            e.src3_tag = src3_tag & MASK_TAG
            e.src3_value = src3_value & MASK64

        e.imm = imm & MASK32
        e.use_imm = use_imm
        e.rm = rm & 0x7
        e.branch_target = branch_target & MASK32
        e.predicted_taken = predicted_taken
        e.predicted_target = predicted_target & MASK32
        e.is_fp_mem = is_fp_mem
        e.mem_size = mem_size & 0x3
        e.mem_signed = mem_signed
        e.csr_addr = csr_addr & 0xFFF
        e.csr_imm = csr_imm & 0x1F
        e.pc = pc & MASK32

        return idx

    def cdb_snoop(self, tag: int, value: int) -> None:
        """Process CDB broadcast: wake pending sources across all entries."""
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
            "rm": e.rm,
            "branch_target": e.branch_target,
            "predicted_taken": e.predicted_taken,
            "predicted_target": e.predicted_target,
            "is_fp_mem": e.is_fp_mem,
            "mem_size": e.mem_size,
            "mem_signed": e.mem_signed,
            "csr_addr": e.csr_addr,
            "csr_imm": e.csr_imm,
            "pc": e.pc,
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

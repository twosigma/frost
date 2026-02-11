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

"""Python model of the Register Alias Table for verification.

This module provides a software model that mirrors the RTL behavior of the
Register Alias Table. It tracks:
- INT and FP rename table entries (valid + tag per register)
- Source lookup results (renamed flag, tag, value)
- Commit clear with tag matching
- Checkpoint save/restore/free
- Flush all behavior

The model is used to generate expected outputs that are compared against
actual DUT behavior in tests.
"""

from dataclasses import dataclass, field

# Match RTL parameters
NUM_INT_REGS = 32
NUM_FP_REGS = 32
REG_ADDR_WIDTH = 5
ROB_TAG_WIDTH = 5
NUM_CHECKPOINTS = 4
CHECKPOINT_ID_WIDTH = 2
XLEN = 32
FLEN = 64
RAS_PTR_BITS = 3

MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1
MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK_REG = (1 << REG_ADDR_WIDTH) - 1


@dataclass
class RATEntry:
    """Model of a single RAT entry."""

    valid: bool = False
    tag: int = 0


@dataclass
class LookupResult:
    """Expected source lookup result."""

    renamed: bool = False
    tag: int = 0
    value: int = 0


@dataclass
class CheckpointSlot:
    """Model of a single checkpoint slot."""

    valid: bool = False
    branch_tag: int = 0
    ras_tos: int = 0
    ras_valid_count: int = 0
    int_rat: list[RATEntry] = field(default_factory=list)
    fp_rat: list[RATEntry] = field(default_factory=list)

    def __post_init__(self) -> None:  # noqa: D105
        if not self.int_rat:
            self.int_rat = [RATEntry() for _ in range(NUM_INT_REGS)]
        if not self.fp_rat:
            self.fp_rat = [RATEntry() for _ in range(NUM_FP_REGS)]


class RATModel:
    """Software model of the Register Alias Table.

    This model tracks the expected state of the RAT and provides methods
    to compute expected outputs for test verification.

    Usage:
        model = RATModel()

        # Rename a register
        model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

        # Look up source
        result = model.lookup_int(addr=5, regfile_data=0)
        assert result.renamed
        assert result.tag == 3

        # Commit clear
        model.commit(dest_rf=0, dest_reg=5, tag=3)
        result = model.lookup_int(addr=5, regfile_data=42)
        assert not result.renamed
    """

    def __init__(self) -> None:
        """Initialize RAT model."""
        self.int_rat: list[RATEntry] = [RATEntry() for _ in range(NUM_INT_REGS)]
        self.fp_rat: list[RATEntry] = [RATEntry() for _ in range(NUM_FP_REGS)]
        self.checkpoints: list[CheckpointSlot] = [
            CheckpointSlot() for _ in range(NUM_CHECKPOINTS)
        ]

    # =========================================================================
    # Source Lookup
    # =========================================================================

    def lookup_int(self, addr: int, regfile_data: int) -> LookupResult:
        """Look up an INT source register.

        Args:
            addr: Register address (0-31).
            regfile_data: Current value from the integer regfile.

        Returns:
            LookupResult with renamed flag, tag, and value.
        """
        if addr == 0:
            return LookupResult(renamed=False, tag=0, value=0)

        entry = self.int_rat[addr]
        # Zero-extend XLEN to FLEN
        value = regfile_data & MASK64
        if entry.valid:
            return LookupResult(renamed=True, tag=entry.tag, value=value)
        else:
            return LookupResult(renamed=False, tag=0, value=value)

    def lookup_fp(self, addr: int, regfile_data: int) -> LookupResult:
        """Look up an FP source register.

        Args:
            addr: Register address (0-31).
            regfile_data: Current value from the FP regfile.

        Returns:
            LookupResult with renamed flag, tag, and value.
        """
        entry = self.fp_rat[addr]
        value = regfile_data & MASK64
        if entry.valid:
            return LookupResult(renamed=True, tag=entry.tag, value=value)
        else:
            return LookupResult(renamed=False, tag=0, value=value)

    # =========================================================================
    # Rename Write
    # =========================================================================

    def rename(self, dest_rf: int, dest_reg: int, rob_tag: int) -> None:
        """Write a rename mapping.

        Args:
            dest_rf: 0 = INT, 1 = FP.
            dest_reg: Destination register address.
            rob_tag: ROB tag of the producing instruction.
        """
        if dest_rf == 0:
            if dest_reg == 0:
                return  # x0 writes ignored
            self.int_rat[dest_reg] = RATEntry(valid=True, tag=rob_tag & MASK_TAG)
        else:
            self.fp_rat[dest_reg] = RATEntry(valid=True, tag=rob_tag & MASK_TAG)

    # =========================================================================
    # Commit Clear
    # =========================================================================

    def commit(self, dest_rf: int, dest_reg: int, tag: int) -> None:
        """Clear a RAT entry on commit if the tag matches.

        Args:
            dest_rf: 0 = INT, 1 = FP.
            dest_reg: Destination register address.
            tag: Committing ROB tag.
        """
        if dest_rf == 0:
            if dest_reg == 0:
                return
            entry = self.int_rat[dest_reg]
            if entry.valid and entry.tag == (tag & MASK_TAG):
                entry.valid = False
        else:
            entry = self.fp_rat[dest_reg]
            if entry.valid and entry.tag == (tag & MASK_TAG):
                entry.valid = False

    # =========================================================================
    # Checkpoint Operations
    # =========================================================================

    def checkpoint_save(
        self,
        checkpoint_id: int,
        branch_tag: int,
        ras_tos: int,
        ras_valid_count: int,
    ) -> None:
        """Save current RAT state into a checkpoint slot.

        Args:
            checkpoint_id: Slot index (0-3).
            branch_tag: ROB tag of the branch instruction.
            ras_tos: RAS top-of-stack pointer.
            ras_valid_count: RAS valid entry count.
        """
        slot = self.checkpoints[checkpoint_id]
        slot.valid = True
        slot.branch_tag = branch_tag & MASK_TAG
        slot.ras_tos = ras_tos
        slot.ras_valid_count = ras_valid_count
        # Deep copy current RAT state
        slot.int_rat = [RATEntry(valid=e.valid, tag=e.tag) for e in self.int_rat]
        slot.fp_rat = [RATEntry(valid=e.valid, tag=e.tag) for e in self.fp_rat]

    def checkpoint_restore(self, checkpoint_id: int) -> tuple[int, int]:
        """Restore RAT state from a checkpoint slot.

        Args:
            checkpoint_id: Slot index (0-3).

        Returns:
            Tuple of (ras_tos, ras_valid_count).
        """
        slot = self.checkpoints[checkpoint_id]
        assert slot.valid, f"Restoring from invalid checkpoint {checkpoint_id}"
        # Bulk restore
        self.int_rat = [RATEntry(valid=e.valid, tag=e.tag) for e in slot.int_rat]
        self.fp_rat = [RATEntry(valid=e.valid, tag=e.tag) for e in slot.fp_rat]
        return slot.ras_tos, slot.ras_valid_count

    def checkpoint_free(self, checkpoint_id: int) -> None:
        """Free a checkpoint slot.

        Args:
            checkpoint_id: Slot index (0-3).
        """
        self.checkpoints[checkpoint_id].valid = False

    def checkpoint_available(self) -> tuple[bool, int]:
        """Check if a free checkpoint slot is available.

        Returns:
            Tuple of (available, alloc_id). alloc_id is the lowest free slot.
        """
        for i in range(NUM_CHECKPOINTS):
            if not self.checkpoints[i].valid:
                return True, i
        return False, 0

    # =========================================================================
    # Flush
    # =========================================================================

    def flush_all(self) -> None:
        """Clear all RAT valid bits and checkpoint valid bits."""
        for entry in self.int_rat:
            entry.valid = False
        for entry in self.fp_rat:
            entry.valid = False
        for slot in self.checkpoints:
            slot.valid = False

    # =========================================================================
    # Reset
    # =========================================================================

    def reset(self) -> None:
        """Reset model to initial state."""
        self.int_rat = [RATEntry() for _ in range(NUM_INT_REGS)]
        self.fp_rat = [RATEntry() for _ in range(NUM_FP_REGS)]
        self.checkpoints = [CheckpointSlot() for _ in range(NUM_CHECKPOINTS)]

    # =========================================================================
    # Debug
    # =========================================================================

    def dump_state(self) -> str:
        """Return string representation of current state."""
        lines = ["RATModel State:"]

        # INT RAT
        renamed_int = [(i, e) for i, e in enumerate(self.int_rat) if e.valid]
        if renamed_int:
            lines.append("  INT RAT (renamed):")
            for i, e in renamed_int:
                lines.append(f"    x{i} -> ROB[{e.tag}]")
        else:
            lines.append("  INT RAT: all clear")

        # FP RAT
        renamed_fp = [(i, e) for i, e in enumerate(self.fp_rat) if e.valid]
        if renamed_fp:
            lines.append("  FP RAT (renamed):")
            for i, e in renamed_fp:
                lines.append(f"    f{i} -> ROB[{e.tag}]")
        else:
            lines.append("  FP RAT: all clear")

        # Checkpoints
        active = [(i, s) for i, s in enumerate(self.checkpoints) if s.valid]
        if active:
            lines.append(f"  Checkpoints ({len(active)} active):")
            for i, s in active:
                lines.append(f"    [{i}] branch_tag={s.branch_tag}")
        else:
            lines.append("  Checkpoints: all free")

        return "\n".join(lines)

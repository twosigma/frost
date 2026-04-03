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

"""DUT interface for Register Alias Table verification.

Provides clean access to RAT signals with proper typing and
helper methods for driving stimulus and reading outputs.

Note: Verilator flattens packed structs into single bit vectors.
This interface handles packing/unpacking struct fields automatically.
"""

from typing import Any
from cocotb.triggers import RisingEdge, FallingEdge

from .rat_model import LookupResult, MASK32, MASK64, MASK_TAG, MASK_REG, RATModel

# =============================================================================
# Struct Bit Field Definitions
# =============================================================================
# rat_lookup_t (70 bits, MSB-first):
#   [69]    renamed
#   [68:64]  tag (5 bits)
#   [63:0]   value (64 bits)
RAT_LOOKUP_WIDTH = 70


def unpack_rat_lookup(val: int) -> LookupResult:
    """Unpack rat_lookup_t packed struct into LookupResult."""
    value = val & MASK64
    tag = (val >> 64) & MASK_TAG
    renamed = bool((val >> 69) & 1)
    return LookupResult(renamed=renamed, tag=tag, value=value)


COMMIT_FIELDS = [
    ("valid", 1),
    ("tag", 5),
    ("dest_rf", 1),
    ("dest_reg", 5),
    ("dest_valid", 1),
    ("value", 64),
    ("is_store", 1),
    ("is_fp_store", 1),
    ("exception", 1),
    ("pc", 32),
    ("exc_cause", 5),
    ("fp_flags", 5),
    ("has_fp_flags", 1),
    ("misprediction", 1),
    ("has_checkpoint", 1),
    ("checkpoint_id", 2),
    ("redirect_pc", 32),
    ("predicted_taken", 1),
    ("branch_taken", 1),
    ("branch_target", 32),
    ("is_branch", 1),
    ("is_call", 1),
    ("is_return", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("csr_addr", 12),
    ("csr_op", 3),
    ("csr_write_data", 32),
    ("is_csr", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_wfi", 1),
    ("is_mret", 1),
    ("is_amo", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_compressed", 1),
]
COMMIT_WIDTH = sum(width for _, width in COMMIT_FIELDS)

_COMMIT_OFFSETS: dict[str, tuple[int, int]] = {}
_offset = COMMIT_WIDTH
for _name, _width in COMMIT_FIELDS:
    _offset -= _width
    _COMMIT_OFFSETS[_name] = (_offset, _width)
assert _offset == 0


def pack_commit(
    valid: bool = False,
    tag: int = 0,
    dest_rf: int = 0,
    dest_reg: int = 0,
    dest_valid: bool = False,
) -> int:
    """Pack a commit struct for driving i_commit.

    Only sets the fields the RAT cares about; all others are 0.
    """
    val = 0
    valid_offset, _ = _COMMIT_OFFSETS["valid"]
    tag_offset, _ = _COMMIT_OFFSETS["tag"]
    dest_rf_offset, _ = _COMMIT_OFFSETS["dest_rf"]
    dest_reg_offset, _ = _COMMIT_OFFSETS["dest_reg"]
    dest_valid_offset, _ = _COMMIT_OFFSETS["dest_valid"]

    if valid:
        val |= 1 << valid_offset
    val |= (tag & MASK_TAG) << tag_offset
    val |= (dest_rf & 1) << dest_rf_offset
    val |= (dest_reg & MASK_REG) << dest_reg_offset
    if dest_valid:
        val |= 1 << dest_valid_offset
    return val


def pack_commit_invalid() -> int:
    """Pack an invalid commit (valid=0)."""
    return 0


class RATInterface:
    """Interface to Register Alias Table DUT.

    Handles packing/unpacking of struct signals automatically since
    Verilator flattens packed structs into single bit vectors.
    """

    def __init__(self, dut: Any):
        """Initialize interface with DUT handle."""
        self.dut = dut
        self._shadow_rat = RATModel()
        self._rob_tag_refcounts = [0] * (MASK_TAG + 1)
        self._pending_rename: tuple[int, int, int] | None = None
        self._pending_commit: tuple[int, int, int, bool] | None = None
        self._pending_checkpoint_save: tuple[int, int, int, int] | None = None
        self._pending_checkpoint_restore: int | None = None
        self._pending_checkpoint_free: int | None = None
        self._pending_flush_all = False

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
        await FallingEdge(self.clock)

    async def wait_falling(self) -> None:
        """Wait for falling edge - use this before driving inputs."""
        await FallingEdge(self.clock)

    async def wait_rising(self) -> None:
        """Wait for rising edge - use this before sampling outputs."""
        await RisingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: rising edge then falling edge."""
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _init_inputs(self) -> None:
        """Initialize all input signals to default values."""
        self._shadow_rat = RATModel()
        self._rob_tag_refcounts = [0] * (MASK_TAG + 1)
        self._pending_rename = None
        self._pending_commit = None
        self._pending_checkpoint_save = None
        self._pending_checkpoint_restore = None
        self._pending_checkpoint_free = None
        self._pending_flush_all = False

        # Source lookup addresses
        self.dut.i_int_src1_addr.value = 0
        self.dut.i_int_src2_addr.value = 0
        self.dut.i_fp_src1_addr.value = 0
        self.dut.i_fp_src2_addr.value = 0
        self.dut.i_fp_src3_addr.value = 0

        # Regfile data
        self.dut.i_int_regfile_data1.value = 0
        self.dut.i_int_regfile_data2.value = 0
        self.dut.i_fp_regfile_data1.value = 0
        self.dut.i_fp_regfile_data2.value = 0
        self.dut.i_fp_regfile_data3.value = 0

        # Rename write
        self.dut.i_alloc_valid.value = 0
        self.dut.i_alloc_dest_rf.value = 0
        self.dut.i_alloc_dest_reg.value = 0
        self.dut.i_alloc_rob_tag.value = 0

        # Commit
        self.dut.i_commit.value = 0

        # Checkpoint save
        self.dut.i_checkpoint_save.value = 0
        self.dut.i_checkpoint_id.value = 0
        self.dut.i_checkpoint_branch_tag.value = 0
        self.dut.i_ras_tos.value = 0
        self.dut.i_ras_valid_count.value = 0

        # Checkpoint restore
        self.dut.i_checkpoint_restore.value = 0
        self.dut.i_checkpoint_restore_id.value = 0
        self.dut.i_checkpoint_restore_reclaim_all.value = 0

        # Checkpoint free
        self.dut.i_checkpoint_free.value = 0
        self.dut.i_checkpoint_free_id.value = 0

        # Flush
        self.dut.i_flush_all.value = 0
        self._drive_rob_entry_valid()

    def _drive_rob_entry_valid(self) -> None:
        """Drive the synthetic ROB-valid vector used by standalone RAT tests."""
        rob_valid_mask = 0
        for tag, refcount in enumerate(self._rob_tag_refcounts):
            if refcount > 0:
                rob_valid_mask |= 1 << tag
        self.dut.i_rob_entry_valid.value = rob_valid_mask

    def _apply_pending_cycle_updates(self) -> None:
        """Apply queued same-cycle effects to the synthetic ROB-valid vector."""
        if (
            self._pending_rename is None
            and self._pending_commit is None
            and self._pending_checkpoint_save is None
            and self._pending_checkpoint_restore is None
            and self._pending_checkpoint_free is None
            and not self._pending_flush_all
        ):
            return

        if self._pending_flush_all:
            self._shadow_rat.flush_all()
            self._rob_tag_refcounts = [0] * (MASK_TAG + 1)
        elif self._pending_checkpoint_restore is not None:
            self._shadow_rat.checkpoint_restore(self._pending_checkpoint_restore)
        else:
            if self._pending_checkpoint_save is not None:
                checkpoint_id, branch_tag, ras_tos, ras_valid_count = (
                    self._pending_checkpoint_save
                )
                self._shadow_rat.checkpoint_save(
                    checkpoint_id, branch_tag, ras_tos, ras_valid_count
                )

            if self._pending_checkpoint_free is not None:
                self._shadow_rat.checkpoint_free(self._pending_checkpoint_free)

            if self._pending_commit is not None:
                commit_tag, commit_dest_rf, commit_dest_reg, commit_dest_valid = (
                    self._pending_commit
                )
                if commit_dest_valid:
                    if commit_dest_rf == 0:
                        if commit_dest_reg != 0:
                            entry = self._shadow_rat.int_rat[commit_dest_reg]
                            if entry.valid and entry.tag == commit_tag:
                                self._shadow_rat.commit(
                                    commit_dest_rf, commit_dest_reg, commit_tag
                                )
                                if self._rob_tag_refcounts[commit_tag] > 0:
                                    self._rob_tag_refcounts[commit_tag] -= 1
                    else:
                        entry = self._shadow_rat.fp_rat[commit_dest_reg]
                        if entry.valid and entry.tag == commit_tag:
                            self._shadow_rat.commit(
                                commit_dest_rf, commit_dest_reg, commit_tag
                            )
                            if self._rob_tag_refcounts[commit_tag] > 0:
                                self._rob_tag_refcounts[commit_tag] -= 1

            if self._pending_rename is not None:
                dest_rf, dest_reg, rob_tag = self._pending_rename
                self._shadow_rat.rename(dest_rf, dest_reg, rob_tag)
                if not (dest_rf == 0 and dest_reg == 0):
                    self._rob_tag_refcounts[rob_tag] += 1

        self._drive_rob_entry_valid()
        self._pending_rename = None
        self._pending_commit = None
        self._pending_checkpoint_save = None
        self._pending_checkpoint_restore = None
        self._pending_checkpoint_free = None
        self._pending_flush_all = False

    # =========================================================================
    # Source Lookup Interface (combinational)
    # =========================================================================

    def set_int_src1(self, addr: int, regfile_data: int) -> None:
        """Set INT source 1 lookup inputs."""
        self.dut.i_int_src1_addr.value = addr & MASK_REG
        self.dut.i_int_regfile_data1.value = regfile_data & MASK32

    def set_int_src2(self, addr: int, regfile_data: int) -> None:
        """Set INT source 2 lookup inputs."""
        self.dut.i_int_src2_addr.value = addr & MASK_REG
        self.dut.i_int_regfile_data2.value = regfile_data & MASK32

    def set_fp_src1(self, addr: int, regfile_data: int) -> None:
        """Set FP source 1 lookup inputs."""
        self.dut.i_fp_src1_addr.value = addr & MASK_REG
        self.dut.i_fp_regfile_data1.value = regfile_data & MASK64

    def set_fp_src2(self, addr: int, regfile_data: int) -> None:
        """Set FP source 2 lookup inputs."""
        self.dut.i_fp_src2_addr.value = addr & MASK_REG
        self.dut.i_fp_regfile_data2.value = regfile_data & MASK64

    def set_fp_src3(self, addr: int, regfile_data: int) -> None:
        """Set FP source 3 lookup inputs."""
        self.dut.i_fp_src3_addr.value = addr & MASK_REG
        self.dut.i_fp_regfile_data3.value = regfile_data & MASK64

    def read_int_src1(self) -> LookupResult:
        """Read INT source 1 lookup result."""
        return unpack_rat_lookup(int(self.dut.o_int_src1.value))

    def read_int_src2(self) -> LookupResult:
        """Read INT source 2 lookup result."""
        return unpack_rat_lookup(int(self.dut.o_int_src2.value))

    def read_fp_src1(self) -> LookupResult:
        """Read FP source 1 lookup result."""
        return unpack_rat_lookup(int(self.dut.o_fp_src1.value))

    def read_fp_src2(self) -> LookupResult:
        """Read FP source 2 lookup result."""
        return unpack_rat_lookup(int(self.dut.o_fp_src2.value))

    def read_fp_src3(self) -> LookupResult:
        """Read FP source 3 lookup result."""
        return unpack_rat_lookup(int(self.dut.o_fp_src3.value))

    # =========================================================================
    # Rename Write Interface
    # =========================================================================

    def drive_rename(self, dest_rf: int, dest_reg: int, rob_tag: int) -> None:
        """Drive rename write signals."""
        self.dut.i_alloc_valid.value = 1
        self.dut.i_alloc_dest_rf.value = dest_rf & 1
        self.dut.i_alloc_dest_reg.value = dest_reg & MASK_REG
        self.dut.i_alloc_rob_tag.value = rob_tag & MASK_TAG
        self._pending_rename = (dest_rf & 1, dest_reg & MASK_REG, rob_tag & MASK_TAG)

    def clear_rename(self) -> None:
        """Clear rename write signals."""
        self.dut.i_alloc_valid.value = 0
        self._apply_pending_cycle_updates()

    async def rename(self, dest_rf: int, dest_reg: int, rob_tag: int) -> None:
        """Perform rename transaction: drive on falling, wait rising+falling, clear."""
        await FallingEdge(self.clock)
        self.drive_rename(dest_rf, dest_reg, rob_tag)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_rename()

    # =========================================================================
    # Commit Interface
    # =========================================================================

    def drive_commit(
        self, tag: int, dest_rf: int, dest_reg: int, dest_valid: bool = True
    ) -> None:
        """Drive commit signals."""
        self.dut.i_commit.value = pack_commit(
            valid=True,
            tag=tag,
            dest_rf=dest_rf,
            dest_reg=dest_reg,
            dest_valid=dest_valid,
        )
        self._pending_commit = (
            tag & MASK_TAG,
            dest_rf & 1,
            dest_reg & MASK_REG,
            dest_valid,
        )

    def clear_commit(self) -> None:
        """Clear commit signals."""
        self.dut.i_commit.value = 0
        self._apply_pending_cycle_updates()

    async def commit(
        self, tag: int, dest_rf: int, dest_reg: int, dest_valid: bool = True
    ) -> None:
        """Perform commit transaction."""
        await FallingEdge(self.clock)
        self.drive_commit(tag, dest_rf, dest_reg, dest_valid)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_commit()

    # =========================================================================
    # Checkpoint Save Interface
    # =========================================================================

    def drive_checkpoint_save(
        self,
        checkpoint_id: int,
        branch_tag: int,
        ras_tos: int = 0,
        ras_valid_count: int = 0,
    ) -> None:
        """Drive checkpoint save signals."""
        self.dut.i_checkpoint_save.value = 1
        self.dut.i_checkpoint_id.value = checkpoint_id & 0x3
        self.dut.i_checkpoint_branch_tag.value = branch_tag & MASK_TAG
        self.dut.i_ras_tos.value = ras_tos & 0x7
        self.dut.i_ras_valid_count.value = ras_valid_count & 0xF
        self._pending_checkpoint_save = (
            checkpoint_id & 0x3,
            branch_tag & MASK_TAG,
            ras_tos & 0x7,
            ras_valid_count & 0xF,
        )

    def clear_checkpoint_save(self) -> None:
        """Clear checkpoint save signals."""
        self.dut.i_checkpoint_save.value = 0
        self._apply_pending_cycle_updates()

    async def checkpoint_save(
        self,
        checkpoint_id: int,
        branch_tag: int,
        ras_tos: int = 0,
        ras_valid_count: int = 0,
    ) -> None:
        """Perform checkpoint save transaction."""
        await FallingEdge(self.clock)
        self.drive_checkpoint_save(checkpoint_id, branch_tag, ras_tos, ras_valid_count)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_checkpoint_save()

    # =========================================================================
    # Checkpoint Restore Interface
    # =========================================================================

    def drive_checkpoint_restore(self, checkpoint_id: int) -> None:
        """Drive checkpoint restore signals."""
        self.dut.i_checkpoint_restore.value = 1
        self.dut.i_checkpoint_restore_id.value = checkpoint_id & 0x3
        self.dut.i_checkpoint_restore_reclaim_all.value = 0
        self._pending_checkpoint_restore = checkpoint_id & 0x3

    def clear_checkpoint_restore(self) -> None:
        """Clear checkpoint restore signals."""
        self.dut.i_checkpoint_restore.value = 0
        self.dut.i_checkpoint_restore_id.value = 0
        self.dut.i_checkpoint_restore_reclaim_all.value = 0
        self._apply_pending_cycle_updates()

    async def checkpoint_restore(self, checkpoint_id: int) -> tuple[int, int]:
        """Perform checkpoint restore transaction.

        Returns (ras_tos, ras_valid_count).
        """
        await FallingEdge(self.clock)
        self.drive_checkpoint_restore(checkpoint_id)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_checkpoint_restore()
        return self.ras_tos, self.ras_valid_count

    # =========================================================================
    # Checkpoint Free Interface
    # =========================================================================

    def drive_checkpoint_free(self, checkpoint_id: int) -> None:
        """Drive checkpoint free signals."""
        self.dut.i_checkpoint_free.value = 1
        self.dut.i_checkpoint_free_id.value = checkpoint_id & 0x3
        self._pending_checkpoint_free = checkpoint_id & 0x3

    def clear_checkpoint_free(self) -> None:
        """Clear checkpoint free signals."""
        self.dut.i_checkpoint_free.value = 0
        self._apply_pending_cycle_updates()

    async def checkpoint_free(self, checkpoint_id: int) -> None:
        """Perform checkpoint free transaction."""
        await FallingEdge(self.clock)
        self.drive_checkpoint_free(checkpoint_id)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_checkpoint_free()

    # =========================================================================
    # Flush Interface
    # =========================================================================

    def drive_flush_all(self) -> None:
        """Drive full flush signal."""
        self.dut.i_flush_all.value = 1
        self._pending_flush_all = True

    def clear_flush_all(self) -> None:
        """Clear full flush signal."""
        self.dut.i_flush_all.value = 0
        self._apply_pending_cycle_updates()

    async def flush_all(self) -> None:
        """Perform full flush transaction."""
        await FallingEdge(self.clock)
        self.drive_flush_all()
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_flush_all()

    # =========================================================================
    # Checkpoint Availability Outputs
    # =========================================================================

    @property
    def checkpoint_available(self) -> bool:
        """Check if a checkpoint slot is available."""
        return bool(self.dut.o_checkpoint_available.value)

    @property
    def checkpoint_alloc_id(self) -> int:
        """Get the next free checkpoint ID."""
        return int(self.dut.o_checkpoint_alloc_id.value)

    # =========================================================================
    # RAS Restore Outputs
    # =========================================================================

    @property
    def ras_tos(self) -> int:
        """Get restored RAS top-of-stack pointer."""
        return int(self.dut.o_ras_tos.value)

    @property
    def ras_valid_count(self) -> int:
        """Get restored RAS valid count."""
        return int(self.dut.o_ras_valid_count.value)

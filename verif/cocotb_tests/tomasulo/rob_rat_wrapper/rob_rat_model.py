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

"""Composed ROB + RAT golden model for integration verification.

Imports and composes the individual ReorderBufferModel and RATModel,
wiring the commit bus internally (mirroring the RTL wrapper).
"""

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
    ReorderBufferModel,
)
from cocotb_tests.tomasulo.register_alias_table.rat_model import (
    LookupResult,
    RATModel,
)


class RobRatModel:
    """Composed ROB + RAT model mirroring rob_rat_wrapper RTL.

    The commit bus is internal: when the ROB commits, the commit output
    is automatically propagated to the RAT's commit interface.
    """

    def __init__(self) -> None:
        """Initialize composed ROB and RAT models."""
        self.rob = ReorderBufferModel()
        self.rat = RATModel()

    def reset(self) -> None:
        """Reset both models."""
        self.rob.reset()
        self.rat.reset()

    def dispatch(
        self,
        req: AllocationRequest,
        checkpoint_save: bool = False,
        ras_tos: int = 0,
        ras_valid_count: int = 0,
    ) -> int | None:
        """Dispatch an instruction: ROB allocate + RAT rename + optional checkpoint.

        Returns the allocated ROB tag, or None if ROB is full.
        """
        tag = self.rob.allocate(req)
        if tag is None:
            return None

        # Rename in RAT if instruction has a destination
        if req.dest_valid:
            self.rat.rename(req.dest_rf, req.dest_reg, tag)

        # Checkpoint save if requested (for branches)
        if checkpoint_save:
            avail, cp_id = self.rat.checkpoint_available()
            if avail:
                self.rat.checkpoint_save(cp_id, tag, ras_tos, ras_valid_count)
                self.rob.set_checkpoint(tag, cp_id)
                return tag

        return tag

    def try_commit(self) -> dict | None:
        """Try to commit the head entry.

        If the ROB can commit, commits and propagates to the RAT.
        Returns the commit info dict, or None if nothing to commit.
        """
        if not self.rob.can_commit():
            return None

        expected = self.rob.commit()

        # Propagate commit to RAT (the hardwired commit bus)
        if expected.valid and expected.dest_valid:
            self.rat.commit(expected.dest_rf, expected.dest_reg, expected.tag)

        return {
            "valid": expected.valid,
            "tag": expected.tag,
            "dest_rf": expected.dest_rf,
            "dest_reg": expected.dest_reg,
            "dest_valid": expected.dest_valid,
            "value": expected.value,
            "has_checkpoint": expected.has_checkpoint,
            "checkpoint_id": expected.checkpoint_id,
            "misprediction": expected.misprediction,
        }

    def cdb_write(self, write: CDBWrite) -> None:
        """CDB write to ROB."""
        self.rob.cdb_write(write)

    def branch_update(self, update: BranchUpdate) -> None:
        """Branch resolution update to ROB."""
        self.rob.branch_update(update)

    def misprediction_recovery(self, checkpoint_id: int, flush_tag: int) -> None:
        """Handle misprediction: partial ROB flush + RAT checkpoint restore."""
        self.rob.flush_partial(flush_tag)
        self.rat.checkpoint_restore(checkpoint_id)

    def flush_all(self) -> None:
        """Full flush of both ROB and RAT."""
        self.rob.flush_all()
        self.rat.flush_all()

    def lookup_int(self, addr: int, regfile_data: int) -> LookupResult:
        """INT source lookup via RAT."""
        return self.rat.lookup_int(addr, regfile_data)

    def lookup_fp(self, addr: int, regfile_data: int) -> LookupResult:
        """FP source lookup via RAT."""
        return self.rat.lookup_fp(addr, regfile_data)

    def checkpoint_available(self) -> tuple[bool, int]:
        """Check RAT checkpoint availability."""
        return self.rat.checkpoint_available()

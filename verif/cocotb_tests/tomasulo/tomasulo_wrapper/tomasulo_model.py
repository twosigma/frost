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

"""Composed ROB + RAT + multi-RS golden model for integration verification.

Imports and composes the individual models, wiring the commit bus internally
(mirroring the RTL wrapper). Models six RS instances with dispatch routing
based on rs_type.
"""

from typing import Any

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
from cocotb_tests.tomasulo.reservation_station.rs_model import (
    RSModel,
)
from cocotb_tests.tomasulo.cdb_arbiter.cdb_arbiter_model import (
    FU_ALU,
)

# RS type constants (mirrors riscv_pkg::rs_type_e)
RS_INT = 0
RS_MUL = 1
RS_MEM = 2
RS_FP = 3
RS_FMUL = 4
RS_FDIV = 5
RS_NONE = 6

# RS depths (mirrors riscv_pkg parameters)
RS_DEPTHS = {
    RS_INT: 8,
    RS_MUL: 4,
    RS_MEM: 8,
    RS_FP: 6,
    RS_FMUL: 4,
    RS_FDIV: 2,
}


class TomasuloModel:
    """Composed ROB + RAT + multi-RS model mirroring tomasulo_wrapper RTL."""

    def __init__(self) -> None:
        """Initialize composed ROB + RAT + 6 RS model."""
        self.rob = ReorderBufferModel()
        self.rat = RATModel()

        # Six RS instances matching RTL parameterization
        self.int_rs = RSModel(depth=RS_DEPTHS[RS_INT])
        self.mul_rs = RSModel(depth=RS_DEPTHS[RS_MUL])
        self.mem_rs = RSModel(depth=RS_DEPTHS[RS_MEM])
        self.fp_rs = RSModel(depth=RS_DEPTHS[RS_FP])
        self.fmul_rs = RSModel(depth=RS_DEPTHS[RS_FMUL])
        self.fdiv_rs = RSModel(depth=RS_DEPTHS[RS_FDIV])

        self._rs_map: dict[int, RSModel] = {
            RS_INT: self.int_rs,
            RS_MUL: self.mul_rs,
            RS_MEM: self.mem_rs,
            RS_FP: self.fp_rs,
            RS_FMUL: self.fmul_rs,
            RS_FDIV: self.fdiv_rs,
        }

        # Backward compat: self.rs aliases INT_RS
        self.rs = self.int_rs

    def _all_rs(self) -> list[RSModel]:
        """Return all RS models."""
        return list(self._rs_map.values())

    def get_rs(self, rs_type: int) -> RSModel:
        """Return the RS model for the given type."""
        return self._rs_map[rs_type]

    def reset(self) -> None:
        """Reset all sub-models."""
        self.rob.reset()
        self.rat.reset()
        for rs in self._all_rs():
            rs.reset()

    def dispatch(
        self,
        req: AllocationRequest,
        checkpoint_save: bool = False,
        ras_tos: int = 0,
        ras_valid_count: int = 0,
    ) -> int | None:
        """Dispatch: ROB allocate + RAT rename + optional checkpoint.

        Returns the allocated ROB tag, or None if ROB is full.
        """
        tag = self.rob.allocate(req)
        if tag is None:
            return None

        if req.dest_valid:
            self.rat.rename(req.dest_rf, req.dest_reg, tag)

        if checkpoint_save:
            avail, cp_id = self.rat.checkpoint_available()
            if avail:
                self.rat.checkpoint_save(cp_id, tag, ras_tos, ras_valid_count)
                self.rob.set_checkpoint(tag, cp_id)
                return tag

        return tag

    def try_commit(self) -> dict | None:
        """Try to commit the head entry, propagating to RAT."""
        if not self.rob.can_commit():
            return None

        expected = self.rob.commit()

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

    def fu_complete(
        self,
        fu_index: int = FU_ALU,
        tag: int = 0,
        value: int = 0,
        exception: bool = False,
        exc_cause: int = 0,
        fp_flags: int = 0,
    ) -> None:
        """Simulate FU completion through CDB arbiter → ROB + all RS.

        With the CDB arbiter inside the wrapper, any FU completion broadcasts
        to both ROB (cdb_write) and all RS (cdb_snoop). Tests drive one FU at
        a time, so the arbiter always grants immediately.

        Tolerant of writes to invalid ROB entries (RTL silently ignores).
        """
        try:
            self.rob.cdb_write(
                CDBWrite(
                    tag=tag,
                    value=value,
                    exception=exception,
                    exc_cause=exc_cause,
                    fp_flags=fp_flags,
                )
            )
        except ValueError:
            pass  # RTL silently ignores CDB to invalid ROB entries
        for rs in self._all_rs():
            rs.cdb_snoop(tag, value)

    # Backward-compat: old methods now route through fu_complete
    def cdb_write(self, write: CDBWrite) -> None:
        """CDB write to ROB + snoop all RS (arbiter always broadcasts both)."""
        self.fu_complete(
            FU_ALU,
            tag=write.tag,
            value=write.value,
            exception=write.exception,
            exc_cause=write.exc_cause,
            fp_flags=write.fp_flags,
        )

    def cdb_snoop(self, tag: int, value: int) -> None:
        """CDB snoop + ROB write (arbiter always broadcasts both)."""
        self.fu_complete(FU_ALU, tag=tag, value=value)

    def cdb_write_and_snoop(
        self,
        tag: int,
        value: int = 0,
        exception: bool = False,
        exc_cause: int = 0,
        fp_flags: int = 0,
    ) -> None:
        """Write CDB to ROB and snoop to all RS (backward compat)."""
        self.fu_complete(
            FU_ALU,
            tag=tag,
            value=value,
            exception=exception,
            exc_cause=exc_cause,
            fp_flags=fp_flags,
        )

    def rs_dispatch(self, rs_type: int = RS_INT, **kwargs: Any) -> int | None:
        """Dispatch an instruction to the specified RS type."""
        rs = self._rs_map.get(rs_type)
        if rs is None:
            return None
        return rs.dispatch(**kwargs)

    def rs_try_issue(self, rs_type: int = RS_INT, fu_ready: bool = True) -> dict | None:
        """Try to issue from the specified RS type."""
        rs = self._rs_map.get(rs_type)
        if rs is None:
            return None
        return rs.try_issue(fu_ready)

    def branch_update(self, update: BranchUpdate) -> None:
        """Forward branch update to ROB."""
        self.rob.branch_update(update)

    def misprediction_recovery(self, checkpoint_id: int, flush_tag: int) -> None:
        """Partial flush of ROB + all RS, restore RAT checkpoint."""
        self.rob.flush_partial(flush_tag)
        for rs in self._all_rs():
            rs.partial_flush(flush_tag, self.rob.head_idx)
        self.rat.checkpoint_restore(checkpoint_id)

    def flush_all(self) -> None:
        """Full flush of all modules."""
        self.rob.flush_all()
        self.rat.flush_all()
        for rs in self._all_rs():
            rs.flush_all()

    def lookup_int(self, addr: int, regfile_data: int) -> LookupResult:
        """Look up integer register in RAT."""
        return self.rat.lookup_int(addr, regfile_data)

    def lookup_fp(self, addr: int, regfile_data: int) -> LookupResult:
        """Look up FP register in RAT."""
        return self.rat.lookup_fp(addr, regfile_data)

    def checkpoint_available(self) -> tuple[bool, int]:
        """Return whether a checkpoint slot is available."""
        return self.rat.checkpoint_available()

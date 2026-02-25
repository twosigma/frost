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

"""DUT interface for Tomasulo integration wrapper verification.

Reuses packing/unpacking functions from ROB, RAT, and RS interfaces.
Adds compound dispatch method that coordinates ROB alloc + RAT rename + RS dispatch.
Supports six RS instances with per-RS issue/status/fu_ready access.

When running with the Icarus VPI-safe testbench wrapper
(tomasulo_wrapper_tb), the RS dispatch and issue ports are individual
scalar signals instead of wide packed struct ports. The interface
detects this automatically via ``hasattr(dut, 'i_rs_dispatch_valid')``.
"""

from typing import Any
from cocotb.triggers import RisingEdge, FallingEdge

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_interface import (
    pack_alloc_request,
    unpack_alloc_response,
    pack_branch_update,
    unpack_commit,
)
from cocotb_tests.tomasulo.register_alias_table.rat_interface import (
    unpack_rat_lookup,
)
from cocotb_tests.tomasulo.reservation_station.rs_interface import (
    pack_rs_dispatch,
    unpack_rs_issue,
    MASK_TAG,
    MASK32,
    MASK64,
)
from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
)
from cocotb_tests.tomasulo.register_alias_table.rat_model import (
    LookupResult,
    MASK_REG,
)
from cocotb_tests.tomasulo.cdb_arbiter.cdb_arbiter_interface import (
    pack_fu_complete,
    unpack_cdb_broadcast,
)
from cocotb_tests.tomasulo.cdb_arbiter.cdb_arbiter_model import (
    FuComplete,
    CdbBroadcast,
    NUM_FUS,
    FU_ALU,
)

# RS type constants (mirrors riscv_pkg::rs_type_e)
RS_INT = 0
RS_MUL = 1
RS_MEM = 2
RS_FP = 3
RS_FMUL = 4
RS_FDIV = 5

# Per-RS DUT signal names for issue, fu_ready, full, empty, count.
# INT_RS uses the backward-compatible names (o_rs_issue, i_rs_fu_ready, etc.).
# o_rs_full is a dispatch-target mux; o_int_rs_full is the dedicated INT_RS full.
_RS_SIGNAL_MAP = {
    RS_INT: {
        "issue": "o_rs_issue",
        "fu_ready": "i_rs_fu_ready",
        "full": "o_int_rs_full",
        "empty": "o_rs_empty",
        "count": "o_rs_count",
    },
    RS_MUL: {
        "issue": "o_mul_rs_issue",
        "fu_ready": "i_mul_rs_fu_ready",
        "full": "o_mul_rs_full",
        "empty": "o_mul_rs_empty",
        "count": "o_mul_rs_count",
    },
    RS_MEM: {
        "issue": "o_mem_rs_issue",
        "fu_ready": "i_mem_rs_fu_ready",
        "full": "o_mem_rs_full",
        "empty": "o_mem_rs_empty",
        "count": "o_mem_rs_count",
    },
    RS_FP: {
        "issue": "o_fp_rs_issue",
        "fu_ready": "i_fp_rs_fu_ready",
        "full": "o_fp_rs_full",
        "empty": "o_fp_rs_empty",
        "count": "o_fp_rs_count",
    },
    RS_FMUL: {
        "issue": "o_fmul_rs_issue",
        "fu_ready": "i_fmul_rs_fu_ready",
        "full": "o_fmul_rs_full",
        "empty": "o_fmul_rs_empty",
        "count": "o_fmul_rs_count",
    },
    RS_FDIV: {
        "issue": "o_fdiv_rs_issue",
        "fu_ready": "i_fdiv_rs_fu_ready",
        "full": "o_fdiv_rs_full",
        "empty": "o_fdiv_rs_empty",
        "count": "o_fdiv_rs_count",
    },
}


class TomasuloInterface:
    """Interface to the Tomasulo integration wrapper DUT.

    Automatically detects whether the DUT has flattened RS ports (Icarus
    testbench wrapper) or packed struct ports (Verilator / direct module).
    """

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut
        # Icarus tb wrapper exposes individual RS dispatch/issue ports.
        # Only INT_RS is available under ICARUS; multi-RS tests must be skipped.
        self._flat_rs = hasattr(dut, "i_rs_dispatch_valid")

    @property
    def is_icarus(self) -> bool:
        """Return True if running with Icarus (flat RS ports, INT_RS only)."""
        return self._flat_rs

    # =========================================================================
    # Clock and Reset
    # =========================================================================

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    async def reset_dut(self, cycles: int = 5) -> None:
        """Reset the DUT and init all inputs."""
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: rising edge then falling edge."""
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _init_inputs(self) -> None:
        """Initialize all input signals to safe defaults."""
        # ROB allocation
        self.dut.i_alloc_req.value = 0

        # FU completion requests (to CDB arbiter)
        self.clear_all_fu_completes()

        # ROB branch
        self.dut.i_branch_update.value = 0

        # ROB checkpoint recording
        self.dut.i_rob_checkpoint_valid.value = 0
        self.dut.i_rob_checkpoint_id.value = 0

        # ROB external coordination
        self.dut.i_sq_empty.value = 1
        self.dut.i_csr_done.value = 0
        self.dut.i_trap_taken.value = 0
        self.dut.i_mret_done.value = 0
        self.dut.i_mepc.value = 0
        self.dut.i_interrupt_pending.value = 0

        # Flush
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_flush_all.value = 0

        # ROB bypass read
        self.dut.i_read_tag.value = 0

        # RAT source lookup addresses
        self.dut.i_int_src1_addr.value = 0
        self.dut.i_int_src2_addr.value = 0
        self.dut.i_fp_src1_addr.value = 0
        self.dut.i_fp_src2_addr.value = 0
        self.dut.i_fp_src3_addr.value = 0

        # RAT regfile data
        self.dut.i_int_regfile_data1.value = 0
        self.dut.i_int_regfile_data2.value = 0
        self.dut.i_fp_regfile_data1.value = 0
        self.dut.i_fp_regfile_data2.value = 0
        self.dut.i_fp_regfile_data3.value = 0

        # RAT rename
        self.dut.i_rat_alloc_valid.value = 0
        self.dut.i_rat_alloc_dest_rf.value = 0
        self.dut.i_rat_alloc_dest_reg.value = 0
        self.dut.i_rat_alloc_rob_tag.value = 0

        # RAT checkpoint save
        self.dut.i_checkpoint_save.value = 0
        self.dut.i_checkpoint_id.value = 0
        self.dut.i_checkpoint_branch_tag.value = 0
        self.dut.i_ras_tos.value = 0
        self.dut.i_ras_valid_count.value = 0

        # RAT checkpoint restore
        self.dut.i_checkpoint_restore.value = 0
        self.dut.i_checkpoint_restore_id.value = 0

        # RAT checkpoint free
        self.dut.i_checkpoint_free.value = 0
        self.dut.i_checkpoint_free_id.value = 0

        # RS dispatch
        if self._flat_rs:
            self._clear_rs_dispatch_flat()
        else:
            self.dut.i_rs_dispatch.value = 0

        # Per-RS FU ready signals
        self.dut.i_rs_fu_ready.value = 0
        if not self._flat_rs:
            self.dut.i_mul_rs_fu_ready.value = 0
            self.dut.i_mem_rs_fu_ready.value = 0
            self.dut.i_fp_rs_fu_ready.value = 0
            self.dut.i_fmul_rs_fu_ready.value = 0
            self.dut.i_fdiv_rs_fu_ready.value = 0

    # =========================================================================
    # ROB Allocation
    # =========================================================================

    def drive_alloc_request(self, req: AllocationRequest) -> None:
        """Drive ROB allocation request."""
        self.dut.i_alloc_req.value = pack_alloc_request(req)

    def clear_alloc_request(self) -> None:
        """Clear ROB allocation request."""
        self.dut.i_alloc_req.value = 0

    def read_alloc_response(self) -> tuple[bool, int, bool]:
        """Read ROB allocation response."""
        val = int(self.dut.o_alloc_resp.value)
        return unpack_alloc_response(val)

    # =========================================================================
    # FU Completion (drives CDB arbiter, which feeds ROB + all RS)
    # =========================================================================

    def drive_fu_complete(
        self,
        fu_index: int = FU_ALU,
        tag: int = 0,
        value: int = 0,
        exception: bool = False,
        exc_cause: int = 0,
        fp_flags: int = 0,
    ) -> None:
        """Drive a single FU completion request to the CDB arbiter.

        The arbiter internally broadcasts to both ROB (cdb_write) and all RS
        (cdb broadcast for wakeup).
        """
        req = FuComplete(
            valid=True,
            tag=tag,
            value=value,
            exception=exception,
            exc_cause=exc_cause,
            fp_flags=fp_flags,
        )
        self._get_fu_signal(fu_index).value = pack_fu_complete(req)

    def _get_fu_signal(self, fu_index: int) -> Any:
        """Get DUT signal for a specific FU complete slot.

        Verilator: dut.i_fu_complete[index]
        Icarus TB: dut.i_fu_complete_0 .. dut.i_fu_complete_6
        """
        if hasattr(self.dut, "i_fu_complete_0"):
            return getattr(self.dut, f"i_fu_complete_{fu_index}")
        return self.dut.i_fu_complete[fu_index]

    def clear_fu_complete(self, fu_index: int = FU_ALU) -> None:
        """Clear a single FU completion slot."""
        self._get_fu_signal(fu_index).value = 0

    def clear_all_fu_completes(self) -> None:
        """Clear all FU completion slots."""
        for i in range(NUM_FUS):
            self._get_fu_signal(i).value = 0

    def read_cdb_output(self) -> CdbBroadcast:
        """Read the CDB broadcast output for observation."""
        raw = int(self.dut.o_cdb.value)
        return unpack_cdb_broadcast(raw)

    def read_cdb_grant(self) -> int:
        """Read the CDB grant vector."""
        return int(self.dut.o_cdb_grant.value)

    # Backward-compat aliases for tests that used the old CDB interface.
    # These all route through a single FU_ALU completion.
    def drive_cdb(
        self,
        tag: int,
        value: int = 0,
        exception: bool = False,
        exc_cause: int = 0,
        fp_flags: int = 0,
    ) -> None:
        """Drive CDB via FU_ALU completion (backward compat)."""
        self.drive_fu_complete(
            FU_ALU,
            tag=tag,
            value=value,
            exception=exception,
            exc_cause=exc_cause,
            fp_flags=fp_flags,
        )

    def clear_cdb(self) -> None:
        """Clear CDB by clearing all FU completions (backward compat)."""
        self.clear_all_fu_completes()

    def drive_cdb_write(self, write: CDBWrite) -> None:
        """Drive CDB write via FU_ALU completion (backward compat)."""
        self.drive_fu_complete(
            FU_ALU,
            tag=write.tag,
            value=write.value,
            exception=write.exception,
            exc_cause=write.exc_cause,
            fp_flags=write.fp_flags,
        )

    def clear_cdb_write(self) -> None:
        """Clear CDB write by clearing FU_ALU (backward compat)."""
        self.clear_fu_complete(FU_ALU)

    def drive_cdb_broadcast(self, tag: int, value: int = 0, **kwargs: Any) -> None:
        """Drive CDB broadcast via FU_ALU completion (backward compat)."""
        self.drive_fu_complete(
            FU_ALU,
            tag=tag,
            value=value,
            exception=kwargs.get("exception", False),
            exc_cause=kwargs.get("exc_cause", 0),
            fp_flags=kwargs.get("fp_flags", 0),
        )

    def clear_cdb_broadcast(self) -> None:
        """Clear CDB broadcast by clearing FU_ALU (backward compat)."""
        self.clear_fu_complete(FU_ALU)

    # =========================================================================
    # ROB Branch Update
    # =========================================================================

    def drive_branch_update(self, update: BranchUpdate) -> None:
        """Drive branch update to ROB."""
        self.dut.i_branch_update.value = pack_branch_update(update)

    def clear_branch_update(self) -> None:
        """Clear branch update signals."""
        self.dut.i_branch_update.value = 0

    # =========================================================================
    # ROB Checkpoint Recording
    # =========================================================================

    def drive_rob_checkpoint(self, checkpoint_id: int) -> None:
        """Drive ROB checkpoint recording signals."""
        self.dut.i_rob_checkpoint_valid.value = 1
        self.dut.i_rob_checkpoint_id.value = checkpoint_id

    def clear_rob_checkpoint(self) -> None:
        """Clear ROB checkpoint recording signals."""
        self.dut.i_rob_checkpoint_valid.value = 0

    # =========================================================================
    # Commit Observation
    # =========================================================================

    def read_commit(self) -> dict:
        """Read and unpack commit output."""
        val = int(self.dut.o_commit.value)
        return unpack_commit(val)

    @property
    def commit_valid(self) -> bool:
        """Return whether commit output is valid."""
        return self.read_commit()["valid"]

    # =========================================================================
    # ROB Status
    # =========================================================================

    @property
    def rob_full(self) -> bool:
        """Return whether ROB is full."""
        return bool(self.dut.o_rob_full.value)

    @property
    def rob_empty(self) -> bool:
        """Return whether ROB is empty."""
        return bool(self.dut.o_rob_empty.value)

    @property
    def rob_count(self) -> int:
        """Return number of valid ROB entries."""
        return int(self.dut.o_rob_count.value)

    @property
    def head_tag(self) -> int:
        """Return ROB head tag."""
        return int(self.dut.o_head_tag.value)

    @property
    def head_valid(self) -> bool:
        """Return whether ROB head is valid."""
        return bool(self.dut.o_head_valid.value)

    @property
    def head_done(self) -> bool:
        """Return whether ROB head is done."""
        return bool(self.dut.o_head_done.value)

    # =========================================================================
    # ROB Bypass Read
    # =========================================================================

    def set_read_tag(self, tag: int) -> None:
        """Set ROB bypass read tag."""
        self.dut.i_read_tag.value = tag

    def read_entry_done(self) -> bool:
        """Return whether the read entry is done."""
        return bool(self.dut.o_read_done.value)

    def read_entry_value(self) -> int:
        """Return the read entry value."""
        return int(self.dut.o_read_value.value)

    # =========================================================================
    # Flush
    # =========================================================================

    def drive_flush_en(self, flush_tag: int) -> None:
        """Drive partial flush with tag."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag

    def clear_flush_en(self) -> None:
        """Deassert partial flush enable."""
        self.dut.i_flush_en.value = 0

    def drive_flush_all(self) -> None:
        """Assert flush_all signal."""
        self.dut.i_flush_all.value = 1

    def clear_flush_all(self) -> None:
        """Deassert flush_all signal."""
        self.dut.i_flush_all.value = 0

    # =========================================================================
    # RAT Source Lookups
    # =========================================================================

    def set_int_src1(self, addr: int, regfile_data: int) -> None:
        """Drive integer source 1 lookup address and regfile data."""
        self.dut.i_int_src1_addr.value = addr & MASK_REG
        self.dut.i_int_regfile_data1.value = regfile_data & MASK32

    def set_int_src2(self, addr: int, regfile_data: int) -> None:
        """Drive integer source 2 lookup address and regfile data."""
        self.dut.i_int_src2_addr.value = addr & MASK_REG
        self.dut.i_int_regfile_data2.value = regfile_data & MASK32

    def read_int_src1(self) -> LookupResult:
        """Read integer source 1 RAT lookup result."""
        return unpack_rat_lookup(int(self.dut.o_int_src1.value))

    def read_int_src2(self) -> LookupResult:
        """Read integer source 2 RAT lookup result."""
        return unpack_rat_lookup(int(self.dut.o_int_src2.value))

    def set_fp_src1(self, addr: int, regfile_data: int) -> None:
        """Drive FP source 1 lookup address and regfile data."""
        self.dut.i_fp_src1_addr.value = addr & MASK_REG
        self.dut.i_fp_regfile_data1.value = regfile_data & MASK64

    def set_fp_src2(self, addr: int, regfile_data: int) -> None:
        """Drive FP source 2 lookup address and regfile data."""
        self.dut.i_fp_src2_addr.value = addr & MASK_REG
        self.dut.i_fp_regfile_data2.value = regfile_data & MASK64

    def read_fp_src1(self) -> LookupResult:
        """Read FP source 1 RAT lookup result."""
        return unpack_rat_lookup(int(self.dut.o_fp_src1.value))

    def read_fp_src2(self) -> LookupResult:
        """Read FP source 2 RAT lookup result."""
        return unpack_rat_lookup(int(self.dut.o_fp_src2.value))

    # =========================================================================
    # RAT Rename
    # =========================================================================

    def drive_rat_rename(self, dest_rf: int, dest_reg: int, rob_tag: int) -> None:
        """Drive RAT rename signals."""
        self.dut.i_rat_alloc_valid.value = 1
        self.dut.i_rat_alloc_dest_rf.value = dest_rf & 1
        self.dut.i_rat_alloc_dest_reg.value = dest_reg & MASK_REG
        self.dut.i_rat_alloc_rob_tag.value = rob_tag & MASK_TAG

    def clear_rat_rename(self) -> None:
        """Clear RAT rename signals."""
        self.dut.i_rat_alloc_valid.value = 0

    # =========================================================================
    # RAT Checkpoint Save/Restore/Free
    # =========================================================================

    def drive_checkpoint_save(
        self,
        checkpoint_id: int,
        branch_tag: int,
        ras_tos: int = 0,
        ras_valid_count: int = 0,
    ) -> None:
        """Drive RAT checkpoint save signals."""
        self.dut.i_checkpoint_save.value = 1
        self.dut.i_checkpoint_id.value = checkpoint_id & 0x3
        self.dut.i_checkpoint_branch_tag.value = branch_tag & MASK_TAG
        self.dut.i_ras_tos.value = ras_tos & 0x7
        self.dut.i_ras_valid_count.value = ras_valid_count & 0xF

    def clear_checkpoint_save(self) -> None:
        """Deassert checkpoint save."""
        self.dut.i_checkpoint_save.value = 0

    def drive_checkpoint_restore(self, checkpoint_id: int) -> None:
        """Drive RAT checkpoint restore signals."""
        self.dut.i_checkpoint_restore.value = 1
        self.dut.i_checkpoint_restore_id.value = checkpoint_id & 0x3

    def clear_checkpoint_restore(self) -> None:
        """Deassert checkpoint restore."""
        self.dut.i_checkpoint_restore.value = 0

    def drive_checkpoint_free(self, checkpoint_id: int) -> None:
        """Drive RAT checkpoint free signals."""
        self.dut.i_checkpoint_free.value = 1
        self.dut.i_checkpoint_free_id.value = checkpoint_id & 0x3

    def clear_checkpoint_free(self) -> None:
        """Deassert checkpoint free."""
        self.dut.i_checkpoint_free.value = 0

    @property
    def checkpoint_available(self) -> bool:
        """Return whether a checkpoint slot is available."""
        return bool(self.dut.o_checkpoint_available.value)

    @property
    def checkpoint_alloc_id(self) -> int:
        """Return next available checkpoint ID."""
        return int(self.dut.o_checkpoint_alloc_id.value)

    # =========================================================================
    # RS Dispatch (single input, routed by rs_type in the wrapper)
    # =========================================================================

    def drive_rs_dispatch(self, rs_type: int = RS_INT, **kwargs: Any) -> None:
        """Drive RS dispatch signals. rs_type selects which RS receives it."""
        kwargs["valid"] = True
        kwargs["rs_type"] = rs_type
        if self._flat_rs:
            self._drive_rs_dispatch_flat(**kwargs)
        else:
            self.dut.i_rs_dispatch.value = pack_rs_dispatch(**kwargs)

    def clear_rs_dispatch(self) -> None:
        """Clear RS dispatch signals."""
        if self._flat_rs:
            self._clear_rs_dispatch_flat()
        else:
            self.dut.i_rs_dispatch.value = 0

    def _drive_rs_dispatch_flat(self, **kwargs: Any) -> None:
        """Drive individual RS dispatch ports (Icarus wrapper)."""
        d = self.dut
        d.i_rs_dispatch_valid.value = 1 if kwargs.get("valid") else 0
        d.i_rs_dispatch_rs_type.value = int(kwargs.get("rs_type", 0)) & 0x7
        d.i_rs_dispatch_rob_tag.value = int(kwargs.get("rob_tag", 0)) & MASK_TAG
        d.i_rs_dispatch_op.value = int(kwargs.get("op", 0)) & MASK32
        d.i_rs_dispatch_src1_ready.value = 1 if kwargs.get("src1_ready") else 0
        d.i_rs_dispatch_src1_tag.value = int(kwargs.get("src1_tag", 0)) & MASK_TAG
        d.i_rs_dispatch_src1_value.value = int(kwargs.get("src1_value", 0)) & MASK64
        d.i_rs_dispatch_src2_ready.value = 1 if kwargs.get("src2_ready") else 0
        d.i_rs_dispatch_src2_tag.value = int(kwargs.get("src2_tag", 0)) & MASK_TAG
        d.i_rs_dispatch_src2_value.value = int(kwargs.get("src2_value", 0)) & MASK64
        d.i_rs_dispatch_src3_ready.value = 1 if kwargs.get("src3_ready") else 0
        d.i_rs_dispatch_src3_tag.value = int(kwargs.get("src3_tag", 0)) & MASK_TAG
        d.i_rs_dispatch_src3_value.value = int(kwargs.get("src3_value", 0)) & MASK64
        d.i_rs_dispatch_imm.value = int(kwargs.get("imm", 0)) & MASK32
        d.i_rs_dispatch_use_imm.value = 1 if kwargs.get("use_imm") else 0
        d.i_rs_dispatch_rm.value = int(kwargs.get("rm", 0)) & 0x7
        d.i_rs_dispatch_branch_target.value = (
            int(kwargs.get("branch_target", 0)) & MASK32
        )
        d.i_rs_dispatch_predicted_taken.value = (
            1 if kwargs.get("predicted_taken") else 0
        )
        d.i_rs_dispatch_predicted_target.value = (
            int(kwargs.get("predicted_target", 0)) & MASK32
        )
        d.i_rs_dispatch_is_fp_mem.value = 1 if kwargs.get("is_fp_mem") else 0
        d.i_rs_dispatch_mem_size.value = int(kwargs.get("mem_size", 0)) & 0x3
        d.i_rs_dispatch_mem_signed.value = 1 if kwargs.get("mem_signed") else 0
        d.i_rs_dispatch_csr_addr.value = int(kwargs.get("csr_addr", 0)) & 0xFFF
        d.i_rs_dispatch_csr_imm.value = int(kwargs.get("csr_imm", 0)) & 0x1F

    def _clear_rs_dispatch_flat(self) -> None:
        """Clear all individual RS dispatch ports to zero."""
        d = self.dut
        d.i_rs_dispatch_valid.value = 0
        d.i_rs_dispatch_rs_type.value = 0
        d.i_rs_dispatch_rob_tag.value = 0
        d.i_rs_dispatch_op.value = 0
        d.i_rs_dispatch_src1_ready.value = 0
        d.i_rs_dispatch_src1_tag.value = 0
        d.i_rs_dispatch_src1_value.value = 0
        d.i_rs_dispatch_src2_ready.value = 0
        d.i_rs_dispatch_src2_tag.value = 0
        d.i_rs_dispatch_src2_value.value = 0
        d.i_rs_dispatch_src3_ready.value = 0
        d.i_rs_dispatch_src3_tag.value = 0
        d.i_rs_dispatch_src3_value.value = 0
        d.i_rs_dispatch_imm.value = 0
        d.i_rs_dispatch_use_imm.value = 0
        d.i_rs_dispatch_rm.value = 0
        d.i_rs_dispatch_branch_target.value = 0
        d.i_rs_dispatch_predicted_taken.value = 0
        d.i_rs_dispatch_predicted_target.value = 0
        d.i_rs_dispatch_is_fp_mem.value = 0
        d.i_rs_dispatch_mem_size.value = 0
        d.i_rs_dispatch_mem_signed.value = 0
        d.i_rs_dispatch_csr_addr.value = 0
        d.i_rs_dispatch_csr_imm.value = 0

    # =========================================================================
    # RS Issue (per-RS type)
    # =========================================================================

    def set_fu_ready(self, rs_type: int = RS_INT, ready: bool = True) -> None:
        """Set functional unit ready for the specified RS type.

        Under ICARUS only INT_RS is available; other types raise RuntimeError.
        """
        if self._flat_rs and rs_type != RS_INT:
            raise RuntimeError(
                f"RS type {rs_type} not available under ICARUS (INT_RS only)"
            )
        sig_name = _RS_SIGNAL_MAP[rs_type]["fu_ready"]
        getattr(self.dut, sig_name).value = 1 if ready else 0

    def set_rs_fu_ready(self, ready: bool = True) -> None:
        """Set INT_RS functional unit ready (backward compat)."""
        self.set_fu_ready(RS_INT, ready)

    def set_all_fu_ready(self, ready: bool = True) -> None:
        """Set all RS functional units ready."""
        for rs_type in _RS_SIGNAL_MAP:
            if not self._flat_rs or rs_type == RS_INT:
                self.set_fu_ready(rs_type, ready)

    def read_rs_issue_for(self, rs_type: int) -> dict:
        """Read and unpack issue output for the specified RS type.

        Only INT_RS is available under ICARUS; other RS types require Verilator.
        """
        if self._flat_rs:
            if rs_type == RS_INT:
                return self._read_rs_issue_flat()
            raise RuntimeError(
                f"RS type {rs_type} not available under ICARUS (INT_RS only)"
            )
        sig_name = _RS_SIGNAL_MAP[rs_type]["issue"]
        return unpack_rs_issue(int(getattr(self.dut, sig_name).value))

    def read_rs_issue(self) -> dict:
        """Read and unpack INT_RS issue output (backward compat)."""
        if self._flat_rs:
            return self._read_rs_issue_flat()
        return unpack_rs_issue(int(self.dut.o_rs_issue.value))

    def _read_rs_issue_flat(self) -> dict:
        """Read individual RS issue ports (Icarus wrapper)."""
        d = self.dut
        return {
            "valid": bool(d.o_rs_issue_valid.value),
            "rob_tag": int(d.o_rs_issue_rob_tag.value),
            "op": int(d.o_rs_issue_op.value),
            "src1_value": int(d.o_rs_issue_src1_value.value),
            "src2_value": int(d.o_rs_issue_src2_value.value),
            "src3_value": int(d.o_rs_issue_src3_value.value),
            "imm": int(d.o_rs_issue_imm.value),
            "use_imm": bool(d.o_rs_issue_use_imm.value),
            "rm": int(d.o_rs_issue_rm.value),
            "branch_target": int(d.o_rs_issue_branch_target.value),
            "predicted_taken": bool(d.o_rs_issue_predicted_taken.value),
            "predicted_target": int(d.o_rs_issue_predicted_target.value),
            "is_fp_mem": bool(d.o_rs_issue_is_fp_mem.value),
            "mem_size": int(d.o_rs_issue_mem_size.value),
            "mem_signed": bool(d.o_rs_issue_mem_signed.value),
            "csr_addr": int(d.o_rs_issue_csr_addr.value),
            "csr_imm": int(d.o_rs_issue_csr_imm.value),
        }

    def rs_issue_valid_for(self, rs_type: int) -> bool:
        """Return whether issue output is valid for the specified RS type."""
        return self.read_rs_issue_for(rs_type)["valid"]

    @property
    def rs_issue_valid(self) -> bool:
        """Return whether INT_RS issue output is valid (backward compat)."""
        if self._flat_rs:
            return bool(self.dut.o_rs_issue_valid.value)
        return self.read_rs_issue()["valid"]

    # =========================================================================
    # RS Status (per-RS type)
    # =========================================================================

    def rs_full_for(self, rs_type: int) -> bool:
        """Return whether the specified RS is full.

        Uses dedicated per-RS full signals (o_int_rs_full, o_mul_rs_full, etc.),
        NOT the dispatch-target mux o_rs_full.
        Under ICARUS only INT_RS is available; other types raise RuntimeError.
        """
        if self._flat_rs and rs_type != RS_INT:
            raise RuntimeError(
                f"RS type {rs_type} not available under ICARUS (INT_RS only)"
            )
        sig_name = _RS_SIGNAL_MAP[rs_type]["full"]
        return bool(getattr(self.dut, sig_name).value)

    def rs_empty_for(self, rs_type: int) -> bool:
        """Return whether the specified RS is empty.

        Under ICARUS only INT_RS is available; other types raise RuntimeError.
        """
        if self._flat_rs and rs_type != RS_INT:
            raise RuntimeError(
                f"RS type {rs_type} not available under ICARUS (INT_RS only)"
            )
        sig_name = _RS_SIGNAL_MAP[rs_type]["empty"]
        return bool(getattr(self.dut, sig_name).value)

    def rs_count_for(self, rs_type: int) -> int:
        """Return number of valid entries in the specified RS.

        Under ICARUS only INT_RS is available; other types raise RuntimeError.
        """
        if self._flat_rs and rs_type != RS_INT:
            raise RuntimeError(
                f"RS type {rs_type} not available under ICARUS (INT_RS only)"
            )
        sig_name = _RS_SIGNAL_MAP[rs_type]["count"]
        return int(getattr(self.dut, sig_name).value)

    @property
    def dispatch_target_rs_full(self) -> bool:
        """Return o_rs_full (dispatch-target mux, NOT dedicated INT_RS full)."""
        return bool(self.dut.o_rs_full.value)

    # Backward-compat properties (INT_RS)
    @property
    def rs_full(self) -> bool:
        """Return whether INT_RS is full (dedicated o_int_rs_full signal)."""
        return self.rs_full_for(RS_INT)

    @property
    def rs_empty(self) -> bool:
        """Return whether INT_RS is empty (backward compat)."""
        return self.rs_empty_for(RS_INT)

    @property
    def rs_count(self) -> int:
        """Return number of valid INT_RS entries (backward compat)."""
        return self.rs_count_for(RS_INT)

    # =========================================================================
    # Compound Transactions
    # =========================================================================

    async def dispatch(
        self,
        req: AllocationRequest,
        checkpoint_save: bool = False,
        ras_tos: int = 0,
        ras_valid_count: int = 0,
    ) -> int:
        """Dispatch: ROB alloc + RAT rename + optional checkpoint.

        Returns the allocated ROB tag.
        """
        # Drive ROB allocation request
        self.drive_alloc_request(req)

        # Read combinational response
        alloc_ready, tag, _ = self.read_alloc_response()
        assert alloc_ready, "dispatch() called when ROB is not ready"

        # RAT rename
        if req.dest_valid:
            self.drive_rat_rename(req.dest_rf, req.dest_reg, tag)

        # Checkpoint save if requested
        if checkpoint_save:
            cp_id = self.checkpoint_alloc_id
            self.drive_checkpoint_save(cp_id, tag, ras_tos, ras_valid_count)
            self.drive_rob_checkpoint(cp_id)

        # Rising edge: modules register
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

        # Clear
        self.clear_alloc_request()
        self.clear_rat_rename()
        if checkpoint_save:
            self.clear_checkpoint_save()
            self.clear_rob_checkpoint()

        return tag

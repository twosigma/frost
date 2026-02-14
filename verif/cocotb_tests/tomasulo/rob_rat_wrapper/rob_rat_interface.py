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

"""DUT interface for ROB-RAT integration wrapper verification.

Reuses packing/unpacking functions from the existing ROB and RAT interfaces.
"""

from typing import Any
from cocotb.triggers import RisingEdge, FallingEdge

from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_interface import (
    pack_alloc_request,
    unpack_alloc_response,
    pack_cdb_write,
    pack_branch_update,
    unpack_commit,
)
from cocotb_tests.tomasulo.register_alias_table.rat_interface import (
    unpack_rat_lookup,
)
from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
    MASK32,
    MASK64,
)
from cocotb_tests.tomasulo.register_alias_table.rat_model import (
    LookupResult,
    MASK_TAG,
    MASK_REG,
)


class RobRatInterface:
    """Interface to the ROB-RAT integration wrapper DUT."""

    def __init__(self, dut: Any) -> None:
        """Initialize with a cocotb DUT handle."""
        self.dut = dut

    # =========================================================================
    # Clock and Reset
    # =========================================================================

    @property
    def clock(self) -> Any:
        """Return the clock signal."""
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

        # ROB CDB
        self.dut.i_cdb_write.value = 0

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

    # =========================================================================
    # ROB Allocation
    # =========================================================================

    def drive_alloc_request(self, req: AllocationRequest) -> None:
        """Drive allocation request signals."""
        self.dut.i_alloc_req.value = pack_alloc_request(req)

    def clear_alloc_request(self) -> None:
        """Clear allocation request."""
        self.dut.i_alloc_req.value = 0

    def read_alloc_response(self) -> tuple[bool, int, bool]:
        """Return (alloc_ready, alloc_tag, full) from the DUT."""
        val = int(self.dut.o_alloc_resp.value)
        return unpack_alloc_response(val)

    # =========================================================================
    # ROB CDB Write
    # =========================================================================

    def drive_cdb_write(self, write: CDBWrite) -> None:
        """Drive CDB write signals."""
        self.dut.i_cdb_write.value = pack_cdb_write(write)

    def clear_cdb_write(self) -> None:
        """Clear CDB write."""
        self.dut.i_cdb_write.value = 0

    # =========================================================================
    # ROB Branch Update
    # =========================================================================

    def drive_branch_update(self, update: BranchUpdate) -> None:
        """Drive branch update signals."""
        self.dut.i_branch_update.value = pack_branch_update(update)

    def clear_branch_update(self) -> None:
        """Clear branch update."""
        self.dut.i_branch_update.value = 0

    # =========================================================================
    # ROB Checkpoint Recording
    # =========================================================================

    def drive_rob_checkpoint(self, checkpoint_id: int) -> None:
        """Drive ROB checkpoint recording signals."""
        self.dut.i_rob_checkpoint_valid.value = 1
        self.dut.i_rob_checkpoint_id.value = checkpoint_id

    def clear_rob_checkpoint(self) -> None:
        """Clear ROB checkpoint recording."""
        self.dut.i_rob_checkpoint_valid.value = 0

    # =========================================================================
    # Commit Observation
    # =========================================================================

    def read_commit(self) -> dict:
        """Read and unpack the commit output bus."""
        val = int(self.dut.o_commit.value)
        return unpack_commit(val)

    @property
    def commit_valid(self) -> bool:
        """Return whether the commit output is valid this cycle."""
        return self.read_commit()["valid"]

    # =========================================================================
    # ROB Status
    # =========================================================================

    @property
    def rob_full(self) -> bool:
        """Return True if the ROB is full."""
        return bool(self.dut.o_rob_full.value)

    @property
    def rob_empty(self) -> bool:
        """Return True if the ROB is empty."""
        return bool(self.dut.o_rob_empty.value)

    @property
    def rob_count(self) -> int:
        """Return the number of valid ROB entries."""
        return int(self.dut.o_rob_count.value)

    @property
    def head_tag(self) -> int:
        """Return the ROB head tag."""
        return int(self.dut.o_head_tag.value)

    @property
    def head_valid(self) -> bool:
        """Return True if the ROB head entry is valid."""
        return bool(self.dut.o_head_valid.value)

    @property
    def head_done(self) -> bool:
        """Return True if the ROB head entry is done."""
        return bool(self.dut.o_head_done.value)

    # =========================================================================
    # ROB Bypass Read
    # =========================================================================

    def set_read_tag(self, tag: int) -> None:
        """Set the tag for ROB bypass read."""
        self.dut.i_read_tag.value = tag

    def read_entry_done(self) -> bool:
        """Return the done status of the bypass-read entry."""
        return bool(self.dut.o_read_done.value)

    def read_entry_value(self) -> int:
        """Return the value of the bypass-read entry."""
        return int(self.dut.o_read_value.value)

    # =========================================================================
    # Flush
    # =========================================================================

    def drive_flush_en(self, flush_tag: int) -> None:
        """Drive partial flush with the given tag."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag

    def clear_flush_en(self) -> None:
        """Clear partial flush."""
        self.dut.i_flush_en.value = 0

    def drive_flush_all(self) -> None:
        """Drive full flush."""
        self.dut.i_flush_all.value = 1

    def clear_flush_all(self) -> None:
        """Clear full flush."""
        self.dut.i_flush_all.value = 0

    # =========================================================================
    # RAT Source Lookups
    # =========================================================================

    def set_int_src1(self, addr: int, regfile_data: int) -> None:
        """Drive INT source 1 lookup address and regfile data."""
        self.dut.i_int_src1_addr.value = addr & MASK_REG
        self.dut.i_int_regfile_data1.value = regfile_data & MASK32

    def set_int_src2(self, addr: int, regfile_data: int) -> None:
        """Drive INT source 2 lookup address and regfile data."""
        self.dut.i_int_src2_addr.value = addr & MASK_REG
        self.dut.i_int_regfile_data2.value = regfile_data & MASK32

    def read_int_src1(self) -> LookupResult:
        """Read INT source 1 lookup result."""
        return unpack_rat_lookup(int(self.dut.o_int_src1.value))

    def read_int_src2(self) -> LookupResult:
        """Read INT source 2 lookup result."""
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
        """Read FP source 1 lookup result."""
        return unpack_rat_lookup(int(self.dut.o_fp_src1.value))

    def read_fp_src2(self) -> LookupResult:
        """Read FP source 2 lookup result."""
        return unpack_rat_lookup(int(self.dut.o_fp_src2.value))

    # =========================================================================
    # RAT Rename
    # =========================================================================

    def drive_rat_rename(self, dest_rf: int, dest_reg: int, rob_tag: int) -> None:
        """Drive RAT rename write signals."""
        self.dut.i_rat_alloc_valid.value = 1
        self.dut.i_rat_alloc_dest_rf.value = dest_rf & 1
        self.dut.i_rat_alloc_dest_reg.value = dest_reg & MASK_REG
        self.dut.i_rat_alloc_rob_tag.value = rob_tag & MASK_TAG

    def clear_rat_rename(self) -> None:
        """Clear RAT rename write."""
        self.dut.i_rat_alloc_valid.value = 0

    # =========================================================================
    # RAT Checkpoint Save
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
        """Clear RAT checkpoint save."""
        self.dut.i_checkpoint_save.value = 0

    # =========================================================================
    # RAT Checkpoint Restore
    # =========================================================================

    def drive_checkpoint_restore(self, checkpoint_id: int) -> None:
        """Drive RAT checkpoint restore signals."""
        self.dut.i_checkpoint_restore.value = 1
        self.dut.i_checkpoint_restore_id.value = checkpoint_id & 0x3

    def clear_checkpoint_restore(self) -> None:
        """Clear RAT checkpoint restore."""
        self.dut.i_checkpoint_restore.value = 0

    # =========================================================================
    # RAT Checkpoint Free
    # =========================================================================

    def drive_checkpoint_free(self, checkpoint_id: int) -> None:
        """Drive RAT checkpoint free signals."""
        self.dut.i_checkpoint_free.value = 1
        self.dut.i_checkpoint_free_id.value = checkpoint_id & 0x3

    def clear_checkpoint_free(self) -> None:
        """Clear RAT checkpoint free."""
        self.dut.i_checkpoint_free.value = 0

    # =========================================================================
    # RAT Checkpoint Availability
    # =========================================================================

    @property
    def checkpoint_available(self) -> bool:
        """Return True if a free checkpoint slot is available."""
        return bool(self.dut.o_checkpoint_available.value)

    @property
    def checkpoint_alloc_id(self) -> int:
        """Return the next free checkpoint slot ID."""
        return int(self.dut.o_checkpoint_alloc_id.value)

    # =========================================================================
    # Compound Transaction: dispatch
    # =========================================================================

    async def dispatch(
        self,
        req: AllocationRequest,
        checkpoint_save: bool = False,
        ras_tos: int = 0,
        ras_valid_count: int = 0,
    ) -> int:
        """Dispatch an instruction: drive ROB alloc + RAT rename + optional checkpoint.

        Drives on falling edge, reads combinational alloc_tag, drives RAT rename
        with that tag. On rising edge both modules register state simultaneously.

        Returns the allocated tag (current tail pointer, always valid).
        """
        # Drive ROB allocation request
        self.drive_alloc_request(req)

        # Read combinational response (tag = current tail pointer, settles in same delta)
        alloc_ready, tag, _ = self.read_alloc_response()
        assert alloc_ready, "dispatch() called when ROB is not ready to allocate"

        # Drive RAT rename with the allocated tag (if instruction has destination)
        if req.dest_valid:
            self.drive_rat_rename(req.dest_rf, req.dest_reg, tag)

        # Checkpoint save if requested
        if checkpoint_save:
            cp_id = self.checkpoint_alloc_id
            self.drive_checkpoint_save(cp_id, tag, ras_tos, ras_valid_count)
            self.drive_rob_checkpoint(cp_id)

        # Rising edge: both modules register
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

        # Clear all signals
        self.clear_alloc_request()
        self.clear_rat_rename()
        if checkpoint_save:
            self.clear_checkpoint_save()
            self.clear_rob_checkpoint()

        return tag

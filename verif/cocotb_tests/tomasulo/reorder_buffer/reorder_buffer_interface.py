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

"""Typed ROB DUT access and packed-struct conversion helpers.

Verilator flattens packed structs into bit vectors, so this interface packs
and unpacks their fields. The six independent dispatch-bypass value reads
have dedicated accessors, separate from the RAT-style entry read.
"""

from typing import Any

from cocotb.triggers import RisingEdge, FallingEdge
from config import FLEN, MASK64, MASK_XLEN, XLEN

from .reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
)


# =============================================================================
# Struct Bit Field Definitions
# =============================================================================
# These define the bit positions for fields in packed structs.
# SystemVerilog packed structs are MSB-first (first field is at highest bits).

# reorder_buffer_alloc_req_t contains five XLEN fields: pc,
# predicted_target, branch_target, link_addr, and csr_write_data. The other
# fields occupy 49 bits, so the complete width is 369 (49 + 5*64).
# alloc_valid is always the MSB (ALLOC_REQ_WIDTH - 1).
ALLOC_REQ_WIDTH = 49 + (5 * XLEN)


def pack_alloc_request(req: AllocationRequest) -> int:
    """Pack AllocationRequest into a bit vector for driving i_alloc_req.

    The struct fields are packed MSB-first per SystemVerilog semantics.
    """
    val = 0
    bit = 0

    # Pack from LSB to MSB (reverse order of struct declaration)
    val |= (1 if req.has_fp_flags else 0) << bit
    bit += 1
    val |= (req.csr_write_data & MASK_XLEN) << bit
    bit += XLEN
    val |= (req.csr_op & 0x7) << bit
    bit += 3
    val |= (req.csr_addr & 0xFFF) << bit
    bit += 12
    val |= (1 if req.csr_write_intent else 0) << bit
    bit += 1
    val |= (1 if req.is_compressed else 0) << bit
    bit += 1
    val |= (1 if req.is_sc else 0) << bit
    bit += 1
    val |= (1 if req.is_lr else 0) << bit
    bit += 1
    val |= (1 if req.is_amo else 0) << bit
    bit += 1
    val |= (1 if req.is_sfence_vma else 0) << bit
    bit += 1
    val |= (1 if req.is_dret else 0) << bit
    bit += 1
    val |= (1 if req.is_sret else 0) << bit
    bit += 1
    val |= (1 if req.is_mret else 0) << bit
    bit += 1
    val |= (1 if req.is_wfi else 0) << bit
    bit += 1
    val |= (1 if req.is_fence_i else 0) << bit
    bit += 1
    val |= (1 if req.is_fence else 0) << bit
    bit += 1
    val |= (1 if req.is_csr else 0) << bit
    bit += 1
    val |= (1 if req.is_jalr else 0) << bit
    bit += 1
    val |= (1 if req.is_jal else 0) << bit
    bit += 1
    val |= (req.link_addr & MASK_XLEN) << bit
    bit += XLEN
    val |= (1 if req.is_return else 0) << bit
    bit += 1
    val |= (1 if req.is_call else 0) << bit
    bit += 1
    val |= (req.branch_target & MASK_XLEN) << bit
    bit += XLEN
    val |= (req.predicted_target & MASK_XLEN) << bit
    bit += XLEN
    val |= (1 if req.predicted_taken else 0) << bit
    bit += 1
    val |= (1 if req.is_branch else 0) << bit
    bit += 1
    val |= (1 if req.is_fp_instruction else 0) << bit
    bit += 1
    val |= (1 if req.is_fp_store else 0) << bit
    bit += 1
    val |= (1 if req.is_store else 0) << bit
    bit += 1
    val |= (1 if req.dest_valid else 0) << bit
    bit += 1
    val |= (req.dest_reg & 0x1F) << bit
    bit += 5
    val |= (req.dest_rf & 1) << bit
    bit += 1
    val |= (req.rs_type & 0x7) << bit
    bit += 3
    val |= (req.pc & MASK_XLEN) << bit
    bit += XLEN
    val |= 1 << bit  # alloc_valid = 1
    bit += 1

    assert bit == ALLOC_REQ_WIDTH

    return val


# reorder_buffer_alloc_resp_t (7 bits total):
# [6]   alloc_ready
# [5:1] alloc_tag (5 bits)
# [0]   full
ROB_TAG_WIDTH = 5
ALLOC_RESP_WIDTH = ROB_TAG_WIDTH + 2


def unpack_alloc_response(val: int) -> tuple[bool, int, bool]:
    """Unpack allocation response.

    Returns: (alloc_ready, alloc_tag, full)
    """
    full = bool(val & 1)
    alloc_tag = (val >> 1) & ((1 << ROB_TAG_WIDTH) - 1)
    alloc_ready = bool((val >> (ROB_TAG_WIDTH + 1)) & 1)
    return alloc_ready, alloc_tag, full


# reorder_buffer_cdb_write_t uses FLEN for value:
# valid (1) + tag (5) + value (FLEN) + exception (1) + exc_cause (5) + fp_flags (5)
CDB_WRITE_WIDTH = 17 + FLEN


def pack_cdb_write(write: CDBWrite) -> int:
    """Pack CDBWrite into a bit vector."""
    val = 0
    bit = 0

    val |= (write.fp_flags & 0x1F) << bit
    bit += 5
    val |= (write.exc_cause & 0x1F) << bit
    bit += 5
    val |= (1 if write.exception else 0) << bit
    bit += 1
    val |= (write.value & MASK64) << bit
    bit += FLEN
    val |= (write.tag & ((1 << ROB_TAG_WIDTH) - 1)) << bit
    bit += ROB_TAG_WIDTH
    val |= 1 << bit  # valid = 1
    bit += 1

    assert bit == CDB_WRITE_WIDTH

    return val


# reorder_buffer_branch_update_t:
# valid (1) + tag (5) + taken (1) + target (XLEN) + mispredicted (1)
BRANCH_UPDATE_WIDTH = XLEN + 8


def pack_branch_update(update: BranchUpdate) -> int:
    """Pack BranchUpdate into a bit vector."""
    val = 0
    bit = 0

    val |= (1 if update.mispredicted else 0) << bit
    bit += 1
    val |= (update.target & MASK_XLEN) << bit
    bit += XLEN
    val |= (1 if update.taken else 0) << bit
    bit += 1
    val |= (update.tag & ((1 << ROB_TAG_WIDTH) - 1)) << bit
    bit += ROB_TAG_WIDTH
    val |= 1 << bit  # valid = 1
    bit += 1

    assert bit == BRANCH_UPDATE_WIDTH

    return val


ROB_PERF_EVENT_FIELDS = (
    "rob_empty",
    "head_wait_total",
    "head_wait_int",
    "head_wait_branch",
    "head_wait_mul",
    "head_wait_mem_load",
    "head_wait_mem_store",
    "head_wait_mem_amo",
    "head_wait_fp",
    "head_wait_fmul",
    "head_wait_fdiv",
    "commit_blocked_csr",
    "commit_blocked_fence",
    "commit_blocked_wfi",
    "commit_blocked_mret",
    "commit_blocked_trap",
    "head_and_next_done",
    "head_plus_one_done",
    "commit_2_opportunity",
    "commit_2_fire_actual",
    "commit_2_blocked_head_serial",
    "commit_2_blocked_next_serial",
    "commit_2_blocked_next_branch_mispred",
    "commit_2_blocked_next_branch_correct",
)
ROB_PERF_EVENT_WIDTH = 24
assert len(ROB_PERF_EVENT_FIELDS) == ROB_PERF_EVENT_WIDTH


def unpack_rob_perf_events(val: int) -> dict[str, bool]:
    """Unpack the all-one-bit ROB performance-event struct."""
    return {
        name: bool((val >> (ROB_PERF_EVENT_WIDTH - index - 1)) & 1)
        for index, name in enumerate(ROB_PERF_EVENT_FIELDS)
    }


COMMIT_FIELDS = [
    ("valid", 1),
    ("tag", ROB_TAG_WIDTH),
    ("dest_rf", 1),
    ("dest_reg", 5),
    ("dest_valid", 1),
    ("value", FLEN),
    ("is_store", 1),
    ("is_fp_store", 1),
    ("exception", 1),
    ("pc", XLEN),
    ("exc_cause", 5),
    ("fp_flags", 5),
    ("has_fp_flags", 1),
    ("misprediction", 1),
    ("early_recovered", 1),
    ("has_checkpoint", 1),
    ("checkpoint_id", 3),
    ("redirect_pc", XLEN),
    ("predicted_taken", 1),
    ("branch_taken", 1),
    ("branch_target", XLEN),
    ("is_branch", 1),
    ("is_call", 1),
    ("is_return", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("csr_addr", 12),
    ("csr_op", 3),
    ("csr_write_data", XLEN),
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

# reorder_buffer_commit_t contains four XLEN fields and one FLEN result; all
# flags, tags, CSR metadata, and register identifiers occupy another 64 bits.
COMMIT_WIDTH = 64 + FLEN + (4 * XLEN)
assert sum(width for _, width in COMMIT_FIELDS) == COMMIT_WIDTH

_COMMIT_OFFSETS: dict[str, tuple[int, int]] = {}
_offset = COMMIT_WIDTH
for _name, _width in COMMIT_FIELDS:
    _offset -= _width
    _COMMIT_OFFSETS[_name] = (_offset, _width)
assert _offset == 0


def unpack_commit(val: int) -> dict[str, Any]:
    """Unpack commit output into a dictionary."""
    result: dict[str, Any] = {}
    for name, (offset, width) in _COMMIT_OFFSETS.items():
        raw = (val >> offset) & ((1 << width) - 1)
        result[name] = bool(raw) if width == 1 else raw
    return result


def read_commit_output(dut: Any) -> dict[str, Any]:
    """Read commit output as sampled on the active clock edge."""
    if hasattr(dut, "o_commit_comb"):
        return unpack_commit(int(dut.o_commit_comb.value))
    return unpack_commit(int(dut.o_commit.value))


def read_commit_output_2(dut: Any) -> dict[str, Any]:
    """Read widen-commit slot-2 output as sampled on the active clock edge."""
    if hasattr(dut, "o_commit_comb_2"):
        return unpack_commit(int(dut.o_commit_comb_2.value))
    return unpack_commit(int(dut.o_commit_2.value))


class ReorderBufferInterface:
    """Interface to Reorder Buffer DUT.

    Packs and unpacks struct signals, since Verilator flattens packed structs
    into single bit vectors.
    """

    def __init__(self, dut: Any):
        """Initialize interface with DUT handle."""
        self.dut = dut

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

        Returns at a falling edge so that inputs driven right after reset are
        stable before the next rising edge.
        """
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    async def wait_falling(self) -> None:
        """Wait for the falling edge, where inputs are driven."""
        await FallingEdge(self.clock)

    async def wait_rising(self) -> None:
        """Wait for the rising edge, where outputs are sampled."""
        await RisingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: rising edge (state updates), then falling edge.

        Typical pattern:
            # reset_dut() returns at a falling edge
            drive_inputs()        # Drive on falling edge
            await dut_if.step()   # Rising edge (state updates) + falling edge
            sample_outputs()      # Outputs reflect the rising-edge update
            drive_inputs()        # Drive for next cycle
        """
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _init_inputs(self) -> None:
        """Initialize all input signals to default values."""
        self.dut.i_alloc_req.value = 0
        self.dut.i_alloc_req_2.value = 0
        self.dut.i_cdb_write.value = 0
        self.dut.i_cdb_write_2.value = 0
        self.dut.i_cdb_match_tag.value = 0
        self.dut.i_cdb_match_tag_2.value = 0
        self.dut.i_store_complete_valid.value = 0
        self.dut.i_store_complete_tag.value = 0
        self.dut.i_branch_update.value = 0
        self.dut.i_checkpoint_valid.value = 0
        self.dut.i_checkpoint_id.value = 0
        self.dut.i_sq_committed_empty.value = 1
        # Zero-latency cache sync by default (mirrors the no-cached-tier
        # shape's done=req): FENCE.I spends exactly one cycle in
        # SERIAL_FENCE_I_SYNC before committing.
        self.dut.i_fence_i_sync_done.value = 1
        self.dut.i_widen_commit_ok.value = 1
        self.dut.i_commit_hold.value = 0
        self.dut.i_csr_done.value = 0
        self.dut.i_trap_taken.value = 0
        self.dut.i_mret_done.value = 0
        self.dut.i_mepc.value = 0
        self.dut.i_sepc.value = 0
        self.dut.i_dpc.value = 0
        self.dut.i_priv.value = (
            0b11  # PrivM: MRET/privileged CSR tests run in machine mode.
        )
        self.dut.i_counter_blocked.value = 0
        self.dut.i_stimecmp_blocked.value = 0
        self.dut.i_sret_illegal.value = 0
        self.dut.i_sfence_illegal.value = 0
        self.dut.i_wfi_illegal.value = 0
        self.dut.i_priv_is_u.value = 0
        self.dut.i_debug_mode.value = 0
        # All counters enabled (the reset value); the mcounteren gate is
        # inert in PrivM anyway.
        self.dut.i_mcounteren.value = 0b111
        # FS not Off (the reset value is Initial): the D15 FP gate is inert.
        self.dut.i_mstatus_fs_off.value = 0
        self.dut.i_interrupt_pending.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_flush_all.value = 0
        self.dut.i_flush_after_head_commit.value = 0
        self.dut.i_early_recovery_flush.value = 0
        self.dut.i_early_recovery_en.value = 0
        self.dut.i_early_recovery_tag.value = 0
        self.dut.i_read_tag.value = 0
        self.set_bypass_tags((0,) * 6)

    # =========================================================================
    # Allocation Interface
    # =========================================================================

    def drive_alloc_request(self, req: AllocationRequest) -> None:
        """Drive allocation request signals. Call on falling edge."""
        val = pack_alloc_request(req)
        self.dut.i_alloc_req.value = val

    def clear_alloc_request(self) -> None:
        """Clear allocation request."""
        self.dut.i_alloc_req.value = 0

    def drive_alloc_request_2(self, req: AllocationRequest) -> None:
        """Drive slot-2 allocation request signals. Call on falling edge."""
        val = pack_alloc_request(req)
        self.dut.i_alloc_req_2.value = val

    def clear_alloc_request_2(self) -> None:
        """Clear slot-2 allocation request."""
        self.dut.i_alloc_req_2.value = 0

    def clear_alloc_requests(self) -> None:
        """Clear both allocation request ports."""
        self.clear_alloc_request()
        self.clear_alloc_request_2()

    def read_alloc_response(self) -> tuple[bool, int, bool]:
        """Read allocation response. Returns (ready, tag, full). Call after rising edge."""
        val = int(self.dut.o_alloc_resp.value)
        return unpack_alloc_response(val)

    def read_alloc_response_2(self) -> tuple[bool, int, bool]:
        """Read slot-2 allocation response. Returns (ready, tag, full)."""
        val = int(self.dut.o_alloc_resp_2.value)
        return unpack_alloc_response(val)

    async def allocate(self, req: AllocationRequest) -> int | None:
        """Perform allocation transaction.

        Drive on falling edge, wait for rising edge (allocation happens), then clear.
        Returns allocated tag or None if full.
        """
        await FallingEdge(self.clock)
        self.drive_alloc_request(req)
        await RisingEdge(self.clock)
        ready, tag, full = self.read_alloc_response()
        await FallingEdge(self.clock)
        self.clear_alloc_request()
        if ready and not full:
            return tag
        return None

    # =========================================================================
    # CDB Write Interface
    # =========================================================================

    def drive_cdb_write(self, write: CDBWrite) -> None:
        """Drive CDB write signals. Call on falling edge."""
        self.dut.i_cdb_write.value = pack_cdb_write(write)
        # Mirror the tag onto the private head-match duplicate. In hardware it
        # is a register copy of the same arbiter output, and the ROB asserts
        # the two are equal.
        self.dut.i_cdb_match_tag.value = write.tag

    def clear_cdb_write(self) -> None:
        """Clear CDB write."""
        self.dut.i_cdb_write.value = 0
        self.dut.i_cdb_match_tag.value = 0

    def drive_cdb_write_2(self, write: CDBWrite) -> None:
        """Drive lane-1 CDB write signals. Call on falling edge."""
        self.dut.i_cdb_write_2.value = pack_cdb_write(write)
        self.dut.i_cdb_match_tag_2.value = write.tag

    def clear_cdb_write_2(self) -> None:
        """Clear lane-1 CDB write."""
        self.dut.i_cdb_write_2.value = 0
        self.dut.i_cdb_match_tag_2.value = 0

    def clear_cdb_writes(self) -> None:
        """Clear both CDB lanes and their private match-tag copies."""
        self.clear_cdb_write()
        self.clear_cdb_write_2()

    def drive_store_complete(self, tag: int) -> None:
        """Drive direct store-complete pulse. Call on falling edge."""
        self.dut.i_store_complete_valid.value = 1
        self.dut.i_store_complete_tag.value = tag

    def clear_store_complete(self) -> None:
        """Clear direct store-complete pulse."""
        self.dut.i_store_complete_valid.value = 0
        self.dut.i_store_complete_tag.value = 0

    async def store_complete(self, tag: int) -> None:
        """Perform direct store-complete transaction."""
        await FallingEdge(self.clock)
        self.drive_store_complete(tag)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_store_complete()

    async def cdb_write(self, write: CDBWrite) -> None:
        """Perform CDB write transaction."""
        await FallingEdge(self.clock)
        self.drive_cdb_write(write)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_cdb_write()

    async def cdb_write_2(self, write: CDBWrite) -> None:
        """Perform a lane-1 CDB write transaction."""
        await FallingEdge(self.clock)
        self.drive_cdb_write_2(write)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_cdb_write_2()

    # =========================================================================
    # Branch Update Interface
    # =========================================================================

    def drive_branch_update(self, update: BranchUpdate) -> None:
        """Drive branch update signals. Call on falling edge."""
        self.dut.i_branch_update.value = pack_branch_update(update)

    def clear_branch_update(self) -> None:
        """Clear branch update."""
        self.dut.i_branch_update.value = 0

    async def branch_update(self, update: BranchUpdate) -> None:
        """Perform branch update transaction."""
        await FallingEdge(self.clock)
        self.drive_branch_update(update)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_branch_update()

    # =========================================================================
    # Checkpoint Interface
    # =========================================================================

    def drive_checkpoint(self, checkpoint_id: int) -> None:
        """Drive checkpoint assignment signals."""
        self.dut.i_checkpoint_valid.value = 1
        self.dut.i_checkpoint_id.value = checkpoint_id

    def clear_checkpoint(self) -> None:
        """Clear checkpoint signals."""
        self.dut.i_checkpoint_valid.value = 0

    # =========================================================================
    # Commit Output Interface
    # =========================================================================

    def read_commit(self) -> dict:
        """Read commit output signals."""
        return read_commit_output(self.dut)

    def read_commit_2(self) -> dict[str, Any]:
        """Read widen-commit slot-2 output signals."""
        return read_commit_output_2(self.dut)

    def read_perf_events(self) -> dict[str, bool]:
        """Read the combinational ROB performance-event outputs."""
        return unpack_rob_perf_events(int(self.dut.o_perf_events.value))

    @property
    def commit_valid(self) -> bool:
        """Check if commit is valid this cycle."""
        commit = self.read_commit()
        return commit["valid"]

    @property
    def commit_2_valid_raw(self) -> bool:
        """Return unregistered widen-commit slot-2 valid."""
        return bool(self.dut.o_commit_2_valid_raw.value)

    @property
    def commit_2_store_like_raw(self) -> bool:
        """Return unregistered widen-commit slot-2 store-like marker."""
        return bool(self.dut.o_commit_2_store_like_raw.value)

    # =========================================================================
    # External Coordination Signals
    # =========================================================================

    def set_sq_committed_empty(self, empty: bool) -> None:
        """Set store queue committed-empty signal."""
        self.dut.i_sq_committed_empty.value = 1 if empty else 0

    def set_csr_done(self, done: bool) -> None:
        """Set CSR operation done signal."""
        self.dut.i_csr_done.value = 1 if done else 0

    def set_trap_taken(self, taken: bool) -> None:
        """Set trap taken acknowledgement signal."""
        self.dut.i_trap_taken.value = 1 if taken else 0

    def set_mret_done(self, done: bool) -> None:
        """Set MRET done signal."""
        self.dut.i_mret_done.value = 1 if done else 0

    def set_mepc(self, mepc: int) -> None:
        """Set MEPC value for MRET."""
        self.dut.i_mepc.value = mepc & MASK_XLEN

    def set_interrupt_pending(self, pending: bool) -> None:
        """Set interrupt pending signal for WFI."""
        self.dut.i_interrupt_pending.value = 1 if pending else 0

    def set_widen_commit_ok(self, ok: bool) -> None:
        """Set downstream readiness for slot-2 widen commit."""
        self.dut.i_widen_commit_ok.value = 1 if ok else 0

    @property
    def csr_start(self) -> bool:
        """CSR operation start signal."""
        return bool(self.dut.o_csr_start.value)

    @property
    def trap_pending(self) -> bool:
        """Trap pending output signal."""
        return bool(self.dut.o_trap_pending.value)

    @property
    def trap_pc(self) -> int:
        """Trap PC output."""
        return int(self.dut.o_trap_pc.value)

    @property
    def trap_cause(self) -> int:
        """Trap cause output."""
        return int(self.dut.o_trap_cause.value)

    @property
    def mret_start(self) -> bool:
        """MRET start signal."""
        return bool(self.dut.o_mret_start.value)

    @property
    def fence_i_sync_req(self) -> bool:
        """True while the serializer is requesting the fence.i cache sync."""
        return bool(self.dut.o_fence_i_sync_req.value)

    @property
    def sfence_window(self) -> bool:
        """True only while an SFENCE.VMA owns the serializer sync window."""
        return bool(self.dut.o_sfence_window.value)

    @property
    def fence_class_flush_event(self) -> bool:
        """Serializer-owned native-fence or translation-CSR retirement event."""
        return bool(self.dut.o_fence_class_flush_event.value)

    @property
    def translation_csr_commit_shadow(self) -> bool:
        """One-cycle shadow between translation-CSR retirement and flush."""
        return bool(self.dut.o_translation_csr_commit_shadow.value)

    def set_fence_i_sync_done(self, done: bool) -> None:
        """Drive the cache-sync completion input."""
        self.dut.i_fence_i_sync_done.value = 1 if done else 0

    @property
    def fence_i_flush(self) -> bool:
        """Registered native-fence or translation-CSR frontend flush."""
        return bool(self.dut.o_fence_i_flush.value)

    # =========================================================================
    # Flush Interface
    # =========================================================================

    def drive_partial_flush(self, flush_tag: int) -> None:
        """Drive partial flush signals."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag

    def clear_partial_flush(self) -> None:
        """Clear partial flush enable."""
        self.dut.i_flush_en.value = 0

    async def partial_flush(self, flush_tag: int) -> None:
        """Perform partial flush and wait for completion."""
        await FallingEdge(self.clock)
        self.drive_partial_flush(flush_tag)
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_partial_flush()

    def drive_full_flush(self) -> None:
        """Drive full flush signal."""
        self.dut.i_flush_all.value = 1

    def clear_full_flush(self) -> None:
        """Clear full flush signal."""
        self.dut.i_flush_all.value = 0

    async def full_flush(self) -> None:
        """Perform full flush and wait for completion."""
        await FallingEdge(self.clock)
        self.drive_full_flush()
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)
        self.clear_full_flush()

    # =========================================================================
    # Status Signals
    # =========================================================================

    @property
    def full(self) -> bool:
        """Return True if buffer is full."""
        return bool(self.dut.o_full.value)

    @property
    def full_for_2(self) -> bool:
        """Return True if there is not enough room for a 2-wide allocation."""
        return bool(self.dut.o_full_for_2.value)

    @property
    def empty(self) -> bool:
        """Return True if buffer is empty."""
        return bool(self.dut.o_empty.value)

    @property
    def count(self) -> int:
        """Return number of entries in buffer."""
        return int(self.dut.o_count.value)

    @property
    def head_tag(self) -> int:
        """Return tag of head entry."""
        return int(self.dut.o_head_tag.value)

    @property
    def head_valid(self) -> bool:
        """Return True if head entry is valid."""
        return bool(self.dut.o_head_valid.value)

    @property
    def head_done(self) -> bool:
        """Return True if head entry is done."""
        return bool(self.dut.o_head_done.value)

    @property
    def head_ptr(self) -> int:
        """Return head pointer (with wrap bit) via debug signal."""
        return int(self.dut.dbg_head_ptr.value)

    @property
    def tail_ptr(self) -> int:
        """Return tail pointer (with wrap bit) via debug signal."""
        return int(self.dut.dbg_tail_ptr.value)

    # =========================================================================
    # Entry Read Interface
    # =========================================================================

    def set_read_tag(self, tag: int) -> None:
        """Set the tag for entry reads. Call on falling edge."""
        self.dut.i_read_tag.value = tag

    def read_entry_done(self) -> bool:
        """Read entry done status. Call after setting tag and rising edge."""
        return bool(self.dut.o_read_done.value)

    def read_entry_value(self) -> int:
        """Read entry value. Call after setting tag and rising edge."""
        return int(self.dut.o_read_value.value)

    def set_bypass_tags(self, tags: tuple[int, ...]) -> None:
        """Drive all six asynchronous dispatch-bypass read addresses."""
        if len(tags) != 6 or any(not 0 <= tag < (1 << ROB_TAG_WIDTH) for tag in tags):
            raise ValueError("ROB bypass reads require six in-range tags")
        for channel, tag in enumerate(tags, start=1):
            getattr(self.dut, f"i_bypass_tag_{channel}").value = tag

    def read_bypass_values(self) -> tuple[int, ...]:
        """Read all six bypass values after combinational settling, with no edge."""
        return tuple(
            int(getattr(self.dut, f"o_bypass_value_{channel}").value)
            for channel in range(1, 7)
        )

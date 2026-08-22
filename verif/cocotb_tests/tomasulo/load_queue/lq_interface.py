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

"""DUT interface for Load Queue verification.

Provides packing/unpacking for lq_alloc_req_t, lq_addr_update_t,
sq_forward_result_t, fu_complete_t and transaction helpers for
driving stimulus and reading results.
"""

from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge

from .lq_model import FuComplete
from ..fu_shims.fp_add_shim_interface import _parse_instr_op_enum
from config import FLEN, INSTR_OP_WIDTH, MASK32, MASK64, MASK_XLEN, XLEN

# Loads at or above this address ride the cached tier (slots); below it the
# fast tier (BRAM/MMIO). Mirrors the LQ's CACHED_BASE default.
CACHED_BASE = 0x8000_0000

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
# instr_op_e enum values for atomics, parsed from riscv_pkg.sv by name so
# enum-membership edits can never silently skew these ordinals (hardcoded
# copies were bitten by exactly that when ZIP/UNZIP were removed).
_INSTR_OPS = _parse_instr_op_enum()
OP_WIDTH = INSTR_OP_WIDTH
LR_W = _INSTR_OPS["LR_W"]
SC_W = _INSTR_OPS["SC_W"]
AMOSWAP_W = _INSTR_OPS["AMOSWAP_W"]
AMOADD_W = _INSTR_OPS["AMOADD_W"]
AMOXOR_W = _INSTR_OPS["AMOXOR_W"]
AMOAND_W = _INSTR_OPS["AMOAND_W"]
AMOOR_W = _INSTR_OPS["AMOOR_W"]
AMOMIN_W = _INSTR_OPS["AMOMIN_W"]
AMOMAX_W = _INSTR_OPS["AMOMAX_W"]
AMOMINU_W = _INSTR_OPS["AMOMINU_W"]
AMOMAXU_W = _INSTR_OPS["AMOMAXU_W"]
LR_D = _INSTR_OPS["LR_D"]
SC_D = _INSTR_OPS["SC_D"]
AMOSWAP_D = _INSTR_OPS["AMOSWAP_D"]
AMOADD_D = _INSTR_OPS["AMOADD_D"]
AMOXOR_D = _INSTR_OPS["AMOXOR_D"]
AMOAND_D = _INSTR_OPS["AMOAND_D"]
AMOOR_D = _INSTR_OPS["AMOOR_D"]
AMOMIN_D = _INSTR_OPS["AMOMIN_D"]
AMOMAX_D = _INSTR_OPS["AMOMAX_D"]
AMOMINU_D = _INSTR_OPS["AMOMINU_D"]
AMOMAXU_D = _INSTR_OPS["AMOMAXU_D"]

# lq_alloc_req_t packed layout (MSB-first in SV):
# valid(1) | rob_tag(5) | is_fp(1) | size(2) | sign_ext(1) | is_lr(1) | is_amo(1) | amo_op(8) = 20 bits

# lq_addr_update_t packed layout:
# valid(1) | rob_tag(5) | address(XLEN) | is_mmio(1) | amo_rs2(XLEN) = 135 bits at RV64

# sq_forward_result_t packed layout:
# data(64) | can_forward(1) | match(1) = 66 bits

# fu_complete_t packed layout:
# fp_flags(5) | exc_cause(5) | exception(1) | value(64) | tag(5) | valid(1) = 81 bits


def pack_lq_alloc(
    valid: bool = False,
    rob_tag: int = 0,
    is_fp: bool = False,
    size: int = 2,
    sign_ext: bool = False,
    is_lr: bool = False,
    is_amo: bool = False,
    amo_op: int = 0,
) -> int:
    """Pack lq_alloc_req_t into bit vector (LSB-first matching SV packed struct)."""
    val = 0
    bit = 0
    # Fields packed from LSB (last declared in SV) to MSB (first declared)
    val |= (amo_op & ((1 << OP_WIDTH) - 1)) << bit
    bit += OP_WIDTH
    val |= (1 if is_amo else 0) << bit
    bit += 1
    val |= (1 if is_lr else 0) << bit
    bit += 1
    val |= (1 if sign_ext else 0) << bit
    bit += 1
    val |= (size & 0x3) << bit
    bit += 2
    val |= (1 if is_fp else 0) << bit
    bit += 1
    val |= (rob_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if valid else 0) << bit
    return val


def pack_lq_addr_update(
    valid: bool = False,
    rob_tag: int = 0,
    address: int = 0,
    is_mmio: bool = False,
    amo_rs2: int = 0,
) -> int:
    """Pack lq_addr_update_t into bit vector (LSB-first matching SV packed struct)."""
    val = 0
    bit = 0
    val |= (amo_rs2 & MASK_XLEN) << bit
    bit += XLEN
    val |= (1 if is_mmio else 0) << bit
    bit += 1
    val |= (address & MASK_XLEN) << bit
    bit += XLEN
    val |= (rob_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if valid else 0) << bit
    return val


def pack_sq_forward(
    match: bool = False,
    can_forward: bool = False,
    data: int = 0,
) -> int:
    """Pack sq_forward_result_t into bit vector."""
    val = 0
    bit = 0
    val |= (data & MASK64) << bit
    bit += FLEN
    val |= (1 if can_forward else 0) << bit
    bit += 1
    val |= (1 if match else 0) << bit
    return val


def unpack_fu_complete(raw: int) -> FuComplete:
    """Unpack fu_complete_t bit vector."""
    bit = 0
    fp_flags = (raw >> bit) & 0x1F
    bit += 5
    exc_cause = (raw >> bit) & 0x1F
    bit += 5
    exception = bool((raw >> bit) & 1)
    bit += 1
    value = (raw >> bit) & MASK64
    bit += FLEN
    tag = (raw >> bit) & MASK_TAG
    bit += ROB_TAG_WIDTH
    valid = bool((raw >> bit) & 1)
    return FuComplete(
        valid=valid,
        tag=tag,
        value=value,
        exception=exception,
        exc_cause=exc_cause,
        fp_flags=fp_flags,
    )


class LQInterface:
    """Interface to the Load Queue DUT."""

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    @property
    def clock(self) -> Any:
        """Return the clock signal."""
        return self.dut.i_clk

    async def reset_dut(self, cycles: int = 5) -> None:
        """Reset the DUT and initialize all inputs."""
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: rising edge then falling edge.

        Samples the memory launch just before the edge so a later
        ``drive_mem_response`` can tag the response with the launching
        request's tier and cached slot (see ``read_mem_request``).
        """
        self._sample_launch()
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _sample_launch(self) -> None:
        """Remember the request presented on o_mem_read_* (if any)."""
        if bool(self.dut.o_mem_read_en.value):
            addr = int(self.dut.o_mem_read_addr.value)
            self.last_launch_cached = addr >= CACHED_BASE
            self.last_launch_slot = int(self.dut.o_mem_read_id.value)

    def _init_inputs(self) -> None:
        """Initialize all input signals to safe defaults."""
        self.dut.i_alloc.value = 0
        # Slot-2 alloc (2-wide dispatch plumbing).  Defensive init
        # for the same reason as i_alloc — Verilator zero-inits top-module
        # inputs but explicit init avoids future X-propagation surprises.
        self.dut.i_alloc_2.value = 0
        self.dut.i_addr_update.value = 0
        self.dut.i_pre_issue_rob_tag.value = 0
        self.dut.i_pre_issue_needs_lq.value = 0
        self.dut.i_sq_all_older_addrs_known.value = 0
        self.dut.i_sq_forward.value = 0
        self.dut.i_mem_read_data.value = 0
        self.dut.i_mem_read_valid.value = 0
        self.dut.i_mem_read_is_cached.value = 0
        self.dut.i_mem_read_id.value = 0
        self.dut.i_mem_bus_busy.value = 0
        self.dut.i_mem_request_pending.value = 0
        self.dut.i_cached_resp_held.value = 0
        self.last_launch_cached = False
        self.last_launch_slot = 0
        self.dut.i_adapter_result_pending.value = 0
        self.dut.i_result_accepted.value = 0
        self.dut.i_rob_head_tag.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_flush_all.value = 0
        self.dut.i_early_recovery_flush.value = 0
        self.dut.i_cache_invalidate_valid.value = 0
        self.dut.i_cache_invalidate_addr.value = 0
        self.dut.i_sc_clear_reservation.value = 0
        self.dut.i_reservation_snoop_invalidate.value = 0
        self.dut.i_sq_empty.value = 0
        self.dut.i_sq_committed_empty.value = 1
        self.dut.i_trap_misaligned_accesses.value = 0
        self.dut.i_amo_mem_write_done.value = 0

    # =========================================================================
    # Allocation
    # =========================================================================

    def drive_alloc(
        self,
        rob_tag: int,
        is_fp: bool = False,
        size: int = 2,
        sign_ext: bool = False,
        is_lr: bool = False,
        is_amo: bool = False,
        amo_op: int = 0,
    ) -> None:
        """Drive allocation request."""
        self.dut.i_alloc.value = pack_lq_alloc(
            valid=True,
            rob_tag=rob_tag,
            is_fp=is_fp,
            size=size,
            sign_ext=sign_ext,
            is_lr=is_lr,
            is_amo=is_amo,
            amo_op=amo_op,
        )

    def drive_alloc_2(
        self,
        rob_tag: int,
        is_fp: bool = False,
        size: int = 2,
        sign_ext: bool = False,
        is_lr: bool = False,
        is_amo: bool = False,
        amo_op: int = 0,
    ) -> None:
        """Drive slot-2 allocation request."""
        self.dut.i_alloc_2.value = pack_lq_alloc(
            valid=True,
            rob_tag=rob_tag,
            is_fp=is_fp,
            size=size,
            sign_ext=sign_ext,
            is_lr=is_lr,
            is_amo=is_amo,
            amo_op=amo_op,
        )

    def clear_alloc(self) -> None:
        """Clear allocation request."""
        self.dut.i_alloc.value = 0

    def clear_alloc_2(self) -> None:
        """Clear slot-2 allocation request."""
        self.dut.i_alloc_2.value = 0

    # =========================================================================
    # Address-update look-ahead
    # =========================================================================

    def drive_pre_issue(self, rob_tag: int) -> None:
        """Drive the MEM-RS look-ahead one cycle before an address update."""
        self.dut.i_pre_issue_rob_tag.value = rob_tag & MASK_TAG
        self.dut.i_pre_issue_needs_lq.value = 1

    def clear_pre_issue(self) -> None:
        """Clear the MEM-RS address-update look-ahead."""
        self.dut.i_pre_issue_needs_lq.value = 0

    # =========================================================================
    # Address Update
    # =========================================================================

    def drive_addr_update(
        self,
        rob_tag: int,
        address: int,
        is_mmio: bool = False,
        amo_rs2: int = 0,
    ) -> None:
        """Drive address update."""
        self.dut.i_addr_update.value = pack_lq_addr_update(
            valid=True,
            rob_tag=rob_tag,
            address=address,
            is_mmio=is_mmio,
            amo_rs2=amo_rs2,
        )

    def clear_addr_update(self) -> None:
        """Clear address update."""
        self.dut.i_addr_update.value = 0

    # =========================================================================
    # SQ Disambiguation
    # =========================================================================

    def drive_sq_all_older_known(self, val: bool = True) -> None:
        """Drive i_sq_all_older_addrs_known."""
        self.dut.i_sq_all_older_addrs_known.value = 1 if val else 0

    def drive_sq_empty(self, val: bool = True) -> None:
        """Drive store-queue empty signal."""
        self.dut.i_sq_empty.value = 1 if val else 0

    def drive_sq_forward(
        self,
        match: bool = False,
        can_forward: bool = False,
        data: int = 0,
    ) -> None:
        """Drive SQ forwarding response."""
        self.dut.i_sq_forward.value = pack_sq_forward(match, can_forward, data)

    def clear_sq_forward(self) -> None:
        """Clear SQ forwarding response."""
        self.dut.i_sq_forward.value = 0

    def read_sq_check(self) -> dict:
        """Read SQ disambiguation check outputs."""
        return {
            "valid": bool(self.dut.o_sq_check_valid.value),
            "addr": int(self.dut.o_sq_check_addr.value),
            "rob_tag": int(self.dut.o_sq_check_rob_tag.value),
            "size": int(self.dut.o_sq_check_size.value),
        }

    # =========================================================================
    # Memory Interface
    # =========================================================================

    def drive_mem_response(
        self,
        data: int,
        *,
        dword: bool = False,
        cached: bool | None = None,
        slot: int | None = None,
    ) -> None:
        """Drive a memory read response beat.

        The data tier returns aligned 64-bit beats (hw/rtl/README.md, "Data-tier bus contract").
        For a full-beat (FLD) response pass ``dword=True`` with the 64-bit
        value.  Otherwise ``data`` is a 32-bit word: it is replicated into
        both word lanes so the response is correct at either ``addr[2]``,
        mirroring how word data is positioned on the store side.

        A response answers either the fast tier's single outstanding request
        or one cached slot: ``cached``/``slot`` default to the tier and slot
        of the most recent launch seen by ``step``/``read_mem_request`` (the
        router tags real responses the same way).
        """
        if dword:
            self.dut.i_mem_read_data.value = data & MASK64
        else:
            word = data & MASK32
            self.dut.i_mem_read_data.value = (word << 32) | word
        is_cached = self.last_launch_cached if cached is None else cached
        self.dut.i_mem_read_is_cached.value = 1 if is_cached else 0
        self.dut.i_mem_read_id.value = self.last_launch_slot if slot is None else slot
        self.dut.i_mem_read_valid.value = 1

    def clear_mem_response(self) -> None:
        """Clear memory read response."""
        self.dut.i_mem_read_valid.value = 0
        self.dut.i_mem_read_is_cached.value = 0

    def drive_mem_bus_busy(self, busy: bool = True) -> None:
        """Drive memory-bus busy input from SQ/AMO/backend recovery."""
        self.dut.i_mem_bus_busy.value = 1 if busy else 0

    def drive_mem_request_pending(self, pending: bool = True) -> None:
        """Drive the router's exact staged-but-unaccepted request status."""
        self.dut.i_mem_request_pending.value = 1 if pending else 0

    def drive_cached_resp_held(self, held: bool = True) -> None:
        """Drive the router's "cached response held behind a fast beat" flag."""
        self.dut.i_cached_resp_held.value = 1 if held else 0

    def drive_cache_invalidate(self, addr: int) -> None:
        """Drive L0 cache invalidation for one address."""
        self.dut.i_cache_invalidate_valid.value = 1
        self.dut.i_cache_invalidate_addr.value = addr & MASK_XLEN

    def clear_cache_invalidate(self) -> None:
        """Clear L0 cache invalidation."""
        self.dut.i_cache_invalidate_valid.value = 0

    def read_mem_request(self) -> dict:
        """Read memory read request outputs (and remember the launch)."""
        self._sample_launch()
        return {
            "en": bool(self.dut.o_mem_read_en.value),
            "addr": int(self.dut.o_mem_read_addr.value),
            "size": int(self.dut.o_mem_read_size.value),
            "id": int(self.dut.o_mem_read_id.value),
        }

    # =========================================================================
    # CDB / FU Complete
    # =========================================================================

    def drive_result_accepted(self, accepted: bool = True) -> None:
        """Drive the staged-result acceptance handshake."""
        self.dut.i_result_accepted.value = 1 if accepted else 0

    def clear_result_accepted(self) -> None:
        """Clear the staged-result acceptance handshake."""
        self.dut.i_result_accepted.value = 0

    def read_fu_complete(self) -> FuComplete:
        """Read fu_complete output."""
        raw = int(self.dut.o_fu_complete.value)
        return unpack_fu_complete(raw)

    async def accept_fu_complete(self) -> None:
        """Pulse acceptance for the currently-presented staged result."""
        self.drive_result_accepted(True)
        await self.step()
        self.clear_result_accepted()

    # =========================================================================
    # ROB Head Tag
    # =========================================================================

    def drive_rob_head_tag(self, tag: int) -> None:
        """Drive ROB head tag."""
        self.dut.i_rob_head_tag.value = tag & MASK_TAG

    # =========================================================================
    # Flush
    # =========================================================================

    def drive_flush_all(self) -> None:
        """Assert full flush."""
        self.dut.i_flush_all.value = 1

    def clear_flush_all(self) -> None:
        """Deassert full flush."""
        self.dut.i_flush_all.value = 0

    def drive_partial_flush(self, flush_tag: int, early_recovery: bool = False) -> None:
        """Drive a partial flush, optionally from the early-recovery phase."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag & MASK_TAG
        self.dut.i_early_recovery_flush.value = 1 if early_recovery else 0

    def clear_partial_flush(self) -> None:
        """Deassert partial flush."""
        self.dut.i_flush_en.value = 0
        self.dut.i_early_recovery_flush.value = 0

    # =========================================================================
    # Status
    # =========================================================================

    @property
    def full(self) -> bool:
        """Return whether the load queue is full."""
        return bool(self.dut.o_full.value)

    @property
    def full_for_2(self) -> bool:
        """Return whether there is room for fewer than two new entries."""
        return bool(self.dut.o_full_for_2.value)

    @property
    def empty(self) -> bool:
        """Return whether the load queue is empty."""
        return bool(self.dut.o_empty.value)

    @property
    def count(self) -> int:
        """Return the number of valid load queue entries."""
        return int(self.dut.o_count.value)

    @property
    def mem_outstanding(self) -> bool:
        """Return whether the LQ is tracking a live memory response owner."""
        return bool(self.dut.o_mem_outstanding.value)

    # =========================================================================
    # Reservation Register (LR/SC)
    # =========================================================================

    def read_reservation_valid(self) -> bool:
        """Read reservation valid output."""
        return bool(self.dut.o_reservation_valid.value)

    def read_reservation_addr(self) -> int:
        """Read reservation address output."""
        return int(self.dut.o_reservation_addr.value)

    def drive_sc_clear_reservation(self, val: bool = True) -> None:
        """Drive SC clear reservation signal."""
        self.dut.i_sc_clear_reservation.value = 1 if val else 0

    def drive_reservation_snoop_invalidate(self, val: bool = True) -> None:
        """Drive reservation snoop invalidation signal."""
        self.dut.i_reservation_snoop_invalidate.value = 1 if val else 0

    # =========================================================================
    # SQ Committed-Empty
    # =========================================================================

    def drive_sq_committed_empty(self, val: bool = True) -> None:
        """Drive the committed-store-empty AMO serialization status."""
        self.dut.i_sq_committed_empty.value = 1 if val else 0

    def drive_trap_misaligned_accesses(self, val: bool = True) -> None:
        """Enable or disable architectural misaligned-load traps."""
        self.dut.i_trap_misaligned_accesses.value = 1 if val else 0

    # =========================================================================
    # AMO Memory Write Interface
    # =========================================================================

    def read_amo_mem_write(self) -> dict:
        """Read AMO memory write request outputs."""
        return {
            "en": bool(self.dut.o_amo_mem_write_en.value),
            "addr": int(self.dut.o_amo_mem_write_addr.value),
            "data": int(self.dut.o_amo_mem_write_data.value),
            "is_dword": bool(self.dut.o_amo_mem_write_is_dword.value),
        }

    def drive_amo_mem_write_done(self, val: bool = True) -> None:
        """Drive AMO memory write done signal."""
        self.dut.i_amo_mem_write_done.value = 1 if val else 0

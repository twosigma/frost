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

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
XLEN = 32
FLEN = 64

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK32 = (1 << XLEN) - 1
MASK64 = (1 << FLEN) - 1

# lq_alloc_req_t packed layout (MSB-first in SV):
# sign_ext(1) | size(2) | is_fp(1) | rob_tag(5) | valid(1) = 10 bits
LQ_ALLOC_WIDTH = 10

# lq_addr_update_t packed layout:
# is_mmio(1) | address(32) | rob_tag(5) | valid(1) = 39 bits
LQ_ADDR_UPDATE_WIDTH = 39

# sq_forward_result_t packed layout:
# data(64) | can_forward(1) | match(1) = 66 bits
SQ_FORWARD_WIDTH = 66

# fu_complete_t packed layout:
# fp_flags(5) | exc_cause(5) | exception(1) | value(64) | tag(5) | valid(1) = 81 bits
FU_COMPLETE_WIDTH = 81


def pack_lq_alloc(
    valid: bool = False,
    rob_tag: int = 0,
    is_fp: bool = False,
    size: int = 2,
    sign_ext: bool = False,
) -> int:
    """Pack lq_alloc_req_t into bit vector."""
    val = 0
    bit = 0
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
) -> int:
    """Pack lq_addr_update_t into bit vector."""
    val = 0
    bit = 0
    val |= (1 if is_mmio else 0) << bit
    bit += 1
    val |= (address & MASK32) << bit
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
        """Advance one cycle: rising edge then falling edge."""
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _init_inputs(self) -> None:
        """Initialize all input signals to safe defaults."""
        self.dut.i_alloc.value = 0
        self.dut.i_addr_update.value = 0
        self.dut.i_sq_all_older_addrs_known.value = 0
        self.dut.i_sq_forward.value = 0
        self.dut.i_mem_read_data.value = 0
        self.dut.i_mem_read_valid.value = 0
        self.dut.i_adapter_result_pending.value = 0
        self.dut.i_rob_head_tag.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_flush_all.value = 0
        self.dut.i_cache_invalidate_valid.value = 0
        self.dut.i_cache_invalidate_addr.value = 0

    # =========================================================================
    # Allocation
    # =========================================================================

    def drive_alloc(
        self,
        rob_tag: int,
        is_fp: bool = False,
        size: int = 2,
        sign_ext: bool = False,
    ) -> None:
        """Drive allocation request."""
        self.dut.i_alloc.value = pack_lq_alloc(
            valid=True, rob_tag=rob_tag, is_fp=is_fp, size=size, sign_ext=sign_ext
        )

    def clear_alloc(self) -> None:
        """Clear allocation request."""
        self.dut.i_alloc.value = 0

    # =========================================================================
    # Address Update
    # =========================================================================

    def drive_addr_update(
        self, rob_tag: int, address: int, is_mmio: bool = False
    ) -> None:
        """Drive address update."""
        self.dut.i_addr_update.value = pack_lq_addr_update(
            valid=True, rob_tag=rob_tag, address=address, is_mmio=is_mmio
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

    def drive_mem_response(self, data: int) -> None:
        """Drive memory read response."""
        self.dut.i_mem_read_data.value = data & MASK32
        self.dut.i_mem_read_valid.value = 1

    def clear_mem_response(self) -> None:
        """Clear memory read response."""
        self.dut.i_mem_read_valid.value = 0

    def read_mem_request(self) -> dict:
        """Read memory read request outputs."""
        return {
            "en": bool(self.dut.o_mem_read_en.value),
            "addr": int(self.dut.o_mem_read_addr.value),
            "size": int(self.dut.o_mem_read_size.value),
        }

    # =========================================================================
    # CDB / FU Complete
    # =========================================================================

    def drive_adapter_pending(self, pending: bool = True) -> None:
        """Drive adapter back-pressure signal."""
        self.dut.i_adapter_result_pending.value = 1 if pending else 0

    def read_fu_complete(self) -> FuComplete:
        """Read fu_complete output."""
        raw = int(self.dut.o_fu_complete.value)
        return unpack_fu_complete(raw)

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

    def drive_partial_flush(self, flush_tag: int) -> None:
        """Drive partial flush."""
        self.dut.i_flush_en.value = 1
        self.dut.i_flush_tag.value = flush_tag & MASK_TAG

    def clear_partial_flush(self) -> None:
        """Deassert partial flush."""
        self.dut.i_flush_en.value = 0

    # =========================================================================
    # Status
    # =========================================================================

    @property
    def full(self) -> bool:
        """Return whether the load queue is full."""
        return bool(self.dut.o_full.value)

    @property
    def empty(self) -> bool:
        """Return whether the load queue is empty."""
        return bool(self.dut.o_empty.value)

    @property
    def count(self) -> int:
        """Return the number of valid load queue entries."""
        return int(self.dut.o_count.value)

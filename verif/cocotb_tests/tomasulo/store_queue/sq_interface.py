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

"""DUT interface for Store Queue verification.

Provides packing/unpacking for sq_alloc_req_t, sq_addr_update_t,
sq_data_update_t, sq_forward_result_t and transaction helpers for
driving stimulus and reading results.
"""

from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge

from .sq_model import ForwardResult, MemWriteReq

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
XLEN = 32
FLEN = 64

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK32 = (1 << XLEN) - 1
MASK64 = (1 << FLEN) - 1

# sq_alloc_req_t packed layout (MSB-first in SV):
# size(2) | is_fp(1) | rob_tag(5) | valid(1) = 9 bits
SQ_ALLOC_WIDTH = 9

# sq_addr_update_t packed layout:
# is_mmio(1) | address(32) | rob_tag(5) | valid(1) = 39 bits
SQ_ADDR_UPDATE_WIDTH = 39

# sq_data_update_t packed layout:
# data(64) | rob_tag(5) | valid(1) = 70 bits
SQ_DATA_UPDATE_WIDTH = 70

# sq_forward_result_t packed layout:
# data(64) | can_forward(1) | match(1) = 66 bits
SQ_FORWARD_WIDTH = 66


def pack_sq_alloc(
    valid: bool = False,
    rob_tag: int = 0,
    is_fp: bool = False,
    size: int = 2,
) -> int:
    """Pack sq_alloc_req_t into bit vector."""
    val = 0
    bit = 0
    val |= (size & 0x3) << bit
    bit += 2
    val |= (1 if is_fp else 0) << bit
    bit += 1
    val |= (rob_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if valid else 0) << bit
    return val


def pack_sq_addr_update(
    valid: bool = False,
    rob_tag: int = 0,
    address: int = 0,
    is_mmio: bool = False,
) -> int:
    """Pack sq_addr_update_t into bit vector."""
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


def pack_sq_data_update(
    valid: bool = False,
    rob_tag: int = 0,
    data: int = 0,
) -> int:
    """Pack sq_data_update_t into bit vector."""
    val = 0
    bit = 0
    val |= (data & MASK64) << bit
    bit += FLEN
    val |= (rob_tag & MASK_TAG) << bit
    bit += ROB_TAG_WIDTH
    val |= (1 if valid else 0) << bit
    return val


def unpack_sq_forward(raw: int) -> ForwardResult:
    """Unpack sq_forward_result_t bit vector."""
    bit = 0
    data = (raw >> bit) & MASK64
    bit += FLEN
    can_forward = bool((raw >> bit) & 1)
    bit += 1
    match = bool((raw >> bit) & 1)
    return ForwardResult(match=match, can_forward=can_forward, data=data)


class SQInterface:
    """Interface to the Store Queue DUT."""

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
        self.dut.i_data_update.value = 0
        self.dut.i_commit_valid.value = 0
        self.dut.i_commit_rob_tag.value = 0
        self.dut.i_sq_check_valid.value = 0
        self.dut.i_sq_check_addr.value = 0
        self.dut.i_sq_check_rob_tag.value = 0
        self.dut.i_sq_check_size.value = 0
        self.dut.i_mem_write_done.value = 0
        self.dut.i_rob_head_tag.value = 0
        self.dut.i_flush_en.value = 0
        self.dut.i_flush_tag.value = 0
        self.dut.i_flush_all.value = 0

    # =========================================================================
    # Allocation
    # =========================================================================

    def drive_alloc(
        self,
        rob_tag: int,
        is_fp: bool = False,
        size: int = 2,
    ) -> None:
        """Drive allocation request."""
        self.dut.i_alloc.value = pack_sq_alloc(
            valid=True, rob_tag=rob_tag, is_fp=is_fp, size=size
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
        self.dut.i_addr_update.value = pack_sq_addr_update(
            valid=True, rob_tag=rob_tag, address=address, is_mmio=is_mmio
        )

    def clear_addr_update(self) -> None:
        """Clear address update."""
        self.dut.i_addr_update.value = 0

    # =========================================================================
    # Data Update
    # =========================================================================

    def drive_data_update(self, rob_tag: int, data: int) -> None:
        """Drive data update."""
        self.dut.i_data_update.value = pack_sq_data_update(
            valid=True, rob_tag=rob_tag, data=data
        )

    def clear_data_update(self) -> None:
        """Clear data update."""
        self.dut.i_data_update.value = 0

    # =========================================================================
    # Commit
    # =========================================================================

    def drive_commit(self, rob_tag: int) -> None:
        """Drive commit signal for a store."""
        self.dut.i_commit_valid.value = 1
        self.dut.i_commit_rob_tag.value = rob_tag & MASK_TAG

    def clear_commit(self) -> None:
        """Clear commit signal."""
        self.dut.i_commit_valid.value = 0

    # =========================================================================
    # Store-to-Load Forwarding Check
    # =========================================================================

    def drive_sq_check(self, addr: int, rob_tag: int, size: int = 2) -> None:
        """Drive forwarding check from LQ."""
        self.dut.i_sq_check_valid.value = 1
        self.dut.i_sq_check_addr.value = addr & MASK32
        self.dut.i_sq_check_rob_tag.value = rob_tag & MASK_TAG
        self.dut.i_sq_check_size.value = size

    def clear_sq_check(self) -> None:
        """Clear forwarding check."""
        self.dut.i_sq_check_valid.value = 0

    def read_sq_forward(self) -> ForwardResult:
        """Read SQ forwarding result outputs."""
        raw = int(self.dut.o_sq_forward.value)
        return unpack_sq_forward(raw)

    def read_all_older_addrs_known(self) -> bool:
        """Read all_older_addrs_known output."""
        return bool(self.dut.o_sq_all_older_addrs_known.value)

    # =========================================================================
    # Memory Write Interface
    # =========================================================================

    def read_mem_write(self) -> MemWriteReq:
        """Read memory write request outputs."""
        return MemWriteReq(
            en=bool(self.dut.o_mem_write_en.value),
            addr=int(self.dut.o_mem_write_addr.value),
            data=int(self.dut.o_mem_write_data.value),
            byte_en=int(self.dut.o_mem_write_byte_en.value),
        )

    def drive_mem_write_done(self) -> None:
        """Assert memory write done."""
        self.dut.i_mem_write_done.value = 1

    def clear_mem_write_done(self) -> None:
        """Deassert memory write done."""
        self.dut.i_mem_write_done.value = 0

    # =========================================================================
    # Cache Invalidation
    # =========================================================================

    def read_cache_invalidate(self) -> dict:
        """Read cache invalidation outputs."""
        return {
            "valid": bool(self.dut.o_cache_invalidate_valid.value),
            "addr": int(self.dut.o_cache_invalidate_addr.value),
        }

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
        """Return whether the store queue is full."""
        return bool(self.dut.o_full.value)

    @property
    def empty(self) -> bool:
        """Return whether the store queue is empty."""
        return bool(self.dut.o_empty.value)

    @property
    def count(self) -> int:
        """Return the number of valid store queue entries."""
        return int(self.dut.o_count.value)

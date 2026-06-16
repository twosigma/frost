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

"""Unit tests for the CPU OOO data-memory request router.

Covers the three-way arbitration (SQ > AMO > queued LQ reads), the MMIO
sidebands, and the cached-tier handshake: tier-routed enables, the
write-inflight port hold, and the per-tier read-valid/data muxing.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CLOCK_PERIOD_NS = 10
MMIO_ADDR = 0x40000000
UART_RX_DATA_MMIO_ADDR = MMIO_ADDR + 0x4
FIFO0_MMIO_ADDR = MMIO_ADDR + 0x8
FIFO1_MMIO_ADDR = MMIO_ADDR + 0xC
CACHED_BASE = 0x80000000
FAST_ADDR = 0x100
CACHED_ADDR = CACHED_BASE + 0x1234


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_sq_mem_write_en.value = 0
    dut.i_sq_mem_write_addr.value = 0
    dut.i_sq_mem_write_data.value = 0
    dut.i_sq_mem_write_byte_en.value = 0
    dut.i_sq_mem_write_is_mmio.value = 0
    dut.i_sq_mem_write_is_cached.value = 0
    dut.i_amo_mem_write_en.value = 0
    dut.i_amo_mem_write_addr.value = 0
    dut.i_amo_mem_write_data.value = 0
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_read_addr.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    dut.i_data_mem_rd_data.value = 0
    dut.i_cached_read_data.value = 0
    dut.i_cached_read_valid.value = 0
    dut.i_cached_write_done.value = 0
    dut.i_cached_write_inflight.value = 0


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset router state, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await Timer(1, unit="ns")


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


@cocotb.test()
async def test_fast_sq_write_done_next_cycle(dut: Any) -> None:
    """A low-BRAM SQ write asserts BRAM enables and done one cycle later."""
    await _setup_test(dut)
    dut.i_sq_mem_write_en.value = 1
    dut.i_sq_mem_write_addr.value = FAST_ADDR
    dut.i_sq_mem_write_data.value = 0xDEADBEEF
    dut.i_sq_mem_write_byte_en.value = 0b1111
    await _settle()
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0b1111
    assert int(dut.o_data_mem_cached_byte_wr_en.value) == 0
    assert int(dut.o_data_mem_addr.value) == FAST_ADDR
    assert int(dut.o_sq_mem_write_done.value) == 0
    await _advance_cycle(dut)
    dut.i_sq_mem_write_en.value = 0
    dut.i_sq_mem_write_byte_en.value = 0
    await _settle()
    assert int(dut.o_sq_mem_write_done.value) == 1
    await _advance_cycle(dut)
    assert int(dut.o_sq_mem_write_done.value) == 0


@cocotb.test()
async def test_cached_sq_write_handshake(dut: Any) -> None:
    """Check a cached SQ write: masked off BRAM, completes on cached done."""
    await _setup_test(dut)
    dut.i_sq_mem_write_en.value = 1
    dut.i_sq_mem_write_addr.value = CACHED_ADDR
    dut.i_sq_mem_write_data.value = 0xA5A5A5A5
    dut.i_sq_mem_write_byte_en.value = 0b0011
    dut.i_sq_mem_write_is_cached.value = 1
    await _settle()
    assert (
        int(dut.o_data_mem_bram_byte_wr_en.value) == 0
    ), "cached store must not hit BRAM"
    assert int(dut.o_data_mem_cached_byte_wr_en.value) == 0b0011
    await _advance_cycle(dut)
    dut.i_sq_mem_write_en.value = 0
    dut.i_sq_mem_write_byte_en.value = 0
    dut.i_sq_mem_write_is_cached.value = 0
    # Adapter is now busy with the store.
    dut.i_cached_write_inflight.value = 1
    await _settle()
    assert int(dut.o_sq_mem_write_done.value) == 0, "no fast done for a cached store"
    # Several cycles later the adapter reports completion.
    for _ in range(5):
        await _advance_cycle(dut)
        assert int(dut.o_sq_mem_write_done.value) == 0
    dut.i_cached_write_done.value = 1
    dut.i_cached_write_inflight.value = 0
    await _settle()
    assert int(dut.o_sq_mem_write_done.value) == 1
    await _advance_cycle(dut)
    dut.i_cached_write_done.value = 0


@cocotb.test()
async def test_load_queued_behind_cached_write_inflight(dut: Any) -> None:
    """Check a load queues behind a cached store and issues after done."""
    await _setup_test(dut)
    dut.i_cached_write_inflight.value = 1
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = FAST_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert (
        int(dut.o_data_mem_read_enable.value) == 0
    ), "load must wait for the cached store"
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 1, "load must be queued"
    assert int(dut.o_data_mem_read_enable.value) == 0
    # Store completes: the queued load issues.
    dut.i_cached_write_inflight.value = 0
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_data_mem_addr.value) == FAST_ADDR
    dut.i_data_mem_rd_data.value = 0x12345678
    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_read_valid.value) == 1
    assert int(dut.o_lq_mem_read_data.value) == 0x12345678


@cocotb.test()
async def test_fast_read_one_cycle_valid(dut: Any) -> None:
    """A low-BRAM load returns data with the 1-cycle valid pulse."""
    await _setup_test(dut)
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = FAST_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_data_mem_cached_read_enable.value) == 0
    dut.i_data_mem_rd_data.value = 0xCAFE0001
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    await _settle()
    assert int(dut.o_lq_mem_read_valid.value) == 1
    assert int(dut.o_lq_mem_read_data.value) == 0xCAFE0001
    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_read_valid.value) == 0


@cocotb.test()
async def test_cached_read_handshake(dut: Any) -> None:
    """Check a cached load completes only on i_cached_read_valid."""
    await _setup_test(dut)
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = CACHED_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_data_mem_cached_read_enable.value) == 1
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    await _settle()
    # The fast tap must NOT fire for a cached load.
    assert int(dut.o_lq_mem_read_valid.value) == 0
    for _ in range(7):
        await _advance_cycle(dut)
        assert int(dut.o_lq_mem_read_valid.value) == 0
    dut.i_cached_read_valid.value = 1
    dut.i_cached_read_data.value = 0x0DDC0FFE
    await _settle()
    assert int(dut.o_lq_mem_read_valid.value) == 1
    assert int(dut.o_lq_mem_read_data.value) == 0x0DDC0FFE
    await _advance_cycle(dut)
    dut.i_cached_read_valid.value = 0
    await _settle()
    assert int(dut.o_lq_mem_read_valid.value) == 0


@cocotb.test()
async def test_mmio_read_pulse(dut: Any) -> None:
    """An MMIO load raises the MMIO pulse/valid sideband (not the cached one)."""
    await _setup_test(dut)
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = MMIO_ADDR + 0x10
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_mmio_read_pulse.value) == 1
    assert int(dut.o_mmio_load_valid.value) == 1
    assert int(dut.o_mmio_load_addr.value) == MMIO_ADDR + 0x10
    assert int(dut.o_data_mem_cached_read_enable.value) == 0
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0


@cocotb.test()
async def test_mmio_destructive_read_pulses_registered(dut: Any) -> None:
    """FIFO/UART-RX destructive-read side effects pulse one cycle after accept."""
    await _setup_test(dut)
    pulse_outputs = [
        "o_mmio_fifo0_read_pulse",
        "o_mmio_fifo1_read_pulse",
        "o_mmio_uart_rx_ready_pulse",
    ]
    cases = [
        (FIFO0_MMIO_ADDR, "o_mmio_fifo0_read_pulse"),
        (FIFO1_MMIO_ADDR, "o_mmio_fifo1_read_pulse"),
        (UART_RX_DATA_MMIO_ADDR, "o_mmio_uart_rx_ready_pulse"),
    ]

    for addr, expected_pulse in cases:
        dut.i_lq_mem_read_en.value = 1
        dut.i_lq_mem_read_addr.value = addr
        dut.i_lq_mem_addr_valid.value = 1
        await _settle()
        assert int(dut.o_mmio_read_pulse.value) == 1
        for output_name in pulse_outputs:
            assert int(getattr(dut, output_name).value) == 0

        await _advance_cycle(dut)
        for output_name in pulse_outputs:
            expected = 1 if output_name == expected_pulse else 0
            assert int(getattr(dut, output_name).value) == expected

        dut.i_lq_mem_read_en.value = 0
        dut.i_lq_mem_addr_valid.value = 0
        await _advance_cycle(dut)
        for output_name in pulse_outputs:
            assert int(getattr(dut, output_name).value) == 0


@cocotb.test()
async def test_amo_write_bram_and_priority(dut: Any) -> None:
    """Check AMO writes hit BRAM and defer to SQ priority."""
    await _setup_test(dut)
    # AMO alone: done combinationally, BRAM write-enable asserted.
    dut.i_amo_mem_write_en.value = 1
    dut.i_amo_mem_write_addr.value = FAST_ADDR + 8
    dut.i_amo_mem_write_data.value = 0x77
    await _settle()
    assert int(dut.o_amo_mem_write_done.value) == 1
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0b1111
    # SQ arrives: AMO must defer.
    dut.i_sq_mem_write_en.value = 1
    dut.i_sq_mem_write_addr.value = FAST_ADDR
    dut.i_sq_mem_write_byte_en.value = 0b1111
    await _settle()
    assert int(dut.o_amo_mem_write_done.value) == 0
    assert int(dut.o_data_mem_addr.value) == FAST_ADDR, "SQ owns the address mux"
    dut.i_sq_mem_write_en.value = 0
    dut.i_sq_mem_write_byte_en.value = 0
    dut.i_amo_mem_write_en.value = 0
    await _advance_cycle(dut)


@cocotb.test()
async def test_amo_cached_write_handshake(dut: Any) -> None:
    """A cached-region AMO write is masked off BRAM and forwarded to the cache.

    The LQ holds i_amo_mem_write_en high for the whole write phase, so the
    adapter must see a SINGLE-CYCLE cached byte-enable pulse (it re-enqueues on
    every non-zero strobe cycle), the new value on o_data_mem_cached_wr_data
    that same cycle, and the AMO done only when the adapter reports completion.
    """
    await _setup_test(dut)
    dut.i_amo_mem_write_en.value = 1
    dut.i_amo_mem_write_addr.value = CACHED_ADDR
    dut.i_amo_mem_write_data.value = 0xCAFEF00D
    await _settle()
    # Launch cycle: masked off BRAM, single word-wide strobe to the cache, with
    # the AMO new value on the cached write-data bus. No done yet.
    assert (
        int(dut.o_data_mem_bram_byte_wr_en.value) == 0
    ), "cached AMO must not hit BRAM"
    assert int(dut.o_data_mem_cached_byte_wr_en.value) == 0b1111
    assert int(dut.o_data_mem_cached_wr_data.value) == 0xCAFEF00D
    assert int(dut.o_amo_mem_write_done.value) == 0, "no fast done for a cached AMO"
    await _advance_cycle(dut)
    # Adapter is now busy; the held enable must NOT re-pulse the cached strobe.
    dut.i_cached_write_inflight.value = 1
    await _settle()
    assert (
        int(dut.o_data_mem_cached_byte_wr_en.value) == 0
    ), "cached AMO strobe must be a single-cycle pulse"
    assert int(dut.o_amo_mem_write_done.value) == 0
    for _ in range(4):
        await _advance_cycle(dut)
        assert int(dut.o_data_mem_cached_byte_wr_en.value) == 0
        assert int(dut.o_amo_mem_write_done.value) == 0
    # Adapter reports completion: AMO done pulses, SQ done stays low (no store).
    dut.i_cached_write_done.value = 1
    dut.i_cached_write_inflight.value = 0
    await _settle()
    assert int(dut.o_amo_mem_write_done.value) == 1
    assert (
        int(dut.o_sq_mem_write_done.value) == 0
    ), "cached AMO done must not hit the SQ"
    dut.i_amo_mem_write_en.value = 0
    dut.i_cached_write_done.value = 0
    await _advance_cycle(dut)
    assert int(dut.o_amo_mem_write_done.value) == 0


@cocotb.test()
async def test_amo_mmio_write_still_dropped(dut: Any) -> None:
    """An AMO to the MMIO window is masked from BRAM and the cache (undefined)."""
    await _setup_test(dut)
    dut.i_amo_mem_write_en.value = 1
    dut.i_amo_mem_write_addr.value = MMIO_ADDR + 0x10
    dut.i_amo_mem_write_data.value = 0x55
    await _settle()
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0
    assert int(dut.o_data_mem_cached_byte_wr_en.value) == 0
    # MMIO AMO completes combinationally (it is not a cached write).
    assert int(dut.o_amo_mem_write_done.value) == 1
    dut.i_amo_mem_write_en.value = 0
    await _advance_cycle(dut)


@cocotb.test()
async def test_cached_read_enable_not_spurious(dut: Any) -> None:
    """Check low-BRAM loads never pulse the cached read enable."""
    await _setup_test(dut)
    for addr in (0x0, 0x1FFC, FAST_ADDR):
        dut.i_lq_mem_read_en.value = 1
        dut.i_lq_mem_read_addr.value = addr
        dut.i_lq_mem_addr_valid.value = 1
        await _settle()
        assert int(dut.o_data_mem_cached_read_enable.value) == 0
        await _advance_cycle(dut)
        dut.i_lq_mem_read_en.value = 0
        dut.i_lq_mem_addr_valid.value = 0
        await _advance_cycle(dut)

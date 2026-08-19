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

Covers the three-way arbitration (SQ > AMO > queued LQ reads), mandatory
one-cycle device-request staging, the committed-store drain fence, MMIO
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
OUTSIDE_MMIO_DEVICE_ADDR = 0x50001234


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_sq_mem_write_en.value = 0
    dut.i_sq_mem_write_addr.value = 0
    dut.i_sq_mem_write_data.value = 0
    dut.i_sq_mem_write_byte_en.value = 0
    dut.i_sq_mem_write_is_mmio.value = 0
    dut.i_sq_mem_write_is_cached.value = 0
    dut.i_flush_all.value = 0
    # Normal operation begins with no committed store awaiting its device
    # write. Individual drain-fence tests close this status explicitly.
    dut.i_sq_committed_empty.value = 1
    dut.i_amo_mem_write_en.value = 0
    dut.i_amo_mem_write_addr.value = 0
    dut.i_amo_mem_write_data.value = 0
    dut.i_amo_mem_write_is_dword.value = 0
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
    """An MMIO load pulses only after its mandatory pending-register stage."""
    await _setup_test(dut)
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = MMIO_ADDR + 0x10
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_data_mem_cached_read_enable.value) == 0

    # The first edge captures the live device request. Acceptance and every
    # MMIO effect now derive only from that registered pending/address state.
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 1
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_mmio_read_pulse.value) == 1
    assert int(dut.o_mmio_load_valid.value) == 1
    assert int(dut.o_mmio_load_addr.value) == MMIO_ADDR + 0x10
    assert int(dut.o_data_mem_cached_read_enable.value) == 0

    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 1


@cocotb.test()
async def test_full_flush_cancels_staged_mmio_before_accept(dut: Any) -> None:
    """A next-cycle full flush cancels the staged request with no response."""
    await _setup_test(dut)
    dut.i_sq_committed_empty.value = 1
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = FIFO0_MMIO_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0

    # Model a registered full-flush source becoming visible in the cycle after
    # the live handoff edge. The pending Q/address were captured, but the flush
    # qualifier suppresses the terminal candidate before any sampling edge.
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    dut.i_flush_all.value = 1
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 1
    assert int(dut.o_mmio_load_addr.value) == FIFO0_MMIO_ADDR
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_data_mem_cached_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 0
    assert int(dut.o_mmio_fifo0_read_pulse.value) == 0
    assert int(dut.o_mmio_fifo1_read_pulse.value) == 0
    assert int(dut.o_mmio_uart_rx_ready_pulse.value) == 0

    await _advance_cycle(dut)
    dut.i_flush_all.value = 0
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 0
    assert int(dut.o_mmio_fifo0_read_pulse.value) == 0
    assert int(dut.o_mmio_fifo1_read_pulse.value) == 0
    assert int(dut.o_mmio_uart_rx_ready_pulse.value) == 0

    # No late pulse or fast-valid response may appear after cancellation.
    for _ in range(2):
        await _advance_cycle(dut)
        assert int(dut.o_lq_mem_read_valid.value) == 0
        assert int(dut.o_mmio_read_pulse.value) == 0
        assert int(dut.o_mmio_fifo0_read_pulse.value) == 0


@cocotb.test()
async def test_device_quadrant_always_parks_before_accept(dut: Any) -> None:
    """Even with an open drain, unmapped device space cannot accept live."""
    await _setup_test(dut)
    dut.i_sq_committed_empty.value = 1
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = OUTSIDE_MMIO_DEVICE_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()

    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0

    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    dut.i_data_mem_rd_data.value = 0x5A5A1234
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 1
    assert int(dut.o_data_mem_addr.value) == OUTSIDE_MMIO_DEVICE_ADDR
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_data_mem_cached_read_enable.value) == 0

    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 1
    assert int(dut.o_lq_mem_read_data.value) == 0x5A5A1234


@cocotb.test()
async def test_device_drain_high_to_low_after_capture_blocks_accept(dut: Any) -> None:
    """A same-edge new committed store closes drain before pending accept."""
    await _setup_test(dut)
    dut.i_sq_committed_empty.value = 1
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = MMIO_ADDR + 0x10
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 0

    # The live handoff sees the old high status. Immediately after its capture
    # edge, model the SQ's same-edge commit-pessimistic status falling low.
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    dut.i_sq_committed_empty.value = 0
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 1
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0

    for _ in range(2):
        await _advance_cycle(dut)
        assert int(dut.o_lq_mem_request_valid.value) == 1
        assert int(dut.o_data_mem_read_enable.value) == 0
        assert int(dut.o_mmio_read_pulse.value) == 0

    # Reopening the drain releases the held request exactly once.
    dut.i_sq_committed_empty.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_mmio_read_pulse.value) == 1
    assert int(dut.o_mmio_load_valid.value) == 1
    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 1
    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_read_valid.value) == 0


@cocotb.test()
async def test_device_quadrant_boundary_table_and_drain_scope(dut: Any) -> None:
    """Check every quadrant boundary and confine drain gating to quadrant 01."""
    await _setup_test(dut)
    cases = (
        (0x3FFF_FFFF, False, False, False),
        (0x4000_0000, True, False, True),
        (0x7FFF_FFFF, True, False, False),
        (0x8000_0000, False, True, False),
        (0xBFFF_FFFF, False, True, False),
        (0xC000_0000, False, False, False),
        (0xFFFF_FFFF, False, False, False),
    )

    async def reset_between_cases() -> None:
        _clear_inputs(dut)
        dut.i_rst.value = 1
        await _advance_cycle(dut)
        dut.i_rst.value = 0
        await _settle()

    # With drain open, only quadrant 01 must stage; all other quadrants retain
    # the live low-BRAM/cached/unmapped bypass behavior.
    for index, (addr, is_device, is_cached, is_mmio) in enumerate(cases):
        if index:
            await reset_between_cases()
        dut.i_sq_committed_empty.value = 1
        dut.i_lq_mem_read_en.value = 1
        dut.i_lq_mem_read_addr.value = addr
        dut.i_lq_mem_addr_valid.value = 1
        await _settle()
        assert int(dut.o_data_mem_addr.value) == addr
        assert int(dut.o_data_mem_read_enable.value) == (0 if is_device else 1)
        assert int(dut.o_data_mem_cached_read_enable.value) == (1 if is_cached else 0)
        assert int(dut.o_mmio_read_pulse.value) == 0
        assert int(dut.o_mmio_load_valid.value) == 0

        await _advance_cycle(dut)
        dut.i_lq_mem_read_en.value = 0
        dut.i_lq_mem_addr_valid.value = 0
        await _settle()
        if is_device:
            assert int(dut.o_lq_mem_request_valid.value) == 1
            assert int(dut.o_data_mem_addr.value) == addr
            assert int(dut.o_data_mem_read_enable.value) == 1
            assert int(dut.o_data_mem_cached_read_enable.value) == 0
            assert int(dut.o_mmio_read_pulse.value) == (1 if is_mmio else 0)
            assert int(dut.o_mmio_load_valid.value) == (1 if is_mmio else 0)
            await _advance_cycle(dut)
            assert int(dut.o_lq_mem_request_valid.value) == 0
        else:
            assert int(dut.o_lq_mem_request_valid.value) == 0

    # Closing committed-empty changes only the two quadrant-01 boundary cases.
    for addr, is_device, is_cached, _ in cases:
        await reset_between_cases()
        dut.i_sq_committed_empty.value = 0
        dut.i_lq_mem_read_en.value = 1
        dut.i_lq_mem_read_addr.value = addr
        dut.i_lq_mem_addr_valid.value = 1
        await _settle()
        assert int(dut.o_data_mem_read_enable.value) == (0 if is_device else 1)
        assert int(dut.o_data_mem_cached_read_enable.value) == (1 if is_cached else 0)
        await _advance_cycle(dut)
        dut.i_lq_mem_read_en.value = 0
        dut.i_lq_mem_addr_valid.value = 0
        await _settle()
        if is_device:
            assert int(dut.o_lq_mem_request_valid.value) == 1
            assert int(dut.o_data_mem_read_enable.value) == 0
            assert int(dut.o_mmio_read_pulse.value) == 0
            dut.i_sq_committed_empty.value = 1
            await _settle()
            assert int(dut.o_data_mem_read_enable.value) == 1
            await _advance_cycle(dut)
            assert int(dut.o_lq_mem_request_valid.value) == 0
        else:
            assert int(dut.o_lq_mem_request_valid.value) == 0


@cocotb.test()
async def test_device_read_parks_until_store_drain_then_releases_once(
    dut: Any,
) -> None:
    """A staged device read stays inert and stable until drain, then releases."""
    await _setup_test(dut)

    destructive_outputs = (
        "o_mmio_fifo0_read_pulse",
        "o_mmio_fifo1_read_pulse",
        "o_mmio_uart_rx_ready_pulse",
    )
    held_addr = FIFO0_MMIO_ADDR
    dut.i_sq_committed_empty.value = 0
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = held_addr
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()

    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_data_mem_cached_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 0
    for output_name in destructive_outputs:
        assert int(getattr(dut, output_name).value) == 0

    # Park the request, then remove and perturb the live LQ inputs. The parked
    # address must remain the sole candidate while the drain status is closed.
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 1
    dut.i_lq_mem_read_addr.value = CACHED_ADDR
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 1
    for cycle in range(3):
        assert int(dut.o_data_mem_addr.value) == held_addr
        assert int(dut.o_mmio_load_addr.value) == held_addr
        assert int(dut.o_data_mem_read_enable.value) == 0
        assert int(dut.o_data_mem_cached_read_enable.value) == 0
        assert int(dut.o_mmio_read_pulse.value) == 0
        assert int(dut.o_mmio_load_valid.value) == 0
        assert int(dut.o_lq_mem_read_valid.value) == 0
        for output_name in destructive_outputs:
            assert int(getattr(dut, output_name).value) == 0
        await _advance_cycle(dut)

    # Opening the drain fence accepts exactly the held read. The destructive
    # side effect and fast response-valid each occur on the following cycle.
    dut.i_lq_mem_addr_valid.value = 0
    dut.i_sq_committed_empty.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_data_mem_addr.value) == held_addr
    assert int(dut.o_mmio_load_addr.value) == held_addr
    assert int(dut.o_mmio_read_pulse.value) == 1
    assert int(dut.o_mmio_load_valid.value) == 1
    assert int(dut.o_data_mem_cached_read_enable.value) == 0

    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 1
    assert int(dut.o_mmio_fifo0_read_pulse.value) == 1
    assert int(dut.o_mmio_fifo1_read_pulse.value) == 0
    assert int(dut.o_mmio_uart_rx_ready_pulse.value) == 0

    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_read_valid.value) == 0
    for output_name in destructive_outputs:
        assert int(getattr(dut, output_name).value) == 0
    for _ in range(2):
        await _advance_cycle(dut)
        assert int(dut.o_data_mem_read_enable.value) == 0
        assert int(dut.o_mmio_read_pulse.value) == 0
        assert int(dut.o_lq_mem_read_valid.value) == 0


@cocotb.test()
async def test_device_read_waits_for_write_port_and_store_drain(dut: Any) -> None:
    """Both the write-port conflict and committed-store drain block release."""
    await _setup_test(dut)

    held_addr = MMIO_ADDR + 0x10
    dut.i_sq_committed_empty.value = 0
    dut.i_sq_mem_write_en.value = 1
    dut.i_sq_mem_write_addr.value = FAST_ADDR
    dut.i_sq_mem_write_byte_en.value = 0b1111
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = held_addr
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 0

    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    assert int(dut.o_lq_mem_request_valid.value) == 1

    # Drain status alone cannot release while the SQ still owns the port.
    dut.i_sq_committed_empty.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    await _advance_cycle(dut)

    # Likewise, freeing the port cannot release while the drain closes again.
    dut.i_sq_committed_empty.value = 0
    dut.i_sq_mem_write_en.value = 0
    dut.i_sq_mem_write_byte_en.value = 0
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    await _advance_cycle(dut)

    dut.i_sq_committed_empty.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_data_mem_addr.value) == held_addr
    assert int(dut.o_mmio_read_pulse.value) == 1
    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_data_mem_read_enable.value) == 0


@cocotb.test()
async def test_reset_discards_parked_device_read(dut: Any) -> None:
    """Reset clears a drain-blocked request without releasing its side effect."""
    await _setup_test(dut)

    dut.i_sq_committed_empty.value = 0
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = FIFO1_MMIO_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    assert int(dut.o_lq_mem_request_valid.value) == 1

    # Opening the drain while reset is asserted must not expose the old pending
    # request in the interval before the reset edge.
    dut.i_sq_committed_empty.value = 1
    dut.i_rst.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_data_mem_cached_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 0
    assert int(dut.o_mmio_fifo0_read_pulse.value) == 0
    assert int(dut.o_mmio_fifo1_read_pulse.value) == 0
    assert int(dut.o_mmio_uart_rx_ready_pulse.value) == 0
    await _advance_cycle(dut)
    dut.i_rst.value = 0
    await _settle()
    assert int(dut.o_lq_mem_request_valid.value) == 0
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 0
    assert int(dut.o_mmio_fifo0_read_pulse.value) == 0
    assert int(dut.o_mmio_fifo1_read_pulse.value) == 0
    assert int(dut.o_mmio_uart_rx_ready_pulse.value) == 0
    await _advance_cycle(dut)
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_lq_mem_read_valid.value) == 0


@cocotb.test()
async def test_device_quadrant_outside_mmio_range_still_waits_for_drain(
    dut: Any,
) -> None:
    """The conservative drain class covers the quadrant, not only peripherals."""
    await _setup_test(dut)

    dut.i_sq_committed_empty.value = 0
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = OUTSIDE_MMIO_DEVICE_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0

    for _ in range(2):
        assert int(dut.o_lq_mem_request_valid.value) == 1
        assert int(dut.o_data_mem_addr.value) == OUTSIDE_MMIO_DEVICE_ADDR
        assert int(dut.o_data_mem_read_enable.value) == 0
        assert int(dut.o_mmio_read_pulse.value) == 0
        await _advance_cycle(dut)

    dut.i_sq_committed_empty.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_data_mem_addr.value) == OUTSIDE_MMIO_DEVICE_ADDR
    assert int(dut.o_mmio_read_pulse.value) == 0
    assert int(dut.o_mmio_load_valid.value) == 0
    assert int(dut.o_data_mem_cached_read_enable.value) == 0
    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_read_valid.value) == 1
    assert int(dut.o_lq_mem_request_valid.value) == 0


@cocotb.test()
async def test_store_drain_status_does_not_block_fast_or_cached_reads(
    dut: Any,
) -> None:
    """Only the device quadrant consumes the committed-store drain status."""
    await _setup_test(dut)
    dut.i_sq_committed_empty.value = 0

    # Low-BRAM request remains the historical one-cycle path.
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = FAST_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_data_mem_cached_read_enable.value) == 0
    assert int(dut.o_mmio_read_pulse.value) == 0
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    assert int(dut.o_lq_mem_read_valid.value) == 1
    await _advance_cycle(dut)
    assert int(dut.o_lq_mem_read_valid.value) == 0

    # Cached-tier request is likewise unaffected; it completes only on the
    # adapter's variable-latency response-valid handshake.
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = CACHED_ADDR
    dut.i_lq_mem_addr_valid.value = 1
    await _settle()
    assert int(dut.o_data_mem_read_enable.value) == 1
    assert int(dut.o_data_mem_cached_read_enable.value) == 1
    assert int(dut.o_mmio_read_pulse.value) == 0
    await _advance_cycle(dut)
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    assert int(dut.o_lq_mem_read_valid.value) == 0
    dut.i_cached_read_data.value = 0xABCD1234
    dut.i_cached_read_valid.value = 1
    await _settle()
    assert int(dut.o_lq_mem_read_valid.value) == 1
    assert int(dut.o_lq_mem_read_data.value) == 0xABCD1234
    await _advance_cycle(dut)
    dut.i_cached_read_valid.value = 0


@cocotb.test()
async def test_mmio_destructive_read_pulses_registered(dut: Any) -> None:
    """Destructive effects follow pending-state MMIO accept by one cycle."""
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
        assert int(dut.o_data_mem_read_enable.value) == 0
        assert int(dut.o_mmio_read_pulse.value) == 0
        for output_name in pulse_outputs:
            assert int(getattr(dut, output_name).value) == 0

        # Capture the device request, then observe its terminal pending-state
        # accept. The destructive outputs are still one register later.
        await _advance_cycle(dut)
        dut.i_lq_mem_read_en.value = 0
        dut.i_lq_mem_addr_valid.value = 0
        await _settle()
        assert int(dut.o_lq_mem_request_valid.value) == 1
        assert int(dut.o_mmio_read_pulse.value) == 1
        for output_name in pulse_outputs:
            assert int(getattr(dut, output_name).value) == 0

        await _advance_cycle(dut)
        assert int(dut.o_lq_mem_request_valid.value) == 0
        assert int(dut.o_mmio_read_pulse.value) == 0
        for output_name in pulse_outputs:
            expected = 1 if output_name == expected_pulse else 0
            assert int(getattr(dut, output_name).value) == expected

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
    # Word-lane strobe on the 64-bit beat: addr[2]=0 selects the low lanes
    # (docs/rv64/m1_data_tier.md).
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0x0F
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
    # Word-lane strobe on the 64-bit beat: CACHED_ADDR has addr[2]=1, so the
    # AMO word occupies the high lanes (docs/rv64/m1_data_tier.md).
    assert int(dut.o_data_mem_cached_byte_wr_en.value) == 0xF0
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

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

"""Unit tests for the CPU OOO data-memory request router."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
MMIO_ADDR = 0x40000000
MMIO_SIZE_BYTES = 0x2C


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_sq_mem_write_en.value = 0
    dut.i_sq_mem_write_addr.value = 0
    dut.i_sq_mem_write_data.value = 0
    dut.i_sq_mem_write_byte_en.value = 0
    dut.i_sq_mem_write_is_mmio.value = 0
    dut.i_sq_mem_write_is_uram.value = 0
    dut.i_amo_mem_write_en.value = 0
    dut.i_amo_mem_write_addr.value = 0
    dut.i_amo_mem_write_data.value = 0
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_read_addr.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    dut.i_data_mem_rd_data.value = 0
    dut.i_uram_rd_data.value = 0


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


def _get_int_parameter(dut: Any, name: str, default: int) -> int:
    """Return a Verilog parameter value when cocotb exposes it."""
    try:
        return int(getattr(dut, name).value)
    except AttributeError:
        return default


def _drive_sq_write(
    dut: Any,
    *,
    addr: int = 0x100,
    data: int = 0xA5A55A5A,
    byte_en: int = 0b1111,
    is_mmio: bool = False,
    is_uram: bool = False,
) -> None:
    """Drive a store-queue write request."""
    dut.i_sq_mem_write_en.value = 1
    dut.i_sq_mem_write_addr.value = addr
    dut.i_sq_mem_write_data.value = data
    dut.i_sq_mem_write_byte_en.value = byte_en
    dut.i_sq_mem_write_is_mmio.value = 1 if is_mmio else 0
    dut.i_sq_mem_write_is_uram.value = 1 if is_uram else 0


def _drive_amo_write(
    dut: Any,
    *,
    addr: int = 0x200,
    data: int = 0x12345678,
) -> None:
    """Drive an atomic-unit write request."""
    dut.i_amo_mem_write_en.value = 1
    dut.i_amo_mem_write_addr.value = addr
    dut.i_amo_mem_write_data.value = data


def _drive_lq_read(dut: Any, *, addr: int = 0x300, addr_valid: bool = True) -> None:
    """Drive a load-queue read request."""
    dut.i_lq_mem_read_en.value = 1
    dut.i_lq_mem_read_addr.value = addr
    dut.i_lq_mem_addr_valid.value = 1 if addr_valid else 0


@cocotb.test()
async def test_idle_outputs_are_inactive_and_read_data_mirrors(dut: Any) -> None:
    """Idle router outputs are inactive while read data mirrors memory input."""
    await _setup_test(dut)

    dut.i_data_mem_rd_data.value = 0xCAFEBABE
    await _settle()

    assert int(dut.o_data_mem_addr.value) == 0
    assert int(dut.o_data_mem_wr_data.value) == 0
    assert int(dut.o_data_mem_per_byte_wr_en.value) == 0
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0
    assert not dut.o_data_mem_read_enable.value
    assert not dut.o_mmio_read_pulse.value
    assert not dut.o_mmio_load_valid.value
    assert not dut.o_sq_mem_write_done.value
    assert not dut.o_amo_mem_write_done.value
    assert not dut.o_lq_mem_request_valid.value
    assert int(dut.o_lq_mem_read_data.value) == 0xCAFEBABE
    assert not dut.o_lq_mem_read_valid.value


@cocotb.test()
async def test_sq_write_has_priority_and_blocks_lq_request(dut: Any) -> None:
    """SQ writes own the port, block lower-priority requests, and queue LQ."""
    await _setup_test(dut)

    _drive_sq_write(dut, addr=0x100, data=0x11112222, byte_en=0b0101)
    _drive_amo_write(dut, addr=0x200, data=0x33334444)
    _drive_lq_read(dut, addr=0x300)
    await _settle()

    assert int(dut.o_data_mem_addr.value) == 0x100
    assert int(dut.o_data_mem_wr_data.value) == 0x11112222
    assert int(dut.o_data_mem_per_byte_wr_en.value) == 0b0101
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0b0101
    assert not dut.o_data_mem_read_enable.value
    assert not dut.o_amo_mem_write_done.value
    assert not dut.o_lq_mem_request_valid.value

    await _advance_cycle(dut)

    assert dut.o_sq_mem_write_done.value
    assert dut.o_lq_mem_request_valid.value
    assert not dut.o_lq_mem_read_valid.value


@cocotb.test()
async def test_mmio_sq_write_preserves_peripheral_mask_only(dut: Any) -> None:
    """MMIO SQ writes keep peripheral byte enables but mask BRAM writes."""
    await _setup_test(dut)

    _drive_sq_write(
        dut,
        addr=MMIO_ADDR + 0x10,
        data=0x55667788,
        byte_en=0b1010,
        is_mmio=True,
    )
    await _settle()

    assert int(dut.o_data_mem_addr.value) == MMIO_ADDR + 0x10
    assert int(dut.o_data_mem_wr_data.value) == 0x55667788
    assert int(dut.o_data_mem_per_byte_wr_en.value) == 0b1010
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0

    await _advance_cycle(dut)

    assert dut.o_sq_mem_write_done.value


@cocotb.test()
async def test_amo_write_has_second_priority_and_mmio_masks_bram(dut: Any) -> None:
    """AMO writes run when SQ is idle and MMIO AMOs are masked from BRAM."""
    await _setup_test(dut)

    _drive_amo_write(dut, addr=0x200, data=0xAABBCCDD)
    _drive_lq_read(dut, addr=0x300)
    await _settle()

    assert int(dut.o_data_mem_addr.value) == 0x200
    assert int(dut.o_data_mem_wr_data.value) == 0xAABBCCDD
    assert int(dut.o_data_mem_per_byte_wr_en.value) == 0b1111
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0b1111
    assert dut.o_amo_mem_write_done.value
    assert not dut.o_data_mem_read_enable.value

    dut.i_amo_mem_write_addr.value = MMIO_ADDR + 0x04
    await _settle()

    assert int(dut.o_data_mem_addr.value) == MMIO_ADDR + 0x04
    assert int(dut.o_data_mem_per_byte_wr_en.value) == 0b1111
    assert int(dut.o_data_mem_bram_byte_wr_en.value) == 0

    await _advance_cycle(dut)

    assert dut.o_lq_mem_request_valid.value


@cocotb.test()
async def test_lq_read_bypasses_when_port_is_free(dut: Any) -> None:
    """LQ reads use the port immediately and return valid data one cycle later."""
    await _setup_test(dut)

    dut.i_data_mem_rd_data.value = 0x13579BDF
    _drive_lq_read(dut, addr=0x900)
    await _settle()

    assert dut.o_data_mem_read_enable.value
    assert int(dut.o_data_mem_addr.value) == 0x900
    assert int(dut.o_lq_mem_read_data.value) == 0x13579BDF
    assert not dut.o_lq_mem_request_valid.value
    assert not dut.o_lq_mem_read_valid.value

    await _advance_cycle(dut)

    assert dut.o_lq_mem_read_valid.value

    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    await _advance_cycle(dut)

    assert not dut.o_lq_mem_read_valid.value


@cocotb.test()
async def test_blocked_lq_request_retries_after_write_conflict(dut: Any) -> None:
    """A blocked load is held and retried once the write conflict clears."""
    await _setup_test(dut)

    _drive_sq_write(dut, addr=0x100, data=0x22223333)
    _drive_lq_read(dut, addr=0x444)
    await _advance_cycle(dut)

    assert dut.o_lq_mem_request_valid.value
    assert not dut.o_data_mem_read_enable.value

    dut.i_sq_mem_write_en.value = 0
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    await _settle()

    assert dut.o_data_mem_read_enable.value
    assert int(dut.o_data_mem_addr.value) == 0x444
    assert dut.o_lq_mem_request_valid.value

    await _advance_cycle(dut)

    assert not dut.o_lq_mem_request_valid.value
    assert dut.o_lq_mem_read_valid.value


@cocotb.test()
async def test_uram_queued_load_waits_for_delayed_store_done(dut: Any) -> None:
    """A load queued behind a URAM store must not replay before store-done."""
    await _setup_test(dut)

    uram_write_latency = _get_int_parameter(dut, "URAM_WRITE_LATENCY", 2)
    assert uram_write_latency >= 2, "test requires delayed URAM writes"

    uram_addr = 0x01000080
    _drive_sq_write(
        dut,
        addr=uram_addr,
        data=0x11223344,
        byte_en=0b1111,
        is_uram=True,
    )
    _drive_lq_read(dut, addr=uram_addr)
    await _settle()

    assert int(dut.o_data_mem_uram_byte_wr_en.value) == 0b1111
    assert not dut.o_data_mem_uram_read_enable.value

    await _advance_cycle(dut)

    dut.i_sq_mem_write_en.value = 0
    dut.i_sq_mem_write_is_uram.value = 0
    dut.i_sq_mem_write_byte_en.value = 0
    dut.i_lq_mem_read_en.value = 0
    dut.i_lq_mem_addr_valid.value = 0
    await _settle()

    assert dut.o_lq_mem_request_valid.value
    assert not dut.o_sq_mem_write_done.value
    assert not dut.o_data_mem_read_enable.value
    assert not dut.o_data_mem_uram_read_enable.value

    await _advance_cycle(dut)

    assert dut.o_sq_mem_write_done.value
    assert dut.o_data_mem_read_enable.value
    assert dut.o_data_mem_uram_read_enable.value


@cocotb.test()
async def test_mmio_lq_read_sidebands_and_pulse(dut: Any) -> None:
    """MMIO LQ reads assert the MMIO load sideband and read pulse."""
    await _setup_test(dut)

    _drive_lq_read(dut, addr=MMIO_ADDR + MMIO_SIZE_BYTES - 4)
    await _settle()

    assert dut.o_data_mem_read_enable.value
    assert int(dut.o_data_mem_addr.value) == MMIO_ADDR + MMIO_SIZE_BYTES - 4
    assert dut.o_mmio_load_valid.value
    assert int(dut.o_mmio_load_addr.value) == MMIO_ADDR + MMIO_SIZE_BYTES - 4
    assert dut.o_mmio_read_pulse.value

    dut.i_lq_mem_read_addr.value = MMIO_ADDR + MMIO_SIZE_BYTES
    await _settle()

    assert dut.o_data_mem_read_enable.value
    assert not dut.o_mmio_load_valid.value
    assert not dut.o_mmio_read_pulse.value

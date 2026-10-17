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

"""Check memory_error_unit's registers, counters and interrupt.

The bench drives the unit's register bus as cpu_and_mem does (byte offsets,
32-bit writes, 64-bit read pairs) and its report inputs as the X3's ECC
reader and the cache bridge do, one-cycle pulses.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

CLOCK_PERIOD_NS = 10
ID_BITS = 5  # the registry's -GID_BITS, cpu_and_mem's DDR AXI id width

CAPS = 0x00
STATUS = 0x04
IRQ_EN = 0x08
CE_COUNT = 0x10
UE_COUNT = 0x14
AXI_RD_ERRS = 0x18
AXI_WR_ERRS = 0x1C
CE_ADDR = 0x20
UE_ADDR = 0x28
AXI_ERR = 0x30
ECC_POLLS = 0x38
VERSION = 1

ST_CE = 0x1
ST_UE = 0x2
ST_AXI_RD = 0x4
ST_AXI_WR = 0x8
ST_CE_ADDR = 0x10
ST_UE_ADDR = 0x20
ST_ALL = 0x3F

PULSE_INPUTS = (
    "i_ecc_poll",
    "i_ce_valid",
    "i_ce_addr_valid",
    "i_ue_valid",
    "i_ue_addr_valid",
    "i_rd_err_valid",
    "i_wr_err_valid",
)


async def _start(dut: Any) -> None:
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_wr_en.value = 0
    dut.i_wr_offset.value = 0
    dut.i_wr_data.value = 0
    dut.i_rd_offset.value = 0
    dut.i_ecc_present.value = 0
    for name in PULSE_INPUTS:
        getattr(dut, name).value = 0
    for name in ("i_ce_count", "i_ce_addr", "i_ue_addr"):
        getattr(dut, name).value = 0
    for name in ("i_rd_err_resp", "i_rd_err_id", "i_wr_err_resp", "i_wr_err_id"):
        getattr(dut, name).value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0


async def _write(dut: Any, offset: int, value: int) -> None:
    """One 32-bit store, taking effect at the next rising edge."""
    await FallingEdge(dut.i_clk)
    dut.i_wr_en.value = 1
    dut.i_wr_offset.value = offset
    dut.i_wr_data.value = value
    await FallingEdge(dut.i_clk)
    dut.i_wr_en.value = 0


async def _read32(dut: Any, offset: int) -> int:
    """Read the 32-bit register at offset from its 64-bit pair."""
    await FallingEdge(dut.i_clk)
    dut.i_rd_offset.value = offset & ~0x7
    await ReadOnly()
    pair = int(dut.o_rd_pair.value)
    return (pair >> 32) if offset & 0x4 else pair & 0xFFFF_FFFF


async def _read64(dut: Any, offset: int) -> int:
    await FallingEdge(dut.i_clk)
    dut.i_rd_offset.value = offset
    await ReadOnly()
    return int(dut.o_rd_pair.value)


async def _pulse(dut: Any, **inputs: int) -> None:
    """Drive the named inputs for one cycle; pulses drop afterwards."""
    await FallingEdge(dut.i_clk)
    for name, value in inputs.items():
        getattr(dut, name).value = value
    await FallingEdge(dut.i_clk)
    for name in inputs:
        if name in PULSE_INPUTS:
            getattr(dut, name).value = 0


@cocotb.test()
async def test_reset_and_caps(dut: Any) -> None:
    """Every register reads zero after reset; CAPS follows i_ecc_present."""
    await _start(dut)
    for offset in range(0, 0x100, 4):
        value = await _read32(dut, offset)
        expected = (VERSION << 8) if offset == CAPS else 0
        assert value == expected, f"offset 0x{offset:02x} reads 0x{value:x} after reset"
    await FallingEdge(dut.i_clk)
    dut.i_ecc_present.value = 1
    assert await _read32(dut, CAPS) == (VERSION << 8) | 1
    assert not int(dut.o_irq.value)


@cocotb.test()
async def test_ecc_reports(dut: Any) -> None:
    """Corrected and uncorrectable reports set status, counts and addresses."""
    await _start(dut)
    await _pulse(dut, i_ce_valid=1, i_ce_count=3)
    await _pulse(dut, i_ce_valid=1, i_ce_count=255)
    await _pulse(dut, i_ce_addr_valid=1, i_ce_addr=0x8000_1238)
    assert await _read32(dut, CE_COUNT) == 258
    assert await _read64(dut, CE_ADDR) == 0x8000_1238
    assert await _read32(dut, STATUS) == ST_CE | ST_CE_ADDR

    await _pulse(dut, i_ue_valid=1, i_ue_addr_valid=1, i_ue_addr=0x2_7FFF_FFC0)
    await _pulse(dut, i_ue_valid=1, i_ue_addr_valid=1, i_ue_addr=0x8123_4540)
    assert await _read32(dut, UE_COUNT) == 2
    assert await _read64(dut, UE_ADDR) == 0x8123_4540, "UE_ADDR keeps the latest"
    assert await _read32(dut, STATUS) == ST_CE | ST_UE | ST_CE_ADDR | ST_UE_ADDR
    # An uncorrectable error whose address the reader could not capture counts,
    # and leaves UE_ADDR and its new-address bit alone.
    await _write(dut, STATUS, ST_ALL)
    await _pulse(dut, i_ue_valid=1, i_ue_addr=0x9999_0000)
    assert await _read32(dut, UE_COUNT) == 3
    assert await _read64(dut, UE_ADDR) == 0x8123_4540
    assert await _read32(dut, STATUS) == ST_UE

    # An address report alone sets only its new-address bit.
    await _write(dut, STATUS, ST_ALL)
    await _pulse(dut, i_ce_addr_valid=1, i_ce_addr=0x9000_0000)
    assert await _read32(dut, STATUS) == ST_CE_ADDR
    assert await _read32(dut, CE_COUNT) == 258
    assert await _read64(dut, CE_ADDR) == 0x9000_0000

    for _ in range(5):
        await _pulse(dut, i_ecc_poll=1)
    assert await _read32(dut, ECC_POLLS) == 5


@cocotb.test()
async def test_axi_errors(dut: Any) -> None:
    """AXI error reports count by channel; the latest write wins a tie."""
    await _start(dut)
    await _pulse(dut, i_rd_err_valid=1, i_rd_err_resp=2, i_rd_err_id=0x13)
    assert await _read32(dut, AXI_ERR) == (0x13 << 8) | (2 << 1)
    await _pulse(dut, i_wr_err_valid=1, i_wr_err_resp=3, i_wr_err_id=0x05)
    assert await _read32(dut, AXI_ERR) == (0x05 << 8) | (3 << 1) | 1
    await _pulse(
        dut,
        i_rd_err_valid=1,
        i_rd_err_resp=2,
        i_rd_err_id=0x1F,
        i_wr_err_valid=1,
        i_wr_err_resp=2,
        i_wr_err_id=0x0A,
    )
    assert await _read32(dut, AXI_ERR) == (0x0A << 8) | (2 << 1) | 1
    assert await _read32(dut, AXI_RD_ERRS) == 2
    assert await _read32(dut, AXI_WR_ERRS) == 2
    assert await _read32(dut, STATUS) == ST_AXI_RD | ST_AXI_WR


@cocotb.test()
async def test_status_and_interrupt(dut: Any) -> None:
    """STATUS clears by writing ones; IRQ follows STATUS & IRQ_EN."""
    await _start(dut)
    await _write(dut, IRQ_EN, ST_UE | ST_AXI_RD)
    assert await _read32(dut, IRQ_EN) == ST_UE | ST_AXI_RD
    await _pulse(dut, i_ce_valid=1, i_ce_count=1)
    await RisingEdge(dut.i_clk)
    await ReadOnly()
    assert not int(dut.o_irq.value), "a disabled kind interrupted"

    await _pulse(dut, i_rd_err_valid=1, i_rd_err_resp=2)
    await ReadOnly()
    assert int(dut.o_irq.value), "an enabled kind did not interrupt"

    # Writing zeros, or ones to clear bits, never sets a bit.
    await _write(dut, STATUS, 0)
    assert await _read32(dut, STATUS) == ST_CE | ST_AXI_RD
    await _write(dut, STATUS, ST_AXI_RD | ST_UE)
    assert await _read32(dut, STATUS) == ST_CE
    assert not int(dut.o_irq.value), "the interrupt outlived its status bit"

    # A report in the cycle of a clear of its bit wins.
    await FallingEdge(dut.i_clk)
    dut.i_wr_en.value = 1
    dut.i_wr_offset.value = STATUS
    dut.i_wr_data.value = ST_CE | ST_UE
    dut.i_ue_valid.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_wr_en.value = 0
    dut.i_ue_valid.value = 0
    assert await _read32(dut, STATUS) == ST_UE, "the clear beat the report"
    assert int(dut.o_irq.value)

    # Writes elsewhere in the window change nothing.
    for offset in (CAPS, CE_COUNT, UE_COUNT, CE_ADDR, AXI_ERR, ECC_POLLS, 0x44, 0xFC):
        await _write(dut, offset, 0xFFFF_FFFF)
    assert await _read32(dut, STATUS) == ST_UE
    assert await _read32(dut, IRQ_EN) == ST_UE | ST_AXI_RD
    assert await _read32(dut, CE_COUNT) == 1


@cocotb.test()
async def test_counters_saturate(dut: Any) -> None:
    """Counters stop at 2^32 - 1."""
    await _start(dut)
    await FallingEdge(dut.i_clk)
    dut.ce_count_q.value = 0xFFFF_FF00
    dut.axi_rd_errs_q.value = 0xFFFF_FFFF
    await _pulse(dut, i_ce_valid=1, i_ce_count=0xFF)
    assert await _read32(dut, CE_COUNT) == 0xFFFF_FFFF
    await _pulse(dut, i_ce_valid=1, i_ce_count=1)
    assert await _read32(dut, CE_COUNT) == 0xFFFF_FFFF
    await _pulse(dut, i_rd_err_valid=1, i_rd_err_resp=2)
    assert await _read32(dut, AXI_RD_ERRS) == 0xFFFF_FFFF


@cocotb.test()
async def test_new_address_bits(dut: Any) -> None:
    """IRQ_EN holds six bits, and a new address interrupts when it is enabled."""
    await _start(dut)
    await _write(dut, IRQ_EN, 0xFFFF_FFFF)
    assert await _read32(dut, IRQ_EN) == ST_ALL
    await _write(dut, IRQ_EN, ST_UE_ADDR)
    await _pulse(dut, i_ce_addr_valid=1, i_ce_addr=0x8000_0040)
    await ReadOnly()
    assert not int(dut.o_irq.value), "a disabled bit interrupted"
    await _pulse(dut, i_ue_valid=1, i_ue_addr_valid=1, i_ue_addr=0x8000_0080)
    await ReadOnly()
    assert int(dut.o_irq.value), "a new UE address did not interrupt"
    await _write(dut, STATUS, ST_UE_ADDR)
    assert await _read32(dut, STATUS) == ST_CE_ADDR | ST_UE
    assert not int(dut.o_irq.value)

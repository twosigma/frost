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

"""Cycle-exact tests of data_mem_response_mux feeding a real data_mem_request_router.

The testbench runs two routers side by side. The reference router gets the plain
selection (MMIO data while MMIO is valid, otherwise BRAM data) and the cached data
separately; the other gets the mux's merged payload on both data inputs. Every
router output is compared before and after every edge, valid or not. Separate
checks cover the response port, ids, and destructive device pulses. The same tests
run on the portable and Xilinx LUT5 builds, and standalone 32- and 64-bit
instances cover all 32 LUT truth-table rows.
"""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer

MASK64 = (1 << 64) - 1
FAST_ADDR = 0x100
CACHED_ADDR = 0x80001230
FIFO_ADDR = 0x40000008
OUTPUTS = (
    "cached_read_ready",
    "cached_read_held",
    "data_mem_addr",
    "data_mem_wr_data",
    "data_mem_per_byte_wr_en",
    "data_mem_bram_byte_wr_en",
    "data_mem_bram_write_any",
    "data_mem_read_enable",
    "data_mem_cached_byte_wr_en",
    "data_mem_cached_wr_data",
    "data_mem_cached_read_enable",
    "data_mem_cached_read_id",
    "mmio_read_pulse",
    "mmio_load_addr",
    "mmio_load_valid",
    "mmio_fifo0_read_pulse",
    "mmio_fifo1_read_pulse",
    "mmio_uart_rx_ready_pulse",
    "sq_mem_write_done",
    "amo_mem_write_done",
    "lq_mem_request_valid",
    "device_request_pending",
    "lq_mem_read_data",
    "lq_mem_read_valid",
    "lq_mem_read_is_cached",
    "lq_mem_read_id",
)
INPUTS = (
    "clk",
    "rst",
    "flush_all",
    "sq_mem_write_en",
    "sq_mem_write_addr",
    "sq_mem_write_data",
    "sq_mem_write_byte_en",
    "sq_mem_write_is_mmio",
    "sq_mem_write_is_cached",
    "amo_mem_write_en",
    "amo_mem_write_addr",
    "amo_mem_write_data",
    "amo_mem_write_is_dword",
    "lq_mem_read_en",
    "lq_mem_read_addr",
    "lq_mem_addr_valid",
    "lq_mem_read_id",
    "sq_committed_empty",
    "data_mem_rd_data",
    "cached_read_data",
    "cached_read_id",
    "cached_read_valid",
    "cached_write_done",
    "cached_write_inflight",
    "mmio_read_data",
    "mmio_read_valid",
    "helper_cached_read_ready",
)


class RouterPair:
    """Drive only the common inputs, checking every observable router output."""

    def __init__(self, dut: Any) -> None:
        """Bind the common top-level signals and actual cached-id width."""
        self.dut = dut
        self.samples = 0
        self.id_mask = (1 << len(dut.i_cached_read_id)) - 1

    def drive(self, **values: int) -> None:
        """Update common inputs without advancing the clock."""
        for name, value in values.items():
            getattr(self.dut, "i_" + name).value = value

    def value(self, name: str) -> int:
        """Read one settled top-level signal."""
        return int(getattr(self.dut, name).value)

    async def sample(self) -> dict[str, int]:
        """Settle and compare every output, plus independently selected data."""
        await Timer(1, unit="ns")
        self.samples += 1
        observed = {}
        for name in OUTPUTS:
            actual = self.value("o_" + name)
            expected = self.value("o_ref_" + name)
            assert actual == expected, (self.samples, name, hex(actual), hex(expected))
            observed[name] = actual
        fast = (
            self.value("i_mmio_read_data")
            if self.value("i_mmio_read_valid")
            else (self.value("i_data_mem_rd_data"))
        )
        standalone = (
            self.value("i_cached_read_data")
            if self.value("i_helper_cached_read_ready")
            else fast
        )
        assert self.value("o_standalone64") == standalone
        assert self.value("o_standalone32") == standalone & 0xFFFFFFFF
        selected = (
            self.value("i_cached_read_data") if observed["cached_read_ready"] else fast
        )
        assert self.value("o_selected_read_data") == selected
        assert observed["lq_mem_read_data"] == selected
        return observed

    async def edge(self) -> dict[str, int]:
        """Check before and after a rising edge and return the post-edge values."""
        await self.sample()
        self.drive(clk=1)
        observed = await self.sample()
        self.drive(clk=0)
        await self.sample()
        return observed

    async def reset(self) -> None:
        """Initialize every testbench input and apply two synchronous reset edges."""
        self.drive(**dict.fromkeys(INPUTS, 0))
        self.drive(rst=1, sq_committed_empty=1)
        await self.edge()
        await self.edge()
        self.drive(rst=0)
        await self.sample()


@cocotb.test()
async def test_helper_truth_table_and_walking_bits(dut: Any) -> None:
    """All 32 input combinations and every data bit agree at widths 32 and 64."""
    pair = RouterPair(dut)
    await pair.reset()
    for row in range(32):
        pair.drive(
            data_mem_rd_data=MASK64 if row & 1 else 0,
            mmio_read_data=MASK64 if row & 2 else 0,
            cached_read_data=MASK64 if row & 4 else 0,
            mmio_read_valid=(row >> 3) & 1,
            helper_cached_read_ready=(row >> 4) & 1,
        )
        await pair.sample()
    rng = random.Random(0x5253504D5558)
    for selector in range(4):
        for bit in range(64):
            pair.drive(
                data_mem_rd_data=1 << bit,
                mmio_read_data=MASK64 ^ (1 << bit),
                cached_read_data=rng.getrandbits(64),
                mmio_read_valid=selector & 1,
                helper_cached_read_ready=(selector >> 1) & 1,
            )
            await pair.sample()


@cocotb.test()
async def test_fast_overlap_and_stale_mmio_cached_payload(dut: Any) -> None:
    """Fast beats retain priority; a stale MMIO valid cannot corrupt cached data."""
    pair = RouterPair(dut)
    await pair.reset()
    bram, mmio, cached = 0x12345678ABCDEF01, 0xFEDCBA9876543210, 0xF0E1D2C3B4A59687
    pair.drive(
        data_mem_rd_data=bram,
        mmio_read_data=mmio,
        cached_read_data=cached,
        mmio_read_valid=1,
        cached_read_valid=1,
        cached_read_id=pair.id_mask,
    )
    out = await pair.sample()
    assert out["cached_read_ready"] == out["lq_mem_read_is_cached"] == 1
    assert out["lq_mem_read_data"] == cached
    assert out["lq_mem_read_id"] == pair.id_mask
    pair.drive(lq_mem_read_en=1, lq_mem_addr_valid=1, lq_mem_read_addr=FAST_ADDR)
    assert (await pair.sample())["data_mem_read_enable"] == 1
    out = await pair.edge()
    assert out["cached_read_ready"] == out["lq_mem_read_is_cached"] == 0
    assert out["cached_read_held"] == out["lq_mem_read_valid"] == 1
    assert out["lq_mem_read_data"] == mmio
    pair.drive(mmio_read_valid=0)
    assert (await pair.sample())["lq_mem_read_data"] == bram
    # Consecutive fast accepts hold exactly the same cached response and id.
    for _ in range(3):
        out = await pair.edge()
        assert out["cached_read_held"] == 1
        assert out["lq_mem_read_id"] == pair.id_mask
    pair.drive(lq_mem_read_en=0, lq_mem_addr_valid=0, mmio_read_valid=1)
    out = await pair.edge()
    assert out["cached_read_ready"] == out["lq_mem_read_is_cached"] == 1
    assert out["lq_mem_read_data"] == cached
    # An invalid cached response still passes its data and id through.
    pair.drive(cached_read_valid=0, cached_read_id=0)
    out = await pair.sample()
    assert out["lq_mem_read_valid"] == 0
    assert out["lq_mem_read_data"] == cached
    assert out["lq_mem_read_id"] == 0


@cocotb.test()
async def test_device_drain_stalls_flush_reset_and_side_effects(dut: Any) -> None:
    """Device parking, drain, flush, reset, and destructive pulses match the reference."""
    pair = RouterPair(dut)
    await pair.reset()
    pair.drive(
        sq_committed_empty=0,
        lq_mem_read_en=1,
        lq_mem_addr_valid=1,
        lq_mem_read_addr=FIFO_ADDR,
        cached_read_valid=1,
        cached_read_id=3,
        cached_read_data=0xABCDEF0123456789,
        mmio_read_data=0xDEADFEED11223344,
        mmio_read_valid=1,
    )
    assert (await pair.sample())["mmio_read_pulse"] == 0
    await pair.edge()
    pair.drive(lq_mem_read_en=0, lq_mem_addr_valid=0, lq_mem_read_addr=FAST_ADDR)
    for _ in range(3):
        out = await pair.edge()
        assert out["lq_mem_request_valid"] == 1
        assert out["mmio_read_pulse"] == out["mmio_fifo0_read_pulse"] == 0
        assert out["lq_mem_read_is_cached"] == 1
    pair.drive(sq_committed_empty=1)
    assert (await pair.sample())["mmio_read_pulse"] == 0
    out = await pair.edge()
    assert out["mmio_read_pulse"] == out["mmio_load_valid"] == 1
    assert out["mmio_load_addr"] == FIFO_ADDR
    out = await pair.edge()
    assert out["mmio_read_pulse"] == 0
    assert out["mmio_fifo0_read_pulse"] == 1
    assert out["mmio_fifo1_read_pulse"] == out["mmio_uart_rx_ready_pulse"] == 0
    assert out["lq_mem_read_data"] == 0xDEADFEED11223344
    assert out["cached_read_held"] == 1
    await pair.edge()
    # Cancel a separately captured but unaccepted device request under flush.
    pair.drive(
        sq_committed_empty=0,
        lq_mem_read_en=1,
        lq_mem_addr_valid=1,
        lq_mem_read_addr=FIFO_ADDR + 4,
    )
    await pair.edge()
    pair.drive(lq_mem_read_en=0, lq_mem_addr_valid=0, flush_all=1, sq_committed_empty=1)
    assert (await pair.sample())["mmio_read_pulse"] == 0
    out = await pair.edge()
    assert out["lq_mem_request_valid"] == out["mmio_fifo1_read_pulse"] == 0
    pair.drive(flush_all=0)
    for _ in range(4):
        out = await pair.edge()
        assert out["mmio_read_pulse"] == out["mmio_fifo1_read_pulse"] == 0
    # Synchronous reset clears the fast response but does not mask a valid cached one.
    pair.drive(lq_mem_read_en=1, lq_mem_addr_valid=1, lq_mem_read_addr=FAST_ADDR)
    assert (await pair.edge())["cached_read_ready"] == 0
    pair.drive(lq_mem_read_en=0, rst=1)
    out = await pair.edge()
    assert out["cached_read_ready"] == out["lq_mem_read_is_cached"] == 1
    assert out["lq_mem_read_valid"] == 1
    assert out["mmio_read_pulse"] == out["mmio_fifo0_read_pulse"] == 0


@cocotb.test()
async def test_parked_request_identity_and_write_arbitration(dut: Any) -> None:
    """A load parked behind SQ, AMO, and in-flight cached writes keeps its address and id."""
    pair = RouterPair(dut)
    await pair.reset()
    pair.drive(
        sq_mem_write_en=1,
        sq_mem_write_addr=0x300,
        sq_mem_write_data=0x11223344,
        sq_mem_write_byte_en=0xF0,
        amo_mem_write_en=1,
        amo_mem_write_addr=0x408,
        amo_mem_write_data=0x55667788,
        amo_mem_write_is_dword=1,
        lq_mem_read_en=1,
        lq_mem_addr_valid=1,
        lq_mem_read_addr=CACHED_ADDR,
        lq_mem_read_id=pair.id_mask,
    )
    out = await pair.sample()
    assert out["data_mem_addr"] == 0x300
    assert out["data_mem_wr_data"] == 0x11223344
    assert out["data_mem_bram_byte_wr_en"] == 0xF0
    assert out["data_mem_read_enable"] == 0
    await pair.edge()
    pair.drive(
        sq_mem_write_en=0,
        lq_mem_read_en=0,
        lq_mem_addr_valid=0,
        lq_mem_read_addr=FAST_ADDR,
        lq_mem_read_id=0,
    )
    out = await pair.sample()
    assert out["data_mem_addr"] == 0x408
    assert out["data_mem_bram_byte_wr_en"] == 0xFF
    assert out["amo_mem_write_done"] == 1
    await pair.edge()
    pair.drive(amo_mem_write_en=0, cached_write_inflight=1)
    for _ in range(3):
        out = await pair.edge()
        assert out["lq_mem_request_valid"] == 1
        assert out["data_mem_read_enable"] == 0
    pair.drive(cached_write_inflight=0)
    out = await pair.sample()
    assert out["data_mem_cached_read_enable"] == 1
    assert out["data_mem_addr"] == CACHED_ADDR
    assert out["data_mem_cached_read_id"] == pair.id_mask
    await pair.edge()
    pair.drive(
        cached_read_valid=1,
        cached_read_id=pair.id_mask,
        cached_read_data=0x1234FEDCBA987654,
        mmio_read_valid=1,
        mmio_read_data=0x1111111111111111,
    )
    out = await pair.sample()
    assert out["lq_mem_read_is_cached"] == 1
    assert out["lq_mem_read_id"] == pair.id_mask
    assert out["lq_mem_read_data"] == 0x1234FEDCBA987654


@cocotb.test()
async def test_randomized_exact_cycle_router_pair(dut: Any) -> None:
    """Independent payloads and valid bits accompany legal one-entry request traffic."""
    pair = RouterPair(dut)
    await pair.reset()
    rng = random.Random(0x5EA064)
    addresses = (
        0x100,
        0x108,
        CACHED_ADDR,
        CACHED_ADDR + 8,
        FIFO_ADDR,
        FIFO_ADDR + 4,
        FIFO_ADDR - 4,
        0x50001234,
    )
    coverage = dict.fromkeys(
        ("fast", "cached", "overlap", "stale", "pending", "flush_pending"), 0
    )
    for cycle in range(1200):
        pending = pair.value("o_lq_mem_request_valid")
        sq_addr, amo_addr = rng.choice(addresses), rng.choice(addresses)
        flush = int(rng.randrange(23) == 0)
        pair.drive(
            rst=int(cycle % 137 == 136),
            flush_all=flush,
            sq_mem_write_en=int(rng.randrange(7) == 0),
            sq_mem_write_addr=sq_addr,
            sq_mem_write_data=rng.getrandbits(64),
            sq_mem_write_byte_en=rng.randrange(256),
            sq_mem_write_is_mmio=int(0x40000000 <= sq_addr < 0x4000002C),
            sq_mem_write_is_cached=int(sq_addr >= 0x80000000),
            amo_mem_write_en=int(rng.randrange(9) == 0),
            amo_mem_write_addr=amo_addr,
            amo_mem_write_data=rng.getrandbits(64),
            amo_mem_write_is_dword=rng.randrange(2),
            lq_mem_read_en=int(not pending and rng.randrange(3) == 0),
            lq_mem_read_addr=rng.choice(addresses),
            lq_mem_addr_valid=rng.randrange(2),
            lq_mem_read_id=rng.randrange(pair.id_mask + 1),
            sq_committed_empty=rng.randrange(2),
            cached_write_inflight=int(rng.randrange(5) == 0),
            cached_write_done=int(rng.randrange(7) == 0),
            cached_read_valid=rng.randrange(2),
            cached_read_id=rng.randrange(pair.id_mask + 1),
            data_mem_rd_data=rng.getrandbits(64),
            mmio_read_data=rng.getrandbits(64),
            cached_read_data=rng.getrandbits(64),
            mmio_read_valid=rng.randrange(2),
            helper_cached_read_ready=rng.randrange(2),
        )
        out = await pair.sample()
        coverage["fast"] += 1 - out["cached_read_ready"]
        coverage["cached"] += out["lq_mem_read_is_cached"]
        coverage["overlap"] += out["cached_read_held"]
        coverage["stale"] += out["lq_mem_read_is_cached"] * pair.value(
            "i_mmio_read_valid"
        )
        coverage["pending"] += pending
        coverage["flush_pending"] += pending * flush
        await pair.edge()
    assert all(coverage.values()), coverage
    dut._log.info("exact-cycle samples=%d coverage=%s", pair.samples, coverage)

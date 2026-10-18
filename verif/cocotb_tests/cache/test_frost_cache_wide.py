# Copyright (c) 2026 John Goodacre
# SPDX-License-Identifier: Apache-2.0

"""Exercise distinct cache/DDR lines across a 64 GiB offset aperture.

The sparse AXI test memory is keyed by the complete DDR offset. This is a
test-only address-identity check; it does not model production DDR hardware.
"""

import cocotb

from cocotb_tests.cache.test_frost_cache import (
    BASE_ADDR,
    LINE_BYTES,
    ReferenceModel,
    _line_transaction,
    _port_transaction,
    _setup,
)
from cocotb_tests.cache.test_frost_cache_dma import LoadQueueStub


@cocotb.test()
async def wide_ddr_offsets_survive_cache_eviction(dut):
    await _setup(dut)
    model = ReferenceModel()
    offsets = (
        0x140,
        (1 << 32) + 0x140,
        (1 << 35) + 0x140,
        (1 << 36) - 64,
        (1 << 36) - 32,
    )
    addresses = [BASE_ADDR + offset for offset in offsets]
    assert len(dut.i_up_req_addr) >= 37

    # The first three lines map to the same L1/L2 index despite being far
    # apart. The last two are the distinct 32-byte sectors of the final L2
    # line in the 64 GiB DDR aperture.
    for index, addr in enumerate(addresses):
        data = int.from_bytes(bytes([0x31 + index]) * LINE_BYTES, "little")
        await _line_transaction(
            dut, write=True, addr=addr, wdata=data, wstrb=(1 << LINE_BYTES) - 1
        )
        model.write_line(addr, data, (1 << LINE_BYTES) - 1)
        got_now = await _line_transaction(dut, write=False, addr=addr)
        assert got_now == data, f"immediate readback failed at 0x{addr:x}"

    # More conflicts evict dirty lines from both levels to the AXI memory.
    for index in range(1, 8):
        addr = BASE_ADDR + 0x140 + index * 4096
        data = int.from_bytes(bytes([0x70 + index]) * LINE_BYTES, "little")
        await _line_transaction(
            dut, write=True, addr=addr, wdata=data, wstrb=(1 << LINE_BYTES) - 1
        )

    # Evict both sectors of the aperture's final L2 line independently.
    for sector in (0, LINE_BYTES):
        for index in range(1, 5):
            addr = BASE_ADDR + (1 << 36) - 64 + sector - index * 4096
            data = int.from_bytes(bytes([0x80 + index + sector]) * LINE_BYTES, "little")
            await _line_transaction(
                dut, write=True, addr=addr, wdata=data, wstrb=(1 << LINE_BYTES) - 1
            )

    for addr in addresses:
        got = await _line_transaction(dut, write=False, addr=addr)
        expected = model.read_line(addr)
        assert got == expected, (
            f"cache/DDR alias at 0x{addr:x}: got 0x{got:064x}, "
            f"expected 0x{expected:064x}"
        )


@cocotb.test()
async def wide_dma_coherence_preserves_high_address(dut):
    """CPU/DMA partial writes and dirty evictions retain the full DDR address."""
    await _setup(dut)
    lq = LoadQueueStub(dut)
    model = ReferenceModel()
    full = (1 << LINE_BYTES) - 1
    low = BASE_ADDR + 0x200
    high = low + (1 << 32)
    last = BASE_ADDR + (1 << 36) - LINE_BYTES

    try:
        for addr, seed in ((low, 0x21), (high, 0x43), (last, 0x65)):
            data = int.from_bytes(bytes([seed]) * LINE_BYTES, "little")
            await _line_transaction(dut, write=True, addr=addr, wdata=data, wstrb=full)
            model.write_line(addr, data, full)

        # Read dirty CPU lines through the coherent DMA port. The high line
        # conflicts with the low line at both cache indexes but must not alias.
        for addr in (high, low, last):
            got = await _port_transaction(dut, "dma", write=False, addr=addr)
            assert got == model.read_line(addr), f"DMA read alias at 0x{addr:x}"

        # A partial coherent DMA write probes the CPU copy and merges at the
        # shared level; both CPU and DMA must see the unchanged low sentinel.
        new_data = int.from_bytes(bytes([0xB7]) * LINE_BYTES, "little")
        mask = 0x0000_FF00
        await _port_transaction(
            dut, "dma", write=True, addr=high, wdata=new_data, wstrb=mask
        )
        model.write_line(high, new_data, mask)
        for addr in (low, high, last):
            got = await _line_transaction(dut, write=False, addr=addr)
            assert got == model.read_line(addr), f"CPU read alias at 0x{addr:x}"

        # Force dirty conflicts to DDR and reload through both clients.
        for index in range(1, 8):
            addr = high + index * 4096
            data = int.from_bytes(bytes([0x80 + index]) * LINE_BYTES, "little")
            await _line_transaction(dut, write=True, addr=addr, wdata=data, wstrb=full)
        for addr in (low, high, last):
            got = await _port_transaction(dut, "dma", write=False, addr=addr)
            assert got == model.read_line(addr), f"DMA reload alias at 0x{addr:x}"
        assert lq.admits and lq.invals and lq.releases
        assert any(addr == high for _, addr in lq.admits)
    finally:
        lq.stop()

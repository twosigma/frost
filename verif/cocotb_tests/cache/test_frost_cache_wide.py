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
    _setup,
)


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

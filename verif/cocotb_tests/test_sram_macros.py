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

"""Check the RAM wrappers built from the ASIC flow's SRAM macros.

Each bench builds one wrapper with FROST_SRAM_MACROS and the parameters of
one of the design's memories, so that frost_sram_1w1r or frost_sram_2rw
tiles it onto the OpenRAM macros in asic/sram/macros, whose Verilog models
stand in for them. Random reads and writes over addresses at the edges of
every macro, and some others, are checked against a model of the wrapper's
contract. A macro's read of a word written in the same cycle is undefined,
so the traffic does that only in the memories that write whole words on one
clock, where frost_sram_1w1r holds each write for a cycle so that such a read
returns the old word, which the benches check.

A macro's read data settles in the second half of the cycle after the read,
in time for the registers that the next rising edge clocks, so the benches
sample outputs just before rising edges and drive inputs just after them.
"""

import os
import random
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLOCK_PERIOD_NS = 10
CYCLES = 3000
# The starting image that the instruction memory's cold-bank bench loads
# (USE_INIT_FILE, INIT_FILE in tests/test_run_cocotb.py).
INIT_IMAGE = Path(__file__).with_name("sram_init.mem")


async def _start_cycle(clock: Any) -> None:
    """Wait for a rising edge and for the registers it updates."""
    await RisingEdge(clock)
    await Timer(1, unit="ns")


async def _sample_point(period_ns: float) -> None:
    """From a cycle's start, wait until just before its closing edge."""
    await Timer(period_ns - 2, unit="ns")


def _read_hex_image(path: Path, data_width: int) -> dict[int, int]:
    """Return a $readmemh image's words by address."""
    words: dict[int, int] = {}
    address = 0
    for raw_line in path.read_text().splitlines():
        for token in raw_line.split("//", 1)[0].split():
            if token.startswith("@"):
                address = int(token[1:], 16)
            else:
                words[address] = int(token, 16) & ((1 << data_width) - 1)
                address += 1
    return words


def _hot_addresses(address_width: int, tile_address_width: int) -> list[int]:
    """Return addresses at the edges of every macro row, plus random ones."""
    depth = 1 << address_width
    tile_depth = min(depth, 1 << tile_address_width)
    addresses = set()
    for base in range(0, depth, tile_depth):
        addresses.update(
            {base, base + 1, base + tile_depth // 2, base + tile_depth - 1}
        )
    addresses.update(random.randrange(depth) for _ in range(32))
    return sorted(addresses)


def _merge(
    old: int | None, new: int, mask: int, lanes: int, granule: int
) -> int | None:
    """Return a word after a masked write, or None if a lane is unknown."""
    full = (1 << (lanes * granule)) - 1
    written = 0
    for lane in range(lanes):
        if mask >> lane & 1:
            written |= ((1 << granule) - 1) << (lane * granule)
    if old is None:
        return new & full if written == full else None
    return (old & ~written & full) | (new & written)


class Expected:
    """Read data expected at the sample points of later cycles."""

    def __init__(self, label: str) -> None:
        """Start with no reads due; label names the bench in failures."""
        self.label = label
        self.reads: dict[int, tuple[int, int | None]] = {}
        self.checked = 0

    def expect(self, cycle: int, address: int, value: int | None) -> None:
        """Expect value from address in cycle; None leaves the data unchecked."""
        self.reads[cycle] = (address, value)

    def check(self, cycle: int, output: Any) -> bool:
        """Check the read due in cycle; return whether one was due."""
        if cycle not in self.reads:
            return False
        address, value = self.reads.pop(cycle)
        if value is not None:
            got = int(output.value)
            assert got == value, (
                f"{self.label}: cycle {cycle}, address {address:#x}: read "
                f"{got:#x}, expected {value:#x}"
            )
            self.checked += 1
        return True


async def _sdp_ram_byte_en(dut: Any) -> None:
    """Check the cache data arrays: byte writes, READ_LATENCY-cycle reads."""
    data_width = len(dut.i_wdata)
    address_width = len(dut.i_waddr)
    lanes = len(dut.i_wbyte_en)
    read_latency = int(dut.READ_LATENCY.value)
    write_latency = int(dut.WRITE_LATENCY.value)
    register_input = int(dut.REGISTER_READ_INPUT.value)
    addresses = _hot_addresses(address_width, 12)

    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_wbyte_en.value = 0
    dut.i_re.value = 0
    await _start_cycle(dut.i_clk)

    # A write presented in cycle c reaches the array in cycle
    # c + write_latency - 1, and a read presented in cycle c samples the array
    # in cycle c + register_input, where it sees the writes of earlier cycles.
    memory: dict[int, int | None] = {}
    array_writes: dict[int, tuple[int, int, int]] = {}
    expected = Expected("sdp_ram_byte_en")
    for cycle in range(CYCLES):
        write = random.random() < 0.5
        read = random.random() < 0.6
        write_address = random.choice(addresses)
        read_address = random.choice(addresses)
        write_cycle = cycle + write_latency - 1
        read_cycle = cycle + register_input
        landing = array_writes.get(read_cycle)
        if landing is not None and landing[0] == read_address:
            read = False
        if write_cycle == read_cycle and write_address == read_address:
            write = False
        # Whole-row writes, as fills do, make rows known; byte writes merge.
        mask = (1 << lanes) - 1 if random.random() < 0.3 else random.getrandbits(lanes)
        data = random.getrandbits(data_width)
        dut.i_wbyte_en.value = mask if write else 0
        dut.i_waddr.value = write_address
        dut.i_wdata.value = data
        dut.i_re.value = int(read)
        dut.i_raddr.value = read_address
        if write:
            array_writes[write_cycle] = (write_address, data, mask)
        for array_cycle in sorted(c for c in array_writes if c < read_cycle):
            address, value, write_mask = array_writes.pop(array_cycle)
            memory[address] = _merge(
                memory.get(address), value, write_mask, lanes, data_width // lanes
            )
        if read:
            expected.expect(
                cycle + read_latency, read_address, memory.get(read_address)
            )
        await _sample_point(CLOCK_PERIOD_NS)
        expected.check(cycle, dut.o_rdata)
        await _start_cycle(dut.i_clk)
    assert expected.checked > CYCLES // 10, f"{expected.checked} reads checked"


async def _sdp_block_ram(dut: Any) -> None:
    """Check the tags, replacement state, and BTB payloads: a read every cycle.

    A quarter of the cycles write the word being read, which returns the old
    word, as from a block RAM, and some read the word written in the cycle
    before, which returns the new one.
    """
    data_width = len(dut.i_write_data)
    address_width = len(dut.i_write_address)
    addresses = _hot_addresses(address_width, 12)

    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_write_enable.value = 0
    dut.i_bulk_clear.value = 0
    await _start_cycle(dut.i_clk)

    memory: dict[int, int] = {}
    expected = Expected("sdp_block_ram")
    last_write: int | None = None
    for cycle in range(CYCLES):
        if last_write is not None and random.random() < 0.15:
            read_address = last_write
        else:
            read_address = random.choice(addresses)
        if random.random() < 0.25:
            write_address = read_address
            write = True
        else:
            write_address = random.choice(addresses)
            write = random.random() < 0.5
        data = random.getrandbits(data_width)
        dut.i_write_enable.value = int(write)
        dut.i_write_address.value = write_address
        dut.i_write_data.value = data
        dut.i_read_address.value = read_address
        if read_address in memory:
            expected.expect(cycle + 1, read_address, memory[read_address])
        if write:
            memory[write_address] = data
        last_write = write_address if write else None
        await _sample_point(CLOCK_PERIOD_NS)
        expected.check(cycle, dut.o_read_data)
        await _start_cycle(dut.i_clk)
    assert expected.checked > CYCLES // 10, f"{expected.checked} reads checked"
    dut.i_write_enable.value = 0
    await _start_cycle(dut.i_clk)
    if int(dut.SUPPORT_BULK_CLEAR.value):
        await _check_bulk_clear(dut, addresses, read_latency=1, read_enable=None)


async def _check_bulk_clear(
    dut: Any, addresses: list[int], read_latency: int, read_enable: Any
) -> None:
    """Clear every word, with a write in the same cycle, and read back zeros.

    Simulation's bulk clear zeroes the macros' models; the clear wins over a
    write in its cycle, as in the block RAM. A macro's read in the clear's
    cycle, here of the word being written, returns zeros as well.
    """
    dut.i_bulk_clear.value = 1
    dut.i_write_enable.value = 1
    dut.i_write_address.value = addresses[0]
    dut.i_write_data.value = (1 << len(dut.i_write_data)) - 1
    if hasattr(dut, "i_write_word_mask"):
        dut.i_write_word_mask.value = (1 << len(dut.i_write_word_mask)) - 1
    dut.i_read_address.value = addresses[0]
    if read_enable is not None:
        read_enable.value = 1
    await _start_cycle(dut.i_clk)
    dut.i_bulk_clear.value = 0
    dut.i_write_enable.value = 0
    if read_enable is not None:
        read_enable.value = 0
    for _ in range(read_latency - 1):
        await _start_cycle(dut.i_clk)
    await _sample_point(CLOCK_PERIOD_NS)
    got = int(dut.o_read_data.value)
    assert got == 0, f"{dut._name}: the read in the clear's cycle returns {got:#x}"
    await _start_cycle(dut.i_clk)
    for address in addresses:
        dut.i_read_address.value = address
        if read_enable is not None:
            read_enable.value = 1
        await _start_cycle(dut.i_clk)
        if read_enable is not None:
            read_enable.value = 0
        for _ in range(read_latency - 1):
            await _start_cycle(dut.i_clk)
        await _sample_point(CLOCK_PERIOD_NS)
        got = int(dut.o_read_data.value)
        assert got == 0, (
            f"{dut._name}: address {address:#x} reads {got:#x} after a clear"
        )
        await _start_cycle(dut.i_clk)


async def _sdp_packed_tag_uram(dut: Any) -> None:
    """Check the L2 tags: group reads after READ_LATENCY cycles, held between.

    A read returns the group of READ_WORDS entries that holds its address,
    and a write sets the entries of its group that the word mask selects.
    """
    data_width = len(dut.i_write_data)
    address_width = len(dut.i_write_address)
    words = len(dut.i_write_word_mask)
    word_bits = words.bit_length() - 1
    read_latency = int(dut.READ_LATENCY.value)
    groups = _hot_addresses(address_width - word_bits, 12)

    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_write_enable.value = 0
    dut.i_bulk_clear.value = 0
    dut.i_read_enable.value = 0
    dut.i_write_word_mask.value = 0
    await _start_cycle(dut.i_clk)

    def group_value(group: int) -> int | None:
        value = 0
        for word in range(words):
            entry = memory.get((group << word_bits) | word)
            if entry is None:
                return None
            value |= entry << (word * data_width)
        return value

    memory: dict[int, int] = {}
    expected = Expected("sdp_packed_tag_uram")
    held: int | None = None
    for cycle in range(CYCLES):
        read = random.random() < 0.6
        read_group = random.choice(groups)
        write_group = random.choice(groups)
        write = random.random() < 0.5 and not (read and write_group == read_group)
        # Whole-group writes make groups known; others set some entries.
        all_words = (1 << words) - 1
        mask = all_words if random.random() < 0.3 else random.getrandbits(words)
        data = random.getrandbits(data_width)
        # An address's word bits select nothing: a group is read and written
        # whole, under the mask.
        dut.i_write_enable.value = int(write)
        dut.i_write_address.value = (write_group << word_bits) | random.getrandbits(
            word_bits
        )
        dut.i_write_word_mask.value = mask
        dut.i_write_data.value = data
        dut.i_read_enable.value = int(read)
        dut.i_read_address.value = (read_group << word_bits) | random.getrandbits(
            word_bits
        )
        if read:
            expected.expect(cycle + read_latency, read_group, group_value(read_group))
        if write:
            for word in range(words):
                if mask >> word & 1:
                    memory[(write_group << word_bits) | word] = data
        await _sample_point(CLOCK_PERIOD_NS)
        response = expected.reads.get(cycle)
        if expected.check(cycle, dut.o_read_data):
            held = response[1] if response is not None else None
        elif held is not None:
            got = int(dut.o_read_data.value)
            assert got == held, f"cycle {cycle}: the output changed to {got:#x}"
        await _start_cycle(dut.i_clk)
    assert expected.checked > CYCLES // 10, f"{expected.checked} reads checked"
    dut.i_read_enable.value = 0
    dut.i_write_enable.value = 0
    for _ in range(read_latency):
        await _start_cycle(dut.i_clk)
    if int(dut.SUPPORT_BULK_CLEAR.value):
        await _check_bulk_clear(
            dut,
            [group << word_bits for group in groups],
            read_latency,
            dut.i_read_enable,
        )


async def _sdp_block_ram_dc(dut: Any) -> None:
    """Check the NIC FIFOs' storage, on unrelated write and read clocks."""
    data_width = len(dut.i_write_data)
    address_width = len(dut.i_write_address)
    depth = 1 << address_width
    read_period_ns = 6.4
    Clock(dut.i_write_clock, CLOCK_PERIOD_NS, unit="ns").start()
    Clock(dut.i_read_clock, read_period_ns, unit="ns").start()
    dut.i_write_enable.value = 0
    dut.i_read_address.value = 0
    await _start_cycle(dut.i_write_clock)

    checked = 0
    memory: dict[int, int] = {}
    for phase in range(4):
        # Write words in one half, then read every word written there.
        half = range(phase % 2 * depth // 2, (phase % 2 + 1) * depth // 2)
        for address in random.sample(list(half), 96):
            data = random.getrandbits(data_width)
            dut.i_write_enable.value = 1
            dut.i_write_address.value = address
            dut.i_write_data.value = data
            memory[address] = data
            await _start_cycle(dut.i_write_clock)
        dut.i_write_enable.value = 0
        await _start_cycle(dut.i_write_clock)
        await _start_cycle(dut.i_read_clock)
        for address in sorted(a for a in memory if a in half):
            dut.i_read_address.value = address
            await _start_cycle(dut.i_read_clock)
            await _sample_point(read_period_ns)
            got = int(dut.o_read_data.value)
            assert got == memory[address], (
                f"sdp_block_ram_dc: address {address:#x}: read {got:#x}, "
                f"expected {memory[address]:#x}"
            )
            checked += 1
            await _start_cycle(dut.i_read_clock)
    assert checked > 300, f"{checked} reads checked"


async def _sdp_block_ram_dc_init(dut: Any) -> None:
    """Check the instruction memory's banks: quarter-rate writes, held reads.

    The write port runs on a quarter of the read clock, with aligned rising
    edges, as imem_predecode's port A does. A read returns the last word
    written to its address, and a cycle without a read leaves the output
    unchanged. A write presented in cycle c reaches the macros at the write
    clock's falling edge in cycle c + 6, and a read presented in cycle r reads
    at the read clock's falling edge in cycle r + 1, so the traffic reads a
    word being written only from cycle c + 5. With USE_INIT_FILE, the bench
    first reads back the starting image, INIT_IMAGE.
    """
    data_width = len(dut.i_write_data)
    address_width = len(dut.i_write_address)
    addresses = _hot_addresses(address_width, 12)

    Clock(dut.i_read_clock, CLOCK_PERIOD_NS, unit="ns").start()
    Clock(dut.i_write_clock, 4 * CLOCK_PERIOD_NS, unit="ns").start()
    dut.i_write_enable.value = 0
    dut.i_read_enable.value = 0
    await _start_cycle(dut.i_write_clock)

    memory: dict[int, int] = {}
    if int(dut.USE_INIT_FILE.value):
        memory = _read_hex_image(INIT_IMAGE, data_width)
        for address, word in sorted(memory.items()):
            dut.i_read_enable.value = 1
            dut.i_read_address.value = address
            await _start_cycle(dut.i_read_clock)
            dut.i_read_enable.value = 0
            await _sample_point(CLOCK_PERIOD_NS)
            got = int(dut.o_read_data.value)
            assert got == word, (
                f"sdp_block_ram_dc_init: address {address:#x} starts with "
                f"{got:#x}, not the image's {word:#x}"
            )
            await _start_cycle(dut.i_read_clock)
        addresses = sorted(set(addresses) | set(memory))
    # Writes not yet readable: address -> (first cycle a read sees it, data).
    landing: dict[int, tuple[int, int]] = {}
    expected = Expected("sdp_block_ram_dc_init")
    held: int | None = None
    for cycle in range(CYCLES):
        for address in [a for a, (due, _) in landing.items() if due <= cycle]:
            memory[address] = landing.pop(address)[1]
        if cycle % 4 == 0:
            write = random.random() < 0.5
            write_address = random.choice(addresses)
            data = random.getrandbits(data_width)
            dut.i_write_enable.value = int(write)
            dut.i_write_address.value = write_address
            dut.i_write_data.value = data
            if write:
                landing[write_address] = (cycle + 5, data)
        read_address = random.choice(addresses)
        read = random.random() < 0.6 and read_address not in landing
        dut.i_read_enable.value = int(read)
        dut.i_read_address.value = read_address
        if read:
            expected.expect(cycle + 1, read_address, memory.get(read_address))
        await _sample_point(CLOCK_PERIOD_NS)
        response = expected.reads.get(cycle)
        if expected.check(cycle, dut.o_read_data):
            held = response[1] if response is not None else None
        elif held is not None:
            got = int(dut.o_read_data.value)
            assert got == held, f"cycle {cycle}: the output changed to {got:#x}"
        await _start_cycle(dut.i_read_clock)
    assert expected.checked > CYCLES // 10, f"{expected.checked} reads checked"


async def _tdp_bram_dc_byte_en(dut: Any) -> None:
    """Check the data memory: byte-write ports on the core and quarter clocks."""
    data_width = len(dut.i_port_a_write_data)
    lanes = len(dut.i_port_a_byte_write_enable)
    address_width = int(dut.ADDR_WIDTH.value)
    byte_shift = (lanes - 1).bit_length()
    addresses = _hot_addresses(address_width, 12)
    # Each port owns half of the addresses, so the ports never collide.
    owned = {
        "a": [a for a in addresses if a % 2 == 0],
        "b": [a for a in addresses if a % 2 == 1],
    }
    # Port B runs on the core clock and port A on a quarter of it, with
    # aligned rising edges, as in cpu_and_mem. A port A read presented in
    # cycle c of port B is due at the sample point of cycle c + 7.
    latency = {"a": 7, "b": 1}

    Clock(dut.i_port_b_clk, CLOCK_PERIOD_NS, unit="ns").start()
    Clock(dut.i_port_a_clk, 4 * CLOCK_PERIOD_NS, unit="ns").start()
    for port in ("a", "b"):
        getattr(dut, f"i_port_{port}_byte_write_enable").value = 0
        getattr(dut, f"i_port_{port}_byte_address").value = 0
    await _start_cycle(dut.i_port_a_clk)
    # Both macro ports must latch idle controls before sampling untouched bytes.
    await _start_cycle(dut.i_port_a_clk)

    # Snapshot untouched bytes before the traffic's partial writes.
    tiles = dut.u_sram.gen_row
    tile_depth = len(tiles[0].u_macro.mem)
    memory: dict[int, int | None] = {
        address: int(
            tiles[address // tile_depth].u_macro.mem[address % tile_depth].value
        )
        for address in addresses
    }
    if not os.environ.get("FROST_RANDOM_START_SEED"):
        assert all(memory[address] == address for address in addresses)
    expected = {port: Expected(f"tdp_bram_dc_byte_en port {port}") for port in "ab"}
    for cycle in range(CYCLES):
        for port in ("b", "a") if cycle % 4 == 0 else ("b",):
            address = random.choice(owned[port])
            write = random.random() < 0.4
            mask = random.getrandbits(lanes) or 1
            data = random.getrandbits(data_width)
            getattr(dut, f"i_port_{port}_byte_address").value = address << byte_shift
            getattr(dut, f"i_port_{port}_write_data").value = data
            getattr(dut, f"i_port_{port}_byte_write_enable").value = (
                mask if write else 0
            )
            if write:
                memory[address] = _merge(
                    memory.get(address), data, mask, lanes, data_width // lanes
                )
            else:
                expected[port].expect(
                    cycle + latency[port], address, memory.get(address)
                )
        await _sample_point(CLOCK_PERIOD_NS)
        expected["b"].check(cycle, dut.o_port_b_read_data)
        expected["a"].check(cycle, dut.o_port_a_read_data)
        await _start_cycle(dut.i_port_b_clk)
    for port in "ab":
        assert expected[port].checked > CYCLES // 40, (
            f"port {port}: {expected[port].checked} reads checked"
        )


BENCHES = {
    "sdp_ram_byte_en": _sdp_ram_byte_en,
    "sdp_block_ram": _sdp_block_ram,
    "sdp_packed_tag_uram": _sdp_packed_tag_uram,
    "sdp_block_ram_dc": _sdp_block_ram_dc,
    "sdp_block_ram_dc_init": _sdp_block_ram_dc_init,
    "tdp_bram_dc_byte_en": _tdp_bram_dc_byte_en,
}


def _macro_grid(dut: Any) -> tuple[int, int]:
    """Return the rows and columns of macros that the wrapper's memory holds."""
    if dut._name == "tdp_bram_dc_byte_en":
        rows = dut.u_sram.gen_row
        return len(rows), 1
    grid = dut.u_sram.gen_macros.gen_row
    return len(grid), len(grid[0].gen_column)


@cocotb.test()
async def test_sram_macro_wrapper(dut: Any) -> None:
    """Check one RAM wrapper built from SRAM macros against its contract."""
    rows, columns = (int(n) for n in os.environ["SRAM_MACRO_GRID"].split("x"))
    assert _macro_grid(dut) == (rows, columns), (
        f"{dut._name} holds {_macro_grid(dut)} macros, not {(rows, columns)}"
    )
    await BENCHES[dut._name](dut)

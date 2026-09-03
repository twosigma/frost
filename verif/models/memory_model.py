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

"""Software model of the CPU data memory.

A sparse, little-endian, byte-addressable dict mirrors hardware memory, so the
testbench can supply load values to the instruction models and check the DUT's
stores. The constructor copies the DUT's initial memory contents so both sides
start from the same state. ``driver_and_monitor`` then checks every store the
DUT makes.

There is no global instance. A test builds one model and passes it to whatever
needs memory access:

    mem_model = MemoryModel(dut)

    from models.alu_model import lw
    value = lw(mem_model, address)
"""

from cocotb.triggers import RisingEdge, FallingEdge
import cocotb
from typing import Any
from config import (
    MASK32,
    MASK64,
    MEM_STRB_BITS,
    MEMORY_ADDRESS_MASK,
    MEMORY_WORD_ALIGN_MASK,
    MEMORY_DWORD_ALIGN_MASK,
    MEMORY_SIZE_DWORDS,
)


def poke_dut_memory_word(device_under_test: Any, byte_address: int, value: int) -> None:
    """Deposit one 32-bit word into the DUT's dword-row simulation data BRAM.

    The data BRAM stores aligned 64-bit rows (hw/rtl/README.md, "Data-tier bus
    contract"), so a word deposit is a read-modify-write of the addressed row's
    word lane.

    cocotb ``.value`` writes are queued deposits. A second read-modify-write of
    the same row within one scheduler delta therefore reads the pre-deposit
    value, and its write clobbers the first word. Use poke_dut_memory_dword to
    write both words of a row in one delta.

    Args:
        device_under_test: CoCoTB DUT handle with data_memory_for_simulation
        byte_address: Word-aligned byte address to poke
        value: 32-bit value to deposit
    """
    row = byte_address >> 3
    shift = 32 if byte_address & 0x4 else 0
    row_handle = device_under_test.data_memory_for_simulation.memory[row]
    current = int(row_handle.value)
    row_handle.value = (current & ~(MASK32 << shift)) | ((value & MASK32) << shift)


def peek_dut_memory_word(device_under_test: Any, byte_address: int) -> int:
    """Read one 32-bit word from the DUT's dword-row simulation data BRAM.

    Args:
        device_under_test: CoCoTB DUT handle with data_memory_for_simulation
        byte_address: Word-aligned byte address to read

    Returns:
        The 32-bit word at that address
    """
    row = byte_address >> 3
    shift = 32 if byte_address & 0x4 else 0
    row_value = int(device_under_test.data_memory_for_simulation.memory[row].value)
    return (row_value >> shift) & MASK32


def poke_dut_memory_dword(
    device_under_test: Any, byte_address: int, value: int
) -> None:
    """Deposit one aligned 64-bit dword row into the DUT's simulation data BRAM.

    Args:
        device_under_test: CoCoTB DUT handle with data_memory_for_simulation
        byte_address: Dword-aligned byte address to poke
        value: 64-bit value to deposit
    """
    device_under_test.data_memory_for_simulation.memory[byte_address >> 3].value = (
        value & MASK64
    )


class MemoryModel:
    """Byte-addressable software copy of data memory.

    Implements the MemoryReader protocol from alu_model.py, so the model can be
    handed straight to the load models (lw, ld, lh, lhu, lb, lbu). The
    ``driver_and_monitor`` coroutine runs alongside the test and checks the
    DUT's stores.

    Attributes:
        dut: Reference to the device under test
        read_address: Address staged by the caller for the next modelled load
        ram_bytes: Byte address to byte value
    """

    def __init__(self, device_under_test: Any) -> None:
        """Initialize the model from the DUT's current memory contents.

        Copying at construction leaves software and hardware memory identical
        before the test drives its first instruction.

        Args:
            device_under_test: CoCoTB DUT handle with data_memory_for_simulation
        """
        self.dut = device_under_test
        self.read_address: int = 0
        self.ram_bytes: dict[int, int] = {}

        # The simulation data BRAM stores aligned 64-bit dword rows, so the
        # copy runs one dword per row index.
        for row_index in range(MEMORY_SIZE_DWORDS):
            self.write_dword(
                row_index * 8,
                int(
                    device_under_test.data_memory_for_simulation.memory[row_index].value
                ),
            )

    def read_byte(self, address: int) -> int:
        """Read a single byte from memory at the specified address.

        Args:
            address: Byte address to read from

        Returns:
            8-bit value at that address (0 if uninitialized)
        """
        return self.ram_bytes.get(address & MEMORY_ADDRESS_MASK, 0)

    def write_byte(self, address: int, value: int) -> None:
        """Write a single byte to memory at the specified address.

        Args:
            address: Byte address to write to
            value: 8-bit value to write
        """
        self.ram_bytes[address & MEMORY_ADDRESS_MASK] = value & 0xFF

    def read_word(self, address: int) -> int:
        """Read a full 32-bit word from memory (little-endian).

        Args:
            address: Byte address (will be aligned to 4-byte boundary)

        Returns:
            32-bit word value assembled from 4 bytes
        """
        aligned_address = address & MEMORY_WORD_ALIGN_MASK
        return (
            self.read_byte(aligned_address)
            | self.read_byte(aligned_address + 1) << 8
            | self.read_byte(aligned_address + 2) << 16
            | self.read_byte(aligned_address + 3) << 24
        )

    def write_word(self, address: int, value: int = 0) -> None:
        """Write a full 32-bit word to memory (little-endian).

        Args:
            address: Byte address (will be aligned to 4-byte boundary)
            value: 32-bit word value to write
        """
        aligned_address = address & MEMORY_WORD_ALIGN_MASK

        self.write_byte(aligned_address, value & 0xFF)
        self.write_byte(aligned_address + 1, (value >> 8) & 0xFF)
        self.write_byte(aligned_address + 2, (value >> 16) & 0xFF)
        self.write_byte(aligned_address + 3, (value >> 24) & 0xFF)

    def read_dword(self, address: int) -> int:
        """Read a full aligned 64-bit dword from memory (little-endian).

        Args:
            address: Byte address (will be aligned to 8-byte boundary)

        Returns:
            64-bit dword value assembled from 8 bytes
        """
        aligned_address = address & MEMORY_DWORD_ALIGN_MASK
        return self.read_word(aligned_address) | (
            self.read_word(aligned_address + 4) << 32
        )

    def write_dword(self, address: int, value: int = 0) -> None:
        """Write a full aligned 64-bit dword to memory (little-endian).

        Args:
            address: Byte address (will be aligned to 8-byte boundary)
            value: 64-bit dword value to write
        """
        aligned_address = address & MEMORY_DWORD_ALIGN_MASK
        self.write_word(aligned_address, value & MASK32)
        self.write_word(aligned_address + 4, (value >> 32) & MASK32)

    async def driver_and_monitor(
        self,
        write_data_expected_queue: list[int],
        write_address_expected_queue: list[int],
    ) -> None:
        """Check DUT memory writes against the expected-write queues.

        Runs concurrently with the test, watching the DUT's data memory
        interface. Once reset de-asserts, every write the DUT drives has to
        match the address and data at the head of the expected queues. A write
        arriving with the queues empty fails the test.

        Despite the name, the coroutine is check-only. It does not write back
        into the software memory model and does not drive read data to the CPU.

        Args:
            write_data_expected_queue: Queue of expected write data values
            write_address_expected_queue: Queue of expected write addresses

        Raises:
            AssertionError: If write address or data doesn't match expected,
                          or if unexpected write occurs
        """
        await RisingEdge(self.dut.i_clk)
        while bool(self.dut.i_rst.value):
            await RisingEdge(self.dut.i_clk)

        while True:
            await FallingEdge(self.dut.i_clk)
            await RisingEdge(self.dut.i_clk)

            wr_mask = int(self.dut.o_data_mem_per_byte_wr_en.value) & (
                (1 << MEM_STRB_BITS) - 1
            )
            if wr_mask:
                # Store data rides the beat replicated across lanes (bus
                # contract), so the full 64-bit compare is lane-independent.
                wr_addr = int(self.dut.o_data_mem_addr.value) & MASK32
                wr_data = int(self.dut.o_data_mem_wr_data.value) & MASK64

                if write_address_expected_queue:
                    exp_addr = write_address_expected_queue.pop(0)
                    exp_data = write_data_expected_queue.pop(0)

                    assert wr_addr == exp_addr, (
                        f"Memory-write address mismatch: got 0x{wr_addr:08X}, "
                        f"expected 0x{exp_addr:08X}, "
                        f"RANDOM_SEED {cocotb.RANDOM_SEED}"
                    )

                    assert wr_data == exp_data, (
                        f"Memory-write data mismatch at 0x{wr_addr:08X}: "
                        f"got 0x{wr_data:016X}, expected 0x{exp_data:016X}, "
                        f"RANDOM_SEED {cocotb.RANDOM_SEED}"
                    )
                else:
                    raise AssertionError(
                        f"Unexpected memory write: addr 0x{wr_addr:08X}, "
                        f"data 0x{wr_data:016X}, mask 0b{wr_mask:08b}, "
                        f"RANDOM_SEED {cocotb.RANDOM_SEED}"
                    )

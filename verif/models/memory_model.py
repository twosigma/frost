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

"""Software model of the CPU data-memory interface.

The byte-addressable model mirrors hardware memory so the testbench can:

    1. Drive read data back to the CPU for load instructions
    2. Monitor write operations and verify addresses/data
    3. Keep software and hardware memory synchronized

Memory is sparse, little-endian, and passed explicitly rather than held in
global state. ``driver_and_monitor`` checks DUT stores.

Usage:
    The MemoryModel is instantiated once per test with the DUT:

        mem_model = MemoryModel(dut)

    Then passed explicitly to functions that need memory access:

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

    The data BRAM stores aligned 64-bit rows (hw/rtl/README.md, "Data-tier bus contract"), so
    a word deposit is a read-modify-write of the addressed row's word lane.

    CAUTION: cocotb ``.value`` writes are queued deposits — the read half of
    a second RMW to the SAME row within one scheduler delta sees the
    pre-deposit value and its write clobbers the first word.  To write both
    words of a row in one delta, use poke_dut_memory_dword instead.

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
    """Software model of data memory for CPU verification.

    Models load and store operations, maintaining a byte-addressable memory array.
    Synchronizes with DUT memory through a coroutine that monitors memory transactions.

    This class implements the MemoryReader protocol from alu_model.py, allowing
    it to be passed to load functions (lw, lh, lb, lhu, lbu).

    Attributes:
        dut: Reference to the device under test
        read_address: Address for pending load operation
        ram_bytes: Byte-addressable memory dictionary
    """

    def __init__(self, device_under_test: Any) -> None:
        """Initialize data memory model with contents from DUT.

        Copies initial memory contents from hardware to software model to ensure
        consistency between software model and hardware state.

        Args:
            device_under_test: CoCoTB DUT handle with data_memory_for_simulation
        """
        self.dut = device_under_test
        self.read_address: int = 0  # Address for pending load operation
        self.ram_bytes: dict[int, int] = {}  # Byte-addressable memory dictionary

        # Initialize testbench RAM to match DUT RAM contents (the simulation
        # data BRAM stores aligned 64-bit dword rows).
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

        # Write the word as 4 bytes in little-endian order (LSB first)
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

        This coroutine runs concurrently with the main test, monitoring the
        DUT's data memory interface. It:

            1. Waits for reset to complete
            2. Continuously monitors for memory write operations
            3. When a write is detected, verifies address and data match the
               head of the expected queues (and fails on an unexpected write)

        Despite the name, it neither writes back into the software memory
        model nor drives read data to the CPU; it is check-only.

        Args:
            write_data_expected_queue: Queue of expected write data values
            write_address_expected_queue: Queue of expected write addresses

        Raises:
            AssertionError: If write address or data doesn't match expected,
                          or if unexpected write occurs
        """
        # Wait for reset to de-assert
        await RisingEdge(self.dut.i_clk)
        while bool(self.dut.i_rst.value):
            await RisingEdge(self.dut.i_clk)

        # Main monitoring loop
        while True:
            # Advance clock and check for memory writes
            await FallingEdge(self.dut.i_clk)
            await RisingEdge(self.dut.i_clk)

            # Check if DUT is performing a write (non-zero 8-lane strobe)
            wr_mask = int(self.dut.o_data_mem_per_byte_wr_en.value) & (
                (1 << MEM_STRB_BITS) - 1
            )
            if wr_mask:
                # Read write address and beat data from DUT outputs.  Store
                # data rides the beat replicated (bus contract), so the full
                # 64-bit compare is lane-independent.
                wr_addr = int(self.dut.o_data_mem_addr.value) & MASK32
                wr_data = int(self.dut.o_data_mem_wr_data.value) & MASK64

                # Verify against expected values from software model
                if write_address_expected_queue:
                    exp_addr = write_address_expected_queue.pop(0)
                    exp_data = write_data_expected_queue.pop(0)

                    # Verify write address matches expected
                    assert wr_addr == exp_addr, (
                        f"Memory-write address mismatch: got 0x{wr_addr:08X}, "
                        f"expected 0x{exp_addr:08X}, "
                        f"RANDOM_SEED {cocotb.RANDOM_SEED}"
                    )

                    # Verify write data matches expected
                    assert wr_data == exp_data, (
                        f"Memory-write data mismatch at 0x{wr_addr:08X}: "
                        f"got 0x{wr_data:016X}, expected 0x{exp_data:016X}, "
                        f"RANDOM_SEED {cocotb.RANDOM_SEED}"
                    )
                else:
                    # No write was expected - this is an error
                    raise AssertionError(
                        f"Unexpected memory write: addr 0x{wr_addr:08X}, "
                        f"data 0x{wr_data:016X}, mask 0b{wr_mask:08b}, "
                        f"RANDOM_SEED {cocotb.RANDOM_SEED}"
                    )

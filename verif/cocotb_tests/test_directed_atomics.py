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

"""Directed RISC-V A-extension tests for LR.W and SC.W.

LR/SC stays out of the random regression because the reservation register
makes it stateful: whether an SC.W succeeds depends on the preceding LR.W and
on everything issued between them, which a random instruction stream does not
control.

Test cases:
    1. LR.W + SC.W success: load-reserved then store-conditional to the same
       address
    2. SC.W without LR.W: fails (no reservation)
    3. SC.W to the wrong address: LR to addr A, SC to addr B, fails
    4. Back-to-back LR.W/SC.W with no instruction between them
    5. LR.W + intervening NOPs + SC.W: the reservation persists

OOO retirement:
    On the cpu_ooo core an instruction's architectural effects (regfile write,
    store to memory) land at ROB commit, a variable number of cycles after the
    cpu_tb harness feeds it. LR/SC in particular are serialized through the
    memory RS/LSQ. Register readbacks therefore wait for the instruction's
    commit on the registered ROB commit bus (wait_for_int_reg_commit) and
    store visibility waits for the monitor-checked memory write
    (wait_for_memory_writes) instead of counting a fixed in-order pipeline
    depth.

LR/SC protocol:
    ┌────────────────────────────────────────────────────────────────┐
    │ LR.W rd, (rs1)                                                 │
    │   - Load word from memory[rs1] into rd                         │
    │   - Set reservation register to rs1 address                    │
    │                                                                │
    │ SC.W rd, rs2, (rs1)                                            │
    │   - If reservation matches rs1 address:                        │
    │       - Store rs2 to memory[rs1]                               │
    │       - Write 0 to rd (success)                                │
    │   - Else:                                                      │
    │       - Do not store                                           │
    │       - Write 1 to rd (failure)                                │
    │   - Clear reservation in either case                           │
    └────────────────────────────────────────────────────────────────┘

Usage: ``cd tests && ./test_run_cocotb.py directed_atomics``.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from config import MASK32
from models.memory_model import MemoryModel
from utils.memory_utils import replicate_store_data_for_beat
from cocotb_tests.test_helpers import DUTInterface
from cocotb_tests.test_state import TestState
from cocotb_tests.test_common import (
    TestConfig,
    drive_nops_until,
    execute_nop,
    wait_for_int_reg_commit,
)


async def wait_for_memory_writes(
    dut_if: DUTInterface, state: TestState, what: str
) -> None:
    """Wait until every queued expected memory write has been performed.

    The MemoryModel monitor pops (and value/address-checks) one entry from the
    expected-write queues per write it observes on the DUT memory port, so an
    empty queue means all modeled stores have drained to memory. Pads two more
    NOPs afterwards so the last write is visible in the memory array.
    """
    await drive_nops_until(
        dut_if,
        state,
        lambda: not state.memory_write_address_expected_queue,
        what,
    )
    for _ in range(2):
        await execute_nop(dut_if, state)


async def execute_lr_sc_instruction(
    dut_if: DUTInterface,
    state: TestState,
    mem_model: MemoryModel,
    operation: str,
    rd: int,
    rs1: int,
    rs2: int,
    expected_rd_value: int,
    expected_sc_success: bool | None,
) -> None:
    """Execute and model one LR.W or SC.W instruction.

    Args:
        dut_if: DUT interface for signal access
        state: Test state for tracking expectations
        mem_model: Memory model for load/store operations
        operation: "lr.w" or "sc.w"
        rd: Destination register
        rs1: Address register
        rs2: Data register (for SC.W, ignored for LR.W)
        expected_rd_value: Expected value written to rd
        expected_sc_success: For SC.W, whether it should succeed (None for LR.W)
    """
    from encoders.op_tables import AMO_LR_SC

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()

    encoder = AMO_LR_SC[operation]
    if operation == "lr.w":
        instr = encoder(rd, rs1)
    else:
        instr = encoder(rd, rs2, rs1)

    address = state.register_file_previous[rs1] & ~0x3  # Word-aligned

    queue_len = len(state.register_file_current_expected_queue)

    if operation == "lr.w":
        # LR.W: load from memory, set reservation
        mem_model.read_address = address
        state.set_reservation(address)
        writeback_value = expected_rd_value
        cocotb.log.info(
            f"LR.W x{rd}, (x{rs1}): addr=0x{address:08X}, "
            f"loaded=0x{writeback_value:08X}, reservation set, queue_before={queue_len}, "
            f"instr=0x{instr:08X}"
        )
    else:
        # SC.W: check reservation, conditionally store
        success = state.check_reservation(address)
        state.clear_reservation()
        writeback_value = 0 if success else 1

        if success:
            # Model memory write (word data rides the beat replicated)
            write_data = state.register_file_previous[rs2]
            state.memory_write_address_expected_queue.append(address)
            state.memory_write_data_expected_queue.append(
                replicate_store_data_for_beat("sw", write_data)
            )
            mem_model.write_word(address, write_data)
            cocotb.log.info(
                f"SC.W x{rd}, x{rs2}, (x{rs1}): addr=0x{address:08X}, "
                f"data=0x{write_data:08X}, SUCCESS (rd=0)"
            )
        else:
            cocotb.log.info(
                f"SC.W x{rd}, x{rs2}, (x{rs1}): addr=0x{address:08X}, "
                f"FAILED (rd=1, no write)"
            )

        # Track SC result for verification
        state.last_sc_succeeded = success
        state.last_sc_address = address
        state.last_sc_data = state.register_file_previous[rs2]

    if rd != 0:
        state.register_file_current[rd] = writeback_value & MASK32

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)

    dut_if.instruction = instr
    await RisingEdge(dut_if.clock)

    state.increment_cycle_counter()
    state.increment_instret_counter()
    state.update_program_counter(expected_pc)
    state.advance_register_state()


async def execute_store(
    dut_if: DUTInterface,
    state: TestState,
    mem_model: MemoryModel,
    rs1: int,
    rs2: int,
    imm: int = 0,
) -> None:
    """Execute a SW (store word) instruction.

    Used by directed tests to initialize memory before testing LR/SC sequences.

    Args:
        dut_if: DUT interface for signal access
        state: Test state for tracking expectations
        mem_model: Memory model for store operations
        rs1: Base address register
        rs2: Data register
        imm: Immediate offset (default 0)
    """
    from encoders.op_tables import STORES

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()

    enc_sw = STORES["sw"]
    instr = enc_sw(rs2, rs1, imm)

    address = (state.register_file_previous[rs1] + imm) & MASK32
    write_data = state.register_file_previous[rs2] & MASK32

    # Queue expected memory write (word data rides the beat replicated)
    state.memory_write_address_expected_queue.append(address)
    state.memory_write_data_expected_queue.append(
        replicate_store_data_for_beat("sw", write_data)
    )

    mem_model.write_word(address, write_data)

    cocotb.log.info(
        f"SW x{rs2}, {imm}(x{rs1}): addr=0x{address:08X}, data=0x{write_data:08X}"
    )

    # Queue expected outputs (no register change for store)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)

    dut_if.instruction = instr
    await RisingEdge(dut_if.clock)

    state.increment_cycle_counter()
    state.increment_instret_counter()
    state.update_program_counter(expected_pc)
    state.advance_register_state()


async def run_directed_lr_sc_test(dut: Any, config: TestConfig | None = None) -> None:
    """Directed test for LR.W (load-reserved) and SC.W (store-conditional).

    LR.W sets a reservation on a memory address and SC.W stores only if that
    reservation is still valid. The five cases are listed in the module
    docstring.

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
    """
    if config is None:
        config = TestConfig(num_loops=100)  # Shorter test for directed cases

    # ========================================================================
    # Initialization Phase
    # ========================================================================
    dut_if = DUTInterface(dut)
    state = TestState()

    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Word-aligned addresses in the initialized memory region.
    test_address_1 = 0x100  # First test address
    test_address_2 = 0x200  # Second test address (for mismatch test)
    test_data = 0xDEADBEEF

    # Every register gets its final test value before any expected value is
    # queued.
    test_value_1 = 0x12345678  # Initial value for addr1
    test_value_2 = 0x87654321  # Initial value for addr2

    # Known register values (not random) so the directed cases are reproducible.
    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x01010101) & MASK32  # Predictable values

    state.register_file_current[10] = test_address_1  # x10 = addr1
    state.register_file_current[11] = test_address_2  # x11 = addr2
    state.register_file_current[12] = test_data  # x12 = data to store
    state.register_file_current[20] = test_value_1  # x20 = initial value for addr1
    state.register_file_current[21] = test_value_2  # x21 = initial value for addr2

    # Write all register values to the DUT.
    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # The regfile/PC monitors are not started for directed tests. They assume
    # steady-state instruction flow, with expected values queued at the same
    # rate o_vld fires, and the waits and readback checks below break that.
    # Each instruction sequence is verified with an explicit readback instead.

    reset_cycle_count = await dut_if.reset_dut(config.reset_cycles)
    state.csr_cycle_counter = reset_cycle_count - config.reset_cycles

    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file history used by the monitor alignment model.
    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup: Let pipeline drain and sync expected queues
    # ========================================================================
    cocotb.log.info("=== Warming up pipeline ===")
    for i in range(8):  # More than pipeline depth to ensure sync
        cocotb.log.info(
            f"Warmup NOP {i}: queue_len={len(state.register_file_current_expected_queue)}"
        )
        await execute_nop(dut_if, state)

    # ========================================================================
    # Initialize DUT memory by performing stores
    # ========================================================================
    cocotb.log.info("=== Initializing memory via store instructions ===")

    # SW x20, 0(x10) - store test_value_1 to test_address_1
    await execute_store(dut_if, state, mem_model, rs1=10, rs2=20)
    # SW x21, 0(x11) - store test_value_2 to test_address_2
    await execute_store(dut_if, state, mem_model, rs1=11, rs2=21)

    # Wait for both stores to drain to memory. On the OOO core stores leave
    # the store queue only after ROB commit, so this takes a variable number
    # of cycles. The MemoryModel monitor checks each write as it happens.
    cocotb.log.info("=== Waiting for stores to complete ===")
    await wait_for_memory_writes(dut_if, state, "init stores to reach memory")

    # Peek the DUT memory after the stores. The simulation data BRAM stores
    # 64-bit dword rows, and the helper extracts the word lane.
    from models.memory_model import peek_dut_memory_word

    try:
        mem_val_1 = peek_dut_memory_word(dut, test_address_1)
        mem_val_2 = peek_dut_memory_word(dut, test_address_2)
        cocotb.log.info(
            f"DEBUG: DUT memory word at 0x{test_address_1:08X} = 0x{mem_val_1:08X}"
        )
        cocotb.log.info(
            f"DEBUG: DUT memory word at 0x{test_address_2:08X} = 0x{mem_val_2:08X}"
        )
    except Exception as e:
        cocotb.log.warning(f"DEBUG: Could not read DUT memory: {e}")

    # ========================================================================
    # Test Case 1: LR.W + SC.W Success (same address)
    # ========================================================================
    cocotb.log.info("=== Test Case 1: LR.W + SC.W to same address (should succeed) ===")

    # Drive LR.W x5, (x10) - load from test_address_1, set reservation
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="lr.w",
        rd=5,
        rs1=10,
        rs2=0,
        expected_rd_value=0x12345678,  # Value at test_address_1
        expected_sc_success=None,  # N/A for LR.W
    )

    # Wait for the LR.W to retire: its architectural x5 write lands at ROB
    # commit, a variable number of cycles after issue on the OOO core.
    await wait_for_int_reg_commit(
        dut, dut_if, state, 5, "Test Case 1 LR.W x5 to commit"
    )

    x5_value = dut_if.read_register(5)
    cocotb.log.info(
        f"DEBUG: After LR.W + NOPs, x5 = 0x{x5_value:08X} (expected 0x12345678)"
    )
    assert (
        x5_value == 0x12345678
    ), f"LR.W failed: x5 = 0x{x5_value:08X}, expected 0x12345678"
    cocotb.log.info("=== LR.W TEST PASSED! ===")

    # Drive SC.W x6, x12, (x10) - store test_data to test_address_1
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=6,
        rs1=10,
        rs2=12,
        expected_rd_value=0,  # 0 = success
        expected_sc_success=True,
    )

    # Verify SC.W result after it retires
    await wait_for_int_reg_commit(
        dut, dut_if, state, 6, "Test Case 1 SC.W x6 to commit"
    )
    x6_value = dut_if.read_register(6)
    assert (
        x6_value == 0
    ), f"SC.W Test Case 1 failed: x6 = {x6_value}, expected 0 (success)"
    cocotb.log.info(f"SC.W x6 = {x6_value} (success)")

    # The successful SC.W also stores test_data to test_address_1; wait for
    # that (monitor-checked) write to drain so later LR.W reads see it.
    await wait_for_memory_writes(
        dut_if, state, "Test Case 1 SC.W store to reach memory"
    )

    # ========================================================================
    # Test Case 2: SC.W without LR.W (should fail)
    # ========================================================================
    cocotb.log.info("=== Test Case 2: SC.W without LR.W (should fail) ===")

    # SC.W x7, x12, (x10) - no reservation, should fail
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=7,
        rs1=10,
        rs2=12,
        expected_rd_value=1,  # 1 = failure
        expected_sc_success=False,
    )

    # Verify SC.W failure after it retires
    await wait_for_int_reg_commit(
        dut, dut_if, state, 7, "Test Case 2 SC.W x7 to commit"
    )
    x7_value = dut_if.read_register(7)
    assert (
        x7_value == 1
    ), f"SC.W Test Case 2 failed: x7 = {x7_value}, expected 1 (failure)"
    cocotb.log.info(f"SC.W x7 = {x7_value} (failed as expected)")

    # ========================================================================
    # Test Case 3: LR.W + SC.W to different address (should fail)
    # ========================================================================
    cocotb.log.info("=== Test Case 3: LR.W addr1, SC.W addr2 (should fail) ===")

    # LR.W x8, (x10) - load from test_address_1
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="lr.w",
        rd=8,
        rs1=10,
        rs2=0,
        expected_rd_value=test_data,  # Value stored by Test Case 1
        expected_sc_success=None,
    )

    # SC.W x9, x12, (x11) - try to store to test_address_2 (wrong address!)
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=9,
        rs1=11,
        rs2=12,  # x11 = addr2, different from LR's x10
        expected_rd_value=1,  # 1 = failure (address mismatch)
        expected_sc_success=False,
    )

    # Verify SC.W failure due to address mismatch. Waiting for x9 also
    # covers the LR.W x8 (ROB commit is in program order).
    await wait_for_int_reg_commit(
        dut, dut_if, state, 9, "Test Case 3 SC.W x9 to commit"
    )
    x9_value = dut_if.read_register(9)
    assert (
        x9_value == 1
    ), f"SC.W Test Case 3 failed: x9 = {x9_value}, expected 1 (failure)"
    cocotb.log.info(f"SC.W x9 = {x9_value} (failed due to address mismatch)")

    # ========================================================================
    # Test Case 4: Back-to-back LR.W/SC.W
    # ========================================================================
    cocotb.log.info("=== Test Case 4: Back-to-back LR.W/SC.W (pipeline test) ===")

    # LR.W immediately followed by SC.W, with no instruction between them.
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="lr.w",
        rd=13,
        rs1=11,
        rs2=0,  # LR from addr2
        expected_rd_value=0x87654321,  # Original value at addr2
        expected_sc_success=None,
    )

    # Immediately follow with SC.W to same address
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=14,
        rs1=11,
        rs2=12,  # SC to addr2 (same as LR)
        expected_rd_value=0,  # 0 = success
        expected_sc_success=True,
    )

    # Verify back-to-back SC.W success
    await wait_for_int_reg_commit(
        dut, dut_if, state, 14, "Test Case 4 SC.W x14 to commit"
    )
    x14_value = dut_if.read_register(14)
    assert (
        x14_value == 0
    ), f"SC.W Test Case 4 failed: x14 = {x14_value}, expected 0 (success)"
    cocotb.log.info(f"SC.W x14 = {x14_value} (back-to-back success via forwarding)")

    # Wait for the successful SC.W's store to test_address_2 to drain.
    await wait_for_memory_writes(
        dut_if, state, "Test Case 4 SC.W store to reach memory"
    )

    # ========================================================================
    # Test Case 5: LR.W + intervening NOPs + SC.W (reservation persists)
    # ========================================================================
    cocotb.log.info("=== Test Case 5: LR.W + NOPs + SC.W (reservation persists) ===")

    # LR.W x15, (x10) - set reservation
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="lr.w",
        rd=15,
        rs1=10,
        rs2=0,
        expected_rd_value=test_data,  # Value from Test Case 1's SC
        expected_sc_success=None,
    )

    # Insert a few NOPs (addi x0, x0, 0)
    for _ in range(3):
        await execute_nop(dut_if, state)

    # SC.W x16, x12, (x10) - should still succeed
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=16,
        rs1=10,
        rs2=12,
        expected_rd_value=0,  # 0 = success
        expected_sc_success=True,
    )

    # Verify SC.W success after intervening NOPs
    await wait_for_int_reg_commit(
        dut, dut_if, state, 16, "Test Case 5 SC.W x16 to commit"
    )
    x16_value = dut_if.read_register(16)
    assert (
        x16_value == 0
    ), f"SC.W Test Case 5 failed: x16 = {x16_value}, expected 0 (success)"
    cocotb.log.info(f"SC.W x16 = {x16_value} (success after NOPs)")

    # Wait for the successful SC.W's store to test_address_1 to drain.
    await wait_for_memory_writes(
        dut_if, state, "Test Case 5 SC.W store to reach memory"
    )

    # ========================================================================
    # Cleanup: Flush pipeline with NOPs
    # ========================================================================
    cocotb.log.info("=== Flushing pipeline ===")
    for _ in range(10):
        await execute_nop(dut_if, state)

    cocotb.log.info("=== All LR.W/SC.W directed tests passed! ===")


@cocotb.test()
async def test_directed_lr_sc(dut: Any) -> None:
    """Directed test for LR.W and SC.W atomic instructions."""
    await run_directed_lr_sc_test(dut)

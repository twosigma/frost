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

"""Directed tests for back-to-back multi-cycle operations.

This module tests that back-to-back multi-cycle operations (integer div/mul
and FP operations) correctly write their results even when one operation's
stall overlaps with another operation in the writeback stage.

The RTL gates regfile writes on the stall signal. This test verifies that
the pipeline correctly handles the case where:
1. Operation A completes and its result is in WB
2. Operation B causes a stall
3. Operation A's write should still succeed
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from config import MASK32, MASK64, PIPELINE_DEPTH
from monitors.monitors import regfile_monitor, pc_monitor, fp_regfile_monitor
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface
from cocotb_tests.test_state import TestState
from cocotb_tests.test_common import TestConfig
from encoders.op_tables import R_ALU


async def execute_instruction(
    dut_if: DUTInterface,
    state: TestState,
    instr: int,
    rd: int,
    expected_value: int,
    description: str,
    is_fp: bool = False,
    use_fp_monitor: bool = False,
    first_after_warmup: bool = False,
) -> None:
    """Execute a single instruction and model its effects.

    Args:
        dut_if: DUT interface
        state: Test state
        instr: Encoded instruction
        rd: Destination register
        expected_value: Expected result value
        description: Description for logging
        is_fp: True if result goes to FP register file
        use_fp_monitor: True if FP monitor is running
        first_after_warmup: True for first instruction after warmup (skip FallingEdge wait)
    """
    # Wait for ready - skip FallingEdge on first call after warmup (matches test_cpu.py)
    if not first_after_warmup:
        await FallingEdge(dut_if.clock)
    wait_cycles = await dut_if.wait_ready()
    state.csr_cycle_counter += wait_cycles

    # Update software model
    if is_fp:
        state.fp_register_file_current[rd] = expected_value & MASK64
    else:
        if rd != 0:
            state.register_file_current[rd] = expected_value & MASK32

    # Queue expected outputs
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    if use_fp_monitor:
        state.fp_register_file_current_expected_queue.append(
            state.fp_register_file_current.copy()
        )
    state.program_counter_expected_values_queue.append(expected_pc)

    if is_fp:
        cocotb.log.info(f"{description}: rd={rd}, expected=0x{expected_value:016X}")
    else:
        cocotb.log.info(f"{description}: rd={rd}, expected=0x{expected_value:08X}")

    # Drive instruction
    dut_if.instruction = instr
    await RisingEdge(dut_if.clock)

    # Advance state
    state.increment_cycle_counter()
    state.increment_instret_counter()
    state.update_program_counter(expected_pc)
    state.advance_register_state()


async def setup_test(dut: Any, use_fp_monitor: bool = False) -> tuple:
    """Set up clock, reset, monitors, and warmup.

    Returns:
        Tuple of (dut_if, state, mem_model)
    """
    config = TestConfig()
    dut_if = DUTInterface(dut)
    state = TestState()

    # Initialize instruction to NOP
    nop = 0x00000013
    dut_if.instruction = nop

    # Start clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Reset DUT first (before initializing registers to avoid reset clearing them)
    reset_cycles = await dut_if.reset_dut(config.reset_cycles)
    state.csr_cycle_counter = reset_cycles - config.reset_cycles

    # Initialize register files AFTER reset
    state.register_file_current = dut_if.initialize_registers()
    if use_fp_monitor:
        state.fp_register_file_current = dut_if.initialize_fp_registers()

    # Start monitors
    cocotb.start_soon(regfile_monitor(dut, state.register_file_current_expected_queue))
    cocotb.start_soon(pc_monitor(dut, state.program_counter_expected_values_queue))
    if use_fp_monitor:
        cocotb.start_soon(
            fp_regfile_monitor(dut, state.fp_register_file_current_expected_queue)
        )

    # Memory model
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize previous state
    state.register_file_previous = state.register_file_current.copy()
    state.fp_register_file_previous = state.fp_register_file_current.copy()

    # Warmup pipeline with NOPs (matches test_cpu.py warmup pattern exactly)
    cocotb.log.info(f"=== Warming up pipeline ({PIPELINE_DEPTH} NOPs) ===")
    for warmup_cycle in range(PIPELINE_DEPTH):
        # Queue expected outputs for NOP (no register change, sequential PC)
        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        if use_fp_monitor:
            state.fp_register_file_current_expected_queue.append(
                state.fp_register_file_current.copy()
            )
        expected_pc = (state.program_counter_current + 4) & MASK32
        state.program_counter_expected_values_queue.append(expected_pc)

        # Drive NOP
        dut_if.instruction = nop

        # Wait for clock edge
        await RisingEdge(dut_if.clock)
        state.increment_cycle_counter()
        state.increment_instret_counter()

        # Update state for next iteration
        state.update_program_counter(expected_pc)
        state.advance_register_state()

    return dut_if, state, mem_model


async def drain_pipeline(
    dut_if: DUTInterface, state: TestState, use_fp_monitor: bool = False
) -> None:
    """Drain pipeline with NOPs to let all results complete."""
    cocotb.log.info("=== Draining pipeline ===")
    nop = 0x00000013
    for i in range(PIPELINE_DEPTH + 2):
        # Wait for ready (skip FallingEdge on first iteration, like test_cpu.py pattern)
        if i != 0:
            await FallingEdge(dut_if.clock)
        wait_cycles = await dut_if.wait_ready()
        state.csr_cycle_counter += wait_cycles

        # Queue expected outputs
        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        if use_fp_monitor:
            state.fp_register_file_current_expected_queue.append(
                state.fp_register_file_current.copy()
            )
        expected_pc = (state.program_counter_current + 4) & MASK32
        state.program_counter_expected_values_queue.append(expected_pc)

        # Drive NOP
        dut_if.instruction = nop
        await RisingEdge(dut_if.clock)

        # Advance state
        state.increment_cycle_counter()
        state.increment_instret_counter()
        state.update_program_counter(expected_pc)
        state.advance_register_state()


@cocotb.test()
async def test_back_to_back_integer_div(dut: Any) -> None:
    """Test back-to-back integer DIV operations.

    This test verifies that two consecutive DIV instructions both correctly
    write their results to the register file, even though the second DIV
    causes a stall while the first is completing.

    Sequence:
    1. ADDI x1, x0, 100    # Set up dividend
    2. ADDI x2, x0, 10     # Set up divisor
    3. ADDI x3, x0, 7      # Set up second divisor
    4. DIV x4, x1, x2      # 100 / 10 = 10
    5. DIV x5, x1, x3      # 100 / 7 = 14
    6. Drain pipeline and verify
    """
    cocotb.log.info("=== Test: Back-to-back integer DIV ===")

    dut_if, state, _ = await setup_test(dut, use_fp_monitor=False)

    # Get encoders
    enc_addi, _ = R_ALU.get("addi") or (None, None)
    if enc_addi is None:
        from encoders.op_tables import I_ALU

        enc_addi, _ = I_ALU["addi"]

    enc_div, eval_div = R_ALU["div"]

    # Set up operands: x1=100, x2=10, x3=7
    cocotb.log.info("Setting up operands...")

    # ADDI x1, x0, 100 (first instruction after warmup)
    instr = enc_addi(1, 0, 100)
    await execute_instruction(
        dut_if, state, instr, 1, 100, "ADDI x1, x0, 100", first_after_warmup=True
    )

    # ADDI x2, x0, 10
    instr = enc_addi(2, 0, 10)
    await execute_instruction(dut_if, state, instr, 2, 10, "ADDI x2, x0, 10")

    # ADDI x3, x0, 7
    instr = enc_addi(3, 0, 7)
    await execute_instruction(dut_if, state, instr, 3, 7, "ADDI x3, x0, 7")

    # Back-to-back DIV operations
    cocotb.log.info("Executing back-to-back DIV operations...")

    # DIV x4, x1, x2: 100 / 10 = 10
    instr = enc_div(4, 1, 2)
    expected = eval_div(100, 10)
    await execute_instruction(
        dut_if, state, instr, 4, expected, "DIV x4, x1, x2 (100/10)"
    )

    # DIV x5, x1, x3: 100 / 7 = 14
    instr = enc_div(5, 1, 3)
    expected = eval_div(100, 7)
    await execute_instruction(
        dut_if, state, instr, 5, expected, "DIV x5, x1, x3 (100/7)"
    )

    # Drain pipeline
    await drain_pipeline(dut_if, state, use_fp_monitor=False)

    # Verify final register values by reading from hardware
    x4_hw = dut_if.read_register(4)
    x5_hw = dut_if.read_register(5)
    cocotb.log.info(f"Final x4 = {x4_hw} (expected 10)")
    cocotb.log.info(f"Final x5 = {x5_hw} (expected 14)")

    assert x4_hw == 10, f"x4 mismatch: got {x4_hw}, expected 10"
    assert x5_hw == 14, f"x5 mismatch: got {x5_hw}, expected 14"

    cocotb.log.info("=== PASSED: Back-to-back integer DIV ===")


@cocotb.test()
async def test_back_to_back_fp_div(dut: Any) -> None:
    """Test back-to-back FP FDIV.S operations.

    This test verifies that two consecutive FDIV.S instructions both correctly
    write their results to the FP register file.

    Sequence:
    1. Set up FP operands in f1, f2, f3 via integer path
    2. FDIV.S f4, f1, f2
    3. FDIV.S f5, f1, f3
    4. Drain pipeline and verify
    """
    cocotb.log.info("=== Test: Back-to-back FP FDIV.S ===")

    dut_if, state, _ = await setup_test(dut, use_fp_monitor=True)

    from encoders.instruction_encode import enc_fmv_w_x, enc_fdiv_s, enc_lui
    from models.fp_model import fdiv_s, box32

    # Set up FP operands via FMV.W.X (move integer bits to FP register)
    # f1 = 10.0 (0x41200000)
    # f2 = 2.0 (0x40000000)
    # f3 = 5.0 (0x40A00000)

    cocotb.log.info("Setting up FP operands via FMV.W.X...")

    # x1 = 0x41200000 (10.0f) using LUI (first instruction after warmup)
    instr = enc_lui(1, 0x41200)  # LUI x1, 0x41200
    await execute_instruction(
        dut_if,
        state,
        instr,
        1,
        0x41200000,
        "LUI x1, 0x41200",
        use_fp_monitor=True,
        first_after_warmup=True,
    )

    # x2 = 0x40000000 (2.0f)
    instr = enc_lui(2, 0x40000)
    await execute_instruction(
        dut_if, state, instr, 2, 0x40000000, "LUI x2, 0x40000", use_fp_monitor=True
    )

    # x3 = 0x40A00000 (5.0f)
    instr = enc_lui(3, 0x40A00)
    await execute_instruction(
        dut_if, state, instr, 3, 0x40A00000, "LUI x3, 0x40A00", use_fp_monitor=True
    )

    # Move to FP registers: FMV.W.X fd, rs1
    # f1 = x1 (10.0)
    instr = enc_fmv_w_x(1, 1)
    await execute_instruction(
        dut_if,
        state,
        instr,
        1,
        box32(0x41200000),
        "FMV.W.X f1, x1",
        is_fp=True,
        use_fp_monitor=True,
    )

    # f2 = x2 (2.0)
    instr = enc_fmv_w_x(2, 2)
    await execute_instruction(
        dut_if,
        state,
        instr,
        2,
        box32(0x40000000),
        "FMV.W.X f2, x2",
        is_fp=True,
        use_fp_monitor=True,
    )

    # f3 = x3 (5.0)
    instr = enc_fmv_w_x(3, 3)
    await execute_instruction(
        dut_if,
        state,
        instr,
        3,
        box32(0x40A00000),
        "FMV.W.X f3, x3",
        is_fp=True,
        use_fp_monitor=True,
    )

    # Back-to-back FDIV.S operations
    cocotb.log.info("Executing back-to-back FDIV.S operations...")

    # FDIV.S f4, f1, f2: 10.0 / 2.0 = 5.0 (0x40A00000)
    instr = enc_fdiv_s(4, 1, 2)
    expected = box32(fdiv_s(0x41200000, 0x40000000))  # 10.0 / 2.0
    cocotb.log.info(f"FDIV.S f4, f1, f2: expected result = 0x{expected:016X}")
    await execute_instruction(
        dut_if,
        state,
        instr,
        4,
        expected,
        "FDIV.S f4, f1, f2 (10.0/2.0)",
        is_fp=True,
        use_fp_monitor=True,
    )

    # FDIV.S f5, f1, f3: 10.0 / 5.0 = 2.0 (0x40000000)
    instr = enc_fdiv_s(5, 1, 3)
    expected = box32(fdiv_s(0x41200000, 0x40A00000))  # 10.0 / 5.0
    cocotb.log.info(f"FDIV.S f5, f1, f3: expected result = 0x{expected:016X}")
    await execute_instruction(
        dut_if,
        state,
        instr,
        5,
        expected,
        "FDIV.S f5, f1, f3 (10.0/5.0)",
        is_fp=True,
        use_fp_monitor=True,
    )

    # Drain pipeline
    await drain_pipeline(dut_if, state, use_fp_monitor=True)

    cocotb.log.info("=== Test complete, monitors will verify results ===")


@cocotb.test()
async def test_fld_faddd_load_use_hazard(dut: Any) -> None:
    """Test FLD followed immediately by FADD.D.

    This targets the load-use hazard path for multi-cycle FP ops to ensure
    the loaded double is stable before operand capture.
    """
    cocotb.log.info("=== Test: FLD -> FADD.D load-use hazard ===")

    dut_if, state, mem_model = await setup_test(dut, use_fp_monitor=True)

    # Get encoders
    enc_addi, _ = R_ALU.get("addi") or (None, None)
    if enc_addi is None:
        from encoders.op_tables import I_ALU

        enc_addi, _ = I_ALU["addi"]

    from encoders.instruction_encode import enc_fld, enc_fadd_d
    from models.fp_model import fadd_d

    # Initialize memory with a known double at an 8-byte aligned address
    base_addr = 0x100
    load_bits = 0x3FF0000000000000  # 1.0 double
    low_word = load_bits & MASK32
    high_word = (load_bits >> 32) & MASK32
    word_index = base_addr >> 2

    dut.data_memory_for_simulation.memory[word_index].value = low_word
    dut.data_memory_for_simulation.memory[word_index + 1].value = high_word
    mem_model.write_word(base_addr, low_word)
    mem_model.write_word(base_addr + 4, high_word)

    cocotb.log.info(
        f"Memory init @0x{base_addr:08X}: low=0x{low_word:08X}, high=0x{high_word:08X}"
    )

    # x1 = base_addr (first instruction after warmup)
    instr = enc_addi(1, 0, base_addr)
    await execute_instruction(
        dut_if,
        state,
        instr,
        1,
        base_addr,
        f"ADDI x1, x0, 0x{base_addr:X}",
        use_fp_monitor=True,
        first_after_warmup=True,
    )

    # FLD f1, 0(x1)
    instr = enc_fld(1, 1, 0)
    await execute_instruction(
        dut_if,
        state,
        instr,
        1,
        load_bits,
        "FLD f1, 0(x1)",
        is_fp=True,
        use_fp_monitor=True,
    )

    # FADD.D f2, f1, f1 (1.0 + 1.0 = 2.0)
    expected = fadd_d(load_bits, load_bits)
    instr = enc_fadd_d(2, 1, 1)
    await execute_instruction(
        dut_if,
        state,
        instr,
        2,
        expected,
        "FADD.D f2, f1, f1",
        is_fp=True,
        use_fp_monitor=True,
    )

    # Drain pipeline
    await drain_pipeline(dut_if, state, use_fp_monitor=True)

    cocotb.log.info("=== PASSED: FLD -> FADD.D load-use hazard ===")


@cocotb.test()
async def test_lh_bext_load_use_hazard(dut: Any) -> None:
    """Test LH followed immediately by BEXT after an unrelated stall.

    This reproduces a stale load-hit forwarding corner case:
    1. Warm cache with LH from address A (value has bit1=1)
    2. Trigger a multi-cycle DIV stall
    3. Execute LH from uncached address B (value bit1=0)
    4. Immediately consume with BEXT x3, x27, x15

    Expected result is x3=0. Any stale forwarding from address A produces x3=1.
    """
    cocotb.log.info("=== Test: LH -> BEXT integer load-use hazard ===")

    dut_if, state, mem_model = await setup_test(dut, use_fp_monitor=False)

    from encoders.op_tables import I_ALU, LOADS

    enc_addi, _ = I_ALU["addi"]
    enc_lh, _ = LOADS["lh"]
    enc_bext, eval_bext = R_ALU["bext"]
    enc_div, eval_div = R_ALU["div"]

    # Address A (cache warmup, bit1=1) and address B (expected miss, bit1=0)
    addr_a = 0x120
    addr_b = 0x220
    value_a = 0x00000002
    value_b = 0x00000000
    bit_index = 1

    dut.data_memory_for_simulation.memory[addr_a >> 2].value = value_a
    dut.data_memory_for_simulation.memory[addr_b >> 2].value = value_b
    mem_model.write_word(addr_a, value_a)
    mem_model.write_word(addr_b, value_b)

    cocotb.log.info(
        f"Memory init: A=0x{addr_a:08X}->0x{value_a:08X}, "
        f"B=0x{addr_b:08X}->0x{value_b:08X}"
    )

    # Setup integer operands/registers.
    await execute_instruction(
        dut_if,
        state,
        enc_addi(10, 0, addr_a),
        10,
        addr_a,
        f"ADDI x10, x0, 0x{addr_a:X}",
        first_after_warmup=True,
    )
    await execute_instruction(
        dut_if,
        state,
        enc_addi(11, 0, addr_b),
        11,
        addr_b,
        f"ADDI x11, x0, 0x{addr_b:X}",
    )
    await execute_instruction(
        dut_if, state, enc_addi(15, 0, bit_index), 15, bit_index, "ADDI x15, x0, 1"
    )
    await execute_instruction(
        dut_if, state, enc_addi(7, 0, 100), 7, 100, "ADDI x7, x0, 100"
    )
    await execute_instruction(dut_if, state, enc_addi(8, 0, 3), 8, 3, "ADDI x8, x0, 3")

    # Warm cache entry for address A (first load may miss and fill).
    await execute_instruction(
        dut_if, state, enc_lh(5, 10, 0), 5, 0x00000002, "LH x5, 0(x10)"
    )
    # Second load from same address should be served via cache-hit path.
    await execute_instruction(
        dut_if, state, enc_lh(6, 10, 0), 6, 0x00000002, "LH x6, 0(x10)"
    )

    # Insert unrelated multi-cycle stall to stress stale forwarding state.
    div_expected = eval_div(100, 3)
    await execute_instruction(
        dut_if, state, enc_div(9, 7, 8), 9, div_expected, "DIV x9, x7, x8 (100/3)"
    )

    # Critical pair: load from B then immediate dependent BEXT.
    await execute_instruction(
        dut_if, state, enc_lh(27, 11, 0), 27, 0x00000000, "LH x27, 0(x11)"
    )
    bext_expected = eval_bext(0x00000000, bit_index)
    await execute_instruction(
        dut_if,
        state,
        enc_bext(3, 27, 15),
        3,
        bext_expected,
        "BEXT x3, x27, x15",
    )

    await drain_pipeline(dut_if, state, use_fp_monitor=False)

    x27_hw = dut_if.read_register(27)
    x3_hw = dut_if.read_register(3)
    cocotb.log.info(f"Final x27 = 0x{x27_hw:08X} (expected 0x00000000)")
    cocotb.log.info(f"Final x3  = 0x{x3_hw:08X} (expected 0x{bext_expected:08X})")

    assert (
        x27_hw == 0x00000000
    ), f"x27 mismatch: got 0x{x27_hw:08X}, expected 0x00000000"
    assert (
        x3_hw == bext_expected
    ), f"x3 mismatch: got 0x{x3_hw:08X}, expected 0x{bext_expected:08X}"

    cocotb.log.info("=== PASSED: LH -> BEXT integer load-use hazard ===")

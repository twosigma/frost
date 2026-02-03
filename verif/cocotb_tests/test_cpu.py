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

"""Random instruction verification test for RISC-V CPU core.

Test RISC-V CPU - Random Regression
===================================

This module implements the main random instruction testbench for the Frost
RISC-V CPU. It uses constrained-random testing to verify CPU correctness
by generating thousands of random valid instructions and comparing hardware
execution against a software reference model.

Test Approach:
    1. Generate random RISC-V instruction
    2. Encode to binary and drive into DUT
    3. Model expected behavior in software
    4. Hardware monitors verify outputs match expectations
    5. Repeat thousands of times with coverage tracking

What This Tests:
    - All supported RISC-V instructions (100+ types across I, M, A, B-subset, Zicsr)
    - Register file reads and writes
    - Program counter updates (sequential, branch, jump)
    - Memory loads and stores (byte, halfword, word)
    - Pipeline behavior (stalls, flushes, hazards)
    - Branch prediction and misprediction handling

What This Does NOT Test:
    - Instruction fetch (instructions driven directly from testbench)
    - Instruction cache behavior
    - Data cache behavior
    - Multi-cycle memory latency
    (See test_real_program.py for full system integration tests)

Related Test Modules:
    - test_directed_atomics.py: LR.W/SC.W atomic instruction tests
    - test_directed_traps.py: ECALL, EBREAK, MRET, interrupt handling
    - test_compressed.py: C extension compressed instruction tests
    - test_real_program.py: Full system integration tests

Entry Points:
    - test_random_riscv_regression(): Default random test (16,000 instructions)
    - test_random_riscv_regression_force_one_address(): Single address stress test
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from monitors.monitors import regfile_monitor, pc_monitor, fp_regfile_monitor
from config import (
    MASK32,
    PIPELINE_DEPTH,
)
from encoders.op_tables import (
    R_ALU,
    LOADS,
    STORES,
    BRANCHES,
    JUMPS,
    FP_LOADS,
    FP_STORES,
)
from cocotb_tests.instruction_generator import ALL_FP_OPS
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface, TestStatistics
from cocotb_tests.instruction_generator import InstructionGenerator
from cocotb_tests.cpu_model import CPUModel
from cocotb_tests.test_state import TestState
from cocotb_tests.test_common import (
    TestConfig,
    handle_branch_flush,
    flush_remaining_outputs,
)
from utils.instruction_logger import InstructionLogger


# ============================================================================
# Main Random Regression Test
# ============================================================================


async def test_random_riscv_regression_main(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Main coroutine for random RISC-V regression: ALU + branches + jumps + loads/stores.

    Test Flow:
        1. Initialize DUT and start clock
        2. Start concurrent monitors for register file, PC, and memory
        3. Reset DUT
        4. Execute main loop:
            a. Generate random instruction (or NOP if branch flush)
            b. Encode instruction to binary
            c. Model expected behavior in software
            d. Drive instruction into DUT
            e. Queue expected results for monitors to check
            f. Update software state for next cycle
        5. Flush remaining pipeline outputs
        6. Verify coverage

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
    """
    if config is None:
        config = TestConfig()
    # ========================================================================
    # Initialization Phase
    # ========================================================================

    # Create interfaces and statistics tracker
    dut_if = DUTInterface(dut)
    stats = TestStatistics()
    operation = "addi"
    state = TestState()

    # Initialize DUT signals
    # IMPORTANT: Drive a 32-bit NOP (addi x0,x0,0) instead of 0 during initialization.
    # With C extension, 0 looks like a compressed instruction (bits [1:0] = 00).
    nop_32bit = 0x00000013  # addi x0, x0, 0
    dut_if.instruction = nop_32bit

    # Start free-running clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Reset DUT first (before initializing registers to avoid reset clearing them)
    # Returns cycle count for CSR counter synchronization
    # Note: RTL cycle counter is held at 0 during reset, so subtract reset cycles
    reset_cycle_count = await dut_if.reset_dut(config.reset_cycles)
    state.csr_cycle_counter = reset_cycle_count - config.reset_cycles

    # Initialize register file AFTER reset
    state.register_file_current = dut_if.initialize_registers()

    # Start concurrent monitors (run in background, checking outputs as they arrive)
    cocotb.start_soon(regfile_monitor(dut, state.register_file_current_expected_queue))
    cocotb.start_soon(pc_monitor(dut, state.program_counter_expected_values_queue))

    # Initialize memory model and start memory interface monitor
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file state for first instruction.
    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup: Fill pipeline with NOPs to synchronize expected value queues
    # ========================================================================
    # With 6-stage pipeline, we need to queue expected values for the first
    # PIPELINE_DEPTH cycles before o_vld starts firing. Drive NOPs to ensure
    # predictable initial state.
    cocotb.log.info(f"=== Warming up pipeline ({PIPELINE_DEPTH} NOPs) ===")
    nop_32bit = 0x00000013  # addi x0, x0, 0
    for warmup_cycle in range(PIPELINE_DEPTH):
        # Queue expected outputs for NOP (no register change, sequential PC)
        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        expected_pc = (state.program_counter_current + 4) & MASK32
        state.program_counter_expected_values_queue.append(expected_pc)

        # Drive NOP
        dut_if.instruction = nop_32bit

        # Wait for clock edge
        await RisingEdge(dut_if.clock)
        state.increment_cycle_counter()
        state.increment_instret_counter()

        # Update PC for next iteration
        state.update_program_counter(expected_pc)
        state.advance_register_state()

        cocotb.log.info(
            f"Warmup NOP {warmup_cycle}: pc_cur={state.program_counter_current}"
        )

    # ========================================================================
    # Main Test Loop - Random Instruction Generation and Verification
    # ========================================================================

    for cycle in range(config.num_loops):
        stats.cycles_executed += 1

        # Wait for DUT to be ready (not stalled, not in reset)
        if cycle != 0:
            await FallingEdge(dut_if.clock)
        wait_cycles = await dut_if.wait_ready()
        state.csr_cycle_counter += wait_cycles  # Track cycles spent waiting for stalls

        # ====================================================================
        # Step 1: Generate Instruction
        # ====================================================================
        # After a taken branch/jump, flush pipeline with NOP to model speculative
        # execution behavior. Otherwise, generate a new random instruction.
        # All control flow (JAL, JALR, branches) resolved in EX stage, need 3 flush cycles.
        if state.is_in_flush:
            operation, rd, rs1, rs2, imm = handle_branch_flush(state, operation)
            offset = None
            if config.use_structured_logging:
                InstructionLogger.log_branch_flush(cycle, state.program_counter_current)
        else:
            # Generate random instruction with optional memory address constraints
            mem_constraint = (
                config.memory_init_size
                if config.constrain_addresses_to_memory
                else None
            )
            instr_params = InstructionGenerator.generate_random_instruction(
                state.register_file_previous, config.force_one_address, mem_constraint
            )
            operation = instr_params.operation
            rd = instr_params.destination_register
            rs1 = instr_params.source_register_1
            rs2 = instr_params.source_register_2
            imm = instr_params.immediate
            offset = instr_params.branch_offset

        # Extract CSR address for CSR instructions (None during branch flushes)
        csr_address = None
        if not state.is_in_flush:
            csr_address = instr_params.csr_address

        # Record instruction execution for coverage tracking
        stats.record_instruction(
            operation, state.branch_taken_current if operation in BRANCHES else None
        )

        # ====================================================================
        # Step 2: Encode Instruction to Binary
        # ====================================================================
        instr = InstructionGenerator.encode_instruction(
            operation, rd, rs1, rs2, imm, offset, csr_address
        )

        # ====================================================================
        # Step 3: Model Expected Behavior in Software
        # ====================================================================
        # Compute what the hardware SHOULD produce for this instruction
        # Note: is_fp_dest is ignored here since this test only generates integer instructions
        rd_to_update, rd_wb_value, expected_pc, _ = (
            CPUModel.model_instruction_execution(
                state, mem_model, operation, rd, rs1, rs2, imm, offset, csr_address
            )
        )

        # For store instructions, model the expected memory write
        CPUModel.model_memory_write(state, mem_model, operation, rs1, rs2, imm)

        # ====================================================================
        # Step 4: Update Software State
        # ====================================================================
        # Update register file model if instruction writes to a register
        if rd_to_update:
            state.register_file_current[rd_to_update] = rd_wb_value & MASK32

        # Queue expected results for monitors to verify when they emerge from pipeline
        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        state.program_counter_expected_values_queue.append(expected_pc)

        # ====================================================================
        # Step 5: Drive Instruction into DUT
        # ====================================================================
        dut_if.instruction = instr

        # Log instruction execution (optional structured format for debugging)
        if config.use_structured_logging:
            addr = (state.register_file_previous[rs1] + imm) & MASK32
            InstructionLogger.log_instruction_execution(
                cycle=cycle,
                operation=operation,
                pc_current=state.program_counter_current,
                pc_expected=expected_pc,
                destination_register=rd_to_update,
                writeback_value=rd_wb_value,
                source_register_1=rs1,
                source_register_2=rs2,
                immediate=imm if operation not in (R_ALU | BRANCHES | JUMPS) else None,
                address=addr if operation in (LOADS | STORES) else None,
                branch_taken=state.branch_taken_current
                if operation in BRANCHES
                else None,
            )
        else:
            # Standard logging format
            cocotb.log.info(
                f"cycle {cycle} instr {operation}, pc_cur {state.program_counter_current}, "
                f"expected_pc {expected_pc}, "
                f"rs1 {rs1}, rs2 {rs2}, "
                f"wb_value {rd_wb_value} to rd {rd_to_update}"
            )
            addr = (state.register_file_previous[rs1] + imm) & MASK32
            if operation in LOADS:
                cocotb.log.info(f"cycle {cycle} loading from address {addr}")
            if operation in STORES:
                cocotb.log.info(f"cycle {cycle} storing to address {addr}")

        # Wait for rising edge (instruction sampled by DUT on this edge)
        await RisingEdge(dut_if.clock)

        # Track CSR counters: cycle increments every clock, instret when instruction retires
        state.increment_cycle_counter()
        state.increment_instret_counter()  # Each iteration = one instruction retired

        # ====================================================================
        # Step 6: Advance Software State for Next Cycle
        # ====================================================================
        # Move PC through pipeline stages
        # All control flow (JAL, JALR, branches) now resolved in EX stage with same timing
        pc_update = CPUModel.calculate_internal_pc_update(
            state,
            operation,
            state.register_file_previous[rs1],
            imm,
            offset,
            expected_pc,
        )
        state.update_program_counter(pc_update)

        # Advance register file state through pipeline stages
        state.advance_register_state()

    # ========================================================================
    # Test Completion Phase
    # ========================================================================

    # Stop driving new instructions
    await FallingEdge(dut_if.clock)
    wait_cycles = await dut_if.wait_ready()
    state.csr_cycle_counter += wait_cycles  # Track cycles spent waiting for stalls
    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Report test statistics
    if config.use_structured_logging:
        InstructionLogger.log_coverage_summary(
            stats.coverage, config.min_coverage_count
        )
    cocotb.log.info(stats.report())

    # Verify coverage: all instructions must execute > min_coverage_count times
    coverage_issues = stats.check_coverage(config.min_coverage_count)
    if coverage_issues:
        error_message = "Coverage verification failed:\n" + "\n".join(
            f"  - {issue}" for issue in coverage_issues
        )
        cocotb.log.error(error_message)
        raise AssertionError(error_message)

    # Wait for pipeline to drain and all monitors to verify remaining outputs
    await flush_remaining_outputs(dut, state, dut_if)


@cocotb.test()
async def test_random_riscv_regression(dut: Any) -> None:
    """Random RISC-V regression: ALU + branches + jumps + loads/stores."""
    await test_random_riscv_regression_main(dut=dut)


@cocotb.test()
async def test_random_riscv_regression_force_one_address(dut: Any) -> None:
    """Random RISC-V regression but forcing one address to stress hazards and cache."""
    config = TestConfig(force_one_address=True)
    await test_random_riscv_regression_main(dut=dut, config=config)


# ============================================================================
# Random Regression with F Extension (Floating-Point)
# ============================================================================


async def test_random_riscv_regression_with_fp_main(
    dut: Any,
    config: TestConfig | None = None,
    fp_probability: float = 0.3,
    fp_operations: list[str] | None = None,
) -> None:
    """Main coroutine for random RISC-V regression including F extension instructions.

    This test extends the base regression to include single-precision floating-point
    instructions. It randomly mixes integer and FP instructions according to fp_probability.

    Test Flow:
        Same as test_random_riscv_regression_main, but with:
        - FP register file state tracking
        - FP register file monitor
        - Mixed integer/FP instruction generation
        - Proper routing of results to INT or FP register files

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
        fp_probability: Probability (0.0-1.0) of generating FP instruction vs integer
        fp_operations: Optional list of FP operations to choose from
    """
    if config is None:
        config = TestConfig()

    # ========================================================================
    # Initialization Phase
    # ========================================================================

    dut_if = DUTInterface(dut)
    stats = TestStatistics()
    operation = "addi"
    state = TestState()

    # Initialize DUT signals
    nop_32bit = 0x00000013  # addi x0, x0, 0
    dut_if.instruction = nop_32bit

    # Start free-running clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Reset DUT first (before initializing registers to avoid reset clearing them)
    reset_cycle_count = await dut_if.reset_dut(config.reset_cycles)
    state.csr_cycle_counter = reset_cycle_count - config.reset_cycles

    # Initialize register files AFTER reset
    state.register_file_current = dut_if.initialize_registers()
    # Initialize FP register file to 0 (ensures test isolation between tests)
    state.fp_register_file_current = dut_if.initialize_fp_registers()

    # Start concurrent monitors (run in background, checking outputs as they arrive)
    cocotb.start_soon(regfile_monitor(dut, state.register_file_current_expected_queue))
    cocotb.start_soon(
        fp_regfile_monitor(dut, state.fp_register_file_current_expected_queue)
    )
    cocotb.start_soon(pc_monitor(dut, state.program_counter_expected_values_queue))

    # Initialize memory model and start memory interface monitor
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file state for first instruction
    state.register_file_previous = state.register_file_current.copy()
    state.fp_register_file_previous = state.fp_register_file_current.copy()

    # ========================================================================
    # Warmup: Fill pipeline with NOPs
    # ========================================================================
    cocotb.log.info(f"=== Warming up pipeline ({PIPELINE_DEPTH} NOPs) ===")
    for warmup_cycle in range(PIPELINE_DEPTH):
        state.queue_expected_outputs((state.program_counter_current + 4) & MASK32)
        expected_pc = (state.program_counter_current + 4) & MASK32

        dut_if.instruction = nop_32bit

        await RisingEdge(dut_if.clock)
        state.increment_cycle_counter()
        state.increment_instret_counter()

        state.update_program_counter(expected_pc)
        state.advance_register_state()

        cocotb.log.info(
            f"Warmup NOP {warmup_cycle}: pc_cur={state.program_counter_current}"
        )

    # ========================================================================
    # Main Test Loop - Random Integer + FP Instruction Generation
    # ========================================================================

    for cycle in range(config.num_loops):
        stats.cycles_executed += 1

        if cycle != 0:
            await FallingEdge(dut_if.clock)
        wait_cycles = await dut_if.wait_ready()
        state.csr_cycle_counter += wait_cycles

        # ====================================================================
        # Step 1: Generate Instruction (Integer or FP)
        # ====================================================================
        if state.is_in_flush:
            operation, rd, rs1, rs2, imm = handle_branch_flush(state, operation)
            offset = None
            rs3 = 0
            if config.use_structured_logging:
                InstructionLogger.log_branch_flush(cycle, state.program_counter_current)
        else:
            mem_constraint = (
                config.memory_init_size
                if config.constrain_addresses_to_memory
                else None
            )
            # Use the FP-aware generator
            instr_params = InstructionGenerator.generate_random_instruction_with_fp(
                state.register_file_previous,
                state.fp_register_file_previous,
                config.force_one_address,
                mem_constraint,
                fp_probability,
                fp_operations,
            )
            operation = instr_params.operation
            rd = instr_params.destination_register
            rs1 = instr_params.source_register_1
            rs2 = instr_params.source_register_2
            rs3 = instr_params.source_register_3
            imm = instr_params.immediate
            offset = instr_params.branch_offset

        # Extract CSR address for CSR instructions
        csr_address = None
        if not state.is_in_flush:
            csr_address = instr_params.csr_address

        # Record instruction execution for coverage
        stats.record_instruction(
            operation, state.branch_taken_current if operation in BRANCHES else None
        )

        # ====================================================================
        # Step 2: Encode Instruction to Binary
        # ====================================================================
        instr = InstructionGenerator.encode_instruction(
            operation, rd, rs1, rs2, imm, offset, csr_address, rs3
        )

        # ====================================================================
        # Step 3: Model Expected Behavior in Software
        # ====================================================================
        rd_to_update, rd_wb_value, expected_pc, is_fp_dest = (
            CPUModel.model_instruction_execution(
                state, mem_model, operation, rd, rs1, rs2, imm, offset, csr_address, rs3
            )
        )

        # For store instructions (int or FP), model the expected memory write
        CPUModel.model_memory_write(state, mem_model, operation, rs1, rs2, imm)

        # ====================================================================
        # Step 4: Update Software State
        # ====================================================================
        # Update the correct register file based on instruction type
        if rd_to_update is not None:
            if is_fp_dest:
                state.update_fp_register(rd_to_update, rd_wb_value)
            else:
                state.update_register(rd_to_update, rd_wb_value)

        # Queue expected results for monitors
        state.queue_expected_outputs(expected_pc)

        # ====================================================================
        # Step 5: Drive Instruction into DUT
        # ====================================================================
        dut_if.instruction = instr

        # Logging
        if not config.use_structured_logging:
            op_type = "FP" if operation in ALL_FP_OPS else "INT"
            dest_type = "fp" if is_fp_dest else "x"
            cocotb.log.info(
                f"cycle {cycle} [{op_type}] {operation}, pc_cur {state.program_counter_current}, "
                f"expected_pc {expected_pc}, "
                f"rs1 {rs1}, rs2 {rs2}, "
                f"wb_value 0x{rd_wb_value:08X} to {dest_type}{rd_to_update}"
            )
            if operation in (LOADS | FP_LOADS):
                addr = (state.register_file_previous[rs1] + imm) & MASK32
                cocotb.log.info(f"cycle {cycle} loading from address 0x{addr:08X}")
            if operation in (STORES | FP_STORES):
                addr = (state.register_file_previous[rs1] + imm) & MASK32
                cocotb.log.info(f"cycle {cycle} storing to address 0x{addr:08X}")

        await RisingEdge(dut_if.clock)

        state.increment_cycle_counter()
        state.increment_instret_counter()

        # ====================================================================
        # Step 6: Advance Software State for Next Cycle
        # ====================================================================
        pc_update = CPUModel.calculate_internal_pc_update(
            state,
            operation,
            state.register_file_previous[rs1],
            imm,
            offset,
            expected_pc,
        )
        state.update_program_counter(pc_update)
        state.advance_register_state()

    # ========================================================================
    # Test Completion Phase
    # ========================================================================

    await FallingEdge(dut_if.clock)
    wait_cycles = await dut_if.wait_ready()
    state.csr_cycle_counter += wait_cycles
    dut_if.instruction = 0x00000013  # 32-bit NOP

    # Report statistics
    cocotb.log.info(stats.report())

    # Coverage check - FP instructions are also tracked
    coverage_issues = stats.check_coverage(config.min_coverage_count)
    if coverage_issues:
        error_message = "Coverage verification failed:\n" + "\n".join(
            f"  - {issue}" for issue in coverage_issues
        )
        cocotb.log.error(error_message)
        raise AssertionError(error_message)

    # Flush remaining outputs
    await flush_remaining_outputs(dut, state, dut_if)


@cocotb.test()
async def test_random_riscv_regression_with_fp(dut: Any) -> None:
    """Random RISC-V regression including F extension floating-point instructions.

    This test mixes integer and single-precision FP instructions randomly,
    verifying both the integer and FP register files against the software model.
    FP instructions are generated with ~30% probability.
    """
    config = TestConfig(num_loops=24000)
    await test_random_riscv_regression_with_fp_main(
        dut=dut,
        config=config,
        fp_probability=0.3,
        fp_operations=InstructionGenerator.get_fp_operations_single(),
    )


@cocotb.test()
async def test_random_riscv_regression_fp_heavy(dut: Any) -> None:
    """Random RISC-V regression with heavy FP instruction emphasis (70% FP).

    This test stresses the FPU by generating mostly FP instructions,
    exercising FP arithmetic, comparisons, conversions, and FP load/store.
    Uses lower min_coverage_count (40) since integer instructions only get 30% of iterations.
    """
    config = TestConfig(num_loops=24000, min_coverage_count=40)
    await test_random_riscv_regression_with_fp_main(
        dut=dut,
        config=config,
        fp_probability=0.7,
        fp_operations=InstructionGenerator.get_fp_operations_single(),
    )


@cocotb.test()
async def test_random_riscv_regression_with_fp_double(dut: Any) -> None:
    """Random RISC-V regression including D extension floating-point instructions.

    This test mixes integer and double-precision FP instructions randomly,
    verifying both the integer and FP register files against the software model.
    FP instructions are generated with ~30% probability.
    """
    config = TestConfig(num_loops=24000)
    await test_random_riscv_regression_with_fp_main(
        dut=dut,
        config=config,
        fp_probability=0.3,
        fp_operations=InstructionGenerator.get_fp_operations_double(),
    )


@cocotb.test()
async def test_random_riscv_regression_fp_double_heavy(dut: Any) -> None:
    """Random RISC-V regression with heavy D extension FP emphasis (70% FP).

    This test stresses the FPU by generating mostly double-precision FP instructions,
    exercising FP arithmetic, comparisons, conversions, and FP load/store.
    Uses lower min_coverage_count (40) since integer instructions only get 30% of iterations.
    """
    config = TestConfig(num_loops=24000, min_coverage_count=40)
    await test_random_riscv_regression_with_fp_main(
        dut=dut,
        config=config,
        fp_probability=0.7,
        fp_operations=InstructionGenerator.get_fp_operations_double(),
    )


@cocotb.test()
async def test_random_riscv_regression_with_fp_mixed(dut: Any) -> None:
    """Random RISC-V regression with mixed single- and double-precision FP ops.

    This test mixes integer instructions with both .s and .d FP operations to
    stress NaN-boxing, FP/FP conversion, and mixed-width hazards.
    """
    config = TestConfig(num_loops=24000)
    await test_random_riscv_regression_with_fp_main(
        dut=dut,
        config=config,
        fp_probability=0.3,
        fp_operations=InstructionGenerator.get_fp_operations(),
    )


@cocotb.test()
async def test_random_riscv_regression_fp_mixed_heavy(dut: Any) -> None:
    """Random RISC-V regression with heavy mixed FP ops (70% FP).

    Uses lower min_coverage_count (40) since integer instructions only get 30% of iterations.
    """
    config = TestConfig(num_loops=24000, min_coverage_count=40)
    await test_random_riscv_regression_with_fp_main(
        dut=dut,
        config=config,
        fp_probability=0.7,
        fp_operations=InstructionGenerator.get_fp_operations(),
    )

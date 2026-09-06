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

"""Constrained-random instruction testbench for the Frost CPU.

Each iteration generates a random RISC-V instruction, models its effect in
software, and drives the encoded instruction into the DUT. Background monitors
compare the DUT outputs against the modelled values as they emerge from the
pipeline. A run covers thousands of instructions and ends by checking
per-instruction coverage.

Covered:
    - All supported RISC-V instructions (100+ types across I, M, A, B-subset, Zicsr)
    - Register file reads and writes
    - Program counter updates (sequential, branch, jump)
    - Memory loads and stores (byte, halfword, word)
    - Pipeline behavior (stalls, flushes, hazards)
    - Branch prediction and misprediction handling

Not covered:
    - Instruction fetch (instructions driven directly from testbench)
    - Instruction cache behavior
    - Data cache behavior
    - Multi-cycle memory latency
    (See test_real_program.py for system integration tests.)

Related Test Modules:
    - test_directed_atomics.py: LR.W/SC.W atomic instruction tests
    - test_directed_traps.py: ECALL, EBREAK, MRET, interrupt handling
    - test_compressed.py: C extension compressed instruction tests
    - test_real_program.py: Full system integration tests

Entry Points:
    - test_random_riscv_regression(): Default random test (16,000 instructions)
    - test_random_riscv_regression_force_one_address(): Single address stress test
    - Six FP variants (see "Floating-Point Test Wrappers" below): mixed
      integer/floating-point runs covering the F and D extensions
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from monitors.monitors import regfile_monitor, pc_monitor, fp_regfile_monitor
from config import (
    MASK32,
    NOP_INSTRUCTION,
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
from cocotb_tests.instruction_generator import (
    ALL_FP_OPS,
    assert_random_memory_access_in_ram,
)
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface, TestStatistics
from cocotb_tests.instruction_generator import InstructionGenerator
from cocotb_tests.cpu_model import CPUModel
from cocotb_tests.test_state import TestState
from cocotb_tests.test_common import (
    TestConfig,
    handle_branch_flush,
    flush_remaining_outputs,
    warmup_pipeline,
)
from utils.instruction_logger import InstructionLogger


# ============================================================================
# Unified Random Regression Test
# ============================================================================


async def run_random_regression(
    dut: Any,
    config: TestConfig | None = None,
    enable_fp: bool = False,
    fp_probability: float = 0.3,
    fp_operations: list[str] | None = None,
) -> None:
    """Run random RISC-V regression testing.

    ``enable_fp`` selects between integer-only and mixed integer/FP
    generation. After reset, monitors for the register files, the PC, and the
    memory interface run in the background. Each loop iteration generates one
    instruction (a NOP while the model is flushing after a taken branch),
    models its effect, queues the expected results for the monitors, and
    drives the encoded instruction into the DUT. The run ends by checking
    per-instruction coverage, then draining the pipeline so the monitors see
    the last outputs.

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
        enable_fp: If True, enable FP register file init, FP monitor, and
            mixed integer/FP instruction generation.
        fp_probability: Probability (0.0-1.0) of generating FP instruction vs integer.
            Only used when enable_fp=True.
        fp_operations: Optional list of FP operations to choose from.
            Only used when enable_fp=True.
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

    # Drive a 32-bit NOP (addi x0,x0,0) rather than 0 during initialization.
    # With the C extension, 0 looks like a compressed instruction (bits [1:0] = 00).
    dut_if.instruction = NOP_INSTRUCTION

    Clock(dut_if.clock, config.clock_period_ns, unit="ns").start()

    # Reset before initializing the register files, or reset would clear them.
    # reset_dut returns a cycle count for CSR counter synchronization. The RTL
    # cycle counter is held at 0 during reset, so subtract the reset cycles.
    reset_cycle_count = await dut_if.reset_dut(config.reset_cycles)
    state.csr_cycle_counter = reset_cycle_count - config.reset_cycles

    state.register_file_current = dut_if.initialize_registers()
    if enable_fp:
        state.fp_register_file_current = dut_if.initialize_fp_registers()

    # The monitors run in the background, checking outputs as they arrive.
    cocotb.start_soon(regfile_monitor(dut, state.register_file_current_expected_queue))
    if enable_fp:
        cocotb.start_soon(
            fp_regfile_monitor(dut, state.fp_register_file_current_expected_queue)
        )
    cocotb.start_soon(pc_monitor(dut, state.program_counter_expected_values_queue))

    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file state for first instruction
    state.register_file_previous = state.register_file_current.copy()
    if enable_fp:
        state.fp_register_file_previous = state.fp_register_file_current.copy()

    # ========================================================================
    # Warmup: Fill pipeline with NOPs to synchronize expected value queues
    # ========================================================================
    await warmup_pipeline(dut_if, state, enable_fp=enable_fp)

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
        # After a taken branch or jump the model feeds NOPs, standing in for
        # the instructions the CPU fetched speculatively and discarded. All
        # control flow (JAL, JALR, branches) resolves in EX, so the flush
        # lasts 3 cycles.
        if state.is_in_flush:
            operation, rd, rs1, rs2, imm = handle_branch_flush(state, operation)
            offset = None
            rs3 = 0
            if config.use_structured_logging:
                InstructionLogger.log_branch_flush(cycle, state.program_counter_current)
        else:
            # Generate random instruction with optional memory address constraints
            mem_constraint = (
                config.memory_init_size
                if config.constrain_addresses_to_memory
                else None
            )
            if enable_fp:
                instr_params = InstructionGenerator.generate_random_instruction_with_fp(
                    state.register_file_previous,
                    state.fp_register_file_previous,
                    config.force_one_address,
                    mem_constraint,
                    fp_probability,
                    fp_operations,
                )
            else:
                instr_params = InstructionGenerator.generate_random_instruction(
                    state.register_file_previous,
                    config.force_one_address,
                    mem_constraint,
                )
            operation = instr_params.operation
            rd = instr_params.destination_register
            rs1 = instr_params.source_register_1
            rs2 = instr_params.source_register_2
            rs3 = instr_params.source_register_3
            imm = instr_params.immediate
            offset = instr_params.branch_offset

        # Extract CSR address for CSR instructions (None during branch flushes)
        csr_address = None
        if not state.is_in_flush:
            csr_address = instr_params.csr_address
            try:
                assert_random_memory_access_in_ram(
                    operation,
                    state.register_file_previous[rs1],
                    imm,
                )
            except AssertionError as exc:
                raise AssertionError(
                    "Random regression generated reserved-region memory access "
                    f"at cycle {cycle}: {exc}"
                ) from exc

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
        # Pick the register file the instruction writes.
        if rd_to_update is not None:
            if is_fp_dest:
                state.update_fp_register(rd_to_update, rd_wb_value)
            else:
                state.update_register(rd_to_update, rd_wb_value)

        # Queue expected results for monitors to verify when they emerge from pipeline
        state.queue_expected_outputs(expected_pc, include_fp=enable_fp)

        # ====================================================================
        # Step 5: Drive Instruction into DUT
        # ====================================================================
        dut_if.instruction = instr

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
                address=addr
                if operation in (LOADS | STORES | FP_LOADS | FP_STORES)
                else None,
                branch_taken=state.branch_taken_current
                if operation in BRANCHES
                else None,
            )
        else:
            if enable_fp:
                op_type = "FP" if operation in ALL_FP_OPS else "INT"
                dest_type = "fp" if is_fp_dest else "x"
                cocotb.log.info(
                    f"cycle {cycle} [{op_type}] {operation}, pc_cur {state.program_counter_current}, "
                    f"expected_pc {expected_pc}, "
                    f"rs1 {rs1}, rs2 {rs2}, "
                    f"wb_value 0x{rd_wb_value:08X} to {dest_type}{rd_to_update}"
                )
            else:
                cocotb.log.info(
                    f"cycle {cycle} instr {operation}, pc_cur {state.program_counter_current}, "
                    f"expected_pc {expected_pc}, "
                    f"rs1 {rs1}, rs2 {rs2}, "
                    f"wb_value {rd_wb_value} to rd {rd_to_update}"
                )
            if operation in (LOADS | FP_LOADS):
                addr = (state.register_file_previous[rs1] + imm) & MASK32
                cocotb.log.info(f"cycle {cycle} loading from address 0x{addr:08X}")
            if operation in (STORES | FP_STORES):
                addr = (state.register_file_previous[rs1] + imm) & MASK32
                cocotb.log.info(f"cycle {cycle} storing to address 0x{addr:08X}")

        # Wait for rising edge (instruction sampled by DUT on this edge)
        await RisingEdge(dut_if.clock)

        # Track the CSR counters: cycle increments every clock, instret when
        # an instruction retires.
        state.increment_cycle_counter()
        state.increment_instret_counter()

        # ====================================================================
        # Step 6: Advance Software State for Next Cycle
        # ====================================================================
        # Move the model PC through the pipeline stages. All control flow
        # (JAL, JALR, branches) resolves in EX with the same timing.
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
    state.csr_cycle_counter += wait_cycles
    dut_if.instruction = NOP_INSTRUCTION

    if config.use_structured_logging:
        InstructionLogger.log_coverage_summary(
            stats.coverage, config.min_coverage_count
        )
    cocotb.log.info(stats.report())

    # Every instruction type must execute more than min_coverage_count times.
    coverage_issues = stats.check_coverage(config.min_coverage_count)
    if coverage_issues:
        error_message = "Coverage verification failed:\n" + "\n".join(
            f"  - {issue}" for issue in coverage_issues
        )
        cocotb.log.error(error_message)
        raise AssertionError(error_message)

    # Wait for pipeline to drain and all monitors to verify remaining outputs
    await flush_remaining_outputs(dut, state, dut_if)


# ============================================================================
# Integer-Only Test Wrappers
# ============================================================================


@cocotb.test()
async def test_random_riscv_regression(dut: Any) -> None:
    """Random RISC-V regression: ALU + branches + jumps + loads/stores."""
    await run_random_regression(dut=dut)


@cocotb.test()
async def test_random_riscv_regression_force_one_address(dut: Any) -> None:
    """Random RISC-V regression but forcing one address to stress hazards and cache."""
    config = TestConfig(force_one_address=True)
    await run_random_regression(dut=dut, config=config)


# ============================================================================
# Floating-Point Test Wrappers
# ============================================================================


@cocotb.test()
async def test_random_riscv_regression_with_fp(dut: Any) -> None:
    """Random RISC-V regression including F extension floating-point instructions.

    Mixes integer and single-precision FP instructions, checking both the
    integer and the FP register file against the software model. FP
    instructions are generated with ~30% probability.
    """
    config = TestConfig(num_loops=24000)
    await run_random_regression(
        dut=dut,
        config=config,
        enable_fp=True,
        fp_probability=0.3,
        fp_operations=InstructionGenerator.get_fp_operations_single(),
    )


@cocotb.test()
async def test_random_riscv_regression_fp_heavy(dut: Any) -> None:
    """Random RISC-V regression with heavy FP instruction emphasis (70% FP).

    Stresses the FPU with mostly FP instructions, exercising FP arithmetic,
    comparisons, conversions, and FP load/store. min_coverage_count drops to
    30 because integer instructions get only 30% of the iterations.
    """
    config = TestConfig(num_loops=24000, min_coverage_count=30)
    await run_random_regression(
        dut=dut,
        config=config,
        enable_fp=True,
        fp_probability=0.7,
        fp_operations=InstructionGenerator.get_fp_operations_single(),
    )


@cocotb.test()
async def test_random_riscv_regression_with_fp_double(dut: Any) -> None:
    """Random RISC-V regression including D extension floating-point instructions.

    Mixes integer and double-precision FP instructions, checking both the
    integer and the FP register file against the software model. FP
    instructions are generated with ~30% probability.
    """
    config = TestConfig(num_loops=24000)
    await run_random_regression(
        dut=dut,
        config=config,
        enable_fp=True,
        fp_probability=0.3,
        fp_operations=InstructionGenerator.get_fp_operations_double(),
    )


@cocotb.test()
async def test_random_riscv_regression_fp_double_heavy(dut: Any) -> None:
    """Random RISC-V regression with heavy D extension FP emphasis (70% FP).

    Stresses the FPU with mostly double-precision FP instructions, exercising
    FP arithmetic, comparisons, conversions, and FP load/store.
    min_coverage_count drops to 30 because integer instructions get only 30%
    of the iterations.
    """
    config = TestConfig(num_loops=24000, min_coverage_count=30)
    await run_random_regression(
        dut=dut,
        config=config,
        enable_fp=True,
        fp_probability=0.7,
        fp_operations=InstructionGenerator.get_fp_operations_double(),
    )


@cocotb.test()
async def test_random_riscv_regression_with_fp_mixed(dut: Any) -> None:
    """Random RISC-V regression with mixed single- and double-precision FP ops.

    Mixes integer instructions with both .s and .d FP operations to stress
    NaN-boxing, FP/FP conversion, and mixed-width hazards.
    """
    config = TestConfig(num_loops=24000)
    await run_random_regression(
        dut=dut,
        config=config,
        enable_fp=True,
        fp_probability=0.3,
        fp_operations=InstructionGenerator.get_fp_operations(),
    )


@cocotb.test()
async def test_random_riscv_regression_fp_mixed_heavy(dut: Any) -> None:
    """Random RISC-V regression with heavy mixed FP ops (70% FP).

    min_coverage_count drops to 30 because integer instructions get only 30%
    of the iterations.
    """
    config = TestConfig(num_loops=24000, min_coverage_count=30)
    await run_random_regression(
        dut=dut,
        config=config,
        enable_fp=True,
        fp_probability=0.7,
        fp_operations=InstructionGenerator.get_fp_operations(),
    )

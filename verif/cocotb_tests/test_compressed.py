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

"""Tests for RISC-V C extension compressed instructions.

Compressed Instruction Tests
============================

This module contains tests for the RISC-V C extension (compressed instructions).
Compressed instructions are 16-bit encodings that reduce code size by providing
shorter versions of common operations.

C Extension Overview:
    - 16-bit instructions aligned on 2-byte boundaries
    - Can be identified by bits [1:0] != 0b11
    - Most common instructions have compressed forms
    - Some instructions only operate on registers x8-x15 (s0-s7/a0-a7)

Compressed Instruction Categories:
    ┌─────────────────────────────────────────────────────────────────┐
    │ Register Operations (full register set x1-x31):                │
    │   C.LI   rd, imm    - Load immediate (rd = sign_extend(imm))   │
    │   C.ADDI rd, nzimm  - Add immediate (rd = rd + nzimm)          │
    │   C.MV   rd, rs2    - Move register (rd = rs2)                 │
    │   C.ADD  rd, rs2    - Add register (rd = rd + rs2)             │
    │   C.SLLI rd, shamt  - Shift left logical (rd = rd << shamt)    │
    │                                                                 │
    │ Register Operations (limited to x8-x15 only):                   │
    │   C.SUB  rd', rs2'  - Subtract (rd' = rd' - rs2')              │
    │   C.AND  rd', rs2'  - AND (rd' = rd' & rs2')                   │
    │   C.OR   rd', rs2'  - OR (rd' = rd' | rs2')                    │
    │   C.XOR  rd', rs2'  - XOR (rd' = rd' ^ rs2')                   │
    │   C.SRLI rd', shamt - Shift right logical                      │
    │   C.SRAI rd', shamt - Shift right arithmetic                   │
    │   C.ANDI rd', imm   - AND immediate                            │
    └─────────────────────────────────────────────────────────────────┘

    rd' and rs2' refer to the 3-bit compressed register encoding that
    maps to registers x8-x15 (add 8 to get the actual register number).

Test Strategy:
    Unlike the random regression tests, these are directed tests that:
    1. Execute each compressed instruction type
    2. Directly verify register values after execution
    3. Test edge cases (negative immediates, shifts, etc.)

Usage:
    make test TEST=test_compressed_instructions
    make test TEST=test_random_riscv_regression_with_compressed
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from config import MASK32, PIPELINE_DEPTH
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface
from cocotb_tests.test_common import TestConfig


async def run_compressed_instruction_test(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Test compressed (16-bit) instruction execution.

    This test verifies the C extension implementation by executing multiple
    compressed instructions and directly checking register values. Each test:
    1. Encodes a compressed instruction
    2. Packs it into a 32-bit word
    3. Drives it through the pipeline
    4. Verifies the expected register value

    Tests: C.LI, C.ADDI, C.MV, C.ADD, C.SUB, C.AND, C.OR, C.XOR, C.SLLI,
           C.SRLI, C.SRAI, C.ANDI

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses defaults.
    """
    if config is None:
        config = TestConfig(num_loops=500, min_coverage_count=5)

    from encoders.compressed_encode import (
        enc_c_li,
        enc_c_addi,
        enc_c_mv,
        enc_c_add,
        enc_c_sub,
        enc_c_and,
        enc_c_or,
        enc_c_xor,
        enc_c_slli,
        enc_c_srli,
        enc_c_srai,
        enc_c_andi,
        enc_c_nop,
    )

    dut_if = DUTInterface(dut)
    nop_32bit = 0x00000013  # addi x0, x0, 0
    c_nop = enc_c_nop()
    nop_packed = (c_nop << 16) | c_nop  # Compressed NOP in both halves
    pipeline_depth = PIPELINE_DEPTH

    # Initialize instruction signal before clock starts
    dut_if.instruction = nop_32bit

    # Start clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Reset the DUT
    await dut_if.reset_dut(config.reset_cycles)

    # Initialize memory model (required for pipeline operation)
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor([], [])  # Empty queues, not checking memory
    )

    # Reference to register file for reading values
    regfile_ram = dut_if.dut.device_under_test.regfile_inst.gen_read_port[
        0
    ].read_port_ram.ram

    def read_reg(reg: int) -> int:
        """Read a register value from the register file."""
        return int(regfile_ram[reg].value)

    async def flush_pipeline() -> None:
        """Flush the pipeline with compressed NOPs."""
        for _ in range(pipeline_depth * 2):
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

    async def execute_compressed_instr(instr_16bit: int) -> None:
        """Execute a compressed instruction and wait for it to complete.

        Handles PC alignment requirements for compressed instructions.
        After executing compressed instructions, PC may be at an odd half-word
        (PC[1]=1). This function waits for proper alignment before driving
        the next instruction.

        Args:
            instr_16bit: 16-bit compressed instruction encoding
        """
        # Ensure PC is word-aligned before presenting new instruction.
        # After executing compressed instructions, PC may be at an odd half-word (PC[1]=1).
        # When PC[1]=1 and prev_was_compressed_at_lo=1, the CPU uses instr_buffer
        # instead of i_instr, so we must wait until PC[1]=0.
        while True:
            pc_val = int(dut_if.dut.o_pc.value)
            if (pc_val & 0x2) == 0:  # PC[1] == 0, word-aligned
                break
            # Wait one more cycle to let CPU process hi half
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

        # Pack NOP in high half, instruction in low half.
        # With C extension, the CPU processes both halves of a word when PC advances
        # from lo to hi. Using NOP in high half ensures only the target instruction
        # has effect (NOP at hi does nothing).
        packed = (c_nop << 16) | instr_16bit
        await FallingEdge(dut_if.clock)
        dut_if.instruction = packed
        await RisingEdge(dut_if.clock)

        # Wait for pipeline to complete
        for _ in range(pipeline_depth + 1):
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

    def check_reg(reg: int, expected: int, desc: str) -> None:
        """Check that a register has the expected value.

        Args:
            reg: Register number to check
            expected: Expected value
            desc: Description for logging

        Raises:
            AssertionError: If register value doesn't match expected
        """
        actual = read_reg(reg) & MASK32
        expected = expected & MASK32
        if actual != expected:
            raise AssertionError(
                f"FAIL: {desc} - x{reg} = 0x{actual:08x}, expected 0x{expected:08x}"
            )
        cocotb.log.info(f"  PASS: {desc} (x{reg} = 0x{actual:08x})")

    # ========================================================================
    # Initial Pipeline Flush
    # ========================================================================
    cocotb.log.info("=== Flushing pipeline ===")
    await flush_pipeline()
    cocotb.log.info(f"Pipeline flushed, PC = {int(dut_if.dut.o_pc.value)}")

    # ========================================================================
    # Test 1: C.LI (Load Immediate)
    # ========================================================================
    cocotb.log.info("=== Test 1: C.LI ===")
    await execute_compressed_instr(enc_c_li(rd=10, imm=25))
    check_reg(10, 25, "c.li x10, 25")

    # Test with negative immediate
    await execute_compressed_instr(enc_c_li(rd=11, imm=-5))
    check_reg(11, -5, "c.li x11, -5")

    # ========================================================================
    # Test 2: C.ADDI (Add Immediate)
    # ========================================================================
    cocotb.log.info("=== Test 2: C.ADDI ===")
    # x10 = 25 from previous test, add 10 -> 35
    await execute_compressed_instr(enc_c_addi(rd=10, nzimm=10))
    check_reg(10, 35, "c.addi x10, 10 (25 + 10 = 35)")

    # Test with negative immediate
    await execute_compressed_instr(enc_c_addi(rd=10, nzimm=-3))
    check_reg(10, 32, "c.addi x10, -3 (35 - 3 = 32)")

    # ========================================================================
    # Test 3: C.MV (Move Register)
    # ========================================================================
    cocotb.log.info("=== Test 3: C.MV ===")
    # Set up x12 with a known value first
    await execute_compressed_instr(enc_c_li(rd=12, imm=17))
    await execute_compressed_instr(enc_c_mv(rd=13, rs2=12))
    check_reg(13, 17, "c.mv x13, x12 (copy 17)")

    # ========================================================================
    # Test 4: C.ADD (Add Registers)
    # ========================================================================
    cocotb.log.info("=== Test 4: C.ADD ===")
    # x10 = 32, x12 = 17, set x10 = x10 + x12 = 49
    await execute_compressed_instr(enc_c_add(rd=10, rs2=12))
    check_reg(10, 49, "c.add x10, x12 (32 + 17 = 49)")

    # ========================================================================
    # Test 5: C.SUB (Subtract Registers) - uses x8-x15 only
    # ========================================================================
    cocotb.log.info("=== Test 5: C.SUB ===")
    # Set up x8 = 100, x9 = 30
    await execute_compressed_instr(enc_c_li(rd=8, imm=31))  # Max positive imm is 31
    await execute_compressed_instr(enc_c_addi(rd=8, nzimm=31))  # 31 + 31 = 62
    await execute_compressed_instr(enc_c_addi(rd=8, nzimm=31))  # 62 + 31 = 93
    await execute_compressed_instr(enc_c_li(rd=9, imm=30))
    await execute_compressed_instr(enc_c_sub(rd_prime=8, rs2_prime=9))
    check_reg(8, 63, "c.sub x8, x9 (93 - 30 = 63)")

    # ========================================================================
    # Test 6: C.AND (AND Registers)
    # ========================================================================
    cocotb.log.info("=== Test 6: C.AND ===")
    await execute_compressed_instr(enc_c_li(rd=14, imm=0x1F))  # 0b11111
    await execute_compressed_instr(enc_c_li(rd=15, imm=0x0A))  # 0b01010
    await execute_compressed_instr(enc_c_and(rd_prime=14, rs2_prime=15))
    check_reg(14, 0x0A, "c.and x14, x15 (0x1F & 0x0A = 0x0A)")

    # ========================================================================
    # Test 7: C.OR (OR Registers)
    # ========================================================================
    cocotb.log.info("=== Test 7: C.OR ===")
    await execute_compressed_instr(enc_c_li(rd=14, imm=0x05))  # 0b00101
    await execute_compressed_instr(enc_c_li(rd=15, imm=0x0A))  # 0b01010
    await execute_compressed_instr(enc_c_or(rd_prime=14, rs2_prime=15))
    check_reg(14, 0x0F, "c.or x14, x15 (0x05 | 0x0A = 0x0F)")

    # ========================================================================
    # Test 8: C.XOR (XOR Registers)
    # ========================================================================
    cocotb.log.info("=== Test 8: C.XOR ===")
    await execute_compressed_instr(enc_c_li(rd=14, imm=0x0F))  # 0b01111
    await execute_compressed_instr(enc_c_li(rd=15, imm=0x03))  # 0b00011
    await execute_compressed_instr(enc_c_xor(rd_prime=14, rs2_prime=15))
    check_reg(14, 0x0C, "c.xor x14, x15 (0x0F ^ 0x03 = 0x0C)")

    # ========================================================================
    # Test 9: C.SLLI (Shift Left Logical Immediate)
    # ========================================================================
    cocotb.log.info("=== Test 9: C.SLLI ===")
    await execute_compressed_instr(enc_c_li(rd=10, imm=1))
    await execute_compressed_instr(enc_c_slli(rd=10, shamt=4))
    check_reg(10, 16, "c.slli x10, 4 (1 << 4 = 16)")

    # ========================================================================
    # Test 10: C.SRLI (Shift Right Logical Immediate) - uses x8-x15
    # ========================================================================
    cocotb.log.info("=== Test 10: C.SRLI ===")
    await execute_compressed_instr(enc_c_li(rd=8, imm=31))  # 31 (max single imm)
    await execute_compressed_instr(enc_c_addi(rd=8, nzimm=1))  # 32
    await execute_compressed_instr(enc_c_srli(rd_prime=8, shamt=2))
    check_reg(8, 8, "c.srli x8, 2 (32 >> 2 = 8)")

    # ========================================================================
    # Test 11: C.SRAI (Shift Right Arithmetic Immediate) - uses x8-x15
    # ========================================================================
    cocotb.log.info("=== Test 11: C.SRAI ===")
    await execute_compressed_instr(enc_c_li(rd=8, imm=-16))  # -16 (0xFFFFFFF0)
    await execute_compressed_instr(enc_c_srai(rd_prime=8, shamt=2))
    check_reg(8, -4, "c.srai x8, 2 (-16 >>> 2 = -4)")

    # ========================================================================
    # Test 12: C.ANDI (AND Immediate) - uses x8-x15
    # ========================================================================
    cocotb.log.info("=== Test 12: C.ANDI ===")
    await execute_compressed_instr(enc_c_li(rd=8, imm=0x1F))  # 0b11111
    await execute_compressed_instr(enc_c_andi(rd_prime=8, imm=0x07))  # 0b00111
    check_reg(8, 0x07, "c.andi x8, 7 (0x1F & 0x07 = 0x07)")

    cocotb.log.info("=== All compressed instruction tests passed! ===")


@cocotb.test()
async def test_compressed_instructions(dut: Any) -> None:
    """Test C extension compressed instruction execution."""
    await run_compressed_instruction_test(dut)


@cocotb.test()
async def test_random_riscv_regression_with_compressed(dut: Any) -> None:
    """Random RISC-V regression with C extension compressed instructions.

    This test exercises compressed (16-bit) instruction execution by running
    pairs of compressed ALU instructions. Unlike the main random test which
    uses 32-bit instructions with PC+4, this test uses 16-bit instructions
    with PC+2, properly handling instruction alignment.

    Tests: C.ADD, C.MV, C.AND, C.OR, C.XOR, C.SUB, C.ADDI, C.LI, C.SLLI,
           C.SRLI, C.SRAI, C.ANDI, C.LW, C.LWSP
    """
    # Use the dedicated compressed instruction test with more iterations
    config = TestConfig(num_loops=1000, min_coverage_count=10)
    await run_compressed_instruction_test(dut, config)


# =============================================================================
# Compressed Floating-Point Tests
# =============================================================================


async def run_compressed_fp_instruction_test(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Test compressed floating-point (16-bit) instruction execution.

    This test verifies the C extension FP implementation (C.FLW, C.FSW,
    C.FLWSP, C.FSWSP) by executing compressed FP load/store instructions
    and directly checking FP register and memory values.

    Tests: C.FLW, C.FSW, C.FLWSP, C.FSWSP

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses defaults.
    """
    if config is None:
        config = TestConfig(num_loops=500, min_coverage_count=5)

    from encoders.compressed_encode import (
        enc_c_li,
        enc_c_addi,
        enc_c_nop,
        enc_c_flw,
        enc_c_fsw,
        enc_c_flwsp,
        enc_c_fswsp,
    )
    from encoders.instruction_encode import (
        enc_fmv_w_x,
        enc_i,
    )

    def enc_lui(rd: int, imm_upper: int) -> int:
        """Encode LUI instruction: rd = imm << 12."""
        return (imm_upper << 12) | (rd << 7) | 0x37

    def enc_addi(rd: int, rs1: int, imm: int) -> int:
        """Encode ADDI instruction: rd = rs1 + imm."""
        return enc_i(imm & 0xFFF, rs1, 0x0, rd)

    dut_if = DUTInterface(dut)
    nop_32bit = 0x00000013  # addi x0, x0, 0
    c_nop = enc_c_nop()
    nop_packed = (c_nop << 16) | c_nop  # Compressed NOP in both halves
    pipeline_depth = PIPELINE_DEPTH

    # Initialize instruction signal before clock starts
    dut_if.instruction = nop_32bit

    # Start clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Reset the DUT
    await dut_if.reset_dut(config.reset_cycles)

    # Note: We don't need the MemoryModel driver/monitor since we verify store
    # correctness by loading values back (store-then-load pattern).

    # Reference to register files for reading values
    int_regfile_ram = dut_if.dut.device_under_test.regfile_inst.gen_read_port[
        0
    ].read_port_ram.ram
    fp_regfile_ram = dut_if.dut.device_under_test.fp_regfile_inst.gen_read_port[
        0
    ].read_port_ram.ram

    def read_int_reg(reg: int) -> int:
        """Read an integer register value from the register file."""
        return int(int_regfile_ram[reg].value)

    def read_fp_reg(reg: int) -> int:
        """Read an FP register value (as bits) from the FP register file."""
        return int(fp_regfile_ram[reg].value)

    async def flush_pipeline() -> None:
        """Flush the pipeline with compressed NOPs."""
        for _ in range(pipeline_depth * 2):
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

    async def execute_compressed_instr(instr_16bit: int) -> None:
        """Execute a compressed instruction and wait for it to complete."""
        # Ensure PC is word-aligned before presenting new instruction
        while True:
            pc_val = int(dut_if.dut.o_pc.value)
            if (pc_val & 0x2) == 0:  # PC[1] == 0, word-aligned
                break
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

        # Pack NOP in high half, instruction in low half
        packed = (c_nop << 16) | instr_16bit
        await FallingEdge(dut_if.clock)
        dut_if.instruction = packed
        await RisingEdge(dut_if.clock)

        # Wait for pipeline to complete
        for _ in range(pipeline_depth + 1):
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

    async def execute_32bit_instr(instr_32bit: int, extra_wait: int = 0) -> None:
        """Execute a 32-bit instruction and wait for it to complete.

        Args:
            instr_32bit: The 32-bit encoded instruction
            extra_wait: Additional cycles to wait (for FP operations)
        """
        # Ensure PC is word-aligned
        while True:
            pc_val = int(dut_if.dut.o_pc.value)
            if (pc_val & 0x2) == 0:
                break
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

        await FallingEdge(dut_if.clock)
        dut_if.instruction = instr_32bit
        await RisingEdge(dut_if.clock)

        # Wait for pipeline to complete (extra wait for FP operations)
        for _ in range(pipeline_depth + 1 + extra_wait):
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_32bit
            await RisingEdge(dut_if.clock)

    def check_int_reg(reg: int, expected: int, desc: str) -> None:
        """Check that an integer register has the expected value."""
        actual = read_int_reg(reg) & MASK32
        expected = expected & MASK32
        if actual != expected:
            raise AssertionError(
                f"FAIL: {desc} - x{reg} = 0x{actual:08x}, expected 0x{expected:08x}"
            )
        cocotb.log.info(f"  PASS: {desc} (x{reg} = 0x{actual:08x})")

    def check_fp_reg(reg: int, expected: int, desc: str) -> None:
        """Check that an FP register has the expected value (as bits)."""
        actual = read_fp_reg(reg) & MASK32
        expected = expected & MASK32
        if actual != expected:
            raise AssertionError(
                f"FAIL: {desc} - f{reg} = 0x{actual:08x}, expected 0x{expected:08x}"
            )
        cocotb.log.info(f"  PASS: {desc} (f{reg} = 0x{actual:08x})")

    # ========================================================================
    # Initial Pipeline Flush
    # ========================================================================
    cocotb.log.info("=== Flushing pipeline ===")
    await flush_pipeline()
    cocotb.log.info(f"Pipeline flushed, PC = {int(dut_if.dut.o_pc.value)}")

    # ========================================================================
    # Setup: Initialize base addresses and test values
    # ========================================================================
    cocotb.log.info("=== Setting up base addresses ===")

    # Set x8 to a valid memory base address (must be in initialized memory range)
    # Use address 0x100 as base (well within typical memory range)
    base_addr = 0x100
    await execute_compressed_instr(enc_c_li(rd=8, imm=0))  # x8 = 0
    await execute_compressed_instr(enc_c_addi(rd=8, nzimm=16))  # x8 = 16
    # Build up to 0x100 (256) by repeated additions
    for _ in range(15):
        await execute_compressed_instr(enc_c_addi(rd=8, nzimm=16))  # x8 += 16
    check_int_reg(8, base_addr, f"x8 = base address 0x{base_addr:x}")

    # Set SP (x2) to a valid stack address for C.FLWSP/C.FSWSP tests
    # Use address 0x200 as stack base
    stack_addr = 0x200
    await execute_compressed_instr(enc_c_li(rd=2, imm=0))  # sp = 0
    for _ in range(32):
        await execute_compressed_instr(enc_c_addi(rd=2, nzimm=16))  # sp += 16
    check_int_reg(2, stack_addr, f"sp = stack address 0x{stack_addr:x}")

    # ========================================================================
    # Test 1: C.FSW - Store FP value to memory
    # ========================================================================
    cocotb.log.info("=== Test 1: C.FSW (compressed FP store) ===")

    # Load test value into x10 using 32-bit LUI+ADDI
    # Value: 0x12345678
    test_fp_bits_1 = 0x12345678
    # LUI loads upper 20 bits: 0x12345 << 12 = 0x12345000
    # But ADDI sign-extends, so we need to compensate if lower bits have bit 11 set
    # 0x678 has bit 11 = 0, so no adjustment needed
    await execute_32bit_instr(enc_lui(rd=10, imm_upper=0x12345))  # x10 = 0x12345000
    await execute_32bit_instr(enc_addi(rd=10, rs1=10, imm=0x678))  # x10 = 0x12345678
    check_int_reg(10, test_fp_bits_1, f"x10 = test value 0x{test_fp_bits_1:08x}")

    # Move x10 to f9 using FMV.W.X (32-bit instruction)
    # FP operations need extra wait cycles for the pipelined FPU
    await execute_32bit_instr(enc_fmv_w_x(rd=9, rs1=10), extra_wait=10)
    check_fp_reg(9, test_fp_bits_1, f"f9 = 0x{test_fp_bits_1:08x} via FMV.W.X")

    # Now store f9 to memory at x8+0 using C.FSW
    # C.FSW rs1', rs2', uimm -> fsw rs2', uimm(rs1')
    await execute_compressed_instr(enc_c_fsw(rs1_prime=8, rs2_prime=9, uimm=0))
    cocotb.log.info(f"  Executed c.fsw f9, 0(x8) - stored 0x{test_fp_bits_1:08x}")

    # ========================================================================
    # Test 2: C.FLW - Load FP value from memory
    # ========================================================================
    cocotb.log.info("=== Test 2: C.FLW (compressed FP load) ===")

    # Load the value we just stored into f10 using C.FLW
    await execute_compressed_instr(enc_c_flw(rd_prime=10, rs1_prime=8, uimm=0))
    check_fp_reg(10, test_fp_bits_1, f"c.flw f10, 0(x8) loaded 0x{test_fp_bits_1:08x}")

    # ========================================================================
    # Test 3: C.FSWSP - Store FP value to stack
    # ========================================================================
    cocotb.log.info("=== Test 3: C.FSWSP (compressed FP store to stack) ===")

    # Load test value into x11 using 32-bit LUI+ADDI
    # Value: 0xDEADBEEF
    test_fp_bits_2 = 0xDEADBEEF
    # 0xEEF has bit 11 set (0x800), so add 1 to upper and use negative lower
    # 0xDEADB + 1 = 0xDEADC, lower = 0xEEF - 0x1000 = -0x111 = -273
    await execute_32bit_instr(enc_lui(rd=11, imm_upper=0xDEADC))  # x11 = 0xDEADC000
    await execute_32bit_instr(enc_addi(rd=11, rs1=11, imm=-273))  # x11 = 0xDEADBEEF
    check_int_reg(11, test_fp_bits_2, f"x11 = test value 0x{test_fp_bits_2:08x}")

    # Move x11 to f11
    await execute_32bit_instr(enc_fmv_w_x(rd=11, rs1=11), extra_wait=10)
    check_fp_reg(11, test_fp_bits_2, f"f11 = 0x{test_fp_bits_2:08x} via FMV.W.X")

    # Store f11 to stack at SP+4 using C.FSWSP
    await execute_compressed_instr(enc_c_fswsp(rs2=11, uimm=4))
    cocotb.log.info(f"  Executed c.fswsp f11, 4(sp) - stored 0x{test_fp_bits_2:08x}")

    # ========================================================================
    # Test 4: C.FLWSP - Load FP value from stack
    # ========================================================================
    cocotb.log.info("=== Test 4: C.FLWSP (compressed FP load from stack) ===")

    # Load the value we just stored into f12 using C.FLWSP
    await execute_compressed_instr(enc_c_flwsp(rd=12, uimm=4))
    check_fp_reg(
        12, test_fp_bits_2, f"c.flwsp f12, 4(sp) loaded 0x{test_fp_bits_2:08x}"
    )

    # ========================================================================
    # Test 5: C.FLW with non-zero offset
    # ========================================================================
    cocotb.log.info("=== Test 5: C.FLW/C.FSW with offset ===")

    # Load test value into x12 using 32-bit LUI+ADDI
    # Value: 0xCAFEBABE
    test_fp_bits_3 = 0xCAFEBABE
    # 0xABE has bit 11 set (0x800), so add 1 to upper and use negative lower
    # 0xCAFEB + 1 = 0xCAFEC, lower = 0xABE - 0x1000 = -0x542 = -1346
    await execute_32bit_instr(enc_lui(rd=12, imm_upper=0xCAFEC))  # x12 = 0xCAFEC000
    await execute_32bit_instr(enc_addi(rd=12, rs1=12, imm=-1346))  # x12 = 0xCAFEBABE
    check_int_reg(12, test_fp_bits_3, f"x12 = test value 0x{test_fp_bits_3:08x}")

    await execute_32bit_instr(enc_fmv_w_x(rd=13, rs1=12), extra_wait=10)
    check_fp_reg(13, test_fp_bits_3, f"f13 = 0x{test_fp_bits_3:08x}")

    # Store f13 to memory at x8+8
    await execute_compressed_instr(enc_c_fsw(rs1_prime=8, rs2_prime=13, uimm=8))
    cocotb.log.info("  Executed c.fsw f13, 8(x8)")

    # Load it back into f14
    await execute_compressed_instr(enc_c_flw(rd_prime=14, rs1_prime=8, uimm=8))
    check_fp_reg(14, test_fp_bits_3, f"c.flw f14, 8(x8) loaded 0x{test_fp_bits_3:08x}")

    # ========================================================================
    # Test 6: Verify values persist across different offsets
    # ========================================================================
    cocotb.log.info("=== Test 6: Verify memory persistence ===")

    # Re-load the first value (should still be at x8+0)
    await execute_compressed_instr(enc_c_flw(rd_prime=15, rs1_prime=8, uimm=0))
    check_fp_reg(15, test_fp_bits_1, f"c.flw f15, 0(x8) = 0x{test_fp_bits_1:08x}")

    # Re-load from stack (should still be at SP+4)
    await execute_compressed_instr(enc_c_flwsp(rd=8, uimm=4))
    check_fp_reg(8, test_fp_bits_2, f"c.flwsp f8, 4(sp) = 0x{test_fp_bits_2:08x}")

    cocotb.log.info("=== All compressed FP instruction tests passed! ===")


@cocotb.test()
async def test_compressed_fp_instructions(dut: Any) -> None:
    """Test C extension compressed floating-point instruction execution.

    This test verifies compressed FP load/store instructions (C.FLW, C.FSW,
    C.FLWSP, C.FSWSP) that move data between FP registers and memory.
    """
    await run_compressed_fp_instruction_test(dut)

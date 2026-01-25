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

"""Random RISC-V instruction generation for verification testing.

Instruction Generator
=====================

This module provides constraint-random instruction generation for RISC-V
verification. It generates valid instruction parameters and encodes them
into binary format for driving into the DUT.

Purpose:
    Generate random but valid RISC-V instructions for thorough testing
    of the CPU implementation. Each instruction must satisfy:
    - Valid register indices (0-31)
    - Proper immediate ranges (12-bit for most, 5-bit for shifts)
    - Alignment requirements (2-byte for halfword, 4-byte for word)
    - Even offsets for branches and jumps

Random Testing Benefits:
    - Exercises corner cases not covered by directed tests
    - Finds unexpected interactions between instructions
    - Achieves high coverage without manual test writing
    - Stress tests with unusual register/immediate combinations

Example Usage:
    >>> # Generate a random instruction
    >>> regfile = [random.randint(0, 0xFFFFFFFF) for _ in range(32)]
    >>> op, rd, rs1, rs2, imm, offset = InstructionGenerator.generate_random_instruction(regfile)
    >>>
    >>> # Encode to binary
    >>> instruction_bits = InstructionGenerator.encode_instruction(op, rd, rs1, rs2, imm, offset)
    >>> # Drive into DUT
    >>> dut.instruction = instruction_bits
"""

import random
from typing import NamedTuple
from config import (
    IMM_12BIT_MIN,
    IMM_12BIT_MAX,
    SHIFT_AMOUNT_MASK,
    HALFWORD_ALIGNMENT,
    WORD_ALIGNMENT,
    DOUBLEWORD_ALIGNMENT,
)
from encoders.op_tables import (
    R_ALU,
    I_ALU,
    I_UNARY,
    LOADS,
    STORES,
    BRANCHES,
    JUMPS,
    FENCES,
    CSRS,
    ZICNTR_CSRS,
    # A extension (atomics)
    AMO,
    AMO_LR_SC,
    # Machine-mode trap instructions (for directed tests only)
    TRAP_INSTRS,
    # C extension (compressed instructions)
    C_ALU_REG,
    C_ALU_FULL,
    C_ALU_IMM_LIMITED,
    C_ALU_IMM_FULL,
    C_LOADS_LIMITED,
    C_STORES_LIMITED,
    C_LOADS_STACK,
    C_STORES_STACK,
    C_BRANCHES,
    C_JUMPS,
    # F extension (floating-point)
    FP_ARITH_2OP,
    FP_ARITH_1OP,
    FP_FMA,
    FP_SGNJ,
    FP_MINMAX,
    FP_CMP,
    FP_CVT_F2I,
    FP_CVT_I2F,
    FP_CVT_F2F,
    FP_MV_F2I,
    FP_MV_I2F,
    FP_CLASS,
    FP_LOADS,
    FP_STORES,
)
from encoders.compressed_encode import enc_c_nop
from utils.memory_utils import generate_aligned_immediate


class InstructionParams(NamedTuple):
    """Parameters for a generated RISC-V instruction.

    This provides named access to instruction components, making code
    more readable than positional tuple unpacking.
    """

    operation: str
    """Instruction mnemonic (e.g., "add", "lw", "beq", "csrrs", "fadd.s")."""
    destination_register: int
    """Destination register index (rd, 0-31). For FP ops, may be FP register."""
    source_register_1: int
    """First source register index (rs1, 0-31). For FP ops, may be FP register."""
    source_register_2: int
    """Second source register index (rs2, 0-31). For FP ops, may be FP register."""
    immediate: int
    """Immediate value for I-type instructions."""
    branch_offset: int | None
    """Branch/jump offset for B-type and J-type (None for others)."""
    csr_address: int | None = None
    """CSR address for Zicsr instructions (None for others)."""
    source_register_3: int = 0
    """Third source register for FMA instructions (rs3, 0-31)."""


# Sets of all FP operations grouped by result destination type
FP_OPS_TO_FP_REG = set(
    list(FP_ARITH_2OP.keys())
    + list(FP_ARITH_1OP.keys())
    + list(FP_FMA.keys())
    + list(FP_SGNJ.keys())
    + list(FP_MINMAX.keys())
    + list(FP_CVT_I2F.keys())
    + list(FP_CVT_F2F.keys())
    + list(FP_MV_I2F.keys())
    + list(FP_LOADS.keys())
)
"""Operations that write results to FP register file."""

FP_OPS_TO_INT_REG = set(
    list(FP_CMP.keys())
    + list(FP_CVT_F2I.keys())
    + list(FP_MV_F2I.keys())
    + list(FP_CLASS.keys())
)
"""Operations that write results to integer register file."""

FP_OPS_NO_WRITE = set(FP_STORES.keys())
"""Operations that don't write any register (FP stores)."""

ALL_FP_OPS = FP_OPS_TO_FP_REG | FP_OPS_TO_INT_REG | FP_OPS_NO_WRITE
"""All floating-point operations."""


def _is_double_precision_fp_op(operation: str) -> bool:
    """Return True if operation uses double-precision encoding/data path."""
    if operation in ("fld", "fsd"):
        return True
    if ".d" in operation:
        return True
    if ".s" in operation:
        return False
    # Default to single-precision for legacy F ops without .s/.d suffix
    return False


def _is_single_precision_fp_op(operation: str) -> bool:
    """Return True if operation uses single-precision encoding/data path."""
    if operation in ("flw", "fsw"):
        return True
    if operation in ("fld", "fsd"):
        return False
    if ".d" in operation:
        return False
    if ".s" in operation:
        return True
    # Default to single-precision for legacy F ops without .s/.d suffix
    return True


class InstructionGenerator:
    """Generates random RISC-V instructions for testing.

    This class provides methods to generate constraint-random instruction
    parameters and encode them into binary format. The generation respects
    RISC-V ISA constraints like alignment requirements and immediate ranges.
    """

    @staticmethod
    def get_all_operations() -> list[str]:
        """Get list of all supported RISC-V integer operations.

        Returns:
            List of operation mnemonics (e.g., ['add', 'sub', 'lw', ...])

        Note:
            CSR instructions read Zicntr counters (cycle, time, instret) which
            are timing-dependent. The test framework tracks these counters in
            software to verify correct CSR read values.
        """
        return (
            list(R_ALU.keys())
            + list(I_ALU.keys())
            + list(I_UNARY.keys())
            + list(STORES.keys())
            + list(LOADS.keys())
            + list(BRANCHES.keys())
            + list(JUMPS.keys())
            + list(FENCES.keys())
            + list(CSRS.keys())
            + list(AMO.keys())
            # Note: LR.W/SC.W excluded from random tests - reservation tracking
            # is complex with random instruction sequences. Use directed tests.
        )

    @staticmethod
    def get_fp_operations() -> list[str]:
        """Get list of all supported floating-point operations (F + D).

        Returns:
            List of FP operation mnemonics (e.g., ['fadd.s', 'fmul.s', ...])

        Note:
            Sorted for deterministic ordering across runs (sets have
            non-deterministic iteration order without PYTHONHASHSEED).
        """
        return sorted(ALL_FP_OPS)

    @staticmethod
    def get_fp_operations_single() -> list[str]:
        """Get list of supported single-precision floating-point operations."""
        return sorted([op for op in ALL_FP_OPS if _is_single_precision_fp_op(op)])

    @staticmethod
    def get_fp_operations_double() -> list[str]:
        """Get list of supported double-precision floating-point operations."""
        return sorted([op for op in ALL_FP_OPS if _is_double_precision_fp_op(op)])

    @staticmethod
    def get_all_operations_with_fp() -> list[str]:
        """Get list of all supported RISC-V operations including FP.

        Returns:
            List of all operation mnemonics including both integer and FP ops.
        """
        return (
            InstructionGenerator.get_all_operations()
            + InstructionGenerator.get_fp_operations()
        )

    @staticmethod
    def generate_random_instruction(
        register_file_state: list[int],
        force_one_address: bool = False,
        constrain_to_memory_size: int | None = None,
    ) -> InstructionParams:
        """Generate random RISC-V instruction parameters.

        Generates a random instruction with properly constrained operands,
        immediates, and offsets according to RISC-V specifications.

        Args:
            register_file_state: Current register file values (32 entries).
                                Used for calculating effective addresses.
            force_one_address: If True, force address calculation to use only
                              register value (immediate=0, rs1=0). Useful for
                              stressing memory hazards.
            constrain_to_memory_size: If provided, constrains memory addresses
                                     to [0, memory_size) to exercise allocated
                                     memory rather than generating many
                                     out-of-range addresses.

        Returns:
            Tuple of (operation, destination_reg, source_reg_1, source_reg_2,
                     immediate, branch_offset)

        Examples:
            >>> regfile = [0] * 32
            >>> regfile[5] = 0x1000
            >>> op, rd, rs1, rs2, imm, offset = InstructionGenerator.generate_random_instruction(regfile)
            >>> op in InstructionGenerator.get_all_operations()
            True
        """
        available_operations = InstructionGenerator.get_all_operations()
        operation = random.choice(available_operations)

        # RISC-V register indices (rd = destination, rs1/rs2 = sources)
        destination_register = random.randint(
            1, 31
        )  # Never x0 (except stores/branches)
        source_register_1 = 0 if force_one_address else random.randint(0, 31)
        source_register_2 = random.randint(0, 31)

        # Immediate value generation - varies by instruction type
        if force_one_address:
            immediate_value = 0
        elif operation in (
            "slli",
            "srli",
            "srai",
            "bseti",
            "bclri",
            "binvi",
            "bexti",
            "rori",
        ):
            # Shift, Zbs bit-position, and Zbb rotate immediates use only 5 bits
            immediate_value = random.randint(0, SHIFT_AMOUNT_MASK)
        else:
            # Standard 12-bit signed immediate range
            immediate_value = random.randint(IMM_12BIT_MIN, IMM_12BIT_MAX)

        # Ensure proper alignment for halfword and word accesses
        # Optionally constrain to allocated memory space
        if operation in ("lh", "lhu", "sh"):
            # Halfword access requires 2-byte alignment
            immediate_value = generate_aligned_immediate(
                register_file_state[source_register_1],
                HALFWORD_ALIGNMENT,
                IMM_12BIT_MIN,
                IMM_12BIT_MAX,
                constrain_to_memory_size,
            )
        elif operation in ("lw", "sw", "lwu"):
            # Word access requires 4-byte alignment
            immediate_value = generate_aligned_immediate(
                register_file_state[source_register_1],
                WORD_ALIGNMENT,
                IMM_12BIT_MIN,
                IMM_12BIT_MAX,
                constrain_to_memory_size,
            )
        elif operation == "jalr":
            # JALR target = (rs1 + imm) & ~1. To keep PC word-aligned in 32-bit
            # tests, we need (rs1 + imm) & 0x2 == 0 (bit[1] of sum must be 0).
            # After &~1, the target will be word-aligned.
            rs1_val = register_file_state[source_register_1]
            # Adjust immediate to make (rs1 + imm) have bit[1] = 0
            # If rs1 has bit[1] = 1, we need imm to also have bit[1] = 1 (to carry out)
            # or adjust imm to compensate
            base_imm = random.randint(IMM_12BIT_MIN, IMM_12BIT_MAX)
            # Make sum have bit[1] = 0 by adjusting imm
            sum_bits = (rs1_val + base_imm) & 0x3
            if sum_bits == 2:
                immediate_value = base_imm + 2  # Will wrap and clear bit[1]
            elif sum_bits == 3:
                immediate_value = base_imm + 1  # 3+1=4, clears bits[1:0]
            else:
                immediate_value = base_imm  # Already OK (0 or 1)
            # Clamp to valid range
            if immediate_value > IMM_12BIT_MAX:
                immediate_value -= 4
            elif immediate_value < IMM_12BIT_MIN:
                immediate_value += 4
        elif operation in AMO or operation in AMO_LR_SC:
            # AMO operations use rs1 directly as address (no immediate offset)
            # but we need to ensure rs1 contains a word-aligned address
            # Set immediate to 0 (AMO doesn't use immediate) and rs1 will be used directly
            immediate_value = 0
            # Note: The test framework should ensure rs1 contains a valid aligned address

        # Generate branch/jump offsets
        # With C extension IF stage, PC can be at halfword boundaries. To keep
        # the 32-bit instruction test working (no compressed instructions),
        # we use offsets that are multiples of 4 to keep PC word-aligned.
        branch_offset = None
        if operation in BRANCHES:
            # Branch offsets are 13-bit signed, must be multiple of 4 for 32-bit tests
            branch_offset = random.randrange(-4096, 4096, 4) or 4
        elif operation == "jal":
            # JAL offsets are 21-bit signed, must be multiple of 4 for 32-bit tests
            branch_offset = random.randrange(-1048576, 1048576, 4)

        # Generate CSR instruction parameters
        csr_address = None
        if operation in CSRS:
            # Select a random Zicntr CSR to read
            csr_address = random.choice(ZICNTR_CSRS)
            # For pure reads (CSRR pseudo-instruction), use rs1=0 or zimm=0
            # This reads the CSR without modifying it
            source_register_1 = 0  # rs1=x0 means no write to CSR
            immediate_value = 0  # zimm=0 for immediate variants

        return InstructionParams(
            operation=operation,
            destination_register=destination_register,
            source_register_1=source_register_1,
            source_register_2=source_register_2,
            immediate=immediate_value,
            branch_offset=branch_offset,
            csr_address=csr_address,
        )

    @staticmethod
    def generate_random_fp_instruction(
        int_register_file_state: list[int],
        fp_register_file_state: list[int],
        constrain_to_memory_size: int | None = None,
        fp_operations: list[str] | None = None,
    ) -> InstructionParams:
        """Generate random F extension floating-point instruction parameters.

        Generates a random FP instruction with properly constrained operands.
        FP instructions use different register files depending on the operation:
        - FP arithmetic: reads FP regs, writes FP reg
        - FP compare: reads FP regs, writes INT reg (0 or 1)
        - FP convert F->I: reads FP reg, writes INT reg
        - FP convert I->F: reads INT reg, writes FP reg
        - FP move F->I: reads FP reg (bits), writes INT reg (bits)
        - FP move I->F: reads INT reg (bits), writes FP reg (bits)
        - FP load: reads INT reg (addr), writes FP reg
        - FP store: reads INT reg (addr) + FP reg (data), no write

        Args:
            int_register_file_state: Current integer register file values (32 entries)
            fp_register_file_state: Current FP register file values (32 entries)
            constrain_to_memory_size: If provided, constrains memory addresses
            fp_operations: Optional list of FP operations to choose from

        Returns:
            InstructionParams with FP instruction details
        """
        available_fp_ops = (
            fp_operations
            if fp_operations is not None
            else InstructionGenerator.get_fp_operations()
        )
        operation = random.choice(available_fp_ops)

        # Default values - will be overwritten based on instruction type
        destination_register = random.randint(0, 31)
        source_register_1 = random.randint(0, 31)
        source_register_2 = random.randint(0, 31)
        source_register_3 = random.randint(0, 31)
        immediate_value = 0

        # Handle different FP instruction types
        if operation in FP_LOADS:
            # FLW: rd=FP, rs1=INT (base address), imm=offset
            # Need word-aligned address
            alignment = DOUBLEWORD_ALIGNMENT if operation == "fld" else WORD_ALIGNMENT
            immediate_value = generate_aligned_immediate(
                int_register_file_state[source_register_1],
                alignment,
                IMM_12BIT_MIN,
                IMM_12BIT_MAX,
                constrain_to_memory_size,
            )
        elif operation in FP_STORES:
            # FSW: rs2=FP (data), rs1=INT (base address), imm=offset
            # Need word-aligned address
            alignment = DOUBLEWORD_ALIGNMENT if operation == "fsd" else WORD_ALIGNMENT
            immediate_value = generate_aligned_immediate(
                int_register_file_state[source_register_1],
                alignment,
                IMM_12BIT_MIN,
                IMM_12BIT_MAX,
                constrain_to_memory_size,
            )
        # Other FP ops don't use immediates

        return InstructionParams(
            operation=operation,
            destination_register=destination_register,
            source_register_1=source_register_1,
            source_register_2=source_register_2,
            immediate=immediate_value,
            branch_offset=None,
            csr_address=None,
            source_register_3=source_register_3,
        )

    @staticmethod
    def generate_random_instruction_with_fp(
        int_register_file_state: list[int],
        fp_register_file_state: list[int],
        force_one_address: bool = False,
        constrain_to_memory_size: int | None = None,
        fp_probability: float = 0.3,
        fp_operations: list[str] | None = None,
    ) -> InstructionParams:
        """Generate random instruction, potentially FP, with given probability.

        Args:
            int_register_file_state: Current integer register file values
            fp_register_file_state: Current FP register file values
            force_one_address: If True, force simple address calculation
            constrain_to_memory_size: Constrain memory addresses to this range
            fp_probability: Probability (0.0-1.0) of generating FP instruction
            fp_operations: Optional list of FP operations to choose from

        Returns:
            InstructionParams for either integer or FP instruction
        """
        if random.random() < fp_probability:
            return InstructionGenerator.generate_random_fp_instruction(
                int_register_file_state,
                fp_register_file_state,
                constrain_to_memory_size,
                fp_operations,
            )
        else:
            return InstructionGenerator.generate_random_instruction(
                int_register_file_state,
                force_one_address,
                constrain_to_memory_size,
            )

    @staticmethod
    def encode_instruction(
        operation: str,
        destination_register: int,
        source_register_1: int,
        source_register_2: int,
        immediate_value: int,
        branch_offset: int | None,
        csr_address: int | None = None,
        source_register_3: int = 0,
    ) -> int:
        """Encode RISC-V instruction into 32-bit binary format.

        Selects appropriate encoding function based on instruction type and format.

        Args:
            operation: Instruction mnemonic (e.g., "add", "lw", "beq", "csrrs", "fadd.s")
            destination_register: Destination register index (0-31)
            source_register_1: First source register index (0-31)
            source_register_2: Second source register index (0-31)
            immediate_value: Immediate value for I-type instructions
            branch_offset: Branch/jump offset (for B-type and J-type)
            csr_address: CSR address for Zicsr instructions (e.g., 0xC00 for cycle)
            source_register_3: Third source register for FMA instructions (0-31)

        Returns:
            32-bit encoded instruction

        Raises:
            RuntimeError: If operation is not recognized

        Examples:
            >>> instr = InstructionGenerator.encode_instruction("add", 1, 2, 3, 0, None)
            >>> isinstance(instr, int)
            True
        """
        if operation in R_ALU:
            # R-type format: register-register operations
            encoder_function, _ = R_ALU[operation]
            return encoder_function(
                destination_register, source_register_1, source_register_2
            )
        elif operation in I_ALU:
            # I-type format: immediate operations
            encoder_function, _ = I_ALU[operation]
            return encoder_function(
                destination_register, source_register_1, immediate_value
            )
        elif operation in I_UNARY:
            # I-type format: unary operations (Zbb clz, ctz, cpop, sext.b, sext.h, orc.b, rev8)
            encoder_function, _ = I_UNARY[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in LOADS:
            # I-type format: load operations
            encoder_function, _ = LOADS[operation]
            return encoder_function(
                destination_register, source_register_1, immediate_value
            )
        elif operation in STORES:
            # S-type format: store operations (no destination register)
            encoder_function = STORES[operation]
            return encoder_function(
                source_register_2, source_register_1, immediate_value
            )
        elif operation in BRANCHES:
            # B-type format: branch operations
            encoder_function = BRANCHES[operation]
            return encoder_function(source_register_2, source_register_1, branch_offset)
        elif operation in JUMPS:
            # J-type format: jump operations
            encoder_function = JUMPS[operation]
            return (
                encoder_function(destination_register, branch_offset)
                if operation == "jal"
                else encoder_function(
                    destination_register, source_register_1, immediate_value
                )
            )
        elif operation in FENCES:
            # Fence instructions take no operands (fixed encoding)
            encoder_function = FENCES[operation]
            return encoder_function()
        elif operation in CSRS:
            # CSR instructions: read/modify CSR registers
            # For Zicntr counters, we use pure reads (rs1=0 or zimm=0)
            encoder_function = CSRS[operation]
            assert csr_address is not None, "CSR address required for CSR instructions"
            if operation in ("csrrw", "csrrs", "csrrc"):
                # Register-based CSR instructions: csrXX rd, csr, rs1
                return encoder_function(
                    destination_register, csr_address, source_register_1
                )
            else:
                # Immediate-based CSR instructions: csrXXi rd, csr, zimm
                return encoder_function(
                    destination_register, csr_address, immediate_value
                )
        elif operation in AMO:
            # A extension: Atomic memory operations (amoswap.w, amoadd.w, etc.)
            # Format: AMO rd, rs2, (rs1) - atomically loads from rs1, computes, stores
            encoder_function, _ = AMO[operation]
            return encoder_function(
                destination_register, source_register_2, source_register_1
            )
        elif operation in AMO_LR_SC:
            # A extension: Load-reserved / Store-conditional
            encoder_function = AMO_LR_SC[operation]
            if operation == "lr.w":
                # LR.W rd, (rs1) - Load and set reservation
                return encoder_function(destination_register, source_register_1)
            else:
                # SC.W rd, rs2, (rs1) - Store conditional
                return encoder_function(
                    destination_register, source_register_2, source_register_1
                )
        elif operation in TRAP_INSTRS:
            # Machine-mode trap instructions (ECALL, EBREAK, MRET, WFI)
            # These take no operands - fixed encodings
            encoder_function = TRAP_INSTRS[operation]
            return encoder_function()
        # F extension (floating-point) instruction encoding
        elif operation in FP_ARITH_2OP:
            # Two-operand FP arithmetic (fadd.s, fsub.s, fmul.s, fdiv.s)
            encoder_function, _ = FP_ARITH_2OP[operation]
            return encoder_function(
                destination_register, source_register_1, source_register_2
            )
        elif operation in FP_ARITH_1OP:
            # Single-operand FP arithmetic (fsqrt.s)
            encoder_function, _ = FP_ARITH_1OP[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in FP_FMA:
            # Fused multiply-add (fmadd.s, fmsub.s, fnmadd.s, fnmsub.s)
            encoder_function, _ = FP_FMA[operation]
            return encoder_function(
                destination_register,
                source_register_1,
                source_register_2,
                source_register_3,
            )
        elif operation in FP_SGNJ:
            # Sign injection (fsgnj.s, fsgnjn.s, fsgnjx.s)
            encoder_function, _ = FP_SGNJ[operation]
            return encoder_function(
                destination_register, source_register_1, source_register_2
            )
        elif operation in FP_MINMAX:
            # Min/max (fmin.s, fmax.s)
            encoder_function, _ = FP_MINMAX[operation]
            return encoder_function(
                destination_register, source_register_1, source_register_2
            )
        elif operation in FP_CMP:
            # Comparison (feq.s, flt.s, fle.s) - result to integer register
            encoder_function, _ = FP_CMP[operation]
            return encoder_function(
                destination_register, source_register_1, source_register_2
            )
        elif operation in FP_CVT_F2I:
            # FP to integer conversion (fcvt.w.s, fcvt.wu.s)
            encoder_function, _ = FP_CVT_F2I[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in FP_CVT_I2F:
            # Integer to FP conversion (fcvt.s.w, fcvt.s.wu)
            encoder_function, _ = FP_CVT_I2F[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in FP_CVT_F2F:
            # FP to FP conversion (fcvt.s.d, fcvt.d.s)
            encoder_function, _ = FP_CVT_F2F[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in FP_MV_F2I:
            # FP bits to integer move (fmv.x.w)
            encoder_function, _ = FP_MV_F2I[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in FP_MV_I2F:
            # Integer bits to FP move (fmv.w.x)
            encoder_function, _ = FP_MV_I2F[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in FP_CLASS:
            # Classify (fclass.s)
            encoder_function, _ = FP_CLASS[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in FP_LOADS:
            # FP load (flw)
            encoder_function, _ = FP_LOADS[operation]
            return encoder_function(
                destination_register, source_register_1, immediate_value
            )
        elif operation in FP_STORES:
            # FP store (fsw)
            encoder_function = FP_STORES[operation]
            return encoder_function(
                source_register_2, source_register_1, immediate_value
            )
        else:
            raise RuntimeError(f"Unknown operation: {operation}")


class CompressedInstructionParams(NamedTuple):
    """Parameters for a generated compressed RISC-V instruction.

    Compressed instructions have more constraints than regular instructions:
    - Many operations only work with registers x8-x15
    - Immediate ranges are more limited
    - Some operations have fixed register usage (e.g., sp for stack ops)
    """

    operation: str
    """Compressed instruction mnemonic (e.g., "c.addi", "c.lw", "c.beqz")."""
    destination_register: int
    """Destination register index (may be constrained to x8-x15)."""
    source_register_1: int
    """First source register index."""
    source_register_2: int
    """Second source register (for register-register ops)."""
    immediate: int
    """Immediate value (range depends on instruction type)."""
    branch_offset: int | None
    """Branch/jump offset for C.BEQZ, C.BNEZ, C.J, C.JAL (None for others)."""
    is_16bit: bool = True
    """Always True for compressed instructions."""


class CompressedInstructionGenerator:
    """Generates random compressed RISC-V instructions for testing.

    Compressed instructions have various constraints:
    - Register constraints: Many ops only use x8-x15 (3-bit encoding)
    - Immediate constraints: Smaller ranges than 32-bit instructions
    - Alignment constraints: Stack offsets must be 4-byte aligned

    The generator respects these constraints when creating random instructions.
    """

    # Operations that use full register set (x1-x31)
    FULL_REG_OPS = (
        list(C_ALU_FULL.keys())
        + list(C_ALU_IMM_FULL.keys())
        + list(C_LOADS_STACK.keys())
    )

    # Operations that use limited register set (x8-x15)
    LIMITED_REG_OPS = (
        list(C_ALU_REG.keys())
        + list(C_ALU_IMM_LIMITED.keys())
        + list(C_LOADS_LIMITED.keys())
        + list(C_STORES_LIMITED.keys())
        + list(C_BRANCHES.keys())
    )

    @staticmethod
    def get_all_compressed_operations() -> list[str]:
        """Get list of all supported compressed operations.

        Returns:
            List of compressed operation mnemonics
        """
        ops: list[str] = []
        ops.extend(C_ALU_REG.keys())
        ops.extend(C_ALU_FULL.keys())
        ops.extend(C_ALU_IMM_LIMITED.keys())
        ops.extend(C_ALU_IMM_FULL.keys())
        ops.extend(C_LOADS_LIMITED.keys())
        ops.extend(C_LOADS_STACK.keys())
        # Note: C_STORES, C_BRANCHES, C_JUMPS excluded from random tests
        # because they have side effects that are harder to verify
        return ops

    @staticmethod
    def generate_random_compressed_instruction(
        register_file_state: list[int],
    ) -> CompressedInstructionParams:
        """Generate random compressed RISC-V instruction parameters.

        Args:
            register_file_state: Current register file values (32 entries)

        Returns:
            CompressedInstructionParams with instruction details
        """
        available_operations = (
            CompressedInstructionGenerator.get_all_compressed_operations()
        )
        operation = random.choice(available_operations)

        # Default values
        destination_register = 0
        source_register_1 = 0
        source_register_2 = 0
        immediate_value = 0
        branch_offset = None

        if operation in C_ALU_REG:
            # Register-register ops with limited registers (x8-x15)
            destination_register = random.randint(8, 15)
            source_register_2 = random.randint(8, 15)
            source_register_1 = destination_register  # rd = rd op rs2

        elif operation in C_ALU_FULL:
            # Register-register ops with full registers (x1-x31)
            destination_register = random.randint(1, 31)
            source_register_2 = random.randint(1, 31)
            if operation == "c.add":
                source_register_1 = destination_register  # rd = rd + rs2
            else:  # c.mv
                source_register_1 = 0  # rd = x0 + rs2

        elif operation in C_ALU_IMM_LIMITED:
            # Immediate ops with limited registers (x8-x15)
            destination_register = random.randint(8, 15)
            source_register_1 = destination_register  # rd = rd op imm
            if operation in ("c.srli", "c.srai"):
                immediate_value = random.randint(1, 31)  # shift amount
            else:  # c.andi
                immediate_value = random.randint(-32, 31)  # 6-bit signed

        elif operation in C_ALU_IMM_FULL:
            # Immediate ops with full registers
            destination_register = random.randint(1, 31)
            if operation == "c.li":
                source_register_1 = 0  # rd = x0 + imm
                immediate_value = random.randint(-32, 31)
            elif operation == "c.addi":
                source_register_1 = destination_register  # rd = rd + imm
                immediate_value = random.randint(-32, 31)
                if immediate_value == 0:
                    immediate_value = 1  # nzimm required
            elif operation == "c.slli":
                source_register_1 = destination_register
                immediate_value = random.randint(1, 31)  # shift amount

        elif operation in C_LOADS_LIMITED:
            # c.lw rd', offset(rs1')
            destination_register = random.randint(8, 15)
            source_register_1 = random.randint(8, 15)
            # Offset must be multiple of 4, range [0, 124]
            immediate_value = random.randrange(0, 128, 4)

        elif operation in C_LOADS_STACK:
            # c.lwsp rd, offset(sp)
            destination_register = random.randint(1, 31)
            source_register_1 = 2  # sp
            # Offset must be multiple of 4, range [0, 252]
            immediate_value = random.randrange(0, 256, 4)

        return CompressedInstructionParams(
            operation=operation,
            destination_register=destination_register,
            source_register_1=source_register_1,
            source_register_2=source_register_2,
            immediate=immediate_value,
            branch_offset=branch_offset,
        )

    @staticmethod
    def encode_compressed_instruction(
        operation: str,
        destination_register: int,
        source_register_1: int,
        source_register_2: int,
        immediate_value: int,
        branch_offset: int | None,
    ) -> int:
        """Encode compressed instruction into 16-bit binary format.

        Args:
            operation: Compressed instruction mnemonic
            destination_register: Destination register index
            source_register_1: First source register index
            source_register_2: Second source register index
            immediate_value: Immediate value
            branch_offset: Branch/jump offset

        Returns:
            16-bit encoded instruction

        Raises:
            RuntimeError: If operation is not recognized
        """
        if operation in C_ALU_REG:
            encoder_function, _ = C_ALU_REG[operation]
            return encoder_function(destination_register, source_register_2)

        elif operation in C_ALU_FULL:
            encoder_function, _ = C_ALU_FULL[operation]
            return encoder_function(destination_register, source_register_2)

        elif operation in C_ALU_IMM_LIMITED:
            encoder_function, _ = C_ALU_IMM_LIMITED[operation]
            return encoder_function(destination_register, immediate_value)

        elif operation in C_ALU_IMM_FULL:
            encoder_function, _ = C_ALU_IMM_FULL[operation]
            return encoder_function(destination_register, immediate_value)

        elif operation in C_LOADS_LIMITED:
            encoder_function, _ = C_LOADS_LIMITED[operation]
            return encoder_function(
                destination_register, source_register_1, immediate_value
            )

        elif operation in C_LOADS_STACK:
            encoder_function, _ = C_LOADS_STACK[operation]
            return encoder_function(destination_register, immediate_value)

        elif operation in C_STORES_LIMITED:
            encoder_function = C_STORES_LIMITED[operation]
            return encoder_function(
                source_register_1, source_register_2, immediate_value
            )

        elif operation in C_STORES_STACK:
            encoder_function = C_STORES_STACK[operation]
            return encoder_function(source_register_2, immediate_value)

        elif operation in C_BRANCHES:
            encoder_function = C_BRANCHES[operation]
            return encoder_function(source_register_1, branch_offset)

        elif operation in C_JUMPS:
            encoder_function = C_JUMPS[operation]
            if operation in ("c.j", "c.jal"):
                return encoder_function(branch_offset)
            else:  # c.jr, c.jalr
                return encoder_function(source_register_1)

        else:
            raise RuntimeError(f"Unknown compressed operation: {operation}")

    @staticmethod
    def pack_compressed_pair(instr1: int, instr2: int) -> int:
        """Pack two 16-bit compressed instructions into a 32-bit word.

        The first instruction goes in bits [15:0] (executed first when PC[1]=0).
        The second instruction goes in bits [31:16] (executed second when PC[1]=1).

        Args:
            instr1: First 16-bit instruction (lower half)
            instr2: Second 16-bit instruction (upper half)

        Returns:
            32-bit word with both instructions packed
        """
        return ((instr2 & 0xFFFF) << 16) | (instr1 & 0xFFFF)

    @staticmethod
    def pack_with_nop(instr: int, position: str = "lower") -> int:
        """Pack a 16-bit instruction with a C.NOP in a 32-bit word.

        Args:
            instr: 16-bit instruction to pack
            position: "lower" for bits [15:0], "upper" for bits [31:16]

        Returns:
            32-bit word with instruction and NOP
        """
        c_nop = enc_c_nop()
        if position == "lower":
            return ((c_nop & 0xFFFF) << 16) | (instr & 0xFFFF)
        else:
            return ((instr & 0xFFFF) << 16) | (c_nop & 0xFFFF)

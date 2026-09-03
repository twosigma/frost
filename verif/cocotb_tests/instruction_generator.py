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

"""Constrained-random RISC-V instruction generator.

Generated instructions satisfy:
    - Register indices in 0-31
    - Immediate ranges (12-bit signed for most, 5-bit for shifts)
    - Alignment requirements (2-byte for halfword, 4-byte for word)
    - Even offsets for branches and jumps

Constrained-random streams reach operand and register combinations the
directed tests do not.

Example::

    >>> # Generate a random instruction
    >>> regfile = [random.randint(0, 0xFFFFFFFF) for _ in range(32)]
    >>> params = InstructionGenerator.generate_random_instruction(regfile)
    >>>
    >>> # Encode to binary
    >>> instruction_bits = InstructionGenerator.encode_instruction(*params)
    >>> 0 <= instruction_bits <= 0xFFFFFFFF
    True
"""

import random
from typing import NamedTuple
from config import (
    MASK_XLEN,
    XLEN,
    IMM_12BIT_MIN,
    IMM_12BIT_MAX,
    SHIFT_AMOUNT_MASK,
    HALFWORD_ALIGNMENT,
    WORD_ALIGNMENT,
    DOUBLEWORD_ALIGNMENT,
    MMIO_BASE_ADDR,
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
from utils.memory_utils import generate_aligned_immediate


class InstructionParams(NamedTuple):
    """Named fields for a generated RISC-V instruction."""

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

_RANDOM_MEMORY_OPS = LOADS | STORES | FP_LOADS | FP_STORES | AMO | AMO_LR_SC
"""Randomly generated operations that issue a data-memory access."""


# Grouped FP op tables by encoder signature for encode_instruction()
_FP_ENCODE_RD_RS1_RS2 = {**FP_ARITH_2OP, **FP_SGNJ, **FP_MINMAX, **FP_CMP}
_FP_ENCODE_RD_RS1 = {
    **FP_ARITH_1OP,
    **FP_CVT_F2I,
    **FP_CVT_I2F,
    **FP_CVT_F2F,
    **FP_MV_F2I,
    **FP_MV_I2F,
    **FP_CLASS,
}
_FP_ENCODE_RD_RS1_RS2_RS3 = {**FP_FMA}


def _is_double_precision_fp_op(operation: str) -> bool:
    """Return True if operation uses double-precision encoding/data path."""
    if operation in ("fld", "fsd"):
        return True
    if ".d" in operation:
        return True
    if ".s" in operation:
        return False
    # Default to single-precision for unqualified F ops without .s/.d suffix.
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
    # Default to single-precision for unqualified F ops without .s/.d suffix.
    return True


def _is_mmio_address(address: int) -> bool:
    """Return True if the address falls in the CPU's reserved high-address region."""
    masked_address = address & MASK_XLEN
    return masked_address >= MMIO_BASE_ADDR


def _effective_address(rs1_value: int, immediate: int) -> int:
    """Return the XLEN-wide effective address for a base+offset memory access."""
    return (rs1_value + immediate) & MASK_XLEN


def assert_random_memory_access_in_ram(
    operation: str, rs1_value: int, immediate: int
) -> None:
    """Raise if a random memory op targets the CPU's reserved high-address region."""
    if operation not in _RANDOM_MEMORY_OPS:
        return

    effective_address = _effective_address(rs1_value, immediate)
    if _is_mmio_address(effective_address):
        address_digits = XLEN // 4
        raise AssertionError(
            "Random generator produced reserved-region memory access: "
            f"op={operation} "
            f"rs1=0x{rs1_value & MASK_XLEN:0{address_digits}x} "
            f"imm={immediate} addr=0x{effective_address:0{address_digits}x} "
            f"MMIO_BASE_ADDR=0x{MMIO_BASE_ADDR:0{address_digits}x}"
        )


def _adjust_imm_to_avoid_mmio(
    rs1_value: int, immediate: int, alignment: int = 1
) -> int:
    """Adjust immediate if the effective address would land in reserved high space.

    Frost treats every address at or above 0x40000000 as MMIO/reserved space.
    Random RAM accesses stay below that boundary so the DUT and the software
    memory model exercise the same backing store.

    Args:
        rs1_value: Base register value
        immediate: Current immediate value
        alignment: Address alignment requirement (1, 2, 4, or 8)

    Returns:
        An immediate that keeps the access below MMIO_BASE_ADDR, or the
        original immediate when it already does or when no 12-bit immediate
        can reach RAM from this base.
    """
    effective_address = _effective_address(rs1_value, immediate)

    if not _is_mmio_address(effective_address):
        return immediate

    distance_to_start = effective_address - MMIO_BASE_ADDR + alignment
    if alignment > 1:
        distance_to_start = (
            (distance_to_start + alignment - 1) // alignment
        ) * alignment
    new_imm = immediate - distance_to_start
    if IMM_12BIT_MIN <= new_imm <= IMM_12BIT_MAX:
        return new_imm

    # This base cannot reach RAM within the 12-bit immediate range; the caller
    # re-picks rs1 for that rare case.
    return immediate


def _choose_non_mmio_rs1(register_file_state: list[int]) -> int:
    """Choose rs1 whose value is outside the CPU's reserved/MMIO high region."""
    candidates = [
        reg
        for reg, value in enumerate(register_file_state)
        if not _is_mmio_address(value)
    ]
    if candidates:
        return random.choice(candidates)
    return 0


def _choose_non_mmio_word_aligned_rs1(register_file_state: list[int]) -> int:
    """Choose rs1 whose value is word-aligned and outside MMIO space."""
    candidates = [
        reg
        for reg, value in enumerate(register_file_state)
        if ((value & MASK_XLEN) % WORD_ALIGNMENT) == 0 and not _is_mmio_address(value)
    ]
    if candidates:
        return random.choice(candidates)
    return 0


def _generate_constrained_memory_operand(
    register_file_state: list[int],
    preferred_rs1: int,
    alignment: int,
    memory_size_constraint: int,
) -> tuple[int, int]:
    """Return a base register and immediate whose address is in allocated RAM.

    The preferred random register usually cannot reach the low initialized
    memory with a 12-bit immediate. In that case x0 provides a guaranteed low
    base for a well-formed architectural register-file snapshot.
    """
    address_limit = min(memory_size_constraint, MMIO_BASE_ADDR)
    candidate_registers = (preferred_rs1, 0) if preferred_rs1 else (0,)
    for source_register in candidate_registers:
        try:
            immediate = generate_aligned_immediate(
                register_file_state[source_register],
                alignment,
                IMM_12BIT_MIN,
                IMM_12BIT_MAX,
                address_limit,
            )
        except ValueError:
            continue
        return source_register, immediate
    raise ValueError(
        "neither the selected base register nor x0 can reach constrained memory"
    )


def _choose_constrained_word_aligned_rs1(
    register_file_state: list[int], memory_size_constraint: int
) -> int:
    """Choose a word-aligned register value inside allocated, non-MMIO RAM."""
    address_limit = min(memory_size_constraint, MMIO_BASE_ADDR)
    if address_limit <= 0:
        raise ValueError("memory size constraint must be positive")
    candidates = [
        reg
        for reg, value in enumerate(register_file_state)
        if (value & MASK_XLEN) % WORD_ALIGNMENT == 0
        and (value & MASK_XLEN) < address_limit
    ]
    if not candidates:
        raise ValueError("no word-aligned register value is in constrained memory")
    return random.choice(candidates)


class InstructionGenerator:
    """Generate and encode random instructions within RISC-V constraints."""

    @staticmethod
    def get_all_operations() -> list[str]:
        """Get list of all supported RISC-V integer operations.

        Returns:
            List of operation mnemonics (e.g., ['add', 'sub', 'lw', ...])

        Note:
            The CSR instructions read the Zicntr counters (cycle, time,
            instret), which are timing-dependent. The test framework tracks
            these counters in software to check the values read back.
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
            # LR.W/SC.W are left to directed tests: whether an SC.W succeeds
            # depends on the preceding LR.W and on everything issued between
            # them, which a random stream does not control.
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
    def generate_random_instruction(
        register_file_state: list[int],
        force_one_address: bool = False,
        constrain_to_memory_size: int | None = None,
    ) -> InstructionParams:
        """Generate an instruction with constrained operands and offsets.

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
            InstructionParams for the generated instruction (csr_address is set
            only for CSR reads; source_register_3 stays 0).

        Examples:
            >>> regfile = [0] * 32
            >>> regfile[5] = 0x1000
            >>> params = InstructionGenerator.generate_random_instruction(regfile)
            >>> params.operation in InstructionGenerator.get_all_operations()
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

        # Immediate range depends on the instruction type.
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

        # Align memory accesses and optionally keep them inside allocated RAM.
        if operation in LOADS or operation in STORES:
            if operation in ("lh", "lhu", "sh"):
                mem_alignment = HALFWORD_ALIGNMENT
            elif operation in ("lw", "sw", "lwu"):
                mem_alignment = WORD_ALIGNMENT
            else:
                mem_alignment = 1

            if force_one_address:
                source_register_1 = 0
                immediate_value = 0
            elif constrain_to_memory_size is not None:
                source_register_1, immediate_value = (
                    _generate_constrained_memory_operand(
                        register_file_state,
                        source_register_1,
                        mem_alignment,
                        constrain_to_memory_size,
                    )
                )
            elif mem_alignment > 1:
                immediate_value = generate_aligned_immediate(
                    register_file_state[source_register_1],
                    mem_alignment,
                    IMM_12BIT_MIN,
                    IMM_12BIT_MAX,
                )
        elif operation == "jalr":
            # JALR target = (rs1 + imm) & ~1. The 32-bit tests keep the PC
            # word-aligned, so bit[1] of (rs1 + imm) has to be 0; the &~1 then
            # leaves a multiple of 4.
            rs1_val = register_file_state[source_register_1]
            # Pick an immediate, then nudge it so the sum has bit[1] clear.
            base_imm = random.randint(IMM_12BIT_MIN, IMM_12BIT_MAX)
            sum_bits = (rs1_val + base_imm) & 0x3
            if sum_bits == 2:
                immediate_value = base_imm + 2  # Will wrap and clear bit[1]
            elif sum_bits == 3:
                immediate_value = base_imm + 1  # 3+1=4, clears bits[1:0]
            else:
                immediate_value = base_imm  # Already OK (0 or 1)
            # Clamp back into the 12-bit range; a step of 4 keeps bits[1:0].
            if immediate_value > IMM_12BIT_MAX:
                immediate_value -= 4
            elif immediate_value < IMM_12BIT_MIN:
                immediate_value += 4
        elif operation in AMO or operation in AMO_LR_SC:
            # AMOs address memory through rs1 alone, with no immediate, so rs1
            # has to hold a word-aligned RAM address.
            immediate_value = 0
            if force_one_address:
                source_register_1 = 0
            elif constrain_to_memory_size is not None:
                source_register_1 = _choose_constrained_word_aligned_rs1(
                    register_file_state, constrain_to_memory_size
                )
            else:
                source_register_1 = _choose_non_mmio_word_aligned_rs1(
                    register_file_state
                )

        # Keep random memory ops in normal RAM space. Only re-pick rs1 when the
        # originally selected base cannot be adjusted away from the reserved region.
        if operation in LOADS or operation in STORES:
            if operation in ("lh", "lhu", "sh"):
                mem_alignment = HALFWORD_ALIGNMENT
            elif operation in ("lw", "sw", "lwu"):
                mem_alignment = WORD_ALIGNMENT
            else:
                mem_alignment = 1
            immediate_value = _adjust_imm_to_avoid_mmio(
                register_file_state[source_register_1],
                immediate_value,
                mem_alignment,
            )
            effective_address = _effective_address(
                register_file_state[source_register_1], immediate_value
            )
            if _is_mmio_address(effective_address):
                source_register_1 = _choose_non_mmio_rs1(register_file_state)
                if operation in ("lh", "lhu", "sh"):
                    immediate_value = generate_aligned_immediate(
                        register_file_state[source_register_1],
                        HALFWORD_ALIGNMENT,
                        IMM_12BIT_MIN,
                        IMM_12BIT_MAX,
                        constrain_to_memory_size,
                    )
                elif operation in ("lw", "sw", "lwu"):
                    immediate_value = generate_aligned_immediate(
                        register_file_state[source_register_1],
                        WORD_ALIGNMENT,
                        IMM_12BIT_MIN,
                        IMM_12BIT_MAX,
                        constrain_to_memory_size,
                    )
                immediate_value = _adjust_imm_to_avoid_mmio(
                    register_file_state[source_register_1],
                    immediate_value,
                    mem_alignment,
                )
                effective_address = _effective_address(
                    register_file_state[source_register_1],
                    immediate_value,
                )
                if _is_mmio_address(effective_address):
                    # Last-resort escape hatch for wrapped negative offsets.
                    source_register_1 = 0
                    immediate_value = 0

        # The C-extension IF stage allows a PC on a halfword boundary. The
        # 32-bit tests carry no compressed instructions, so branch and jump
        # offsets are multiples of 4 to keep the PC word-aligned.
        branch_offset = None
        if operation in BRANCHES:
            # Branch offsets are 13-bit signed, must be multiple of 4 for 32-bit tests
            branch_offset = random.randrange(-4096, 4096, 4) or 4
        elif operation == "jal":
            # JAL offsets are 21-bit signed, must be multiple of 4 for 32-bit tests
            branch_offset = random.randrange(-1048576, 1048576, 4)

        csr_address = None
        if operation in CSRS:
            csr_address = random.choice(ZICNTR_CSRS)
            # Pure read (the csrr pseudo-instruction): rs1=x0 or zimm=0 leaves
            # the CSR unmodified.
            source_register_1 = 0  # rs1=x0 means no write to CSR
            immediate_value = 0  # zimm=0 for immediate variants

        assert_random_memory_access_in_ram(
            operation,
            register_file_state[source_register_1],
            immediate_value,
        )

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
        """Generate a random F/D floating-point instruction.

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

        # Defaults; the memory ops below replace the immediate (and rs1 when
        # the base lands in MMIO space).
        destination_register = random.randint(0, 31)
        source_register_1 = random.randint(0, 31)
        source_register_2 = random.randint(0, 31)
        source_register_3 = random.randint(0, 31)
        immediate_value = 0

        if operation in FP_LOADS:
            # FLW/FLD: rd=FP, rs1=INT base, imm=offset; word/dword-aligned.
            alignment = DOUBLEWORD_ALIGNMENT if operation == "fld" else WORD_ALIGNMENT
            if constrain_to_memory_size is not None:
                source_register_1, immediate_value = (
                    _generate_constrained_memory_operand(
                        int_register_file_state,
                        source_register_1,
                        alignment,
                        constrain_to_memory_size,
                    )
                )
            else:
                immediate_value = generate_aligned_immediate(
                    int_register_file_state[source_register_1],
                    alignment,
                    IMM_12BIT_MIN,
                    IMM_12BIT_MAX,
                )
        elif operation in FP_STORES:
            # FSW/FSD: rs2=FP data, rs1=INT base, imm=offset; word/dword-aligned.
            alignment = DOUBLEWORD_ALIGNMENT if operation == "fsd" else WORD_ALIGNMENT
            if constrain_to_memory_size is not None:
                source_register_1, immediate_value = (
                    _generate_constrained_memory_operand(
                        int_register_file_state,
                        source_register_1,
                        alignment,
                        constrain_to_memory_size,
                    )
                )
            else:
                immediate_value = generate_aligned_immediate(
                    int_register_file_state[source_register_1],
                    alignment,
                    IMM_12BIT_MIN,
                    IMM_12BIT_MAX,
                )
        # Other FP ops don't use immediates

        # Keep FP memory ops in normal RAM space. Only re-pick rs1 when the
        # original base cannot be adjusted away from the reserved region.
        if operation in FP_LOADS or operation in FP_STORES:
            fp_alignment = (
                DOUBLEWORD_ALIGNMENT if operation in ("fld", "fsd") else WORD_ALIGNMENT
            )
            immediate_value = _adjust_imm_to_avoid_mmio(
                int_register_file_state[source_register_1],
                immediate_value,
                fp_alignment,
            )
            effective_address = _effective_address(
                int_register_file_state[source_register_1], immediate_value
            )
            if _is_mmio_address(effective_address):
                source_register_1 = _choose_non_mmio_rs1(int_register_file_state)
                immediate_value = generate_aligned_immediate(
                    int_register_file_state[source_register_1],
                    fp_alignment,
                    IMM_12BIT_MIN,
                    IMM_12BIT_MAX,
                    constrain_to_memory_size,
                )
                immediate_value = _adjust_imm_to_avoid_mmio(
                    int_register_file_state[source_register_1],
                    immediate_value,
                    fp_alignment,
                )
                effective_address = _effective_address(
                    int_register_file_state[source_register_1],
                    immediate_value,
                )
                if _is_mmio_address(effective_address):
                    # Last-resort escape hatch for wrapped negative offsets.
                    source_register_1 = 0
                    immediate_value = 0

        assert_random_memory_access_in_ram(
            operation,
            int_register_file_state[source_register_1],
            immediate_value,
        )

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

        Dispatches on the op table the mnemonic belongs to, which fixes the
        instruction format and the encoder's argument order.

        Args:
            operation: Instruction mnemonic (e.g., "add", "lw", "beq", "fadd.s")
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
            # I-type format: Zbb unary ops (clz, ctz, cpop, sext.b, sext.h, orc.b, rev8)
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
            # CSR instructions. The random stream only reads the Zicntr
            # counters (rs1=0 or zimm=0).
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
            # A extension AMOs: amoXX rd, rs2, (rs1). Atomically loads from
            # rs1, computes with rs2, and stores the result back.
            encoder_function, _ = AMO[operation]
            return encoder_function(
                destination_register, source_register_2, source_register_1
            )
        elif operation in AMO_LR_SC:
            # A extension: Load-reserved / Store-conditional
            encoder_function = AMO_LR_SC[operation]
            if operation == "lr.w":
                # LR.W rd, (rs1): load and set the reservation
                return encoder_function(destination_register, source_register_1)
            else:
                # SC.W rd, rs2, (rs1): store conditional
                return encoder_function(
                    destination_register, source_register_2, source_register_1
                )
        elif operation in TRAP_INSTRS:
            # Machine-mode trap instructions (ECALL, EBREAK, MRET, WFI): fixed
            # encodings, no operands.
            encoder_function = TRAP_INSTRS[operation]
            return encoder_function()
        # F/D extension (floating-point) instruction encoding
        elif operation in _FP_ENCODE_RD_RS1_RS2:
            encoder_function, _ = _FP_ENCODE_RD_RS1_RS2[operation]
            return encoder_function(
                destination_register, source_register_1, source_register_2
            )
        elif operation in _FP_ENCODE_RD_RS1:
            encoder_function, _ = _FP_ENCODE_RD_RS1[operation]
            return encoder_function(destination_register, source_register_1)
        elif operation in _FP_ENCODE_RD_RS1_RS2_RS3:
            encoder_function, _ = _FP_ENCODE_RD_RS1_RS2_RS3[operation]
            return encoder_function(
                destination_register,
                source_register_1,
                source_register_2,
                source_register_3,
            )
        elif operation in FP_LOADS:
            encoder_function, _ = FP_LOADS[operation]
            return encoder_function(
                destination_register, source_register_1, immediate_value
            )
        elif operation in FP_STORES:
            encoder_function = FP_STORES[operation]
            return encoder_function(
                source_register_2, source_register_1, immediate_value
            )
        else:
            raise RuntimeError(f"Unknown operation: {operation}")

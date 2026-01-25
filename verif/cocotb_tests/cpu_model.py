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

"""Software reference model of CPU behavior for verification.

CPU Model
=========

This module implements a cycle-accurate software model of RISC-V CPU
behavior. It models instruction execution, register writeback, PC updates,
and memory operations for comparison against hardware execution.

Purpose:
    The CPU model computes the EXPECTED behavior of each instruction in
    software. These expected values are then compared against actual
    hardware outputs by the verification monitors. Any mismatch indicates
    a bug in the hardware implementation.

Key Responsibilities:
    1. Model register writeback values (what should be written to rd)
    2. Model program counter updates (sequential, branch, jump)
    3. Model memory writes (address, data, byte mask)
    4. Track branch taken/not-taken decisions

Example Flow:
    1. Test generates "add x5, x3, x4"
    2. CPUModel.model_instruction_execution() computes:
        - rd_to_update = 5
        - writeback_value = register[3] + register[4]
        - expected_pc = current_pc + 4
    3. Monitors verify hardware produces same results
"""

import cocotb
from config import MASK32, MEMORY_WORD_ALIGN_MASK
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
    AMO,
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
from cocotb_tests.instruction_generator import (
    FP_OPS_TO_FP_REG,
    FP_OPS_NO_WRITE,
)
from models.memory_model import MemoryModel
from models.branch_model import branch_taken_decision
from models.alu_model import lw
from utils.memory_utils import (
    calculate_byte_mask_for_store,
    get_byte_offset,
)
from cocotb_tests.test_state import TestState


class CPUModel:
    """Software model of CPU behavior for verification against hardware.

    This class provides methods to model RISC-V instruction execution in
    software, calculating expected results for:
    - Register writeback values
    - Program counter updates
    - Memory write operations
    - Branch taken/not-taken decisions

    The model is used to generate expected values that are compared against
    actual hardware execution for verification.
    """

    @staticmethod
    def model_instruction_execution(
        state: TestState,
        memory_model: MemoryModel,
        operation: str,
        destination_register: int,
        source_register_1: int,
        source_register_2: int,
        immediate_value: int,
        branch_offset: int | None,
        csr_address: int | None = None,
        source_register_3: int = 0,
    ) -> tuple[int | None, int, int, bool]:
        """Model execution of a single RISC-V instruction.

        Computes the expected behavior of executing one instruction, including:
        - Which register (if any) will be updated
        - The value to write back to that register
        - The expected program counter after execution
        - Whether the destination is an FP register

        Args:
            state: Current test state with register file and PC
            memory_model: Memory model for load/store operations
            operation: Instruction mnemonic (e.g., "add", "lw", "beq", "csrrs", "fadd.s")
            destination_register: Destination register index (0-31)
            source_register_1: First source register index (0-31)
            source_register_2: Second source register index (0-31)
            immediate_value: Immediate value for I-type instructions
            branch_offset: Branch/jump offset (for B-type and J-type)
            csr_address: CSR address for Zicsr instructions (e.g., 0xC00 for cycle)
            source_register_3: Third source register for FMA instructions (0-31)

        Returns:
            Tuple of (register_to_update, writeback_value, expected_pc, is_fp_destination)
            - register_to_update: Register index to write, or None for stores/branches
            - writeback_value: Value to write to destination register
            - expected_pc: Expected program counter after instruction
            - is_fp_destination: True if result goes to FP register file

        Example:
            >>> # Model an ADD x1, x2, x3 instruction
            >>> reg_idx, value, pc, is_fp = CPUModel.model_instruction_execution(
            ...     state, mem_model, "add", 1, 2, 3, 0, None
            ... )
            >>> reg_idx == 1  # Writes to x1
            True
        """
        # Set memory read address for load and AMO operations (needed before writeback calculation)
        # AMO operations use rs1 directly as address (no immediate offset)
        if operation in LOADS:
            memory_model.read_address = (
                state.register_file_previous[source_register_1] + immediate_value
            ) & MASK32
        elif operation in FP_LOADS:
            # FP loads use integer register for address calculation
            memory_model.read_address = (
                state.register_file_previous[source_register_1] + immediate_value
            ) & MASK32
        elif operation in AMO or operation == "lr.w":
            # AMO and LR.W use rs1 as address (word-aligned)
            memory_model.read_address = (
                state.register_file_previous[source_register_1] & ~0x3
            )

        # Determine whether branch or jump was taken
        if operation in BRANCHES:
            rs1_val = state.register_file_previous[source_register_1]
            rs2_val = state.register_file_previous[source_register_2]
            state.branch_taken_current = branch_taken_decision(
                operation,
                rs1_val,
                rs2_val,
            )
            cocotb.log.info(
                f"Branch {operation}: rs1(x{source_register_1})=0x{rs1_val:08X}, "
                f"rs2(x{source_register_2})=0x{rs2_val:08X}, "
                f"taken={state.branch_taken_current}"
            )
            state.branch_was_jal_current = False
        elif operation in JUMPS:
            state.branch_taken_current = True  # Jumps are always taken
            # JAL and JALR are now both resolved in EX stage (3 flush cycles each)
            state.branch_was_jal_current = False
        else:
            state.branch_taken_current = False
            state.branch_was_jal_current = False

        # Stores, branches, and fences don't write to destination register
        # Note: CSR instructions DO write to rd (the old CSR value)
        # FP stores also don't write to any register
        register_index_to_update = (
            None
            if (
                operation in STORES
                or operation in BRANCHES
                or operation in FENCES
                or operation in FP_OPS_NO_WRITE
            )
            else destination_register
        )

        # Determine if destination is FP or integer register
        is_fp_destination = operation in FP_OPS_TO_FP_REG

        # Calculate writeback value for destination register
        writeback_value = CPUModel._compute_writeback_value(
            state,
            memory_model,
            operation,
            source_register_1,
            source_register_2,
            immediate_value,
            csr_address,
            source_register_3,
        )

        # Calculate expected program counter after instruction execution
        expected_program_counter = CPUModel._compute_expected_program_counter(
            state, operation, source_register_1, immediate_value, branch_offset
        )

        return (
            register_index_to_update,
            writeback_value,
            expected_program_counter,
            is_fp_destination,
        )

    @staticmethod
    def _compute_writeback_value(
        state: TestState,
        memory_model: MemoryModel,
        operation: str,
        source_register_1: int,
        source_register_2: int,
        immediate_value: int,
        csr_address: int | None = None,
        source_register_3: int = 0,
    ) -> int:
        """Compute the value to write back to the destination register.

        Executes the operation using software model (ALU, load, FPU, etc.) and
        returns the result that should be written to the destination register.

        Args:
            state: Test state with current register values
            memory_model: Memory model for load operations
            operation: Instruction mnemonic
            source_register_1: First source register index
            source_register_2: Second source register index
            immediate_value: Immediate value for I-type
            csr_address: CSR address for Zicsr instructions
            source_register_3: Third source register for FMA instructions

        Returns:
            Value to write to destination register
        """
        if operation in JUMPS:
            # JAL/JALR write return address (PC+4) to destination
            # Uses PC from 2 cycles ago (passed through pipeline registers)
            return (state.program_counter_two_cycles_ago + 4) & MASK32
        elif operation in CSRS:
            # CSR instructions write the old CSR value to rd
            # The value depends on which CSR is being read
            assert csr_address is not None, "CSR address required for CSR instructions"
            return state.get_csr_value(csr_address)
        elif operation in LOADS:
            # Execute load operation from memory
            # Load functions now take (memory, address) to avoid global state
            _, fn = LOADS[operation]
            return fn(memory_model, memory_model.read_address)
        elif operation in I_ALU:
            # Execute immediate ALU operation
            _, fn = I_ALU[operation]
            return fn(
                state.register_file_previous[source_register_1],
                immediate_value & MASK32,
            )
        elif operation in I_UNARY:
            # Execute unary ALU operation (Zbb clz, ctz, cpop, sext.b, sext.h, orc.b, rev8)
            _, fn = I_UNARY[operation]
            return fn(state.register_file_previous[source_register_1])
        elif operation in R_ALU:
            # Execute register-register ALU operation
            _, fn = R_ALU[operation]
            return fn(
                state.register_file_previous[source_register_1],
                state.register_file_previous[source_register_2],
            )
        elif operation == "lr.w":
            # LR.W: rd receives memory value, and reservation is set
            # Set reservation immediately - by the time any SC.W executes,
            # the LR.W will have completed (handled by pipeline hazards)
            state.set_reservation(memory_model.read_address)
            return lw(memory_model, memory_model.read_address)
        elif operation in AMO:
            # AMO: rd receives old memory value (like a load)
            return lw(memory_model, memory_model.read_address)
        elif operation == "sc.w":
            # SC.W: rd receives 0 on success, 1 on failure
            # Check reservation and clear it (SC always clears reservation)
            sc_address = state.register_file_previous[source_register_1] & ~0x3
            success = state.check_reservation(sc_address)
            state.clear_reservation()
            # Store SC result for memory write modeling
            state.last_sc_succeeded = success
            state.last_sc_address = sc_address
            state.last_sc_data = state.register_file_previous[source_register_2]
            return 0 if success else 1
        # ===== F extension (floating-point) operations =====
        elif operation in FP_LOADS:
            # FLW: Load 32 bits from memory to FP register
            _, fn = FP_LOADS[operation]
            return fn(memory_model, memory_model.read_address)
        elif operation in FP_ARITH_2OP:
            # Two-operand FP arithmetic (fadd.s, fsub.s, fmul.s, fdiv.s)
            _, fn = FP_ARITH_2OP[operation]
            return fn(
                state.fp_register_file_previous[source_register_1],
                state.fp_register_file_previous[source_register_2],
            )
        elif operation in FP_ARITH_1OP:
            # Single-operand FP arithmetic (fsqrt.s)
            _, fn = FP_ARITH_1OP[operation]
            return fn(state.fp_register_file_previous[source_register_1])
        elif operation in FP_FMA:
            # Fused multiply-add (fmadd.s, fmsub.s, fnmadd.s, fnmsub.s)
            _, fn = FP_FMA[operation]
            return fn(
                state.fp_register_file_previous[source_register_1],
                state.fp_register_file_previous[source_register_2],
                state.fp_register_file_previous[source_register_3],
            )
        elif operation in FP_SGNJ:
            # Sign injection (fsgnj.s, fsgnjn.s, fsgnjx.s)
            _, fn = FP_SGNJ[operation]
            return fn(
                state.fp_register_file_previous[source_register_1],
                state.fp_register_file_previous[source_register_2],
            )
        elif operation in FP_MINMAX:
            # Min/max (fmin.s, fmax.s)
            _, fn = FP_MINMAX[operation]
            return fn(
                state.fp_register_file_previous[source_register_1],
                state.fp_register_file_previous[source_register_2],
            )
        elif operation in FP_CMP:
            # Comparison (feq.s, flt.s, fle.s) -> integer result
            _, fn = FP_CMP[operation]
            return fn(
                state.fp_register_file_previous[source_register_1],
                state.fp_register_file_previous[source_register_2],
            )
        elif operation in FP_CVT_F2I:
            # FP to integer conversion (fcvt.w.s, fcvt.wu.s)
            _, fn = FP_CVT_F2I[operation]
            return fn(state.fp_register_file_previous[source_register_1])
        elif operation in FP_CVT_I2F:
            # Integer to FP conversion (fcvt.s.w, fcvt.s.wu)
            _, fn = FP_CVT_I2F[operation]
            return fn(state.register_file_previous[source_register_1])
        elif operation in FP_CVT_F2F:
            # FP to FP conversion (fcvt.s.d, fcvt.d.s)
            _, fn = FP_CVT_F2F[operation]
            return fn(state.fp_register_file_previous[source_register_1])
        elif operation in FP_MV_F2I:
            # FP bits to integer move (fmv.x.w)
            _, fn = FP_MV_F2I[operation]
            return fn(state.fp_register_file_previous[source_register_1])
        elif operation in FP_MV_I2F:
            # Integer bits to FP move (fmv.w.x)
            _, fn = FP_MV_I2F[operation]
            return fn(state.register_file_previous[source_register_1])
        elif operation in FP_CLASS:
            # Classify (fclass.s) -> integer result
            _, fn = FP_CLASS[operation]
            return fn(state.fp_register_file_previous[source_register_1])
        else:
            # Stores, branches, and fences don't produce writeback
            return 0

    @staticmethod
    def _compute_expected_program_counter(
        state: TestState,
        operation: str,
        source_register_1: int,
        immediate: int,
        offset: int | None,
    ) -> int:
        """Compute the expected program counter after instruction execution.

        In the 6-stage pipeline, o_pc_vld fires at ID stage (before branch resolution
        in EX). So o_pc shows sequential PC regardless of whether branch is taken.
        The branch/jump target affects subsequent flush NOPs, not the instruction's
        own o_pc output.

        All instruction types return sequential PC (program_counter_current + 4):
        - Sequential: PC + 4
        - Taken branch: PC + 4 (target affects flush NOPs)
        - Not-taken branch: PC + 4
        - JAL: PC + 4 (target affects flush NOPs)
        - JALR: PC + 4 (target affects flush NOPs)

        Args:
            state: Test state with current PC values
            operation: Instruction mnemonic
            source_register_1: First source register (for JALR)
            immediate: Immediate value (for JALR)
            offset: Branch/jump offset

        Returns:
            Expected program counter value
        """
        if operation in BRANCHES:
            # In 6-stage pipeline, o_pc_vld fires at ID stage (before branch resolution in EX).
            # So o_pc shows sequential PC regardless of whether branch is taken.
            # The branch target affects subsequent flush NOPs, not the branch's own o_pc.
            return (state.program_counter_current + 4) & MASK32
        elif operation == "jal":
            # JAL is now resolved in EX stage (like JALR and branches).
            # In 6-stage pipeline, o_pc_vld fires at ID stage (before JAL resolution in EX).
            # So o_pc shows sequential PC, just like branches and JALR.
            # The JAL target affects subsequent flush NOPs, not the JAL's own o_pc.
            return (state.program_counter_current + 4) & MASK32
        elif operation == "jalr":
            # JALR is resolved in EX stage (like branches) because it needs register values.
            # In 6-stage pipeline, o_pc_vld fires at ID stage (before JALR resolution in EX).
            # So o_pc shows sequential PC, just like branches.
            # The JALR target affects subsequent flush NOPs, not the JALR's own o_pc.
            return (state.program_counter_current + 4) & MASK32
        else:
            # Sequential execution: PC + 4
            return (state.program_counter_current + 4) & MASK32

    @staticmethod
    def calculate_internal_pc_update(
        state: TestState,
        operation: str,
        rs1_value: int,
        immediate: int,
        offset: int | None,
        expected_pc: int,
    ) -> int:
        """Calculate the internal PC update value for pipeline state tracking.

        The internal PC tracking differs from the expected PC output because:
        - expected_pc: What the hardware outputs (always sequential in 6-stage pipeline)
        - internal PC: What we track so subsequent flush NOPs have correct expected_pc

        For control flow instructions (JAL, JALR, taken branches), the internal
        PC is set to (target - 4) so that when we compute expected_pc = pc_cur + 4
        for flush NOPs, we get the correct target address.

        Args:
            state: Test state with PC tracking
            operation: Instruction mnemonic
            rs1_value: Value of rs1 register (for JALR)
            immediate: Immediate value (for JALR)
            offset: Branch/jump offset
            expected_pc: The expected PC output value

        Returns:
            PC value to use for internal state tracking
        """
        if operation == "jal":
            # JAL target = instruction_PC + offset = two_cycles_ago + offset
            # Set pc_update = target - 4 so flush NOPs compute expected_pc = target
            assert offset is not None, "JAL instructions must have an offset"
            jal_target = (state.program_counter_two_cycles_ago + offset) & MASK32
            return (jal_target - 4) & MASK32
        elif operation == "jalr":
            # JALR target = (rs1 + imm) & ~1
            # Set pc_update = target - 4 so flush NOPs compute expected_pc = target
            jalr_target = (rs1_value + immediate) & 0xFFFFFFFE & MASK32
            return (jalr_target - 4) & MASK32
        elif operation in BRANCHES and state.branch_taken_current:
            # Taken branch target = instruction_PC + offset = two_cycles_ago + offset
            # Set pc_update = target - 4 so flush NOPs compute expected_pc = target
            assert offset is not None, "Branch instructions must have an offset"
            return (state.program_counter_two_cycles_ago + offset - 4) & MASK32
        else:
            # Non-control-flow: internal tracking matches expected output
            return expected_pc

    @staticmethod
    def model_memory_write(
        state: TestState,
        mem_model: MemoryModel,
        operation: str,
        source_register_1: int,
        source_register_2: int,
        immediate: int,
    ) -> None:
        """Model expected memory writes for STORE operations.

        Calculates expected memory write address, data, and byte mask for
        store instructions (SB, SH, SW). Updates both the expected value
        queues and the memory model.

        Memory Write Encoding:
            RISC-V stores write data to a 32-bit word-aligned memory interface.
            For sub-word stores (SB, SH), the data must be shifted to the correct
            byte position within the word.

            Example: SB x5, 2(x1) where x1=0x1001, x5=0xAB
                - Address = 0x1001 + 2 = 0x1003
                - Byte offset = 3 (address & 0x3)
                - Write data = 0xAB << 24 = 0xAB000000
                - Write mask = 0b1000 (byte 3 only)

        Args:
            state: Test state with register values and expected queues
            mem_model: Memory model to update
            operation: Store operation ("sb", "sh", or "sw")
            source_register_1: Base address register
            source_register_2: Data register
            immediate: Address offset

        Side Effects:
            - Appends to memory_write_address_expected_queue
            - Appends to memory_write_data_expected_queue
            - Updates memory model bytes
        """
        # Handle SC.W memory writes (only if successful)
        if operation == "sc.w":
            # SC.W only writes to memory if it succeeded
            # The success was computed in _compute_writeback_value and stored in state
            if state.last_sc_succeeded:
                write_address = state.last_sc_address
                write_data = state.last_sc_data
                cocotb.log.info(
                    f"op sc.w SUCCESS: writing data {write_data} to address {write_address}"
                )
                # Update expected queues
                state.memory_write_address_expected_queue.append(write_address)
                state.memory_write_data_expected_queue.append(write_data)
                # Update memory model
                mem_model.write_word(write_address, write_data)
            return

        # Handle AMO memory writes (atomic read-modify-write)
        if operation in AMO:
            # AMO address is rs1 (word-aligned)
            write_address = state.register_file_previous[source_register_1] & ~0x3
            # Read old value from memory
            old_value = lw(mem_model, write_address)
            # Compute new value using AMO evaluator
            _, evaluator = AMO[operation]
            new_value = evaluator(
                old_value,
                state.register_file_previous[source_register_2],
            )
            cocotb.log.info(
                f"op {operation} at address {write_address}: "
                f"old={old_value}, rs2={state.register_file_previous[source_register_2]}, "
                f"new={new_value}"
            )
            # Update expected queues
            state.memory_write_address_expected_queue.append(write_address)
            state.memory_write_data_expected_queue.append(new_value)
            # Update memory model
            mem_model.write_word(write_address, new_value)
            return

        # Handle FP store (FSW/FSD)
        if operation in FP_STORES:
            # FSW: rs2 is FP register (data), rs1 is INT register (address)
            write_address = (
                state.register_file_previous[source_register_1] + immediate
            ) & MASK32
            # Get data from FP register file
            fp_value = state.fp_register_file_previous[source_register_2]
            if operation == "fsd":
                # RTL writes FSD as two 32-bit stores: low word then high word.
                # See hw/rtl/cpu_and_mem/cpu/ma_stage/ma_stage.sv (FP_MEM_STORE_HI).
                low_word = fp_value & MASK32
                high_word = (fp_value >> 32) & MASK32
                cocotb.log.info(
                    f"op {operation} storing fp_rs2_val 0x{fp_value:016X} "
                    f"to address 0x{write_address:08X}"
                )
                # Queue low word then high word (little-endian)
                state.memory_write_address_expected_queue.append(write_address)
                state.memory_write_data_expected_queue.append(low_word)
                state.memory_write_address_expected_queue.append(
                    (write_address + 4) & MASK32
                )
                state.memory_write_data_expected_queue.append(high_word)
                # Update memory model
                mem_model.write_word(write_address & MEMORY_WORD_ALIGN_MASK, low_word)
                mem_model.write_word(
                    (write_address + 4) & MEMORY_WORD_ALIGN_MASK, high_word
                )
            else:
                write_data = fp_value & MASK32
                cocotb.log.info(
                    f"op {operation} with fp_rs2_val 0x{write_data:08X} "
                    f"storing to address 0x{write_address:08X}"
                )
                # Update expected queues
                state.memory_write_address_expected_queue.append(write_address)
                state.memory_write_data_expected_queue.append(write_data)
                # Update memory model (word-aligned store)
                mem_model.write_word(write_address & MEMORY_WORD_ALIGN_MASK, write_data)
            return

        if operation not in STORES:
            return

        # Calculate effective address: base + offset
        write_address = (
            state.register_file_previous[source_register_1] + immediate
        ) & MASK32

        # Get byte position within 32-bit word (0-3)
        byte_offset = get_byte_offset(write_address)

        # Get value to store from source register
        source_register_2_value = (
            state.register_file_previous[source_register_2] & MASK32
        )

        # Calculate write mask (which bytes in word to update)
        write_mask = calculate_byte_mask_for_store(operation, byte_offset)

        # Calculate write data, shifting to correct byte lanes for sub-word stores
        # For SB/SH: shift left so data aligns with byte position
        # For SW: no shift needed, use full word
        if operation in ("sb", "sh"):
            write_data = (source_register_2_value << (8 * byte_offset)) & MASK32
        else:  # sw
            write_data = source_register_2_value & MASK32

        cocotb.log.info(
            f"op {operation} with rs2_val {source_register_2_value} storing data value of "
            f"{write_data} to address {write_address} with wr_mask {write_mask}"
        )

        # Update expected queues
        state.memory_write_address_expected_queue.append(write_address)
        state.memory_write_data_expected_queue.append(write_data)

        # Update memory model
        write_address_word = write_address & MEMORY_WORD_ALIGN_MASK
        for i in range(4):
            if (write_mask >> i) & 1:
                mem_model.write_byte(
                    write_address_word + i, (write_data >> (8 * i)) & 0xFF
                )

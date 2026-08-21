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

"""Execute instructions and model their effects for directed tests.

``InstructionExecutor`` applies the shared sequence:

1. Wait for DUT ready
2. Encode instruction to binary
3. Model expected behavior
4. Queue expected values for monitors
5. Drive instruction to DUT
6. Advance software state

Centralizing this sequence keeps the directed suites consistent.

Usage::

    from cocotb_tests.instruction_executor import InstructionExecutor

    executor = InstructionExecutor(dut_if, state, mem_model)

    # Execute a simple ALU instruction
    await executor.execute_alu("add", rd=1, rs1=2, rs2=3)

    # Execute a load
    await executor.execute_load("lw", rd=5, rs1=10, imm=16)

    # Execute a store
    await executor.execute_store("sw", rs1=10, rs2=5, imm=0)

    # Execute a NOP
    await executor.execute_nop()

    # Flush pipeline with NOPs
    await executor.flush_pipeline(cycles=6)
"""

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge

from config import MASK32, PIPELINE_DEPTH
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface
from cocotb_tests.test_state import TestState
from utils.instruction_logger import InstructionLogger


class InstructionExecutor:
    """Execute and model single instructions in directed tests.

    Handles:
    - DUT ready/valid handshaking
    - Instruction encoding
    - Expected value modeling
    - Queue management for monitors
    - Software state updates

    Attributes:
        dut_if: DUT interface for signal access
        state: Test state for tracking expectations
        mem_model: Memory model for load/store operations
        logger: Optional instruction logger for debugging
    """

    def __init__(
        self,
        dut_if: DUTInterface,
        state: TestState,
        mem_model: MemoryModel,
        logger: InstructionLogger | None = None,
    ) -> None:
        """Initialize the instruction executor.

        Args:
            dut_if: DUT interface for signal access
            state: Test state for tracking expectations
            mem_model: Memory model for load/store operations
            logger: Optional instruction logger for debugging output
        """
        self.dut_if = dut_if
        self.state = state
        self.mem_model = mem_model
        self.logger = logger

    async def execute_nop(self, log: bool = False) -> None:
        """Execute a NOP instruction (addi x0, x0, 0).

        A NOP is used for:
        - Pipeline warmup
        - Branch flush handling
        - Test synchronization

        Args:
            log: If True, log the NOP execution for debugging
        """
        await self.execute_alu("addi", rd=0, rs1=0, rs2=0, imm=0, log=log)

    async def flush_pipeline(self, cycles: int = PIPELINE_DEPTH) -> None:
        """Flush pipeline by executing NOPs.

        Args:
            cycles: Number of NOP cycles to execute (default: PIPELINE_DEPTH)
        """
        for _ in range(cycles):
            await self.execute_nop()

    async def execute_alu(
        self,
        operation: str,
        rd: int,
        rs1: int,
        rs2: int = 0,
        imm: int = 0,
        log: bool = False,
    ) -> None:
        """Execute an ALU instruction and model its effects.

        Supports both R-type (register-register) and I-type (immediate) ALU ops.

        Args:
            operation: Instruction mnemonic (e.g., "add", "addi", "sub")
            rd: Destination register
            rs1: Source register 1
            rs2: Source register 2 (for R-type, ignored for I-type)
            imm: Immediate value (for I-type, ignored for R-type)
            log: If True, log the instruction execution
        """
        from encoders.op_tables import R_ALU, I_ALU
        from cocotb_tests.cpu_model import CPUModel

        await FallingEdge(self.dut_if.clock)
        await self.dut_if.wait_ready()

        # Encode instruction
        if operation in R_ALU:
            encoder, _ = R_ALU[operation]
            instr = encoder(rd, rs1, rs2)
        elif operation in I_ALU:
            encoder, _ = I_ALU[operation]
            instr = encoder(rd, rs1, imm)
        else:
            raise ValueError(f"Unknown ALU operation: {operation}")

        # Model expected behavior
        rd_to_update, rd_wb_value, expected_pc, is_fp_dest = (
            CPUModel.model_instruction_execution(
                self.state, self.mem_model, operation, rd, rs1, rs2, imm, None, None
            )
        )

        # Update register file model
        if rd_to_update is not None:
            if is_fp_dest:
                self.state.update_fp_register(rd_to_update, rd_wb_value)
            else:
                self.state.update_register(rd_to_update, rd_wb_value)

        # Queue expected outputs
        self.state.queue_expected_outputs(expected_pc)

        if log:
            cocotb.log.info(
                f"{operation} x{rd}, x{rs1}, {'x' + str(rs2) if operation in R_ALU else str(imm)}: "
                f"result=0x{rd_wb_value:08X}"
            )

        # Drive instruction
        self.dut_if.instruction = instr
        await RisingEdge(self.dut_if.clock)

        # Advance state
        self.state.increment_cycle_counter()
        self.state.increment_instret_counter()
        self.state.update_program_counter(expected_pc)
        self.state.advance_register_state()

    async def execute_load(
        self,
        operation: str,
        rd: int,
        rs1: int,
        imm: int = 0,
        log: bool = False,
    ) -> int:
        """Execute a load instruction and model its effects.

        Args:
            operation: Load mnemonic ("lw", "lh", "lhu", "lb", "lbu")
            rd: Destination register
            rs1: Base address register
            imm: Immediate offset

        Returns:
            The loaded value
        """
        from encoders.op_tables import LOADS
        from cocotb_tests.cpu_model import CPUModel

        await FallingEdge(self.dut_if.clock)
        await self.dut_if.wait_ready()

        # Encode instruction (LOADS returns (encoder, evaluator) tuple)
        encoder, _ = LOADS[operation]
        instr = encoder(rd, rs1, imm)

        # Compute address
        address = (self.state.register_file_previous[rs1] + imm) & MASK32

        # Tell memory model which address we're reading
        self.mem_model.read_address = address

        # Model expected behavior
        rd_to_update, rd_wb_value, expected_pc, is_fp_dest = (
            CPUModel.model_instruction_execution(
                self.state, self.mem_model, operation, rd, rs1, 0, imm, None, None
            )
        )

        # Update register file model
        if rd_to_update is not None:
            if is_fp_dest:
                self.state.update_fp_register(rd_to_update, rd_wb_value)
            else:
                self.state.update_register(rd_to_update, rd_wb_value)

        # Queue expected outputs
        self.state.queue_expected_outputs(expected_pc)

        if log:
            cocotb.log.info(
                f"{operation} x{rd}, {imm}(x{rs1}): addr=0x{address:08X}, "
                f"loaded=0x{rd_wb_value:08X}"
            )

        # Drive instruction
        self.dut_if.instruction = instr
        await RisingEdge(self.dut_if.clock)

        # Advance state
        self.state.increment_cycle_counter()
        self.state.increment_instret_counter()
        self.state.update_program_counter(expected_pc)
        self.state.advance_register_state()

        return rd_wb_value

    async def execute_store(
        self,
        operation: str,
        rs1: int,
        rs2: int,
        imm: int = 0,
        log: bool = False,
    ) -> None:
        """Execute a store instruction and model its effects.

        Args:
            operation: Store mnemonic ("sw", "sh", "sb")
            rs1: Base address register
            rs2: Data register
            imm: Immediate offset
            log: If True, log the store execution
        """
        from encoders.op_tables import STORES
        from cocotb_tests.cpu_model import CPUModel

        await FallingEdge(self.dut_if.clock)
        await self.dut_if.wait_ready()

        # Encode instruction
        encoder = STORES[operation]
        instr = encoder(rs2, rs1, imm)

        # Model memory write
        CPUModel.model_memory_write(
            self.state, self.mem_model, operation, rs1, rs2, imm
        )

        # Model expected behavior (stores don't write to register file)
        _, _, expected_pc, _ = CPUModel.model_instruction_execution(
            self.state, self.mem_model, operation, 0, rs1, rs2, imm, None, None
        )

        # Queue expected outputs (no register change for store)
        self.state.queue_expected_outputs(expected_pc)

        if log:
            address = (self.state.register_file_previous[rs1] + imm) & MASK32
            write_data = self.state.register_file_previous[rs2] & MASK32
            cocotb.log.info(
                f"{operation} x{rs2}, {imm}(x{rs1}): addr=0x{address:08X}, "
                f"data=0x{write_data:08X}"
            )

        # Drive instruction
        self.dut_if.instruction = instr
        await RisingEdge(self.dut_if.clock)

        # Advance state
        self.state.increment_cycle_counter()
        self.state.increment_instret_counter()
        self.state.update_program_counter(expected_pc)
        self.state.advance_register_state()

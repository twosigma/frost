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

"""Structured logging for instruction execution and debugging.

Formatters for the three kinds of line a test emits: one per retired
instruction, one per pipeline event, and the end-of-run coverage summary. Each
line leads with the simulation cycle so a log can be lined up with a waveform.
"""

import cocotb
from encoders.op_tables import LOADS, STORES, BRANCHES, JUMPS


class InstructionLogger:
    """Log-line formatters for RISC-V instruction execution."""

    @staticmethod
    def log_instruction_execution(
        cycle: int,
        operation: str,
        pc_current: int,
        pc_expected: int,
        destination_register: int | None,
        writeback_value: int,
        source_register_1: int,
        source_register_2: int,
        immediate: int | None = None,
        address: int | None = None,
        branch_taken: bool | None = None,
    ) -> None:
        """Log instruction execution with full context.

        Args:
            cycle: Current simulation cycle
            operation: Instruction mnemonic (e.g., "add", "lw")
            pc_current: Current PC value
            pc_expected: Expected next PC value
            destination_register: Destination register index (or None)
            writeback_value: Value being written to destination
            source_register_1: First source register index
            source_register_2: Second source register index
            immediate: Immediate value (if applicable)
            address: Memory address (for loads/stores)
            branch_taken: Branch decision (for branches)
        """
        parts = [
            f"[Cycle {cycle:5d}]",
            f"{operation:6s}",
            f"PC: 0x{pc_current:08x} → 0x{pc_expected:08x}",
        ]

        if destination_register is not None:
            parts.append(f"x{destination_register} ← 0x{writeback_value:08x}")

        parts.append(f"(x{source_register_1}, x{source_register_2})")

        if immediate is not None:
            parts.append(f"imm={immediate}")

        if address is not None:
            parts.append(f"@0x{address:08x}")

        if branch_taken is not None:
            parts.append(f"[{'TAKEN' if branch_taken else 'NOT-TAKEN'}]")

        cocotb.log.info(" ".join(parts))

    @staticmethod
    def log_pipeline_event(cycle: int, event: str, details: str = "") -> None:
        """Log pipeline events like stalls, flushes, or hazards.

        Args:
            cycle: Current simulation cycle
            event: Event name (e.g., "FLUSH", "STALL", "HAZARD")
            details: Additional details about the event
        """
        details_str = f": {details}" if details else ""
        cocotb.log.warning(f"[Cycle {cycle:5d}] PIPELINE {event}{details_str}")

    @staticmethod
    def log_branch_flush(cycle: int, pc: int) -> None:
        """Log branch flush event (NOP insertion).

        Args:
            cycle: Current simulation cycle
            pc: PC value where flush occurred
        """
        InstructionLogger.log_pipeline_event(
            cycle, "FLUSH", f"Branch misprediction at PC=0x{pc:08x}, inserting NOP"
        )

    @staticmethod
    def log_coverage_summary(
        instruction_counts: dict[str, int], threshold: int
    ) -> None:
        """Log instruction coverage summary.

        Args:
            instruction_counts: Dict mapping operation → execution count
            threshold: Minimum required execution count
        """
        cocotb.log.info("=" * 60)
        cocotb.log.info("INSTRUCTION COVERAGE SUMMARY")
        cocotb.log.info("=" * 60)

        alu_ops = []
        mem_ops = []
        branch_ops = []
        jump_ops = []

        for op, count in sorted(instruction_counts.items()):
            if op in LOADS or op in STORES:
                mem_ops.append((op, count))
            elif op in BRANCHES:
                branch_ops.append((op, count))
            elif op in JUMPS:
                jump_ops.append((op, count))
            else:
                alu_ops.append((op, count))

        for category, ops in [
            ("ALU Operations", alu_ops),
            ("Memory Operations", mem_ops),
            ("Branch Operations", branch_ops),
            ("Jump Operations", jump_ops),
        ]:
            if ops:
                cocotb.log.info(f"\n{category}:")
                for op, count in ops:
                    status = "✓" if count >= threshold else "✗"
                    cocotb.log.info(f"  {status} {op:10s}: {count:5d} executions")

        cocotb.log.info("=" * 60)

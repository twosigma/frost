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

"""Reference model for RISC-V conditional branches."""

from config import MASK32
from utils.riscv_utils import to_signed32
from utils.validation import ValidationError


def branch_taken_decision(operation: str, operand_a: int, operand_b: int) -> bool:
    """Return whether the branch condition is satisfied.

    The ordered comparisons look at the low 32 bits of each operand, while
    BEQ and BNE compare the values as passed.

    Args:
        operation: Branch mnemonic ("beq", "bne", "blt", "bge", "bltu", "bgeu")
        operand_a: Value from source register 1 (rs1)
        operand_b: Value from source register 2 (rs2)

    Returns:
        Whether the branch is taken.
    """
    if operation == "beq":
        return operand_a == operand_b
    if operation == "bne":
        return operand_a != operand_b
    if operation == "blt":  # signed
        return to_signed32(operand_a) < to_signed32(operand_b)
    if operation == "bge":  # signed
        return to_signed32(operand_a) >= to_signed32(operand_b)
    if operation == "bltu":  # unsigned
        return (operand_a & MASK32) < (operand_b & MASK32)
    if operation == "bgeu":  # unsigned
        return (operand_a & MASK32) >= (operand_b & MASK32)

    raise ValidationError(
        "Invalid branch operation",
        op=operation,
        valid_ops=["beq", "bne", "blt", "bge", "bltu", "bgeu"],
    )

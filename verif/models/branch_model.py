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

from utils.riscv_utils import to_signed_xlen, to_unsigned_xlen
from utils.validation import ValidationError


def branch_taken_decision(operation: str, operand_a: int, operand_b: int) -> bool:
    """Return whether the branch condition is satisfied.

    Every comparison uses the active XLEN, matching the integer register and
    branch-unit operand width.

    Args:
        operation: Branch mnemonic ("beq", "bne", "blt", "bge", "bltu", "bgeu")
        operand_a: Value from source register 1 (rs1)
        operand_b: Value from source register 2 (rs2)

    Returns:
        Whether the branch is taken.
    """
    unsigned_a = to_unsigned_xlen(operand_a)
    unsigned_b = to_unsigned_xlen(operand_b)

    if operation == "beq":
        return unsigned_a == unsigned_b
    if operation == "bne":
        return unsigned_a != unsigned_b
    if operation == "blt":  # signed
        return to_signed_xlen(operand_a) < to_signed_xlen(operand_b)
    if operation == "bge":  # signed
        return to_signed_xlen(operand_a) >= to_signed_xlen(operand_b)
    if operation == "bltu":  # unsigned
        return unsigned_a < unsigned_b
    if operation == "bgeu":  # unsigned
        return unsigned_a >= unsigned_b

    raise ValidationError(
        "Invalid branch operation",
        op=operation,
        valid_ops=["beq", "bne", "blt", "bge", "bltu", "bgeu"],
    )

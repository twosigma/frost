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

"""Software reference models used to predict DUT results.

Modules
-------
alu_model
    Reference implementations for all ALU operations including:
    - Base integer operations (add, sub, and, or, xor, shifts, comparisons)
    - M extension (mul, mulh, div, rem variants)
    - B extension (bit manipulation: clz, ctz, cpop, rotations, etc.)
    - Zicond extension (conditional zero)
    - Zbkb extension (crypto bit manipulation)

    Uses decorators for automatic result masking and shift limiting.

branch_model
    Branch decision logic for conditional branches:
    - BEQ, BNE, BLT, BGE, BLTU, BGEU
    - Proper signed/unsigned comparison handling

memory_model
    Data memory interface model:
    - Byte-addressable memory with little-endian ordering
    - Support for byte, halfword, and word accesses
    - Driver/monitor coroutine for memory write verification

``CPUModel`` uses these models to compute instruction results::

    from models.alu_model import add, sub
    from models.branch_model import branch_taken_decision

    result = add(operand_a=10, operand_b=20)  # Returns 30
    taken = branch_taken_decision("beq", 5, 5)  # Returns True
"""

from models.alu_model import add, sub, and_rv, or_rv, xor
from models.branch_model import branch_taken_decision
from models.memory_model import MemoryModel

__all__ = [
    "add",
    "sub",
    "and_rv",
    "or_rv",
    "xor",
    "branch_taken_decision",
    "MemoryModel",
]

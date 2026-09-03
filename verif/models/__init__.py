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
    Reference implementations of the ALU operations: base integer (add, sub,
    and, or, xor, shifts, comparisons), M (mul, mulh, div, rem), Zba address
    generation, Zbb bit manipulation (clz, ctz, cpop, rotations), Zbs
    single-bit ops, Zicond (conditional zero) and Zbkb (pack, brev8).
    Decorators mask results to XLEN and limit shift amounts.

branch_model
    Taken decision for BEQ, BNE, BLT, BGE, BLTU and BGEU, signed or unsigned
    as the mnemonic requires.

memory_model
    Byte-addressable, little-endian data memory with byte, word and dword
    accesses, plus a driver/monitor coroutine that checks DUT stores.

fp_model
    IEEE 754 reference models for the F and D extensions.

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

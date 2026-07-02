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

"""RISC-V instruction encoding utilities.

This package provides binary encoding for all RISC-V instructions supported
by the Frost CPU, including extensions.

Supported Extensions
--------------------
- RV32I: Base integer instruction set
- M: Integer multiply/divide
- A: Atomic memory operations (LR.W, SC.W, AMO*)
- B: Bit manipulation (Zba + Zbb + Zbs)
- C: Compressed 16-bit instructions
- Zicsr: CSR access instructions
- Zicntr: Base counters (cycle, time, instret)
- Zba: Address generation (sh1add, sh2add, sh3add)
- Zbb: Basic bit manipulation (clz, ctz, cpop, etc.)
- Zbs: Single-bit operations (bset, bclr, binv, bext)
- Zbkb: Crypto bit manipulation (pack, brev8, zip, unzip)
- Zicond: Conditional zero (czero.eqz, czero.nez)

Modules
-------
instruction_encode
    Encoders for 32-bit instruction formats (R, I, S, B, U, J types)

compressed_encode
    Encoders for 16-bit compressed instruction formats

op_tables
    Mapping tables from instruction mnemonics to encoders and evaluators.
    This is the primary interface for instruction generation.

Usage
-----
To encode an instruction by mnemonic::

    from encoders.op_tables import R_ALU, I_ALU, LOADS, STORES

    # Get encoder for 'add' instruction
    enc_add, eval_add = R_ALU["add"]
    binary = enc_add(rd=1, rs1=2, rs2=3)  # add x1, x2, x3

    # Get encoder for 'lw' instruction
    enc_lw, eval_lw = LOADS["lw"]
    binary = enc_lw(rd=5, rs1=10, imm=16)  # lw x5, 16(x10)
"""

# Re-export the main instruction tables for convenience
from encoders.op_tables import (
    R_ALU,
    I_ALU,
    LOADS,
    STORES,
    BRANCHES,
    JUMPS,
    CSRS,
)

__all__ = [
    "R_ALU",
    "I_ALU",
    "LOADS",
    "STORES",
    "BRANCHES",
    "JUMPS",
    "CSRS",
]

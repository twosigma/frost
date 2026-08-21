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

"""Type aliases and ``NewType`` wrappers used by verification code."""

from typing import NewType

# Memory-related types
Address = NewType("Address", int)
"""32-bit memory address (0 to 2^32-1)."""

ByteOffset = NewType("ByteOffset", int)
"""Byte offset within a word (0-3)."""

ByteMask = NewType("ByteMask", int)
"""4-bit byte enable mask (0b0000 to 0b1111)."""

# Register-related types
RegisterIndex = NewType("RegisterIndex", int)
"""RISC-V register index (0-31, where 0 is hardwired to zero)."""

RegisterValue = NewType("RegisterValue", int)
"""32-bit register value."""

# Instruction-related types
Instruction = NewType("Instruction", int)
"""32-bit encoded RISC-V instruction."""

Immediate = NewType("Immediate", int)
"""Immediate value for I-type instructions."""

Offset = NewType("Offset", int)
"""Branch or jump offset."""

ProgramCounter = NewType("ProgramCounter", int)
"""Program counter value (32-bit address)."""

# Cycle counter
CycleCount = NewType("CycleCount", int)
"""Simulation cycle counter."""

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

"""``NewType`` wrappers for integer quantities in verification code."""

from typing import NewType

# Memory-related types
Address = NewType("Address", int)
"""32-bit memory address (0 to 2^32-1)."""

ByteOffset = NewType("ByteOffset", int)
"""Byte offset within an aligned 64-bit data beat (0-7)."""

ByteMask = NewType("ByteMask", int)
"""Byte-lane mask for a 64-bit data beat (0x00 to 0xFF)."""

# Register-related types
RegisterIndex = NewType("RegisterIndex", int)
"""RISC-V register index (0-31, where 0 is hardwired to zero)."""

RegisterValue = NewType("RegisterValue", int)
"""XLEN-bit (64-bit) register value."""

# Instruction-related types
Instruction = NewType("Instruction", int)
"""32-bit encoded RISC-V instruction."""

Immediate = NewType("Immediate", int)
"""Immediate value for I-type instructions."""

Offset = NewType("Offset", int)
"""Branch or jump offset."""

ProgramCounter = NewType("ProgramCounter", int)
"""Program counter value (XLEN bits)."""

# Cycle counter
CycleCount = NewType("CycleCount", int)
"""Simulation cycle counter."""

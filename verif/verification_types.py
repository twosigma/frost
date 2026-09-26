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

Address = NewType("Address", int)
"""Byte address (XLEN bits)."""

RegisterIndex = NewType("RegisterIndex", int)
"""Register index (0-31); integer register x0 is hardwired to zero."""

Instruction = NewType("Instruction", int)
"""32-bit encoded RISC-V instruction."""

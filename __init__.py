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

"""FROST - RISC-V processor package.

This package contains a complete RV32GCB (G = IMAFD) RISC-V processor
implementation with full machine-mode support and additional extensions
(Zicsr, Zicntr, Zifencei, Zicond, Zbkb, and Zihintpause), along with
verification infrastructure, build tools, and software libraries.

Note: B extension = Zba + Zbb + Zbs (address generation, basic bit manipulation,
single-bit operations).
"""

from ._version import __version__

__all__ = [
    "__version__",
]

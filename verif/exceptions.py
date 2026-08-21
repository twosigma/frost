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

"""Verification-specific exceptions."""


class VerificationError(Exception):
    """Base class that lets callers catch all verification failures."""


class AlignmentError(VerificationError):
    """Memory alignment violation.

    Raised when memory access violates alignment requirements:
    - Halfword (2-byte) accesses must be 2-byte aligned
    - Word (4-byte) accesses must be 4-byte aligned
    """

    def __init__(
        self,
        message: str,
        address: int | None = None,
        required_alignment: int | None = None,
    ):
        """Initialize an alignment error.

        Args:
            message: Error description.
            address: Misaligned address.
            required_alignment: Required alignment in bytes (2 or 4).
        """
        super().__init__(message)
        self.address = address
        self.required_alignment = required_alignment

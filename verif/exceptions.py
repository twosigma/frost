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

"""Custom exceptions for verification errors.

Exceptions
==========

This module defines a hierarchy of exception types for different verification
failure scenarios, providing better error categorization and handling:

- VerificationError: base class for all verification failures
- AlignmentError: memory alignment violation
"""


class VerificationError(Exception):
    """Base exception for all verification-related failures.

    All verification-specific exceptions inherit from this base class,
    allowing callers to catch all verification errors with a single handler.
    """


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
        """Initialize alignment error with context.

        Args:
            message: Error description
            address: The misaligned address that caused the error
            required_alignment: Required alignment in bytes (2 or 4)
        """
        super().__init__(message)
        self.address = address
        self.required_alignment = required_alignment

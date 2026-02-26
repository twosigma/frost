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

"""Golden model for the FU CDB Adapter.

Mirrors the RTL holding register + combinational pass-through logic.
Tracks result_pending state and held_result register across clock cycles.
"""

from dataclasses import dataclass

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
FLEN = 64
EXC_CAUSE_WIDTH = 5
FP_FLAGS_WIDTH = 5

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK64 = (1 << FLEN) - 1


@dataclass
class FuComplete:
    """FU completion result (mirrors fu_complete_t)."""

    valid: bool = False
    tag: int = 0
    value: int = 0
    exception: bool = False
    exc_cause: int = 0
    fp_flags: int = 0

    def copy(self) -> "FuComplete":
        """Return a shallow copy."""
        return FuComplete(
            valid=self.valid,
            tag=self.tag,
            value=self.value,
            exception=self.exception,
            exc_cause=self.exc_cause,
            fp_flags=self.fp_flags,
        )


@dataclass
class AdapterOutput:
    """Output of one adapter step."""

    fu_complete: FuComplete
    result_pending: bool


class FuCdbAdapterModel:
    """Golden model for the FU CDB adapter holding register."""

    def __init__(self) -> None:
        """Initialize to idle state."""
        self.result_pending: bool = False
        self.held_result: FuComplete = FuComplete()

    def reset(self) -> None:
        """Reset to idle state."""
        self.result_pending = False
        self.held_result = FuComplete()

    def get_output(self, fu_result: FuComplete) -> AdapterOutput:
        """Get combinational output (before clock edge).

        Args:
            fu_result: Current FU result input.

        Returns:
            AdapterOutput with the current output and pending state.
        """
        if self.result_pending:
            out = self.held_result.copy()
        else:
            out = fu_result.copy()
        return AdapterOutput(fu_complete=out, result_pending=self.result_pending)

    def step(self, fu_result: FuComplete, grant: bool, flush: bool) -> None:
        """Advance one clock cycle (posedge logic).

        Args:
            fu_result: FU result input during this cycle.
            grant: CDB arbiter grant signal.
            flush: Pipeline flush signal.
        """
        if flush:
            self.result_pending = False
            self.held_result = FuComplete()
        elif self.result_pending and grant:
            if fu_result.valid:
                # Back-to-back: grant old, latch new
                self.held_result = fu_result.copy()
                self.result_pending = True
            else:
                # Granted, go idle
                self.result_pending = False
        elif not self.result_pending and fu_result.valid and not grant:
            # Pass-through failed, latch
            self.held_result = fu_result.copy()
            self.result_pending = True

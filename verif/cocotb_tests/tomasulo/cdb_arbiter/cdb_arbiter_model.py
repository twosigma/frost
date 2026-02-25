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

"""Golden model for the CDB Arbiter.

Mirrors the RTL priority-based arbitration logic. Given a list of FU completion
requests, selects the highest-priority valid request and returns the CDB
broadcast result plus per-FU grant vector.
"""

from dataclasses import dataclass

# Width constants from riscv_pkg
ROB_TAG_WIDTH = 5
FLEN = 64

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK64 = (1 << FLEN) - 1

# FU type constants (mirrors riscv_pkg::fu_type_e)
FU_ALU = 0
FU_MUL = 1
FU_DIV = 2
FU_MEM = 3
FU_FP_ADD = 4
FU_FP_MUL = 5
FU_FP_DIV = 6

NUM_FUS = 7

# Priority order: highest priority first (longest latency)
PRIORITY_ORDER = [FU_FP_DIV, FU_DIV, FU_FP_MUL, FU_MUL, FU_FP_ADD, FU_MEM, FU_ALU]


@dataclass
class FuComplete:
    """FU completion request (mirrors fu_complete_t)."""

    valid: bool = False
    tag: int = 0
    value: int = 0
    exception: bool = False
    exc_cause: int = 0
    fp_flags: int = 0


@dataclass
class CdbBroadcast:
    """CDB broadcast output (mirrors cdb_broadcast_t)."""

    valid: bool = False
    tag: int = 0
    value: int = 0
    exception: bool = False
    exc_cause: int = 0
    fp_flags: int = 0
    fu_type: int = 0


class CdbArbiterModel:
    """Golden model for CDB arbiter priority arbitration."""

    def arbitrate(
        self,
        fu_completes: list[FuComplete],
    ) -> tuple[CdbBroadcast, list[bool]]:
        """Arbitrate among FU completion requests.

        Args:
            fu_completes: List of NUM_FUS FuComplete requests, indexed by fu_type_e.

        Returns:
            Tuple of (CdbBroadcast, grants) where grants is a list of NUM_FUS bools.
        """
        assert len(fu_completes) == NUM_FUS

        grants = [False] * NUM_FUS
        cdb = CdbBroadcast()

        for fu_idx in PRIORITY_ORDER:
            req = fu_completes[fu_idx]
            if req.valid:
                grants[fu_idx] = True
                cdb.valid = True
                cdb.tag = req.tag & MASK_TAG
                cdb.value = req.value & MASK64
                cdb.exception = req.exception
                cdb.exc_cause = req.exc_cause & 0x1F
                cdb.fp_flags = req.fp_flags & 0x1F
                cdb.fu_type = fu_idx
                break

        return cdb, grants

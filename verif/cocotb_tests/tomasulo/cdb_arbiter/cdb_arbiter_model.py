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

# Priority order: highest priority first (CoreMark-relevant traffic first)
PRIORITY_ORDER = [FU_MUL, FU_MEM, FU_ALU, FU_DIV, FU_FP_DIV, FU_FP_MUL, FU_FP_ADD]


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


def _broadcast_from(req: FuComplete, fu_idx: int) -> CdbBroadcast:
    """Pack an FU completion request into a CDB broadcast."""
    return CdbBroadcast(
        valid=True,
        tag=req.tag & MASK_TAG,
        value=req.value & MASK64,
        exception=req.exception,
        exc_cause=req.exc_cause & 0x1F,
        fp_flags=req.fp_flags & 0x1F,
        fu_type=fu_idx,
    )


class CdbArbiterModel:
    """Golden model for CDB arbiter priority arbitration (2-wide CDB).

    Lane 0 = highest-priority valid request; lane 1 = highest-priority valid
    request among those lane 0 did not take. Both winners are granted, so the
    grant vector is 2-hot when two or more FUs request the CDB.
    """

    def arbitrate(
        self,
        fu_completes: list[FuComplete],
    ) -> tuple[CdbBroadcast, CdbBroadcast, list[bool]]:
        """Arbitrate among FU completion requests.

        Args:
            fu_completes: List of NUM_FUS FuComplete requests, indexed by fu_type_e.

        Returns:
            Tuple of (lane0_cdb, lane1_cdb, grants). lane1_cdb.valid is False when
            fewer than two FUs request the CDB. grants is a list of NUM_FUS bools
            (up to two set).
        """
        assert len(fu_completes) == NUM_FUS

        grants = [False] * NUM_FUS
        cdb = CdbBroadcast()
        cdb_2 = CdbBroadcast()

        lane0_idx = None
        for fu_idx in PRIORITY_ORDER:
            if fu_completes[fu_idx].valid:
                lane0_idx = fu_idx
                grants[fu_idx] = True
                cdb = _broadcast_from(fu_completes[fu_idx], fu_idx)
                break

        # Lane 1: next-highest-priority valid request, excluding lane 0's winner.
        for fu_idx in PRIORITY_ORDER:
            if fu_idx != lane0_idx and fu_completes[fu_idx].valid:
                grants[fu_idx] = True
                cdb_2 = _broadcast_from(fu_completes[fu_idx], fu_idx)
                break

        return cdb, cdb_2, grants

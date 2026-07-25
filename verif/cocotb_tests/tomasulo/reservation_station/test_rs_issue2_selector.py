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

"""Direct tests for the isolated balanced second-issue selector."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer

DEPTH = 16
MASK = (1 << DEPTH) - 1


def reference_select(ready: int, branch_class: int) -> int | None:
    """Return the canonical serial implementation's second-port index."""
    issue = next((i for i in range(DEPTH) if ready & (1 << i)), None)
    return next(
        (
            i
            for i in range(DEPTH)
            if ready & (1 << i) and not (branch_class & (1 << i)) and i != issue
        ),
        None,
    )


async def check_vector(dut: Any, ready: int, branch_class: int) -> None:
    """Drive one arbitrary vector and compare all outputs with the oracle."""
    ready &= MASK
    branch_class &= MASK
    expected_issue_2 = reference_select(ready, branch_class)

    dut.i_ready.value = ready
    dut.i_branch_class.value = branch_class
    await Timer(1, unit="ns")

    assert bool(dut.o_issue_2_valid.value) == (expected_issue_2 is not None)
    assert int(dut.o_issue_2_idx.value) == (
        expected_issue_2 if expected_issue_2 is not None else 0
    )
    assert int(dut.o_issue_2_onehot.value) == (
        1 << expected_issue_2 if expected_issue_2 is not None else 0
    )


@cocotb.test()
async def test_balanced_issue2_matches_serial_reference(dut: Any) -> None:
    """Cross-check empty, branch, backpressure-contract, and dense vectors."""
    directed = (
        (0x0000, 0x0000),  # empty
        (0x0001, 0x0000),  # only global winner
        (0x0001, 0x0001),  # only global winner is a branch
        (0x0003, 0x0000),  # second nonbranch
        (0x0003, 0x0001),  # branch winner, nonbranch fallback
        (0x0003, 0x0002),  # exclude winner, later branch is ineligible
        (0x8001, 0x0001),  # branch winner across tree halves
        (0xC000, 0x4000),  # high-half winner/exclusion
        (0xFFFF, 0x5555),  # dense alternating branches
        (0xFFFF, 0xAAAA),
        (0xFFFF, 0xFFFF),  # no eligible second port
    )
    for ready, branch_class in directed:
        await check_vector(dut, ready, branch_class)

    # Exhaust all three meaningful states (not ready / ready nonbranch / ready
    # branch) across the low eight leaves. This exercises every merge shape in
    # one complete half of the production tree. The standalone formal target
    # proves all unconstrained full-width input vectors.
    for ternary_vector in range(3**8):
        ready = 0
        branch_class = 0
        encoded = ternary_vector
        for i in range(8):
            state = encoded % 3
            encoded //= 3
            if state:
                ready |= 1 << i
            if state == 2:
                branch_class |= 1 << i
        await check_vector(dut, ready, branch_class)

    # The legacy exclusion applies to port 0's selected entry regardless of
    # whether backpressure lets port 0 fire. There is intentionally no ready
    # input from either FU here: every ordered winner/candidate location is
    # checked under that unconditional contract.
    for winner in range(DEPTH):
        for candidate in range(winner + 1, DEPTH):
            await check_vector(dut, (1 << winner) | (1 << candidate), 0)
            await check_vector(
                dut,
                (1 << winner) | (1 << candidate),
                1 << winner,
            )

    rng = random.Random(0x152BA1A)
    for _ in range(8192):
        await check_vector(dut, rng.getrandbits(DEPTH), rng.getrandbits(DEPTH))

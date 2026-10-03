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

"""Tests for rs_issue2_selector, the balanced-tree selector for INT_RS port 1.

The DUT is the standalone 16-entry selector, compared against a serial
reference.
"""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer

DEPTH = 16
MASK = (1 << DEPTH) - 1


def reference_select(ready: int, branch_class: int) -> int | None:
    """Return port 1's pick: the lowest ready non-branch entry other than port 0's.

    Port 0 picks the lowest ready entry, branch or not.
    """
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
    """Drive one input vector and compare all outputs with the reference."""
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
    """Compare with the serial reference on directed, exhaustive, and random vectors."""
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

    # Enumerate the three states (not ready, ready non-branch, ready branch)
    # of each of the low eight entries. That covers every merge case in one
    # half of this 16-entry tree; the rs_issue2_selector formal target proves
    # every full-width input.
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

    # Port 1 excludes port 0's pick even when back-pressure stops port 0 from
    # firing; the selector has no FU-ready input. Check every ordered pair of
    # port-0 pick and port-1 candidate positions.
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

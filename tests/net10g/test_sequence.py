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

"""Clause 49 Figure 49-15 receive sequencing and prescient termination checks.

Primary state-diagram source (page 29), using the unchanged Clause 49 receive
state transitions, not the separate proposed KR CRC8 extension:
https://www.ieee802.org/3/ap/public/sep05/szczepanek_02_0905.pdf
"""

import itertools
import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


ERROR = 0xFEFEFEFEFEFEFEFE
# Five independently specified block classes in the state diagram.
WORDS = {
    "C": (0x0707070707070707, 0xFF, 0),
    "S": (0xD5555555555555FB, 0x01, 0),
    "D": (0x0123456789ABCDEF, 0x00, 0),
    "T": (0x07070707070707FD, 0xFF, 0),
    "E": (ERROR, 0xFF, 1),
}
# Allowed transitions from the diagram. State INIT is equivalent to C for
# processing; the root PCS independently supplies Local Fault during reset.
TRANSITIONS = {
    ("C", "C"): "C",
    ("C", "S"): "D",
    ("T", "C"): "C",
    ("T", "S"): "D",
    ("D", "D"): "D",
    ("D", "T"): "T",
    ("E", "C"): "C",
    ("E", "D"): "D",
    ("E", "T"): "T",
}


async def edge(
    dut: Any,
    word: tuple[int, int, int] = WORDS["C"],
    enable: bool = True,
    reset: bool = False,
) -> None:
    """Apply a decoded block or a paused cycle."""
    dut.clk.value = 0
    dut.rst.value = reset
    dut.enable.value = enable
    dut.xgmii_data.value, dut.xgmii_ctrl.value, dut.bad_block.value = word
    await Timer(5, unit="ns")
    dut.clk.value = 1
    await Timer(5, unit="ns")


def next_state(previous: str, current: str, lookahead: str) -> str:
    """Evaluate the state diagram's transitions and R_TYPE_NEXT guard."""
    result = TRANSITIONS.get((previous, current), "E")
    if result == "T" and lookahead not in ("C", "S"):
        return "E"
    return result


@cocotb.test()
async def all_short_sequences(dut: Any) -> None:
    """Exhaust every four-block class sequence with a separate transition table."""
    for sequence in itertools.product(WORDS, repeat=4):
        await edge(dut, reset=True)
        state = "C"
        previous: str | None = None
        for kind in sequence:
            await edge(dut, WORDS[kind])
            if previous is None:
                assert not int(dut.valid.value)
            else:
                state = next_state(state, previous, kind)
                assert int(dut.valid.value)
                expected = (ERROR, 255) if state == "E" else WORDS[previous][:2]
                assert (
                    int(dut.checked_data.value),
                    int(dut.checked_ctrl.value),
                ) == expected, sequence
                assert int(dut.bad_sequence.value) == (state == "E"), sequence
            previous = kind


@cocotb.test()
async def termination_lookahead_stalls_and_reset(dut: Any) -> None:
    """Hold pending termination through pauses; reset must discard the pending word."""
    for following in ("C", "S", "D", "T", "E"):
        await edge(dut, reset=True)
        for kind in ("C", "S", "D", "T"):
            await edge(dut, WORDS[kind])
        # The pending T has not been emitted, so a MAC cannot yet commit it.
        assert int(dut.checked_ctrl.value) == 0
        for _ in range(50):
            await edge(dut, WORDS["C"], enable=False)
            assert not int(dut.valid.value)
            assert not int(dut.bad_sequence.value)
        await edge(dut, WORDS[following])
        assert int(dut.valid.value)
        assert int(dut.checked_data.value) == (
            WORDS["T"][0] if following in ("C", "S") else ERROR
        )
        assert int(dut.bad_sequence.value) == (following not in ("C", "S"))

    await edge(dut, reset=True)
    await edge(dut, WORDS["S"])
    await edge(dut, WORDS["T"])
    await edge(dut, reset=True)
    await edge(dut, WORDS["C"])
    assert not int(dut.valid.value)
    await edge(dut, WORDS["C"])
    assert int(dut.valid.value) and not int(dut.bad_sequence.value)


@cocotb.test()
async def decoded_control_classification(dut: Any) -> None:
    """Distinguish explicit /E/ and data bytes from classifying control characters."""
    rng = random.Random(4915)
    # Unlike all-C blocks, /E/ in the C fields of OS, S, and T blocks does not
    # change the R_BLOCK_TYPE. This is the standard's explicit classification.
    special_words = [
        ("E", (0x070707FE07070707, 0xFF, 0)),
        ("C", (0x070707FE0100009C, 0xF1, 0)),
        ("S", (0xD55555FB070707FE, 0x1F, 0)),
        ("T", (0x070707070707FEFD, 0xFF, 0)),
        ("D", (0xFEFDFB9CFDFBFEFE, 0x00, 0)),
        ("E", (0x0123456789ABCDEF, 0x00, 1)),
    ]
    await edge(dut, reset=True)
    state = "C"
    previous: tuple[str, tuple[int, int, int]] | None = None
    for _ in range(1000):
        kind, word = rng.choice(special_words + [(k, v) for k, v in WORDS.items()])
        if rng.randrange(4) == 0:
            await edge(dut, word, enable=False)
            assert not int(dut.valid.value)
        await edge(dut, word)
        if previous is not None:
            state = next_state(state, previous[0], kind)
            expected = (ERROR, 255) if state == "E" else previous[1][:2]
            assert int(dut.valid.value)
            assert (
                int(dut.checked_data.value),
                int(dut.checked_ctrl.value),
            ) == expected
            assert int(dut.bad_sequence.value) == (state == "E")
        previous = kind, word

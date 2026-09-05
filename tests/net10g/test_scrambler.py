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

"""Serial-history reference, published vectors, stalls and error propagation."""

import random

import cocotb
from typing import Any
from cocotb.triggers import Timer


class SerialReference:
    """Track chronological scrambled wire bits, independent of RTL shift direction."""

    def __init__(self, descramble: bool = False) -> None:
        """Seed the serial history with the agreed all-ones reset state."""
        self.bits = [1] * 58
        self.descramble = descramble

    def word(self, value: int) -> int:
        """Process one word in chronological wire-bit order."""
        result = 0
        for index in range(64):
            incoming = (value >> index) & 1
            outgoing = incoming ^ self.bits[-39] ^ self.bits[-58]
            result |= outgoing << index
            self.bits.append(incoming if self.descramble else outgoing)
        return result


async def edge(
    dut: Any, tx: int = 0, rx: int = 0, enable: int = 1, reset: int = 0
) -> None:
    """Drive one enabled or paused cycle and wait for registered outputs."""
    dut.clk.value = 0
    dut.rst.value = reset
    dut.enable.value = enable
    dut.tx_data.value = tx
    dut.rx_data.value = rx
    await Timer(5, unit="ns")
    dut.clk.value = 1
    await Timer(5, unit="ns")


@cocotb.test()
async def published_scrambled_vectors(dut: Any) -> None:
    """Check ten published scrambled payloads and their inverse."""
    # Rick Walker's published Clause 49 implementation vectors. Payload octets
    # are listed in transmission order, each byte sent LSB first.
    # https://www.ieee802.org/3/10G_study/email/msg03521.html
    vectors = [
        "1e 00 4f 6b 36 5c e5 2d",
        "2b 27 4c 40 50 ac 3e 7b",
        "a2 18 18 b5 3a 07 7a f4",
        "26 fd 98 bc d0 d7 35 26",
        "b4 8b 56 33 fa a1 47 8a",
        "29 a7 52 a0 f4 26 e0 7e",
        "d2 30 dd c9 12 45 f9 56",
        "b9 fd ca 5c 09 95 bf 71",
        "46 af f6 91 da f1 0b 13",
        "eb 37 f0 84 f8 76 cd 25",
    ]
    raw = 0xF19AACB66B4F001E
    await edge(dut, reset=1)
    for vector in vectors:
        expected = int.from_bytes(bytes.fromhex(vector), "little")
        await edge(dut, raw, expected)
        assert int(dut.scrambled.value) == expected
        assert int(dut.descrambled.value) == raw


@cocotb.test()
async def serial_reference_reset_and_enable(dut: Any) -> None:
    """Compare independent serial references through stalls and resets."""
    rng = random.Random(0x5839)
    tx_ref, rx_ref = SerialReference(), SerialReference(True)
    tx_expected = rx_expected = 0
    await edge(dut, reset=1)
    for cycle in range(1800):
        reset = cycle in (101, 701, 1153)
        enabled = rng.randrange(4) != 0
        tx_data, rx_data = rng.getrandbits(64), rng.getrandbits(64)
        if reset:
            tx_ref, rx_ref = SerialReference(), SerialReference(True)
            tx_expected = rx_expected = 0
        elif enabled:
            tx_expected, rx_expected = tx_ref.word(tx_data), rx_ref.word(rx_data)
        await edge(dut, tx_data, rx_data, enabled, reset)
        assert int(dut.scrambled.value) == tx_expected, cycle
        assert int(dut.descrambled.value) == rx_expected, cycle


@cocotb.test()
async def channel_error_self_synchronization(dut: Any) -> None:
    """Verify three-error propagation and convergence after 58 input bits."""
    rng = random.Random(0xBAD39)
    tx_ref = SerialReference()
    await edge(dut, reset=1)
    raw_words = [rng.getrandbits(64) for _ in range(16)]
    injection_bit = 3 * 64 + 61
    actual_words = []
    for index, raw in enumerate(raw_words):
        channel = tx_ref.word(raw)
        if index == injection_bit // 64:
            channel ^= 1 << (injection_bit % 64)
        await edge(dut, raw, channel)
        actual_words.append(int(dut.descrambled.value))
    errors: list[int] = []
    for index, (actual, expected) in enumerate(zip(actual_words, raw_words)):
        errors.extend(
            index * 64 + bit for bit in range(64) if ((actual ^ expected) >> bit) & 1
        )
    assert errors == [injection_bit, injection_bit + 39, injection_bit + 58]

    # Joining an arbitrary already-running stream converges after 58 wire bits.
    await edge(dut, reset=1)
    for index in range(5):
        raw = rng.getrandbits(64)
        await edge(dut, rx=tx_ref.word(raw))
        observed = int(dut.descrambled.value)
        assert observed >> (58 if index == 0 else 0) == raw >> (58 if index == 0 else 0)

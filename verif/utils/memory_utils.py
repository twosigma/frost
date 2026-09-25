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

"""Memory access helpers.

The data replication a store needs on the 64-bit data-tier beat.
"""

from config import (
    MASK32,
    MASK64,
)


def replicate_store_data_for_beat(operation: str, value: int) -> int:
    """Replicate store data across the 64-bit beat, per the data-tier bus contract.

    The RTL replicates sub-beat store data across all 64 bits and lets the byte
    strobes pick the addressed lanes: {8{byte}}, {4{half}}, {2{word}}, dword
    pass-through, in store_queue.gen_write_data. The expected-write monitor
    compares the whole beat, so this model reproduces the replication rather
    than zeroing the unselected lanes.

    Args:
        operation: Store operation ("sb", "sh", "sw", "fsw", or "fsd")
        value: Store data (low bits used per the operation's size)

    Returns:
        64-bit beat image with the data replicated across the beat

    Examples:
        >>> hex(replicate_store_data_for_beat("sb", 0xAB))
        '0xabababababababab'
        >>> hex(replicate_store_data_for_beat("sh", 0x1234))
        '0x1234123412341234'
        >>> hex(replicate_store_data_for_beat("sw", 0xDEADBEEF))
        '0xdeadbeefdeadbeef'
        >>> hex(replicate_store_data_for_beat("fsd", 0x0123456789ABCDEF))
        '0x123456789abcdef'
    """
    if operation == "sb":
        byte = value & 0xFF
        return int.from_bytes(bytes([byte]) * 8, "little")

    elif operation == "sh":
        half = value & 0xFFFF
        return half | half << 16 | half << 32 | half << 48

    elif operation in ("sw", "fsw"):
        word = value & MASK32
        return word | word << 32

    elif operation == "fsd":
        return value & MASK64

    else:
        raise ValueError(f"Unknown store operation: {operation}")

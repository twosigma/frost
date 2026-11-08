# Copyright (c) 2026 John Goodacre.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Loop bodies of the board memory benchmarks, as model micro-ops.

The kernels follow the timed loops of a single-purpose stream program
(sequential reads, strided reads, sequential writes and a dependent chase
over a random permutation of 64-byte lines) and a STREAM-style membench
(unrolled integer write and copy loops, which libc memset and memcpy match
on the board, and a dependent chase over a 256 KiB ring). Each body keeps
the compiled loop's data addresses, dependencies and instruction count per
access; arithmetic and branches are representative. A body describes one
pass over a buffer far larger than the L2, so the board calibration starts
it with every cache full of unrelated lines and measures its steady state.
"""

from __future__ import annotations

import random
from collections.abc import Callable
from typing import Any, Protocol


class Builder(Protocol):
    """The part of the model's ProgramBuilder that the kernels use."""

    def emit(
        self,
        kind: str,
        fetch_address: int,
        data_address: int | None = None,
        depends_on: Any = (),
        mispredict: bool = False,
    ) -> int:
        """Append a micro-op and return its ID."""
        ...


CODE = 0x8000_2000
DATA = 0x9000_0000  # cold DDR, away from the preconditioned lines
COPY_DESTINATION = DATA + 0x0200_0000


def stream_read(b: Builder, count: int) -> None:
    """``sink += a[i]``: ld, add, addi, bne for each 8-byte load."""
    ptr = b.emit("alu", CODE)
    acc = b.emit("alu", CODE + 4)
    for index in range(count):
        load = b.emit("load", CODE + 16, DATA + 8 * index, (ptr,))
        acc = b.emit("alu", CODE + 20, depends_on=(load, acc))
        ptr = b.emit("alu", CODE + 24, depends_on=(ptr,))
        b.emit("branch", CODE + 28, depends_on=(ptr,))


def stream_stride(b: Builder, count: int, stride: int) -> None:
    """``sink += a[i]`` every stride bytes: five instructions for each load."""
    ptr = b.emit("alu", CODE)
    acc = b.emit("alu", CODE + 4)
    for index in range(count):
        load = b.emit("load", CODE + 16, DATA + stride * index, (ptr,))
        acc = b.emit("alu", CODE + 20, depends_on=(load, acc))
        ptr = b.emit("alu", CODE + 24, depends_on=(ptr,))
        b.emit("alu", CODE + 28, depends_on=(ptr,))
        b.emit("branch", CODE + 32, depends_on=(ptr,))


def stream_write(b: Builder, count: int) -> None:
    """``a[i] = i``: sd, addi, addi, bne for each 8-byte store."""
    ptr = b.emit("alu", CODE)
    value = b.emit("alu", CODE + 4)
    for index in range(count):
        b.emit("store", CODE + 16, DATA + 8 * index, (ptr, value))
        value = b.emit("alu", CODE + 20, depends_on=(value,))
        ptr = b.emit("alu", CODE + 24, depends_on=(ptr,))
        b.emit("branch", CODE + 28, depends_on=(ptr,))


def int_write(b: Builder, count: int) -> None:
    """Membench int-write, unrolled by four: four sd, addi, bne."""
    ptr = b.emit("alu", CODE)
    value = b.emit("alu", CODE + 4)
    for index in range(0, count, 4):
        for lane in range(4):
            b.emit(
                "store", CODE + 16 + 4 * lane, DATA + 8 * (index + lane), (ptr, value)
            )
        ptr = b.emit("alu", CODE + 32, depends_on=(ptr,))
        b.emit("branch", CODE + 36, depends_on=(ptr,))


def int_copy(b: Builder, count: int) -> None:
    """Membench int-copy, unrolled by four: four ld, four sd, two addi, bne."""
    src = b.emit("alu", CODE)
    dst = b.emit("alu", CODE + 4)
    for index in range(0, count, 4):
        loads = [
            b.emit("load", CODE + 16 + 4 * lane, DATA + 8 * (index + lane), (src,))
            for lane in range(4)
        ]
        for lane in range(4):
            b.emit(
                "store",
                CODE + 32 + 4 * lane,
                COPY_DESTINATION + 8 * (index + lane),
                (loads[lane], dst),
            )
        src = b.emit("alu", CODE + 48, depends_on=(src,))
        dst = b.emit("alu", CODE + 52, depends_on=(dst,))
        b.emit("branch", CODE + 56, depends_on=(src,))


def chase(b: Builder, addresses: list[int]) -> None:
    """``p = a[p]``: slli, add, ld in a chain, with addi and bne beside it."""
    p = b.emit("alu", CODE)
    i = b.emit("alu", CODE + 4)
    for address in addresses:
        shifted = b.emit("alu", CODE + 16, depends_on=(p,))
        pointer = b.emit("alu", CODE + 20, depends_on=(shifted,))
        p = b.emit("load", CODE + 24, address, (pointer,))
        i = b.emit("alu", CODE + 28, depends_on=(i,))
        b.emit("branch", CODE + 32, depends_on=(i,))


def dram_chase(b: Builder, hops: int) -> None:
    """stream.c chase: one load per 64-byte line of a random 64 MiB cycle."""
    lines = random.Random(1).sample(range((64 << 20) // 64), hops)
    chase(b, [DATA + 64 * line for line in lines])


L2_RING_LINES = (256 << 10) // 64


def l2_chase(b: Builder, hops: int) -> None:
    """Membench latency-L2: the 256 KiB ring of 64-byte lines, in order."""
    chase(b, [DATA + 64 * (hop % L2_RING_LINES) for hop in range(hops)])


class Kernel:
    """A board benchmark body and how its steady state is measured."""

    def __init__(
        self,
        build: Callable[[Builder], None],
        accesses: int,
        bytes_per_access: int,
        metric: str,
        dirty: float = 0.0,
        warm_fraction: float = 0.25,
    ) -> None:
        """Describe a body of accesses loads or stores.

        bytes_per_access is the buffer span each access accounts for in the
        board's MB/s figure. metric is "MBps" for a stream or "ns" for a
        dependent chase. dirty is the share of preconditioned cache lines
        that are modified, as behind a long store stream. The measurement
        window starts once warm_fraction of the body has retired.
        """
        self.build = build
        self.accesses = accesses
        self.bytes_per_access = bytes_per_access
        self.metric = metric
        self.dirty = dirty
        self.warm_fraction = warm_fraction


KERNELS: dict[str, Kernel] = {
    "stream_read": Kernel(lambda b: stream_read(b, 6144), 6144, 8, "MBps"),
    "stride_16": Kernel(lambda b: stream_stride(b, 4096, 16), 4096, 16, "MBps"),
    "stride_32": Kernel(lambda b: stream_stride(b, 3072, 32), 3072, 32, "MBps"),
    "stride_64": Kernel(lambda b: stream_stride(b, 2048, 64), 2048, 64, "MBps"),
    "stride_128": Kernel(lambda b: stream_stride(b, 1536, 128), 1536, 128, "MBps"),
    "stream_write": Kernel(lambda b: stream_write(b, 4096), 4096, 8, "MBps", 1.0),
    "memset": Kernel(lambda b: int_write(b, 4096), 4096, 8, "MBps", 1.0),
    # memcpy reports twice the copied bytes, a read and a write of each.
    "memcpy": Kernel(lambda b: int_copy(b, 3072), 3072, 16, "MBps", 0.5),
    "dram_chase": Kernel(lambda b: dram_chase(b, 600), 600, 64, "ns"),
    # Two passes fill the L2 with the ring; the window covers the rest.
    "l2_chase": Kernel(
        lambda b: l2_chase(b, 2 * L2_RING_LINES + 1024),
        2 * L2_RING_LINES + 1024,
        64,
        "ns",
        warm_fraction=L2_RING_LINES / (2 * L2_RING_LINES + 1024),
    ),
}

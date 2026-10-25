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

"""Address and dependency generators for the DDR benchmark kernels.

The generators represent timed loop bodies with cold data and warm code.
Arithmetic represents address generation, accumulators, and loop control;
it is not an instruction trace of a compiled binary. DDR bench data is
zero, as in the behavioral memory. The MLP probe contains its seeded ring.
"""

from typing import Any


KERNELS = (
    "ddr_mlp_independent",
    "ddr_mlp_chase",
    "ddr_mlp_store",
    "ddr_bench_seq_read",
    "ddr_bench_stride_read",
    "ddr_bench_streams_read",
    "ddr_bench_streams_aliased_read",
    "ddr_bench_random_read",
    "ddr_bench_record_read",
    "ddr_bench_chase",
    "ddr_bench_copy",
    "ddr_bench_write",
)


def xorshift32(value: int) -> int:
    """Apply the DDR bench's unsigned 32-bit address generator."""
    value ^= (value << 13) & 0xFFFFFFFF
    value ^= value >> 17
    return (value ^ (value << 5)) & 0xFFFFFFFF


def build_kernel(
    builder: Any, kernel: str, scale_shift: int = 4, mlp_lines: int = 512
) -> list[Any]:
    """Emit a timed kernel with the C program's data addresses and dependencies."""
    if kernel not in KERNELS:
        raise ValueError(f"unknown memory kernel: {kernel}")
    if not 0 <= scale_shift <= 10:
        raise ValueError("scale_shift must be in 0..10")
    if mlp_lines < 4 or mlp_lines % 4:
        raise ValueError("mlp_lines must be a positive multiple of four")
    b = builder

    def emit(kind: str, address: int | None = None, deps: tuple[int, ...] = ()) -> int:
        return b.emit(kind, 0x80002000 + (len(b.ops) % 64) * 4, address, deps)

    def arithmetic(deps: tuple[int, ...], count: int = 1) -> int:
        result = emit("alu", deps=deps)
        for _ in range(count - 1):
            result = emit("alu", deps=(result,))
        return result

    index = emit("alu")
    accumulators = [emit("alu") for _ in range(4)]
    mib = 1 << 20
    if kernel in {"ddr_mlp_chase", "ddr_bench_chase"}:
        mlp = kernel == "ddr_mlp_chase"
        value = 0 if mlp else 0x13579BD
        previous = index
        for _ in range(mlp_lines if mlp else 2048 >> scale_shift):
            address = (
                (0x80600000 + value * 32)
                if mlp
                else (0x81C00000 + (value & 0x7FFFF) * 8)
            )
            addr_op = arithmetic((previous,))
            loaded = emit("load", address, (addr_op,))
            previous = arithmetic((loaded, previous), 1 if mlp else 7)
            value = (value + 1) % mlp_lines if mlp else xorshift32(value)
            index = arithmetic((index,))
            emit("branch", deps=(index,))
        return b.ops

    if kernel in {"ddr_bench_random_read", "ddr_bench_record_read"}:
        record = kernel == "ddr_bench_record_read"
        values = [0x2468ACE, 0] if record else [0x1234567, 0x89ABCDEF]
        state = [index, index]
        count = 4096 >> scale_shift
        for _ in range(count if record else count // 2):
            loads = []
            for lane in range(1 if record else 2):
                state[lane] = arithmetic((state[lane],), 6)
                values[lane] = xorshift32(values[lane])
                address = (
                    (0x81800000 + (values[lane] & 0xFFFF) * 64)
                    if record
                    else (0x81400000 + (values[lane] & 0x7FFFF) * 8)
                )
                addr_op = arithmetic((state[lane],), 2)
                loads.append(emit("load", address, (addr_op,)))
                if record:
                    upper_addr = arithmetic((addr_op,))
                    loads.append(emit("load", address + 32, (upper_addr,)))
            for lane, loaded in enumerate(loads):
                accumulators[lane] = arithmetic((loaded, accumulators[lane]))
            index = arithmetic((index,))
            emit("branch", deps=(index,))
        return b.ops

    if kernel.startswith("ddr_mlp_"):
        count, stride, base = mlp_lines, 32, 0x80600000
    elif kernel in {"ddr_bench_streams_read", "ddr_bench_streams_aliased_read"}:
        count, stride, base = 4 * ((32 * 1024 >> scale_shift) // 8), 8, 0x81000000
    elif kernel in {"ddr_bench_copy", "ddr_bench_write"}:
        count, stride, base = (256 * 1024 >> scale_shift) // 8, 8, 0x82000000
    else:
        stride = 32 if kernel == "ddr_bench_stride_read" else 8
        count = (mib >> scale_shift) // stride
        base = 0x80C00000 if stride == 32 else 0x80800000

    for offset in range(0, count, 4):
        loads = []
        for lane in range(4):
            element = offset + lane
            if kernel in {"ddr_bench_streams_read", "ddr_bench_streams_aliased_read"}:
                aliased = kernel == "ddr_bench_streams_aliased_read"
                address = (
                    (0x82800000 if aliased else base)
                    + lane * (2 * mib if aliased else 32768)
                    + (offset // 4) * 8
                )
            else:
                address = base + element * stride
            addr_op = arithmetic((index,), 1 if lane == 0 else 2)
            if kernel in {"ddr_mlp_store", "ddr_bench_write"}:
                address = (
                    address + 4
                    if kernel == "ddr_mlp_store"
                    else 0x82100000 + element * 8
                )
                emit("store", address, (addr_op, index))
            else:
                loaded = emit("load", address, (addr_op,))
                loads.append((loaded, element))
                if kernel != "ddr_bench_copy":
                    accumulators[lane] = arithmetic((loaded, accumulators[lane]))
        if kernel == "ddr_bench_copy":
            for loaded, element in loads:
                addr_op = arithmetic((index,))
                emit("store", 0x82090000 + element * 8, (loaded, addr_op))
        index = arithmetic((index,))
        emit("branch", deps=(index,))
    return b.ops

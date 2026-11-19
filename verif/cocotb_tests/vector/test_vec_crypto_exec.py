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

"""Group execution, register crossing, restart, masks and data-independent latency."""

import os
import random
from typing import Any
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from .test_vec_engine import Model
from .test_vec_aes_group import model as aes
from .test_vec_sha2_group import model as sha, pack
from .test_vec_ghash_group import zvkg
from .test_vec_clmul_lane import clmul

SPECS: list[tuple[str, int, int | None, int, int]] = []
for name, sub in (("DM", 0), ("DF", 1), ("EM", 2), ("EF", 3)):
    for scalar in (False, True):
        SPECS.append((name, 0x29 if scalar else 0x28, sub, 2, 0x77))
SPECS.extend(
    (
        ("Z", 0x29, 7, 2, 0x77),
        ("KF1", 0x22, 31, 2, 0x77),
        ("KF2", 0x2A, 0, 2, 0x77),
        ("MS", 0x2D, None, 2, 0x77),
        ("CL", 0x2F, None, 2, 0x77),
        ("CH", 0x2E, None, 2, 0x77),
        ("GHSH", 0x2C, None, 2, 0x77),
        ("GMUL", 0x28, 17, 2, 0x77),
    )
)
for name, f6 in (("clmul", 12), ("clmulh", 13)):
    for f3 in (2, 6):
        SPECS.append((name, f6, None, f3, 0x57))


def execute(
    model: Model,
    name: str,
    sew: int,
    vl: int,
    start: int,
    vm: int,
    vd: int,
    vs2: int,
    vs1: int,
    scalar: int,
    f6: int,
    f3: int,
    sub: int,
) -> None:
    """Apply one instruction to a snapshot of the architectural registers."""
    old = Model(model.vlen)
    old.regs = model.regs.copy()
    carry = name.startswith("clmul")
    for i in range(start, vl, 1 if carry else 4):
        if carry:
            if not vm and not (old.regs[0] >> i & 1):
                continue
            value = clmul(
                old.elem(vs2, i, 64), scalar if f3 == 6 else old.elem(vs1, i, 64)
            )
            if name == "clmulh":
                value >>= 64
            model.set_elem(vd, i, 64, value & ((1 << 64) - 1))
            continue
        d = [old.elem(vd, i + k, sew) for k in range(4)]
        a = [old.elem(vs2, (0 if f6 == 0x29 else i) + k, sew) for k in range(4)]
        b = (
            [old.elem(vs1, i + k, sew) for k in range(4)]
            if name in ("MS", "CL", "CH", "GHSH")
            else [0] * 4
        )
        if name in ("MS", "CL", "CH"):
            value = pack(sha(name, sew, d, a, b), sew)
        elif name in ("GHSH", "GMUL"):
            value = zvkg(pack(d, 32), pack(a, 32), pack(b, 32), name == "GMUL")
        else:
            value = aes(name, sub & 15, pack(d, 32), pack(a, 32))
        for k in range(4):
            model.set_elem(vd, i + k, sew, value >> (k * sew) & ((1 << sew) - 1))


@cocotb.test()
async def crypto_families(dut: Any) -> None:
    """Every group form at supported widths and group capacities."""
    vlen = len(dut.o_wdata)
    model = Model(vlen)
    memory = [0] * 32

    async def memory_port() -> None:
        while True:
            await FallingEdge(dut.i_clk)
            addresses = int(dut.o_raddr.value)
            reads = sum(
                memory[(addresses >> (5 * k)) & 31] << (vlen * k) for k in range(4)
            )
            we = int(dut.o_we.value)
            addr = int(dut.o_waddr.value)
            data = int(dut.o_wdata.value)
            enable = int(dut.o_wbe.value)
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            if we:
                for byte in range(vlen // 8):
                    if enable >> byte & 1:
                        mask = 255 << (8 * byte)
                        memory[addr] = (memory[addr] & ~mask) | (data & mask)
            dut.i_rdata.value = reads

    Clock(dut.i_clk, 10, unit="ns").start()
    dut.i_rst.value = 1
    dut.i_valid.value = 0
    dut.i_insn.value = 0
    dut.i_sew.value = 1
    dut.i_vl.value = 0
    dut.i_vstart.value = 0
    dut.i_scalar.value = 0
    dut.i_rdata.value = 0
    cocotb.start_soon(memory_port())
    for _ in range(3):
        await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    rng = random.Random(4119 + vlen)
    count = 0
    for name, f6, sub, f3, opcode in SPECS:
        widths = (
            (64,)
            if name.startswith("clmul")
            else (32, 64)
            if name in ("MS", "CL", "CH")
            else (32,)
        )
        for sew in widths:
            for lm in (0.125, 0.25, 0.5, 1, 2, 4, 8):
                vlmax = int(vlen // sew * lm)
                carry = name.startswith("clmul")
                if vlmax < (1 if carry else 4) or lm < sew / 64:
                    continue
                for trial in range(4):
                    vl = rng.choice(
                        (
                            0,
                            vlmax,
                            (rng.randrange(vlmax + 1) // (1 if carry else 4))
                            * (1 if carry else 4),
                        )
                    )
                    start = (
                        rng.choice((0, 1 if carry else 4, vl, vl + (1 if carry else 4)))
                        if trial == 0
                        else 0
                    )
                    vm = rng.randrange(2) if carry else 1
                    vd, vs2, vs1 = 16, 8, 24
                    if f6 == 0x29:
                        vs2 = 7
                    if name not in ("MS", "CL", "CH") and f6 != 0x29 and trial == 2:
                        vd = vs2
                    cycles = []
                    for sample in range(2):
                        scalar = rng.getrandbits(64)
                        for r in range(32):
                            memory[r] = model.regs[r] = rng.getrandbits(vlen)
                        if carry and not vm:
                            memory[0] = model.regs[0] = (
                                ((1 << vlen) - 1) if sample else 0
                            )
                        execute(
                            model,
                            name,
                            sew,
                            vl,
                            start,
                            vm,
                            vd,
                            vs2,
                            vs1,
                            scalar,
                            f6,
                            f3,
                            sub or 0,
                        )
                        if (
                            os.environ.get("FROST_VECTOR_NEGATIVE_CONTROL") == "1"
                            and count == 0
                        ):
                            model.regs[vd] ^= 1
                        field = vs1 if sub is None else sub
                        dut.i_insn.value = (
                            f6 << 26
                            | vm << 25
                            | vs2 << 20
                            | field << 15
                            | f3 << 12
                            | vd << 7
                            | opcode
                        )
                        dut.i_sew.value = sew.bit_length() - 4
                        dut.i_vl.value = vl
                        dut.i_vstart.value = start
                        dut.i_scalar.value = scalar
                        dut.i_valid.value = 1
                        await FallingEdge(dut.i_clk)
                        dut.i_valid.value = 0
                        for step in range(100000):
                            if int(dut.o_idle.value):
                                break
                            await FallingEdge(dut.i_clk)
                        else:
                            raise AssertionError("timeout")
                        cycles.append(step)
                        context = f"{name} sew={sew} lm={lm} vl={vl} start={start} vm={vm} sample={sample}"
                        for r in range(32):
                            assert memory[r] == model.regs[r], (
                                f"{context}: v{r} {memory[r]:#x} != {model.regs[r]:#x}"
                            )
                        count += 1
                    if (
                        os.environ.get("FROST_VECTOR_LATENCY_NEGATIVE") == "1"
                        and count == 2
                    ):
                        cycles[1] += 1
                    assert cycles[0] == cycles[1], (
                        f"{name}: data-dependent latency {cycles}"
                    )
    dut._log.info("%d crypto instruction/width/group/restart cases matched", count)

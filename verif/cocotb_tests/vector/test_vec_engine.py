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

"""Check vec_engine's integer instructions against a model of their semantics.

The model applies each instruction element by element at SEW, with LMUL
register groups, vl, vstart and the v0 mask, leaving tail and inactive
elements undisturbed (both policies allow it); compares write one mask bit
per active body element. The bench loads random register contents through
the memory-side write port, issues random instructions with random vtype, vl,
vstart and masking, and compares all 32 registers after each one through the
memory-side read port.
"""

import random
from typing import Any
from collections.abc import Callable

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

# funct6 -> (name, forms) for OPIVV (vv), OPIVX (vx), OPIVI (vi)
OPS: dict[int, tuple[str, str]] = {
    0b000000: ("add", "vv vx vi"),
    0b000001: ("andn", "vv vx"),
    0b000010: ("sub", "vv vx"),
    0b000011: ("rsub", "vx vi"),
    0b000100: ("minu", "vv vx"),
    0b000101: ("min", "vv vx"),
    0b000110: ("maxu", "vv vx"),
    0b000111: ("max", "vv vx"),
    0b001001: ("and", "vv vx vi"),
    0b001010: ("or", "vv vx vi"),
    0b001011: ("xor", "vv vx vi"),
    0b010100: ("ror", "vv vx vi"),
    0b010101: ("rol", "vv vx"),
    0b010111: ("merge", "vv vx vi"),
    0b011000: ("mseq", "vv vx vi"),
    0b011001: ("msne", "vv vx vi"),
    0b011010: ("msltu", "vv vx"),
    0b011011: ("mslt", "vv vx"),
    0b011100: ("msleu", "vv vx vi"),
    0b011101: ("msle", "vv vx vi"),
    0b011110: ("msgtu", "vx vi"),
    0b011111: ("msgt", "vx vi"),
    0b100101: ("sll", "vv vx vi"),
    0b101000: ("srl", "vv vx vi"),
    0b101001: ("sra", "vv vx vi"),
}
UNARY = {
    0b01000: "brev8",
    0b01001: "rev8",
    0b01010: "brev",
    0b01100: "clz",
    0b01101: "ctz",
    0b01110: "cpop",
}
UIMM = {"sll", "srl", "sra", "ror", "rol"}


def signed(x: int, bits: int) -> int:
    """Return x as a signed value of the given width."""
    return x - (1 << bits) if x >> (bits - 1) else x


def element_op(name: str, a: int, b: int, sew: int, mask: int) -> int:
    """Return one element's result (or compare bit) for an operation."""
    m = (1 << sew) - 1
    sa, sb = signed(a, sew), signed(b, sew)
    sh = b & (sew - 1)
    table: dict[str, Callable[[], int]] = {
        "add": lambda: (a + b) & m,
        "sub": lambda: (a - b) & m,
        "rsub": lambda: (b - a) & m,
        "and": lambda: a & b,
        "or": lambda: a | b,
        "xor": lambda: a ^ b,
        "andn": lambda: a & ~b & m,
        "minu": lambda: min(a, b),
        "maxu": lambda: max(a, b),
        "min": lambda: (min(sa, sb)) & m,
        "max": lambda: (max(sa, sb)) & m,
        "sll": lambda: (a << sh) & m,
        "srl": lambda: a >> sh,
        "sra": lambda: (sa >> sh) & m,
        "ror": lambda: ((a >> sh) | (a << (sew - sh))) & m,
        "rol": lambda: ((a << sh) | (a >> (sew - sh))) & m,
        "merge": lambda: b if mask else a,
        "mv": lambda: b,
        "mseq": lambda: int(a == b),
        "msne": lambda: int(a != b),
        "msltu": lambda: int(a < b),
        "mslt": lambda: int(sa < sb),
        "msleu": lambda: int(a <= b),
        "msle": lambda: int(sa <= sb),
        "msgtu": lambda: int(a > b),
        "msgt": lambda: int(sa > sb),
        "brev8": lambda: int.from_bytes(
            bytes(int(f"{x:08b}"[::-1], 2) for x in a.to_bytes(sew // 8, "little")),
            "little",
        ),
        "rev8": lambda: int.from_bytes(a.to_bytes(sew // 8, "little")[::-1], "little"),
        "brev": lambda: int(f"{a:0{sew}b}"[::-1], 2),
        "clz": lambda: sew - a.bit_length(),
        "ctz": lambda: (a & -a).bit_length() - 1 if a else sew,
        "cpop": lambda: bin(a).count("1"),
    }
    return table[name]()


class Model:
    """Architectural vector registers and the semantics of the supported ops."""

    def __init__(self, vlen: int) -> None:
        """Start with zero registers."""
        self.vlen = vlen
        self.regs = [0] * 32

    def elem(self, base: int, i: int, sew: int) -> int:
        """Return element i of the register group starting at base."""
        epr = self.vlen // sew
        return (self.regs[base + i // epr] >> ((i % epr) * sew)) & ((1 << sew) - 1)

    def set_elem(self, base: int, i: int, sew: int, v: int) -> None:
        """Write element i of the register group starting at base."""
        epr = self.vlen // sew
        r = base + i // epr
        sh = (i % epr) * sew
        self.regs[r] = (self.regs[r] & ~(((1 << sew) - 1) << sh)) | (v << sh)

    def execute(
        self,
        name: str,
        form: str,
        sew: int,
        vl: int,
        vstart: int,
        vm: int,
        vd: int,
        vs1: int,
        vs2: int,
        scalar: int,
    ) -> None:
        """Apply one instruction."""
        v0 = self.regs[0]
        mask_dest = name.startswith("ms")
        old_vd = self.regs[vd]
        results = []
        for i in range(vstart, vl):
            mbit = (v0 >> i) & 1
            active = vm or mbit or name == "merge"
            a = self.elem(vs2, i, sew)
            b = scalar if form != "vv" else self.elem(vs1, i, sew)
            if active:
                results.append((i, element_op(name, a, b, sew, mbit)))
        if mask_dest:
            new = old_vd
            for i, bit in results:
                new = (new & ~(1 << i)) | (bit << i)
            self.regs[vd] = new
        else:
            for i, v in results:
                self.set_elem(vd, i, sew, v)


@cocotb.test()
async def test_vec_engine_integer(dut: Any) -> None:
    """Random integer instructions against the model."""
    vlen = len(dut.o_xr_data)
    rng = random.Random(2040 + vlen)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in (
        "i_valid",
        "i_insn",
        "i_vsew",
        "i_vlmul",
        "i_vl",
        "i_vstart",
        "i_rs1",
        "i_xr_addr",
        "i_xw_en",
        "i_xw_addr",
        "i_xw_data",
        "i_xw_be",
    ):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    model = Model(vlen)
    for r in range(32):
        v = rng.getrandbits(vlen)
        model.regs[r] = v
        dut.i_xw_en.value = 1
        dut.i_xw_addr.value = r
        dut.i_xw_data.value = v
        dut.i_xw_be.value = (1 << (vlen // 8)) - 1
        await FallingEdge(dut.i_clk)
    dut.i_xw_en.value = 0

    count = 600
    for n in range(count):
        funct6 = rng.choice(list(OPS) + [0b010010] * 3)
        sew = 8 << rng.randrange(4)
        lmul_code = rng.choice([0, 1, 2, 3, 5, 6, 7])
        lmul = 1 << lmul_code if lmul_code < 4 else 1
        frac = {5: 8, 6: 4, 7: 2}.get(lmul_code, 1)
        if sew * frac > 64:
            lmul_code, frac = 0, 1
        vlmax = (vlen // sew) * lmul // frac
        vl = rng.choice([vlmax, rng.randrange(vlmax + 1), 1, 0])
        vstart = rng.randrange(vl + 1) if rng.random() < 0.1 else 0
        vm = rng.getrandbits(1)
        if funct6 == 0b010010:
            name, form, f3 = UNARY[rng.choice(list(UNARY))], "vv", 0b010
            code = {v: k for k, v in UNARY.items()}[name]
        else:
            name, forms = OPS[funct6]
            form = rng.choice(forms.split())
            f3 = {"vv": 0b000, "vx": 0b100, "vi": 0b011}[form]
            code = 0
        groups = lmul
        vs2 = rng.randrange(32 // groups) * groups
        vs1 = rng.randrange(32 // groups) * groups
        if name.startswith("ms"):
            vd = rng.randrange(1, 32)
            # A mask destination may not overlap a source group except at its start.
            while vs2 < vd < vs2 + groups or (form == "vv" and vs1 < vd < vs1 + groups):
                vd = rng.randrange(1, 32)
        else:
            vd = rng.randrange(1, 32 // groups) * groups if groups < 32 else 0
        if funct6 == 0b010111:
            name = "merge" if vm == 0 else "mv"
            vs2 = 0 if vm == 1 else vs2
        scalar_field = rng.getrandbits(5)
        rs1 = rng.getrandbits(64)
        if form == "vi":
            if name in UIMM:
                scalar = scalar_field
                if name == "ror" and rng.getrandbits(1):
                    scalar |= 32
                    funct6 = 0b010101
            else:
                scalar = scalar_field - 32 if scalar_field & 16 else scalar_field
            scalar &= (1 << sew) - 1
        else:
            scalar = rs1 & ((1 << sew) - 1)
        field15 = (
            code if funct6 == 0b010010 else (scalar_field if form == "vi" else vs1)
        )
        if form == "vi" and name == "ror" and funct6 == 0b010101:
            field15 = scalar_field
        insn = (
            (funct6 << 26)
            | (vm << 25)
            | (vs2 << 20)
            | (field15 << 15)
            | (f3 << 12)
            | (vd << 7)
            | 0b1010111
        )
        model.execute(name, form, sew, vl, vstart, vm, vd, vs1, vs2, scalar)

        dut.i_valid.value = 1
        dut.i_insn.value = insn
        dut.i_vsew.value = {8: 0, 16: 1, 32: 2, 64: 3}[sew]
        dut.i_vlmul.value = lmul_code
        dut.i_vl.value = vl
        dut.i_vstart.value = vstart
        dut.i_rs1.value = rs1
        await FallingEdge(dut.i_clk)
        dut.i_valid.value = 0
        for _ in range(500):
            await RisingEdge(dut.i_clk)
            await ReadOnly()
            assert int(dut.o_unsupported.value) == 0, f"unsupported {name}.{form}"
            if int(dut.o_idle.value):
                break
        await FallingEdge(dut.i_clk)
        for r in range(32):
            dut.i_xr_addr.value = r
            await FallingEdge(dut.i_clk)
            got = int(dut.o_xr_data.value)
            if got != model.regs[r]:
                raise AssertionError(
                    f"op {n} {name}.{form} sew {sew} lmul {lmul_code} vl {vl} vstart {vstart} "
                    f"vm {vm} vd {vd} vs1 {vs1} vs2 {vs2}: v{r} {got:#x} want {model.regs[r]:#x}"
                )
    dut._log.info(f"{count} instructions matched the model")

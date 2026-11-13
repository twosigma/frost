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

r"""Random vector-instruction traces for QuickCheckVEngine.

QuickCheckVEngine has no vector templates, so the traces are raw instruction
words, as in atomics.py and crypto.py. Each trace

1. turns on mstatus.FS and mstatus.VS,
2. zeroes v0..v31, vxrm and vxsat, because Sail does not reset them (FROST's
   vector registers are not reset either), and sets vtype with a non-x0 AVL,
   since ``vsetvli x0, x0`` is illegal while vtype.vill is set,
3. runs random integer vector operations under random SEW, LMUL and AVL with
   tail- and mask-undisturbed policies (agnostic elements may legally differ
   between implementations, and the read-out compares every element), and
4. reads vl and vtype, then moves every 64-bit element of v0..v31 into a scalar
   register with ``vmv.x.s`` and an in-place ``vslidedown.vi`` by one, then reads
   vxsat and vlenb.

Step 4 is how a comparison sees vector state: RVFI-DII reports the integer
destination of each instruction, and for a vector load or store only one
element of its data, so a register image cannot be read back through memory.
The instructions are chosen to avoid reserved encodings: destination and
source registers are multiples of LMUL, and widening or narrowing forms are
left out and a masked operation never has vd = v0. A small share of operations
may still trap on some register or mask combinations, which both implementations
must report alike.
"""

import random
from pathlib import Path

# The vector registers are VLEN bits wide; elements are moved out 64 bits at a time.
ELEMENT_BITS = 64
VECTOR_LENGTHS = (128, 256, 512)

# Architecture string for QuickCheckVEngine's -r option.
ARCHITECTURE = "rv64imafdcsv_zicsr_zifencei"

# CSR addresses.
CSR_MSTATUS = 0x300
CSR_VXSAT = 0x009
CSR_VXRM = 0x00A
CSR_VL = 0xC20
CSR_VTYPE = 0xC21
CSR_VLENB = 0xC22

# mstatus.FS and mstatus.VS, both set to Dirty (0b11).
MSTATUS_FS_DIRTY = 3 << 13
MSTATUS_VS_DIRTY = 3 << 9

# Registers: t0 and a0..a3 of the standard calling convention.
T0 = 5
BASE_AVL = 11  # a1: the AVL register
VL_RESULT = 12  # a2: receives vl from vsetvli
EXFIL = 13  # a3: receives vector elements

# Vector arithmetic encodings: name -> (funct6, funct3). funct3 selects the
# operand kind: 0 OPIVV, 2 OPMVV, 3 OPIVI, 4 OPIVX, 6 OPMVX.
OPERATIONS_VV = {
    "vadd.vv": (0x00, 0),
    "vsub.vv": (0x02, 0),
    "vand.vv": (0x09, 0),
    "vor.vv": (0x0A, 0),
    "vxor.vv": (0x0B, 0),
    "vsll.vv": (0x25, 0),
    "vsrl.vv": (0x28, 0),
    "vsra.vv": (0x29, 0),
    "vminu.vv": (0x04, 0),
    "vmin.vv": (0x05, 0),
    "vmaxu.vv": (0x06, 0),
    "vmax.vv": (0x07, 0),
    "vsaddu.vv": (0x20, 0),
    "vsadd.vv": (0x21, 0),
    "vssubu.vv": (0x22, 0),
    "vssub.vv": (0x23, 0),
    "vmul.vv": (0x25, 2),
    "vmulh.vv": (0x27, 2),
    "vmulhu.vv": (0x24, 2),
    "vmulhsu.vv": (0x26, 2),
    "vdivu.vv": (0x20, 2),
    "vdiv.vv": (0x21, 2),
    "vremu.vv": (0x22, 2),
    "vrem.vv": (0x23, 2),
}
OPERATIONS_VI = {
    "vadd.vi": (0x00, 3),
    "vand.vi": (0x09, 3),
    "vor.vi": (0x0A, 3),
    "vxor.vi": (0x0B, 3),
    "vsll.vi": (0x25, 3),
    "vsrl.vi": (0x28, 3),
    "vsra.vi": (0x29, 3),
    "vrsub.vi": (0x03, 3),
    "vslidedown.vi": (0x0F, 3),
}
OPERATIONS_VX = {
    "vadd.vx": (0x00, 4),
    "vsub.vx": (0x02, 4),
    "vxor.vx": (0x0B, 4),
    "vmul.vx": (0x25, 6),
}

SEW_FIELD = {8: 0, 16: 1, 32: 2, 64: 3}
LMUL_FIELD = {1: 0, 2: 1, 4: 2, 8: 3}
AVLS = (0, 1, 3, 7, 15, 31, 100, 1000)

# The .vi forms whose 5-bit immediate is signed; the others are unsigned.
SIGNED_IMMEDIATE = {"vadd.vi", "vand.vi", "vor.vi", "vxor.vi", "vrsub.vi"}


def _i_type(opcode: int, funct3: int, rd: int, rs1: int, imm: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def _lui(rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def _addi(rd: int, rs1: int, imm: int) -> int:
    return _i_type(0x13, 0, rd, rs1, imm)


def _csrrs(rd: int, csr: int, rs1: int) -> int:
    return (csr << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x73


def _csrwi(csr: int, zimm: int) -> int:
    """Encode csrrwi x0, csr, zimm."""
    return (csr << 20) | (zimm << 15) | (0b101 << 12) | 0x73


def _vsetvli(rd: int, rs1: int, vtype: int) -> int:
    return ((vtype & 0x7FF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0x57


def _op_v(funct6: int, vm: int, vs2: int, vs1: int, funct3: int, vd: int) -> int:
    return (
        (funct6 << 26)
        | (vm << 25)
        | (vs2 << 20)
        | ((vs1 & 31) << 15)
        | (funct3 << 12)
        | (vd << 7)
        | 0x57
    )


def _vtype(sew: int, lmul: int, tail_agnostic: int, mask_agnostic: int) -> int:
    return (
        (mask_agnostic << 7)
        | (tail_agnostic << 6)
        | (SEW_FIELD[sew] << 3)
        | LMUL_FIELD[lmul]
    )


def _random_operations(
    rng: random.Random, lmul: int, count: int
) -> list[tuple[int, str]]:
    """Return `count` random vector operations as (word, text) pairs."""
    registers = list(range(0, 31, lmul))
    operations = []
    for _ in range(count):
        vd, vs2, vs1 = (rng.choice(registers) for _ in range(3))
        masked = rng.randrange(2) if vd != 0 else 1
        suffix = "" if masked else ", v0.t"
        kind = rng.random()
        if kind < 0.6:
            name = rng.choice(list(OPERATIONS_VV))
            funct6, funct3 = OPERATIONS_VV[name]
            word = _op_v(funct6, masked, vs2, vs1, funct3, vd)
            text = f"{name} v{vd}, v{vs2}, v{vs1}{suffix}"
        elif kind < 0.8:
            name = rng.choice(list(OPERATIONS_VI))
            funct6, funct3 = OPERATIONS_VI[name]
            immediate = rng.randrange(32)
            word = _op_v(funct6, masked, vs2, immediate, funct3, vd)
            shown = (
                immediate - 32
                if name in SIGNED_IMMEDIATE and immediate > 15
                else immediate
            )
            text = f"{name} v{vd}, v{vs2}, {shown}{suffix}"
        else:
            name = rng.choice(list(OPERATIONS_VX))
            funct6, funct3 = OPERATIONS_VX[name]
            word = _op_v(funct6, masked, vs2, BASE_AVL, funct3, vd)
            text = f"{name} v{vd}, v{vs2}, a1{suffix}"
        operations.append((word, text))
    return operations


def trace(rng: random.Random, vlen: int, length: int) -> list[str]:
    """Return one trace's lines: setup (not shrunk), random body, read-out."""
    setup: list[tuple[int, str]] = [
        (_lui(T0, 6), "lui t0, 6"),
        (_csrrs(0, CSR_MSTATUS, T0), "csrrs x0, mstatus, t0  # FS = Dirty"),
        (_addi(T0, 0, 0x600), "addi t0, x0, 0x600"),
        (_csrrs(0, CSR_MSTATUS, T0), "csrrs x0, mstatus, t0  # VS = Dirty"),
        (_addi(BASE_AVL, 0, -1), "addi a1, x0, -1"),
        (
            _vsetvli(0, BASE_AVL, _vtype(64, 8, 1, 1)),
            "vsetvli x0, a1, e64,m8,ta,ma",
        ),
    ]
    for group in (0, 8, 16, 24):
        setup.append((_op_v(0x17, 1, 0, 0, 3, group), f"vmv.v.i v{group}, 0"))
    setup.append((_csrwi(CSR_VXRM, 0), "csrwi vxrm, 0"))
    setup.append((_csrwi(CSR_VXSAT, 0), "csrwi vxsat, 0"))

    body: list[tuple[int, str]] = []
    for _ in range(length):
        sew = rng.choice(list(SEW_FIELD))
        lmul = rng.choice(list(LMUL_FIELD))
        # Undisturbed policies: agnostic elements may legally differ between
        # implementations, and the read-out compares every element exactly.
        tail_agnostic, mask_agnostic = 0, 0
        avl = rng.choice(AVLS)
        body.append((_addi(BASE_AVL, 0, avl), f"addi a1, x0, {avl}"))
        body.append(
            (
                _vsetvli(
                    VL_RESULT,
                    BASE_AVL,
                    _vtype(sew, lmul, tail_agnostic, mask_agnostic),
                ),
                f"vsetvli a2, a1, e{sew},m{lmul},"
                f"{'ta' if tail_agnostic else 'tu'},{'ma' if mask_agnostic else 'mu'}",
            )
        )
        body.extend(_random_operations(rng, lmul, rng.randint(2, 5)))

    # vl and vtype as the body left them, then every element at the full length.
    readout: list[tuple[int, str]] = [
        (_csrrs(EXFIL, csr, 0), f"csrr a3, {name}")
        for name, csr in (("vl", CSR_VL), ("vtype", CSR_VTYPE))
    ]
    readout.append((_addi(BASE_AVL, 0, -1), "addi a1, x0, -1"))
    readout.append(
        (_vsetvli(0, BASE_AVL, _vtype(64, 1, 1, 1)), "vsetvli x0, a1, e64,m1,ta,ma")
    )
    # Each register is read in place: element 0, then slide down by one and read
    # element 0 again, so no scratch register is needed and all 32 are observed.
    for register in range(32):
        readout.append(
            (_op_v(0x10, 1, register, 0, 2, EXFIL), f"vmv.x.s a3, v{register}")
        )
        for _ in range(1, vlen // ELEMENT_BITS):
            readout.append(
                (
                    _op_v(0x0F, 1, register, 1, 3, register),
                    f"vslidedown.vi v{register}, v{register}, 1",
                )
            )
            readout.append(
                (_op_v(0x10, 1, register, 0, 2, EXFIL), f"vmv.x.s a3, v{register}")
            )
    readout.append((_csrrs(EXFIL, CSR_VXSAT, 0), "csrr a3, vxsat"))
    readout.append((_csrrs(EXFIL, CSR_VLENB, 0), "csrr a3, vlenb"))

    lines = [f"# vector trace, VLEN {vlen}", ".noshrink"]
    lines += [f".4byte {word:#010x}  # {text}" for word, text in setup]
    lines.append(".shrink")
    lines += [f".4byte {word:#010x}  # {text}" for word, text in body]
    lines.append(".noshrink")
    lines += [f".4byte {word:#010x}  # {text}" for word, text in readout]
    return lines


def write_tests(
    directory: Path, count: int, seed: int, length: int, vlen: int
) -> list[Path]:
    """Write reproducible vector traces for a core with the given VLEN."""
    if vlen not in VECTOR_LENGTHS:
        raise ValueError(f"VLEN must be one of {VECTOR_LENGTHS}, got {vlen}")
    rng = random.Random(seed)
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for index in range(count):
        path = directory / f"vector_{seed}_{index:04d}.S"
        path.write_text("\n".join(trace(rng, vlen, length)) + "\n", encoding="utf-8")
        paths.append(path)
    return paths

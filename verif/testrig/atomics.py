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

"""Random A-extension tests that FROST and the Sail model must agree on.

FROST and Sail keep LR reservations under different rules, both allowed by
the specification: a trap, xRET, or FENCE-class flush cancels FROST's
reservation and leaves Sail's. QuickCheckVEngine's atomic templates put such
events between LR and SC, so TestRIG replays these tests instead. Each one
mixes LR, SC, and AMOs with loads, stores, integer operations, jumps,
branches, fences, environment calls, and faulting accesses, and nothing that
can trap or flush falls between an LR and the SC that closes it. Inside those
windows go operations that cannot fault: loads, stores, and AMOs to valid,
aligned addresses (one to the reserved doubleword cancels the reservation in
both), another LR, branches, jumps, and FENCE. Every window ends with an SC,
which cancels the reservation in both whether it succeeds or not, so none is
open outside a window.

Each window, and each setup of a base register, is a `.noshrink` strand,
which QuickCheckVEngine's shrinking neither removes nor rewrites, so a shrunk
counterexample keeps the property. Base registers hold fixed addresses that
only their setup strands write (a base a test leaves unset reads zero, the
start of low BRAM), so the generator knows the address of every access.

Which accesses fault comes from sail_frost.json, which mirrors FROST's
physical memory attributes.
"""

import json
import random
from dataclasses import dataclass
from pathlib import Path

SAIL_CONFIG = Path(__file__).with_name("sail_frost.json")

# Addresses the base registers hold.
DDR = 0x8020_0000  # cached DDR, away from the test's instruction addresses
BRAM = 0x0003_0000  # low BRAM
DEVICE = 0x4000_0100  # a device page: loads and stores, no atomics
QUADRANT = 0x4010_0000  # the rest of the device quadrant: stores only
UNMAPPED = 0x2000_0000  # outside every region

# Base registers and their addresses. Nothing but a setup strand writes them.
BASES = {
    20: DDR,
    21: DDR + 8,
    22: DDR + 4,  # word-aligned only
    23: DDR + 2,  # halfword-aligned only
    24: DDR + 0x40,  # another cache line
    25: BRAM,
    26: BRAM + 8,
    27: DEVICE,
    28: QUADRANT,
    29: UNMAPPED,
}
# Every test sets these bases; it picks a few of the rest.
ALWAYS_SET = (20, 25)

# Operands and results. x30 and x31 stay zero.
DATA = tuple(range(1, 20))

LR, SC = 0x02, 0x03
AMOS = {
    "amoswap": 0x01,
    "amoadd": 0x00,
    "amoxor": 0x04,
    "amoand": 0x0C,
    "amoor": 0x08,
    "amomin": 0x10,
    "amomax": 0x14,
    "amominu": 0x18,
    "amomaxu": 0x1C,
}
LOADS = {"lb": (0, 1), "lh": (1, 2), "lw": (2, 4), "ld": (3, 8)}
LOADS |= {"lbu": (4, 1), "lhu": (5, 2), "lwu": (6, 4)}
STORES = {"sb": (0, 1), "sh": (1, 2), "sw": (2, 4), "sd": (3, 8)}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
CSRS = {"mepc": 0x341, "mcause": 0x342, "mtval": 0x343}

# Integer operations: OP-IMM and OP-IMM-32 (name -> funct3, funct7 or None
# for a 12-bit immediate, shift width), then OP and OP-32 (funct3, funct7).
ALU_IMM = {
    "addi": (0, None, 0),
    "xori": (4, None, 0),
    "ori": (6, None, 0),
    "andi": (7, None, 0),
    "slti": (2, None, 0),
    "sltiu": (3, None, 0),
    "slli": (1, 0x00, 6),
    "srli": (5, 0x00, 6),
    "srai": (5, 0x20, 6),
    "addiw": (0, None, 0),
    "slliw": (1, 0x00, 5),
    "sraiw": (5, 0x20, 5),
}
ALU_REG = {
    "add": (0, 0x00),
    "sub": (0, 0x20),
    "xor": (4, 0x00),
    "or": (6, 0x00),
    "and": (7, 0x00),
    "slt": (2, 0x00),
    "sltu": (3, 0x00),
    "sll": (1, 0x00),
    "sra": (5, 0x20),
    "addw": (0, 0x00),
    "subw": (0, 0x20),
}


@dataclass(frozen=True)
class Instruction:
    """One instruction word and its assembly text."""

    word: int
    text: str


@dataclass(frozen=True)
class Region:
    """A physical memory region and the accesses it allows."""

    base: int
    size: int
    readable: bool
    writable: bool
    amo: bool
    reservable: bool

    def contains(self, address: int, size: int) -> bool:
        """Return whether the region holds all of [address, address + size)."""
        return self.base <= address and address + size <= self.base + self.size


def load_regions(path: Path = SAIL_CONFIG) -> list[Region]:
    """Read the memory regions from Sail's configuration for FROST."""
    lines = path.read_text(encoding="utf-8").splitlines()
    config = json.loads("\n".join(x for x in lines if not x.lstrip().startswith("//")))
    regions = []
    for entry in config["memory"]["regions"]:
        attributes = entry["attributes"]
        regions.append(
            Region(
                base=int(entry["base"]["value"], 16),
                size=int(entry["size"]["value"], 16),
                readable=attributes["readable"],
                writable=attributes["writable"],
                amo=attributes["atomic_support"] != "AMONone",
                reservable=attributes["reservability"] != "RsrvNone",
            )
        )
    return regions


def allows(regions: list[Region], address: int, size: int, kind: str) -> bool:
    """Return whether an access of a kind (load, store, amo, lr, sc) cannot trap."""
    if address % size:
        return False
    for region in regions:
        if region.contains(address, size):
            return {
                "load": region.readable,
                "store": region.writable,
                "amo": region.amo and region.readable and region.writable,
                "lr": region.reservable and region.readable,
                "sc": region.reservable and region.writable,
            }[kind]
    return False


def _i_type(opcode: int, funct3: int, rd: int, rs1: int, imm: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def _r_type(opcode: int, funct3: int, funct7: int, rd: int, rs1: int, rs2: int) -> int:
    return (
        (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode
    )


def _s_type(funct3: int, rs1: int, rs2: int, imm: int) -> int:
    return (
        (((imm >> 5) & 0x7F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | ((imm & 0x1F) << 7)
        | 0x23
    )


def _b_type(funct3: int, rs1: int, rs2: int, offset: int) -> int:
    imm = offset & 0x1FFF
    return (
        (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (funct3 << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 1) << 7)
        | 0x63
    )


def _j_type(rd: int, offset: int) -> int:
    imm = offset & 0x1FFFFF
    return (
        (((imm >> 20) & 1) << 31)
        | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 1) << 20)
        | (((imm >> 12) & 0xFF) << 12)
        | (rd << 7)
        | 0x6F
    )


def _atomic(
    funct5: int, aq: int, rl: int, rd: int, rs1: int, rs2: int, width: int
) -> int:
    funct3 = 3 if width == 8 else 2
    return _r_type(0x2F, funct3, (funct5 << 2) | (aq << 1) | rl, rd, rs1, rs2)


def lui(rd: int, imm20: int) -> Instruction:
    """Encode LUI."""
    return Instruction(
        ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37, f"lui x{rd}, {imm20 & 0xFFFFF:#x}"
    )


def alu_imm(name: str, rd: int, rs1: int, imm: int) -> Instruction:
    """Encode an OP-IMM or OP-IMM-32 instruction; a shift takes its amount as imm."""
    funct3, funct7, shift_bits = ALU_IMM[name]
    opcode = 0x1B if name.endswith("w") else 0x13
    # A shift puts funct7 (funct6 and the amount's sixth bit, for RV64)
    # above the amount.
    field = imm if funct7 is None else (funct7 << 5) | (imm & ((1 << shift_bits) - 1))
    return Instruction(
        _i_type(opcode, funct3, rd, rs1, field), f"{name} x{rd}, x{rs1}, {imm}"
    )


def alu_reg(name: str, rd: int, rs1: int, rs2: int) -> Instruction:
    """Encode an OP or OP-32 instruction."""
    funct3, funct7 = ALU_REG[name]
    opcode = 0x3B if name.endswith("w") else 0x33
    return Instruction(
        _r_type(opcode, funct3, funct7, rd, rs1, rs2), f"{name} x{rd}, x{rs1}, x{rs2}"
    )


def load(name: str, rd: int, rs1: int, imm: int) -> Instruction:
    """Encode a load."""
    funct3, _ = LOADS[name]
    return Instruction(
        _i_type(0x03, funct3, rd, rs1, imm), f"{name} x{rd}, {imm}(x{rs1})"
    )


def store(name: str, rs2: int, rs1: int, imm: int) -> Instruction:
    """Encode a store."""
    funct3, _ = STORES[name]
    return Instruction(_s_type(funct3, rs1, rs2, imm), f"{name} x{rs2}, {imm}(x{rs1})")


def _ordering(aq: int, rl: int) -> str:
    return ("", ".rl", ".aq", ".aqrl")[(aq << 1) | rl]


def lr(rd: int, rs1: int, width: int, aq: int = 0, rl: int = 0) -> Instruction:
    """Encode LR.W or LR.D."""
    suffix = "d" if width == 8 else "w"
    return Instruction(
        _atomic(LR, aq, rl, rd, rs1, 0, width),
        f"lr.{suffix}{_ordering(aq, rl)} x{rd}, (x{rs1})",
    )


def sc(
    rd: int, rs2: int, rs1: int, width: int, aq: int = 0, rl: int = 0
) -> Instruction:
    """Encode SC.W or SC.D."""
    suffix = "d" if width == 8 else "w"
    return Instruction(
        _atomic(SC, aq, rl, rd, rs1, rs2, width),
        f"sc.{suffix}{_ordering(aq, rl)} x{rd}, x{rs2}, (x{rs1})",
    )


def amo(
    name: str, rd: int, rs2: int, rs1: int, width: int, aq: int = 0, rl: int = 0
) -> Instruction:
    """Encode an AMO."""
    suffix = "d" if width == 8 else "w"
    return Instruction(
        _atomic(AMOS[name], aq, rl, rd, rs1, rs2, width),
        f"{name}.{suffix}{_ordering(aq, rl)} x{rd}, x{rs2}, (x{rs1})",
    )


def branch(name: str, rs1: int, rs2: int, offset: int) -> Instruction:
    """Encode a conditional branch."""
    return Instruction(
        _b_type(BRANCHES[name], rs1, rs2, offset), f"{name} x{rs1}, x{rs2}, {offset}"
    )


def jal(rd: int, offset: int) -> Instruction:
    """Encode JAL."""
    return Instruction(_j_type(rd, offset), f"jal x{rd}, {offset}")


def jalr(rd: int, rs1: int, imm: int) -> Instruction:
    """Encode JALR."""
    return Instruction(_i_type(0x67, 0, rd, rs1, imm), f"jalr x{rd}, {imm}(x{rs1})")


def csr_read(rd: int, name: str) -> Instruction:
    """Encode a CSR read, CSRRS rd, csr, x0."""
    return Instruction(_i_type(0x73, 2, rd, 0, CSRS[name]), f"csrr x{rd}, {name}")


FENCE = Instruction(0x0FF0000F, "fence")
FENCE_I = Instruction(0x0000100F, "fence.i")
SFENCE_VMA = Instruction(0x12000073, "sfence.vma")
ECALL = Instruction(0x00000073, "ecall")


def set_address(rd: int, address: int) -> list[Instruction]:
    """Load a 32-bit address into rd, zero-extended."""
    upper = ((address + 0x800) >> 12) & 0xFFFFF
    lower = address - (upper << 12)
    if lower >= 0x800:
        lower -= 0x1000
    return [
        lui(rd, upper),
        alu_imm("slli", rd, rd, 32),
        alu_imm("srli", rd, rd, 32),
        alu_imm("addi", rd, rd, lower),
    ]


@dataclass
class Strand:
    """Instructions that shrinking keeps whole (noshrink) or may cut."""

    noshrink: bool
    instructions: list[Instruction]


class Generator:
    """Write one random test at a time."""

    def __init__(self, rng: random.Random, regions: list[Region]) -> None:
        """Draw every choice from rng; regions give the memory permissions."""
        self.rng = rng
        self.regions = regions
        self.bases: dict[int, int] = {}

    # -- Addresses ------------------------------------------------------------

    def _allows(self, address: int, size: int, kind: str) -> bool:
        return allows(self.regions, address, size, kind)

    def _base_choices(self, size: int, kind: str, safe: bool) -> list[int]:
        """List the base registers whose own address makes this access safe, or unsafe."""
        return [
            reg
            for reg, address in BASES.items()
            if self._allows(self.bases.get(reg, 0), size, kind) == safe
        ]

    def _pick_base(self, size: int, kind: str, safe_only: bool) -> int:
        safe = self._base_choices(size, kind, True)
        if safe_only or self.rng.random() < 0.8:
            return self.rng.choice(safe)
        return self.rng.choice(self._base_choices(size, kind, False) or safe)

    def _offset(self, size: int) -> int:
        """Pick a small non-negative offset aligned to the access size."""
        return size * self.rng.randrange(0, 0x48 // size)

    # -- Operands -------------------------------------------------------------

    def _data(self) -> int:
        return self.rng.choice(DATA)

    def _rd(self) -> int:
        return 0 if self.rng.random() < 0.05 else self._data()

    def _width(self) -> int:
        return self.rng.choice((4, 8))

    def _aqrl(self) -> tuple[int, int]:
        return self.rng.choice(((0, 0), (1, 0), (0, 1), (1, 1)))

    def _value(self, rd: int) -> list[Instruction]:
        """Set a data register to a random value, sign bits included."""
        rng = self.rng
        sequence = [
            lui(rd, rng.randrange(1 << 20)),
            alu_imm("addi", rd, rd, rng.randrange(-2048, 2048)),
        ]
        if rng.random() < 0.5:
            sequence.append(alu_imm("slli", rd, rd, rng.randrange(64)))
        if rng.random() < 0.5:
            sequence.append(alu_imm("xori", rd, rd, rng.randrange(-2048, 2048)))
        return sequence

    # -- Single operations ----------------------------------------------------

    def _alu(self) -> Instruction:
        rng = self.rng
        if rng.random() < 0.5:
            name = rng.choice(list(ALU_IMM))
            _, funct7, shift_bits = ALU_IMM[name]
            imm = (
                rng.randrange(1 << shift_bits)
                if funct7 is not None
                else rng.randrange(-2048, 2048)
            )
            return alu_imm(name, self._data(), self._data(), imm)
        return alu_reg(
            rng.choice(list(ALU_REG)), self._data(), self._data(), self._data()
        )

    def _memory(self, safe_only: bool) -> Instruction:
        """Make a load, store, or AMO; with safe_only, one that cannot fault."""
        rng = self.rng
        kind = rng.choice(("load", "store", "amo"))
        if kind == "amo":
            width = self._width()
            base = self._pick_base(width, "amo", safe_only)
            return amo(
                rng.choice(list(AMOS)),
                self._rd(),
                self._data(),
                base,
                width,
                *self._aqrl(),
            )
        names = LOADS if kind == "load" else STORES
        name = rng.choice(list(names))
        size = names[name][1]
        base = self._pick_base(size, kind, safe_only)
        offset = self._offset(size)
        if safe_only and not self._allows(self.bases.get(base, 0) + offset, size, kind):
            offset = 0
        if kind == "load":
            return load(name, self._rd(), base, offset)
        return store(name, self._data(), base, offset)

    def _control(self) -> Instruction:
        """Make a branch or jump; instructions come from the stream, so any target works."""
        rng = self.rng
        roll = rng.random()
        offset = 2 * rng.randrange(-32, 33)
        if roll < 0.6:
            return branch(
                rng.choice(list(BRANCHES)), self._data(), self._data(), offset
            )
        if roll < 0.85:
            return jal(rng.choice((0, 1, self._data())), offset)
        return jalr(
            rng.choice((0, 1, self._data())), self._data(), rng.randrange(-64, 64)
        )

    def _window_op(self) -> Instruction:
        """Make an operation that cannot trap or flush."""
        roll = self.rng.random()
        if roll < 0.3:
            return self._alu()
        if roll < 0.65:
            return self._memory(safe_only=True)
        if roll < 0.9:
            return self._control()
        if roll < 0.95:
            return FENCE
        width = self._width()
        return lr(self._rd(), self._pick_base(width, "lr", True), width, *self._aqrl())

    # -- Strands ----------------------------------------------------------------

    def _window(self) -> list[Instruction]:
        """Make a window: LR, operations that cannot trap or flush, then SC."""
        rng = self.rng
        width = self._width()
        lr_base = self._pick_base(width, "lr", True)
        window = [lr(self._rd(), lr_base, width, *self._aqrl())]
        window += [self._window_op() for _ in range(rng.randrange(0, 9))]
        sc_width = width if rng.random() < 0.8 else self._width()
        candidates = self._base_choices(sc_width, "sc", True)
        sc_base = (
            lr_base
            if lr_base in candidates and rng.random() < 0.7
            else rng.choice(candidates)
        )
        window.append(sc(self._rd(), self._data(), sc_base, sc_width, *self._aqrl()))
        return window

    def _free_op(self) -> list[Instruction]:
        """Make anything for outside a window, faults and flushes included."""
        rng = self.rng
        roll = rng.random()
        if roll < 0.2:
            return [self._alu()]
        if roll < 0.55:
            return [self._memory(safe_only=False)]
        if roll < 0.65:
            return [self._control()]
        if roll < 0.72:
            return self._value(self._data())
        if roll < 0.8:
            # SC outside a window, where no reservation is open: it fails.
            width = self._width()
            base = self._pick_base(width, "sc", safe_only=False)
            return [sc(self._rd(), self._data(), base, width, *self._aqrl())]
        if roll < 0.86:
            # An LR outside a window only where it faults, so no reservation
            # stays open.
            width = self._width()
            faulting = self._base_choices(width, "lr", False)
            if faulting:
                return [lr(self._rd(), rng.choice(faulting), width, *self._aqrl())]
            return [self._alu()]
        if roll < 0.93:
            return [csr_read(self._data(), rng.choice(list(CSRS)))]
        return [rng.choice((FENCE, FENCE_I, SFENCE_VMA, ECALL))]

    def test(self, length: int) -> list[Strand]:
        """Make one test of about `length` instructions."""
        rng = self.rng
        optional = [reg for reg in BASES if reg not in ALWAYS_SET]
        chosen = list(ALWAYS_SET) + rng.sample(
            optional, rng.randrange(2, len(optional) + 1)
        )
        self.bases = {reg: BASES[reg] for reg in chosen}
        strands = [Strand(True, set_address(reg, BASES[reg])) for reg in chosen]
        for reg in rng.sample(DATA, 6):
            strands.append(Strand(False, self._value(reg)))
        count = sum(len(strand.instructions) for strand in strands)
        while count < length:
            if rng.random() < 0.3:
                strand = Strand(True, self._window())
            else:
                strand = Strand(False, self._free_op())
            strands.append(strand)
            count += len(strand.instructions)
        return strands


def render(strands: list[Strand], header: list[str]) -> str:
    """Render a test as a QuickCheckVEngine trace file."""
    lines = [f"# {line}" if line else "#" for line in header]
    for strand in strands:
        lines.append(".noshrink" if strand.noshrink else ".shrink")
        lines += [
            f".4byte {inst.word:#010x} # {inst.text}" for inst in strand.instructions
        ]
    return "\n".join(lines) + "\n"


def write_tests(directory: Path, count: int, seed: int, length: int) -> list[Path]:
    """Write `count` tests from `seed` into `directory`; return their paths."""
    rng = random.Random(seed)
    generator = Generator(rng, load_regions())
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for index in range(count):
        header = [
            f"A-extension test {index} from seed {seed} (verif/testrig/atomics.py)"
        ]
        path = directory / f"atomics_{seed}_{index:04d}.S"
        path.write_text(render(generator.test(length), header), encoding="utf-8")
        paths.append(path)
    return paths

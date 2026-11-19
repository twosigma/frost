#!/usr/bin/env python3
# Copyright (c) 2026 John Goodacre.
# ruff: noqa: D101, D102, D103, D107, N818
"""Front-end fuzzer program generator (sync #20 item 7).

usage: fe_gen.py SEED OUT.S OUT.h [TARGET_OPS]

Writes a bare-metal RV64GC assembly program, fe_run(), and a header with the signature the
program must return. The program is built from a small structured IR that this script both
emits as assembly and executes in Python, so the expected signature is exact.

The IR mixes the control flow the fetch predictors learn and the PD stage redirects:
  - conditional branches with biased, data-dependent, periodic (loop counter) and phase-change
    directions, in if/else, skip and "branch over a call" shapes;
  - direct calls, indirect calls through `if (p) p()` on a function-pointer table (null entries
    make the guarding branch mostly taken with rare fall-through into the jalr), indirect calls
    through a register, jump tables (jr), early returns, loop breaks, nested calls;
  - compressed and 32-bit encodings in random mixes plus random padding, so branches and
    jalr instructions land in slot 1 and slot 2 packet positions at varied alignments;
  - loops whose body behavior is slow-changing (trained, then different) and phase flips.
The program returns the final 64-bit value of s0. The path through the program determines
which instructions update s0. Paths that differ only in padding have the same signature.
s1 holds the xorshift state, s2-s4 are loop counters saved per function, and a0-a2 are
temporaries.
"""

import os
import random
import sys

M = (1 << 64) - 1


def sext12(v):
    v &= 0xFFF
    return v - 0x1000 if v & 0x800 else v


class Ret(Exception):
    pass


class Brk(Exception):
    pass


class Budget(Exception):
    pass


class Cond:
    """A branch condition: setup asm, branch mnemonic/operands, python predicate (branch taken)."""

    def __init__(self, setup, mn, ops, ev):
        self.setup, self.mn, self.ops, self.ev = setup, mn, ops, ev


class Gen:
    def __init__(self, seed, attempt, maxtrip):
        self.rng = random.Random(seed * 7919 + attempt)
        self.maxtrip = maxtrip
        self.lbl = 0
        self.nfn = self.rng.randint(6, 14)
        self.tables = []  # (label, entries) entries: function index or None
        self.jts = []  # (label, [case labels])
        self.fns = []

    def new(self, p):
        self.lbl += 1
        return f".L{p}{self.lbl}"

    # ---- conditions -------------------------------------------------------------------------
    def make_cond(self, ld):
        r = self.rng
        kinds = ["bias", "bias", "bits", "cmp", "sig"]
        if ld > 0:
            kinds += ["period", "period", "phase", "phase"]
        k = r.choice(kinds)
        if k in ("bias", "bits"):
            bits = r.randint(1, 5) if k == "bias" else r.choice([1, 1, 2])
            sh = r.choice([0, 0, 1, 3, 7, 11, 19, 27, 35])
            mask = (1 << bits) - 1
            setup = ([f"srli a0, s1, {sh}"] if sh else ["mv a0, s1"]) + [
                f"andi a0, a0, {mask}"
            ]
            if r.random() < 0.5:
                return Cond(
                    setup,
                    "bnez",
                    "a0",
                    lambda s, f, sh=sh, m=mask: ((s.x >> sh) & m) != 0,
                )
            return Cond(
                setup, "beqz", "a0", lambda s, f, sh=sh, m=mask: ((s.x >> sh) & m) == 0
            )
        if k == "sig":
            mask = (1 << r.randint(1, 4)) - 1
            setup = [f"andi a0, s0, {mask}"]
            return Cond(setup, "bnez", "a0", lambda s, f, m=mask: (s.sig & m) != 0)
        if k == "cmp":
            mn = r.choice(["blt", "bge", "bltu", "bgeu", "beq", "bne"])
            ops = {
                "blt": lambda a, b: a < b,
                "bge": lambda a, b: a >= b,
                "bltu": lambda a, b: a < b,
                "bgeu": lambda a, b: a >= b,
                "beq": lambda a, b: a == b,
                "bne": lambda a, b: a != b,
            }[mn]
            mk = r.choice([0xFF, 0x3F, 0xF])
            setup = [f"andi a0, s1, {mk}", f"andi a1, s0, {mk}"]
            return Cond(
                setup,
                mn,
                "a0, a1",
                lambda s, f, op=ops, mk=mk: op(s.x & mk, s.sig & mk),
            )
        d = r.randint(1, ld)  # enclosing loop level whose counter is tested
        reg = f"s{1 + d}"
        if k == "period":
            mask = (1 << r.randint(1, 4)) - 1
            setup = [f"andi a0, {reg}, {mask}"]
            if r.random() < 0.5:
                return Cond(
                    setup, "bnez", "a0", lambda s, f, d=d, m=mask: (f[d - 1] & m) != 0
                )
            return Cond(
                setup, "beqz", "a0", lambda s, f, d=d, m=mask: (f[d - 1] & m) == 0
            )
        t = r.randint(1, max(2, self.maxtrip - 1))
        if r.random() < 0.5:
            return Cond(
                [f"li a0, {t}"],
                "blt",
                f"{reg}, a0",
                lambda s, f, d=d, t=t: f[d - 1] < t,
            )
        return Cond(
            [f"li a0, {t}"], "bge", f"{reg}, a0", lambda s, f, d=d, t=t: f[d - 1] >= t
        )

    # ---- statements -------------------------------------------------------------------------
    def block(self, fi, ld, nest, n, inloop):
        out = []
        r = self.rng
        callees = list(range(fi + 1, self.nfn))
        for _ in range(n):
            ch = (
                ["mix"] * 4
                + ["step", "feed", "pad", "pad"]
                + ["if"] * (6 if nest < 3 else 1)
            )
            if nest < 3 and ld < 3:
                ch += ["loop"] * 2
            if callees:
                ch += (
                    ["dcall"] * 2
                    + ["icall_tbl"] * 3
                    + ["icall_reg"] * 2
                    + ["bcall"] * 2
                )
            if nest < 3:
                ch += ["switch"]
            if fi != 0:
                ch += ["retif"]
            if inloop:
                ch += ["break", "slowstep"]
            k = r.choice(ch)
            if k == "mix":
                out.append(self.mix())
            elif k == "step":
                out.append(("step",))
            elif k == "feed":
                out.append(("feed", r.randint(1, 60)))
            elif k == "pad":
                out.append(
                    ("pad", r.choice(["cnop", "cnop", "nop32", "al4", "al8", "cnop2"]))
                )
            elif k == "if":
                c = self.make_cond(ld)
                shape = r.choice(["skip", "skip", "ifelse"])
                fall = self.block(fi, ld, nest + 1, r.randint(1, 3), inloop)
                taken = (
                    self.block(fi, ld, nest + 1, r.randint(1, 3), inloop)
                    if shape == "ifelse"
                    else []
                )
                out.append(("if", c, fall, taken))
            elif k == "loop":
                n_ = r.choice([2, 3, 4, 6, 8, 12, 16, 24, 32, 48])
                n_ = max(2, min(n_, self.maxtrip))
                body = self.block(fi, ld + 1, nest + 1, r.randint(2, 5), True)
                out.append(("loop", ld + 1, n_, body))
            elif k == "dcall":
                out.append(("dcall", r.choice(callees), r.choice(["call", "jal"])))
            elif k == "bcall":  # branch over a direct call (jal behind a branch)
                out.append(("bcall", self.make_cond(ld), r.choice(callees)))
            elif k == "icall_tbl":
                size = r.choice([2, 4, 8])
                pnull = r.choice([0.0, 0.125, 0.5, 0.75, 0.875])
                ent = [
                    None if r.random() < pnull else r.choice(callees)
                    for _ in range(size)
                ]
                lab = f"fe_tbl{len(self.tables)}"
                self.tables.append((lab, ent))
                out.append(
                    (
                        "icall_tbl",
                        lab,
                        ent,
                        r.choice([0, 0, 5, 9, 17, 29]),
                        r.randint(0, 2),
                        r.choice(["jalr0", "jalr1"]),
                    )
                )
            elif k == "icall_reg":
                out.append(("icall_reg", self.make_cond(ld), r.choice(callees)))
            elif k == "switch":
                size = r.choice([2, 4, 8])
                lab = f"fe_jt{len(self.jts)}"
                cases = [self.new("c") for _ in range(size)]
                self.jts.append((lab, cases))
                bodies = [
                    self.block(fi, ld, nest + 1, r.randint(1, 2), inloop)
                    for _ in range(size)
                ]
                out.append(("switch", lab, cases, bodies, r.choice([0, 4, 9, 14, 23])))
            elif k == "retif":
                out.append(("retif", self.make_cond(ld)))
            elif k == "break":
                out.append(("break", self.make_cond(ld)))
            elif k == "slowstep":
                out.append(("slowstep", ld, (1 << r.randint(2, 5)) - 1))
        return out

    def mix(self):
        r = self.rng
        f = r.randrange(7)
        if f == 0:
            return ("mix", 0, r.choice([i for i in range(-32, 32) if i]))
        if f == 1 or f == 2:
            return ("mix", f, r.randint(1, 63))
        if f in (3, 4, 6):
            return ("mix", f, 0)
        return ("mix", 5, sext12(r.randrange(1, 4096)))

    def build(self):
        for fi in range(self.nfn):
            n = self.rng.randint(6, 12) if fi == 0 else self.rng.randint(3, 8)
            body = self.block(fi, 0, 0, n, False)
            self.fns.append(
                {"body": body, "align": self.rng.choice([1, 2, 2, 4, 8, 16, 32, 64])}
            )


# ---- interpreter ----------------------------------------------------------------------------
class State:
    def __init__(self, cap):
        self.sig = 0
        self.x = 0
        self.ops = 0
        self.cap = cap


def tick(s, n=1):
    s.ops += n
    if s.ops > s.cap:
        raise Budget()


def xorshift(x):
    x ^= (x << 13) & M
    x ^= x >> 7
    x ^= (x << 17) & M
    return x


def run_block(g, s, f, blk):
    for st in blk:
        run_stmt(g, s, f, st)


def run_stmt(g, s, f, st):
    k = st[0]
    tick(s)
    if k == "mix":
        form, v = st[1], st[2]
        if form == 0:
            s.sig = (s.sig + v) & M
        elif form == 1:
            s.sig ^= (s.sig << v) & M
        elif form == 2:
            s.sig = (s.sig + (s.sig >> v)) & M
        elif form == 3:
            s.sig ^= s.x
        elif form == 4:
            s.sig = (s.sig + s.x) & M
        elif form == 5:
            s.sig ^= v & M
        else:
            s.sig = (s.sig - s.x) & M
    elif k == "step":
        s.x = xorshift(s.x)
    elif k == "feed":
        s.x = (s.x ^ (s.sig >> st[1])) | 1
    elif k == "pad":
        pass
    elif k == "if":
        run_block(g, s, f, st[3] if st[1].ev(s, f) else st[2])
    elif k == "loop":
        d, n, body = st[1], st[2], st[3]
        for i in range(n):
            f[d - 1] = i
            tick(s, 2)
            try:
                run_block(g, s, f, body)
            except Brk:
                break
    elif k == "dcall":
        run_fn(g, s, st[1])
    elif k == "bcall":
        if not st[1].ev(s, f):
            run_fn(g, s, st[2])
    elif k == "icall_tbl":
        ent, sh = st[2], st[3]
        t = ent[(s.x >> sh) & (len(ent) - 1)]
        if t is not None:
            run_fn(g, s, t)
    elif k == "icall_reg":
        if not st[1].ev(s, f):
            run_fn(g, s, st[2])
    elif k == "switch":
        idx = (s.x >> st[4]) & (len(st[2]) - 1)
        run_block(g, s, f, st[3][idx])
    elif k == "retif":
        if st[1].ev(s, f):
            raise Ret()
    elif k == "break":
        if st[1].ev(s, f):
            raise Brk()
    elif k == "slowstep":
        # x advances only when (loop counter & m) == 0: branch/target history is stable in between
        if (f[st[1] - 1] & st[2]) == 0:
            s.x = xorshift(s.x)


def run_fn(g, s, fi):
    f = [0, 0, 0]
    try:
        run_block(g, s, f, g.fns[fi]["body"])
    except Ret:
        pass


# ---- emitter --------------------------------------------------------------------------------
XS = (
    "slli a0, s1, 13",
    "xor s1, s1, a0",
    "srli a0, s1, 7",
    "xor s1, s1, a0",
    "slli a0, s1, 17",
    "xor s1, s1, a0",
)


class Emit:
    def __init__(self, g, rng):
        self.g, self.r, self.o = g, rng, []
        self.loopends = []
        self.epi = None

    def i(self, text):
        """One instruction; a quarter are forced to the 32-bit encoding."""
        if self.r.random() < 0.25:
            self.o += [".option push", ".option norvc", "    " + text, ".option pop"]
        else:
            self.o.append("    " + text)

    def raw(self, t):
        self.o.append(t)

    def cond_branch(self, c, target):
        for s in c.setup:
            self.i(s)
        self.i(f"{c.mn} {c.ops}, {target}")

    def block(self, blk):
        for st in blk:
            self.stmt(st)

    def shift_index(self, sh, mask):
        self.i(f"srli a0, s1, {sh}" if sh else "mv a0, s1")
        self.i(f"andi a0, a0, {mask}")
        self.i("slli a0, a0, 3")

    def stmt(self, st):
        k = st[0]
        if k == "mix":
            form, v = st[1], st[2]
            if form == 0:
                self.i(f"addi s0, s0, {v}")
            elif form == 1:
                self.i(f"slli a0, s0, {v}")
                self.i("xor s0, s0, a0")
            elif form == 2:
                self.i(f"srli a0, s0, {v}")
                self.i("add s0, s0, a0")
            elif form == 3:
                self.i("xor s0, s0, s1")
            elif form == 4:
                self.i("add s0, s0, s1")
            elif form == 5:
                self.i(f"xori s0, s0, {v}")
            else:
                self.i("sub s0, s0, s1")
        elif k == "step":
            for t in XS:
                self.i(t)
        elif k == "feed":
            self.i(f"srli a0, s0, {st[1]}")
            self.i("xor s1, s1, a0")
            self.i("ori s1, s1, 1")
        elif k == "pad":
            p = st[1]
            if p == "cnop":
                self.raw("    c.nop")
            elif p == "cnop2":
                self.raw("    c.nop")
                self.raw("    c.nop")
            elif p == "nop32":
                self.o += [
                    "    .option push",
                    "    .option norvc",
                    "    nop",
                    "    .option pop",
                ]
            elif p == "al4":
                self.raw("    .balign 4")
            else:
                self.raw("    .balign 8")
        elif k == "if":
            c, fall, taken = st[1], st[2], st[3]
            lt = self.g.new("t")
            self.cond_branch(c, lt)
            self.block(fall)
            if taken:
                lj = self.g.new("j")
                self.i(f"j {lj}")
                self.raw(f"{lt}:")
                self.block(taken)
                self.raw(f"{lj}:")
            else:
                self.raw(f"{lt}:")
        elif k == "loop":
            d, n, body = st[1], st[2], st[3]
            reg = f"s{1 + d}"
            ll = self.g.new("l")
            le = self.g.new("e")
            self.i(f"li {reg}, 0")
            self.raw(f"{ll}:")
            self.loopends.append(le)
            self.block(body)
            self.loopends.pop()
            self.i(f"addi {reg}, {reg}, 1")
            self.i(f"li a0, {n}")
            self.i(f"bne {reg}, a0, {ll}")
            self.raw(f"{le}:")
        elif k == "dcall":
            self.i(f"jal ra, fe_f{st[1]}" if st[2] == "jal" else f"call fe_f{st[1]}")
        elif k == "bcall":
            ls = self.g.new("s")
            self.cond_branch(st[1], ls)
            self.i(f"jal ra, fe_f{st[2]}")
            self.raw(f"{ls}:")
        elif k == "icall_tbl":
            lab, ent, sh, filler, jk = st[1], st[2], st[3], st[4], st[5]
            self.shift_index(sh, len(ent) - 1)
            self.i(f"la a1, {lab}")
            self.i("add a1, a1, a0")
            self.i("ld a1, 0(a1)")
            for _ in range(filler):
                self.raw("    c.nop")
            ls = self.g.new("s")
            self.i(f"beqz a1, {ls}")
            self.i("jalr ra, 0(a1)" if jk == "jalr0" else "jalr a1")
            self.raw(f"{ls}:")
        elif k == "icall_reg":
            ls = self.g.new("s")
            self.i(f"la a2, fe_f{st[2]}")
            self.cond_branch(st[1], ls)
            self.i("jalr ra, 0(a2)")
            self.raw(f"{ls}:")
        elif k == "switch":
            lab, cases, bodies, sh = st[1], st[2], st[3], st[4]
            lend = self.g.new("w")
            self.shift_index(sh, len(cases) - 1)
            self.i(f"la a1, {lab}")
            self.i("add a1, a1, a0")
            self.i("ld a1, 0(a1)")
            self.i("jr a1")
            for cl, b in zip(cases, bodies):
                self.raw(f"{cl}:")
                self.block(b)
                self.i(f"j {lend}")
            self.raw(f"{lend}:")
        elif k == "retif":
            self.cond_branch(st[1], self.epi)
        elif k == "break":
            self.cond_branch(st[1], self.loopends[-1])
        elif k == "slowstep":
            d, m = st[1], st[2]
            ls = self.g.new("s")
            self.i(f"andi a0, s{1 + d}, {m}")
            self.i(f"bnez a0, {ls}")
            for t in XS:
                self.i(t)
            self.raw(f"{ls}:")


def scan(blk, acc):
    for st in blk:
        k = st[0]
        if k in ("dcall", "bcall", "icall_tbl", "icall_reg"):
            acc["call"] = True
        if k == "loop":
            acc["depth"] = max(acc["depth"], st[1])
            scan(st[3], acc)
        elif k == "if":
            scan(st[2], acc)
            scan(st[3], acc)
        elif k == "switch":
            for b in st[3]:
                scan(b, acc)
        elif k == "slowstep":
            acc["depth"] = max(acc["depth"], st[1])


SAVE = (
    (56, "ra"),
    (48, "s0"),
    (40, "s1"),
    (32, "s2"),
    (24, "s3"),
    (16, "s4"),
    (8, "s5"),
)


def emit_program(g, seed, rounds, sig0, x0):
    e = Emit(g, random.Random(seed ^ 0x5EED))
    e.raw(f"# fefuzz seed {seed}: generated by fe_gen.py, do not edit")
    e.raw("    .text")
    e.raw("    .globl fe_run")
    e.raw("    .type fe_run, @function")
    e.raw("    .balign 4")
    e.raw("fe_run:")
    e.raw("    addi sp, sp, -64")
    for off, rg in SAVE:
        e.raw(f"    sd {rg}, {off}(sp)")
    e.raw(f"    li s0, {sig0}")
    e.raw(f"    li s1, {x0}")
    e.raw("    li s5, 0")
    e.raw(".Lrounds:")
    e.raw("    call fe_f0")
    e.raw("    addi s5, s5, 1")
    e.raw(f"    li a0, {rounds}")
    e.raw("    bne s5, a0, .Lrounds")
    e.raw("    mv a0, s0")
    for off, rg in SAVE:
        e.raw(f"    ld {rg}, {off}(sp)")
    e.raw("    addi sp, sp, 64")
    e.raw("    ret")
    for fi, fn in enumerate(g.fns):
        acc = {"call": False, "depth": 0}
        scan(fn["body"], acc)
        saved = (["ra"] if acc["call"] else []) + [
            f"s{2 + j}" for j in range(acc["depth"])
        ]
        frame = (len(saved) * 8 + 15) & ~15
        e.raw(f"    .balign {fn['align']}")
        e.raw(f"fe_f{fi}:")
        if saved:
            e.i(f"addi sp, sp, -{frame}")
            for j, rg in enumerate(saved):
                e.i(f"sd {rg}, {8 * j}(sp)")
        e.epi = g.new("epi")
        e.block(fn["body"])
        e.raw(f"{e.epi}:")
        if saved:
            for j, rg in enumerate(saved):
                e.i(f"ld {rg}, {8 * j}(sp)")
            e.i(f"addi sp, sp, {frame}")
        e.i("ret")
    # Include all generated callees in the address range sampled by the bench.
    e.raw("    .size fe_run, .-fe_run")
    e.raw("    .data")
    e.raw("    .balign 8")
    for lab, ent in g.tables:
        e.raw(f"{lab}:")
        for t in ent:
            e.raw(f"    .dword {'0' if t is None else f'fe_f{t}'}")
    for lab, cases in g.jts:
        e.raw(f"{lab}:")
        for c in cases:
            e.raw(f"    .dword {c}")
    return "\n".join(e.o) + "\n"


def main():
    seed = int(sys.argv[1], 0)
    out_s, out_h = sys.argv[2], sys.argv[3]
    target = (
        int(sys.argv[4])
        if len(sys.argv) > 4
        else int(os.environ.get("FE_TARGET", "6000"))
    )
    trips = [32, 16, 12, 8, 6, 4, 3, 2]
    rng = random.Random(seed)
    sig0 = rng.getrandbits(64)
    x0 = rng.getrandbits(64) | 1
    for attempt, mt in enumerate(trips * 4):
        g = Gen(seed, attempt, mt)
        g.build()
        s = State(max(target * 4, 20000))
        s.sig, s.x = sig0, x0
        try:
            run_fn(g, s, 0)
        except Budget:
            continue
        if s.ops < 300:
            continue
        rounds = max(1, min(60, target // max(1, s.ops)))
        s = State(target * 4)
        s.sig, s.x = sig0, x0
        try:
            for _ in range(rounds):
                run_fn(g, s, 0)
        except Budget:
            continue
        break
    else:
        raise SystemExit("fe_gen: no program within budget")
    text = emit_program(g, seed, rounds, sig0, x0)
    hdr = (
        f"/* fefuzz seed {seed}, generated by fe_gen.py */\n#define FE_SEED {seed}u\n"
        f"#define FE_ROUNDS {rounds}u\n#define FE_OPS {s.ops}u\n"
        f"#define FE_EXPECT 0x{s.sig:016x}ull\n"
    )
    for path, data in ((out_s, text), (out_h, hdr)):
        try:
            with open(path) as fh:
                if fh.read() == data:
                    continue
        except OSError:
            pass
        with open(path, "w") as fh:
            fh.write(data)
    print(
        f"fe_gen: seed {seed} functions {g.nfn} rounds {rounds} ops {s.ops} maxtrip {mt}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()

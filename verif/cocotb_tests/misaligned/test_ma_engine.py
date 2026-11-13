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

"""Misaligned-access engine unit tests.

A Python model plays the register file, the page-table walker and the line
client, each with random delays and response order. Every access is checked
against a reference: the exception and trap value, or the register written
and the memory bytes changed. A faulting access must leave memory untouched,
and the lower sector's request must be issued before the upper one.
"""

import random
from dataclasses import dataclass, field
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

SECTOR = 32
MASK64 = (1 << 64) - 1
DDR_BASE = 0x8000_0000
DDR_LIMIT = 0xC000_0000
BRAM_LIMIT = 0x4_0000

# Exception causes.
LOAD_MISALIGN, LOAD_ACCESS, STORE_MISALIGN, STORE_ACCESS = 4, 5, 6, 7
LOAD_PAGE, STORE_PAGE = 13, 15

# riscv_pkg::data_fault_kind_e
DFAULT_NONE, DFAULT_PAGE, DFAULT_ACCESS = 0, 2, 3

SIZE_CODE = {2: 1, 4: 2, 8: 3}  # bytes -> mem_size_e


def device_ok(pa: int) -> bool:
    """Return whether pa is in a device window (riscv_pkg::pma_device_ok)."""
    if pa >> 32:
        return False
    page = (pa >> 12) & 0xFFFFF
    return (
        0x40000 <= page <= 0x40030
        or (page >> 10) == (0x44000 >> 10)
        or (page >> 9) == 0x240
    )


def region(pa: int, quadrant_store: bool) -> str:
    """Return a part's region verdict: ok, misalign or access (ma_pkg::region)."""
    if DDR_BASE <= pa < DDR_LIMIT:
        return "ok"
    if pa < BRAM_LIMIT or device_ok(pa):
        return "misalign"
    if quadrant_store and (pa >> 32) == 0 and (pa >> 30) == 1:
        return "misalign"
    return "access"


@dataclass
class Leaf:
    """A page-table leaf: walk fault kind or a mapping with permissions."""

    fault: int = DFAULT_NONE
    ppn: int = 0
    level: int = 0
    r: int = 1
    w: int = 1
    x: int = 0
    u: int = 0
    d: int = 1


@dataclass
class Access:
    """One engine operation and the environment it runs in."""

    va: int
    nbytes: int
    store: bool
    unsigned: bool = False
    fp: bool = False
    rd: int = 5
    rd_valid: bool = True
    rs2: int = 7
    translate: bool = False
    priv_u: bool = False
    sum_: bool = False
    mxr: bool = False
    leaves: dict[int, Leaf] = field(default_factory=dict)
    error_ids: tuple[int, ...] = ()


class Env:
    """Register file, walker and line-client models around the DUT."""

    def __init__(self, dut: Any, rng: random.Random) -> None:
        """Hold the DUT, the random source and the memory, register and request state."""
        self.dut = dut
        self.rng = rng
        self.mem: dict[int, int] = {}  # byte address -> value
        self.regs = {(fp, i): rng.getrandbits(64) for fp in (0, 1) for i in range(32)}
        self.access: Access | None = None
        self.requests: list[
            tuple[int, int, int, int, int]
        ] = []  # id, write, addr, data, mask
        self.walks: list[int] = []
        self.fatal_stop = False
        # Line-client readiness: stop accepting after the first request.
        self.stall_after_first = False

    def byte(self, addr: int) -> int:
        """Return memory byte at addr (deterministic default pattern)."""
        return self.mem.get(addr, (addr * 37 + (addr >> 8) * 11) & 0xFF)

    def sector(self, base: int) -> int:
        """Return a 32-byte sector as an integer, byte 0 least significant."""
        return sum(self.byte(base + i) << (8 * i) for i in range(SECTOR))

    async def regfile(self) -> None:
        """Drive the register read data for the presented address every cycle."""
        while True:
            await RisingEdge(self.dut.i_clk)
            await ReadOnly()
            fp = int(self.dut.o_rf_read_fp.value)
            addr = int(self.dut.o_rf_read_addr.value)
            await FallingEdge(self.dut.i_clk)
            self.dut.i_rf_read_data.value = self.regs[(fp, addr)]

    async def walker(self) -> None:
        """Accept walks with random readiness and answer after random delays."""
        dut = self.dut
        pending: list[tuple[int, int]] = []  # (cycles left, vpn)
        while True:
            await FallingEdge(dut.i_clk)
            dut.i_walk_resp_valid.value = 0
            for i, (left, vpn) in enumerate(pending):
                pending[i] = (left - 1, vpn)
            if pending and pending[0][0] <= 0:
                _, vpn = pending.pop(0)
                assert self.access is not None
                leaf = self.access.leaves.get(vpn, Leaf(fault=DFAULT_PAGE))
                dut.i_walk_resp.value = pack_walk_resp(vpn, leaf)
                dut.i_walk_resp_valid.value = 1
            ready = self.rng.random() < 0.6
            dut.i_walk_req_ready.value = int(ready)
            await ReadOnly()
            if ready and int(dut.o_walk_req_valid.value):
                vpn = int(dut.o_walk_vpn.value)
                self.walks.append(vpn)
                pending.append((self.rng.randint(1, 6), vpn))

    async def line_client(self) -> None:
        """Accept sector requests and answer them in random order."""
        dut = self.dut
        pending: list[list[int]] = []  # [cycles left, id, write, addr, data, mask]
        while True:
            await FallingEdge(dut.i_clk)
            dut.i_lc_resp_valid.value = 0
            dut.i_lc_resp_error.value = 0
            for p in pending:
                p[0] -= 1
            due = [p for p in pending if p[0] <= 0]
            if due:
                p = self.rng.choice(due)
                pending.remove(p)
                _, rid, write, addr, data, mask = p
                assert self.access is not None
                error = rid in self.access.error_ids
                if write and not error:
                    for i in range(SECTOR):
                        if (mask >> i) & 1:
                            self.mem[addr + i] = (data >> (8 * i)) & 0xFF
                dut.i_lc_resp_valid.value = 1
                dut.i_lc_resp_id.value = rid
                dut.i_lc_resp_error.value = int(error)
                dut.i_lc_resp_data.value = 0 if write else self.sector(addr)
            ready = self.rng.random() < 0.7
            if self.stall_after_first and self.requests:
                ready = False
            dut.i_lc_req_ready.value = int(ready)
            await ReadOnly()
            if ready and int(dut.o_lc_req_valid.value):
                req = (
                    int(dut.o_lc_req_id.value),
                    int(dut.o_lc_req_write.value),
                    int(dut.o_lc_req_addr.value),
                    int(dut.o_lc_req_data.value),
                    int(dut.o_lc_req_mask.value),
                )
                self.requests.append(req)
                pending.append([self.rng.randint(1, 8), *req])


def pack_walk_resp(vpn: int, leaf: Leaf) -> int:
    """Pack riscv_pkg::ptw_resp_t (fault, vpn, ppn, level, r, w, x, u, d)."""
    value = leaf.fault
    value = (value << 27) | vpn
    value = (value << 44) | leaf.ppn
    value = (value << 2) | leaf.level
    for bit in (leaf.r, leaf.w, leaf.x, leaf.u, leaf.d):
        value = (value << 1) | bit
    return value


def canonical(va: int) -> bool:
    """Return whether va is a canonical Sv39 address."""
    top = va >> 38
    return top in (0, (1 << 26) - 1)


def translate_part(a: Access, va: int) -> tuple[str, int]:
    """Return (verdict, pa) for one part under the access's translation."""
    if not a.translate:
        return region(va, a.store), va
    if not canonical(va):
        return "page", 0
    vpn = (va >> 12) & ((1 << 27) - 1)
    leaf = a.leaves.get(vpn, Leaf(fault=DFAULT_PAGE))
    if leaf.fault == DFAULT_PAGE:
        return "page", 0
    if leaf.fault == DFAULT_ACCESS:
        return "access", 0
    priv_ok = (a.priv_u or a.sum_) if leaf.u else not a.priv_u
    perm = (
        priv_ok and leaf.w and leaf.d
        if a.store
        else priv_ok and (leaf.r or (a.mxr and leaf.x))
    )
    if not perm:
        return "page", 0
    if leaf.ppn >> 20:
        return "access", 0
    if leaf.level == 2:
        ppn = (leaf.ppn & ~((1 << 18) - 1)) | ((va >> 12) & ((1 << 18) - 1))
    elif leaf.level == 1:
        ppn = (leaf.ppn & ~((1 << 9) - 1)) | ((va >> 12) & ((1 << 9) - 1))
    else:
        ppn = leaf.ppn
    pa = (ppn << 12) | (va & 0xFFF)
    return region(pa, False), pa


def cause_of(verdict: str, store: bool) -> int:
    """Return the exception cause for a part verdict."""
    return {
        "misalign": STORE_MISALIGN if store else LOAD_MISALIGN,
        "page": STORE_PAGE if store else LOAD_PAGE,
        "access": STORE_ACCESS if store else LOAD_ACCESS,
    }[verdict]


def reference(a: Access) -> tuple[str, int, int, list[tuple[int, int]]]:
    """Return (kind, cause, tval, parts) where parts are (va, pa) pairs."""
    va = a.va
    split = (va % SECTOR) + a.nbytes > SECTOR
    upper = ((va >> 5) + 1) << 5 & MASK64
    lower_v, lower_pa = translate_part(a, va)
    if lower_v != "ok":
        return "fault", cause_of(lower_v, a.store), va, []
    parts = [(va, lower_pa)]
    if split:
        if a.translate and (upper >> 12) == (va >> 12):
            upper_pa = (lower_pa & ~0xFFF) | (upper & 0xFFF)
            upper_v = region(upper_pa, False)
        else:
            upper_v, upper_pa = translate_part(a, upper)
        if upper_v != "ok":
            tval = va if upper_v == "misalign" else upper
            return "fault", cause_of(upper_v, a.store), tval, []
        parts.append((upper, upper_pa))
    return "ok", 0, 0, parts


def expected_load(env: Env, a: Access, parts: list[tuple[int, int]]) -> int:
    """Return the register value a load writes."""
    raw = 0
    for k in range(a.nbytes):
        byte_va = (a.va + k) & MASK64
        if len(parts) == 2 and (byte_va - parts[1][0]) & MASK64 < SECTOR:
            pa = parts[1][1] + ((byte_va - parts[1][0]) & MASK64)
        else:
            pa = parts[0][1] + ((byte_va - parts[0][0]) & MASK64)
        raw |= env.byte(pa) << (8 * k)
    bits = 8 * a.nbytes
    if a.fp and a.nbytes == 4:
        return (0xFFFF_FFFF << 32) | raw
    if a.nbytes == 8 or a.unsigned:
        return raw
    if raw >> (bits - 1):
        raw |= MASK64 & ~((1 << bits) - 1)
    return raw


async def setup(dut: Any, seed: int) -> Env:
    """Start the clock and models, and reset the engine."""
    rng = random.Random(seed)
    Clock(dut.i_clk, 10, unit="ns").start()
    env = Env(dut, rng)
    for name in (
        "i_start",
        "i_va",
        "i_size",
        "i_unsigned",
        "i_store",
        "i_fp",
        "i_rd",
        "i_rd_valid",
        "i_rs2",
        "i_translate",
        "i_eff_priv_u",
        "i_sum",
        "i_mxr",
        "i_fatal_stop",
        "i_walk_req_ready",
        "i_walk_resp_valid",
        "i_walk_resp",
        "i_lc_req_ready",
        "i_lc_resp_valid",
        "i_lc_resp_id",
        "i_lc_resp_error",
        "i_lc_resp_data",
        "i_rf_read_data",
    ):
        getattr(dut, name).value = 0
    dut.i_older_vector_mem_done.value = 1
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    cocotb.start_soon(env.regfile())
    cocotb.start_soon(env.walker())
    cocotb.start_soon(env.line_client())
    return env


async def run_access(env: Env, a: Access, max_cycles: int = 400) -> dict[str, int]:
    """Start one access and return what the engine reported."""
    dut = env.dut
    env.access = a
    env.requests.clear()
    env.walks.clear()
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 1
    dut.i_va.value = a.va
    dut.i_size.value = SIZE_CODE[a.nbytes]
    dut.i_unsigned.value = int(a.unsigned)
    dut.i_store.value = int(a.store)
    dut.i_fp.value = int(a.fp)
    dut.i_rd.value = a.rd
    dut.i_rd_valid.value = int(a.rd_valid)
    dut.i_rs2.value = a.rs2
    dut.i_translate.value = int(a.translate)
    dut.i_eff_priv_u.value = int(a.priv_u)
    dut.i_sum.value = int(a.sum_)
    dut.i_mxr.value = int(a.mxr)
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 0
    result: dict[str, int] = {}
    for _ in range(max_cycles):
        await ReadOnly()
        if int(dut.o_wb_valid.value):
            result["wb"] = int(dut.o_wb_data.value)
            result["wb_rd"] = int(dut.o_wb_rd.value)
            result["wb_fp"] = int(dut.o_wb_fp.value)
        if int(dut.o_fault.value):
            result["fault"] = 1
            result["cause"] = int(dut.o_fault_cause.value)
            result["tval"] = int(dut.o_fault_tval.value)
        if int(dut.o_done.value):
            result["done"] = 1
        if int(dut.o_fatal_error.value):
            result["fatal"] = 1
        if (
            ("fault" in result or "done" in result or "fatal" in result)
            and not int(dut.o_busy.value)
            or "fatal" in result
        ):
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError(f"engine did not finish: {a}")
    await FallingEdge(dut.i_clk)
    # Let late responses drain before the next access.
    for _ in range(12):
        await FallingEdge(dut.i_clk)
    return result


def expected_walks(a: Access) -> list[int]:
    """Return the pages the engine must walk, in order."""
    if not a.translate:
        return []
    walks = []
    va = a.va
    if not canonical(va):
        return []
    walks.append((va >> 12) & ((1 << 27) - 1))
    if translate_part(a, va)[0] != "ok":
        return walks
    upper = ((va >> 5) + 1) << 5 & MASK64
    split = (va % SECTOR) + a.nbytes > SECTOR
    if split and (upper >> 12) != (va >> 12) and canonical(upper):
        walks.append((upper >> 12) & ((1 << 27) - 1))
    return walks


def check(env: Env, a: Access, before: dict[int, int], result: dict[str, int]) -> None:
    """Compare one access's outcome and memory effect with the reference."""
    kind, cause, tval, parts = reference(a)
    assert env.walks == expected_walks(a), ("walks", a, env.walks, expected_walks(a))
    if a.error_ids and kind == "ok":
        if a.store:
            assert result.get("fatal") == 1, (a, result)
            assert "done" not in result and "fault" not in result, (a, result)
        else:
            assert result.get("fault") == 1, (a, result)
            assert (result["cause"], result["tval"]) == (LOAD_ACCESS, 0), (a, result)
            assert "wb" not in result, (a, result)
        return
    if kind == "fault":
        assert result.get("fault") == 1 and "done" not in result, (a, result)
        assert (result["cause"], result["tval"]) == (cause, tval), (
            a,
            result,
            cause,
            tval,
        )
        assert not env.requests, ("memory request on a fault", a, env.requests)
        assert env.mem == before, ("memory changed on a fault", a)
        return
    assert result.get("done") == 1 and "fault" not in result, (a, result)
    ids = [r[0] for r in env.requests]
    assert ids == list(range(len(parts))), ("issue order", a, env.requests)
    for (rid, write, addr, _, _), (_, pa) in zip(env.requests, parts):
        assert write == int(a.store) and addr == pa & ~(SECTOR - 1), (a, env.requests)
    if a.store:
        assert "wb" not in result, (a, result)
        value = env.regs[(int(a.fp), a.rs2)]
        exp = dict(before)
        for k in range(a.nbytes):
            byte_va = (a.va + k) & MASK64
            if len(parts) == 2 and (byte_va - parts[1][0]) & MASK64 < SECTOR:
                pa = parts[1][1] + ((byte_va - parts[1][0]) & MASK64)
            else:
                pa = parts[0][1] + ((byte_va - parts[0][0]) & MASK64)
            exp[pa] = (value >> (8 * k)) & 0xFF
        assert env.mem == exp, ("store bytes", a)
    else:
        if a.rd_valid:
            assert result.get("wb") == expected_load(env, a, parts), (
                a,
                hex(result.get("wb", 0)),
                hex(expected_load(env, a, parts)),
            )
            assert result["wb_rd"] == a.rd and result["wb_fp"] == int(a.fp)
        else:
            assert "wb" not in result, (a, result)


def misaligned_va(rng: random.Random, base: int, nbytes: int) -> int:
    """Return a misaligned address near a sector, line or page end in base's page."""
    boundary = rng.choice([SECTOR, 64, 4096])
    page_off = rng.randrange(0, 4096, boundary) + boundary
    va = base + page_off - rng.randint(1, nbytes)
    if va % nbytes == 0:
        va += 1
    if rng.random() < 0.3:
        va = base + rng.randrange(0, 4096 - nbytes)
        if va % nbytes == 0:
            va += 1
    return va


def random_leaf(rng: random.Random, store: bool) -> Leaf:
    """Return a mostly valid leaf mapping into DDR, sometimes a faulting one."""
    choice = rng.random()
    ppn = (DDR_BASE >> 12) + rng.randrange(0, 4096)
    if choice < 0.70:
        return Leaf(ppn=ppn)
    if choice < 0.76:
        return Leaf(fault=DFAULT_PAGE)
    if choice < 0.80:
        return Leaf(fault=DFAULT_ACCESS)
    if choice < 0.86:
        return Leaf(ppn=ppn, w=0) if store else Leaf(ppn=ppn, r=0, x=1)
    if choice < 0.90:
        return Leaf(ppn=rng.choice([0x10, 0x40000, 0x50000]))  # BRAM, device, hole
    if choice < 0.94:
        return Leaf(ppn=ppn, u=1)
    if choice < 0.96:
        return Leaf(ppn=1 << 30)  # beyond the physical address width
    if choice < 0.98:
        return Leaf(ppn=(DDR_BASE >> 12) | (rng.randrange(4) << 9), level=1)
    return Leaf(ppn=DDR_BASE >> 12, level=2)


async def random_accesses(dut: Any, seed: int, count: int, translate: bool) -> None:
    """Run random accesses through the engine and check each."""
    env = await setup(dut, seed)
    rng = env.rng
    seen: dict[str, int] = {}
    for n in range(count):
        nbytes = rng.choice([2, 4, 8])
        store = rng.random() < 0.5
        if translate:
            base = rng.choice(
                [0x10_0000, 0x3F_FFFF_F000, 0x7_0000_0000, 0xFFFF_FFFF_FFFF_F000]
            )
            va = misaligned_va(rng, base, nbytes)
            a = Access(va=va, nbytes=nbytes, store=store, translate=True)
            a.priv_u = rng.random() < 0.3
            a.sum_ = rng.random() < 0.5
            a.mxr = rng.random() < 0.3
            for page in (va >> 12, (va >> 12) + 1):
                a.leaves[page & ((1 << 27) - 1)] = random_leaf(rng, store)
        else:
            base = rng.choice(
                [DDR_BASE + rng.randrange(0, 1 << 20, 4096)] * 6
                + [0x3_F000, 0x4003_0000, 0x5000_0000, DDR_LIMIT - 4096, 0x1_0000_0000]
                + [0xFFFF_FFFF_FFFF_F000]
            )
            va = misaligned_va(rng, base, nbytes)
            a = Access(va=va, nbytes=nbytes, store=store)
        a.unsigned = rng.random() < 0.5 and nbytes != 8
        a.fp = nbytes >= 4 and rng.random() < 0.3
        a.unsigned = a.unsigned and not a.fp
        a.rd = rng.randrange(32)
        a.rd_valid = rng.random() < 0.9
        a.rs2 = rng.randrange(32)
        if rng.random() < 0.05:
            a.error_ids = (rng.randrange(2),)
        before = dict(env.mem)
        result = await run_access(env, a)
        requested = {r[0] for r in env.requests}
        a.error_ids = tuple(set(a.error_ids) & requested)
        if a.error_ids and a.store:
            # A failed write is terminal: check it, then reset the engine.
            check(env, a, before, result)
            dut.i_rst.value = 1
            await FallingEdge(dut.i_clk)
            await FallingEdge(dut.i_clk)
            dut.i_rst.value = 0
            continue
        check(env, a, before, result)
        kind, cause, tval, parts = reference(a)
        if a.error_ids:
            key = "error"
        elif kind == "fault":
            key = "upper fault" if tval != a.va else "lower fault"
        else:
            key = ("split " if len(parts) == 2 else "single ") + (
                "store" if a.store else "load"
            )
        seen[key] = seen.get(key, 0) + 1
        dut._log.debug("access %d ok: %s", n, a)
    dut._log.info("outcomes: %s", seen)
    for key in (
        "split store",
        "split load",
        "single store",
        "single load",
        "lower fault",
    ):
        assert seen.get(key, 0) >= 10, (key, seen)
    if translate:
        assert seen.get("upper fault", 0) >= 5, seen


@cocotb.test()
async def test_bare_random(dut: Any) -> None:
    """Untranslated accesses across sectors, lines and pages, in every region."""
    await random_accesses(dut, seed=1, count=300, translate=False)


@cocotb.test()
async def test_translated_random(dut: Any) -> None:
    """Sv39 accesses with faulting, read-only, user, superpage and unmapped leaves."""
    await random_accesses(dut, seed=2, count=300, translate=True)


@cocotb.test()
async def test_upper_page_fault_leaves_memory(dut: Any) -> None:
    """A store whose upper page faults reports the upper page base and writes nothing."""
    env = await setup(dut, seed=3)
    va = 0x10_0FFD
    a = Access(va=va, nbytes=8, store=True, translate=True)
    a.leaves[va >> 12] = Leaf(ppn=DDR_BASE >> 12)
    a.leaves[(va >> 12) + 1] = Leaf(fault=DFAULT_PAGE)
    before = dict(env.mem)
    result = await run_access(env, a)
    assert result.get("fault") == 1
    assert (result["cause"], result["tval"]) == (STORE_PAGE, 0x10_1000)
    assert not env.requests and env.mem == before


@cocotb.test()
async def test_fatal_stop_is_terminal(dut: Any) -> None:
    """A hart stop while the engine waits on memory ends it with no completion."""
    env = await setup(dut, seed=4)
    a = Access(va=DDR_BASE + 0x1F, nbytes=8, store=True)
    env.access = a
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 1
    dut.i_va.value = a.va
    dut.i_size.value = SIZE_CODE[8]
    dut.i_store.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 0
    for _ in range(4):
        await FallingEdge(dut.i_clk)
    dut.i_fatal_stop.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_fatal_stop.value = 0
    for _ in range(60):
        await ReadOnly()
        assert int(dut.o_busy.value) == 1
        assert not int(dut.o_done.value) and not int(dut.o_fault.value)
        assert not int(dut.o_lc_req_valid.value) and not int(dut.o_wb_valid.value)
        await FallingEdge(dut.i_clk)


@cocotb.test()
async def test_waits_for_older_vector_memory(dut: Any) -> None:
    """The engine starts no work until older vector memory has completed."""
    env = await setup(dut, seed=5)
    a = Access(va=DDR_BASE + 0x3E, nbytes=4, store=False)
    env.access = a
    dut.i_older_vector_mem_done.value = 0
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 1
    dut.i_va.value = a.va
    dut.i_size.value = SIZE_CODE[4]
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 0
    for _ in range(30):
        await ReadOnly()
        assert not int(dut.o_lc_req_valid.value) and not int(dut.o_walk_req_valid.value)
        await FallingEdge(dut.i_clk)
    dut.i_older_vector_mem_done.value = 1
    for _ in range(200):
        await ReadOnly()
        if int(dut.o_done.value):
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError("engine did not finish after the vector condition cleared")


@cocotb.test()
async def test_store_error_stops_upper_request(dut: Any) -> None:
    """A failed lower write is terminal before the upper request is accepted."""
    env = await setup(dut, seed=6)
    a = Access(va=DDR_BASE + 0x1D, nbytes=8, store=True, error_ids=(0,))
    env.access = a
    env.stall_after_first = True
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 1
    dut.i_va.value = a.va
    dut.i_size.value = SIZE_CODE[8]
    dut.i_store.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 0
    for _ in range(200):
        await ReadOnly()
        if int(dut.o_fatal_error.value):
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError("no fatal error after a failed write")
    env.stall_after_first = False
    for _ in range(30):
        await FallingEdge(dut.i_clk)
        await ReadOnly()
        assert not int(dut.o_lc_req_valid.value), "request after a failed write"
        assert not int(dut.o_done.value) and not int(dut.o_fault.value)
    assert [r[0] for r in env.requests] == [0], env.requests


@cocotb.test()
async def test_stop_while_request_offered(dut: Any) -> None:
    """A hart stop on the edge a request is offered and ready accepts nothing."""
    env = await setup(dut, seed=7)
    a = Access(va=DDR_BASE + 0x3C, nbytes=8, store=False)
    env.access = a
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 1
    dut.i_va.value = a.va
    dut.i_size.value = SIZE_CODE[8]
    await FallingEdge(dut.i_clk)
    dut.i_start.value = 0
    for _ in range(200):
        await ReadOnly()
        if int(dut.o_lc_req_valid.value):
            break
        await FallingEdge(dut.i_clk)
    else:
        raise AssertionError("no request offered")
    await FallingEdge(dut.i_clk)
    dut.i_fatal_stop.value = 1
    await ReadOnly()
    assert not int(dut.o_lc_req_valid.value), "request offered while stopping"
    await FallingEdge(dut.i_clk)
    dut.i_fatal_stop.value = 0
    for _ in range(40):
        await ReadOnly()
        assert int(dut.o_busy.value) == 1
        assert not int(dut.o_lc_req_valid.value) and not int(dut.o_done.value)
        await FallingEdge(dut.i_clk)

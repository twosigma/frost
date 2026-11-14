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

"""Check vec_hold_rows against a reference model of the range-ordering rule.

Scalar entries and vector memory table entries are allocated in one program
order with ROB tags. Scalar entries get addresses later; table entries get
ranges, may retire and are freed (never reused in the cycle they are freed).
The model keeps, per scalar entry, the table entries that were older and live
when it was allocated (formed in the entry's first valid cycle, as the queue's
valid mirror sees it), and expects a hold whenever one of them is still live and
its range is unknown, the entry's address is unknown, the ranges overlap, or
the entry is atomic, with the overlap and its validity taken from the state a
cycle earlier. With DIRECT_ADDR (the store queue's form) the addresses come
from per-entry inputs instead of the update port, a cycle later.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

DEPTH = 8
VMT = 4


def covers(seg: tuple[int, int, int, int], sec: int) -> bool:
    """Return whether a segment (valid, ppn, lo, hi) covers a sector number."""
    valid, ppn, lo, hi = seg
    return bool(valid) and ppn == sec >> 7 and lo <= (sec & 127) <= hi


@cocotb.test()
async def test_vec_hold_rows_random(dut: Any) -> None:
    """Random traffic against the reference model."""
    rng = random.Random(2041)
    direct = int(dut.DIRECT_ADDR.value) == 1
    for sig in ("i_addr_flat", "i_size_flat", "i_addr_valid", "i_block_flat"):
        getattr(dut, sig).value = 0
    tagw = len(dut.i_head_tag)
    ntag = 1 << tagw
    # Entry width = 2 + tag + 1 + 2 * (1 + (PA - 12) + 14)
    seg_w = (len(dut.i_vmt) // VMT - 3 - tagw) // 2
    ppn_w = seg_w - 15
    ent_w = 3 + tagw + 2 * seg_w
    Clock(dut.i_clk, 2, unit="ns").start()
    dut.i_rst.value = 1
    for sig in (
        "i_valid",
        "i_tag_flat",
        "i_atomic",
        "i_head_tag",
        "i_upd_valid",
        "i_upd_idx",
        "i_upd_addr",
        "i_upd_size",
        "i_vmt",
    ):
        getattr(dut, sig).value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    seq = 0  # program order counter; tag = seq mod 32
    inflight: list[int] = []  # program-order sequence numbers not retired
    ent: list[Any] = [None] * DEPTH
    vmt: list[Any] = [None] * VMT
    prev_ovl: list[list[bool]] = [[False] * VMT for _ in range(DEPTH)]
    prev_ovl_valid: list[list[bool]] = [[False] * VMT for _ in range(DEPTH)]
    rows: list[list[bool]] = [[False] * VMT for _ in range(DEPTH)]
    built = [False] * DEPTH
    prev_head = 0
    addr_known = [False] * DEPTH  # the RTL's registered address-known bit
    checked = 0
    held = 0
    released = 0

    def vmt_word() -> int:
        word = 0
        for t in range(VMT - 1, -1, -1):
            e = vmt[t]
            segs = 0
            if e:
                for g in (1, 0):
                    s = e["segs"][g]
                    segs = (
                        (segs << seg_w)
                        | (s[0] << (seg_w - 1))
                        | (s[1] << 14)
                        | (s[2] << 7)
                        | s[3]
                    )
                word_e = (
                    (1 << (2 + tagw + 1 + 2 * seg_w - 1))
                    | (int(e["retired"]) << (tagw + 1 + 2 * seg_w))
                    | ((e["seq"] % ntag) << (1 + 2 * seg_w))
                    | (int(e["known"]) << (2 * seg_w))
                    | segs
                )
            else:
                word_e = 0
            word = (word << ent_w) | word_e
        return word

    for cycle in range(6000):
        # Next state: frees, retires, allocations, address and range writes.
        head_seq = min(inflight) if inflight else seq
        # Scalar entry frees (any time) and vector frees (only once retired).
        freed_s = set()
        for i in range(DEPTH):
            if ent[i] and rng.random() < 0.05:
                freed_s.add(i)
                if ent[i]["seq"] in inflight:
                    inflight.remove(ent[i]["seq"])
                ent[i] = None
        newly_freed = set()
        for t in range(VMT):
            e = vmt[t]
            if e and e["retired"] and rng.random() < 0.15:
                vmt[t] = None
                newly_freed.add(t)
            elif e and not e["retired"] and e["seq"] == head_seq and rng.random() < 0.3:
                e["retired"] = True
                inflight.remove(e["seq"])
        # Allocate (program order) when the window has room.
        upd = None
        # Keep the age window inside the tag space; a freed slot stays empty
        # for at least one cycle, as both queues and the table guarantee.
        # (against the previous cycle's head too, which the rows compare with:
        # the ROB holds every tag between them).
        if seq - prev_head < ntag - 4 and rng.random() < 0.5:
            free_v = [t for t in range(VMT) if vmt[t] is None and t not in newly_freed]
            free_s = [i for i in range(DEPTH) if ent[i] is None and i not in freed_s]
            if free_v and rng.random() < 0.3:
                t = rng.choice(free_v)
                vmt[t] = {
                    "seq": seq,
                    "retired": False,
                    "known": False,
                    "segs": [(0, 0, 0, 0), (0, 0, 0, 0)],
                }
                inflight.append(seq)
                seq += 1
            elif free_s:
                i = rng.choice(free_s)
                ent[i] = {
                    "seq": seq,
                    "atomic": rng.random() < 0.1,
                    "addr": None,
                    # Direct mode: a cbo.zero entry covering its 64-byte block
                    "block": direct and rng.random() < 0.15,
                }
                inflight.append(seq)
                seq += 1
        # Range writes.
        for t in range(VMT):
            e = vmt[t]
            if e and not e["known"] and rng.random() < 0.2:
                ppn = rng.randrange(4)
                assert ppn_w >= 2
                lo = rng.randrange(128)
                hi = min(127, lo + rng.randrange(4))
                e["segs"] = [
                    (1, ppn, lo, hi),
                    (rng.getrandbits(1), (ppn + 1) % 4, 0, rng.randrange(4)),
                ]
                e["known"] = rng.random() < 0.9
        # One address update.
        cand = [i for i in range(DEPTH) if ent[i] and ent[i]["addr"] is None]
        if cand and rng.random() < 0.5:
            i = rng.choice(cand)
            addr = (
                (rng.randrange(4) << 12) | (rng.randrange(128) << 5) | rng.randrange(32)
            )
            size = rng.randrange(4)
            ranged = [v for v in vmt if v and v["known"]]
            if ranged and rng.random() < 0.4:
                # A doubleword straddling the first or last sector of a range,
                # so only one of the access's two sectors is inside it.
                _, ppn, lo, hi = rng.choice(ranged)["segs"][0]
                edge = (lo << 5) if rng.random() < 0.5 else ((hi + 1) << 5)
                addr = (ppn << 12) + edge - rng.randrange(1, 8)
                addr %= 4 << 12
                size = 3
            upd = (i, addr, size)

        valid = sum(1 << i for i in range(DEPTH) if ent[i])
        tags = sum((ent[i]["seq"] % ntag) << (tagw * i) for i in range(DEPTH) if ent[i])
        atomic = sum(1 << i for i in range(DEPTH) if ent[i] and ent[i]["atomic"])
        dut.i_valid.value = valid
        dut.i_tag_flat.value = tags
        dut.i_atomic.value = atomic
        head_now = min(inflight) if inflight else seq
        dut.i_head_tag.value = head_now % ntag
        dut.i_vmt.value = vmt_word()
        # Direct mode: each entry's address, size and address-valid bit as of
        # the last edge (the store queue's registers).
        a_flat = s_flat = a_valid = 0
        for i in range(DEPTH):
            if ent[i] and ent[i]["addr"] is not None:
                a_flat |= ent[i]["addr"] << (64 * i)
                s_flat |= ent[i]["size"] << (2 * i)
                a_valid |= 1 << i
        dut.i_addr_flat.value = a_flat
        dut.i_size_flat.value = s_flat
        dut.i_addr_valid.value = a_valid
        dut.i_block_flat.value = sum(
            1 << i for i in range(DEPTH) if ent[i] and ent[i]["block"]
        )
        dut.i_upd_valid.value = 1 if upd and not direct else 0
        if upd:
            dut.i_upd_idx.value, dut.i_upd_addr.value, dut.i_upd_size.value = upd

        # Expected hold this cycle, from the model's registered state.
        exp = 0
        for i in range(DEPTH):
            e = ent[i]
            if not e:
                continue
            for t in range(VMT):
                v = vmt[t]
                # In the entry's first valid cycle its row is formed from the
                # table as it is now.
                row = (
                    rows[i][t]
                    if built[i]
                    else (v is not None and (v["retired"] or v["seq"] < e["seq"]))
                )
                if (
                    row
                    and v is not None
                    and (e["atomic"] or not prev_ovl_valid[i][t] or prev_ovl[i][t])
                ):
                    exp |= 1 << i
        await ReadOnly()
        got = int(dut.o_hold_d.value)
        if got != exp:
            bad = (got ^ exp).bit_length() - 1
            detail = {
                "entry": ent[bad],
                "built": built[bad],
                "row": rows[bad],
                "ovl_valid": prev_ovl_valid[bad],
                "ovl": prev_ovl[bad],
                "table": vmt,
                "head": head_now,
            }
            raise AssertionError(
                f"cycle {cycle}: hold {got:08b} want {exp:08b}: {detail}"
            )
        checked += 1
        held += bin(exp).count("1")
        released += sum(
            1
            for i in range(DEPTH)
            if ent[i] and built[i] and any(rows[i]) and not exp >> i & 1
        )
        await RisingEdge(dut.i_clk)
        # Registered model state, as of this edge.
        for i in range(DEPTH):
            e = ent[i]
            for t in range(VMT):
                v = vmt[t]
                live = v is not None
                if e is None:
                    rows[i][t] = False
                elif not built[i]:
                    rows[i][t] = live and (v["retired"] or v["seq"] < e["seq"])
                else:
                    rows[i][t] = rows[i][t] and live
                sec_known = addr_known[i] and e is not None
                prev_ovl_valid[i][t] = sec_known and live and v["known"]
                if sec_known:
                    lo_s = e["addr"] >> 5
                    hi_s = (e["addr"] + (1 << e["size"]) - 1) >> 5
                    if e["block"]:
                        lo_s = (e["addr"] >> 6) << 1
                        hi_s = lo_s + 1
                    prev_ovl[i][t] = live and any(
                        covers(s, x) for s in v["segs"] for x in (lo_s, hi_s)
                    )
                else:
                    prev_ovl[i][t] = False
            built[i] = e is not None
            if e is None:
                addr_known[i] = False
            elif direct:
                addr_known[i] = e["addr"] is not None
            else:
                addr_known[i] = addr_known[i] or (upd is not None and upd[0] == i)
        if upd:
            ent[upd[0]]["addr"], ent[upd[0]]["size"] = upd[1], upd[2]
        prev_head = head_now
        await FallingEdge(dut.i_clk)
    dut._log.info(
        f"{checked} cycles matched the model: {held} entry-cycles held, "
        f"{released} with an older live entry but no overlap"
    )
    assert held > 1000 and released > 200, "traffic too thin to exercise the rule"

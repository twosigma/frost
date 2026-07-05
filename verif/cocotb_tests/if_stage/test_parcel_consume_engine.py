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

"""Golden-model tests for the stage-2 parcel consume engine.

PARCEL_QUEUE_DESIGN.md section 2.3.  The consume engine is combinational: it
reads the parcel queue's presented view (head + head+1) and forms the two
IF->PD packets plus the dequeue count.  This suite drives packed pq_entry_t
values and checks every from_if_to_pd_t field against a reference.

Slot-2 RVC expansion is produced by the RTL rvc_decompressor (verified by its
own suite); here we check the *wiring* with a small table of known
decompressions and otherwise use native slot-2 instructions.
"""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer

# pq_entry_t field layout (offset, width), LSB..MSB (matches riscv_pkg).
_ENTRY_FIELDS = {
    "pc": (79, 31),
    "instr_bytes": (47, 32),
    "is_compressed": (46, 1),
    "allows_slot2_after": (45, 1),
    "slot2_start_ok": (44, 1),
    "btb_hit": (43, 1),
    "predicted_taken": (42, 1),
    "predicted_target": (11, 31),
    "dir_taken": (10, 1),
    "dir_idx": (0, 10),
}

# from_if_to_pd_t declaration order (MSB first); widths per riscv_pkg
# (RasPtrBits=3, BpDirIdxBits=10).
_PKT_DECL = [
    ("program_counter", 32),
    ("raw_parcel", 16),
    ("sel_nop", 1),
    ("sel_compressed", 1),
    ("effective_instr", 32),
    ("link_address", 32),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", 32),
    ("ras_predicted", 1),
    ("ras_predicted_target", 32),
    ("ras_checkpoint_tos", 3),
    ("ras_checkpoint_valid_count", 4),
    ("bp_dir_taken", 1),
    ("bp_dir_idx", 10),
    ("decomp_illegal", 1),
]


def _pkt_offsets() -> tuple[dict[str, tuple[int, int]], int]:
    """Return {field: (lsb_offset, width)} and the total packed width."""
    off: dict[str, tuple[int, int]] = {}
    pos = 0
    for name, width in reversed(_PKT_DECL):
        off[name] = (pos, width)
        pos += width
    return off, pos


_PKT_OFF, _PKT_BITS = _pkt_offsets()
assert _PKT_BITS == 200, _PKT_BITS

NOP = 0x00000013

# Known compressed -> 32-bit expansions (see test_rvc_decompressor for the full
# per-encoding reference).  c.nop -> addi x0,x0,0 ; c.li x10,0 -> addi x10,x0,0.
RVC_EXPAND = {0x0001: 0x00000013, 0x4501: 0x00000513}
RVC_ILLEGAL = {0x0000}  # c.addi4spn nzuimm=0 is reserved

C_NOP = 0x0001
C_LI = 0x4501
N_LUI = 0x12345637
N_LUI2 = 0xABCDE6B7


def _pack_entry(**fields: int) -> int:
    """Pack a pq_entry_t from named fields."""
    v = 0
    for name, (off, width) in _ENTRY_FIELDS.items():
        v |= (fields.get(name, 0) & ((1 << width) - 1)) << off
    return v


def _unpack_packet(v: int) -> dict[str, int]:
    """Unpack a from_if_to_pd_t integer into named fields."""
    return {
        name: (v >> off) & ((1 << width) - 1) for name, (off, width) in _PKT_OFF.items()
    }


def make_entry(
    pc_word: int,
    instr_bytes: int,
    *,
    is_compressed: int = 0,
    allows_slot2_after: int = 1,
    slot2_start_ok: int = 1,
    btb_hit: int = 0,
    predicted_taken: int = 0,
    predicted_target: int = 0,
    dir_taken: int = 0,
    dir_idx: int = 0,
) -> dict[str, int]:
    """Build an entry field dict (pc_word is the [31:1] word-pc)."""
    return {
        "pc": pc_word,
        "instr_bytes": instr_bytes,
        "is_compressed": is_compressed,
        "allows_slot2_after": allows_slot2_after,
        "slot2_start_ok": slot2_start_ok,
        "btb_hit": btb_hit,
        "predicted_taken": predicted_taken,
        "predicted_target": predicted_target,
        "dir_taken": dir_taken,
        "dir_idx": dir_idx,
    }


def _packet_from_entry(
    e: dict[str, int], valid: bool, *, is_slot2: bool
) -> dict[str, int | None]:
    """Build the reference packet for one slot (None fields are not checked)."""
    pkt: dict[str, int | None] = {name: 0 for name, _ in _PKT_DECL}
    pkt["sel_nop"] = 0 if valid else 1
    pkt["effective_instr"] = NOP
    if not valid:
        return pkt
    pc_full = e["pc"] << 1
    parcel = e["instr_bytes"] & 0xFFFF
    size = 2 if e["is_compressed"] else 4
    pkt["program_counter"] = pc_full
    pkt["raw_parcel"] = parcel
    pkt["sel_compressed"] = e["is_compressed"]
    pkt["link_address"] = pc_full + size
    pkt["btb_hit"] = e["btb_hit"]
    pkt["btb_predicted_taken"] = e["predicted_taken"]
    pkt["btb_predicted_target"] = e["predicted_target"] << 1
    pkt["bp_dir_idx"] = e["dir_idx"]
    if is_slot2:
        pkt["bp_dir_taken"] = 0  # slot-2 direction hint held 0 (matches HEAD)
        if e["is_compressed"]:
            if parcel in RVC_ILLEGAL:
                # The decompressor's expansion for a reserved parcel is
                # implementation-defined; only decomp_illegal is checked.
                pkt["effective_instr"] = None
                pkt["decomp_illegal"] = 1
            else:
                pkt["effective_instr"] = RVC_EXPAND[parcel]
        else:
            pkt["effective_instr"] = e["instr_bytes"] & 0xFFFFFFFF
    else:
        pkt["bp_dir_taken"] = e["dir_taken"]
        pkt["effective_instr"] = e["instr_bytes"] & 0xFFFFFFFF
    return pkt


def golden_consume(
    valid: int,
    e0: dict[str, int],
    e1: dict[str, int],
    *,
    stall: bool,
    flush: bool,
) -> dict[str, Any]:
    """Predict the slot-1/slot-2 packets and the dequeue count."""
    slot1_valid = bool(valid & 1) and not flush
    slot2_pair = (
        bool(valid & 2)
        and bool(e0["allows_slot2_after"])
        and bool(e1["slot2_start_ok"])
        and not e0["predicted_taken"]
    )
    slot2_valid = slot1_valid and slot2_pair
    deq = 0 if stall else (2 if slot2_valid else (1 if slot1_valid else 0))
    return {
        "slot1": _packet_from_entry(e0, slot1_valid, is_slot2=False),
        "slot2": _packet_from_entry(e1, slot2_valid, is_slot2=True),
        "deq": deq,
    }


async def _settle() -> None:
    """Let the combinational logic propagate."""
    await Timer(1, unit="ns")


async def drive_and_check(
    dut: Any,
    valid: int,
    e0: dict[str, int],
    e1: dict[str, int],
    *,
    stall: bool = False,
    flush: bool = False,
    ctx: str = "",
) -> None:
    """Drive one input configuration and check every output field."""
    dut.i_entry_valid.value = valid
    dut.i_entry0.value = _pack_entry(**e0)
    dut.i_entry1.value = _pack_entry(**e1)
    dut.i_stall.value = 1 if stall else 0
    dut.i_flush.value = 1 if flush else 0
    await _settle()

    exp = golden_consume(valid, e0, e1, stall=stall, flush=flush)
    assert (
        int(dut.o_deq_count.value) == exp["deq"]
    ), f"{ctx}: deq_count={int(dut.o_deq_count.value)} want {exp['deq']}"
    for slot_name, dut_sig in (("slot1", dut.o_slot1), ("slot2", dut.o_slot2)):
        got = _unpack_packet(int(dut_sig.value))
        for field, want in exp[slot_name].items():
            if want is None:
                continue  # implementation-defined (e.g. illegal-RVC expansion)
            assert (
                got[field] == want
            ), f"{ctx}: {slot_name}.{field}={got[field]:#x} want {want:#x}"


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_empty_queue_nops(dut: Any) -> None:
    """An empty presented view yields two NOP packets and deq_count 0."""
    e = make_entry(0, 0)
    await drive_and_check(dut, 0b00, e, e, ctx="empty")


@cocotb.test()
async def test_single_slot1(dut: Any) -> None:
    """One valid entry emits a slot-1 packet and a slot-2 NOP, deq_count 1."""
    e0 = make_entry(0x10 >> 1, N_LUI)
    e1 = make_entry(0, 0)
    await drive_and_check(dut, 0b01, e0, e1, ctx="single")


@cocotb.test()
async def test_bundle_native(dut: Any) -> None:
    """A two-wide native bundle emits both packets and deq_count 2."""
    e0 = make_entry(0x20 >> 1, N_LUI)
    e1 = make_entry(0x24 >> 1, N_LUI2)  # contiguous: 0x20 + 4
    await drive_and_check(dut, 0b11, e0, e1, ctx="bundle-native")


@cocotb.test()
async def test_bundle_rvc_slot2(dut: Any) -> None:
    """A compressed slot-2 is expanded by the consume-side decompressor."""
    e0 = make_entry(0x40 >> 1, C_NOP, is_compressed=1)
    e1 = make_entry(0x42 >> 1, C_LI, is_compressed=1)  # 0x40 + 2
    await drive_and_check(dut, 0b11, e0, e1, ctx="bundle-rvc")


@cocotb.test()
async def test_slot2_decomp_illegal(dut: Any) -> None:
    """An illegal compressed slot-2 sets decomp_illegal."""
    e0 = make_entry(0x50 >> 1, C_NOP, is_compressed=1)
    e1 = make_entry(0x52 >> 1, 0x0000, is_compressed=1)  # reserved RVC
    await drive_and_check(dut, 0b11, e0, e1, ctx="decomp-illegal")


@cocotb.test()
async def test_no_pair_allows_slot2(dut: Any) -> None:
    """e0.allows_slot2_after=0 blocks pairing (deq_count 1)."""
    e0 = make_entry(0x60 >> 1, N_LUI, allows_slot2_after=0)
    e1 = make_entry(0x64 >> 1, N_LUI2)
    await drive_and_check(dut, 0b11, e0, e1, ctx="no-pair-allows")


@cocotb.test()
async def test_no_pair_start_ok(dut: Any) -> None:
    """e1.slot2_start_ok=0 blocks pairing (deq_count 1)."""
    e0 = make_entry(0x70 >> 1, N_LUI)
    e1 = make_entry(0x74 >> 1, N_LUI2, slot2_start_ok=0)
    await drive_and_check(dut, 0b11, e0, e1, ctx="no-pair-start")


@cocotb.test()
async def test_no_pair_predicted_taken(dut: Any) -> None:
    """A predicted-taken slot-1 blocks pairing (head+1 is the target)."""
    e0 = make_entry(
        0x80 >> 1, N_LUI, predicted_taken=1, btb_hit=1, predicted_target=0x200 >> 1
    )
    e1 = make_entry(0x84 >> 1, N_LUI2)
    await drive_and_check(dut, 0b11, e0, e1, ctx="no-pair-taken")


@cocotb.test()
async def test_stall_freezes_dequeue(dut: Any) -> None:
    """A stall holds deq_count at 0 while still presenting the packets."""
    e0 = make_entry(0x90 >> 1, N_LUI)
    e1 = make_entry(0x94 >> 1, N_LUI2)
    await drive_and_check(dut, 0b11, e0, e1, stall=True, ctx="stall")


@cocotb.test()
async def test_flush_nops(dut: Any) -> None:
    """A flush forces two NOP packets and deq_count 0."""
    e0 = make_entry(0xA0 >> 1, N_LUI)
    e1 = make_entry(0xA4 >> 1, N_LUI2)
    await drive_and_check(dut, 0b11, e0, e1, flush=True, ctx="flush")


@cocotb.test()
async def test_metadata_passthrough(dut: Any) -> None:
    """BTB/direction metadata flows from entries to packets."""
    e0 = make_entry(
        0xB0 >> 1,
        N_LUI,
        btb_hit=1,
        predicted_taken=1,
        predicted_target=0x300 >> 1,
        dir_taken=1,
        dir_idx=0x155,
    )
    e1 = make_entry(
        0xB4 >> 1,
        N_LUI2,
        btb_hit=1,
        dir_idx=0x2AB,
    )
    # e0 predicted_taken suppresses pairing, so only slot-1 metadata is checked.
    await drive_and_check(dut, 0b11, e0, e1, ctx="metadata")


# ---------------------------------------------------------------------------
# Randomized soak
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_randomized_soak(dut: Any) -> None:
    """Soak random contiguous entry pairs, stalls, and flushes."""
    rng = random.Random(0xC0FFEE)

    def rand_entry(pc_word: int) -> dict[str, int]:
        is_c = rng.random() < 0.5
        if is_c:
            bytes_ = rng.choice([C_NOP, C_LI])  # keep RVC expansion predictable
        else:
            bytes_ = rng.getrandbits(32) | 0x3  # native low bits (advisory only)
        return make_entry(
            pc_word,
            bytes_,
            is_compressed=1 if is_c else 0,
            allows_slot2_after=rng.randint(0, 1),
            slot2_start_ok=rng.randint(0, 1),
            btb_hit=rng.randint(0, 1),
            predicted_taken=rng.randint(0, 1),
            predicted_target=rng.getrandbits(31),
            dir_taken=rng.randint(0, 1),
            dir_idx=rng.getrandbits(10),
        )

    for i in range(3000):
        pc0 = rng.getrandbits(30) << 1 >> 1  # 31-bit word-pc
        e0 = rand_entry(pc0 & 0x7FFFFFFF)
        size0 = 1 if e0["is_compressed"] else 2  # word-pc units
        e1 = rand_entry((e0["pc"] + size0) & 0x7FFFFFFF)  # contiguous successor
        valid = rng.choice([0b00, 0b01, 0b11, 0b11])
        stall = rng.random() < 0.15
        flush = rng.random() < 0.1
        await drive_and_check(
            dut, valid, e0, e1, stall=stall, flush=flush, ctx=f"soak-{i}"
        )

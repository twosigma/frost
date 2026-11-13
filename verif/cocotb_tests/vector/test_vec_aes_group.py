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

"""Check vec_aes_group against a Python AES model.

The model's own round functions first reproduce the FIPS-197 examples (an
AES-128 encryption and decryption, and the AES-128 and AES-256 key
expansions), built only from the operations the block implements. Then random
states, keys and round numbers, including out-of-range ones, run through every
operation back to back; each result is compared three cycles after the cycle
that takes the input.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 3
OPS = {"EF": 0, "EM": 1, "DF": 2, "DM": 3, "Z": 4, "KF1": 5, "KF2": 6}
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


def xtime(x: int) -> int:
    """Multiply by x in GF(2^8)."""
    return ((x << 1) ^ (0x1B if x & 0x80 else 0)) & 0xFF


def gmul(a: int, b: int) -> int:
    """Multiply in GF(2^8)."""
    p = 0
    while b:
        if b & 1:
            p ^= a
        a = xtime(a)
        b >>= 1
    return p


def make_sbox() -> list[int]:
    """Return the AES S-box."""
    box = []
    for x in range(256):
        inv = 0 if x == 0 else next(y for y in range(256) if gmul(x, y) == 1)
        r = inv
        for k in range(1, 5):
            r ^= ((inv << k) | (inv >> (8 - k))) & 0xFF
        box.append(r ^ 0x63)
    return box


SBOX = make_sbox()
INV_SBOX = [0] * 256
for _i, _v in enumerate(SBOX):
    INV_SBOX[_v] = _i


def to_bytes(x: int) -> list[int]:
    """Return the 16 bytes of a 128-bit group, byte 0 lowest."""
    return [(x >> (8 * j)) & 0xFF for j in range(16)]


def from_bytes(b: list[int]) -> int:
    """Return the 128-bit group of 16 bytes."""
    return sum(v << (8 * j) for j, v in enumerate(b))


def shift_rows(s: list[int], inverse: bool) -> list[int]:
    """Row r of column c takes column (c + r) or (c - r)."""
    out = [0] * 16
    for c in range(4):
        for r in range(4):
            src = (c - r) % 4 if inverse else (c + r) % 4
            out[4 * c + r] = s[4 * src + r]
    return out


def mix(s: list[int], inverse: bool) -> list[int]:
    """MixColumns or InvMixColumns."""
    m = (
        [[14, 11, 13, 9], [9, 14, 11, 13], [13, 9, 14, 11], [11, 13, 9, 14]]
        if inverse
        else [[2, 3, 1, 1], [1, 2, 3, 1], [1, 1, 2, 3], [3, 1, 1, 2]]
    )
    out = [0] * 16
    for c in range(4):
        col = s[4 * c : 4 * c + 4]
        for r in range(4):
            v = 0
            for k in range(4):
                v ^= gmul(col[k], m[r][k])
            out[4 * c + r] = v
    return out


def words(x: int) -> list[int]:
    """Return the four little-endian 32-bit words."""
    return [(x >> (32 * i)) & 0xFFFFFFFF for i in range(4)]


def sub_word(w: int) -> int:
    """Apply the S-box to each byte of a word."""
    return sum(SBOX[(w >> (8 * j)) & 0xFF] << (8 * j) for j in range(4))


def rot_word(w: int) -> int:
    """RotWord on a little-endian word: byte 1 moves to byte 0."""
    return ((w >> 8) | (w << 24)) & 0xFFFFFFFF


def model(op: str, rnd: int, state: int, key: int) -> int:
    """Return the block's result."""
    s = to_bytes(state)
    if op == "Z":
        return state ^ key
    if op in ("EF", "EM"):
        t = shift_rows([SBOX[v] for v in s], False)
        if op == "EM":
            t = mix(t, False)
        return from_bytes(t) ^ key
    if op in ("DF", "DM"):
        keyed = from_bytes([INV_SBOX[v] for v in shift_rows(s, True)]) ^ key
        return from_bytes(mix(to_bytes(keyed), True)) if op == "DM" else keyed
    if op == "KF1":
        if rnd == 0 or rnd > 10:
            rnd ^= 8
        k = words(key)
        w = [k[0] ^ sub_word(rot_word(k[3])) ^ RCON[rnd - 1]]
    else:
        if rnd < 2 or rnd > 14:
            rnd ^= 8
        k = words(key)
        sched = (
            sub_word(k[3])
            if rnd & 1
            else sub_word(rot_word(k[3])) ^ RCON[(rnd >> 1) - 1]
        )
        k = words(state)
        w = [k[0] ^ sched]
    for i in range(1, 4):
        w.append(k[i] ^ w[i - 1])
    return sum(v << (32 * i) for i, v in enumerate(w))


def check_model() -> None:
    """Reproduce FIPS-197 C.1 (AES-128) and C.3's first expanded key word (AES-256)."""
    key = from_bytes(list(bytes.fromhex("000102030405060708090a0b0c0d0e0f")))
    pt = from_bytes(list(bytes.fromhex("00112233445566778899aabbccddeeff")))
    keys = [key]
    for r in range(1, 11):
        keys.append(model("KF1", r, 0, keys[-1]))
    s = model("Z", 0, pt, keys[0])
    for r in range(1, 10):
        s = model("EM", 0, s, keys[r])
    s = model("EF", 0, s, keys[10])
    assert bytes(to_bytes(s)).hex() == "69c4e0d86a7b0430d8cdb78070b4c55a"
    s = model("Z", 0, s, keys[10])
    for r in range(9, 0, -1):
        s = model("DM", 0, s, keys[r])
    s = model("DF", 0, s, keys[0])
    assert bytes(to_bytes(s)).hex() == "00112233445566778899aabbccddeeff"
    k256 = bytes.fromhex(
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    )
    k0, k1 = from_bytes(list(k256[:16])), from_bytes(list(k256[16:]))
    k2 = model("KF2", 2, k0, k1)
    assert bytes(to_bytes(k2)).hex() == "a573c29fa176c498a97fce93a572c09c"


@cocotb.test()
async def test_vec_aes_group_random(dut: Any) -> None:
    """Every operation on random values, back to back."""
    check_model()
    rng = random.Random(2032)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in ("i_valid", "i_op", "i_rnd", "i_state", "i_key"):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    names = list(OPS)
    count = 3000
    pending: dict[int, tuple[str, int, int, int, int]] = {}
    checked = 0
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            op = names[cycle % len(names)] if cycle < 7 * 16 else rng.choice(names)
            rnd = cycle % 16 if cycle < 7 * 16 else rng.randrange(16)
            state, key = rng.getrandbits(128), rng.getrandbits(128)
            dut.i_valid.value = 1
            dut.i_op.value = OPS[op]
            dut.i_rnd.value = rnd
            dut.i_state.value = state
            dut.i_key.value = key
            pending[cycle] = (op, rnd, state, key, model(op, rnd, state, key))
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            op, rnd, state, key, want = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got = int(dut.o_result.value)
            assert got == want, (
                f"{op} rnd={rnd} state={state:#x} key={key:#x}: {got:#x} want {want:#x}"
            )
            checked += 1
        await FallingEdge(dut.i_clk)
    assert checked == count
    dut._log.info(f"{checked} AES operations checked")

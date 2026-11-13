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

"""Check vec_sha2_group against a Python model of vsha2ms, vsha2cl and vsha2ch.

The model's operations first compress the padded one-block message "abc" into
the SHA-256 and SHA-512 digests that hashlib computes, using the instruction
sequence a vector SHA-2 kernel uses. Then random groups run through every
operation at both element widths back to back; each result is compared four
cycles after the cycle that takes the input.
"""

import hashlib
import random
import struct
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LATENCY = 4
OPS = {"MS": 0, "CL": 1, "CH": 2}
K256 = [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2,
]


def k512() -> list[int]:
    """Return the SHA-512 constants (fractional cube roots of the first 80 primes)."""
    primes: list[int] = []
    n = 2
    while len(primes) < 80:
        if all(n % p for p in primes if p * p <= n):
            primes.append(n)
        n += 1
    out = []
    for p in primes:
        lo, hi = 0, 1 << 70
        while lo < hi:  # integer cube root of p * 2**192
            mid = (lo + hi + 1) // 2
            if mid**3 <= p << 192:
                lo = mid
            else:
                hi = mid - 1
        out.append(lo & ((1 << 64) - 1))
    return out


K512 = k512()


def ror(x: int, n: int, w: int) -> int:
    """Rotate right within w bits."""
    return ((x >> n) | (x << (w - n))) & ((1 << w) - 1)


def sigmas(w: int) -> tuple[Any, Any, Any, Any]:
    """Return (Sigma0, Sigma1, sigma0, sigma1) for word width w."""
    if w == 32:
        return (
            lambda x: ror(x, 2, 32) ^ ror(x, 13, 32) ^ ror(x, 22, 32),
            lambda x: ror(x, 6, 32) ^ ror(x, 11, 32) ^ ror(x, 25, 32),
            lambda x: ror(x, 7, 32) ^ ror(x, 18, 32) ^ (x >> 3),
            lambda x: ror(x, 17, 32) ^ ror(x, 19, 32) ^ (x >> 10),
        )
    return (
        lambda x: ror(x, 28, 64) ^ ror(x, 34, 64) ^ ror(x, 39, 64),
        lambda x: ror(x, 14, 64) ^ ror(x, 18, 64) ^ ror(x, 41, 64),
        lambda x: ror(x, 1, 64) ^ ror(x, 8, 64) ^ (x >> 7),
        lambda x: ror(x, 19, 64) ^ ror(x, 61, 64) ^ (x >> 6),
    )


def model(op: str, w: int, vd: list[int], vs2: list[int], vs1: list[int]) -> list[int]:
    """Return the four result words."""
    m = (1 << w) - 1
    big0, big1, sm0, sm1 = sigmas(w)
    if op == "MS":
        wv = vd + [vs2[0], 0, 0, 0, 0, vs2[1], vs2[2], vs2[3]] + vs1
        for t in range(16, 20):
            wv.append((sm1(wv[t - 2]) + wv[t - 7] + sm0(wv[t - 15]) + wv[t - 16]) & m)
        return wv[16:20]
    h, g, d, c = vd
    f, e, b, a = vs2
    wk = vs1[2:4] if op == "CH" else vs1[0:2]
    for k in wk:
        t1 = (h + big1(e) + ((e & f) ^ (~e & g)) + k) & m
        t2 = (big0(a) + ((a & b) ^ (a & c) ^ (b & c))) & m
        h, g, f, e, d, c, b, a = g, f, e, (d + t1) & m, c, b, a, (t1 + t2) & m
    return [f, e, b, a]


def compress(w: int, block: bytes, state: list[int]) -> list[int]:
    """One SHA-2 block through the instruction sequence of a vector kernel."""
    m = (1 << w) - 1
    kk = K256 if w == 32 else K512
    rounds = 64 if w == 32 else 80
    fmt = ">16I" if w == 32 else ">16Q"
    msg = list(struct.unpack(fmt, block))
    a, b, c, d, e, f, g, h = state
    abef = [f, e, b, a]
    cdgh = [h, g, d, c]
    sched = [msg[0:4], msg[4:8], msg[8:12], msg[12:16]]
    for q in range(rounds // 4):
        words = sched[q % 4]
        wk = [(words[i] + kk[4 * q + i]) & m for i in range(4)]
        # After two rounds the old {f, e, b, a} are the new {h, g, d, c}.
        cdgh, abef = abef, model("CL", w, cdgh, abef, wk)
        cdgh, abef = abef, model("CH", w, cdgh, abef, wk)
        if q + 4 < rounds // 4:
            w0, w1, w2, w3 = (
                sched[q % 4],
                sched[(q + 1) % 4],
                sched[(q + 2) % 4],
                sched[(q + 3) % 4],
            )
            sched[q % 4] = model("MS", w, w0, [w1[0], w2[1], w2[2], w2[3]], w3)
    f, e, b, a = abef
    h, g, d, c = cdgh
    return [(x + y) & m for x, y in zip(state, [a, b, c, d, e, f, g, h])]


def check_model() -> None:
    """Reproduce the SHA-256 and SHA-512 digests of "abc"."""
    block256 = b"abc" + b"\x80" + b"\x00" * 52 + struct.pack(">Q", 24)
    iv256 = [
        0x6A09E667,
        0xBB67AE85,
        0x3C6EF372,
        0xA54FF53A,
        0x510E527F,
        0x9B05688C,
        0x1F83D9AB,
        0x5BE0CD19,
    ]
    out = compress(32, block256, iv256)
    assert struct.pack(">8I", *out) == hashlib.sha256(b"abc").digest()
    block512 = b"abc" + b"\x80" + b"\x00" * 108 + struct.pack(">QQ", 0, 24)
    iv512 = [
        0x6A09E667F3BCC908,
        0xBB67AE8584CAA73B,
        0x3C6EF372FE94F82B,
        0xA54FF53A5F1D36F1,
        0x510E527FADE682D1,
        0x9B05688C2B3E6C1F,
        0x1F83D9ABFB41BD6B,
        0x5BE0CD19137E2179,
    ]
    out = compress(64, block512, iv512)
    assert struct.pack(">8Q", *out) == hashlib.sha512(b"abc").digest()


def pack(words: list[int], w: int) -> int:
    """Pack four words, word 0 lowest."""
    return sum(v << (w * k) for k, v in enumerate(words))


@cocotb.test()
async def test_vec_sha2_group_random(dut: Any) -> None:
    """Every operation at SEW 32 and 64, back to back."""
    check_model()
    rng = random.Random(2033)
    Clock(dut.i_clk, 2, unit="ns").start()
    for sig in ("i_valid", "i_op", "i_sew64", "i_vd", "i_vs2", "i_vs1"):
        getattr(dut, sig).value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0

    names = list(OPS)
    count = 3000
    pending: dict[int, tuple[str, int, int]] = {}
    checked = 0
    for cycle in range(count + LATENCY + 1):
        if cycle < count:
            op = rng.choice(names)
            w = rng.choice([32, 64])
            vd, vs2, vs1 = ([rng.getrandbits(w) for _ in range(4)] for _ in range(3))
            dut.i_valid.value = 1
            dut.i_op.value = OPS[op]
            dut.i_sew64.value = int(w == 64)
            dut.i_vd.value = pack(vd, w)
            dut.i_vs2.value = pack(vs2, w)
            dut.i_vs1.value = pack(vs1, w)
            pending[cycle] = (op, w, pack(model(op, w, vd, vs2, vs1), w))
        else:
            dut.i_valid.value = 0
        await RisingEdge(dut.i_clk)
        await ReadOnly()
        origin = cycle - LATENCY
        if origin in pending:
            op, w, want = pending.pop(origin)
            assert int(dut.o_valid.value) == 1
            got = int(dut.o_result.value)
            assert got == want, f"{op} SEW {w}: {got:#x} want {want:#x}"
            checked += 1
        await FallingEdge(dut.i_clk)
    assert checked == count
    dut._log.info(f"{checked} SHA-2 operations checked")

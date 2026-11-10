# Copyright (c) 2026 John Goodacre.

"""Unit bench for nic_tx_segment, the TCP segmentation stage.

Real IPv4 and IPv6 TCP packets (with VLAN tags, IP and TCP options, and every
header length modulo 8) go in as beats; a Python model cuts them as Linux's
software segmentation does and every segment out must match byte for byte:
total length, identification, IPv4 header checksum, sequence number, flags and
the TCP checksum field (the pseudo-header sum plus the segment's TCP length).
The model also covers back-to-back plain and segmented frames, the checksum request
each frame carries, and frames the stage must drop or repair.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

FIN, SYN, RST, PSH, ACK, URG, ECE, CWR = 1, 2, 4, 8, 16, 32, 64, 128


def fold(x: int) -> int:
    """Fold carries back into 16 bits."""
    while x >> 16:
        x = (x & 0xFFFF) + (x >> 16)
    return x


def words_sum(data: bytes) -> int:
    """Return the ones-complement sum of 16-bit big-endian words, an odd last byte padded."""
    if len(data) % 2:
        data += b"\x00"
    return fold(
        sum(int.from_bytes(data[i : i + 2], "big") for i in range(0, len(data), 2))
    )


def ip4_checksum(header: bytes) -> int:
    """Return the IPv4 header checksum of a header."""
    h = bytearray(header)
    h[10:12] = b"\x00\x00"
    return (~words_sum(bytes(h))) & 0xFFFF


class Packet:
    """A TCP packet and everything the model needs to segment it."""

    def __init__(
        self,
        rng: random.Random,
        *,
        ip6: bool = False,
        vlan: bool = False,
        ip_opt_words: int = 0,
        tcp_opt_words: int = 0,
        payload_len: int = 3000,
        flags: int = ACK | PSH | FIN | CWR,
        mss: int = 1460,
    ) -> None:
        """Build a random TCP packet of the given shape."""
        self.ip6, self.vlan, self.mss = ip6, vlan, mss
        self.payload = bytes(rng.getrandbits(8) for _ in range(payload_len))
        eth = bytes(rng.getrandbits(8) for _ in range(12))
        if vlan:
            eth += b"\x81\x00" + bytes([rng.getrandbits(8), rng.getrandbits(8)])
        eth += b"\x86\xdd" if ip6 else b"\x08\x00"
        self.l3 = len(eth)
        self.tcp_hl = 20 + 4 * tcp_opt_words
        self.seq0 = rng.getrandbits(32)
        self.id0 = rng.getrandbits(16)
        self.flags = flags
        if ip6:
            src = bytes(rng.getrandbits(8) for _ in range(16))
            dst = bytes(rng.getrandbits(8) for _ in range(16))
            self.ip_len = 40
            ip = (
                bytes([0x60, 0x12, 0x34, 0x56])
                + b"\xbe\xef"
                + bytes([6, 64])
                + src
                + dst
            )
            pseudo = words_sum(src + dst + b"\x00\x06")
        else:
            src = bytes(rng.getrandbits(8) for _ in range(4))
            dst = bytes(rng.getrandbits(8) for _ in range(4))
            self.ip_len = 20 + 4 * ip_opt_words
            ip = (
                bytes([0x40 | (self.ip_len // 4), rng.getrandbits(8)])
                + b"\xbe\xef"
                + self.id0.to_bytes(2, "big")
                + b"\x40\x00"
                + bytes([64, 6])
                + b"\x12\x34"
                + src
                + dst
                + bytes(rng.getrandbits(8) for _ in range(4 * ip_opt_words))
            )
            pseudo = words_sum(src + dst + b"\x00\x06")
        self.seed = pseudo
        tcp = (
            bytes(
                [
                    rng.getrandbits(8),
                    rng.getrandbits(8),
                    rng.getrandbits(8),
                    rng.getrandbits(8),
                ]
            )
            + self.seq0.to_bytes(4, "big")
            + bytes(rng.getrandbits(8) for _ in range(4))
            + bytes([(self.tcp_hl // 4) << 4, flags])
            + bytes([rng.getrandbits(8), rng.getrandbits(8)])
            + pseudo.to_bytes(2, "big")
            + bytes([rng.getrandbits(8), rng.getrandbits(8)])
            + bytes(rng.getrandbits(8) for _ in range(4 * tcp_opt_words))
        )
        self.header = eth + ip + tcp
        self.l4 = self.l3 + self.ip_len
        self.hdr_len = len(self.header)
        self.frame = self.header + self.payload

    def config(self) -> dict[str, int]:
        """Return the segmentation configuration the stage receives with the frame."""
        return {
            "segment": 1,
            "mss": self.mss,
            "payload": len(self.payload),
            "l4off2": self.l4 // 2,
            "tcphl4": self.tcp_hl // 4,
            "ip6": int(self.ip6),
            "vlan": int(self.vlan),
        }

    def segments(self) -> list[bytes]:
        """Return the frames Linux's software segmentation makes from the packet."""
        out = []
        sent = 0
        rem = len(self.payload)
        k = 0
        while rem > 0:
            plen = min(self.mss, rem)
            last = plen == rem
            h = bytearray(self.header)
            if self.ip6:
                h[self.l3 + 4 : self.l3 + 6] = (
                    self.hdr_len - self.l3 - 40 + plen
                ).to_bytes(2, "big")
            else:
                h[self.l3 + 2 : self.l3 + 4] = (self.hdr_len - self.l3 + plen).to_bytes(
                    2, "big"
                )
                h[self.l3 + 4 : self.l3 + 6] = ((self.id0 + k) & 0xFFFF).to_bytes(
                    2, "big"
                )
                h[self.l3 + 10 : self.l3 + 12] = ip4_checksum(
                    bytes(h[self.l3 : self.l3 + self.ip_len])
                ).to_bytes(2, "big")
            h[self.l4 + 4 : self.l4 + 8] = ((self.seq0 + sent) & 0xFFFFFFFF).to_bytes(
                4, "big"
            )
            f = self.flags
            if not last:
                f &= ~(FIN | PSH)
            if k != 0:
                f &= ~CWR
            h[self.l4 + 13] = f & 0xFF
            h[self.l4 + 16 : self.l4 + 18] = fold(
                self.seed + self.tcp_hl + plen
            ).to_bytes(2, "big")
            out.append(bytes(h) + self.payload[sent : sent + plen])
            sent += plen
            rem -= plen
            k += 1
        return out

    def csum_request(self) -> int:
        """Return the checksum request every segment carries."""
        return (8 << 8) | ((self.l4 // 2) << 1) | 1


class Bench:
    """Drive frames and gaps into the stage and collect what comes out."""

    def __init__(
        self, dut: Any, seed: int, in_gap: float = 0.0, out_gap: float = 0.0
    ) -> None:
        """Start with no frames queued."""
        self.dut = dut
        self.rng = random.Random(seed)
        self.in_gap = in_gap
        self.out_gap = out_gap
        # data, code, first beat of a frame, the frame's segmentation configuration, its plain csum request
        self.beats: list[tuple[int, int, bool, dict[str, int] | None, int]] = []
        self.frames: list[tuple[bytes, int]] = []
        self.errs = 0
        self._cur = bytearray()
        self._cur_csum: int | None = None

    def queue_frame(
        self, frame: bytes, cfg: dict[str, int] | None, csum: int = 0
    ) -> None:
        """Queue a frame as beats with its configuration and plain checksum request."""
        for pos in range(0, len(frame), 8):
            chunk = frame[pos : pos + 8]
            last = pos + 8 >= len(frame)
            code = (int(last) << 3) | (len(chunk) - 1)
            data = int.from_bytes(
                chunk.ljust(8, bytes([self.rng.getrandbits(8)])), "little"
            )
            self.beats.append((data, code, pos == 0, cfg, csum))

    async def run(self, expect_frames: int, limit: int = 400000) -> None:
        """Drive the queued beats and collect frames until the expected number has come out."""
        dut = self.dut
        idx = 0
        for _ in range(limit):
            await FallingEdge(dut.i_clk)
            present = idx < len(self.beats) and self.rng.random() >= self.in_gap
            if present:
                data, code, first, cfg, csum = self.beats[idx]
                if first:
                    self._apply_cfg(cfg, csum)
                dut.i_in_data.value = data
                dut.i_in_code.value = code
            dut.i_in_valid.value = int(present)
            ready = int(self.rng.random() >= self.out_gap)
            dut.i_out_ready.value = ready
            await Timer(2, unit="ps")
            in_ready = int(dut.o_in_ready.value)
            out_valid = int(dut.o_out_valid.value)
            out_data = int(dut.o_out_data.value)
            out_code = int(dut.o_out_code.value)
            out_csum = int(dut.o_out_csum.value)
            err = int(dut.o_err.value)
            await RisingEdge(dut.i_clk)
            if err:
                self.errs += 1
            if present and in_ready:
                idx += 1
            if out_valid and ready:
                n = (out_code & 7) + 1
                if not self._cur:
                    self._cur_csum = out_csum
                else:
                    assert out_csum == self._cur_csum, (
                        "csum request changed inside a frame"
                    )
                self._cur += out_data.to_bytes(8, "little")[:n]
                if out_code & 8:
                    self.frames.append((bytes(self._cur), self._cur_csum or 0))
                    self._cur = bytearray()
                else:
                    assert n == 8, "a nonfinal beat must carry 8 bytes"
            if len(self.frames) >= expect_frames and idx >= len(self.beats):
                # let the error pulse of the last frame arrive, with the input quiet
                dut.i_in_valid.value = 0
                for _ in range(10):
                    await RisingEdge(dut.i_clk)
                    if int(dut.o_err.value):
                        self.errs += 1
                return
        raise AssertionError(
            f"timeout: {len(self.frames)} of {expect_frames} frames, {idx}/{len(self.beats)} beats"
        )

    def _apply_cfg(self, cfg: dict[str, int] | None, csum: int) -> None:
        d = self.dut
        c = cfg or {
            "segment": 0,
            "mss": 0,
            "payload": 0,
            "l4off2": 0,
            "tcphl4": 0,
            "ip6": 0,
            "vlan": 0,
        }
        d.i_cfg_segment.value = c["segment"]
        d.i_cfg_mss.value = c["mss"]
        d.i_cfg_payload.value = c["payload"]
        d.i_cfg_l4_off2.value = c["l4off2"]
        d.i_cfg_tcphl4.value = c["tcphl4"]
        d.i_cfg_ip6.value = c["ip6"]
        d.i_cfg_vlan.value = c["vlan"]
        d.i_cfg_csum.value = csum


async def setup(
    dut: Any, seed: int, in_gap: float = 0.0, out_gap: float = 0.0
) -> Bench:
    """Start the clock, reset the stage and return a bench."""
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_flush,
        dut.i_cfg_segment,
        dut.i_cfg_mss,
        dut.i_cfg_payload,
        dut.i_cfg_l4_off2,
        dut.i_cfg_tcphl4,
        dut.i_cfg_ip6,
        dut.i_cfg_vlan,
        dut.i_cfg_csum,
        dut.i_in_valid,
        dut.i_in_data,
        dut.i_in_code,
        dut.i_out_ready,
    ):
        sig.value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    return Bench(dut, seed, in_gap, out_gap)


def check_frames(bench: Bench, expected: list[tuple[bytes, int]]) -> None:
    """Compare the collected frames with the expected ones."""
    assert len(bench.frames) == len(expected), (
        f"{len(bench.frames)} frames, expected {len(expected)}"
    )
    for i, ((got, got_csum), (want, want_csum)) in enumerate(
        zip(bench.frames, expected)
    ):
        assert got_csum == want_csum, (
            f"frame {i}: csum request {got_csum:#x}, expected {want_csum:#x}"
        )
        if got != want:
            first = next(
                (j for j in range(min(len(got), len(want))) if got[j] != want[j]),
                min(len(got), len(want)),
            )
            raise AssertionError(
                f"frame {i}: {len(got)} bytes, expected {len(want)}; first difference at byte {first}:"
                f" got {got[first : first + 8].hex()} want {want[first : first + 8].hex()}"
            )


async def one_case(
    dut: Any, seed: int, in_gap: float, out_gap: float, **kw: Any
) -> None:
    """Segment one random packet and check every segment."""
    bench = await setup(dut, seed, in_gap, out_gap)
    pkt = Packet(bench.rng, **kw)
    bench.queue_frame(pkt.frame, pkt.config(), 0)
    segs = pkt.segments()
    await bench.run(len(segs))
    check_frames(bench, [(s, pkt.csum_request()) for s in segs])
    assert bench.errs == 0, f"{bench.errs} unexpected errors"


@cocotb.test()
async def test_ipv4_three_segments(dut: Any) -> None:
    """A 4000-byte payload at MSS 1460 makes three segments with exact headers."""
    await one_case(dut, 1, 0.0, 0.0, payload_len=4000, mss=1460)


@cocotb.test()
async def test_header_lengths_and_alignments(dut: Any) -> None:
    """Every header length modulo 8, with options, VLAN and odd MSS values."""
    n = 0
    for vlan in (False, True):
        for ip_opt in (0, 1, 2, 3):
            for tcp_opt in (0, 1, 2, 3):
                n += 1
                await one_case(
                    dut,
                    100 + n,
                    0.15,
                    0.15,
                    vlan=vlan,
                    ip_opt_words=ip_opt,
                    tcp_opt_words=tcp_opt,
                    payload_len=700 + 37 * n,
                    mss=[536, 333, 1000, 247][n % 4],
                )


@cocotb.test()
async def test_ipv6(dut: Any) -> None:
    """IPv6 segments carry the payload length and the same TCP changes."""
    for n, (vlan, tcp_opt) in enumerate([(False, 0), (True, 0), (False, 2), (True, 3)]):
        await one_case(
            dut,
            200 + n,
            0.1,
            0.1,
            ip6=True,
            vlan=vlan,
            tcp_opt_words=tcp_opt,
            payload_len=2500 + n,
            mss=1220,
        )


@cocotb.test()
async def test_boundaries(dut: Any) -> None:
    """Payload equal to, one under and one over a multiple of the MSS, and tiny ones."""
    mss = 500
    for n, p in enumerate(
        [1, 2, 7, 8, 9, mss - 1, mss, mss + 1, 2 * mss, 2 * mss + 1, 3 * mss - 1, 64000]
    ):
        await one_case(
            dut, 300 + n, 0.05, 0.05, payload_len=p, mss=mss if p < 5000 else 1460
        )


@cocotb.test()
async def test_small_mss(dut: Any) -> None:
    """An MSS of a few bytes still segments exactly, whatever the preparation time."""
    for n, mss in enumerate([1, 3, 8, 13, 60]):
        await one_case(dut, 400 + n, 0.0, 0.0, payload_len=200, mss=mss)


@cocotb.test()
async def test_flags(dut: Any) -> None:
    """FIN and PSH only on the last segment, CWR only on the first, the rest kept."""
    for n, flags in enumerate(
        [ACK, ACK | PSH | FIN | CWR, ACK | ECE | URG | CWR, FIN | PSH, CWR | ACK | PSH]
    ):
        await one_case(dut, 500 + n, 0.0, 0.2, flags=flags, payload_len=3500, mss=1000)


@cocotb.test()
async def test_back_to_back_with_plain_frames(dut: Any) -> None:
    """Plain and segmented frames alternate; plain frames pass untouched with their own request."""
    bench = await setup(dut, 7, 0.1, 0.1)
    rng = bench.rng
    expected: list[tuple[bytes, int]] = []
    for n in range(12):
        if n % 3 == 1:
            pkt = Packet(
                rng,
                ip6=bool(n & 1),
                vlan=bool(n & 2),
                tcp_opt_words=n % 3,
                payload_len=900 + 31 * n,
                mss=400 + 7 * n,
            )
            bench.queue_frame(pkt.frame, pkt.config(), 0)
            expected += [(s, pkt.csum_request()) for s in pkt.segments()]
        else:
            body = bytes(
                rng.getrandbits(8) for _ in range(rng.choice([1, 8, 60, 61, 64, 1514]))
            )
            req = rng.getrandbits(15)
            bench.queue_frame(body, None, req)
            expected.append((body, req))
    await bench.run(len(expected))
    check_frames(bench, expected)
    assert bench.errs == 0


@cocotb.test()
async def test_invalid_frames_are_dropped(dut: Any) -> None:
    """MSS 0, a payload of 0, an oversize header and a frame shorter than its header: dropped, flagged."""
    bench = await setup(dut, 9, 0.0, 0.0)
    rng = bench.rng
    good = Packet(rng, payload_len=300, mss=100)
    bad_mss = Packet(rng, payload_len=300, mss=100)
    cfg = bad_mss.config()
    cfg["mss"] = 0
    bench.queue_frame(bad_mss.frame, cfg, 0)
    bad_hdr = Packet(rng, payload_len=300, mss=100)
    cfg = bad_hdr.config()
    cfg["tcphl4"] = (
        15  # 60-byte TCP header declared, but also pushes the header past what fits with l4
    )
    cfg["l4off2"] = 100
    bench.queue_frame(bad_hdr.frame, cfg, 0)
    short = Packet(rng, payload_len=300, mss=100)
    bench.queue_frame(short.frame[:30], short.config(), 0)
    bench.queue_frame(good.frame, good.config(), 0)
    segs = good.segments()
    await bench.run(len(segs))
    check_frames(bench, [(s, good.csum_request()) for s in segs])
    assert bench.errs == 3, f"{bench.errs} errors, expected 3"


@cocotb.test()
async def test_payload_shorter_than_declared_is_padded(dut: Any) -> None:
    """The declared payload is honoured: the shortfall goes out as zeros and the error pulses."""
    bench = await setup(dut, 11, 0.0, 0.0)
    pkt = Packet(bench.rng, payload_len=1000, mss=300)
    cfg = pkt.config()
    cfg["payload"] = 1200
    padded = Packet.__new__(Packet)
    padded.__dict__.update(pkt.__dict__)
    padded.payload = pkt.payload + bytes(200)
    bench.queue_frame(pkt.frame, cfg, 0)
    segs = padded.segments()
    await bench.run(len(segs))
    check_frames(bench, [(s, pkt.csum_request()) for s in segs])
    assert bench.errs == 1, f"{bench.errs} errors, expected 1"


@cocotb.test()
async def test_payload_longer_than_declared_is_trimmed(dut: Any) -> None:
    """Bytes beyond the declared payload are discarded and flagged."""
    bench = await setup(dut, 12, 0.0, 0.0)
    pkt = Packet(bench.rng, payload_len=1000, mss=300)
    longer = Packet.__new__(Packet)
    longer.__dict__.update(pkt.__dict__)
    longer.frame = pkt.frame + bytes(77)
    bench.queue_frame(longer.frame, pkt.config(), 0)
    segs = pkt.segments()
    await bench.run(len(segs))
    check_frames(bench, [(s, pkt.csum_request()) for s in segs])
    assert bench.errs == 1, f"{bench.errs} errors, expected 1"


@cocotb.test()
async def test_random_stress(dut: Any) -> None:
    """Random packets, gaps and backpressure, many frames back to back."""
    bench = await setup(dut, 21, 0.3, 0.3)
    rng = bench.rng
    expected: list[tuple[bytes, int]] = []
    for n in range(40):
        if rng.random() < 0.2:
            body = bytes(rng.getrandbits(8) for _ in range(rng.randrange(1, 300)))
            req = rng.getrandbits(15)
            bench.queue_frame(body, None, req)
            expected.append((body, req))
            continue
        pkt = Packet(
            rng,
            ip6=rng.random() < 0.3,
            vlan=rng.random() < 0.4,
            ip_opt_words=rng.randrange(0, 4),
            tcp_opt_words=rng.randrange(0, 4),
            payload_len=rng.randrange(1, 4000),
            mss=rng.randrange(1, 1500),
            flags=rng.getrandbits(8),
        )
        if len(pkt.payload) // pkt.mss > 60:
            pkt.mss = len(pkt.payload) // 60 + 1
        bench.queue_frame(pkt.frame, pkt.config(), 0)
        expected += [(s, pkt.csum_request()) for s in pkt.segments()]
    await bench.run(len(expected), limit=3_000_000)
    check_frames(bench, expected)
    assert bench.errs == 0, f"{bench.errs} unexpected errors"

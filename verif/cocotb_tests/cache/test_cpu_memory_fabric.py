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

"""Check arbitration ownership across the CPU fabric's registered boundary."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


class Bench:
    """Observe each external handshake immediately before its accepting edge."""

    def __init__(self, dut: Any) -> None:
        """Keep stalled AXI payloads for stability checks."""
        self.dut = dut
        self.held: dict[str, tuple[int, ...]] = {}
        self.read_requests: list[tuple[int, int]] = []

    async def step(self, **inputs: int) -> dict[str, int]:
        """Drive inputs, sample outputs, check held beats, then clock once."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        names = [
            "idle",
            "cache_ready",
            "data_ready",
            "fetch_ready",
            "cache_resp_valid",
            "cache_resp_id",
            "cache_resp_data",
            "cache_resp_error",
            "data_resp_valid",
            "data_resp_data",
            "data_resp_status",
            "fetch_resp_valid",
            "fetch_resp_id",
            "fetch_resp_data",
            "fetch_resp_error",
            "axi_rready",
            "axi_bready",
        ]
        channel_fields = {
            "ar": ("id", "addr", "size", "cache", "prot"),
            "aw": ("id", "addr", "size", "cache", "prot"),
            "w": ("data", "strb", "last"),
        }
        for channel, fields in channel_fields.items():
            names += ["axi_" + channel + field for field in ("valid", *fields)]
        s = {name: int(getattr(self.dut, "o_" + name).value) for name in names}
        if s["axi_arvalid"] and int(self.dut.i_axi_arready.value):
            self.read_requests.append((s["axi_arid"], s["axi_araddr"]))
        for channel, fields in channel_fields.items():
            valid = s["axi_" + channel + "valid"]
            payload = tuple(s["axi_" + channel + f] for f in fields)
            if int(self.dut.i_axi_rst.value):
                assert not valid
                self.held.pop(channel, None)
                continue
            if channel in self.held:
                assert valid and payload == self.held[channel], channel
            if valid and not int(getattr(self.dut, "i_axi_" + channel + "ready").value):
                self.held[channel] = payload
            else:
                self.held.pop(channel, None)
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")
        return s

    async def reset(self) -> None:
        """Start with no client or fabric transaction outstanding."""
        inputs = {"rst": 1, "axi_rst": 1}
        for client, fields in {
            "cache": ("valid", "write", "addr", "wdata", "wstrb", "id"),
            "data": (
                "valid",
                "write",
                "addr",
                "size",
                "cache",
                "prot",
                "wdata",
                "wstrb",
            ),
            "fetch": ("valid", "addr", "id"),
        }.items():
            inputs.update({client + "_" + field: 0 for field in fields})
        inputs.update(
            {
                "axi_" + field: 0
                for field in (
                    "awready",
                    "wready",
                    "arready",
                    "bvalid",
                    "bid",
                    "bresp",
                    "buser",
                    "rvalid",
                    "rid",
                    "rdata",
                    "rresp",
                    "rlast",
                    "ruser",
                )
            }
        )
        inputs["axi_rlast"] = 1
        await self.step(**inputs)
        await self.step()
        assert (await self.step(rst=0, axi_rst=0))["idle"]


@cocotb.test()
async def arbitration_holds_payloads_and_routes_responses(dut: Any) -> None:
    """Three competing clients survive channel stalls and independently delayed errors."""
    b = Bench(dut)
    await b.reset()
    full_data = int.from_bytes(bytes(range(64)), "little")
    fetch_word = 0x13579BDF2468ACE0
    fetch_bytes = len(dut.o_fetch_resp_data) // 8
    fetch_offset = 64 - fetch_bytes
    inputs = {
        "cache_valid": 1,
        "cache_write": 1,
        "cache_addr": 0x80000080,
        "cache_id": 5,
        "cache_wdata": full_data,
        "cache_wstrb": (1 << 64) - 1,
        "data_valid": 1,
        "data_write": 1,
        "data_addr": 0x40000017,
        "data_size": 0,
        "data_cache": 0,
        "data_prot": 3,
        "data_wdata": 0xA5 << (23 * 8),
        "data_wstrb": 1 << 23,
        "fetch_valid": 1,
        "fetch_addr": 0x1200 + fetch_offset,
        "fetch_id": 1,
    }
    accepted: list[str] = []
    aw: list[tuple[int, ...]] = []
    w: list[tuple[int, ...]] = []
    ar: list[tuple[int, ...]] = []
    replies: list[tuple[str, int, int]] = []
    b_count = 0
    r_done = False
    for cycle in range(250):
        inputs.update(
            axi_awready=int(cycle >= 15 and cycle % 3 == 0),
            axi_wready=int(cycle >= 23 and cycle % 5 == 0),
            axi_arready=int(cycle >= 12 and cycle % 2 == 0),
        )
        send_b = cycle >= 60 and b_count < min(len(aw), len(w))
        inputs.update(
            axi_bvalid=int(send_b),
            axi_bid=aw[b_count][0] if send_b else 0,
            axi_bresp=2 if b_count == 0 else 3,
        )
        inputs.update(
            axi_rvalid=int(bool(ar) and not r_done and cycle >= 55),
            axi_rid=35,
            axi_rdata=fetch_word << (fetch_offset * 8),
        )
        s = await b.step(**inputs)
        for client in ("cache", "data", "fetch"):
            if inputs[client + "_valid"] and s[client + "_ready"]:
                accepted.append(client)
                inputs[client + "_valid"] = 0
                # A producer owns no payload after acceptance. Deliberately
                # change it while the fabric's register is backpressured.
                inputs[client + "_addr"] = 0xBAD000
                if client != "fetch":
                    inputs[client + "_wdata"] = 0
                    inputs[client + "_wstrb"] = 0
        for channel, records, fields in (
            ("aw", aw, ("id", "addr", "size", "cache", "prot")),
            ("ar", ar, ("id", "addr", "size", "cache", "prot")),
            ("w", w, ("data", "strb", "last")),
        ):
            if s["axi_" + channel + "valid"] and inputs["axi_" + channel + "ready"]:
                records.append(tuple(s["axi_" + channel + f] for f in fields))
        if send_b and s["axi_bready"]:
            b_count += 1
        if inputs["axi_rvalid"] and s["axi_rready"]:
            r_done = True
        if s["cache_resp_valid"]:
            replies.append(("cache", s["cache_resp_id"], s["cache_resp_error"]))
        if s["data_resp_valid"]:
            replies.append(("data", 32, s["data_resp_status"]))
        if s["fetch_resp_valid"]:
            assert s["fetch_resp_data"] == fetch_word and not s["fetch_resp_error"]
            replies.append(("fetch", s["fetch_resp_id"], 0))
        if len(replies) == 3 and s["idle"]:
            break
    else:
        raise AssertionError("fabric did not drain every client")
    assert accepted == ["cache", "data", "fetch"]
    assert aw == [(5, 0x80000080, 6, 15, 3), (32, 0x40000017, 0, 0, 3)]
    assert w == [(full_data, (1 << 64) - 1, 1), (0xA5 << (23 * 8), 1 << 23, 1)]
    assert ar == [
        (
            35,
            0x1200 + fetch_offset,
            fetch_bytes.bit_length() - 1,
            14 if fetch_bytes > 8 else 2,
            7,
        )
    ]
    assert sorted(replies) == [("cache", 5, 1), ("data", 32, 3), ("fetch", 1, 0)]


@cocotb.test()
async def interleaved_read_and_write_responses_preserve_fetch_lanes(dut: Any) -> None:
    """Exercise both fetch IDs and every word lane across an R/B/R sequence."""
    b = Bench(dut)
    bus_bytes = len(dut.i_axi_rdata) // 8
    fetch_bytes = len(dut.o_fetch_resp_data) // 8
    mask = (1 << (fetch_bytes * 8)) - 1
    for offset in range(0, bus_bytes, fetch_bytes):
        await b.reset()
        write_id = 4 + (offset // fetch_bytes) % 2
        offsets = (offset, bus_bytes - fetch_bytes - offset)
        payloads = (
            int.from_bytes(bytes(range(bus_bytes)), "little"),
            int.from_bytes(bytes(255 - x for x in range(bus_bytes)), "little"),
        )
        s = await b.step(
            axi_awready=1,
            axi_wready=1,
            axi_arready=1,
            cache_valid=1,
            cache_write=1,
            cache_id=write_id,
            cache_addr=0x80000000,
            cache_wstrb=(1 << bus_bytes) - 1,
        )
        assert s["cache_ready"]
        s = await b.step(
            cache_valid=0, fetch_valid=1, fetch_id=0, fetch_addr=0x1000 + offsets[0]
        )
        assert s["fetch_ready"]
        s = await b.step(fetch_id=1, fetch_addr=0x2000 + offsets[1])
        assert s["fetch_ready"]
        await b.step(fetch_valid=0)
        for _ in range(6):
            await b.step()
        await b.step(
            axi_rvalid=1,
            axi_rid=34,
            axi_rdata=payloads[0],
            axi_rresp=0,
            axi_bvalid=1,
            axi_bid=write_id,
            axi_bresp=3,
        )
        first = await b.step(
            axi_rid=35, axi_rdata=payloads[1], axi_rresp=2, axi_bvalid=0
        )
        assert first["axi_rready"] and first["fetch_resp_valid"]
        assert first["fetch_resp_id"] == 0 and not first["fetch_resp_error"]
        assert first["fetch_resp_data"] == (payloads[0] >> (8 * offsets[0])) & mask
        middle = await b.step(axi_rvalid=0)
        assert middle["cache_resp_valid"] and middle["cache_resp_id"] == write_id
        assert middle["cache_resp_error"] and not middle["fetch_resp_valid"]
        last = await b.step()
        assert last["fetch_resp_valid"] and last["fetch_resp_id"] == 1
        assert last["fetch_resp_error"]
        assert last["fetch_resp_data"] == (payloads[1] >> (8 * offsets[1])) & mask
        for _ in range(3):
            s = await b.step()
            assert s["idle"] and not (s["cache_resp_valid"] or s["fetch_resp_valid"])


@cocotb.test()
async def reused_fetch_id_ignores_wrong_channel_response(dut: Any) -> None:
    """Check that a B carrying a pending fetch ID cannot complete its read."""
    b = Bench(dut)
    await b.reset()
    fetch_bytes = len(dut.o_fetch_resp_data) // 8
    for sequence in range(3):
        offset = (sequence * fetch_bytes) % (len(dut.i_axi_rdata) // 8)
        payload = 0x1234567800000000 + sequence
        s = await b.step(
            axi_arready=1, fetch_valid=1, fetch_id=0, fetch_addr=0x1000 + offset
        )
        assert s["fetch_ready"]
        await b.step(fetch_valid=0)
        for _ in range(6):
            await b.step()
        s = await b.step(axi_bvalid=1, axi_bid=34, axi_bresp=3)
        assert s["axi_bready"] and not s["fetch_resp_valid"]
        s = await b.step(axi_bvalid=0)
        assert not s["fetch_resp_valid"]
        await b.step(
            axi_rvalid=1, axi_rid=34, axi_rdata=payload << (offset * 8), axi_rresp=0
        )
        s = await b.step(axi_rvalid=0)
        assert s["fetch_resp_valid"] and s["fetch_resp_id"] == 0
        assert s["fetch_resp_data"] == payload and not s["fetch_resp_error"]
        assert (await b.step())["idle"]


async def fill_two_write_slots(b: Bench) -> None:
    """Park one write in the master and a second in the fabric register."""
    s = await b.step(
        cache_valid=1,
        cache_write=1,
        cache_id=3,
        cache_addr=0x80000000,
        cache_wdata=0xAA,
        cache_wstrb=(1 << 64) - 1,
    )
    assert s["cache_ready"]
    s = await b.step(
        cache_valid=0,
        data_valid=1,
        data_write=1,
        data_addr=0x40000008,
        data_size=3,
        data_cache=0,
        data_prot=3,
        data_wdata=0xBB << 64,
        data_wstrb=0xFF << 8,
    )
    assert s["data_ready"]
    s = await b.step(data_valid=0)
    assert s["axi_awvalid"] and s["axi_awid"] == 3 and not s["idle"]


@cocotb.test()
async def cpu_reset_cancels_queue_but_drains_presented_write(dut: Any) -> None:
    """Drain old AXI debt before a new epoch and cancel the queued device write."""
    b = Bench(dut)
    await b.reset()
    await fill_two_write_slots(b)
    await b.step(rst=1)
    await b.step()
    fetch_valid = 1
    b_done = False
    ar_done = False
    r_done = False
    got_fetch = False
    for cycle in range(80):
        inputs = dict(
            rst=0,
            fetch_valid=fetch_valid,
            fetch_addr=0x1000,
            fetch_id=0,
            axi_awready=int(cycle >= 5),
            axi_wready=int(cycle >= 9),
            axi_arready=1,
            axi_bvalid=int(cycle >= 15 and not b_done),
            axi_bid=3,
            axi_bresp=2,
            axi_rvalid=int(ar_done and not r_done),
            axi_rid=34,
            axi_rdata=0xCAFE,
        )
        s = await b.step(**inputs)
        if fetch_valid and s["fetch_ready"]:
            fetch_valid = 0
        assert not s["cache_resp_valid"] and not s["data_resp_valid"]
        if s["axi_awvalid"]:
            assert s["axi_awid"] == 3, "queued device write survived CPU reset"
        if s["axi_arvalid"]:
            assert b_done, "new AXI request escaped before old write response"
            assert s["axi_arid"] == 34 and s["axi_araddr"] == 0x1000
            ar_done = True
        if inputs["axi_bvalid"] and s["axi_bready"]:
            b_done = True
        if inputs["axi_rvalid"] and s["axi_rready"]:
            r_done = True
        if s["fetch_resp_valid"]:
            assert not got_fetch and s["fetch_resp_data"] == 0xCAFE
            got_fetch = True
        if got_fetch and s["idle"]:
            break
    assert got_fetch and b_done and r_done and s["idle"]


@cocotb.test()
async def fabric_reset_clears_both_request_stages(dut: Any) -> None:
    """Remove the parked AXI write and queued request when both sides reset."""
    b = Bench(dut)
    await b.reset()
    await fill_two_write_slots(b)
    await b.step(rst=1, axi_rst=1)
    for _ in range(8):
        s = await b.step(rst=0, axi_rst=0, axi_awready=1, axi_wready=1, axi_arready=1)
        assert s["idle"]
        assert not (s["axi_awvalid"] or s["axi_wvalid"] or s["axi_arvalid"])


@cocotb.test()
async def lane_metadata_tracks_replacement_and_id_reuse(dut: Any) -> None:
    """Keep each read's lane through buffer replacement and same-edge ID reuse."""
    b = Bench(dut)
    await b.reset()
    bus_bytes = len(dut.i_axi_rdata) // 8
    fetch_bytes = len(dut.o_fetch_resp_data) // 8
    last_offset = bus_bytes - fetch_bytes
    low_word, high_word, reused_word = 0x12345678, 0x23456789, 0x3456789A
    s = await b.step(axi_arready=1, fetch_valid=1, fetch_id=0, fetch_addr=0x1000)
    assert s["fetch_ready"]
    s = await b.step(fetch_id=1, fetch_addr=0x2000 + last_offset)
    assert s["fetch_ready"]
    await b.step(fetch_valid=0)
    for _ in range(6):
        await b.step()
    await b.step(axi_rvalid=1, axi_rid=34, axi_rdata=low_word)
    s = await b.step(
        axi_rid=35,
        axi_rdata=high_word << (last_offset * 8),
        axi_rresp=2,
        fetch_valid=1,
        fetch_id=0,
        fetch_addr=0x3000 + last_offset,
    )
    assert s["fetch_ready"] and s["axi_rready"]
    assert s["fetch_resp_valid"] and s["fetch_resp_id"] == 0
    assert s["fetch_resp_data"] == low_word and not s["fetch_resp_error"]
    s = await b.step(axi_rvalid=0, fetch_valid=0)
    assert s["fetch_resp_valid"] and s["fetch_resp_id"] == 1
    assert s["fetch_resp_data"] == high_word and s["fetch_resp_error"]
    for _ in range(6):
        await b.step()
    await b.step(
        axi_rvalid=1,
        axi_rid=34,
        axi_rdata=reused_word << (last_offset * 8),
        axi_rresp=0,
    )
    s = await b.step(axi_rvalid=0)
    assert s["fetch_resp_valid"] and s["fetch_resp_id"] == 0
    assert s["fetch_resp_data"] == reused_word and not s["fetch_resp_error"]
    assert (await b.step())["idle"]


@cocotb.test()
async def reversed_fetch_replies_survive_an_intervening_data_read(dut: Any) -> None:
    """Match out-of-order fetch lanes across a data-client response."""
    b = Bench(dut)
    await b.reset()
    bus_bytes = len(dut.i_axi_rdata) // 8
    fetch_bytes = len(dut.o_fetch_resp_data) // 8
    mask = (1 << (fetch_bytes * 8)) - 1
    offset = bus_bytes - fetch_bytes
    payloads = [
        int.from_bytes(bytes(base + x for x in range(bus_bytes)), "little")
        for base in (0, 80, 160)
    ]
    s = await b.step(
        axi_arready=1, fetch_valid=1, fetch_id=0, fetch_addr=0x1000 + offset
    )
    assert s["fetch_ready"]
    s = await b.step(fetch_id=1, fetch_addr=0x2000)
    assert s["fetch_ready"]
    s = await b.step(
        fetch_valid=0, data_valid=1, data_write=0, data_addr=0x40000000, data_size=3
    )
    for _ in range(12):
        if s["data_ready"]:
            break
        s = await b.step()
    assert s["data_ready"]
    await b.step(data_valid=0)
    for _ in range(6):
        await b.step()
    assert b.read_requests == [(34, 0x1000 + offset), (35, 0x2000), (32, 0x40000000)]
    assert (await b.step(axi_rvalid=1, axi_rid=35, axi_rdata=payloads[0]))["axi_rready"]
    s = await b.step(axi_rid=32, axi_rdata=payloads[1])
    assert s["axi_rready"]
    assert s["fetch_resp_valid"] and s["fetch_resp_id"] == 1
    assert s["fetch_resp_data"] == payloads[0] & mask and not s["fetch_resp_error"]
    s = await b.step(axi_rid=34, axi_rdata=payloads[2], axi_rresp=2)
    assert s["axi_rready"]
    assert s["data_resp_valid"] and not s["fetch_resp_valid"]
    assert s["data_resp_data"] == payloads[1] and s["data_resp_status"] == 0
    s = await b.step(axi_rvalid=0)
    assert s["fetch_resp_valid"] and s["fetch_resp_id"] == 0
    assert s["fetch_resp_data"] == (payloads[2] >> (offset * 8)) & mask
    assert s["fetch_resp_error"]
    assert (await b.step())["idle"]


@cocotb.test()
async def reset_cancels_buffered_fetch_lane_before_reuse(dut: Any) -> None:
    """Refresh lane metadata after buffered cancellation and stale draining."""
    b = Bench(dut)
    await b.reset()
    bus_bytes = len(dut.i_axi_rdata) // 8
    fetch_bytes = len(dut.o_fetch_resp_data) // 8
    offset = bus_bytes - fetch_bytes
    s = await b.step(
        axi_arready=1, fetch_valid=1, fetch_id=0, fetch_addr=0x1000 + offset
    )
    assert s["fetch_ready"]
    s = await b.step(fetch_id=1, fetch_addr=0x2000)
    assert s["fetch_ready"]
    await b.step(fetch_valid=0)
    for _ in range(6):
        await b.step()
    assert b.read_requests == [(34, 0x1000 + offset), (35, 0x2000)]
    assert (await b.step(axi_rvalid=1, axi_rid=34, axi_rdata=0x1234 << (offset * 8)))[
        "axi_rready"
    ]
    s = await b.step(rst=1, axi_rvalid=0)
    assert not s["fetch_resp_valid"]
    s = await b.step(rst=0, fetch_valid=1, fetch_id=0, fetch_addr=0x3000)
    assert s["fetch_ready"] and not s["fetch_resp_valid"]
    s = await b.step(fetch_valid=0, axi_rvalid=1, axi_rid=35, axi_rdata=0xBAD)
    assert s["axi_rready"] and not s["fetch_resp_valid"]
    for _ in range(8):
        s = await b.step(axi_rvalid=0)
        assert not s["fetch_resp_valid"]
    assert b.read_requests[-1] == (34, 0x3000) and len(b.read_requests) == 3
    assert (await b.step(axi_rvalid=1, axi_rid=34, axi_rdata=0x5678))["axi_rready"]
    s = await b.step(axi_rvalid=0)
    assert s["fetch_resp_valid"] and s["fetch_resp_id"] == 0
    assert s["fetch_resp_data"] == 0x5678 and not s["fetch_resp_error"]
    assert (await b.step())["idle"]

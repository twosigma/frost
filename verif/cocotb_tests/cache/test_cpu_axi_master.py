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

"""Exercise the CPU's AXI port using only its external handshakes."""

import random
from typing import Any

import cocotb
from cocotb.triggers import Timer


class Bench:
    """Clock explicitly so every observation names the accepting edge."""

    def __init__(self, dut: Any) -> None:
        """Initialize the interface and scoreboard."""
        self.dut = dut
        self.held: dict[str, tuple[int, ...]] = {}

    async def step(self, **inputs: int) -> dict[str, int]:
        """Apply inputs, check VALID stability, and take one rising edge."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        names = [
            "req_ready",
            "resp_valid",
            "resp_write",
            "resp_id",
            "resp_rdata",
            "resp_status",
            "read_resp_id",
            "read_resp_rdata",
            "read_resp_status",
            "idle",
            "axi_bready",
            "axi_rready",
        ]
        for channel in ("ar", "aw"):
            names += [
                "axi_" + channel + field
                for field in (
                    "valid",
                    "id",
                    "addr",
                    "len",
                    "size",
                    "burst",
                    "lock",
                    "cache",
                    "prot",
                    "qos",
                    "region",
                    "user",
                )
            ]
        names += [
            "axi_w" + field for field in ("valid", "data", "strb", "last", "user")
        ]
        result = {name: int(getattr(self.dut, "o_" + name).value) for name in names}
        if result["resp_valid"] and not result["resp_write"]:
            for field in ("id", "rdata", "status"):
                assert result["read_resp_" + field] == result["resp_" + field]
        fabric_reset = int(self.dut.i_axi_rst.value)
        cpu_reset = int(self.dut.i_rst.value)
        for channel, fields, ready in (
            (
                "ar",
                (
                    "id",
                    "addr",
                    "len",
                    "size",
                    "burst",
                    "lock",
                    "cache",
                    "prot",
                    "qos",
                    "region",
                    "user",
                ),
                "axi_arready",
            ),
            (
                "aw",
                (
                    "id",
                    "addr",
                    "len",
                    "size",
                    "burst",
                    "lock",
                    "cache",
                    "prot",
                    "qos",
                    "region",
                    "user",
                ),
                "axi_awready",
            ),
            ("w", ("data", "strb", "last", "user"), "axi_wready"),
        ):
            valid = result["axi_" + channel + "valid"]
            payload = tuple(result["axi_" + channel + f] for f in fields)
            if not fabric_reset and channel in self.held:
                assert valid and payload == self.held[channel], channel
            if valid and not int(getattr(self.dut, "i_" + ready).value):
                self.held[channel] = payload
            else:
                self.held.pop(channel, None)
            if fabric_reset:
                assert not valid
        payload = tuple(result["resp_" + n] for n in ("write", "id", "rdata", "status"))
        if not cpu_reset and not fabric_reset and "resp" in self.held:
            assert result["resp_valid"] and payload == self.held["resp"]
        if result["resp_valid"] and not int(self.dut.i_resp_ready.value):
            self.held["resp"] = payload
        else:
            self.held.pop("resp", None)
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")
        return result

    async def reset(self) -> None:
        """Reset both sides of the connection for a new independent test."""
        inputs = {
            "rst": 1,
            "axi_rst": 1,
            "req_valid": 0,
            "req_write": 0,
            "req_addr": 0,
            "req_size": 0,
            "req_cache": 0,
            "req_prot": 0,
            "req_wdata": 0,
            "req_wstrb": 0,
            "req_id": 0,
            "resp_ready": 1,
            "axi_awready": 0,
            "axi_wready": 0,
            "axi_arready": 0,
            "axi_bvalid": 0,
            "axi_bid": 0,
            "axi_bresp": 0,
            "axi_buser": 0,
            "axi_rvalid": 0,
            "axi_rid": 0,
            "axi_rdata": 0,
            "axi_rresp": 0,
            "axi_rlast": 1,
            "axi_ruser": 0,
        }
        await self.step(**inputs)
        await self.step()
        await self.step(rst=0, axi_rst=0)

    async def request(
        self,
        ident: int,
        addr: int,
        size: int,
        *,
        write: bool = False,
        cache: int = 0,
        prot: int = 3,
        data: int = 0,
        strb: int = 0,
    ) -> None:
        """Check that the client keeps the request until the master accepts it."""
        for _ in range(80):
            s = await self.step(
                req_valid=1,
                req_id=ident,
                req_addr=addr,
                req_size=size,
                req_write=int(write),
                req_cache=cache,
                req_prot=prot,
                req_wdata=data,
                req_wstrb=strb,
            )
            if s["req_ready"]:
                self.dut.i_req_valid.value = 0
                return
        raise AssertionError("request did not become ready")

    async def read_response(self, ident: int, data: int, status: int = 0) -> None:
        """Present R until its handshake, independently of client READY."""
        for _ in range(80):
            s = await self.step(
                axi_rvalid=1, axi_rid=ident, axi_rdata=data, axi_rresp=status
            )
            if s["axi_rready"]:
                self.dut.i_axi_rvalid.value = 0
                return
        raise AssertionError("R did not become ready")

    async def write_response(self, ident: int, status: int = 0) -> None:
        """Present B until its handshake, independently of client READY."""
        for _ in range(80):
            s = await self.step(axi_bvalid=1, axi_bid=ident, axi_bresp=status)
            if s["axi_bready"]:
                self.dut.i_axi_bvalid.value = 0
                return
        raise AssertionError("B did not become ready")


@cocotb.test()
async def sizes_attributes_addresses_and_byte_lanes(dut: Any) -> None:
    """Byte through line accesses retain their addresses, sizes, and attributes."""
    b = Bench(dut)
    await b.reset()
    for size in range(7):
        # Use the same ID for device and normal-memory transactions. Attributes
        # must come from the request, never from an ID partition.
        for cache in (0, 2, 15):
            offset = (64 - (1 << size)) & 63
            addr = 0x12_4000_0080 + offset
            strb = ((1 << (1 << size)) - 1) << offset
            data = int.from_bytes(bytes(range(64)), "little")
            await b.request(
                7, addr, size, write=True, cache=cache, data=data, strb=strb
            )
            for _ in range(3):
                s = await b.step()
                assert s["axi_awvalid"] and s["axi_wvalid"]
                assert (s["axi_awaddr"], s["axi_awsize"], s["axi_awcache"]) == (
                    addr,
                    size,
                    cache,
                )
                assert s["axi_wstrb"] == strb and s["axi_wdata"] == data
                assert s["axi_awlen"] == 0 and s["axi_awburst"] == 1
                assert s["axi_awprot"] == 3 and s["axi_wlast"] == 1
                assert s["axi_awlock"] == s["axi_awuser"] == s["axi_wuser"] == 0
            await b.step(axi_wready=1)
            s = await b.step(axi_wready=0, axi_awready=1)
            assert s["axi_awvalid"] and not s["axi_wvalid"]
            await b.step(axi_awready=0)
            await b.write_response(7)
            s = await b.step()
            assert s["resp_valid"] and s["resp_write"] and s["resp_id"] == 7
            await b.request(7, addr, size, cache=cache, prot=6)
            s = await b.step(axi_arready=1)
            assert (s["axi_araddr"], s["axi_arsize"], s["axi_arcache"]) == (
                addr,
                size,
                cache,
            )
            assert s["axi_arprot"] == 6 and s["axi_arlen"] == 0
            assert s["axi_arlock"] == s["axi_aruser"] == 0
            await b.step(axi_arready=0)
            await b.read_response(7, data)
            s = await b.step()
            assert s["resp_valid"] and not s["resp_write"]
            assert s["resp_id"] == 7 and s["resp_rdata"] == data
    assert (await b.step())["idle"]


@cocotb.test()
async def errors_out_of_order_and_response_backpressure(dut: Any) -> None:
    """RRESP/BRESP and IDs survive arbitrary completion order and a blocked CPU."""
    b = Bench(dut)
    await b.reset()
    await b.step(axi_arready=1, axi_awready=1, axi_wready=1, resp_ready=0)
    for ident in range(12):
        await b.request(
            ident,
            0x8000_0000 + 64 * ident,
            6,
            write=bool(ident & 1),
            cache=15,
            strb=(1 << 64) - 1,
        )
    await b.step()
    order = list(range(12))
    random.Random(82).shuffle(order)
    for ident in order:
        status = (0, 2, 3)[ident % 3]
        if ident & 1:
            await b.write_response(ident, status)
        else:
            await b.read_response(ident, 0xA000 + ident, status)
        for _ in range(4):
            s = await b.step(req_id=ident, req_valid=1)
            assert not s["req_ready"], (
                "ID reused before the client consumed its response"
            )
            assert (
                s["resp_valid"] and s["resp_id"] == ident and s["resp_status"] == status
            )
        s = await b.step(req_valid=0, resp_ready=1)
        assert s["resp_write"] == (ident & 1)
        if not (ident & 1):
            assert s["resp_rdata"] == 0xA000 + ident
        await b.step(resp_ready=0)
    assert (await b.step())["idle"]


@cocotb.test()
async def blocked_response_does_not_switch_channels(dut: Any) -> None:
    """Check that a later B cannot replace a stalled R, or a later R a stalled B."""
    for first_write in (False, True):
        b = Bench(dut)
        await b.reset()
        await b.step(axi_arready=1, axi_awready=1, axi_wready=1, resp_ready=0)
        await b.request(1, 0x1000, 3)
        await b.request(2, 0x1008, 3, write=True, strb=0xFF00)
        await b.step()
        if first_write:
            await b.write_response(2, 3)
        else:
            await b.read_response(1, 0x1234, 2)
        await b.step()
        if first_write:
            await b.read_response(1, 0x1234, 2)
        else:
            await b.write_response(2, 3)
        for _ in range(5):
            s = await b.step()
            assert s["resp_id"] == (2 if first_write else 1)
        first = await b.step(resp_ready=1)
        second = await b.step()
        assert {first["resp_id"], second["resp_id"]} == {1, 2}
        assert first["resp_valid"] and second["resp_valid"]
        assert (await b.step())["idle"]


@cocotb.test()
async def cpu_reset_preserves_beats_and_drains_old_epoch(dut: Any) -> None:
    """Check that a reset between AW and W does not withdraw the remaining write beat."""
    b = Bench(dut)
    await b.reset()
    await b.request(4, 0x4000_0004, 2, write=True, data=0x55 << 32, strb=0xF0)
    await b.step(axi_awready=1)
    await b.step(axi_awready=0, rst=1)
    for _ in range(3):
        s = await b.step()
        assert s["axi_wvalid"] and not s["axi_awvalid"]
        assert not s["req_ready"] and not s["resp_valid"]
    await b.step(rst=0, req_id=4, req_valid=1)
    await b.step(axi_wready=1)
    for _ in range(4):
        assert not (await b.step())["req_ready"]
    await b.write_response(4, 2)
    s = await b.step(req_valid=0)
    assert not s["resp_valid"], "pre-reset completion reached the restarted CPU"
    assert s["req_ready"] and s["idle"]


@cocotb.test()
async def reset_discards_buffered_response_without_waiting_twice(dut: Any) -> None:
    """Check that a reply already buffered at reset is not an outstanding fabric request."""
    b = Bench(dut)
    await b.reset()
    await b.step(axi_arready=1, resp_ready=0)
    await b.request(3, 0x1000, 3)
    await b.step()
    await b.read_response(3, 0x99)
    assert (await b.step())["resp_valid"]
    await b.step(rst=1)
    await b.step(rst=0)
    s = await b.step()
    assert s["idle"] and s["req_ready"] and not s["resp_valid"]


@cocotb.test()
async def fabric_reset_withdraws_pending_channels(dut: Any) -> None:
    """Check that a fabric reset cancels both pending channels and ID ownership."""
    b = Bench(dut)
    await b.reset()
    await b.request(8, 0x8000_0040, 6, write=True, cache=15, strb=(1 << 64) - 1)
    await b.request(9, 0x8000_0080, 6, cache=15)
    s = await b.step()
    assert s["axi_arvalid"] and s["axi_awvalid"] and s["axi_wvalid"]
    await b.step(rst=1, axi_rst=1)
    await b.step(rst=0, axi_rst=0)
    s = await b.step()
    assert s["idle"] and s["req_ready"]

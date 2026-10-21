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

"""FROST bridge channel ownership, narrow lanes, and delayed completion."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


class Bench:
    """Drive the public interfaces and track external transactions."""

    def __init__(self, dut: Any) -> None:
        """Initialize the interface and scoreboard."""
        self.dut = dut
        self.held: dict[str, tuple[int, ...]] = {}
        self.local_count = 0

    async def step(self, **inputs: int) -> dict[str, int]:
        """Advance one clock edge and sample the interface."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        groups = {
            "local_": (
                "valid",
                "write",
                "addr",
                "size",
                "prot",
                "wdata",
                "wstrb",
                "error",
            ),
            "axi_r": ("valid", "id", "data", "resp", "last", "user"),
            "axi_b": ("valid", "id", "resp", "user"),
            "ddr_axi_ar": ("valid", "id", "addr", "len", "size", "burst"),
            "ddr_axi_aw": ("valid", "id", "addr", "len", "size", "burst"),
            "ddr_axi_w": ("valid", "data", "strb", "last"),
        }
        names = [
            "axi_awready",
            "axi_wready",
            "axi_arready",
            "local_resp_ready",
            "ddr_axi_rready",
            "ddr_axi_bready",
        ]
        names += [
            prefix + field for prefix, fields in groups.items() for field in fields
        ]
        s = {name: int(getattr(self.dut, "o_" + name).value) for name in names}
        for prefix, fields in groups.items():
            reset = int(self.dut.i_axi_rst.value)
            payload = tuple(s[prefix + field] for field in fields[1:])
            # Read requests have no meaningful write payload.
            if prefix == "local_" and not s["local_write"]:
                payload = payload[:4] + payload[-1:]
            valid = s[prefix + "valid"]
            if prefix in self.held and not reset:
                assert valid and payload == self.held[prefix], prefix
            if valid and not int(getattr(self.dut, "i_" + prefix + "ready").value):
                self.held[prefix] = payload
            else:
                self.held.pop(prefix, None)
        self.local_count += s["local_valid"] * int(self.dut.i_local_ready.value)
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")
        return s

    async def reset(self) -> None:
        """Reset the device and initialize its inputs."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        await self.step(
            axi_rst=1, axi_wlast=1, ddr_axi_rlast=1, axi_awburst=1, axi_arburst=1
        )
        await self.step()
        await self.step(axi_rst=0)

    async def address(self, channel: str, ident: int, addr: int, size: int) -> None:
        """Check address."""
        for _ in range(40):
            s = await self.step(
                **{
                    f"axi_{channel}valid": 1,
                    f"axi_{channel}id": ident,
                    f"axi_{channel}addr": addr,
                    f"axi_{channel}size": size,
                    f"axi_{channel}prot": 3,
                }
            )
            if s[f"axi_{channel}ready"]:
                getattr(self.dut, f"i_axi_{channel}valid").value = 0
                return
        raise AssertionError("address was never accepted")


@cocotb.test()
async def narrow_lanes_complete_once_on_response(dut: Any) -> None:
    """Check narrow lanes complete once on response."""
    b = Bench(dut)
    await b.reset()
    data = int.from_bytes(bytes(range(64)), "little")
    for size in range(4):
        addr = 0x40000000 + 64 - (1 << size)
        strb = ((1 << (1 << size)) - 1) << (addr & 63)
        await b.address("aw", 32, addr, size)
        await b.step(axi_wvalid=1, axi_wdata=data, axi_wstrb=strb)
        for _ in range(5):
            s = await b.step()
            assert s["local_valid"] and not s["axi_bvalid"]
            assert (s["local_addr"], s["local_size"], s["local_prot"]) == (
                addr,
                size,
                3,
            )
            assert s["local_wdata"] == data >> 448
            assert s["local_wstrb"] == strb >> 56
        s = await b.step(local_ready=1)
        assert s["axi_wready"]
        await b.step(axi_wvalid=0, local_ready=0)
        for _ in range(7):
            assert not (await b.step())["axi_bvalid"]
        s = await b.step(local_resp_valid=1, local_resp_status=2)
        assert s["local_resp_ready"]
        for _ in range(4):
            s = await b.step(local_resp_valid=0)
            assert s["axi_bvalid"] and s["axi_bid"] == 32 and s["axi_bresp"] == 2
        await b.step(axi_bready=1)
        await b.step(axi_bready=0)
        await b.address("ar", 35, addr, size)
        await b.step(local_ready=1)
        await b.step(
            local_ready=0,
            local_resp_valid=1,
            local_resp_rdata=0xDEADBEEF,
            local_resp_status=3,
        )
        for _ in range(4):
            s = await b.step(local_resp_valid=0)
            assert s["axi_rvalid"] and s["axi_rid"] == 35 and s["axi_rresp"] == 3
            assert s["axi_rdata"] == 0xDEADBEEF << 448
        await b.step(axi_rready=1)
        await b.step(axi_rready=0)
    assert b.local_count == 8


@cocotb.test()
async def stalled_local_write_cannot_be_replaced_by_later_read(dut: Any) -> None:
    """Check stalled local write cannot be replaced by later read."""
    b = Bench(dut)
    await b.reset()
    await b.address("aw", 32, 0x40000000, 2)
    await b.step(axi_wvalid=1, axi_wstrb=15, axi_wdata=0x1234)
    await b.address("ar", 34, 0x1000, 3)
    for _ in range(5):
        s = await b.step()
        assert s["local_valid"] and s["local_write"] and s["local_addr"] == 0x40000000
    await b.step(local_ready=1)
    await b.step(axi_wvalid=0, local_ready=0, local_resp_valid=1)
    s = await b.step(local_resp_valid=0, local_ready=1)
    assert s["local_valid"] and not s["local_write"] and s["local_addr"] == 0x1000
    assert b.local_count == 2


@cocotb.test()
async def ddr_channels_and_response_mux_hold_ownership(dut: Any) -> None:
    """Check ddr channels and response mux hold ownership."""
    b = Bench(dut)
    await b.reset()
    await b.address("aw", 17, 0x80001000, 6)
    s = await b.step(
        axi_wvalid=1, axi_wdata=0x123456, axi_wstrb=(1 << 64) - 1, ddr_axi_wready=1
    )
    assert s["ddr_axi_wvalid"] and s["axi_wready"]
    for _ in range(5):
        s = await b.step(axi_wvalid=0, ddr_axi_wready=0)
        assert s["ddr_axi_awvalid"] and not s["ddr_axi_wvalid"]
        assert s["ddr_axi_awaddr"] == 0x1000 and s["ddr_axi_awid"] == 17
    await b.step(ddr_axi_awready=1)
    await b.step(ddr_axi_awready=0, ddr_axi_arready=1)
    await b.address("ar", 21, 0x80002000, 6)
    # A DDR R is already stalled when a local R becomes available.
    await b.step(
        ddr_axi_rvalid=1, ddr_axi_rid=21, ddr_axi_rdata=0x5678, ddr_axi_rresp=2
    )
    await b.address("ar", 34, 0x1000, 3)
    await b.step(local_ready=1)
    await b.step(local_ready=0, local_resp_valid=1, local_resp_rdata=0xCAFE)
    for _ in range(5):
        s = await b.step(local_resp_valid=0)
        assert s["axi_rid"] == 21 and s["axi_rdata"] == 0x5678 and s["axi_rresp"] == 2
    await b.step(axi_rready=1)
    s = await b.step(ddr_axi_rvalid=0)
    assert s["axi_rvalid"] and s["axi_rid"] == 34 and s["axi_rdata"] == 0xCAFE
    await b.step(axi_rready=0, ddr_axi_bvalid=1, ddr_axi_bid=17, ddr_axi_bresp=3)
    await b.address("aw", 32, 0x40000000, 0)
    await b.step(axi_wvalid=1, axi_wstrb=1, local_ready=1)
    await b.step(axi_wvalid=0, local_ready=0, local_resp_valid=1, local_resp_status=2)
    for _ in range(5):
        s = await b.step(local_resp_valid=0)
        assert s["axi_bid"] == 17 and s["axi_bresp"] == 3
    await b.step(axi_bready=1)
    s = await b.step(ddr_axi_bvalid=0)
    assert s["axi_bvalid"] and s["axi_bid"] == 32 and s["axi_bresp"] == 2


@cocotb.test()
async def unsupported_ddr_id_is_rejected_without_alias(dut: Any) -> None:
    """Check unsupported ddr id is rejected without alias."""
    b = Bench(dut)
    await b.reset()
    await b.address("ar", 35, 0x80001000, 6)
    s = await b.step(local_ready=1, ddr_axi_arready=1)
    assert not s["ddr_axi_arvalid"] and s["local_error"]
    await b.step(local_ready=0, local_resp_valid=1, local_resp_status=3)
    s = await b.step(local_resp_valid=0, axi_rready=1)
    assert s["axi_rvalid"] and s["axi_rid"] == 35 and s["axi_rresp"] == 3

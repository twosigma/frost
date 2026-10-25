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

"""A single-transaction AXI4-Lite master with independent AW and W timing."""

from typing import Any

from cocotb.triggers import FallingEdge, RisingEdge, Timer


class AxilMaster:
    """Drive independent request channels and accept one response per access."""

    def __init__(self, dut: Any, prefix: str = "axil") -> None:
        """Bind the DUT clock and AXI4-Lite signal prefix."""
        self.dut = dut
        self.prefix = prefix

    def signal(self, name: str) -> Any:
        """Return a signal with the slave port direction."""
        direction = (
            "o"
            if name
            in {
                "awready",
                "wready",
                "bvalid",
                "bresp",
                "arready",
                "rvalid",
                "rdata",
                "rresp",
            }
            else "i"
        )
        return getattr(self.dut, f"{direction}_{self.prefix}_{name}")

    def idle(self) -> None:
        """Initialize master inputs while the slave is in reset."""
        for name in (
            "awvalid",
            "awaddr",
            "awprot",
            "wvalid",
            "wdata",
            "wstrb",
            "bready",
            "arvalid",
            "araddr",
            "arprot",
            "rready",
        ):
            self.signal(name).value = 0

    async def write(
        self,
        addr: int,
        data: int,
        strb: int = 255,
        *,
        aw_delay: int = 0,
        w_delay: int = 0,
        response_delay: int = 0,
    ) -> None:
        """Write once, allowing channel skew and B backpressure."""
        aw_done = w_done = False
        response_seen = 0
        for cycle in range(1000):
            await FallingEdge(self.dut.i_clk)
            self.signal("awvalid").value = int(not aw_done and cycle >= aw_delay)
            self.signal("awaddr").value = addr
            self.signal("wvalid").value = int(not w_done and cycle >= w_delay)
            self.signal("wdata").value = data
            self.signal("wstrb").value = strb
            self.signal("bready").value = int(response_seen >= response_delay)
            await Timer(1, unit="ps")
            aw_fire = int(self.signal("awvalid").value) and int(
                self.signal("awready").value
            )
            w_fire = int(self.signal("wvalid").value) and int(
                self.signal("wready").value
            )
            bvalid = int(self.signal("bvalid").value)
            b_fire = bvalid and int(self.signal("bready").value)
            if bvalid:
                assert aw_done and w_done
                assert int(self.signal("bresp").value) == 0
                response_seen += 1
            await RisingEdge(self.dut.i_clk)
            await Timer(1, unit="ps")
            aw_done |= bool(aw_fire)
            w_done |= bool(w_fire)
            if b_fire:
                return
        raise AssertionError("AXI4-Lite write timeout")

    async def read(self, addr: int, *, response_delay: int = 0) -> int:
        """Read once and check response stability under R backpressure."""
        ar_done = False
        response_seen = 0
        result = None
        for _ in range(1000):
            await FallingEdge(self.dut.i_clk)
            self.signal("arvalid").value = int(not ar_done)
            self.signal("araddr").value = addr
            self.signal("rready").value = int(response_seen >= response_delay)
            await Timer(1, unit="ps")
            ar_fire = int(self.signal("arvalid").value) and int(
                self.signal("arready").value
            )
            rvalid = int(self.signal("rvalid").value)
            r_fire = rvalid and int(self.signal("rready").value)
            if rvalid:
                assert ar_done
                assert int(self.signal("rresp").value) == 0
                data = int(self.signal("rdata").value)
                if result is None:
                    result = data
                assert result == data
                response_seen += 1
            await RisingEdge(self.dut.i_clk)
            await Timer(1, unit="ps")
            ar_done |= bool(ar_fire)
            if r_fire:
                assert result is not None
                return result
        raise AssertionError("AXI4-Lite read timeout")

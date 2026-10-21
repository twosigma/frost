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

"""Page-table bus errors at every walk level, including poisoned responses."""

from typing import Any
import cocotb
from cocotb.triggers import Timer


class Bench:
    """Drive dependent PTE requests without using internal walker state."""

    def __init__(self, dut: Any) -> None:
        """Initialize the interface and scoreboard."""
        self.dut = dut

    async def step(self, **inputs: int) -> dict[str, int]:
        """Sample outputs before the accepting clock edge."""
        self.dut.i_clk.value = 0
        for name, value in inputs.items():
            getattr(self.dut, "i_" + name).value = value
        await Timer(5, unit="ns")
        s = {
            n: int(getattr(self.dut, "o_" + n).value)
            for n in (
                "req_ready",
                "resp_valid",
                "resp",
                "line_req_valid",
                "line_req_addr",
            )
        }
        self.dut.i_clk.value = 1
        await Timer(5, unit="ns")
        return s

    async def reset(self) -> None:
        """Initialize a cached root at 0x80000000."""
        await self.step(
            rst=1,
            root_ppn=0x80000,
            req_valid=0,
            req_vpn=0,
            discard=0,
            line_req_ready=0,
            line_resp_valid=0,
            line_resp_error=0,
            line_resp_id=0,
            line_resp_rdata=0,
        )
        await self.step(rst=0)

    async def issue(self) -> None:
        """Launch one walk for VPN zero."""
        s = await self.step(req_valid=1)
        assert s["req_ready"]
        await self.step(req_valid=0)

    async def line(
        self, addr: int, pte: int, error: bool = False, discard: bool = False
    ) -> None:
        """Stall each request, then return the selected PTE or a failed beat."""
        for _ in range(15):
            s = await self.step()
            if s["line_req_valid"]:
                break
        else:
            raise AssertionError("walker did not issue a PTE read")
        for _ in range(3):
            s = await self.step()
            assert s["line_req_valid"] and s["line_req_addr"] == addr
        await self.step(line_req_ready=1)
        await self.step(line_req_ready=0)
        for _ in range(4):
            assert not (await self.step())["resp_valid"]
        await self.step(
            line_resp_valid=1,
            line_resp_rdata=pte,
            line_resp_error=int(error),
            discard=int(discard),
        )
        self.dut.i_line_resp_valid.value = 0
        self.dut.i_discard.value = 0


@cocotb.test()
async def access_fault_at_each_level_and_successful_retry(dut: Any) -> None:
    """Check that an error overrides PTE contents and does not poison a subsequent walk."""
    b = Bench(dut)
    for fail_at in range(3):
        await b.reset()
        await b.issue()
        for depth in range(fail_at + 1):
            await b.line(
                0x80000000 + depth * 4096,
                ((0x80001 + depth) << 10) | 1,
                error=depth == fail_at,
            )
        s = await b.step()
        assert s["resp_valid"] and (s["resp"] >> 78) == 3
        await b.step()
        await b.issue()
        # Aligned 1 GiB leaf, V/R/W/X/A/D. This retry must succeed.
        await b.line(0x80000000, (0x80000 << 10) | 0xCF)
        await b.step()
        s = await b.step()
        assert s["resp_valid"] and (s["resp"] >> 78) == 0
        await b.step()


@cocotb.test()
async def discarded_error_drains_without_faulting_the_next_request(dut: Any) -> None:
    """Check that sFENCE/satp discard suppresses a late bus error but frees the walker."""
    b = Bench(dut)
    await b.reset()
    await b.issue()
    await b.line(0x80000000, 0, error=True, discard=True)
    for _ in range(6):
        assert not (await b.step())["resp_valid"]
    await b.issue()
    await b.line(0x80000000, (0x80000 << 10) | 0xCF)
    await b.step()
    s = await b.step()
    assert s["resp_valid"] and (s["resp"] >> 78) == 0

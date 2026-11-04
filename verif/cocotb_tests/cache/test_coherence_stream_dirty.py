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

"""Keep dirty ownership across stale hint eligibility and delayed writeback."""

from typing import Any

import cocotb

from cocotb_tests.cache.test_coherence_endpoints import pack
from cocotb_tests.cache.test_coherence_home import unpack
from cocotb_tests.cache.test_coherence_l1d_stream import StreamPrivate


class DirtyStream(StreamPrivate):
    """Record a hint checked before its sector becomes a frozen writeback."""

    def __init__(self, dut: Any) -> None:
        """Initialize the final-admission hazard witness."""
        super().__init__(dut)
        self.checked_before_freeze = False

    async def tick(self, count: int = 1) -> None:
        """Observe eligibility beside the independent dirty-victim pipeline."""
        for _ in range(count):
            if (
                not self.get("i_rst")
                and self.get("hint_valid_q")
                and self.get("hint_checked_q")
                and self.get("hint_eligible_q")
                and self.get("hint_addr_q") == 0x80000060
                and not self.get("wb_live")
            ):
                self.checked_before_freeze = True
            await super().tick()

    async def frozen_hint_sector(self) -> None:
        """Evict a Modified hint target after its registered eligibility check."""
        await self.reset()
        await self.set(i_address=0x80000060, i_write_mask=255, i_write_data=0xDEADBEEF)
        await self.tick()
        await self.set(i_write_mask=0)
        await self.requests_at_least(1)
        await self.grant(0)
        await self.release(0)
        await self.issue(0, 0x80000260)
        await self.requests_at_least(2)
        await self.issue(1, 0x80000000)
        await self.issue(2, 0x80000020)
        await self.issue(3, 0x80000040)
        for _ in range(100):
            if (
                self.get("phase_q") == 2
                and self.get("lookup_addr_q") == 0x80000040
                and self.get("array_valid")
            ):
                break
            await self.tick()
        else:
            raise AssertionError("Third training lookup did not occur")
        await self.grant(1)
        await self.release(1)
        await self.wait("o_w_valid")
        assert self.checked_before_freeze
        put = unpack(self.get("o_w"), (1, 1, 1, self.p, 256, 1))
        assert put[3] == 0x80000060 and put[4] & ((1 << 64) - 1) == 0xDEADBEEF
        await self.tick(60)
        assert not any(r[2] == 0x80000060 and r[0] == 0 for _, r in self.requests)
        assert not self.get("o_fatal")


@cocotb.test()
async def frozen_sector_excludes_hint_through_absorption(dut: Any) -> None:
    """Return frozen dirty bytes to a probe while rejecting its stale hint."""
    b = DirtyStream(dut)
    await b.frozen_hint_sector()
    await b.set(
        i_p_valid=1,
        i_p=pack(
            (2, 0),
            (6, 17),
            (1, 0),
            (b.p, 0x80000060),
            (2, 2),
            (2, 0),
            (9, 0),
            (5, 0),
            (3, 3),
        ),
    )
    await b.wait("o_p_ready")
    await b.tick()
    await b.set(i_p_valid=0)
    await b.wait("o_r_valid")
    reply = unpack(b.get("o_r"), (2, 6, 1, 1, b.p, 2, 1, 1, 256, 1, 1, 1, 1, 1))
    assert reply[7] and reply[9]
    assert reply[8] & ((1 << 64) - 1) == 0xDEADBEEF
    await b.tick(20)
    assert b.get("o_r_valid") and b.get("wb_live")
    await b.set(i_r_ready=1)
    await b.tick()
    await b.set(
        i_r_ready=0,
        i_wa_valid=1,
        i_wa=pack(
            (1, 0), (1, reply[10]), (1, 0), (b.p, 0x80000060), (1, 1), (6, 17), (1, 0)
        ),
    )
    await b.wait("o_wa_ready")
    await b.tick()
    await b.set(i_wa_valid=0)
    assert not b.get("wb_live") and not b.get("o_fatal")


@cocotb.test()
async def dirty_writeback_error_remains_fatal(dut: Any) -> None:
    """Preserve dirty-data failure handling while look-ahead is active."""
    b = DirtyStream(dut)
    await b.reset()
    await b.set(i_address=0x80000260, i_write_mask=255, i_write_data=0xDEADBEEF)
    await b.tick()
    await b.set(i_write_mask=0)
    await b.requests_at_least(1)
    await b.grant(0)
    await b.release(0)
    await b.issue(0, 0x80000000)
    await b.issue(1, 0x80000020)
    await b.issue(2, 0x80000040)
    await b.requests_at_least(5)
    hint = next(
        i for i, (_, request) in enumerate(b.requests) if request[2] == 0x80000060
    )
    assert b.get("ld_prefetch_q") >> b.requests[hint][0] & 1
    await b.grant(hint)
    await b.wait("o_w_valid")
    put = unpack(b.get("o_w"), (1, 1, 1, b.p, 256, 1))
    await b.set(i_w_ready=1)
    await b.tick()
    await b.set(
        i_w_ready=0,
        i_wa_valid=1,
        i_wa=pack((1, 0), (1, put[1]), (1, 0), (b.p, put[3]), (1, 0), (6, 0), (1, 1)),
    )
    await b.wait("o_wa_ready")
    await b.tick()
    await b.set(i_wa_valid=0)
    await b.wait("o_fatal")
    assert b.get("o_fatal_addr") == 0x80000260

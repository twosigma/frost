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

"""Unit tests for the low-BRAM slow-metadata request presenter.

The bench models the registered response-ready bit from ``imem_predecode``.
It verifies that an unready low request repeats exactly after the preceding
response publishes, that a ready response is held until publication is
allowed, and that ready requests, high-tier traffic, retargets, and unresolved
translations continue to expose the live seam.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLOCK_PERIOD_NS = 10


def _drive_request(
    dut: Any,
    pc: int,
    *,
    pa0: int | None = None,
    pa_valid: int = 1,
    owner_low: int = 1,
    faults: tuple[int, int, int, int] = (0, 0, 0, 0),
) -> None:
    """Drive one complete live VA/PA/fault request bundle."""
    physical0 = pc if pa0 is None else pa0
    dut.i_pc.value = pc
    dut.i_pa0.value = physical0
    dut.i_pa1.value = (physical0 + 4) & 0xFFFF_FFFF
    dut.i_pa_valid.value = pa_valid
    dut.i_owner_low.value = owner_low
    dut.i_fault0.value = faults[0]
    dut.i_fault0_page.value = faults[1]
    dut.i_fault1.value = faults[2]
    dut.i_fault1_page.value = faults[3]


async def _settle() -> None:
    await Timer(1, unit="ns")


def _check_presented(
    dut: Any,
    pc: int,
    pa0: int,
    *,
    pa_valid: int = 1,
    faults: tuple[int, int, int, int] = (0, 0, 0, 0),
) -> None:
    """Check every externally presented request field."""
    assert int(dut.o_fetch_address.value) == pc
    assert int(dut.o_fetch_pa0.value) == pa0
    assert int(dut.o_fetch_pa1.value) == (pa0 + 4) & 0xFFFF_FFFF
    assert int(dut.o_fetch_pa_valid.value) == pa_valid
    assert int(dut.o_fetch_fault0.value) == faults[0]
    assert int(dut.o_fetch_fault0_page.value) == faults[1]
    assert int(dut.o_fetch_fault1.value) == faults[2]
    assert int(dut.o_fetch_fault1_page.value) == faults[3]


@cocotb.test()
async def test_exact_repeat_and_live_bypass(dut: Any) -> None:
    """Cover slow repeat, retarget, high-tier, and unresolved-PA behavior."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_response_ready.value = 0
    dut.i_response_overlay_hit.value = 0
    dut.i_response_claim.value = 1
    dut.i_publish_hold.value = 0
    dut.i_retarget.value = 0
    _drive_request(dut, 0, pa_valid=0)
    await RisingEdge(dut.i_clk)
    await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0

    # Overlay hit is the registered proof that the preceding memory request
    # belongs to the timed low range. Its old always-valid contract must not
    # depend on the slow presenter's owner/PA-valid state (that dependency
    # would put these state flops at the head of the fast PC recurrence).
    _drive_request(dut, 0x8000_0000, pa_valid=0, owner_low=0)
    dut.i_response_ready.value = 1
    dut.i_response_overlay_hit.value = 1
    await _settle()
    assert int(dut.o_response_valid.value) == 1

    # Ready overlay responses retain the old live-through behavior, including
    # arbitrary live movement such as the PC movement around a pipeline stall.
    overlay_pc = 0x1200
    _drive_request(dut, overlay_pc)
    dut.i_response_ready.value = 1
    dut.i_response_overlay_hit.value = 1
    await RisingEdge(dut.i_clk)
    await _settle()
    assert int(dut.o_response_valid.value) == 1
    live_pc = 0x1220
    _drive_request(dut, live_pc)
    await _settle()
    _check_presented(dut, live_pc, live_pc)
    dut.i_publish_hold.value = 1
    held_overlay_live_pc = 0x1240
    _drive_request(dut, held_overlay_live_pc)
    await _settle()
    assert int(dut.o_response_valid.value) == 1
    _check_presented(dut, held_overlay_live_pc, held_overlay_live_pc)
    dut.i_publish_hold.value = 0

    # Capture a slow request while the prior response is ready. If its own
    # ready bit drops after the prior response publishes, this already-launched
    # request is the owed fetch and must repeat exactly rather than being
    # skipped for the newly advanced live PC.
    slow_pc = 0x5000
    slow_pa = 0x0001_5000
    slow_faults = (1, 1, 0, 0)
    _drive_request(dut, slow_pc, pa0=slow_pa, faults=slow_faults)
    await RisingEdge(dut.i_clk)
    dut.i_response_ready.value = 0
    dut.i_response_overlay_hit.value = 0
    _drive_request(dut, 0x6000, pa0=0x0001_6000, faults=(0, 0, 1, 1))
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, slow_pc, slow_pa, faults=slow_faults)

    # It continues repeating exactly even if all live fields move again.
    await RisingEdge(dut.i_clk)
    _drive_request(dut, 0x6800, pa0=0x0001_6800, faults=(1, 0, 0, 1))
    await _settle()
    _check_presented(dut, slow_pc, slow_pa, faults=slow_faults)

    # Its now-ready response can publish while the pins immediately launch the
    # latest live request.
    dut.i_response_ready.value = 1
    await _settle()
    assert int(dut.o_response_valid.value) == 1
    _check_presented(dut, 0x6800, 0x0001_6800, faults=(1, 0, 0, 1))

    # That different request is now the owed fetch. Its first slow response is
    # unready, so it must repeat rather than being mistaken for a residual copy
    # of the response that just published.
    await RisingEdge(dut.i_clk)
    dut.i_response_ready.value = 0
    _drive_request(dut, 0x6C00, pa0=0x0001_6C00)
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, 0x6800, 0x0001_6800, faults=(1, 0, 0, 1))

    # A response that becomes ready while publication is held must retain its
    # exact request and remain invalid until the hold is released. Start this
    # independent episode with an explicit retarget so the still-owed live
    # successor from the preceding slow publication is cancelled lawfully.
    held_pc = 0x7000
    held_pa = 0x0001_7000
    _drive_request(dut, held_pc, pa0=held_pa)
    dut.i_response_ready.value = 0
    dut.i_retarget.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_retarget.value = 0
    _drive_request(dut, 0x7400, pa0=0x0001_7400)
    await RisingEdge(dut.i_clk)
    dut.i_response_ready.value = 1
    dut.i_publish_hold.value = 1
    _drive_request(dut, 0x7800, pa0=0x0001_7800)
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, held_pc, held_pa)
    await RisingEdge(dut.i_clk)
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, held_pc, held_pa)
    dut.i_publish_hold.value = 0
    await _settle()
    assert int(dut.o_response_valid.value) == 1
    _check_presented(dut, 0x7800, 0x0001_7800)

    # Start an independent episode in which the pins still carry the same slow
    # request when it publishes on the raw first stall cycle. Preserve that
    # identity-qualified fact through the registered hold; release must chase
    # the live successor without publishing the old response a second time.
    residual_pc = 0x7900
    residual_pa = 0x0001_7900
    dut.i_response_ready.value = 0
    dut.i_retarget.value = 1
    _drive_request(dut, residual_pc, pa0=residual_pa)
    await RisingEdge(dut.i_clk)
    dut.i_retarget.value = 0
    dut.i_response_ready.value = 1
    await _settle()
    assert int(dut.o_response_valid.value) == 1
    _check_presented(dut, residual_pc, residual_pa)
    await RisingEdge(dut.i_clk)
    dut.i_publish_hold.value = 1
    _drive_request(dut, 0x7A00, pa0=0x0001_7A00)
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, residual_pc, residual_pa)
    await RisingEdge(dut.i_clk)
    await RisingEdge(dut.i_clk)
    dut.i_publish_hold.value = 0
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, 0x7A00, 0x0001_7A00)

    # A true retarget cancels an unready repeat and launches the target now.
    obsolete_pc = 0x7C00
    _drive_request(dut, obsolete_pc)
    await RisingEdge(dut.i_clk)
    dut.i_response_ready.value = 0
    target_pc = 0x2400
    _drive_request(dut, target_pc)
    dut.i_retarget.value = 1
    await _settle()
    _check_presented(dut, target_pc, target_pc)
    await RisingEdge(dut.i_clk)
    dut.i_retarget.value = 0
    await _settle()
    _check_presented(dut, target_pc, target_pc)

    # An unresolved request never owns a retry. The resolved live PA must be
    # sampled instead of deadlocking on the placeholder physical address.
    dut.i_response_ready.value = 1
    unresolved_pc = 0x3800
    _drive_request(dut, unresolved_pc, pa0=0, pa_valid=0)
    await RisingEdge(dut.i_clk)
    dut.i_response_ready.value = 0
    resolved_pa = 0x0001_3800
    _drive_request(dut, unresolved_pc, pa0=resolved_pa, pa_valid=1)
    await _settle()
    _check_presented(dut, unresolved_pc, resolved_pa)

    # Cached high-tier traffic never owns the low BRAM, so an unready wrapped
    # alias cannot delay a subsequent low request.
    dut.i_response_ready.value = 1
    _drive_request(dut, 0x8000_1000, owner_low=0)
    await RisingEdge(dut.i_clk)
    dut.i_response_ready.value = 0
    low_target = 0x3000
    _drive_request(dut, low_target, owner_low=1)
    await _settle()
    _check_presented(dut, low_target, low_target)


@cocotb.test()
async def test_only_claimed_slow_identity_waits_for_live_change(dut: Any) -> None:
    """Retry an unclaimed response, then suppress it once IF claims it."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_response_ready.value = 0
    dut.i_response_overlay_hit.value = 0
    dut.i_response_claim.value = 0
    dut.i_publish_hold.value = 0
    dut.i_retarget.value = 0
    _drive_request(dut, 0, pa_valid=0)
    await RisingEdge(dut.i_clk)
    await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0

    # A ready response that IF squashes is not publication. While the live seam
    # still carries the exact same request it must remain eligible every cycle.
    held_pc = 0x5200
    held_pa = 0x0001_5200
    held_faults = (1, 0, 0, 1)
    _drive_request(dut, held_pc, pa0=held_pa, faults=held_faults)
    await RisingEdge(dut.i_clk)
    dut.i_response_ready.value = 1
    await _settle()
    assert int(dut.o_response_valid.value) == 1
    _check_presented(dut, held_pc, held_pa, faults=held_faults)
    await RisingEdge(dut.i_clk)

    for _ in range(2):
        await _settle()
        assert int(dut.o_response_valid.value) == 1
        _check_presented(dut, held_pc, held_pa, faults=held_faults)
        await RisingEdge(dut.i_clk)

    # Once IF claims the live packet, suppress the residual synchronous copy
    # until the complete live request identity changes.
    dut.i_response_claim.value = 1
    await _settle()
    assert int(dut.o_response_valid.value) == 1
    await RisingEdge(dut.i_clk)
    for _ in range(3):
        await _settle()
        assert int(dut.o_response_valid.value) == 0
        _check_presented(dut, held_pc, held_pa, faults=held_faults)
        await RisingEdge(dut.i_clk)

    # A physical/fault identity change at the same VA is a new request. The
    # residual old response is suppressed on the transition cycle, then the
    # new slow request observes the ordinary unready/ready fallback cadence.
    changed_pa = 0x0002_5200
    changed_faults = (0, 1, 1, 0)
    _drive_request(dut, held_pc, pa0=changed_pa, faults=changed_faults)
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, held_pc, changed_pa, faults=changed_faults)
    await RisingEdge(dut.i_clk)

    dut.i_response_ready.value = 0
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, held_pc, changed_pa, faults=changed_faults)
    await RisingEdge(dut.i_clk)

    dut.i_response_ready.value = 1
    await _settle()
    assert int(dut.o_response_valid.value) == 1
    _check_presented(dut, held_pc, changed_pa, faults=changed_faults)
    await RisingEdge(dut.i_clk)

    # Changing ownership at the same VA/PA also ends the low request's
    # identity. High-tier traffic can never publish through this presenter.
    _drive_request(
        dut,
        held_pc,
        pa0=changed_pa,
        owner_low=0,
        faults=changed_faults,
    )
    await _settle()
    assert int(dut.o_response_valid.value) == 0
    _check_presented(dut, held_pc, changed_pa, faults=changed_faults)
    await RisingEdge(dut.i_clk)
    await _settle()
    assert int(dut.o_response_valid.value) == 0

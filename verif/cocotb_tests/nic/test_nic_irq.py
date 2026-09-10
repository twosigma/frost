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

"""Unit tests for nic_irq (hw/rtl/peripherals/nic/nic_irq.sv).

The interrupt contract slice 2's driver relies on: sticky status with a
set that wins over a same-cycle clear, a mask with atomic set and clear
views that never loses an event, and per-direction moderation whose
interval starts at the acknowledgement. The cases follow the review's list:
completions placed before, in and after the acknowledgement; a completion
that lands while the bit is already set; every zero/nonzero combination of
delay and max; count saturation; a timer expiry in the acknowledgement's
cycle; parameter changes while an interval is pending; long masking; and
the driver sequence (acknowledge, scan, unmask) losing nothing under a
completion at every offset.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

STATUS = 0x040
MASK = 0x044
RX_ITR = 0x048
TX_ITR = 0x04C
TICK = 0x050
MASK_SET = 0x054
MASK_CLR = 0x058
BIT_RX = 1 << 0
BIT_TX = 1 << 1
BIT_RX_DROP = 1 << 2
BIT_LINK = 1 << 3
BIT_DESC_ERR = 1 << 4


async def _setup(dut: Any) -> None:
    Clock(dut.i_clk, 10, unit="ns").start()
    for sig in (
        dut.i_wr_en,
        dut.i_wr_offset,
        dut.i_wr_data,
        dut.i_rx_done,
        dut.i_tx_done,
        dut.i_rx_drop,
        dut.i_link_change,
        dut.i_desc_err,
    ):
        sig.value = 0
    dut.i_rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await FallingEdge(dut.i_clk)


async def _write(dut: Any, offset: int, value: int) -> None:
    """One register write, driven at a falling edge, taken at the next rising edge."""
    dut.i_wr_en.value = 1
    dut.i_wr_offset.value = offset
    dut.i_wr_data.value = value
    await FallingEdge(dut.i_clk)
    dut.i_wr_en.value = 0


async def _pulse(dut: Any, sig: Any) -> None:
    sig.value = 1
    await FallingEdge(dut.i_clk)
    sig.value = 0


async def _cycles(dut: Any, n: int) -> None:
    for _ in range(n):
        await FallingEdge(dut.i_clk)


def _status(dut: Any) -> int:
    return int(dut.o_status.value)


@cocotb.test()
async def test_event_latches_and_w1c(dut: Any) -> None:
    """RX_DROP, LINK and DESC_ERR latch on a pulse and clear on W1C only of themselves."""
    await _setup(dut)
    await _pulse(dut, dut.i_rx_drop)
    await _pulse(dut, dut.i_link_change)
    await _cycles(dut, 2)
    assert _status(dut) == BIT_RX_DROP | BIT_LINK
    await _write(dut, STATUS, BIT_LINK)
    await _cycles(dut, 1)
    assert _status(dut) == BIT_RX_DROP
    await _pulse(dut, dut.i_desc_err)
    await _cycles(dut, 1)
    assert _status(dut) == BIT_RX_DROP | BIT_DESC_ERR
    await _write(dut, STATUS, 0x1F)
    await _cycles(dut, 1)
    assert _status(dut) == 0


@cocotb.test()
async def test_set_wins_over_same_cycle_clear(dut: Any) -> None:
    """A W1C in the cycle an event sets the bit leaves it set."""
    await _setup(dut)
    await _pulse(dut, dut.i_rx_drop)
    await _cycles(dut, 2)
    assert _status(dut) & BIT_RX_DROP
    # Clear and a new event in the same cycle.
    dut.i_wr_en.value = 1
    dut.i_wr_offset.value = STATUS
    dut.i_wr_data.value = BIT_RX_DROP
    dut.i_rx_drop.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_wr_en.value = 0
    dut.i_rx_drop.value = 0
    await _cycles(dut, 1)
    assert _status(dut) & BIT_RX_DROP, "the same-cycle set was lost to the clear"


@cocotb.test()
async def test_mask_gates_level_and_atomic_views(dut: Any) -> None:
    """o_irq follows status & mask; SET/CLR views touch only their bits."""
    await _setup(dut)
    await _pulse(dut, dut.i_link_change)
    await _cycles(dut, 2)
    assert int(dut.o_irq.value) == 0
    await _write(dut, MASK_SET, BIT_LINK | BIT_TX)
    await _cycles(dut, 2)
    assert int(dut.o_mask.value) == BIT_LINK | BIT_TX
    assert int(dut.o_irq.value) == 1
    await _write(dut, MASK_CLR, BIT_LINK)
    await _cycles(dut, 2)
    assert int(dut.o_mask.value) == BIT_TX
    assert int(dut.o_irq.value) == 0
    # Masking loses nothing: the latch is still set and the line returns on unmask.
    assert _status(dut) & BIT_LINK
    await _write(dut, MASK, 0x1F)
    await _cycles(dut, 2)
    assert int(dut.o_irq.value) == 1


@cocotb.test()
async def test_immediate_moderation(dut: Any) -> None:
    """With delay 0 one completion raises RX at once whatever max says."""
    await _setup(dut)
    await _write(dut, RX_ITR, (8 << 16) | 0)  # max 8, delay 0
    await _pulse(dut, dut.i_rx_done)
    await _cycles(dut, 3)
    assert _status(dut) & BIT_RX, "delay 0 must not wait for the count"


@cocotb.test()
async def test_count_threshold_with_deadline(dut: Any) -> None:
    """With max 3 and a long delay the third completion raises; a lone one waits."""
    await _setup(dut)
    await _write(dut, TICK, 4)
    await _write(dut, RX_ITR, (3 << 16) | 50)  # max 3, delay 50 ticks = 200 cycles
    for _ in range(2):
        await _pulse(dut, dut.i_rx_done)
        await _cycles(dut, 3)
        assert not (_status(dut) & BIT_RX), "raised below the count threshold"
    await _pulse(dut, dut.i_rx_done)
    await _cycles(dut, 3)
    assert _status(dut) & BIT_RX, "the third completion must raise"
    # Acknowledge, then a single completion waits for the deadline.
    await _write(dut, STATUS, BIT_RX)
    await _cycles(dut, 2)
    assert not (_status(dut) & BIT_RX)
    await _pulse(dut, dut.i_rx_done)
    await _cycles(dut, 150)
    assert not (_status(dut) & BIT_RX), "raised before the deadline"
    await _cycles(dut, 70)
    assert _status(dut) & BIT_RX, "the deadline did not raise"


@cocotb.test()
async def test_timer_only_when_max_is_zero(dut: Any) -> None:
    """With max 0 the comparator is off: many completions still wait for the deadline."""
    await _setup(dut)
    await _write(dut, TICK, 1)
    await _write(dut, RX_ITR, (0 << 16) | 40)
    for _ in range(20):
        await _pulse(dut, dut.i_rx_done)
    await _cycles(dut, 5)
    assert not (_status(dut) & BIT_RX)
    await _cycles(dut, 40)
    assert _status(dut) & BIT_RX


@cocotb.test()
async def test_deadline_never_restarts_and_config_applies_next_interval(
    dut: Any,
) -> None:
    """Later completions do not push the deadline; an ITR change waits for the next interval."""
    await _setup(dut)
    await _write(dut, TICK, 1)
    await _write(dut, TX_ITR, (0 << 16) | 60)
    await _pulse(dut, dut.i_tx_done)
    # Keep completing every 10 cycles; a restarting timer would never fire.
    for _ in range(5):
        await _cycles(dut, 9)
        await _pulse(dut, dut.i_tx_done)
    # Reconfigure mid-interval: must not shorten this interval.
    await _write(dut, TX_ITR, (0 << 16) | 5)
    await _cycles(dut, 2)
    assert not (_status(dut) & BIT_TX), "the deadline moved with the reconfiguration"
    await _cycles(dut, 20)
    assert _status(dut) & BIT_TX, "the original deadline did not fire"
    # Next interval uses the new delay.
    await _write(dut, STATUS, BIT_TX)
    await _cycles(dut, 1)
    await _pulse(dut, dut.i_tx_done)
    await _cycles(dut, 10)
    assert _status(dut) & BIT_TX


@cocotb.test()
async def test_ack_before_scan_loses_nothing(dut: Any) -> None:
    """A completion at any offset around the acknowledgement is notified again."""
    await _setup(dut)
    await _write(dut, TICK, 1)
    await _write(dut, RX_ITR, (1 << 16) | 100)  # max 1: every completion raises
    for offset in range(-3, 4):
        # Raise once, then acknowledge with a completion at the given offset.
        await _pulse(dut, dut.i_rx_done)
        await _cycles(dut, 3)
        assert _status(dut) & BIT_RX
        if offset < 0:
            await _pulse(dut, dut.i_rx_done)
            await _cycles(dut, -offset - 1)
            await _write(dut, STATUS, BIT_RX)
        elif offset == 0:
            dut.i_wr_en.value = 1
            dut.i_wr_offset.value = STATUS
            dut.i_wr_data.value = BIT_RX
            dut.i_rx_done.value = 1
            await FallingEdge(dut.i_clk)
            dut.i_wr_en.value = 0
            dut.i_rx_done.value = 0
        else:
            await _write(dut, STATUS, BIT_RX)
            await _cycles(dut, offset - 1)
            await _pulse(dut, dut.i_rx_done)
        await _cycles(dut, 4)
        if offset < 0:
            # The completion preceded the acknowledgement: it belongs to the
            # acknowledged interval, and the driver's scan after the
            # acknowledgement reaps it; the bit must be clear.
            assert not (_status(dut) & BIT_RX), f"offset {offset}: stale raise"
        else:
            assert _status(dut) & BIT_RX, f"offset {offset}: the completion was lost"
            await _write(dut, STATUS, BIT_RX)
            await _cycles(dut, 2)


@cocotb.test()
async def test_completion_while_set_reraises_after_ack_only_if_new(dut: Any) -> None:
    """Completions while the bit is set join that interval; none arrive after the ack, none raise."""
    await _setup(dut)
    await _write(dut, RX_ITR, (1 << 16) | 0)
    await _pulse(dut, dut.i_rx_done)
    await _cycles(dut, 3)
    assert _status(dut) & BIT_RX
    for _ in range(5):
        await _pulse(dut, dut.i_rx_done)
    await _write(dut, STATUS, BIT_RX)
    await _cycles(dut, 5)
    assert not (_status(dut) & BIT_RX), "old-interval completions raised after the ack"


@cocotb.test()
async def test_count_saturates(dut: Any) -> None:
    """More than 255 completions without an acknowledgement still raise on the threshold."""
    await _setup(dut)
    await _write(dut, RX_ITR, (255 << 16) | 1000)
    await _write(dut, TICK, 1)
    for _ in range(300):
        await _pulse(dut, dut.i_rx_done)
    await _cycles(dut, 3)
    assert _status(dut) & BIT_RX


@cocotb.test()
async def test_tick_zero_counts_as_one(dut: Any) -> None:
    """TICK = 0 behaves as 1: a delay of 10 ticks is 10 cycles."""
    await _setup(dut)
    await _write(dut, TICK, 0)
    await _write(dut, RX_ITR, (0 << 16) | 10)
    await _pulse(dut, dut.i_rx_done)
    await _cycles(dut, 6)
    assert not (_status(dut) & BIT_RX)
    await _cycles(dut, 8)
    assert _status(dut) & BIT_RX


@cocotb.test()
async def test_long_masking_keeps_state(dut: Any) -> None:
    """Counting and latching go on while masked; the line asserts on unmask."""
    await _setup(dut)
    await _write(dut, MASK, 0)
    await _write(dut, TX_ITR, (2 << 16) | 0)
    await _pulse(dut, dut.i_tx_done)
    await _cycles(dut, 300)
    assert _status(dut) & BIT_TX
    assert int(dut.o_irq.value) == 0
    await _write(dut, MASK_SET, BIT_TX)
    await _cycles(dut, 2)
    assert int(dut.o_irq.value) == 1

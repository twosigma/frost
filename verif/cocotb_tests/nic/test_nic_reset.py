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

"""Reset handshake tests on nic_reset_test_harness.

The harness holds nic_reset_ctrl, two nic_domain_reset far sides, two
async_fifos and a cdc_gray_count across three clocks. Checked: the RESET sequence (drain first, busy until the core-side reset is
done and the requests are up, never waiting for a MAC clock); the
per-domain generation handshake (ready only after the domain acknowledged
the current generation and left reset); an absent clock (RESET completes,
that domain stays not-ready, becomes ready when the clock returns); a clock
lost during operation (the domain drops to not-ready, a new generation runs
when it returns); a stale acknowledgement (a second RESET is not satisfied
by the previous generation); words left in a FIFO across a RESET never
reappear and the FIFO works after; the event counter survives a domain
reset without inventing events and the RESET clears it.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CORE_PS = 3334
TX_PS = 6206
RX_PS = 6202
TIMEOUT = 5000


class _Clocks:
    """Start/stop control over the two MAC clocks."""

    def __init__(self, dut: Any) -> None:
        self._dut = dut
        self._tx: Any = None
        self._rx: Any = None

    def start(self, tx: bool = True, rx: bool = True) -> None:
        """Start the selected MAC clocks."""
        if tx and self._tx is None:
            self._tx = Clock(self._dut.i_tx_clk, TX_PS, unit="ps")
            self._tx.start()
        if rx and self._rx is None:
            self._rx = Clock(self._dut.i_rx_clk, RX_PS, unit="ps")
            self._rx.start()

    def stop(self, tx: bool = False, rx: bool = False) -> None:
        """Stop the selected MAC clocks (the level freezes)."""
        if tx and self._tx is not None:
            self._tx.stop()
            self._tx = None
        if rx and self._rx is not None:
            self._rx.stop()
            self._rx = None


async def _setup(dut: Any, tx_clk: bool = True, rx_clk: bool = True) -> _Clocks:
    Clock(dut.i_clk, CORE_PS, unit="ps").start()
    clocks = _Clocks(dut)
    clocks.start(tx_clk, rx_clk)
    for sig in (
        dut.i_reset_req,
        dut.i_c2t_data,
        dut.i_c2t_valid,
        dut.i_t_ready,
        dut.i_r_data,
        dut.i_r_valid,
        dut.i_c_ready,
        dut.i_r_event,
    ):
        sig.value = 0
    dut.i_dma_idle.value = 1
    dut.i_tx_clk_ok.value = 1 if tx_clk else 0
    dut.i_rx_clk_ok.value = 1 if rx_clk else 0
    dut.i_rst.value = 1
    for _ in range(6):
        await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    return clocks


async def _core(dut: Any, n: int) -> None:
    for _ in range(n):
        await FallingEdge(dut.i_clk)


async def _wait_for(dut: Any, cond: Any, what: str, limit: int = TIMEOUT) -> int:
    """Wait (core cycles) until cond() holds; return the cycles taken."""
    for n in range(limit):
        if cond():
            return n
        await FallingEdge(dut.i_clk)
    raise AssertionError(f"timeout waiting for {what}")


async def _reset_and_wait(dut: Any) -> None:
    """Request RESET, see it start and finish, then wait for both domains ready."""
    # A full core cycle of request, aligned to the core clock (the caller
    # may return from another domain's edge).
    await FallingEdge(dut.i_clk)
    dut.i_reset_req.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_reset_req.value = 0
    await _wait_for(dut, lambda: int(dut.o_busy.value) == 1, "RESET start", 20)
    await _wait_for(dut, lambda: int(dut.o_busy.value) == 0, "RESET end", 200)
    await _wait_for(dut, lambda: _ready(dut) == (1, 1), "ready after RESET")


def _ready(dut: Any) -> tuple[int, int]:
    return int(dut.o_tx_ready.value), int(dut.o_rx_ready.value)


async def _push_c2t(dut: Any, words: list[int]) -> None:
    for w in words:
        dut.i_c2t_data.value = w
        dut.i_c2t_valid.value = 1
        await _wait_for(dut, lambda: int(dut.o_c2t_ready.value) == 1, "c2t ready")
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ps")
    dut.i_c2t_valid.value = 0


async def _pop(
    dut: Any, clk: Any, valid: Any, data: Any, ready: Any, n: int, limit: int
) -> list[int]:
    """Pop up to n words: observe at a falling edge, then let the rising edge pop."""
    got: list[int] = []
    ready.value = 0
    for _ in range(limit):
        await FallingEdge(clk)
        if int(valid.value) == 1:
            got.append(int(data.value))
            ready.value = 1
            if len(got) == n:
                await RisingEdge(clk)
                await Timer(1, unit="ps")
                break
        else:
            ready.value = 0
    ready.value = 0
    return got


async def _pop_t(dut: Any, n: int, limit: int = TIMEOUT) -> list[int]:
    return await _pop(
        dut, dut.i_tx_clk, dut.o_t_valid, dut.o_t_data, dut.i_t_ready, n, limit
    )


async def _pop_c(dut: Any, n: int, limit: int = TIMEOUT) -> list[int]:
    return await _pop(
        dut, dut.i_clk, dut.o_c_valid, dut.o_c_data, dut.i_c_ready, n, limit
    )


@cocotb.test()
async def test_startup_handshake_then_ready(dut: Any) -> None:
    """After the core reset both domains complete a generation and report ready."""
    await _setup(dut)
    assert int(dut.o_busy.value) == 1 or _ready(dut) == (0, 0)
    n = await _wait_for(dut, lambda: _ready(dut) == (1, 1), "both ready")
    assert int(dut.o_busy.value) == 0
    assert int(dut.o_tx_domain_rst.value) == 0 and int(dut.o_rx_domain_rst.value) == 0
    assert int(dut.o_tx_applied.value) == int(dut.o_tx_gen.value)
    assert int(dut.o_rx_applied.value) == int(dut.o_rx_gen.value)
    dut._log.info(f"startup handshake took {n} core cycles")


@cocotb.test()
async def test_reset_drains_then_resets_and_busy_ends_without_acks(dut: Any) -> None:
    """RESET waits for DMA idle, pulses the core reset, and busy clears before the far sides answer."""
    await _setup(dut)
    await _wait_for(dut, lambda: _ready(dut) == (1, 1), "ready")
    dut.i_dma_idle.value = 0
    await FallingEdge(dut.i_clk)
    dut.i_reset_req.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_reset_req.value = 0
    await _core(dut, 20)
    assert int(dut.o_busy.value) == 1 and int(dut.o_stop_dma.value) == 1
    assert int(dut.o_core_rst.value) == 0, "core reset before the drain finished"
    assert _ready(dut) == (1, 1), "domains disturbed before the drain finished"
    dut.i_dma_idle.value = 1
    saw_core_rst = False
    for _ in range(12):
        await FallingEdge(dut.i_clk)
        saw_core_rst |= int(dut.o_core_rst.value) == 1
    assert saw_core_rst, "no core reset pulse"
    await _wait_for(dut, lambda: int(dut.o_busy.value) == 0, "busy clear", 40)
    # The requests are up and the domains are not ready yet (their clocks are
    # slow); busy already cleared.
    assert int(dut.o_tx_req.value) == 1 and int(dut.o_rx_req.value) == 1
    assert _ready(dut) == (0, 0)
    await _wait_for(dut, lambda: _ready(dut) == (1, 1), "ready again")


@cocotb.test()
async def test_absent_clock_does_not_block_reset(dut: Any) -> None:
    """With the RX clock absent, RESET completes; RX stays not ready until the clock returns."""
    clocks = await _setup(dut, tx_clk=True, rx_clk=False)
    await _wait_for(dut, lambda: _ready(dut)[0] == 1, "tx ready")
    assert _ready(dut)[1] == 0
    assert (
        int(dut.o_rx_domain_rst.value) == 1
    ), "an absent-clock domain must sit in reset"
    dut.i_reset_req.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_reset_req.value = 0
    await _wait_for(dut, lambda: int(dut.o_busy.value) == 0, "busy clear", 200)
    await _wait_for(dut, lambda: _ready(dut)[0] == 1, "tx ready again")
    assert _ready(dut)[1] == 0
    assert (
        int(dut.o_rx_req.value) == 1
    ), "the request must stay up while the clock is absent"
    # The clock returns: the far side applies the pending generation.
    clocks.start(rx=True)
    await _core(dut, 4)
    dut.i_rx_clk_ok.value = 1
    await _wait_for(
        dut, lambda: _ready(dut)[1] == 1, "rx ready after the clock returned"
    )
    assert int(dut.o_rx_applied.value) == int(dut.o_rx_gen.value)


@cocotb.test()
async def test_clock_loss_in_operation_restarts_generation(dut: Any) -> None:
    """A clock loss drops ready; when the clock returns a new generation runs before ready."""
    clocks = await _setup(dut)
    await _wait_for(dut, lambda: _ready(dut) == (1, 1), "ready")
    gen_before = int(dut.o_tx_gen.value)
    clocks.stop(tx=True)
    dut.i_tx_clk_ok.value = 0
    await _core(dut, 3)
    assert _ready(dut)[0] == 0
    assert int(dut.o_tx_req.value) == 1 and int(dut.o_tx_gen.value) != gen_before
    assert (
        int(dut.o_tx_domain_rst.value) == 1
    ), "the request must reset the domain without a clock"
    await _core(dut, 50)
    assert _ready(dut)[0] == 0, "ready without a clock"
    clocks.start(tx=True)
    await _core(dut, 4)
    dut.i_tx_clk_ok.value = 1
    await _wait_for(
        dut, lambda: _ready(dut)[0] == 1, "tx ready after the clock returned"
    )
    assert int(dut.o_tx_applied.value) == int(dut.o_tx_gen.value)


@cocotb.test()
async def test_stale_acknowledgement_does_not_satisfy_new_reset(dut: Any) -> None:
    """A second RESET toggles the generation; ready needs the new acknowledgement."""
    await _setup(dut)
    await _wait_for(dut, lambda: _ready(dut) == (1, 1), "ready")
    gen_before = int(dut.o_tx_gen.value)
    dut.i_reset_req.value = 1
    await FallingEdge(dut.i_clk)
    dut.i_reset_req.value = 0
    await _wait_for(dut, lambda: int(dut.o_tx_req.value) == 1, "request up", 40)
    assert int(dut.o_tx_gen.value) != gen_before
    # The far side still reports the old generation for a while: not ready.
    await _core(dut, 2)
    assert int(dut.o_tx_applied.value) == gen_before
    assert _ready(dut)[0] == 0
    await _wait_for(
        dut, lambda: _ready(dut) == (1, 1), "ready after the new generation"
    )
    assert int(dut.o_tx_applied.value) == int(dut.o_tx_gen.value)


@cocotb.test()
async def test_fifo_words_never_survive_reset(dut: Any) -> None:
    """Words left in the core-to-TX FIFO across a RESET do not reappear; the FIFO works after."""
    await _setup(dut)
    await _wait_for(dut, lambda: _ready(dut) == (1, 1), "ready")
    await _push_c2t(dut, [0x100 + i for i in range(8)])
    got = await _pop_t(dut, 3)
    assert got == [0x100, 0x101, 0x102]
    await _reset_and_wait(dut)
    leftover = await _pop_t(dut, 1, limit=60)
    assert leftover == [], f"a word from before the reset reappeared: {leftover}"
    await _push_c2t(dut, [0x200 + i for i in range(5)])
    assert await _pop_t(dut, 5) == [0x200 + i for i in range(5)]


@cocotb.test()
async def test_rx_to_core_fifo_and_counter_across_domain_reset(dut: Any) -> None:
    """RX words and events flow; a domain reset rebases the counter; RESET clears it."""
    clocks = await _setup(dut)
    await _wait_for(dut, lambda: _ready(dut) == (1, 1), "ready")
    # Events and words from the RX domain.
    rng = random.Random(3)
    n_events = 0
    words = [0x300 + i for i in range(6)]
    for w in words:
        await FallingEdge(dut.i_rx_clk)
        dut.i_r_data.value = w
        dut.i_r_valid.value = 1
        dut.i_r_event.value = 1
        n_events += 1
    await FallingEdge(dut.i_rx_clk)
    dut.i_r_valid.value = 0
    dut.i_r_event.value = 0
    for _ in range(rng.randrange(5, 9)):
        await FallingEdge(dut.i_rx_clk)
        dut.i_r_event.value = 1
        n_events += 1
    await FallingEdge(dut.i_rx_clk)
    dut.i_r_event.value = 0
    got = await _pop_c(dut, len(words), limit=400)
    assert got == words
    await _core(dut, 20)
    assert int(dut.o_c_total.value) == n_events
    # Lose and restore the RX clock: the source counter resets, the total holds.
    clocks.stop(rx=True)
    dut.i_rx_clk_ok.value = 0
    await _core(dut, 30)
    clocks.start(rx=True)
    await _core(dut, 4)
    dut.i_rx_clk_ok.value = 1
    await _wait_for(dut, lambda: _ready(dut)[1] == 1, "rx ready")
    await _core(dut, 10)
    assert (
        int(dut.o_c_total.value) == n_events
    ), "the domain reset invented or lost events"
    # More events count on from there; a RESET clears the total.
    for _ in range(4):
        await FallingEdge(dut.i_rx_clk)
        dut.i_r_event.value = 1
    await FallingEdge(dut.i_rx_clk)
    dut.i_r_event.value = 0
    await _core(dut, 20)
    assert int(dut.o_c_total.value) == n_events + 4
    await _reset_and_wait(dut)
    assert int(dut.o_c_total.value) == 0

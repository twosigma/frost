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

"""Unit tests for the IF-stage return address stack.

IF drives one operation per cycle for the packet it hands PD: a push for a
call, a pop for a return, both for a coroutine swap. Misprediction recovery
restores a checkpoint and replays the mispredicted instruction's own operation.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
RAS_DEPTH = 8


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    dut.i_push.value = 0
    dut.i_pop.value = 0
    dut.i_push_address.value = 0
    dut.i_misprediction.value = 0
    dut.i_restore_tos.value = 0
    dut.i_restore_valid_count.value = 0
    dut.i_pop_after_restore.value = 0
    dut.i_push_after_restore.value = 0
    dut.i_push_address_after_restore.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset the RAS, and clear inputs."""
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await _settle()


async def _operate(dut: Any, *, push: bool, pop: bool, address: int = 0) -> None:
    """Apply one operation on the next edge."""
    _clear_inputs(dut)
    dut.i_push.value = int(push)
    dut.i_pop.value = int(pop)
    dut.i_push_address.value = address
    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _settle()


async def _push(dut: Any, address: int) -> None:
    """Push one return address."""
    await _operate(dut, push=True, pop=False, address=address)


async def _pop(dut: Any) -> None:
    """Pop one return address."""
    await _operate(dut, push=False, pop=True)


async def _swap(dut: Any, address: int) -> None:
    """Replace the top entry (a coroutine swap)."""
    await _operate(dut, push=True, pop=True, address=address)


async def _restore(
    dut: Any,
    *,
    tos: int,
    count: int,
    pop: bool = False,
    push: bool = False,
    address: int = 0,
) -> None:
    """Apply a misprediction restore on the next edge."""
    _clear_inputs(dut)
    dut.i_misprediction.value = 1
    dut.i_restore_tos.value = tos
    dut.i_restore_valid_count.value = count
    dut.i_pop_after_restore.value = int(pop)
    dut.i_push_after_restore.value = int(push)
    dut.i_push_address_after_restore.value = address
    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _settle()


def _assert_state(dut: Any, *, tos: int, count: int, top: int | None = None) -> None:
    """Assert the registered state and, for a non-empty stack, the top entry."""
    assert int(dut.o_tos.value) == tos % RAS_DEPTH
    assert int(dut.o_valid_count.value) == count
    assert bool(dut.o_nonempty.value) is (count != 0)
    if top is not None:
        assert int(dut.o_top.value) == top


@cocotb.test()
async def test_reset_leaves_an_empty_stack(dut: Any) -> None:
    """Reset clears the pointer and count."""
    await _setup_test(dut)
    _assert_state(dut, tos=0, count=0)


@cocotb.test()
async def test_push_and_pop_in_lifo_order(dut: Any) -> None:
    """Pushes stack return addresses and pops expose them in LIFO order."""
    await _setup_test(dut)

    await _push(dut, 0x1004)
    _assert_state(dut, tos=1, count=1, top=0x1004)
    await _push(dut, 0x2004)
    _assert_state(dut, tos=2, count=2, top=0x2004)

    await _pop(dut)
    _assert_state(dut, tos=1, count=1, top=0x1004)
    await _pop(dut)
    _assert_state(dut, tos=0, count=0)


@cocotb.test()
async def test_pop_and_swap_on_an_empty_stack_do_nothing(dut: Any) -> None:
    """With nothing to pop, a pop and a swap leave the state as it was."""
    await _setup_test(dut)

    await _pop(dut)
    _assert_state(dut, tos=0, count=0)
    await _swap(dut, 0x3004)
    _assert_state(dut, tos=0, count=0)

    # The swap wrote nothing: a push then exposes only its own entry.
    await _push(dut, 0x3104)
    _assert_state(dut, tos=1, count=1, top=0x3104)


@cocotb.test()
async def test_swap_replaces_the_top_and_keeps_the_depth(dut: Any) -> None:
    """A swap writes the top entry; the entry below and the depth survive."""
    await _setup_test(dut)
    await _push(dut, 0x6004)
    await _push(dut, 0x6104)

    await _swap(dut, 0x7104)
    _assert_state(dut, tos=2, count=2, top=0x7104)

    # A later push goes above the replaced entry, not over it.
    await _push(dut, 0x8104)
    _assert_state(dut, tos=3, count=3, top=0x8104)
    await _pop(dut)
    _assert_state(dut, tos=2, count=2, top=0x7104)
    await _pop(dut)
    _assert_state(dut, tos=1, count=1, top=0x6004)


@cocotb.test()
async def test_push_onto_a_full_stack_overwrites_the_oldest_entry(dut: Any) -> None:
    """The count saturates at the depth and the oldest entry is lost."""
    await _setup_test(dut)
    for i in range(RAS_DEPTH + 1):
        await _push(dut, 0x9000 + 4 * i)
    _assert_state(dut, tos=RAS_DEPTH + 1, count=RAS_DEPTH, top=0x9000 + 4 * RAS_DEPTH)

    # Push 0 was overwritten by push 8, so the pops return pushes 8 down to 1.
    for i in range(RAS_DEPTH, 0, -1):
        _assert_state(dut, tos=i - (RAS_DEPTH - 1), count=i, top=0x9000 + 4 * i)
        await _pop(dut)
    _assert_state(dut, tos=1, count=0)


@cocotb.test()
async def test_restore_discards_speculative_pushes(dut: Any) -> None:
    """A restore returns the stack to an older checkpoint."""
    await _setup_test(dut)
    await _push(dut, 0x8004)
    saved_tos = int(dut.o_tos.value)
    saved_count = int(dut.o_valid_count.value)

    await _push(dut, 0x9004)
    _assert_state(dut, tos=2, count=2)

    await _restore(dut, tos=saved_tos, count=saved_count)
    _assert_state(dut, tos=1, count=1, top=0x8004)


@cocotb.test()
async def test_restore_then_pop_replays_a_return(dut: Any) -> None:
    """Recovery restores a checkpoint and then consumes one entry."""
    await _setup_test(dut)
    await _push(dut, 0xA004)
    await _push(dut, 0xB004)

    await _restore(dut, tos=2, count=2, pop=True)
    _assert_state(dut, tos=1, count=1, top=0xA004)


@cocotb.test()
async def test_restore_then_push_replays_a_call(dut: Any) -> None:
    """Recovery restores a checkpoint and pushes the call's link address."""
    await _setup_test(dut)
    await _restore(dut, tos=0, count=0, push=True, address=0xC004)
    _assert_state(dut, tos=1, count=1, top=0xC004)


@cocotb.test()
async def test_restore_then_swap_replays_a_coroutine(dut: Any) -> None:
    """Both after-restore bits replace the restored top and keep the depth."""
    await _setup_test(dut)
    await _push(dut, 0xA004)
    await _push(dut, 0xB004)

    await _restore(dut, tos=2, count=2, pop=True, push=True, address=0xD004)
    # Treating the pair as a plain push would leave the pointer and count at 3.
    _assert_state(dut, tos=2, count=2, top=0xD004)
    await _pop(dut)
    _assert_state(dut, tos=1, count=1, top=0xA004)


@cocotb.test()
async def test_restore_swap_on_an_empty_stack_changes_nothing(dut: Any) -> None:
    """With nothing to pop, the front end performs neither half, so recovery matches."""
    await _setup_test(dut)
    await _restore(dut, tos=0, count=0, pop=True, push=True, address=0xE004)
    _assert_state(dut, tos=0, count=0)


@cocotb.test()
async def test_restore_takes_priority_over_an_operation(dut: Any) -> None:
    """An operation in the restore cycle is dropped."""
    await _setup_test(dut)
    await _push(dut, 0xF004)

    _clear_inputs(dut)
    dut.i_misprediction.value = 1
    dut.i_restore_tos.value = 1
    dut.i_restore_valid_count.value = 1
    dut.i_push.value = 1
    dut.i_push_address.value = 0xF104
    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _settle()

    _assert_state(dut, tos=1, count=1, top=0xF004)

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

"""Unit tests for the FU CDB Adapter.

Tests the holding register, combinational pass-through, back-pressure,
flush behavior, and constrained-random stress scenarios.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from .fu_cdb_adapter_interface import FuCdbAdapterInterface, MASK64, MASK_TAG
from .fu_cdb_adapter_model import FuCdbAdapterModel, FuComplete

CLOCK_PERIOD_NS = 10


async def setup(dut: Any) -> tuple[FuCdbAdapterInterface, FuCdbAdapterModel]:
    """Start clock, reset DUT, and return interface and model."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut_if = FuCdbAdapterInterface(dut)
    model = FuCdbAdapterModel()
    await dut_if.reset_dut()
    return dut_if, model


def assert_output_match(
    dut_if: FuCdbAdapterInterface,
    model: FuCdbAdapterModel,
    fu_result: FuComplete,
    context: str = "",
) -> None:
    """Assert DUT output matches model for given input."""
    prefix = f"[{context}] " if context else ""
    expected = model.get_output(fu_result)
    dut_out = dut_if.read_fu_complete()
    dut_pending = dut_if.read_result_pending()

    assert (
        dut_out.valid == expected.fu_complete.valid
    ), f"{prefix}valid: DUT={dut_out.valid} model={expected.fu_complete.valid}"
    if expected.fu_complete.valid:
        assert (
            dut_out.tag == expected.fu_complete.tag
        ), f"{prefix}tag: DUT={dut_out.tag} model={expected.fu_complete.tag}"
        assert (
            dut_out.value == expected.fu_complete.value
        ), f"{prefix}value: DUT=0x{dut_out.value:x} model=0x{expected.fu_complete.value:x}"
        assert (
            dut_out.exception == expected.fu_complete.exception
        ), f"{prefix}exception: DUT={dut_out.exception} model={expected.fu_complete.exception}"
        assert (
            dut_out.exc_cause == expected.fu_complete.exc_cause
        ), f"{prefix}exc_cause: DUT={dut_out.exc_cause} model={expected.fu_complete.exc_cause}"
        assert (
            dut_out.fp_flags == expected.fu_complete.fp_flags
        ), f"{prefix}fp_flags: DUT={dut_out.fp_flags} model={expected.fu_complete.fp_flags}"
    assert (
        dut_pending == expected.result_pending
    ), f"{prefix}result_pending: DUT={dut_pending} model={expected.result_pending}"


# ============================================================================
# Test 1: After reset, output invalid and not pending
# ============================================================================
@cocotb.test()
async def test_reset_idle(dut: Any) -> None:
    """After reset: o_fu_complete.valid=0, o_result_pending=0."""
    dut_if, model = await setup(dut)

    await Timer(1, unit="ns")
    no_input = FuComplete()
    assert_output_match(dut_if, model, no_input, "reset")


# ============================================================================
# Test 2: Input valid, no grant -> output valid (pass-through), then pending
# ============================================================================
@cocotb.test()
async def test_passthrough_no_grant(dut: Any) -> None:
    """Input valid, no grant -> output valid (pass-through), then pending next cycle."""
    dut_if, model = await setup(dut)

    fu_result = FuComplete(valid=True, tag=5, value=0xDEAD_BEEF)
    dut_if.drive_fu_result(tag=5, value=0xDEAD_BEEF)
    await Timer(1, unit="ns")

    # Combinational pass-through (same cycle)
    assert_output_match(dut_if, model, fu_result, "pass-through")

    # Clock edge: not granted, should latch
    model.step(fu_result, grant=False, flush=False)
    await dut_if.step()

    # Now result should be pending
    assert dut_if.read_result_pending(), "Should be pending after no grant"
    assert_output_match(dut_if, model, fu_result, "pending")


# ============================================================================
# Test 3: Input valid + grant same cycle -> no pending (zero latency)
# ============================================================================
@cocotb.test()
async def test_passthrough_with_grant(dut: Any) -> None:
    """Input valid + grant same cycle -> output valid, no pending next cycle."""
    dut_if, model = await setup(dut)

    fu_result = FuComplete(valid=True, tag=7, value=0xCAFE)
    dut_if.drive_fu_result(tag=7, value=0xCAFE)
    dut_if.drive_grant()
    await Timer(1, unit="ns")

    # Pass-through should be valid
    assert_output_match(dut_if, model, fu_result, "pass-through-granted")

    # Clock: granted same cycle, stay idle
    model.step(fu_result, grant=True, flush=False)
    await dut_if.step()

    # Clear inputs
    dut_if.clear_fu_result()
    dut_if.clear_grant()
    await Timer(1, unit="ns")

    no_input = FuComplete()
    assert not dut_if.read_result_pending(), "Should not be pending after grant"
    assert_output_match(dut_if, model, no_input, "after-grant")


# ============================================================================
# Test 4: Tag correct in both pass-through and pending states
# ============================================================================
@cocotb.test()
async def test_tag_propagation(dut: Any) -> None:
    """Tag correct in both pass-through and pending states."""
    dut_if, model = await setup(dut)

    for tag in [0, 1, 15, 16, 31]:
        model.reset()
        await dut_if.reset_dut()

        fu_result = FuComplete(valid=True, tag=tag, value=tag * 100)
        dut_if.drive_fu_result(tag=tag, value=tag * 100)
        await Timer(1, unit="ns")

        # Pass-through check
        dut_out = dut_if.read_fu_complete()
        assert dut_out.tag == tag, f"pass-through tag: DUT={dut_out.tag} expected={tag}"

        # Latch and check pending
        model.step(fu_result, grant=False, flush=False)
        await dut_if.step()

        dut_out = dut_if.read_fu_complete()
        assert dut_out.tag == tag, f"pending tag: DUT={dut_out.tag} expected={tag}"


# ============================================================================
# Test 5: 64-bit FLEN value correctly forwarded/latched
# ============================================================================
@cocotb.test()
async def test_value_propagation(dut: Any) -> None:
    """64-bit FLEN value correctly forwarded/latched."""
    dut_if, model = await setup(dut)

    test_values = [
        0x0000_0000_0000_0000,
        0xFFFF_FFFF_FFFF_FFFF,
        0xDEAD_BEEF_CAFE_BABE,
        0x8000_0000_0000_0001,
        0x0000_0000_0000_0001,
    ]

    for val in test_values:
        model.reset()
        await dut_if.reset_dut()

        fu_result = FuComplete(valid=True, tag=10, value=val)
        dut_if.drive_fu_result(tag=10, value=val)
        await Timer(1, unit="ns")

        # Pass-through
        dut_out = dut_if.read_fu_complete()
        assert (
            dut_out.value == val
        ), f"pass-through: DUT=0x{dut_out.value:016x} expected=0x{val:016x}"

        # Latch
        model.step(fu_result, grant=False, flush=False)
        await dut_if.step()

        dut_out = dut_if.read_fu_complete()
        assert (
            dut_out.value == val
        ), f"pending: DUT=0x{dut_out.value:016x} expected=0x{val:016x}"


# ============================================================================
# Test 6: Exception + exc_cause forwarded correctly
# ============================================================================
@cocotb.test()
async def test_exception_propagation(dut: Any) -> None:
    """Exception + exc_cause forwarded correctly."""
    dut_if, model = await setup(dut)

    fu_result = FuComplete(valid=True, tag=20, value=0, exception=True, exc_cause=0x0B)
    dut_if.drive_fu_result(tag=20, value=0, exception=True, exc_cause=0x0B)
    await Timer(1, unit="ns")

    dut_out = dut_if.read_fu_complete()
    assert dut_out.exception is True
    assert dut_out.exc_cause == 0x0B

    # Latch and check
    model.step(fu_result, grant=False, flush=False)
    await dut_if.step()

    dut_out = dut_if.read_fu_complete()
    assert dut_out.exception is True
    assert dut_out.exc_cause == 0x0B


# ============================================================================
# Test 7: FP flags (5-bit) forwarded correctly
# ============================================================================
@cocotb.test()
async def test_fp_flags_propagation(dut: Any) -> None:
    """FP flags (5-bit) forwarded correctly."""
    dut_if, model = await setup(dut)

    for flag_bit in range(5):
        model.reset()
        await dut_if.reset_dut()

        fp_flags = 1 << flag_bit
        fu_result = FuComplete(valid=True, tag=15, value=42, fp_flags=fp_flags)
        dut_if.drive_fu_result(tag=15, value=42, fp_flags=fp_flags)
        await Timer(1, unit="ns")

        dut_out = dut_if.read_fu_complete()
        assert (
            dut_out.fp_flags == fp_flags
        ), f"bit {flag_bit}: DUT=0x{dut_out.fp_flags:02x} expected=0x{fp_flags:02x}"

        # Latch and check
        model.step(fu_result, grant=False, flush=False)
        await dut_if.step()

        dut_out = dut_if.read_fu_complete()
        assert (
            dut_out.fp_flags == fp_flags
        ), f"pending bit {flag_bit}: DUT=0x{dut_out.fp_flags:02x} expected=0x{fp_flags:02x}"

    # All flags set
    model.reset()
    await dut_if.reset_dut()
    fu_result = FuComplete(valid=True, tag=16, value=99, fp_flags=0x1F)
    dut_if.drive_fu_result(tag=16, value=99, fp_flags=0x1F)
    await Timer(1, unit="ns")

    dut_out = dut_if.read_fu_complete()
    assert dut_out.fp_flags == 0x1F


# ============================================================================
# Test 8: Grant clears pending state
# ============================================================================
@cocotb.test()
async def test_grant_clears_pending(dut: Any) -> None:
    """After grant while pending: result_pending=0, output invalid next cycle."""
    dut_if, model = await setup(dut)

    # Drive result, don't grant -> pending
    fu_result = FuComplete(valid=True, tag=3, value=0x1234)
    dut_if.drive_fu_result(tag=3, value=0x1234)
    model.step(fu_result, grant=False, flush=False)
    await dut_if.step()

    assert dut_if.read_result_pending()

    # Clear input, grant -> should clear pending
    dut_if.clear_fu_result()
    dut_if.drive_grant()
    no_input = FuComplete()
    model.step(no_input, grant=True, flush=False)
    await dut_if.step()

    dut_if.clear_grant()
    await Timer(1, unit="ns")

    assert not dut_if.read_result_pending(), "Should not be pending after grant"
    assert_output_match(dut_if, model, no_input, "after-grant-clear")


# ============================================================================
# Test 9: Held result stable while pending (no grant)
# ============================================================================
@cocotb.test()
async def test_result_stable_while_pending(dut: Any) -> None:
    """Without grant, held result doesn't change over multiple cycles."""
    dut_if, model = await setup(dut)

    fu_result = FuComplete(valid=True, tag=9, value=0xBEEF_CAFE)
    dut_if.drive_fu_result(tag=9, value=0xBEEF_CAFE)
    model.step(fu_result, grant=False, flush=False)
    await dut_if.step()

    assert dut_if.read_result_pending()
    first_out = dut_if.read_fu_complete()

    # Hold for several cycles without grant
    for cycle in range(5):
        model.step(fu_result, grant=False, flush=False)
        await dut_if.step()

        dut_out = dut_if.read_fu_complete()
        assert dut_out.tag == first_out.tag, f"cycle {cycle}: tag changed"
        assert dut_out.value == first_out.value, f"cycle {cycle}: value changed"
        assert dut_if.read_result_pending(), f"cycle {cycle}: no longer pending"


# ============================================================================
# Test 10: Back-to-back: grant + new input while pending
# ============================================================================
@cocotb.test()
async def test_back_to_back(dut: Any) -> None:
    """Grant + new input valid while pending -> stays pending with new result."""
    dut_if, model = await setup(dut)

    # First result, not granted -> pending
    fu_result_1 = FuComplete(valid=True, tag=1, value=0xAAAA)
    dut_if.drive_fu_result(tag=1, value=0xAAAA)
    model.step(fu_result_1, grant=False, flush=False)
    await dut_if.step()
    assert dut_if.read_result_pending()

    # Grant + new result simultaneously
    fu_result_2 = FuComplete(valid=True, tag=2, value=0xBBBB)
    dut_if.drive_fu_result(tag=2, value=0xBBBB)
    dut_if.drive_grant()
    model.step(fu_result_2, grant=True, flush=False)
    await dut_if.step()

    dut_if.clear_grant()
    await Timer(1, unit="ns")

    # Should still be pending with the new result
    assert dut_if.read_result_pending(), "Should remain pending with new result"
    dut_out = dut_if.read_fu_complete()
    assert dut_out.tag == 2, f"Should hold new tag=2, got {dut_out.tag}"
    assert (
        dut_out.value == 0xBBBB
    ), f"Should hold new value=0xBBBB, got 0x{dut_out.value:x}"


# ============================================================================
# Test 11: Flush clears pending result
# ============================================================================
@cocotb.test()
async def test_flush_clears_pending(dut: Any) -> None:
    """i_flush while pending -> clears, becomes idle."""
    dut_if, model = await setup(dut)

    # Make pending
    fu_result = FuComplete(valid=True, tag=11, value=0xF1F2)
    dut_if.drive_fu_result(tag=11, value=0xF1F2)
    model.step(fu_result, grant=False, flush=False)
    await dut_if.step()
    assert dut_if.read_result_pending()

    # Flush
    dut_if.clear_fu_result()
    dut_if.drive_flush()
    no_input = FuComplete()
    model.step(no_input, grant=False, flush=True)
    await dut_if.step()

    dut_if.clear_flush()
    await Timer(1, unit="ns")

    assert not dut_if.read_result_pending(), "Should not be pending after flush"
    assert not dut_if.read_fu_complete().valid, "Output should be invalid after flush"


# ============================================================================
# Test 12: Flush during idle has no effect
# ============================================================================
@cocotb.test()
async def test_flush_during_idle(dut: Any) -> None:
    """i_flush while idle -> stays idle (no effect)."""
    dut_if, model = await setup(dut)

    dut_if.drive_flush()
    no_input = FuComplete()
    model.step(no_input, grant=False, flush=True)
    await dut_if.step()

    dut_if.clear_flush()
    await Timer(1, unit="ns")

    assert not dut_if.read_result_pending()
    assert not dut_if.read_fu_complete().valid


# ============================================================================
# Test 13: Multi-cycle contention (pending for 3 cycles, then granted)
# ============================================================================
@cocotb.test()
async def test_multi_cycle_contention(dut: Any) -> None:
    """Result pending for 3 cycles (no grant), then granted."""
    dut_if, model = await setup(dut)

    fu_result = FuComplete(valid=True, tag=13, value=0xC0FFEE)
    dut_if.drive_fu_result(tag=13, value=0xC0FFEE)

    # Cycle 1: latch (not granted)
    model.step(fu_result, grant=False, flush=False)
    await dut_if.step()
    assert dut_if.read_result_pending()

    # Cycles 2-3: still pending
    for _ in range(2):
        model.step(fu_result, grant=False, flush=False)
        await dut_if.step()
        assert dut_if.read_result_pending()

    # Cycle 4: grant
    dut_if.clear_fu_result()
    dut_if.drive_grant()
    no_input = FuComplete()
    model.step(no_input, grant=True, flush=False)
    await dut_if.step()

    dut_if.clear_grant()
    await Timer(1, unit="ns")

    assert not dut_if.read_result_pending(), "Should clear after grant"


# ============================================================================
# Test 14: o_result_pending mirrors internal state
# ============================================================================
@cocotb.test()
async def test_result_pending_output(dut: Any) -> None:
    """o_result_pending mirrors internal result_pending state."""
    dut_if, model = await setup(dut)

    # Initially not pending
    assert not dut_if.read_result_pending()

    # Drive result, don't grant -> pending after edge
    fu_result = FuComplete(valid=True, tag=14, value=0x99)
    dut_if.drive_fu_result(tag=14, value=0x99)
    model.step(fu_result, grant=False, flush=False)
    await dut_if.step()

    assert dut_if.read_result_pending()

    # Grant -> not pending
    dut_if.clear_fu_result()
    dut_if.drive_grant()
    no_input = FuComplete()
    model.step(no_input, grant=True, flush=False)
    await dut_if.step()

    dut_if.clear_grant()
    await Timer(1, unit="ns")
    assert not dut_if.read_result_pending()


# ============================================================================
# Test 15: New input valid while pending (no grant) -> output shows held result
# ============================================================================
@cocotb.test()
async def test_input_ignored_while_pending(dut: Any) -> None:
    """New input valid while pending (no grant) -> output still shows held result."""
    dut_if, model = await setup(dut)

    # First result latched
    fu_result_1 = FuComplete(valid=True, tag=1, value=0x1111)
    dut_if.drive_fu_result(tag=1, value=0x1111)
    model.step(fu_result_1, grant=False, flush=False)
    await dut_if.step()
    assert dut_if.read_result_pending()

    # New input arrives while pending (no grant)
    dut_if.drive_fu_result(tag=2, value=0x2222)
    await Timer(1, unit="ns")

    # Output should still be the held result (tag=1), not the new input
    dut_out = dut_if.read_fu_complete()
    assert dut_out.tag == 1, f"Should still show held tag=1, got {dut_out.tag}"
    assert (
        dut_out.value == 0x1111
    ), f"Should still show held value, got 0x{dut_out.value:x}"


# ============================================================================
# Test 16: Random stress test — model match every cycle
# ============================================================================
@cocotb.test()
async def test_random_stress(dut: Any) -> None:
    """Random sequences of input/grant/flush, verify model match each cycle."""
    dut_if, model = await setup(dut)

    rng = random.Random(cocotb.RANDOM_SEED)
    num_cycles = 300

    for cycle in range(num_cycles):
        # Random FU result (~60% chance of valid)
        if rng.random() < 0.6:
            fu_result = FuComplete(
                valid=True,
                tag=rng.randint(0, MASK_TAG),
                value=rng.randint(0, MASK64),
                exception=rng.random() < 0.1,
                exc_cause=rng.randint(0, 0x1F),
                fp_flags=rng.randint(0, 0x1F),
            )
            dut_if.drive_fu_result(
                tag=fu_result.tag,
                value=fu_result.value,
                exception=fu_result.exception,
                exc_cause=fu_result.exc_cause,
                fp_flags=fu_result.fp_flags,
            )
        else:
            fu_result = FuComplete()
            dut_if.clear_fu_result()

        # Random grant (~40% when there's something to grant)
        grant = False
        if rng.random() < 0.4 and (model.result_pending or fu_result.valid):
            grant = True
            dut_if.drive_grant()
        else:
            dut_if.clear_grant()

        # Random flush (~5%)
        flush = rng.random() < 0.05
        if flush:
            dut_if.drive_flush()
        else:
            dut_if.clear_flush()

        # Check combinational output before clock edge
        await Timer(1, unit="ns")
        assert_output_match(dut_if, model, fu_result, f"cycle {cycle} pre-edge")

        # Advance clock
        model.step(fu_result, grant=grant, flush=flush)
        await dut_if.step()

    cocotb.log.info(f"=== Random stress test passed ({num_cycles} cycles) ===")

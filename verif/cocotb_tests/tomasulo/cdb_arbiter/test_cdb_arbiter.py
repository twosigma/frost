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

"""Unit tests for the CDB Arbiter.

Tests priority arbitration, grant exclusivity, data propagation, and
constrained-random stress scenarios.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from .cdb_arbiter_interface import CdbArbiterInterface
from .cdb_arbiter_model import (
    CdbArbiterModel,
    CdbBroadcast,
    FuComplete,
    NUM_FUS,
    FU_ALU,
    FU_MUL,
    FU_DIV,
    FU_MEM,
    FU_FP_ADD,
    FU_FP_MUL,
    FU_FP_DIV,
    PRIORITY_ORDER,
    MASK64,
)

CLOCK_PERIOD_NS = 10


async def setup(dut: Any) -> tuple[CdbArbiterInterface, CdbArbiterModel]:
    """Start clock, reset DUT, and return interface and model."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut_if = CdbArbiterInterface(dut)
    model = CdbArbiterModel()
    await dut_if.reset_dut()
    return dut_if, model


def make_fu_completes(specs: dict[int, dict] | None = None) -> list[FuComplete]:
    """Create a list of NUM_FUS FuComplete with given specs.

    specs: dict mapping fu_index -> kwargs for FuComplete (valid defaults True).
    """
    reqs = [FuComplete() for _ in range(NUM_FUS)]
    if specs:
        for fu_idx, kwargs in specs.items():
            kwargs.setdefault("valid", True)
            reqs[fu_idx] = FuComplete(**kwargs)
    return reqs


def drive_and_check(
    dut_if: CdbArbiterInterface,
    model: CdbArbiterModel,
    fu_completes: list[FuComplete],
) -> tuple[CdbBroadcast, list[bool]]:
    """Drive FU completes to DUT, run model, return (model_cdb, model_grants)."""
    from .cdb_arbiter_interface import pack_fu_complete

    for i, req in enumerate(fu_completes):
        dut_if._get_fu_signal(i).value = pack_fu_complete(req)

    model_cdb, model_grants = model.arbitrate(fu_completes)
    return model_cdb, model_grants


def assert_cdb_match(
    dut_cdb: CdbBroadcast, model_cdb: CdbBroadcast, context: str = ""
) -> None:
    """Assert DUT CDB output matches model."""
    prefix = f"[{context}] " if context else ""
    assert (
        dut_cdb.valid == model_cdb.valid
    ), f"{prefix}valid: DUT={dut_cdb.valid} model={model_cdb.valid}"
    if not model_cdb.valid:
        return
    assert (
        dut_cdb.tag == model_cdb.tag
    ), f"{prefix}tag: DUT={dut_cdb.tag} model={model_cdb.tag}"
    assert (
        dut_cdb.value == model_cdb.value
    ), f"{prefix}value: DUT=0x{dut_cdb.value:x} model=0x{model_cdb.value:x}"
    assert (
        dut_cdb.exception == model_cdb.exception
    ), f"{prefix}exception: DUT={dut_cdb.exception} model={model_cdb.exception}"
    assert (
        dut_cdb.exc_cause == model_cdb.exc_cause
    ), f"{prefix}exc_cause: DUT={dut_cdb.exc_cause} model={model_cdb.exc_cause}"
    assert (
        dut_cdb.fp_flags == model_cdb.fp_flags
    ), f"{prefix}fp_flags: DUT={dut_cdb.fp_flags} model={model_cdb.fp_flags}"
    assert (
        dut_cdb.fu_type == model_cdb.fu_type
    ), f"{prefix}fu_type: DUT={dut_cdb.fu_type} model={model_cdb.fu_type}"


def assert_grants_match(
    dut_grants: list[bool], model_grants: list[bool], context: str = ""
) -> None:
    """Assert DUT grant vector matches model."""
    prefix = f"[{context}] " if context else ""
    assert (
        dut_grants == model_grants
    ), f"{prefix}grants: DUT={dut_grants} model={model_grants}"


# ============================================================================
# Test 1: No FU valid → CDB output invalid, all grants 0
# ============================================================================
@cocotb.test()
async def test_reset_no_output(dut: Any) -> None:
    """No FU valid → CDB output invalid, all grants 0."""
    dut_if, model = await setup(dut)

    # All FU completes already cleared by reset
    await Timer(1, unit="ns")  # Let combinational logic settle

    cdb = dut_if.read_cdb_output()
    grants = dut_if.read_grant()

    assert not cdb.valid, "CDB should be invalid when no FU is valid"
    assert grants == [False] * NUM_FUS, f"All grants should be 0, got {grants}"


# ============================================================================
# Test 2: Only ALU valid → ALU result broadcast, ALU granted
# ============================================================================
@cocotb.test()
async def test_single_fu_alu(dut: Any) -> None:
    """Only ALU valid → ALU result broadcast, ALU granted."""
    dut_if, model = await setup(dut)

    fu_completes = make_fu_completes(
        {
            FU_ALU: {"tag": 5, "value": 0xDEADBEEF},
        }
    )
    model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    dut_grants = dut_if.read_grant()

    assert_cdb_match(dut_cdb, model_cdb, "single_alu")
    assert_grants_match(dut_grants, model_grants, "single_alu")
    assert dut_cdb.fu_type == FU_ALU


# ============================================================================
# Test 3: Each FU type alone → correct broadcast and fu_type
# ============================================================================
@cocotb.test()
async def test_single_fu_each(dut: Any) -> None:
    """Each FU type alone → correct broadcast and fu_type."""
    dut_if, model = await setup(dut)

    fu_names = {
        FU_ALU: "ALU",
        FU_MUL: "MUL",
        FU_DIV: "DIV",
        FU_MEM: "MEM",
        FU_FP_ADD: "FP_ADD",
        FU_FP_MUL: "FP_MUL",
        FU_FP_DIV: "FP_DIV",
    }

    for fu_idx, name in fu_names.items():
        tag = fu_idx + 1
        value = (fu_idx + 1) * 0x1111_1111_1111_1111 & MASK64

        fu_completes = make_fu_completes(
            {
                fu_idx: {"tag": tag, "value": value},
            }
        )
        model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)
        await Timer(1, unit="ns")

        dut_cdb = dut_if.read_cdb_output()
        dut_grants = dut_if.read_grant()

        assert_cdb_match(dut_cdb, model_cdb, f"single_{name}")
        assert_grants_match(dut_grants, model_grants, f"single_{name}")
        assert (
            dut_cdb.fu_type == fu_idx
        ), f"{name}: fu_type={dut_cdb.fu_type} expected={fu_idx}"

        # Clear for next iteration
        dut_if.clear_all_fu_completes()
        await Timer(1, unit="ns")


# ============================================================================
# Test 4: FP_DIV + ALU → FP_DIV wins
# ============================================================================
@cocotb.test()
async def test_priority_fp_div_over_alu(dut: Any) -> None:
    """FP_DIV + ALU → FP_DIV wins."""
    dut_if, model = await setup(dut)

    fu_completes = make_fu_completes(
        {
            FU_ALU: {"tag": 1, "value": 0xAAAA},
            FU_FP_DIV: {"tag": 2, "value": 0xBBBB},
        }
    )
    model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    dut_grants = dut_if.read_grant()

    assert_cdb_match(dut_cdb, model_cdb, "fp_div_over_alu")
    assert dut_cdb.fu_type == FU_FP_DIV
    assert dut_cdb.tag == 2
    assert dut_grants[FU_ALU] is False
    assert dut_grants[FU_FP_DIV] is True


# ============================================================================
# Test 5: DIV + MUL → DIV wins
# ============================================================================
@cocotb.test()
async def test_priority_div_over_mul(dut: Any) -> None:
    """DIV + MUL → DIV wins."""
    dut_if, model = await setup(dut)

    fu_completes = make_fu_completes(
        {
            FU_MUL: {"tag": 3, "value": 0x3333},
            FU_DIV: {"tag": 4, "value": 0x4444},
        }
    )
    model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    dut_grants = dut_if.read_grant()

    assert_cdb_match(dut_cdb, model_cdb, "div_over_mul")
    assert dut_cdb.fu_type == FU_DIV
    assert dut_grants[FU_DIV] is True
    assert dut_grants[FU_MUL] is False


# ============================================================================
# Test 6: All 7 FUs valid → FP_DIV wins (highest priority)
# ============================================================================
@cocotb.test()
async def test_priority_all_valid(dut: Any) -> None:
    """All 7 FUs valid → FP_DIV wins (highest priority)."""
    dut_if, model = await setup(dut)

    specs = {}
    for fu_idx in range(NUM_FUS):
        specs[fu_idx] = {"tag": fu_idx, "value": (fu_idx + 1) * 0x100}

    fu_completes = make_fu_completes(specs)
    model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    dut_grants = dut_if.read_grant()

    assert_cdb_match(dut_cdb, model_cdb, "all_valid")
    assert dut_cdb.fu_type == FU_FP_DIV
    assert dut_grants[FU_FP_DIV] is True
    # All others should be denied
    for i in range(NUM_FUS):
        if i != FU_FP_DIV:
            assert dut_grants[i] is False, f"FU {i} should not be granted"


# ============================================================================
# Test 7: All except FP_DIV → DIV wins
# ============================================================================
@cocotb.test()
async def test_priority_all_except_highest(dut: Any) -> None:
    """All except FP_DIV → DIV wins."""
    dut_if, model = await setup(dut)

    specs = {}
    for fu_idx in range(NUM_FUS):
        if fu_idx != FU_FP_DIV:
            specs[fu_idx] = {"tag": fu_idx + 10, "value": fu_idx * 0x1000}

    fu_completes = make_fu_completes(specs)
    model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    dut_grants = dut_if.read_grant()

    assert_cdb_match(dut_cdb, model_cdb, "all_except_highest")
    assert dut_cdb.fu_type == FU_DIV
    assert dut_grants[FU_DIV] is True


# ============================================================================
# Test 8: Exactly one grant bit set when any FU valid
# ============================================================================
@cocotb.test()
async def test_grant_exclusivity(dut: Any) -> None:
    """Exactly one grant bit set when any FU valid."""
    dut_if, model = await setup(dut)

    # Try several combinations
    combos = [
        {FU_ALU: {"tag": 1, "value": 1}},
        {FU_MUL: {"tag": 2, "value": 2}, FU_DIV: {"tag": 3, "value": 3}},
        {
            FU_FP_ADD: {"tag": 4, "value": 4},
            FU_FP_MUL: {"tag": 5, "value": 5},
            FU_FP_DIV: {"tag": 6, "value": 6},
        },
        {FU_ALU: {"tag": 7, "value": 7}, FU_MEM: {"tag": 8, "value": 8}},
    ]

    for i, specs in enumerate(combos):
        fu_completes = make_fu_completes(specs)
        model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)
        await Timer(1, unit="ns")

        grant_raw = dut_if.read_grant_raw()
        # Exactly one bit set
        assert grant_raw != 0, f"combo {i}: grant should not be zero"
        assert (
            grant_raw & (grant_raw - 1)
        ) == 0, f"combo {i}: grant=0b{grant_raw:07b} not onehot"

        dut_if.clear_all_fu_completes()
        await Timer(1, unit="ns")


# ============================================================================
# Test 9: FLEN-wide (64-bit) value correctly forwarded
# ============================================================================
@cocotb.test()
async def test_value_propagation(dut: Any) -> None:
    """FLEN-wide (64-bit) value correctly forwarded."""
    dut_if, model = await setup(dut)

    test_values = [
        0x0000_0000_0000_0000,
        0xFFFF_FFFF_FFFF_FFFF,
        0xDEAD_BEEF_CAFE_BABE,
        0x8000_0000_0000_0001,
        0x0000_0000_0000_0001,
    ]

    for val in test_values:
        fu_completes = make_fu_completes(
            {
                FU_MEM: {"tag": 10, "value": val},
            }
        )
        model_cdb, _ = drive_and_check(dut_if, model, fu_completes)
        await Timer(1, unit="ns")

        dut_cdb = dut_if.read_cdb_output()
        assert (
            dut_cdb.value == val
        ), f"value: DUT=0x{dut_cdb.value:016x} expected=0x{val:016x}"

        dut_if.clear_all_fu_completes()
        await Timer(1, unit="ns")


# ============================================================================
# Test 10: FP flags (nv/dz/of/uf/nx) forwarded from winning FU
# ============================================================================
@cocotb.test()
async def test_fp_flags_propagation(dut: Any) -> None:
    """FP flags (nv/dz/of/uf/nx) forwarded from winning FU."""
    dut_if, model = await setup(dut)

    # Test each individual flag bit
    for flag_bit in range(5):
        fp_flags = 1 << flag_bit
        fu_completes = make_fu_completes(
            {
                FU_FP_ADD: {"tag": 15, "value": 42, "fp_flags": fp_flags},
            }
        )
        model_cdb, _ = drive_and_check(dut_if, model, fu_completes)
        await Timer(1, unit="ns")

        dut_cdb = dut_if.read_cdb_output()
        assert (
            dut_cdb.fp_flags == fp_flags
        ), f"flag bit {flag_bit}: DUT=0x{dut_cdb.fp_flags:02x} expected=0x{fp_flags:02x}"

        dut_if.clear_all_fu_completes()
        await Timer(1, unit="ns")

    # Test all flags set
    fu_completes = make_fu_completes(
        {
            FU_FP_MUL: {"tag": 16, "value": 99, "fp_flags": 0x1F},
        }
    )
    model_cdb, _ = drive_and_check(dut_if, model, fu_completes)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    assert dut_cdb.fp_flags == 0x1F


# ============================================================================
# Test 11: Exception + cause forwarded correctly
# ============================================================================
@cocotb.test()
async def test_exception_propagation(dut: Any) -> None:
    """Exception + cause forwarded correctly."""
    dut_if, model = await setup(dut)

    # Exception with cause
    fu_completes = make_fu_completes(
        {
            FU_DIV: {"tag": 20, "value": 0, "exception": True, "exc_cause": 0x0B},
        }
    )
    model_cdb, _ = drive_and_check(dut_if, model, fu_completes)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    assert dut_cdb.exception is True
    assert dut_cdb.exc_cause == 0x0B

    # No exception
    dut_if.clear_all_fu_completes()
    fu_completes = make_fu_completes(
        {
            FU_ALU: {"tag": 21, "value": 100, "exception": False, "exc_cause": 0},
        }
    )
    model_cdb, _ = drive_and_check(dut_if, model, fu_completes)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    assert dut_cdb.exception is False
    assert dut_cdb.exc_cause == 0


# ============================================================================
# Test 12: ROB tag forwarded correctly
# ============================================================================
@cocotb.test()
async def test_tag_propagation(dut: Any) -> None:
    """ROB tag forwarded correctly."""
    dut_if, model = await setup(dut)

    for tag in [0, 1, 15, 16, 31]:
        fu_completes = make_fu_completes(
            {
                FU_MUL: {"tag": tag, "value": tag * 100},
            }
        )
        model_cdb, _ = drive_and_check(dut_if, model, fu_completes)
        await Timer(1, unit="ns")

        dut_cdb = dut_if.read_cdb_output()
        assert dut_cdb.tag == tag, f"tag: DUT={dut_cdb.tag} expected={tag}"

        dut_if.clear_all_fu_completes()
        await Timer(1, unit="ns")


# ============================================================================
# Test 13: o_cdb.fu_type matches the granted FU
# ============================================================================
@cocotb.test()
async def test_fu_type_field(dut: Any) -> None:
    """o_cdb.fu_type matches the granted FU."""
    dut_if, model = await setup(dut)

    for fu_idx in range(NUM_FUS):
        fu_completes = make_fu_completes(
            {
                fu_idx: {"tag": fu_idx, "value": fu_idx},
            }
        )
        model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)
        await Timer(1, unit="ns")

        dut_cdb = dut_if.read_cdb_output()
        dut_grants = dut_if.read_grant()

        assert dut_cdb.fu_type == fu_idx, f"FU {fu_idx}: fu_type={dut_cdb.fu_type}"
        assert dut_grants[fu_idx] is True

        dut_if.clear_all_fu_completes()
        await Timer(1, unit="ns")


# ============================================================================
# Test 14: Different FUs win across consecutive cycles
# ============================================================================
@cocotb.test()
async def test_sequential_different_fus(dut: Any) -> None:
    """Different FUs win across consecutive cycles."""
    dut_if, model = await setup(dut)

    # Cycle through FU types: each cycle, a different single FU is valid
    for cycle, fu_idx in enumerate(PRIORITY_ORDER):
        dut_if.clear_all_fu_completes()
        dut_if.drive_fu_complete(fu_idx, tag=cycle, value=cycle * 0x1000)
        await dut_if.step()

        # Read after clock edge (combinational settles)
        await Timer(1, unit="ns")
        dut_cdb = dut_if.read_cdb_output()
        assert dut_cdb.valid, f"cycle {cycle}: CDB should be valid"
        assert (
            dut_cdb.fu_type == fu_idx
        ), f"cycle {cycle}: fu_type={dut_cdb.fu_type} expected={fu_idx}"
        assert dut_cdb.tag == cycle


# ============================================================================
# Test 15: FU that lost arbitration: grant=0, must re-present next cycle
# ============================================================================
@cocotb.test()
async def test_loser_must_retry(dut: Any) -> None:
    """FU that lost arbitration: grant=0, must re-present next cycle."""
    dut_if, model = await setup(dut)

    # Cycle 1: ALU + FP_DIV both valid → FP_DIV wins, ALU loses
    dut_if.drive_fu_complete(FU_ALU, tag=1, value=0x1111)
    dut_if.drive_fu_complete(FU_FP_DIV, tag=2, value=0x2222)
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    dut_grants = dut_if.read_grant()
    assert dut_cdb.fu_type == FU_FP_DIV
    assert dut_grants[FU_ALU] is False
    assert dut_grants[FU_FP_DIV] is True

    # Cycle 2: FP_DIV clears (was granted), ALU still valid → ALU wins
    dut_if.clear_fu_complete(FU_FP_DIV)
    await dut_if.step()
    await Timer(1, unit="ns")

    dut_cdb = dut_if.read_cdb_output()
    dut_grants = dut_if.read_grant()
    assert dut_cdb.valid
    assert dut_cdb.fu_type == FU_ALU
    assert dut_cdb.tag == 1
    assert dut_grants[FU_ALU] is True


# ============================================================================
# Test 16: Constrained random: random subset of FUs valid, verify model match
# ============================================================================
@cocotb.test()
async def test_random_multi_fu_stress(dut: Any) -> None:
    """Constrained random: random subset of FUs valid each cycle, verify model match."""
    dut_if, model = await setup(dut)

    rng = random.Random(cocotb.RANDOM_SEED)
    num_cycles = 200

    for cycle in range(num_cycles):
        # Random subset of FUs valid (each with ~50% probability)
        fu_completes = [FuComplete() for _ in range(NUM_FUS)]
        for fu_idx in range(NUM_FUS):
            if rng.random() < 0.5:
                fu_completes[fu_idx] = FuComplete(
                    valid=True,
                    tag=rng.randint(0, 31),
                    value=rng.randint(0, MASK64),
                    exception=rng.random() < 0.1,
                    exc_cause=rng.randint(0, 0x1F),
                    fp_flags=rng.randint(0, 0x1F),
                )

        model_cdb, model_grants = drive_and_check(dut_if, model, fu_completes)

        await dut_if.step()
        await Timer(1, unit="ns")

        dut_cdb = dut_if.read_cdb_output()
        dut_grants = dut_if.read_grant()

        assert_cdb_match(dut_cdb, model_cdb, f"random cycle {cycle}")
        assert_grants_match(dut_grants, model_grants, f"random cycle {cycle}")

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

"""Register Alias Table unit tests.

Tests drive the RAT through RATInterface and use RATModel for expected
lookups. Random tests compare the final state with the model.

Usage (from repository root, through the pinned tools):
    ./scripts/frost.py cocotb register_alias_table
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any
import random

from .rat_model import (
    RATModel,
    NUM_INT_REGS,
    NUM_FP_REGS,
    NUM_CHECKPOINTS,
    MASK32,
    MASK64,
)
from .rat_interface import RATInterface


# =============================================================================
# Test Configuration
# =============================================================================

CLOCK_PERIOD_NS = 10
RESET_CYCLES = 5


def log_random_seed() -> int:
    """Generate, log, and apply a random seed for reproducibility."""
    seed = random.getrandbits(32)
    random.seed(seed)
    cocotb.log.info(f"Random seed: {seed}")
    return seed


# =============================================================================
# Test Setup Helpers
# =============================================================================


async def setup_test(dut: Any) -> tuple[RATInterface, RATModel]:
    """Start the clock and return (interface, model) with both reset."""
    dut_if = RATInterface(dut)
    model = RATModel()

    Clock(dut_if.clock, CLOCK_PERIOD_NS, unit="ns").start()

    await dut_if.reset_dut(RESET_CYCLES)
    model.reset()

    return dut_if, model


def check_lookup(actual: Any, expected: Any, label: str) -> None:
    """Assert that a lookup result matches expected values."""
    assert actual.renamed == expected.renamed, (
        f"{label}: renamed mismatch: got {actual.renamed}, expected {expected.renamed}"
    )
    if expected.renamed:
        assert actual.tag == expected.tag, (
            f"{label}: tag mismatch: got {actual.tag}, expected {expected.tag}"
        )
    # An unrenamed source carries architectural data and an unspecified tag.
    assert actual.value == expected.value, (
        f"{label}: value mismatch: got {actual.value:#x}, expected {expected.value:#x}"
    )


# =============================================================================
# Directed Tests
# =============================================================================


@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """Check reset lookups and the first free checkpoint ID."""
    cocotb.log.info("=== Test: Reset State ===")

    dut_if, model = await setup_test(dut)

    # Lookups are combinational; the edge only lets driven inputs settle.
    for addr in [0, 1, 5, 15, 31]:
        regfile_val = addr * 100
        dut_if.set_int_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(addr, regfile_val)
        check_lookup(result, expected, f"INT x{addr}")

    for addr in [0, 1, 16, 31]:
        regfile_val = 0xDEAD0000 + addr
        dut_if.set_fp_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(addr, regfile_val)
        check_lookup(result, expected, f"FP f{addr}")

    assert dut_if.checkpoint_available, "Checkpoint should be available after reset"
    assert dut_if.checkpoint_alloc_id == 0, "First free checkpoint should be 0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_x0_hardwired_zero(dut: Any) -> None:
    """x0 returns renamed=0 and value=0 even with nonzero regfile data."""
    cocotb.log.info("=== Test: x0 Hardwired Zero ===")

    dut_if, model = await setup_test(dut)

    dut_if.set_int_src1(0, 0xDEADBEEF)
    dut_if.set_int_src2(0, 0x12345678)
    await RisingEdge(dut_if.clock)

    result1 = dut_if.read_int_src1()
    result2 = dut_if.read_int_src2()

    assert not result1.renamed, "x0 src1 should not be renamed"
    assert result1.value == 0, f"x0 src1 value should be 0, got {result1.value:#x}"
    assert not result2.renamed, "x0 src2 should not be renamed"
    assert result2.value == 0, f"x0 src2 value should be 0, got {result2.value:#x}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rv64_regfile_value_passthrough(dut: Any) -> None:
    """Check all integer lookup ports with values that use bits 63:32."""
    cocotb.log.info("=== Test: RV64 Regfile Value Passthrough ===")

    dut_if, model = await setup_test(dut)
    lookups = (
        (dut_if.set_int_src1, dut_if.read_int_src1, 1, 0x0123_4567_89AB_CDEF),
        (dut_if.set_int_src2, dut_if.read_int_src2, 2, 0xFEDC_BA98_7654_3210),
        (dut_if.set_int_src1_2, dut_if.read_int_src1_2, 3, 0x1357_9BDF_2468_ACE0),
        (dut_if.set_int_src2_2, dut_if.read_int_src2_2, 4, 0xF0E1_D2C3_B4A5_9687),
    )

    for drive, read, addr, regfile_value in lookups:
        drive(addr, regfile_value)
        await RisingEdge(dut_if.clock)
        check_lookup(
            read(),
            model.lookup_int(addr, regfile_value),
            f"RV64 INT x{addr}",
        )

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_int_rename_and_lookup(dut: Any) -> None:
    """Look up a renamed INT register and an untouched register."""
    cocotb.log.info("=== Test: INT Rename and Lookup ===")

    dut_if, model = await setup_test(dut)

    dut_if.drive_rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_rename()

    regfile_val = 0x42
    dut_if.set_int_src1(5, regfile_val)
    await RisingEdge(dut_if.clock)

    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, regfile_val)
    check_lookup(result, expected, "INT x5 after rename")

    assert result.renamed, "x5 should be renamed"
    assert result.tag == 3, f"x5 tag should be 3, got {result.tag}"

    dut_if.set_int_src2(10, 0xABCD)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src2()
    expected = model.lookup_int(10, 0xABCD)
    check_lookup(result, expected, "INT x10 not renamed")
    assert not result.renamed, "x10 should not be renamed"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fp_rename_and_lookup(dut: Any) -> None:
    """Rename and look up f0, which is renameable unlike x0."""
    cocotb.log.info("=== Test: FP Rename and Lookup ===")

    dut_if, model = await setup_test(dut)

    dut_if.drive_rename(dest_rf=1, dest_reg=0, rob_tag=7)
    model.rename(dest_rf=1, dest_reg=0, rob_tag=7)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_rename()

    regfile_val = 0x3FF0000000000000  # 1.0 in double
    dut_if.set_fp_src1(0, regfile_val)
    await RisingEdge(dut_if.clock)

    result = dut_if.read_fp_src1()
    expected = model.lookup_fp(0, regfile_val)
    check_lookup(result, expected, "FP f0 after rename")
    assert result.renamed, "f0 should be renamed"
    assert result.tag == 7, f"f0 tag should be 7, got {result.tag}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fp_src3_lookup(dut: Any) -> None:
    """Check renamed and unrenamed operands on FP source 3, used by FMA."""
    cocotb.log.info("=== Test: FP Source 3 Lookup ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=15)
    model.rename(dest_rf=1, dest_reg=10, rob_tag=15)

    regfile_val = 0x4000000000000000  # 2.0 in double
    dut_if.set_fp_src3(10, regfile_val)
    await RisingEdge(dut_if.clock)

    result = dut_if.read_fp_src3()
    expected = model.lookup_fp(10, regfile_val)
    check_lookup(result, expected, "FP f10 via src3")
    assert result.renamed, "f10 should be renamed via src3"

    dut_if.set_fp_src3(20, 0xCAFE)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src3()
    expected = model.lookup_fp(20, 0xCAFE)
    check_lookup(result, expected, "FP f20 not renamed via src3")
    assert not result.renamed, "f20 should not be renamed"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_multiple_renames(dut: Any) -> None:
    """Sequential renames preserve earlier mappings and leave x0 at zero."""
    cocotb.log.info("=== Test: Multiple Renames ===")

    dut_if, model = await setup_test(dut)

    renames = [(1, 0), (5, 3), (10, 7), (31, 15)]  # (reg, tag)
    for reg, tag in renames:
        dut_if.drive_rename(dest_rf=0, dest_reg=reg, rob_tag=tag)
        model.rename(dest_rf=0, dest_reg=reg, rob_tag=tag)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_rename()

    for reg, tag in renames:
        dut_if.set_int_src1(reg, reg * 100)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(reg, reg * 100)
        check_lookup(result, expected, f"INT x{reg}")
        assert result.renamed, f"x{reg} should be renamed"
        assert result.tag == tag, f"x{reg} tag mismatch"

    dut_if.set_int_src1(0, 0xFFFF)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert not result.renamed, "x0 should not be renamed"
    assert result.value == 0, "x0 value should be 0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rename_overwrites_previous(dut: Any) -> None:
    """A newer rename overwrites an older mapping."""
    cocotb.log.info("=== Test: Rename Overwrites Previous ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.tag == 3

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=10)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=10)

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x5 should still be renamed"
    assert result.tag == 10, f"x5 tag should be 10, got {result.tag}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_commit_clears_entry(dut: Any) -> None:
    """Commit clears the RAT entry when its tag matches."""
    cocotb.log.info("=== Test: Commit Clears Entry ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    dut_if.set_int_src1(5, 0x42)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x5 should be renamed before commit"

    await dut_if.commit(tag=3, dest_rf=0, dest_reg=5)
    model.commit(dest_rf=0, dest_reg=5, tag=3)

    dut_if.set_int_src1(5, 0x42)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x42)
    check_lookup(result, expected, "INT x5 after commit")
    assert not result.renamed, "x5 should not be renamed after commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_commit_tag_mismatch_preserves(dut: Any) -> None:
    """Commit with a mismatched tag preserves the RAT entry."""
    cocotb.log.info("=== Test: Commit Tag Mismatch Preserves ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    await dut_if.commit(tag=7, dest_rf=0, dest_reg=5)
    model.commit(dest_rf=0, dest_reg=5, tag=7)

    dut_if.set_int_src1(5, 0x42)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x42)
    check_lookup(result, expected, "INT x5 after mismatched commit")
    assert result.renamed, "x5 should still be renamed (tag mismatch)"
    assert result.tag == 3, f"x5 tag should still be 3, got {result.tag}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rename_and_commit_same_cycle(dut: Any) -> None:
    """Rename wins over commit to the same register in the same cycle."""
    cocotb.log.info("=== Test: Rename and Commit Same Cycle ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    await FallingEdge(dut_if.clock)
    dut_if.drive_rename(dest_rf=0, dest_reg=5, rob_tag=10)
    dut_if.drive_commit(tag=3, dest_rf=0, dest_reg=5)

    # Model: commit first, then rename (rename wins)
    model.commit(dest_rf=0, dest_reg=5, tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=10)

    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_rename()
    dut_if.clear_commit()

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_lookup(result, expected, "INT x5 after simultaneous rename+commit")
    assert result.renamed, "x5 should be renamed (rename wins over commit)"
    assert result.tag == 10, f"x5 tag should be 10, got {result.tag}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_flush_all_clears_everything(dut: Any) -> None:
    """Check INT/FP lookup and checkpoint availability after a full flush."""
    cocotb.log.info("=== Test: Flush All Clears Everything ===")

    dut_if, model = await setup_test(dut)

    for i in range(1, 8):
        await dut_if.rename(dest_rf=0, dest_reg=i, rob_tag=i)
        model.rename(dest_rf=0, dest_reg=i, rob_tag=i)

    for i in range(4):
        await dut_if.rename(dest_rf=1, dest_reg=i, rob_tag=i + 20)
        model.rename(dest_rf=1, dest_reg=i, rob_tag=i + 20)

    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=5)
    model.checkpoint_save(checkpoint_id=0, branch_tag=5, ras_tos=0, ras_valid_count=0)

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x5 should be renamed before flush"

    await dut_if.flush_all()
    model.flush_all()

    for addr in [1, 5, 7, 31]:
        dut_if.set_int_src1(addr, addr * 10)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(addr, addr * 10)
        check_lookup(result, expected, f"INT x{addr} after flush")
        assert not result.renamed, f"x{addr} should not be renamed after flush"

    for addr in [0, 1, 3]:
        dut_if.set_fp_src1(addr, addr * 10)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(addr, addr * 10)
        check_lookup(result, expected, f"FP f{addr} after flush")
        assert not result.renamed, f"f{addr} should not be renamed after flush"

    assert dut_if.checkpoint_available, "Checkpoint should be available after flush"
    assert dut_if.checkpoint_alloc_id == 0, "First free checkpoint should be 0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fp_commit_clears_entry(dut: Any) -> None:
    """FP commit clears a matching FP RAT entry."""
    cocotb.log.info("=== Test: FP Commit Clears Entry ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=12)
    model.rename(dest_rf=1, dest_reg=10, rob_tag=12)

    dut_if.set_fp_src1(10, 0x1234)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    assert result.renamed, "f10 should be renamed"

    await dut_if.commit(tag=12, dest_rf=1, dest_reg=10)
    model.commit(dest_rf=1, dest_reg=10, tag=12)

    dut_if.set_fp_src1(10, 0x1234)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    expected = model.lookup_fp(10, 0x1234)
    check_lookup(result, expected, "FP f10 after commit")
    assert not result.renamed, "f10 should not be renamed after commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_commit_no_dest_valid(dut: Any) -> None:
    """Commit with dest_valid=False preserves the targeted mapping."""
    cocotb.log.info("=== Test: Commit No Dest Valid ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    await dut_if.commit(tag=3, dest_rf=0, dest_reg=5, dest_valid=False)
    # No model commit: dest_valid is false.

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x5 should still be renamed (commit had dest_valid=False)"
    assert result.tag == 3, f"x5 tag should still be 3, got {result.tag}"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Checkpoint Tests
# =============================================================================


@cocotb.test()
async def test_checkpoint_save_restore(dut: Any) -> None:
    """Restore saved mappings after overwriting and adding rename entries."""
    cocotb.log.info("=== Test: Checkpoint Save and Restore ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    await dut_if.rename(dest_rf=0, dest_reg=10, rob_tag=7)
    model.rename(dest_rf=0, dest_reg=10, rob_tag=7)

    await dut_if.checkpoint_save(
        checkpoint_id=0, branch_tag=10, ras_tos=2, ras_valid_count=5
    )
    model.checkpoint_save(checkpoint_id=0, branch_tag=10, ras_tos=2, ras_valid_count=5)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=20)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=20)
    await dut_if.rename(dest_rf=0, dest_reg=15, rob_tag=25)
    model.rename(dest_rf=0, dest_reg=15, rob_tag=25)

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.tag == 20, "x5 tag should be 20 (post-checkpoint rename)"

    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()

    model.checkpoint_restore(0)

    dut_if.set_int_src1(5, 0x42)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x42)
    check_lookup(result, expected, "INT x5 after restore")
    assert result.tag == 3, f"x5 tag should be 3 after restore, got {result.tag}"

    dut_if.set_int_src2(10, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src2()
    expected = model.lookup_int(10, 0)
    check_lookup(result, expected, "INT x10 after restore")
    assert result.tag == 7, f"x10 tag should be 7 after restore, got {result.tag}"

    dut_if.set_int_src1(15, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(15, 0)
    check_lookup(result, expected, "INT x15 after restore")
    assert not result.renamed, "x15 should not be renamed after restore"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_restore_ras_state(dut: Any) -> None:
    """A checkpoint restores the RAS pointer, valid count, and top entry."""
    cocotb.log.info("=== Test: Checkpoint Restore RAS State ===")

    dut_if, model = await setup_test(dut)

    ras_tos = 5
    ras_valid_count = 7
    ras_top = 0xFEDC_BA98_7654_3210
    await dut_if.checkpoint_save(
        checkpoint_id=1,
        branch_tag=2,
        ras_tos=ras_tos,
        ras_valid_count=ras_valid_count,
        ras_top=ras_top,
    )
    model.checkpoint_save(
        checkpoint_id=1,
        branch_tag=2,
        ras_tos=ras_tos,
        ras_valid_count=ras_valid_count,
        ras_top=ras_top,
    )

    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(1)
    await RisingEdge(dut_if.clock)
    # RAS outputs are combinational from the checkpoint RAM read
    actual_tos = dut_if.ras_tos
    actual_count = dut_if.ras_valid_count
    actual_top = dut_if.ras_top
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()

    assert actual_tos == ras_tos, (
        f"RAS TOS mismatch: got {actual_tos}, expected {ras_tos}"
    )
    assert actual_count == ras_valid_count, (
        f"RAS valid count mismatch: got {actual_count}, expected {ras_valid_count}"
    )
    assert actual_top == ras_top, (
        f"RAS top mismatch: got {actual_top:#x}, expected {ras_top:#x}"
    )

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_free(dut: Any) -> None:
    """Freeing a checkpoint makes its slot available again."""
    cocotb.log.info("=== Test: Checkpoint Free ===")

    dut_if, model = await setup_test(dut)

    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=5)
    model.checkpoint_save(checkpoint_id=0, branch_tag=5, ras_tos=0, ras_valid_count=0)

    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_available, (
        "Checkpoint should still be available (1-7 free)"
    )
    assert dut_if.checkpoint_alloc_id == 1, "Next free should be 1"

    await dut_if.checkpoint_free(0)
    model.checkpoint_free(0)

    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_available, "Checkpoint should be available after free"
    assert dut_if.checkpoint_alloc_id == 0, "Next free should be 0 again"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_availability(dut: Any) -> None:
    """Checkpoint allocation selects the lowest free slot."""
    cocotb.log.info("=== Test: Checkpoint Availability ===")

    dut_if, model = await setup_test(dut)

    assert dut_if.checkpoint_available
    assert dut_if.checkpoint_alloc_id == 0

    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=1)
    model.checkpoint_save(0, 1, 0, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_alloc_id == 1, "Next free should be 1"

    await dut_if.checkpoint_save(checkpoint_id=1, branch_tag=2)
    model.checkpoint_save(1, 2, 0, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_alloc_id == 2, "Next free should be 2"

    await dut_if.checkpoint_free(0)
    model.checkpoint_free(0)
    await dut_if.checkpoint_save(checkpoint_id=2, branch_tag=3)
    model.checkpoint_save(2, 3, 0, 0)

    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_alloc_id == 0, "Next free should be 0 (freed earlier)"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_exhaustion(dut: Any) -> None:
    """Exhaust the checkpoints, then free a slot and check availability."""
    cocotb.log.info("=== Test: Checkpoint Exhaustion ===")

    dut_if, model = await setup_test(dut)

    for i in range(NUM_CHECKPOINTS):
        await dut_if.checkpoint_save(checkpoint_id=i, branch_tag=i + 10)
        model.checkpoint_save(i, i + 10, 0, 0)

    await RisingEdge(dut_if.clock)
    assert not dut_if.checkpoint_available, "No checkpoint should be available"

    avail, _ = model.checkpoint_available()
    assert not avail, "Model should also show no checkpoints available"

    await dut_if.checkpoint_free(2)
    model.checkpoint_free(2)
    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_available, "Checkpoint 2 should be available after free"
    assert dut_if.checkpoint_alloc_id == 2, "Freed slot 2 should be next"  # type: ignore[unreachable]

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_restore_undoes_renames(dut: Any) -> None:
    """Restore keeps a saved mapping and clears entries renamed after save."""
    cocotb.log.info("=== Test: Checkpoint Restore Undoes Renames ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=1, rob_tag=1)
    model.rename(0, 1, 1)

    # The checkpoint branch must be younger than the saved producers.
    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=5)
    model.checkpoint_save(0, 5, 0, 0)

    await dut_if.rename(dest_rf=0, dest_reg=2, rob_tag=2)
    model.rename(0, 2, 2)
    await dut_if.rename(dest_rf=0, dest_reg=3, rob_tag=3)
    model.rename(0, 3, 3)
    await dut_if.rename(dest_rf=1, dest_reg=5, rob_tag=4)
    model.rename(1, 5, 4)

    dut_if.set_int_src1(2, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_int_src1().renamed, "x2 should be renamed"

    dut_if.set_fp_src1(5, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_fp_src1().renamed, "f5 should be renamed"

    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()
    model.checkpoint_restore(0)

    dut_if.set_int_src1(1, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x1 should still be renamed after restore"
    assert result.tag == 1

    dut_if.set_int_src1(2, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_int_src1().renamed, "x2 should not be renamed after restore"

    dut_if.set_int_src1(3, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_int_src1().renamed, "x3 should not be renamed after restore"

    dut_if.set_fp_src1(5, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_fp_src1().renamed, "f5 should not be renamed after restore"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_multiple_checkpoint_round_trips(dut: Any) -> None:
    """Restore empty and populated snapshots in successive round trips."""
    cocotb.log.info("=== Test: Multiple Checkpoint Round Trips ===")

    dut_if, model = await setup_test(dut)

    # Round trip 1: save at clean state, modify, restore
    await dut_if.checkpoint_save(
        checkpoint_id=0, branch_tag=0, ras_tos=0, ras_valid_count=0
    )
    model.checkpoint_save(0, 0, 0, 0)

    await dut_if.rename(dest_rf=0, dest_reg=1, rob_tag=10)
    model.rename(0, 1, 10)

    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()
    model.checkpoint_restore(0)

    dut_if.set_int_src1(1, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_int_src1().renamed, (
        "x1 should not be renamed after first restore"
    )

    await dut_if.checkpoint_free(0)
    model.checkpoint_free(0)

    # Round trip 2: save with some renames, modify more, restore
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=15)
    model.rename(0, 5, 15)

    await dut_if.checkpoint_save(
        checkpoint_id=1, branch_tag=16, ras_tos=3, ras_valid_count=6
    )
    model.checkpoint_save(1, 16, 3, 6)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=20)  # Overwrite
    model.rename(0, 5, 20)
    await dut_if.rename(dest_rf=1, dest_reg=0, rob_tag=21)  # New FP
    model.rename(1, 0, 21)

    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(1)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()
    model.checkpoint_restore(1)

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed and result.tag == 15, (
        f"x5 should have tag 15, got {result.tag}"
    )

    dut_if.set_fp_src1(0, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_fp_src1().renamed, "f0 should not be renamed after restore"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_with_fp_state(dut: Any) -> None:
    """A checkpoint restores FP mappings after further renames."""
    cocotb.log.info("=== Test: Checkpoint with FP State ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=1, dest_reg=0, rob_tag=1)
    model.rename(1, 0, 1)
    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=2)
    model.rename(1, 10, 2)
    await dut_if.rename(dest_rf=1, dest_reg=31, rob_tag=3)
    model.rename(1, 31, 3)

    await dut_if.checkpoint_save(checkpoint_id=2, branch_tag=5)
    model.checkpoint_save(2, 5, 0, 0)

    await dut_if.rename(dest_rf=1, dest_reg=0, rob_tag=20)
    model.rename(1, 0, 20)
    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=21)
    model.rename(1, 10, 21)

    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(2)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()
    model.checkpoint_restore(2)

    for reg, expected_tag in [(0, 1), (10, 2), (31, 3)]:
        dut_if.set_fp_src1(reg, 0)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(reg, 0)
        check_lookup(result, expected, f"FP f{reg} after restore")
        assert result.tag == expected_tag, f"f{reg} tag should be {expected_tag}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_flush_all_after_checkpoints(dut: Any) -> None:
    """A full flush restores availability after checkpoint exhaustion."""
    cocotb.log.info("=== Test: Flush All After Checkpoints ===")

    dut_if, model = await setup_test(dut)

    for i in range(NUM_CHECKPOINTS):
        await dut_if.checkpoint_save(checkpoint_id=i, branch_tag=i)
        model.checkpoint_save(i, i, 0, 0)

    assert not dut_if.checkpoint_available, "Should be exhausted"

    await dut_if.flush_all()
    model.flush_all()

    assert dut_if.checkpoint_available, "All checkpoints should be free after flush"
    assert dut_if.checkpoint_alloc_id == 0  # type: ignore[unreachable]

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Priority/Collision Tests
# =============================================================================


@cocotb.test()
async def test_flush_all_priority_over_commit_save_free(dut: Any) -> None:
    """Full flush wins over commit, checkpoint save, and free in the same cycle."""
    cocotb.log.info("=== Test: Flush All Priority Over Commit/Save/Free ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(0, 5, 3)
    await dut_if.rename(dest_rf=0, dest_reg=6, rob_tag=4)
    model.rename(0, 6, 4)
    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=10)
    model.checkpoint_save(0, 10, 0, 0)
    await dut_if.checkpoint_save(checkpoint_id=1, branch_tag=11)
    model.checkpoint_save(1, 11, 0, 0)

    await FallingEdge(dut_if.clock)
    dut_if.drive_commit(tag=3, dest_rf=0, dest_reg=5)
    dut_if.drive_checkpoint_save(
        checkpoint_id=2, branch_tag=12, ras_tos=3, ras_valid_count=5
    )
    dut_if.drive_checkpoint_free(checkpoint_id=0)
    dut_if.drive_flush_all()
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_commit()
    dut_if.clear_checkpoint_save()
    dut_if.clear_checkpoint_free()
    dut_if.clear_flush_all()
    model.flush_all()

    for reg in [5, 6]:
        dut_if.set_int_src1(reg, 0x1234)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(reg, 0x1234)
        check_lookup(result, expected, f"INT x{reg} after flush collision")
        assert not result.renamed, f"x{reg} should not be renamed after flush collision"

    assert dut_if.checkpoint_available, (
        "Checkpoint should be available after flush collision"
    )
    assert dut_if.checkpoint_alloc_id == 0, (
        "All checkpoints should be free after flush collision"
    )

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_restore_priority_over_commit(dut: Any) -> None:
    """Restore a saved mapping while committing its tag in the same cycle."""
    cocotb.log.info("=== Test: Checkpoint Restore Priority Over Commit ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=1)
    model.rename(0, 5, 1)

    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=20)
    model.checkpoint_save(0, 20, 0, 0)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=2)
    model.rename(0, 5, 2)

    # Commit tag 1 differs from the active tag 2 and cannot clear it. Restore
    # reinstates tag 1; this does not test a clear matching the active mapping.
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(0)
    dut_if.drive_commit(tag=1, dest_rf=0, dest_reg=5)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()
    dut_if.clear_commit()
    model.checkpoint_restore(0)

    dut_if.set_int_src1(5, 0x77)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x77)
    check_lookup(result, expected, "INT x5 after restore+commit collision")
    assert result.renamed, "x5 should remain renamed after restore+commit collision"
    assert result.tag == 1, (
        f"x5 tag should be 1 after restore+commit collision, got {result.tag}"
    )

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_save_free_same_cycle_precedence(dut: Any) -> None:
    """Save wins over a same-slot free; different-slot updates both take effect."""
    cocotb.log.info("=== Test: Checkpoint Save/Free Same-Cycle Precedence ===")

    dut_if, model = await setup_test(dut)

    # Save wins over a same-slot free.
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_save(checkpoint_id=0, branch_tag=1)
    dut_if.drive_checkpoint_free(checkpoint_id=0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_save()
    dut_if.clear_checkpoint_free()
    model.checkpoint_free(0)
    model.checkpoint_save(0, 1, 0, 0)

    assert dut_if.checkpoint_available, (
        "Other checkpoint slots should still be available after same-slot save+free"
    )
    assert dut_if.checkpoint_alloc_id == 1, (
        "Slot 0 should remain allocated when save+free target the same slot"
    )

    # Different slots update independently.
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_save(checkpoint_id=1, branch_tag=3)
    dut_if.drive_checkpoint_free(checkpoint_id=0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_save()
    dut_if.clear_checkpoint_free()
    model.checkpoint_free(0)
    model.checkpoint_save(1, 3, 0, 0)

    assert dut_if.checkpoint_available, (
        "Checkpoint should be available after save/free on different slots"
    )
    assert dut_if.checkpoint_alloc_id == 0, (
        "Slot 0 should be next free after save(slot1)+free(slot0)"
    )

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_free_second_port(dut: Any) -> None:
    """Port 2 frees alone or with port 1; save wins over a same-slot free."""
    cocotb.log.info("=== Test: Checkpoint Free Second Port ===")

    dut_if, model = await setup_test(dut)

    for slot in range(4):
        await dut_if.checkpoint_save(checkpoint_id=slot, branch_tag=slot + 8)
        model.checkpoint_save(slot, slot + 8, 0, 0)
    assert dut_if.checkpoint_alloc_id == 4, "Slots 0-3 should be in use"

    async def free_cycle(
        free_1: int | None, free_2: int | None, save: int | None = None
    ) -> None:
        await FallingEdge(dut_if.clock)
        if free_1 is not None:
            dut_if.drive_checkpoint_free(free_1)
        if free_2 is not None:
            dut_if.drive_checkpoint_free_2(free_2)
        if save is not None:
            dut_if.drive_checkpoint_save(checkpoint_id=save, branch_tag=save + 16)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_checkpoint_free()
        dut_if.clear_checkpoint_free_2()
        dut_if.clear_checkpoint_save()
        for slot in (free_1, free_2):
            if slot is not None:
                model.checkpoint_free(slot)
        if save is not None:
            model.checkpoint_save(save, save + 16, 0, 0)

    def check(label: str) -> None:
        avail, alloc_id = model.checkpoint_available()
        assert dut_if.checkpoint_available == avail, f"{label}: availability"
        if avail:
            assert dut_if.checkpoint_alloc_id == alloc_id, (
                f"{label}: next free slot DUT={dut_if.checkpoint_alloc_id} "
                f"model={alloc_id}"
            )

    # Port 2 alone.
    await free_cycle(None, 2)
    check("port 2 frees slot 2")
    assert dut_if.checkpoint_alloc_id == 2

    # Both ports in one cycle, different slots.
    await free_cycle(0, 3)
    check("port 1 frees slot 0, port 2 frees slot 3")
    assert dut_if.checkpoint_alloc_id == 0

    # Refill, then free the same slot on both ports.
    for slot in (0, 2, 3):
        await dut_if.checkpoint_save(checkpoint_id=slot, branch_tag=slot + 8)
        model.checkpoint_save(slot, slot + 8, 0, 0)
    check("slots 0-3 in use again")
    await free_cycle(1, 1)
    check("both ports free slot 1")
    assert dut_if.checkpoint_alloc_id == 1

    # A save to the slot port 2 frees in the same cycle wins.
    await free_cycle(None, 1, save=1)
    check("save wins over a same-slot port-2 free")
    assert dut_if.checkpoint_alloc_id == 4

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# INT/FP Cross-Table Tests
# =============================================================================


@cocotb.test()
async def test_int_fp_independence(dut: Any) -> None:
    """INT and FP mappings are independent at the same register index."""
    cocotb.log.info("=== Test: INT/FP Independence ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(0, 5, 3)

    dut_if.set_fp_src1(5, 0xABCD)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    assert not result.renamed, "f5 should not be affected by x5 rename"

    await dut_if.rename(dest_rf=1, dest_reg=5, rob_tag=7)
    model.rename(1, 5, 7)

    dut_if.set_int_src1(5, 0)
    dut_if.set_fp_src1(5, 0)
    await RisingEdge(dut_if.clock)

    int_result = dut_if.read_int_src1()
    fp_result = dut_if.read_fp_src1()

    assert int_result.renamed and int_result.tag == 3, "x5 should have tag 3"
    assert fp_result.renamed and fp_result.tag == 7, "f5 should have tag 7"

    await dut_if.commit(tag=3, dest_rf=0, dest_reg=5)
    model.commit(0, 5, 3)

    dut_if.set_int_src1(5, 0)
    dut_if.set_fp_src1(5, 0)
    await RisingEdge(dut_if.clock)

    int_result = dut_if.read_int_src1()
    fp_result = dut_if.read_fp_src1()

    assert not int_result.renamed, "x5 should not be renamed after INT commit"
    assert fp_result.renamed and fp_result.tag == 7, "f5 should still be renamed"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Regfile Value Passthrough Tests
# =============================================================================


@cocotb.test()
async def test_regfile_value_passthrough(dut: Any) -> None:
    """Regfile data passes through whether or not a source is renamed; x0 reads 0."""
    cocotb.log.info("=== Test: Regfile Value Passthrough ===")

    dut_if, model = await setup_test(dut)

    # Test INT value passthrough (not renamed)
    dut_if.set_int_src1(5, 0xDEADBEEF)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert not result.renamed
    assert result.value == 0xDEADBEEF, f"Value mismatch: {result.value:#x}"

    # Test INT value passthrough (renamed)
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(0, 5, 3)

    dut_if.set_int_src1(5, 0xCAFEBABE)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed
    assert result.value == 0xCAFEBABE, f"Value mismatch: {result.value:#x}"

    # Test FP value passthrough
    fp_val = 0x4000000000000000  # 2.0 in double
    dut_if.set_fp_src2(10, fp_val)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src2()
    assert not result.renamed
    assert result.value == fp_val, f"FP value mismatch: {result.value:#x}"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Slot-2 / 2-Wide Tests
# =============================================================================


@cocotb.test()
async def test_slot2_source_lookups(dut: Any) -> None:
    """Check slot-2 lookups with renamed, unrenamed, and x0 sources."""
    cocotb.log.info("=== Test: Slot-2 Source Lookups ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(0, 5, 3)
    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=7)
    model.rename(1, 10, 7)

    dut_if.set_int_src1_2(5, 0x1111_2222)
    dut_if.set_int_src2_2(0, 0x3333_4444)
    dut_if.set_fp_src1_2(10, 0xAAAA_BBBB_CCCC_DDDD)
    dut_if.set_fp_src2_2(11, 0x1111_2222_3333_4444)
    dut_if.set_fp_src3_2(10, 0x5555_6666_7777_8888)
    await RisingEdge(dut_if.clock)

    check_lookup(
        dut_if.read_int_src1_2(),
        model.lookup_int(5, 0x1111_2222),
        "slot-2 INT src1 x5",
    )
    check_lookup(
        dut_if.read_int_src2_2(),
        model.lookup_int(0, 0x3333_4444),
        "slot-2 INT src2 x0",
    )
    check_lookup(
        dut_if.read_fp_src1_2(),
        model.lookup_fp(10, 0xAAAA_BBBB_CCCC_DDDD),
        "slot-2 FP src1 f10",
    )
    check_lookup(
        dut_if.read_fp_src2_2(),
        model.lookup_fp(11, 0x1111_2222_3333_4444),
        "slot-2 FP src2 f11",
    )
    check_lookup(
        dut_if.read_fp_src3_2(),
        model.lookup_fp(10, 0x5555_6666_7777_8888),
        "slot-2 FP src3 f10",
    )

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_slot2_rename_and_lookup(dut: Any) -> None:
    """Slot-2 renames write INT and FP entries without a slot-1 rename."""
    cocotb.log.info("=== Test: Slot-2 Rename and Lookup ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename_2(dest_rf=0, dest_reg=6, rob_tag=9)
    model.rename(0, 6, 9)

    dut_if.set_int_src1(6, 0x1234)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(6, 0x1234)
    check_lookup(result, expected, "INT x6 after slot-2 rename")
    assert result.renamed and result.tag == 9, "x6 should carry slot-2 tag 9"

    await dut_if.rename_2(dest_rf=1, dest_reg=8, rob_tag=10)
    model.rename(1, 8, 10)

    dut_if.set_fp_src1(8, 0x4000_0000_0000_0000)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    expected = model.lookup_fp(8, 0x4000_0000_0000_0000)
    check_lookup(result, expected, "FP f8 after slot-2 rename")
    assert result.renamed and result.tag == 10, "f8 should carry slot-2 tag 10"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dual_rename_slot2_wins_same_register(dut: Any) -> None:
    """Slot 2 wins rename collisions; INT/FP writes at one index are independent."""
    cocotb.log.info("=== Test: Dual Rename Slot 2 Wins Same Register ===")

    dut_if, model = await setup_test(dut)

    await FallingEdge(dut_if.clock)
    dut_if.drive_rename(dest_rf=0, dest_reg=5, rob_tag=3)
    dut_if.drive_rename_2(dest_rf=0, dest_reg=5, rob_tag=4)
    model.rename(0, 5, 4)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_rename()
    dut_if.clear_rename_2()

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_lookup(result, expected, "INT x5 after dual rename collision")
    assert result.renamed and result.tag == 4, "slot-2 rename should win"

    await FallingEdge(dut_if.clock)
    dut_if.drive_rename(dest_rf=0, dest_reg=6, rob_tag=5)
    dut_if.drive_rename_2(dest_rf=1, dest_reg=6, rob_tag=6)
    model.rename(0, 6, 5)
    model.rename(1, 6, 6)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_rename()
    dut_if.clear_rename_2()

    dut_if.set_int_src1(6, 0)
    dut_if.set_fp_src1(6, 0)
    await RisingEdge(dut_if.clock)
    int_result = dut_if.read_int_src1()
    fp_result = dut_if.read_fp_src1()
    check_lookup(int_result, model.lookup_int(6, 0), "INT x6 after dual rename")
    check_lookup(fp_result, model.lookup_fp(6, 0), "FP f6 after dual rename")
    assert int_result.renamed and int_result.tag == 5, "x6 should keep slot-1 tag"
    assert fp_result.renamed and fp_result.tag == 6, "f6 should get slot-2 tag"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_slot2_commit_clears_entry(dut: Any) -> None:
    """Slot-2 commit clears a matching RAT entry."""
    cocotb.log.info("=== Test: Slot-2 Commit Clears Entry ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename_2(dest_rf=0, dest_reg=7, rob_tag=11)
    model.rename(0, 7, 11)

    await dut_if.commit_2(tag=11, dest_rf=0, dest_reg=7)
    model.commit(0, 7, 11)

    dut_if.set_int_src1(7, 0xABCD)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(7, 0xABCD)
    check_lookup(result, expected, "INT x7 after slot-2 commit")
    assert not result.renamed, "x7 should clear on matching slot-2 commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_dual_commit_same_cycle(dut: Any) -> None:
    """Slot 1 and slot 2 commits can clear independent RAT entries."""
    cocotb.log.info("=== Test: Dual Commit Same Cycle ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(0, 5, 3)
    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=12)
    model.rename(1, 10, 12)

    await FallingEdge(dut_if.clock)
    dut_if.drive_commit(tag=3, dest_rf=0, dest_reg=5)
    dut_if.drive_commit_2(tag=12, dest_rf=1, dest_reg=10)
    model.commit(0, 5, 3)
    model.commit(1, 10, 12)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_commit()
    dut_if.clear_commit_2()

    dut_if.set_int_src1(5, 0x55)
    dut_if.set_fp_src1(10, 0xAAAA)
    await RisingEdge(dut_if.clock)
    check_lookup(
        dut_if.read_int_src1(),
        model.lookup_int(5, 0x55),
        "INT x5 after dual commit",
    )
    check_lookup(
        dut_if.read_fp_src1(),
        model.lookup_fp(10, 0xAAAA),
        "FP f10 after dual commit",
    )
    assert not dut_if.read_int_src1().renamed, "x5 should clear"
    assert not dut_if.read_fp_src1().renamed, "f10 should clear"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rename_over_slot2_commit_same_cycle(dut: Any) -> None:
    """A same-cycle rename wins over a slot-2 commit clear."""
    cocotb.log.info("=== Test: Rename Over Slot-2 Commit Same Cycle ===")

    dut_if, model = await setup_test(dut)

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(0, 5, 3)

    await FallingEdge(dut_if.clock)
    dut_if.drive_commit_2(tag=3, dest_rf=0, dest_reg=5)
    dut_if.drive_rename(dest_rf=0, dest_reg=5, rob_tag=10)
    model.commit(0, 5, 3)
    model.rename(0, 5, 10)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_commit_2()
    dut_if.clear_rename()

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_lookup(result, expected, "INT x5 after rename over slot-2 commit")
    assert result.renamed and result.tag == 10, "rename should win over commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_save_for_slot2_overlays_slot1_rename(dut: Any) -> None:
    """Slot-2 branch checkpoint includes slot 1's rename but not slot 2's."""
    cocotb.log.info("=== Test: Checkpoint Save for Slot-2 Overlay ===")

    dut_if, model = await setup_test(dut)

    await FallingEdge(dut_if.clock)
    dut_if.drive_rename(dest_rf=0, dest_reg=5, rob_tag=3)
    dut_if.drive_rename_2(dest_rf=0, dest_reg=6, rob_tag=4)
    dut_if.drive_checkpoint_save(
        checkpoint_id=0,
        branch_tag=4,
        ras_tos=1,
        ras_valid_count=2,
        for_slot2=True,
    )
    model.checkpoint_save(0, 4, 1, 2, overlay_rename=(0, 5, 3))
    model.rename(0, 5, 3)
    model.rename(0, 6, 4)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_save()
    dut_if.clear_rename()
    dut_if.clear_rename_2()

    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=10)
    model.rename(0, 5, 10)
    await dut_if.rename(dest_rf=0, dest_reg=7, rob_tag=11)
    model.rename(0, 7, 11)

    dut_if.add_rob_entry_epoch_bits(1 << 3)
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()
    model.checkpoint_restore(0)

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_lookup(result, expected, "slot-1 rename restored from slot-2 checkpoint")
    assert result.renamed and result.tag == 3, "x5 should restore slot-1 rename"

    for reg in (6, 7):
        dut_if.set_int_src1(reg, 0)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(reg, 0)
        check_lookup(result, expected, f"INT x{reg} after slot-2 checkpoint restore")
        assert not result.renamed, f"x{reg} should not survive slot-2 restore"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_bulk_free_mask(dut: Any) -> None:
    """Bulk checkpoint free mask clears multiple slots in one cycle."""
    cocotb.log.info("=== Test: Checkpoint Bulk Free Mask ===")

    dut_if, model = await setup_test(dut)

    for checkpoint_id in range(4):
        await dut_if.checkpoint_save(checkpoint_id, branch_tag=checkpoint_id + 10)
        model.checkpoint_save(checkpoint_id, checkpoint_id + 10, 0, 0)

    assert dut_if.checkpoint_available, "Slots 4-7 should still be free"
    assert dut_if.checkpoint_alloc_id == 4, "Next free slot should be 4"

    free_mask = (1 << 1) | (1 << 3)
    await dut_if.checkpoint_bulk_free(free_mask)
    model.checkpoint_bulk_free(free_mask)

    assert dut_if.checkpoint_available, "Bulk free should make slots available"
    assert dut_if.checkpoint_alloc_id == 1, "Lowest bulk-freed slot should be next"

    await dut_if.checkpoint_save(1, branch_tag=20)
    model.checkpoint_save(1, 20, 0, 0)
    assert dut_if.checkpoint_alloc_id == 3, "Slot 3 should remain bulk-freed"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Constrained Random Tests
# =============================================================================


@cocotb.test()
async def test_random_rename_commit_sequence(dut: Any) -> None:
    """Compare final RAT state after random renames and commits."""
    cocotb.log.info("=== Test: Random Rename/Commit Sequence ===")
    seed = log_random_seed()

    dut_if, model = await setup_test(dut)

    num_ops = 100

    for op in range(num_ops):
        action = random.choice(["rename_int", "rename_fp", "commit_int", "commit_fp"])

        if action == "rename_int":
            reg = random.randint(1, 31)  # Skip x0
            tag = random.randint(0, 31)
            dut_if.drive_rename(dest_rf=0, dest_reg=reg, rob_tag=tag)
            model.rename(0, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_rename()

        elif action == "rename_fp":
            reg = random.randint(0, 31)
            tag = random.randint(0, 31)
            dut_if.drive_rename(dest_rf=1, dest_reg=reg, rob_tag=tag)
            model.rename(1, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_rename()

        elif action == "commit_int":
            reg = random.randint(1, 31)
            tag = random.randint(0, 31)
            dut_if.drive_commit(tag=tag, dest_rf=0, dest_reg=reg)
            model.commit(0, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_commit()

        elif action == "commit_fp":
            reg = random.randint(0, 31)
            tag = random.randint(0, 31)
            dut_if.drive_commit(tag=tag, dest_rf=1, dest_reg=reg)
            model.commit(1, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_commit()

    # Verify final state: check all INT registers
    for addr in range(NUM_INT_REGS):
        regfile_val = random.randint(0, MASK32)
        dut_if.set_int_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(addr, regfile_val)
        check_lookup(result, expected, f"Final INT x{addr}")

    # Verify all FP registers
    for addr in range(NUM_FP_REGS):
        regfile_val = random.randint(0, MASK64)
        dut_if.set_fp_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(addr, regfile_val)
        check_lookup(result, expected, f"Final FP f{addr}")

    cocotb.log.info(f"=== Test Passed ({num_ops} random ops, seed={seed}) ===")


@cocotb.test()
async def test_random_checkpoint_operations(dut: Any) -> None:
    """Compare RAS restores and final RAT/checkpoint state after random operations."""
    cocotb.log.info("=== Test: Random Checkpoint Operations ===")
    seed = log_random_seed()

    dut_if, model = await setup_test(dut)

    num_ops = 80

    for op in range(num_ops):
        avail_model, _ = model.checkpoint_available()

        action = random.choice(
            [
                "rename_int",
                "rename_fp",
                "commit_int",
                "checkpoint_save",
                "checkpoint_free",
                "checkpoint_restore",
            ]
        )

        if action == "rename_int":
            reg = random.randint(1, 31)
            tag = random.randint(0, 31)
            dut_if.drive_rename(dest_rf=0, dest_reg=reg, rob_tag=tag)
            model.rename(0, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_rename()

        elif action == "rename_fp":
            reg = random.randint(0, 31)
            tag = random.randint(0, 31)
            dut_if.drive_rename(dest_rf=1, dest_reg=reg, rob_tag=tag)
            model.rename(1, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_rename()

        elif action == "commit_int":
            reg = random.randint(1, 31)
            tag = random.randint(0, 31)
            dut_if.drive_commit(tag=tag, dest_rf=0, dest_reg=reg)
            model.commit(0, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_commit()

        elif action == "checkpoint_save":
            avail, slot_id = model.checkpoint_available()
            if avail:
                branch_tag = random.randint(0, 31)
                ras_tos = random.randint(0, 7)
                ras_count = random.randint(0, 8)
                ras_top = random.getrandbits(64)
                dut_if.drive_checkpoint_save(
                    slot_id, branch_tag, ras_tos, ras_count, ras_top=ras_top
                )
                model.checkpoint_save(
                    slot_id,
                    branch_tag,
                    ras_tos,
                    ras_count,
                    rob_entry_epoch=dut_if.rob_entry_epoch_mask,
                    ras_top=ras_top,
                )
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_save()
            else:
                pass  # Skip if all checkpoints in use

        elif action == "checkpoint_free":
            valid_slots = [
                i for i in range(NUM_CHECKPOINTS) if model.checkpoints[i].valid
            ]
            if valid_slots:
                slot_id = random.choice(valid_slots)
                dut_if.drive_checkpoint_free(slot_id)
                model.checkpoint_free(slot_id)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_free()

        elif action == "checkpoint_restore":
            valid_slots = [
                i for i in range(NUM_CHECKPOINTS) if model.checkpoints[i].valid
            ]
            if valid_slots:
                slot_id = random.choice(valid_slots)
                dut_if.drive_checkpoint_restore(slot_id)
                expected_ras = model.checkpoint_restore(
                    slot_id,
                    dut_if.rob_entry_valid_mask,
                    dut_if.rob_entry_epoch_mask,
                    dut_if.rob_head_tag,
                )
                await RisingEdge(dut_if.clock)
                actual_ras = (dut_if.ras_tos, dut_if.ras_valid_count, dut_if.ras_top)
                assert actual_ras == expected_ras, (
                    f"Restored RAS state of checkpoint {slot_id}: "
                    f"got {actual_ras}, expected {expected_ras}"
                )
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_restore()

    # Verify final state
    for addr in range(NUM_INT_REGS):
        regfile_val = random.randint(0, MASK32)
        dut_if.set_int_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(addr, regfile_val)
        check_lookup(result, expected, f"Final INT x{addr}")

    for addr in range(NUM_FP_REGS):
        regfile_val = random.randint(0, MASK64)
        dut_if.set_fp_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(addr, regfile_val)
        check_lookup(result, expected, f"Final FP f{addr}")

    # Verify checkpoint availability matches model
    avail_model, id_model = model.checkpoint_available()
    assert dut_if.checkpoint_available == avail_model, (
        f"Checkpoint available mismatch: DUT={dut_if.checkpoint_available}, model={avail_model}"
    )
    if avail_model:
        assert dut_if.checkpoint_alloc_id == id_model, (
            f"Checkpoint alloc_id mismatch: DUT={dut_if.checkpoint_alloc_id}, model={id_model}"
        )

    cocotb.log.info(f"=== Test Passed ({num_ops} random ops, seed={seed}) ===")


@cocotb.test()
async def test_random_mixed_stress(dut: Any) -> None:
    """Compare final RAT state with random slot-1 activity, checkpoints, and flushes."""
    cocotb.log.info("=== Test: Random Mixed Stress ===")
    seed = log_random_seed()

    dut_if, model = await setup_test(dut)

    num_ops = 200

    for op in range(num_ops):
        r = random.random()

        if r < 0.30:
            reg = random.randint(1, 31)
            tag = random.randint(0, 31)
            dut_if.drive_rename(dest_rf=0, dest_reg=reg, rob_tag=tag)
            model.rename(0, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_rename()

        elif r < 0.45:
            reg = random.randint(0, 31)
            tag = random.randint(0, 31)
            dut_if.drive_rename(dest_rf=1, dest_reg=reg, rob_tag=tag)
            model.rename(1, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_rename()

        elif r < 0.65:
            rf = random.randint(0, 1)
            reg = random.randint(0 if rf == 1 else 1, 31)
            tag = random.randint(0, 31)
            dut_if.drive_commit(tag=tag, dest_rf=rf, dest_reg=reg)
            model.commit(rf, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_commit()

        elif r < 0.75:
            avail, slot_id = model.checkpoint_available()
            if avail:
                bt = random.randint(0, 31)
                rt = random.randint(0, 7)
                rc = random.randint(0, 8)
                dut_if.drive_checkpoint_save(slot_id, bt, rt, rc)
                model.checkpoint_save(
                    slot_id,
                    bt,
                    rt,
                    rc,
                    rob_entry_epoch=dut_if.rob_entry_epoch_mask,
                )
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_save()

        elif r < 0.82:
            valid_slots = [
                i for i in range(NUM_CHECKPOINTS) if model.checkpoints[i].valid
            ]
            if valid_slots:
                slot_id = random.choice(valid_slots)
                dut_if.drive_checkpoint_free(slot_id)
                model.checkpoint_free(slot_id)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_free()

        elif r < 0.92:
            valid_slots = [
                i for i in range(NUM_CHECKPOINTS) if model.checkpoints[i].valid
            ]
            if valid_slots:
                slot_id = random.choice(valid_slots)
                dut_if.drive_checkpoint_restore(slot_id)
                model.checkpoint_restore(
                    slot_id,
                    dut_if.rob_entry_valid_mask,
                    dut_if.rob_entry_epoch_mask,
                    dut_if.rob_head_tag,
                )
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_restore()

        else:
            dut_if.drive_flush_all()
            model.flush_all()
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_flush_all()

    # Final verification
    for addr in range(NUM_INT_REGS):
        regfile_val = random.randint(0, MASK32)
        dut_if.set_int_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(addr, regfile_val)
        check_lookup(result, expected, f"Final INT x{addr}")

    for addr in range(NUM_FP_REGS):
        regfile_val = random.randint(0, MASK64)
        dut_if.set_fp_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(addr, regfile_val)
        check_lookup(result, expected, f"Final FP f{addr}")

    cocotb.log.info(f"=== Test Passed ({num_ops} random ops, seed={seed}) ===")

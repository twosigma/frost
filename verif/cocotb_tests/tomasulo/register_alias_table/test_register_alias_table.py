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

This module contains comprehensive tests for the Register Alias Table, including:

Directed Tests:
- test_reset_state: All entries clear after reset
- test_x0_hardwired_zero: x0 always returns renamed=0, value=0
- test_int_rename_and_lookup: Basic INT rename and source lookup
- test_fp_rename_and_lookup: Basic FP rename and source lookup
- test_fp_src3_lookup: FP source 3 (FMA) lookup
- test_multiple_renames: Multiple registers renamed simultaneously
- test_rename_overwrites_previous: Newer rename overwrites older mapping
- test_commit_clears_entry: Commit clears RAT entry when tag matches
- test_commit_tag_mismatch_preserves: Commit with wrong tag preserves entry
- test_rename_and_commit_same_cycle: Rename takes priority over commit to same register
- test_flush_all_clears_everything: Flush clears all RAT and checkpoint state

Checkpoint Tests:
- test_checkpoint_save_restore: Save and restore round-trip
- test_checkpoint_restore_ras_state: RAS state correctly restored
- test_checkpoint_free: Freeing a checkpoint makes it available
- test_checkpoint_availability: Priority encoder finds lowest free slot
- test_checkpoint_exhaustion: All 4 checkpoints in use
- test_checkpoint_restore_undoes_renames: Restore reverts post-checkpoint renames
- test_multiple_checkpoint_round_trips: Multiple save/restore sequences

Constrained Random Tests:
- test_random_rename_commit_sequence: Random interleaving of renames and commits
- test_random_checkpoint_operations: Random checkpoint save/restore/free

Usage:
    cd frost/tests
    make clean
    ./test_run_cocotb.py --sim verilator register_alias_table
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
    """Set up test environment.

    Start clock, reset DUT, initialize model.

    Returns:
        Tuple of (interface, model).
    """
    dut_if = RATInterface(dut)
    model = RATModel()

    cocotb.start_soon(Clock(dut_if.clock, CLOCK_PERIOD_NS, unit="ns").start())

    await dut_if.reset_dut(RESET_CYCLES)
    model.reset()

    return dut_if, model


def check_lookup(actual: Any, expected: Any, label: str) -> None:
    """Assert that a lookup result matches expected values."""
    assert (
        actual.renamed == expected.renamed
    ), f"{label}: renamed mismatch: got {actual.renamed}, expected {expected.renamed}"
    if expected.renamed:
        assert (
            actual.tag == expected.tag
        ), f"{label}: tag mismatch: got {actual.tag}, expected {expected.tag}"
    assert (
        actual.value == expected.value
    ), f"{label}: value mismatch: got {actual.value:#x}, expected {expected.value:#x}"


# =============================================================================
# Directed Tests
# =============================================================================


@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """Test that all entries are clear after reset."""
    cocotb.log.info("=== Test: Reset State ===")

    dut_if, model = await setup_test(dut)

    # Check a few INT registers - none should be renamed
    for addr in [0, 1, 5, 15, 31]:
        regfile_val = addr * 100
        dut_if.set_int_src1(addr, regfile_val)
        # Combinational - can read immediately
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(addr, regfile_val)
        check_lookup(result, expected, f"INT x{addr}")

    # Check a few FP registers
    for addr in [0, 1, 16, 31]:
        regfile_val = 0xDEAD0000 + addr
        dut_if.set_fp_src1(addr, regfile_val)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(addr, regfile_val)
        check_lookup(result, expected, f"FP f{addr}")

    # All 4 checkpoints should be available
    assert dut_if.checkpoint_available, "Checkpoint should be available after reset"
    assert dut_if.checkpoint_alloc_id == 0, "First free checkpoint should be 0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_x0_hardwired_zero(dut: Any) -> None:
    """Test that x0 always returns renamed=0, value=0 regardless of regfile data."""
    cocotb.log.info("=== Test: x0 Hardwired Zero ===")

    dut_if, model = await setup_test(dut)

    # Even with non-zero regfile data, x0 should return value=0
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
async def test_int_rename_and_lookup(dut: Any) -> None:
    """Test basic INT rename and source lookup.

    Renames x5 to ROB tag 3, then looks it up.
    """
    cocotb.log.info("=== Test: INT Rename and Lookup ===")

    dut_if, model = await setup_test(dut)

    # Rename x5 -> ROB[3]
    dut_if.drive_rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_rename()

    # Lookup x5 - should be renamed
    regfile_val = 0x42
    dut_if.set_int_src1(5, regfile_val)
    await RisingEdge(dut_if.clock)

    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, regfile_val)
    check_lookup(result, expected, "INT x5 after rename")

    assert result.renamed, "x5 should be renamed"
    assert result.tag == 3, f"x5 tag should be 3, got {result.tag}"

    # Lookup x10 - should NOT be renamed (was never written)
    dut_if.set_int_src2(10, 0xABCD)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src2()
    expected = model.lookup_int(10, 0xABCD)
    check_lookup(result, expected, "INT x10 not renamed")
    assert not result.renamed, "x10 should not be renamed"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fp_rename_and_lookup(dut: Any) -> None:
    """Test basic FP rename and source lookup.

    Renames f0 to ROB tag 7 (FP f0 is renameable, unlike INT x0).
    """
    cocotb.log.info("=== Test: FP Rename and Lookup ===")

    dut_if, model = await setup_test(dut)

    # Rename f0 -> ROB[7] (f0 IS renameable, unlike x0)
    dut_if.drive_rename(dest_rf=1, dest_reg=0, rob_tag=7)
    model.rename(dest_rf=1, dest_reg=0, rob_tag=7)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_rename()

    # Lookup f0
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
    """Test FP source 3 lookup (for FMA instructions)."""
    cocotb.log.info("=== Test: FP Source 3 Lookup ===")

    dut_if, model = await setup_test(dut)

    # Rename f10 -> ROB[15]
    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=15)
    model.rename(dest_rf=1, dest_reg=10, rob_tag=15)

    # Lookup f10 via src3
    regfile_val = 0x4000000000000000  # 2.0 in double
    dut_if.set_fp_src3(10, regfile_val)
    await RisingEdge(dut_if.clock)

    result = dut_if.read_fp_src3()
    expected = model.lookup_fp(10, regfile_val)
    check_lookup(result, expected, "FP f10 via src3")
    assert result.renamed, "f10 should be renamed via src3"

    # Lookup unrenamed f20 via src3
    dut_if.set_fp_src3(20, 0xCAFE)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src3()
    expected = model.lookup_fp(20, 0xCAFE)
    check_lookup(result, expected, "FP f20 not renamed via src3")
    assert not result.renamed, "f20 should not be renamed"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_multiple_renames(dut: Any) -> None:
    """Test renaming multiple registers sequentially."""
    cocotb.log.info("=== Test: Multiple Renames ===")

    dut_if, model = await setup_test(dut)

    # Rename several INT registers
    renames = [(1, 0), (5, 3), (10, 7), (31, 15)]  # (reg, tag)
    for reg, tag in renames:
        dut_if.drive_rename(dest_rf=0, dest_reg=reg, rob_tag=tag)
        model.rename(dest_rf=0, dest_reg=reg, rob_tag=tag)
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        dut_if.clear_rename()

    # Verify all are renamed
    for reg, tag in renames:
        dut_if.set_int_src1(reg, reg * 100)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(reg, reg * 100)
        check_lookup(result, expected, f"INT x{reg}")
        assert result.renamed, f"x{reg} should be renamed"
        assert result.tag == tag, f"x{reg} tag mismatch"

    # x0 should still be hardwired zero
    dut_if.set_int_src1(0, 0xFFFF)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert not result.renamed, "x0 should not be renamed"
    assert result.value == 0, "x0 value should be 0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rename_overwrites_previous(dut: Any) -> None:
    """Test that a newer rename overwrites an older mapping."""
    cocotb.log.info("=== Test: Rename Overwrites Previous ===")

    dut_if, model = await setup_test(dut)

    # Rename x5 -> ROB[3]
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    # Verify tag 3
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.tag == 3

    # Rename x5 -> ROB[10] (overwrites)
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=10)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=10)

    # Verify tag 10
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x5 should still be renamed"
    assert result.tag == 10, f"x5 tag should be 10, got {result.tag}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_commit_clears_entry(dut: Any) -> None:
    """Test that commit clears RAT entry when tag matches."""
    cocotb.log.info("=== Test: Commit Clears Entry ===")

    dut_if, model = await setup_test(dut)

    # Rename x5 -> ROB[3]
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    # Verify renamed
    dut_if.set_int_src1(5, 0x42)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x5 should be renamed before commit"

    # Commit with matching tag
    await dut_if.commit(tag=3, dest_rf=0, dest_reg=5)
    model.commit(dest_rf=0, dest_reg=5, tag=3)

    # Verify no longer renamed
    dut_if.set_int_src1(5, 0x42)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x42)
    check_lookup(result, expected, "INT x5 after commit")
    assert not result.renamed, "x5 should not be renamed after commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_commit_tag_mismatch_preserves(dut: Any) -> None:
    """Test that commit with wrong tag preserves the RAT entry."""
    cocotb.log.info("=== Test: Commit Tag Mismatch Preserves ===")

    dut_if, model = await setup_test(dut)

    # Rename x5 -> ROB[3]
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    # Commit with WRONG tag (tag=7, not 3)
    await dut_if.commit(tag=7, dest_rf=0, dest_reg=5)
    model.commit(dest_rf=0, dest_reg=5, tag=7)

    # x5 should STILL be renamed with tag 3
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
    """Test that rename takes priority over commit to the same register.

    When both rename and commit target the same register in the same cycle,
    the new rename mapping should win.
    """
    cocotb.log.info("=== Test: Rename and Commit Same Cycle ===")

    dut_if, model = await setup_test(dut)

    # First rename x5 -> ROB[3]
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    # Now simultaneously: commit tag 3 from x5 AND rename x5 -> ROB[10]
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

    # x5 should be renamed with tag 10 (rename wins)
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
    """Test that flush_all clears all RAT entries and checkpoints."""
    cocotb.log.info("=== Test: Flush All Clears Everything ===")

    dut_if, model = await setup_test(dut)

    # Rename several registers
    for i in range(1, 8):
        await dut_if.rename(dest_rf=0, dest_reg=i, rob_tag=i)
        model.rename(dest_rf=0, dest_reg=i, rob_tag=i)

    for i in range(4):
        await dut_if.rename(dest_rf=1, dest_reg=i, rob_tag=i + 20)
        model.rename(dest_rf=1, dest_reg=i, rob_tag=i + 20)

    # Save a checkpoint
    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=5)
    model.checkpoint_save(checkpoint_id=0, branch_tag=5, ras_tos=0, ras_valid_count=0)

    # Verify some are renamed
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x5 should be renamed before flush"

    # Flush all
    await dut_if.flush_all()
    model.flush_all()

    # Verify all INT entries cleared
    for addr in [1, 5, 7, 31]:
        dut_if.set_int_src1(addr, addr * 10)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_int_src1()
        expected = model.lookup_int(addr, addr * 10)
        check_lookup(result, expected, f"INT x{addr} after flush")
        assert not result.renamed, f"x{addr} should not be renamed after flush"

    # Verify all FP entries cleared
    for addr in [0, 1, 3]:
        dut_if.set_fp_src1(addr, addr * 10)
        await RisingEdge(dut_if.clock)
        result = dut_if.read_fp_src1()
        expected = model.lookup_fp(addr, addr * 10)
        check_lookup(result, expected, f"FP f{addr} after flush")
        assert not result.renamed, f"f{addr} should not be renamed after flush"

    # All checkpoints should be free
    assert dut_if.checkpoint_available, "Checkpoint should be available after flush"
    assert dut_if.checkpoint_alloc_id == 0, "First free checkpoint should be 0"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fp_commit_clears_entry(dut: Any) -> None:
    """Test that FP commit clears the correct FP RAT entry."""
    cocotb.log.info("=== Test: FP Commit Clears Entry ===")

    dut_if, model = await setup_test(dut)

    # Rename f10 -> ROB[12]
    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=12)
    model.rename(dest_rf=1, dest_reg=10, rob_tag=12)

    # Verify renamed
    dut_if.set_fp_src1(10, 0x1234)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    assert result.renamed, "f10 should be renamed"

    # Commit FP with matching tag
    await dut_if.commit(tag=12, dest_rf=1, dest_reg=10)
    model.commit(dest_rf=1, dest_reg=10, tag=12)

    # Verify cleared
    dut_if.set_fp_src1(10, 0x1234)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    expected = model.lookup_fp(10, 0x1234)
    check_lookup(result, expected, "FP f10 after commit")
    assert not result.renamed, "f10 should not be renamed after commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_commit_no_dest_valid(dut: Any) -> None:
    """Test that commit with dest_valid=False does not clear any entry."""
    cocotb.log.info("=== Test: Commit No Dest Valid ===")

    dut_if, model = await setup_test(dut)

    # Rename x5 -> ROB[3]
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)

    # Commit with dest_valid=False (like a store commit)
    await dut_if.commit(tag=3, dest_rf=0, dest_reg=5, dest_valid=False)
    # Model: no commit action since dest_valid=False

    # x5 should still be renamed
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
    """Test checkpoint save and restore round-trip.

    Saves state, modifies RAT, restores, verifies original state.
    """
    cocotb.log.info("=== Test: Checkpoint Save and Restore ===")

    dut_if, model = await setup_test(dut)

    # Rename x5 -> ROB[3], x10 -> ROB[7]
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    await dut_if.rename(dest_rf=0, dest_reg=10, rob_tag=7)
    model.rename(dest_rf=0, dest_reg=10, rob_tag=7)

    # Save checkpoint 0
    await dut_if.checkpoint_save(
        checkpoint_id=0, branch_tag=10, ras_tos=2, ras_valid_count=5
    )
    model.checkpoint_save(checkpoint_id=0, branch_tag=10, ras_tos=2, ras_valid_count=5)

    # Modify RAT further (post-checkpoint renames)
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=20)
    model.rename(dest_rf=0, dest_reg=5, rob_tag=20)
    await dut_if.rename(dest_rf=0, dest_reg=15, rob_tag=25)
    model.rename(dest_rf=0, dest_reg=15, rob_tag=25)

    # Verify post-checkpoint state
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.tag == 20, "x5 tag should be 20 (post-checkpoint rename)"

    # Restore checkpoint 0
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()

    model.checkpoint_restore(0)

    # Verify restored state: x5 should have tag 3 (pre-checkpoint value)
    dut_if.set_int_src1(5, 0x42)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x42)
    check_lookup(result, expected, "INT x5 after restore")
    assert result.tag == 3, f"x5 tag should be 3 after restore, got {result.tag}"

    # x10 should still have tag 7 (was in checkpoint)
    dut_if.set_int_src2(10, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src2()
    expected = model.lookup_int(10, 0)
    check_lookup(result, expected, "INT x10 after restore")
    assert result.tag == 7, f"x10 tag should be 7 after restore, got {result.tag}"

    # x15 should NOT be renamed (was renamed post-checkpoint)
    dut_if.set_int_src1(15, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(15, 0)
    check_lookup(result, expected, "INT x15 after restore")
    assert not result.renamed, "x15 should not be renamed after restore"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_restore_ras_state(dut: Any) -> None:
    """Test that RAS state is correctly captured and restored in checkpoints."""
    cocotb.log.info("=== Test: Checkpoint Restore RAS State ===")

    dut_if, model = await setup_test(dut)

    # Save checkpoint with specific RAS state
    ras_tos = 5
    ras_valid_count = 7
    await dut_if.checkpoint_save(
        checkpoint_id=1, branch_tag=2, ras_tos=ras_tos, ras_valid_count=ras_valid_count
    )
    model.checkpoint_save(
        checkpoint_id=1, branch_tag=2, ras_tos=ras_tos, ras_valid_count=ras_valid_count
    )

    # Restore and check RAS state
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(1)
    await RisingEdge(dut_if.clock)
    # RAS outputs are combinational from the checkpoint RAM read
    actual_tos = dut_if.ras_tos
    actual_count = dut_if.ras_valid_count
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()

    assert (
        actual_tos == ras_tos
    ), f"RAS TOS mismatch: got {actual_tos}, expected {ras_tos}"
    assert (
        actual_count == ras_valid_count
    ), f"RAS valid count mismatch: got {actual_count}, expected {ras_valid_count}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_free(dut: Any) -> None:
    """Test that freeing a checkpoint makes it available again."""
    cocotb.log.info("=== Test: Checkpoint Free ===")

    dut_if, model = await setup_test(dut)

    # Allocate checkpoint 0
    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=5)
    model.checkpoint_save(checkpoint_id=0, branch_tag=5, ras_tos=0, ras_valid_count=0)

    # Checkpoint 0 should now be in use; next free should be 1
    await RisingEdge(dut_if.clock)
    assert (
        dut_if.checkpoint_available
    ), "Checkpoint should still be available (1-3 free)"
    assert dut_if.checkpoint_alloc_id == 1, "Next free should be 1"

    # Free checkpoint 0
    await dut_if.checkpoint_free(0)
    model.checkpoint_free(0)

    # Checkpoint 0 should be free again
    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_available, "Checkpoint should be available after free"
    assert dut_if.checkpoint_alloc_id == 0, "Next free should be 0 again"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_availability(dut: Any) -> None:
    """Test checkpoint availability priority encoder."""
    cocotb.log.info("=== Test: Checkpoint Availability ===")

    dut_if, model = await setup_test(dut)

    # Initially all free, alloc_id = 0
    assert dut_if.checkpoint_available
    assert dut_if.checkpoint_alloc_id == 0

    # Allocate 0
    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=1)
    model.checkpoint_save(0, 1, 0, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_alloc_id == 1, "Next free should be 1"

    # Allocate 1
    await dut_if.checkpoint_save(checkpoint_id=1, branch_tag=2)
    model.checkpoint_save(1, 2, 0, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_alloc_id == 2, "Next free should be 2"

    # Free 0, allocate 2
    await dut_if.checkpoint_free(0)
    model.checkpoint_free(0)
    await dut_if.checkpoint_save(checkpoint_id=2, branch_tag=3)
    model.checkpoint_save(2, 3, 0, 0)

    await RisingEdge(dut_if.clock)
    # 0 is free, 1 and 2 are in use
    assert dut_if.checkpoint_alloc_id == 0, "Next free should be 0 (freed earlier)"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_exhaustion(dut: Any) -> None:
    """Test that all 4 checkpoints can be allocated (exhaustion)."""
    cocotb.log.info("=== Test: Checkpoint Exhaustion ===")

    dut_if, model = await setup_test(dut)

    # Allocate all 4 checkpoints
    for i in range(NUM_CHECKPOINTS):
        await dut_if.checkpoint_save(checkpoint_id=i, branch_tag=i + 10)
        model.checkpoint_save(i, i + 10, 0, 0)

    await RisingEdge(dut_if.clock)
    assert not dut_if.checkpoint_available, "No checkpoint should be available"

    avail, _ = model.checkpoint_available()
    assert not avail, "Model should also show no checkpoints available"

    # Free one and verify availability returns
    await dut_if.checkpoint_free(2)
    model.checkpoint_free(2)
    await RisingEdge(dut_if.clock)
    assert dut_if.checkpoint_available, "Checkpoint 2 should be available after free"
    assert dut_if.checkpoint_alloc_id == 2, "Freed slot 2 should be next"  # type: ignore[unreachable]

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_restore_undoes_renames(dut: Any) -> None:
    """Test that checkpoint restore fully reverts to pre-checkpoint state.

    Specifically tests that registers renamed AFTER the checkpoint are
    cleared by the restore.
    """
    cocotb.log.info("=== Test: Checkpoint Restore Undoes Renames ===")

    dut_if, model = await setup_test(dut)

    # Initial state: x1 -> ROB[1]
    await dut_if.rename(dest_rf=0, dest_reg=1, rob_tag=1)
    model.rename(0, 1, 1)

    # Checkpoint 0 (captures x1 -> ROB[1], everything else clear)
    await dut_if.checkpoint_save(checkpoint_id=0, branch_tag=1)
    model.checkpoint_save(0, 1, 0, 0)

    # Post-checkpoint: rename x2->ROB[2], x3->ROB[3], f5->ROB[4]
    await dut_if.rename(dest_rf=0, dest_reg=2, rob_tag=2)
    model.rename(0, 2, 2)
    await dut_if.rename(dest_rf=0, dest_reg=3, rob_tag=3)
    model.rename(0, 3, 3)
    await dut_if.rename(dest_rf=1, dest_reg=5, rob_tag=4)
    model.rename(1, 5, 4)

    # Verify post-checkpoint state
    dut_if.set_int_src1(2, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_int_src1().renamed, "x2 should be renamed"

    dut_if.set_fp_src1(5, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_fp_src1().renamed, "f5 should be renamed"

    # Restore checkpoint 0
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()
    model.checkpoint_restore(0)

    # x1 should still be renamed (was in checkpoint)
    dut_if.set_int_src1(1, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed, "x1 should still be renamed after restore"
    assert result.tag == 1

    # x2, x3 should NOT be renamed (post-checkpoint)
    dut_if.set_int_src1(2, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_int_src1().renamed, "x2 should not be renamed after restore"

    dut_if.set_int_src1(3, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_int_src1().renamed, "x3 should not be renamed after restore"

    # f5 should NOT be renamed (post-checkpoint)
    dut_if.set_fp_src1(5, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_fp_src1().renamed, "f5 should not be renamed after restore"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_multiple_checkpoint_round_trips(dut: Any) -> None:
    """Test multiple checkpoint save/restore sequences."""
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
    assert (
        not dut_if.read_int_src1().renamed
    ), "x1 should not be renamed after first restore"

    # Free checkpoint 0
    await dut_if.checkpoint_free(0)
    model.checkpoint_free(0)

    # Round trip 2: save with some renames, modify more, restore
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=15)
    model.rename(0, 5, 15)

    await dut_if.checkpoint_save(
        checkpoint_id=1, branch_tag=15, ras_tos=3, ras_valid_count=6
    )
    model.checkpoint_save(1, 15, 3, 6)

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

    # x5 should have tag 15 (checkpoint value, not 20)
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert (
        result.renamed and result.tag == 15
    ), f"x5 should have tag 15, got {result.tag}"

    # f0 should NOT be renamed (post-checkpoint)
    dut_if.set_fp_src1(0, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_fp_src1().renamed, "f0 should not be renamed after restore"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_checkpoint_with_fp_state(dut: Any) -> None:
    """Test that checkpoint correctly captures and restores FP RAT state."""
    cocotb.log.info("=== Test: Checkpoint with FP State ===")

    dut_if, model = await setup_test(dut)

    # Rename several FP registers
    await dut_if.rename(dest_rf=1, dest_reg=0, rob_tag=1)
    model.rename(1, 0, 1)
    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=2)
    model.rename(1, 10, 2)
    await dut_if.rename(dest_rf=1, dest_reg=31, rob_tag=3)
    model.rename(1, 31, 3)

    # Checkpoint
    await dut_if.checkpoint_save(checkpoint_id=2, branch_tag=5)
    model.checkpoint_save(2, 5, 0, 0)

    # Modify FP RAT
    await dut_if.rename(dest_rf=1, dest_reg=0, rob_tag=20)
    model.rename(1, 0, 20)
    await dut_if.rename(dest_rf=1, dest_reg=10, rob_tag=21)
    model.rename(1, 10, 21)

    # Restore
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_restore(2)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_restore()
    model.checkpoint_restore(2)

    # Verify FP state restored
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
    """Test flush_all clears checkpoints too."""
    cocotb.log.info("=== Test: Flush All After Checkpoints ===")

    dut_if, model = await setup_test(dut)

    # Allocate all 4 checkpoints
    for i in range(NUM_CHECKPOINTS):
        await dut_if.checkpoint_save(checkpoint_id=i, branch_tag=i)
        model.checkpoint_save(i, i, 0, 0)

    assert not dut_if.checkpoint_available, "Should be exhausted"

    # Flush
    await dut_if.flush_all()
    model.flush_all()

    # All checkpoints should be free
    assert dut_if.checkpoint_available, "All checkpoints should be free after flush"
    assert dut_if.checkpoint_alloc_id == 0  # type: ignore[unreachable]

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# INT/FP Cross-Table Tests
# =============================================================================


@cocotb.test()
async def test_int_fp_independence(dut: Any) -> None:
    """Test that INT and FP tables are independent.

    Renaming x5 should not affect f5, and vice versa.
    """
    cocotb.log.info("=== Test: INT/FP Independence ===")

    dut_if, model = await setup_test(dut)

    # Rename x5 -> ROB[3]
    await dut_if.rename(dest_rf=0, dest_reg=5, rob_tag=3)
    model.rename(0, 5, 3)

    # f5 should NOT be renamed
    dut_if.set_fp_src1(5, 0xABCD)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_fp_src1()
    assert not result.renamed, "f5 should not be affected by x5 rename"

    # Rename f5 -> ROB[7]
    await dut_if.rename(dest_rf=1, dest_reg=5, rob_tag=7)
    model.rename(1, 5, 7)

    # Both should be renamed with different tags
    dut_if.set_int_src1(5, 0)
    dut_if.set_fp_src1(5, 0)
    await RisingEdge(dut_if.clock)

    int_result = dut_if.read_int_src1()
    fp_result = dut_if.read_fp_src1()

    assert int_result.renamed and int_result.tag == 3, "x5 should have tag 3"
    assert fp_result.renamed and fp_result.tag == 7, "f5 should have tag 7"

    # Commit x5 (INT) should not affect f5 (FP)
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
    """Test that regfile data is passed through correctly in lookup results.

    When a register is renamed, the value field still contains the regfile data.
    When not renamed, value contains the regfile data.
    When x0, value is always 0.
    """
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
    # Value should still be the regfile data (zero-extended to FLEN)
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
# Constrained Random Tests
# =============================================================================


@cocotb.test()
async def test_random_rename_commit_sequence(dut: Any) -> None:
    """Test random interleaving of renames and commits.

    Randomly renames and commits registers, verifying model matches DUT.
    """
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
    """Test random checkpoint save/restore/free with rename operations."""
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
            # Find a free slot
            avail, slot_id = model.checkpoint_available()
            if avail:
                branch_tag = random.randint(0, 31)
                ras_tos = random.randint(0, 7)
                ras_count = random.randint(0, 8)
                dut_if.drive_checkpoint_save(slot_id, branch_tag, ras_tos, ras_count)
                model.checkpoint_save(slot_id, branch_tag, ras_tos, ras_count)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_save()
            else:
                pass  # Skip if all checkpoints in use

        elif action == "checkpoint_free":
            # Find a valid slot to free
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
            # Find a valid slot to restore
            valid_slots = [
                i for i in range(NUM_CHECKPOINTS) if model.checkpoints[i].valid
            ]
            if valid_slots:
                slot_id = random.choice(valid_slots)
                dut_if.drive_checkpoint_restore(slot_id)
                model.checkpoint_restore(slot_id)
                await RisingEdge(dut_if.clock)
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
    assert (
        dut_if.checkpoint_available == avail_model
    ), f"Checkpoint available mismatch: DUT={dut_if.checkpoint_available}, model={avail_model}"
    if avail_model:
        assert (
            dut_if.checkpoint_alloc_id == id_model
        ), f"Checkpoint alloc_id mismatch: DUT={dut_if.checkpoint_alloc_id}, model={id_model}"

    cocotb.log.info(f"=== Test Passed ({num_ops} random ops, seed={seed}) ===")


@cocotb.test()
async def test_random_mixed_stress(dut: Any) -> None:
    """Stress test with all operation types including flush_all."""
    cocotb.log.info("=== Test: Random Mixed Stress ===")
    seed = log_random_seed()

    dut_if, model = await setup_test(dut)

    num_ops = 200

    for op in range(num_ops):
        r = random.random()

        if r < 0.30:
            # Rename INT
            reg = random.randint(1, 31)
            tag = random.randint(0, 31)
            dut_if.drive_rename(dest_rf=0, dest_reg=reg, rob_tag=tag)
            model.rename(0, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_rename()

        elif r < 0.45:
            # Rename FP
            reg = random.randint(0, 31)
            tag = random.randint(0, 31)
            dut_if.drive_rename(dest_rf=1, dest_reg=reg, rob_tag=tag)
            model.rename(1, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_rename()

        elif r < 0.65:
            # Commit
            rf = random.randint(0, 1)
            reg = random.randint(0 if rf == 1 else 1, 31)
            tag = random.randint(0, 31)
            dut_if.drive_commit(tag=tag, dest_rf=rf, dest_reg=reg)
            model.commit(rf, reg, tag)
            await RisingEdge(dut_if.clock)
            await FallingEdge(dut_if.clock)
            dut_if.clear_commit()

        elif r < 0.75:
            # Checkpoint save
            avail, slot_id = model.checkpoint_available()
            if avail:
                bt = random.randint(0, 31)
                rt = random.randint(0, 7)
                rc = random.randint(0, 8)
                dut_if.drive_checkpoint_save(slot_id, bt, rt, rc)
                model.checkpoint_save(slot_id, bt, rt, rc)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_save()

        elif r < 0.82:
            # Checkpoint free
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
            # Checkpoint restore
            valid_slots = [
                i for i in range(NUM_CHECKPOINTS) if model.checkpoints[i].valid
            ]
            if valid_slots:
                slot_id = random.choice(valid_slots)
                dut_if.drive_checkpoint_restore(slot_id)
                model.checkpoint_restore(slot_id)
                await RisingEdge(dut_if.clock)
                await FallingEdge(dut_if.clock)
                dut_if.clear_checkpoint_restore()

        else:
            # Flush all (~8% probability)
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

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

"""Integration tests for the Tomasulo wrapper (ROB + RAT + RS).

Ports the original rob_rat_wrapper tests and adds RS integration tests
exercising the full dispatch -> wakeup -> issue -> commit pipeline.
"""

import random
import re
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

from .tomasulo_interface import (
    TomasuloInterface,
    RS_INT,
    RS_MUL,
    RS_MEM,
    RS_FP,
    RS_FMUL,
    RS_FDIV,
)
from .tomasulo_model import TomasuloModel

from cocotb_tests.tomasulo.cdb_arbiter.cdb_arbiter_model import (
    CdbBroadcast,
    FU_ALU,
    FU_MUL,
    FU_DIV,
    FU_FP_ADD,
    FU_FP_MUL,
    FU_FP_DIV,
)
from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_model import (
    AllocationRequest,
    CDBWrite,
    BranchUpdate,
)
from cocotb_tests.tomasulo.register_alias_table.rat_model import (
    LookupResult,
)

NUM_CHECKPOINTS = 4


# ---------------------------------------------------------------------------
# Parse instr_op_e from riscv_pkg.sv so op values track the RTL source.
# ---------------------------------------------------------------------------
def _parse_instr_op_enum() -> dict[str, int]:
    """Parse the instr_op_e enum from riscv_pkg.sv and return name->value map.

    Handles both implicit sequential values and explicit assignments
    (e.g. ``FOO = 5``, ``BAR = 32'HDEAD_BEEF``).  Raises RuntimeError
    on parse failures so silent mis-numbering cannot occur.
    """
    pkg_path = (
        Path(__file__).resolve().parents[4]
        / "hw"
        / "rtl"
        / "cpu_and_mem"
        / "cpu"
        / "riscv_pkg.sv"
    )
    text = pkg_path.read_text()
    # Extract the enum body between 'typedef enum {' and '} instr_op_e;'
    m = re.search(r"typedef\s+enum\s*\{(.*?)\}\s*instr_op_e\s*;", text, re.DOTALL)
    if not m:
        raise RuntimeError("Could not find instr_op_e enum in riscv_pkg.sv")
    body = m.group(1)
    result: dict[str, int] = {}
    next_val = 0
    for line in body.splitlines():
        line = re.sub(r"//.*", "", line)  # strip comments
        line = re.sub(r"/\*.*?\*/", "", line)  # strip inline /* */
        line = line.strip().rstrip(",")
        if not line:
            continue
        # NAME = VALUE  (explicit assignment)
        # Supports: plain decimal (5), sized (8'd5, 32'hFF), unsized ('hFF),
        # octal (8'o17), binary (4'b1010), with optional _ separators.
        em = re.fullmatch(
            r"([A-Z_][A-Z0-9_]*)\s*=\s*(?:\d*'[bBdDhHoO])?([0-9a-fA-F_]+)",
            line,
        )
        if em:
            digits = em.group(2).replace("_", "")
            base = 10
            # Detect base from the format specifier preceding the digits
            bm = re.search(r"'([bBdDhHoO])", line)
            if bm:
                base = {"b": 2, "d": 10, "h": 16, "o": 8}[bm.group(1).lower()]
            try:
                next_val = int(digits, base)
            except ValueError as exc:
                raise RuntimeError(f"Cannot parse instr_op_e value: {line!r}") from exc
            result[em.group(1)] = next_val
            next_val += 1
            continue
        # NAME  (implicit sequential)
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", line):
            result[line] = next_val
            next_val += 1
            continue
        # Unrecognised non-blank line inside the enum — fail loudly
        raise RuntimeError(f"Cannot parse instr_op_e entry: {line!r}")
    if not result:
        raise RuntimeError("instr_op_e enum body is empty")
    return result


_INSTR_OPS = _parse_instr_op_enum()

OP_ADD = _INSTR_OPS["ADD"]
OP_SUB = _INSTR_OPS["SUB"]
OP_MUL = _INSTR_OPS["MUL"]
OP_MULH = _INSTR_OPS["MULH"]
OP_DIV = _INSTR_OPS["DIV"]
OP_DIVU = _INSTR_OPS["DIVU"]
OP_REM = _INSTR_OPS["REM"]
OP_LW = _INSTR_OPS["LW"]
OP_LB = _INSTR_OPS["LB"]
OP_SW = _INSTR_OPS["SW"]
OP_FLW = _INSTR_OPS["FLW"]

# RS depths (mirrors riscv_pkg parameters)
RS_DEPTHS = {
    RS_INT: 8,
    RS_MUL: 4,
    RS_MEM: 8,
    RS_FP: 6,
    RS_FMUL: 4,
    RS_FDIV: 2,
}

# All RS types for iteration
ALL_RS_TYPES = [RS_INT, RS_MUL, RS_MEM, RS_FP, RS_FMUL, RS_FDIV]
# RS types without integrated FU pipeline (safe for manual CDB completion)
MANUAL_CDB_RS_TYPES = [RS_MEM, RS_FP, RS_FMUL, RS_FDIV]
RS_NAMES = {
    RS_INT: "INT_RS",
    RS_MUL: "MUL_RS",
    RS_MEM: "MEM_RS",
    RS_FP: "FP_RS",
    RS_FMUL: "FMUL_RS",
    RS_FDIV: "FDIV_RS",
}


# =============================================================================
# Helpers
# =============================================================================


def make_int_req(
    pc: int = 0x1000,
    rd: int = 1,
    is_branch: bool = False,
    predicted_taken: bool = False,
    predicted_target: int = 0,
) -> AllocationRequest:
    """Create an integer register allocation request."""
    return AllocationRequest(
        pc=pc,
        dest_rf=0,
        dest_reg=rd,
        dest_valid=True,
        is_branch=is_branch,
        predicted_taken=predicted_taken,
        predicted_target=predicted_target,
    )


def make_fp_req(pc: int = 0x1000, fd: int = 1) -> AllocationRequest:
    """Create a floating-point register allocation request."""
    return AllocationRequest(pc=pc, dest_rf=1, dest_reg=fd, dest_valid=True)


def make_store_req(pc: int = 0x1000) -> AllocationRequest:
    """Create a store instruction allocation request."""
    return AllocationRequest(pc=pc, is_store=True, dest_valid=False)


def make_branch_req(
    pc: int = 0x1000,
    rd: int = 0,
    predicted_taken: bool = True,
    predicted_target: int = 0x2000,
) -> AllocationRequest:
    """Create a branch instruction allocation request."""
    return AllocationRequest(
        pc=pc,
        dest_rf=0,
        dest_reg=rd,
        dest_valid=(rd != 0),
        is_branch=True,
        predicted_taken=predicted_taken,
        predicted_target=predicted_target,
    )


def log_random_seed() -> int:
    """Generate, log, and return a random seed for reproducibility."""
    seed = random.getrandbits(32)
    random.seed(seed)
    cocotb.log.info(f"Random seed: {seed}")
    return seed


async def setup_test(dut: Any) -> tuple[TomasuloInterface, TomasuloModel]:
    """Initialize clock, interface, model and reset DUT."""
    clock = Clock(dut.i_clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    dut_if = TomasuloInterface(dut)
    model = TomasuloModel()
    await dut_if.reset_dut()
    return dut_if, model


def is_icarus(dut: Any) -> bool:
    """Return True if running under ICARUS (only INT_RS available).

    The ICARUS tomasulo_wrapper_tb only exposes flattened INT_RS ports;
    MUL/MEM/FP/FMUL/FDIV RS instances are only present in the Verilator
    (non-ICARUS) RTL path. Multi-RS tests should return early when True.
    """
    return hasattr(dut, "i_rs_dispatch_valid")


def check_rat_lookup(result: LookupResult, expected: LookupResult, label: str) -> None:
    """Assert RAT lookup result matches expected."""
    assert (
        result.renamed == expected.renamed
    ), f"{label}: renamed mismatch DUT={result.renamed} model={expected.renamed}"
    if expected.renamed:
        assert (
            result.tag == expected.tag
        ), f"{label}: tag mismatch DUT={result.tag} model={expected.tag}"


async def wait_for_commit(dut_if: TomasuloInterface, max_cycles: int = 20) -> dict:
    """Wait for a valid commit, raising TimeoutError if not seen."""
    for _ in range(max_cycles):
        await RisingEdge(dut_if.clock)
        commit = dut_if.read_commit()
        if commit["valid"]:
            await FallingEdge(dut_if.clock)
            return commit
    raise TimeoutError("No commit observed within timeout")


async def wait_for_cdb(dut_if: TomasuloInterface, max_cycles: int = 30) -> CdbBroadcast:
    """Wait for a valid CDB broadcast, raising TimeoutError if not seen."""
    for _ in range(max_cycles):
        await RisingEdge(dut_if.clock)
        await FallingEdge(dut_if.clock)
        cdb = dut_if.read_cdb_output()
        if cdb.valid:
            return cdb
    raise TimeoutError("No CDB broadcast observed within timeout")


# =============================================================================
# Ported ROB-RAT Tests (backward compatibility)
# =============================================================================


@cocotb.test()
async def test_dispatch_and_commit_clears_rat(dut: Any) -> None:
    """Commit bus wire: dispatch INT instr -> CDB write -> commit -> RAT cleared."""
    cocotb.log.info("=== Test: Dispatch and Commit Clears RAT ===")
    dut_if, model = await setup_test(dut)

    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    dut_if.set_int_src1(5, 0xAAAA)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert result.renamed and result.tag == tag

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag, value=0xDEADBEEF))
    model.cdb_write(CDBWrite(tag=tag, value=0xDEADBEEF))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["valid"] and commit["tag"] == tag

    dut_if.set_int_src1(5, 0xBBBB)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0xBBBB)
    check_rat_lookup(result, expected, "x5 after commit")
    assert not result.renamed

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_waw_commit_preserves_newer_rename(dut: Any) -> None:
    """Tag-match guard: dispatch A(x5,T0), dispatch B(x5,T1), commit A -> RAT still T1."""
    cocotb.log.info("=== Test: WAW Commit Preserves Newer Rename ===")
    dut_if, model = await setup_test(dut)

    req_a = make_int_req(pc=0x1000, rd=5)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)
    req_b = make_int_req(pc=0x1004, rd=5)
    tag_b = await dut_if.dispatch(req_b)
    model.dispatch(req_b)

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    model.cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    await wait_for_commit(dut_if)
    model.try_commit()

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after A commits")
    assert result.renamed and result.tag == tag_b

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rename_and_commit_same_cycle_priority(dut: Any) -> None:
    """Rename > commit on same register in same cycle."""
    cocotb.log.info("=== Test: Rename and Commit Same Cycle Priority ===")
    dut_if, model = await setup_test(dut)

    req_a = make_int_req(pc=0x1000, rd=5)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    model.cdb_write(CDBWrite(tag=tag_a, value=0x1111))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    req_b = make_int_req(pc=0x1004, rd=5)
    dut_if.drive_alloc_request(req_b)
    _, tag_b, _ = dut_if.read_alloc_response()
    dut_if.drive_rat_rename(0, 5, tag_b)
    model.dispatch(req_b)
    await RisingEdge(dut_if.clock)
    model.try_commit()
    await FallingEdge(dut_if.clock)
    dut_if.clear_alloc_request()
    dut_if.clear_rat_rename()

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after same-cycle rename+commit")
    assert result.renamed and result.tag == tag_b

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_checkpoint_save_and_correct_commit(dut: Any) -> None:
    """Full checkpoint lifecycle: save -> correct prediction -> commit frees checkpoint."""
    cocotb.log.info("=== Test: Branch Checkpoint Save and Correct Commit ===")
    dut_if, model = await setup_test(dut)

    req = make_branch_req(pc=0x1000, predicted_taken=True, predicted_target=0x2000)
    tag = await dut_if.dispatch(req, checkpoint_save=True)
    model.dispatch(req, checkpoint_save=True)

    await FallingEdge(dut_if.clock)
    update = BranchUpdate(tag=tag, taken=True, target=0x2000, mispredicted=False)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["valid"] and commit["has_checkpoint"] and not commit["misprediction"]

    cp_id = commit["checkpoint_id"]
    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_free(cp_id)
    model.rat.checkpoint_free(cp_id)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_free()

    assert dut_if.checkpoint_available

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_branch_misprediction_recovery(dut: Any) -> None:
    """Dispatch, checkpoint, post-branch renames, misprediction -> recover."""
    cocotb.log.info("=== Test: Branch Misprediction Recovery ===")
    dut_if, model = await setup_test(dut)

    req_pre = make_int_req(pc=0x1000, rd=5)
    tag_pre = await dut_if.dispatch(req_pre)
    model.dispatch(req_pre)

    req_br = make_branch_req(pc=0x1004, predicted_taken=True, predicted_target=0x3000)
    cp_id = dut_if.checkpoint_alloc_id
    tag_br = await dut_if.dispatch(req_br, checkpoint_save=True)
    model.dispatch(req_br, checkpoint_save=True)

    req_post = make_int_req(pc=0x3000, rd=5)
    await dut_if.dispatch(req_post)
    model.dispatch(req_post)

    await FallingEdge(dut_if.clock)
    update = BranchUpdate(tag=tag_br, taken=False, target=0x1008, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_branch_update()

    dut_if.drive_flush_en(tag_br)
    dut_if.drive_checkpoint_restore(cp_id)
    model.misprediction_recovery(cp_id, tag_br)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_flush_en()
    dut_if.clear_checkpoint_restore()

    assert dut_if.rob_count == 2

    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after recovery")
    assert result.renamed and result.tag == tag_pre

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_multiple_branches_checkpoint_exhaustion(dut: Any) -> None:
    """4 branches exhaust checkpoints."""
    cocotb.log.info("=== Test: Checkpoint Exhaustion ===")
    dut_if, model = await setup_test(dut)

    for i in range(NUM_CHECKPOINTS):
        req = make_branch_req(
            pc=0x1000 + i * 4, predicted_taken=True, predicted_target=0x2000 + i * 0x100
        )
        await dut_if.dispatch(req, checkpoint_save=True)
        model.dispatch(req, checkpoint_save=True)

    assert not dut_if.checkpoint_available

    await FallingEdge(dut_if.clock)
    dut_if.drive_checkpoint_free(0)
    model.rat.checkpoint_free(0)
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_checkpoint_free()
    assert dut_if.checkpoint_available

    cocotb.log.info("=== Test Passed ===")  # type: ignore[unreachable]


@cocotb.test()
async def test_full_flush_clears_all(dut: Any) -> None:
    """flush_all clears ROB + RAT + RS."""
    cocotb.log.info("=== Test: Full Flush Clears All ===")
    dut_if, model = await setup_test(dut)

    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Also put something in RS
    dut_if.drive_rs_dispatch(
        rob_tag=tag, op=0, src1_ready=False, src1_tag=10, src3_ready=True
    )
    model.rs_dispatch(rob_tag=tag, op=0, src1_ready=False, src1_tag=10, src3_ready=True)
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    assert not dut_if.rs_empty
    assert not dut_if.rob_empty

    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.rob_empty
    assert dut_if.rs_empty  # type: ignore[unreachable]
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_int_src1().renamed

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fp_dispatch_commit_clears_fp_rat(dut: Any) -> None:
    """FP dest_rf=1 propagates correctly through commit bus."""
    cocotb.log.info("=== Test: FP Dispatch/Commit Clears FP RAT ===")
    dut_if, model = await setup_test(dut)

    req = make_fp_req(pc=0x2000, fd=3)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    dut_if.set_fp_src1(3, 0)
    await RisingEdge(dut_if.clock)
    assert dut_if.read_fp_src1().renamed

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag, value=0x4000000000000000))
    model.cdb_write(CDBWrite(tag=tag, value=0x4000000000000000))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["dest_rf"] == 1

    dut_if.set_fp_src1(3, 0)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_fp_src1().renamed

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_store_commit_no_rat_effect(dut: Any) -> None:
    """dest_valid=0 prevents RAT modification for stores."""
    cocotb.log.info("=== Test: Store Commit No RAT Effect ===")
    dut_if, model = await setup_test(dut)

    req_alu = make_int_req(pc=0x1000, rd=5)
    tag_alu = await dut_if.dispatch(req_alu)
    model.dispatch(req_alu)

    req_st = make_store_req(pc=0x1004)
    tag_st = await dut_if.dispatch(req_st)
    model.dispatch(req_st)

    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_alu, value=0x1234))
    model.cdb_write(CDBWrite(tag=tag_alu, value=0x1234))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.drive_cdb_write(CDBWrite(tag=tag_st, value=0))
    model.cdb_write(CDBWrite(tag=tag_st, value=0))
    await RisingEdge(dut_if.clock)
    await FallingEdge(dut_if.clock)
    dut_if.clear_cdb_write()

    for _ in range(20):
        await RisingEdge(dut_if.clock)
        if dut_if.rob_empty:
            break
    await FallingEdge(dut_if.clock)

    while model.rob.can_commit():
        model.try_commit()

    assert dut_if.rob_empty

    dut_if.set_int_src1(5, 0x9999)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0x9999)
    check_rat_lookup(result, expected, "x5 after store commit")
    assert not result.renamed

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_x0_destination_invariant(dut: Any) -> None:
    """x0 remains hardwired zero."""
    cocotb.log.info("=== Test: x0 Destination Invariant ===")
    dut_if, model = await setup_test(dut)

    req = AllocationRequest(pc=0x1000, dest_rf=0, dest_reg=0, dest_valid=False)
    await dut_if.dispatch(req)
    model.dispatch(req)

    dut_if.set_int_src1(0, 0xFFFFFFFF)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    assert not result.renamed and result.value == 0

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# New RS Integration Tests
# =============================================================================


@cocotb.test()
async def test_dispatch_through_rob_rat_rs(dut: Any) -> None:
    """Dispatch allocates ROB tag, renames in RAT, dispatches to RS."""
    cocotb.log.info("=== Test: Dispatch Through ROB+RAT+RS ===")
    dut_if, model = await setup_test(dut)

    # Dispatch to ROB + RAT
    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Dispatch to RS with that tag, src1 ready, src2 pending
    dut_if.drive_rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=False,
        src2_tag=10,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=True,
        src1_value=0x1111,
        src2_ready=False,
        src2_tag=10,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    assert dut_if.rs_count == 1
    assert dut_if.rob_count == 1

    # RS should not issue (src2 not ready)
    dut_if.set_rs_fu_ready(True)
    assert not dut_if.rs_issue_valid

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_wakes_rs_and_completes_rob(dut: Any) -> None:
    """Single CDB broadcast simultaneously wakes RS and marks ROB done."""
    cocotb.log.info("=== Test: CDB Wakes RS and Completes ROB ===")
    dut_if, model = await setup_test(dut)

    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # RS entry: src1 waiting on some other tag
    dut_if.drive_rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=False,
        src1_tag=tag,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=False,
        src1_tag=tag,
        src2_ready=True,
        src2_value=0x2222,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # CDB broadcast: wakes RS src1 AND marks ROB entry done
    dut_if.drive_cdb(tag=tag, value=0xCAFE)
    model.cdb_write_and_snoop(tag=tag, value=0xCAFE)
    await dut_if.step()
    dut_if.clear_cdb()

    # RS should now be ready to issue
    dut_if.set_rs_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_rs_issue()
    assert issue["valid"], "RS should issue after CDB wakeup"
    assert issue["rob_tag"] == tag

    # ROB head should be done
    assert dut_if.head_done, "ROB head should be done after CDB"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_full_pipeline_cycle(dut: Any) -> None:
    """Dispatch -> RS wakeup via CDB -> RS issue -> CDB result -> commit."""
    cocotb.log.info("=== Test: Full Pipeline Cycle ===")
    dut_if, model = await setup_test(dut)

    # 0. Allocate producer entry whose result the consumer will wait on
    producer_req = make_store_req(pc=0x0F00)
    producer_tag = await dut_if.dispatch(producer_req)
    model.dispatch(producer_req)

    # 1. Dispatch consumer instruction to ROB + RAT + RS
    req = make_int_req(pc=0x1000, rd=7)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # RS dispatch: src1 not ready (waiting on producer)
    dut_if.drive_rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=False,
        src1_tag=producer_tag,
        src2_ready=True,
        src2_value=0x42,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=False,
        src1_tag=producer_tag,
        src2_ready=True,
        src2_value=0x42,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # 2. CDB from producer wakes RS src1 (also marks producer done in ROB)
    dut_if.drive_cdb_broadcast(tag=producer_tag, value=0xAAAA)
    model.cdb_snoop(tag=producer_tag, value=0xAAAA)
    await dut_if.step()
    dut_if.clear_cdb_broadcast()

    # 2.5 Commit producer (ROB head, in-order commit)
    commit_prod = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit_prod["valid"] and commit_prod["tag"] == producer_tag

    # 3. RS issues
    dut_if.set_rs_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_rs_issue()
    assert issue["valid"], "RS should issue"
    assert issue["rob_tag"] == tag
    model_issue = model.rs_try_issue(fu_ready=True)
    assert model_issue is not None

    await dut_if.step()
    assert dut_if.rs_empty, "RS should be empty after issue"

    # 4. ALU pipeline auto-completed: ADD(0xAAAA, 0x42) -> CDB -> ROB done
    alu_result = (0xAAAA + 0x42) & 0xFFFFFFFF
    model.cdb_write(CDBWrite(tag=tag, value=alu_result))

    # 5. ROB commits -> RAT clears
    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["valid"] and commit["tag"] == tag

    dut_if.set_int_src1(7, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(7, 0)
    check_rat_lookup(result, expected, "x7 after full pipeline")
    assert not result.renamed, "x7 should be cleared after commit"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_flush_coherence_across_modules(dut: Any) -> None:
    """Partial flush invalidates RS and ROB entries, restores RAT checkpoint."""
    cocotb.log.info("=== Test: Flush Coherence Across Modules ===")
    dut_if, model = await setup_test(dut)

    # Pre-branch instruction
    req_pre = make_int_req(pc=0x1000, rd=5)
    tag_pre = await dut_if.dispatch(req_pre)
    model.dispatch(req_pre)

    # Branch with checkpoint
    req_br = make_branch_req(pc=0x1004, predicted_taken=True, predicted_target=0x3000)
    cp_id = dut_if.checkpoint_alloc_id
    tag_br = await dut_if.dispatch(req_br, checkpoint_save=True)
    model.dispatch(req_br, checkpoint_save=True)

    # Post-branch instruction dispatched to RS too
    req_post = make_int_req(pc=0x3000, rd=5)
    tag_post = await dut_if.dispatch(req_post)
    model.dispatch(req_post)

    # RS dispatch for post-branch instruction
    dut_if.drive_rs_dispatch(
        rob_tag=tag_post,
        op=0,
        src1_ready=True,
        src1_value=0x1,
        src2_ready=True,
        src2_value=0x2,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag_post,
        op=0,
        src1_ready=True,
        src1_value=0x1,
        src2_ready=True,
        src2_value=0x2,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    assert dut_if.rs_count == 1

    # Branch mispredicts
    update = BranchUpdate(tag=tag_br, taken=False, target=0x1008, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await dut_if.step()
    dut_if.clear_branch_update()

    # Partial flush + checkpoint restore
    dut_if.drive_flush_en(tag_br)
    dut_if.drive_checkpoint_restore(cp_id)
    model.misprediction_recovery(cp_id, tag_br)
    await dut_if.step()
    dut_if.clear_flush_en()
    dut_if.clear_checkpoint_restore()

    # RS should be empty (post-branch entry flushed)
    assert dut_if.rs_empty, "RS should be empty after partial flush"
    # ROB should have 2 (pre-branch + branch)
    assert dut_if.rob_count == 2
    # RAT restored
    dut_if.set_int_src1(5, 0)
    await RisingEdge(dut_if.clock)
    result = dut_if.read_int_src1()
    expected = model.lookup_int(5, 0)
    check_rat_lookup(result, expected, "x5 after flush")
    assert result.renamed and result.tag == tag_pre

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rs_full_stalls_dispatch(dut: Any) -> None:
    """RS full signal prevents further dispatch."""
    cocotb.log.info("=== Test: RS Full Stalls Dispatch ===")
    dut_if, model = await setup_test(dut)

    # Fill RS with 8 entries
    for i in range(8):
        dut_if.drive_rs_dispatch(
            rob_tag=i,
            op=0,
            src1_ready=False,
            src1_tag=20,
            src2_ready=False,
            src2_tag=21,
            src3_ready=True,
        )
        model.rs_dispatch(
            rob_tag=i,
            op=0,
            src1_ready=False,
            src1_tag=20,
            src2_ready=False,
            src2_tag=21,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_rs_dispatch()

    assert dut_if.rs_full, "RS should be full"
    assert model.rs.is_full()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_rob_bypass_read_with_rs_state(dut: Any) -> None:
    """ROB bypass read and RS state consistency."""
    cocotb.log.info("=== Test: ROB Bypass Read with RS State ===")
    dut_if, model = await setup_test(dut)

    req = make_int_req(pc=0x1000, rd=8)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Put in RS
    dut_if.drive_rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=True,
        src1_value=0x100,
        src2_ready=True,
        src2_value=0x200,
        src3_ready=True,
    )
    model.rs_dispatch(
        rob_tag=tag,
        op=0,
        src1_ready=True,
        src1_value=0x100,
        src2_ready=True,
        src2_value=0x200,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # RS has the entry, ROB entry is NOT done yet
    dut_if.set_read_tag(tag)
    await RisingEdge(dut_if.clock)
    assert not dut_if.read_entry_done(), "ROB entry should not be done yet"

    # Issue from RS
    dut_if.set_rs_fu_ready(True)
    await Timer(1, unit="ps")  # Let combinational logic settle
    issue = dut_if.read_rs_issue()
    assert issue["valid"], "RS should issue"

    await dut_if.step()
    assert dut_if.rs_empty

    # ALU pipeline auto-completed the entry: ADD(0x100, 0x200) = 0x300.
    # CDB write latched on this step's rising edge — entry is done.
    # Check bypass at falling edge (before commit fires on next rising edge).
    alu_result = (0x100 + 0x200) & 0xFFFFFFFF
    model.cdb_write(CDBWrite(tag=tag, value=alu_result))

    dut_if.set_read_tag(tag)
    await Timer(1, unit="ps")  # Combinational settle
    assert dut_if.read_entry_done(), "ROB entry should be done now"
    assert dut_if.read_entry_value() == alu_result

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_random_dispatch_execute_commit(dut: Any) -> None:
    """Constrained random: dispatch, RS dispatch, CDB, issue, commit, flush."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Random MEM_RS test requires Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: Random Dispatch/Execute/Commit ===")
    seed = log_random_seed()
    dut_if, model = await setup_test(dut)

    # Use MEM_RS for random testing — INT_RS and MUL_RS have integrated FU
    # pipelines that auto-complete entries, conflicting with manual CDB drives.
    dut_if.set_fu_ready(RS_MEM, True)
    await Timer(1, unit="ps")  # Let fu_ready propagate
    num_dispatches = 0
    prev_was_flush = False
    pending_tags: set[int] = set()  # Track valid ROB tags for safe CDB

    for cycle in range(200):
        # Read DUT state BEFORE try_issue (matches RTL's registered state)
        dut_rob_full = dut_if.rob_full
        dut_rs_full = dut_if.rs_full_for(RS_MEM)

        # Check RS issue from settled state (skip after flush cycles)
        if not prev_was_flush:
            issue = dut_if.read_rs_issue_for(RS_MEM)
            model_issue = model.rs_try_issue(rs_type=RS_MEM, fu_ready=True)
            if model_issue is not None:
                assert issue["valid"], f"Cycle {cycle}: model issued but DUT did not"

        # Auto-commit ROB head if done (one per cycle, matching DUT rate)
        c = model.try_commit()
        if c is not None and c["valid"]:
            pending_tags.discard(c["tag"])

        r = random.random()
        prev_was_flush = False

        # Dispatch + RS dispatch (~35%)
        # Drive ROB alloc + RAT rename + RS dispatch all before a SINGLE
        # clock edge so the DUT processes them atomically (avoids the extra
        # edge that dut_if.dispatch() would introduce).
        if r < 0.35 and not dut_rob_full and not dut_rs_full:
            ready, tag, _ = dut_if.read_alloc_response()
            if ready:
                rd = random.randint(1, 31)
                req = make_int_req(pc=0x1000 + num_dispatches * 4, rd=rd)

                # Drive ROB alloc + RAT rename
                dut_if.drive_alloc_request(req)
                if req.dest_valid:
                    dut_if.drive_rat_rename(req.dest_rf, req.dest_reg, tag)
                model.dispatch(req)
                pending_tags.add(tag)

                # Drive RS dispatch to MEM_RS in the same cycle
                src1_ready = random.choice([True, False])
                src2_ready = random.choice([True, False])
                src1_tag = random.randint(0, 31)
                src2_tag = random.randint(0, 31)
                src1_value = random.getrandbits(64) if src1_ready else 0
                src2_value = random.getrandbits(64) if src2_ready else 0

                dut_if.drive_rs_dispatch(
                    rs_type=RS_MEM,
                    rob_tag=tag,
                    op=0,
                    src1_ready=src1_ready,
                    src1_tag=src1_tag,
                    src1_value=src1_value,
                    src2_ready=src2_ready,
                    src2_tag=src2_tag,
                    src2_value=src2_value,
                    src3_ready=True,
                )
                model.rs_dispatch(
                    rs_type=RS_MEM,
                    rob_tag=tag,
                    op=0,
                    src1_ready=src1_ready,
                    src1_tag=src1_tag,
                    src1_value=src1_value,
                    src2_ready=src2_ready,
                    src2_tag=src2_tag,
                    src2_value=src2_value,
                    src3_ready=True,
                )
                await dut_if.step()
                dut_if.clear_alloc_request()
                dut_if.clear_rat_rename()
                dut_if.clear_rs_dispatch()
                num_dispatches += 1
            else:
                await dut_if.step()

        # CDB broadcast to a valid ROB entry (~30%)
        elif r < 0.65 and pending_tags:
            cdb_tag = random.choice(list(pending_tags))
            cdb_value = random.getrandbits(64)
            dut_if.drive_cdb(tag=cdb_tag, value=cdb_value)
            model.cdb_write_and_snoop(tag=cdb_tag, value=cdb_value)
            pending_tags.discard(cdb_tag)  # An instruction completes only once
            await dut_if.step()
            dut_if.clear_cdb()

        # Flush all (~5%)
        elif r < 0.70:
            prev_was_flush = True
            dut_if.drive_flush_all()
            model.flush_all()
            pending_tags.clear()
            await dut_if.step()
            dut_if.clear_flush_all()

        # Idle (~30%)
        else:
            await dut_if.step()

    # Final: flush and verify clean state
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.rob_empty
    assert dut_if.rs_empty_for(RS_MEM)

    cocotb.log.info(f"=== Test Passed ({num_dispatches} dispatches, seed={seed}) ===")


# =============================================================================
# Multi-RS Integration Tests (Week 6-7: all 6 RS types)
# =============================================================================


@cocotb.test()
async def test_dispatch_routes_to_each_rs_type(dut: Any) -> None:
    """Dispatch with each rs_type routes entry only to the targeted RS."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: Dispatch Routes to Each RS Type ===")
    dut_if, model = await setup_test(dut)

    for rs_type in ALL_RS_TYPES:
        name = RS_NAMES[rs_type]

        # Dispatch a ROB entry (needed for valid tags)
        req = make_int_req(pc=0x1000 + rs_type * 4, rd=1 + rs_type)
        tag = await dut_if.dispatch(req)
        model.dispatch(req)

        # RS dispatch targeting this RS type
        dut_if.drive_rs_dispatch(
            rs_type=rs_type,
            rob_tag=tag,
            op=rs_type,
            src1_ready=True,
            src1_value=0x100 + rs_type,
            src2_ready=True,
            src2_value=0x200 + rs_type,
            src3_ready=True,
        )
        model.rs_dispatch(
            rs_type=rs_type,
            rob_tag=tag,
            op=rs_type,
            src1_ready=True,
            src1_value=0x100 + rs_type,
            src2_ready=True,
            src2_value=0x200 + rs_type,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_rs_dispatch()

        # Verify targeted RS got the entry
        assert (
            dut_if.rs_count_for(rs_type) == 1
        ), f"{name}: count should be 1 after dispatch, got {dut_if.rs_count_for(rs_type)}"
        assert not dut_if.rs_empty_for(rs_type), f"{name}: should not be empty"

        # Verify all OTHER RS types are still empty
        for other in ALL_RS_TYPES:
            if other != rs_type and other < rs_type:
                # Already has 1 entry from its own dispatch
                pass
            elif other != rs_type and other > rs_type:
                assert dut_if.rs_empty_for(
                    other
                ), f"{RS_NAMES[other]}: should be empty after dispatch to {name}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_cdb_broadcast_wakes_all_rs_types(dut: Any) -> None:
    """CDB broadcast simultaneously wakes pending sources across all RS types."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: CDB Broadcast Wakes All RS Types ===")
    dut_if, model = await setup_test(dut)

    # Use a common producer tag that entries in each RS will wait on
    producer_tag = 0

    # Dispatch one entry per RS type, all waiting on the same producer tag
    tags = {}
    for rs_type in ALL_RS_TYPES:
        req = make_int_req(pc=0x1000 + rs_type * 4, rd=1 + rs_type)
        tag = await dut_if.dispatch(req)
        model.dispatch(req)
        tags[rs_type] = tag

        dut_if.drive_rs_dispatch(
            rs_type=rs_type,
            rob_tag=tag,
            op=0,
            src1_ready=False,
            src1_tag=producer_tag,
            src2_ready=True,
            src2_value=0x42,
            src3_ready=True,
        )
        model.rs_dispatch(
            rs_type=rs_type,
            rob_tag=tag,
            op=0,
            src1_ready=False,
            src1_tag=producer_tag,
            src2_ready=True,
            src2_value=0x42,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_rs_dispatch()

    # No RS should issue yet (src1 not ready)
    for rs_type in ALL_RS_TYPES:
        dut_if.set_fu_ready(rs_type, True)
    await Timer(1, unit="ps")
    for rs_type in ALL_RS_TYPES:
        assert not dut_if.rs_issue_valid_for(
            rs_type
        ), f"{RS_NAMES[rs_type]}: should not issue before CDB wakeup"

    # CDB broadcast from producer
    dut_if.drive_cdb_broadcast(tag=producer_tag, value=0xAAAA)
    model.cdb_snoop(tag=producer_tag, value=0xAAAA)
    await dut_if.step()
    dut_if.clear_cdb_broadcast()

    # Now all RS should be ready to issue
    await Timer(1, unit="ps")
    for rs_type in ALL_RS_TYPES:
        issue = dut_if.read_rs_issue_for(rs_type)
        model_issue = model.rs_try_issue(rs_type=rs_type, fu_ready=True)
        assert issue["valid"], f"{RS_NAMES[rs_type]}: should issue after CDB wakeup"
        assert model_issue is not None
        assert (
            issue["rob_tag"] == tags[rs_type]
        ), f"{RS_NAMES[rs_type]}: wrong tag in issued entry"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_per_rs_full_independence(dut: Any) -> None:
    """Filling one RS does not affect fullness of other RS types."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: Per-RS Full Independence ===")
    dut_if, model = await setup_test(dut)

    # Fill FDIV_RS (depth 2 -- smallest, quickest to fill)
    for i in range(RS_DEPTHS[RS_FDIV]):
        dut_if.drive_rs_dispatch(
            rs_type=RS_FDIV,
            rob_tag=i,
            op=0,
            src1_ready=False,
            src1_tag=20,
            src2_ready=True,
            src3_ready=True,
        )
        model.rs_dispatch(
            rs_type=RS_FDIV,
            rob_tag=i,
            op=0,
            src1_ready=False,
            src1_tag=20,
            src2_ready=True,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_rs_dispatch()

    # FDIV_RS should be full (dedicated o_fdiv_rs_full output)
    assert dut_if.rs_full_for(RS_FDIV), "FDIV_RS should be full"
    assert model.get_rs(RS_FDIV).is_full()

    # All other RS types should still be empty and not full
    for rs_type in ALL_RS_TYPES:
        if rs_type != RS_FDIV:
            assert dut_if.rs_empty_for(
                rs_type
            ), f"{RS_NAMES[rs_type]}: should be empty when FDIV_RS is full"
            assert not dut_if.rs_full_for(
                rs_type
            ), f"{RS_NAMES[rs_type]}: should not be full when FDIV_RS is full"

    # Verify o_rs_full dispatch-target mux: targeting FDIV shows full
    dut_if.drive_rs_dispatch(
        rs_type=RS_FDIV,
        rob_tag=10,
        op=0,
        src1_ready=True,
        src2_ready=True,
        src3_ready=True,
    )
    await Timer(1, unit="ps")
    assert dut_if.dispatch_target_rs_full, "o_rs_full mux should show FDIV full"
    dut_if.clear_rs_dispatch()

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_flush_all_clears_all_rs_types(dut: Any) -> None:
    """flush_all empties every RS type."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: Flush All Clears All RS Types ===")
    dut_if, model = await setup_test(dut)

    # Put one entry into each RS type
    for rs_type in ALL_RS_TYPES:
        dut_if.drive_rs_dispatch(
            rs_type=rs_type,
            rob_tag=rs_type,
            op=0,
            src1_ready=False,
            src1_tag=20,
            src2_ready=True,
            src3_ready=True,
        )
        model.rs_dispatch(
            rs_type=rs_type,
            rob_tag=rs_type,
            op=0,
            src1_ready=False,
            src1_tag=20,
            src2_ready=True,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_rs_dispatch()

    # All RS should have 1 entry
    for rs_type in ALL_RS_TYPES:
        assert (
            dut_if.rs_count_for(rs_type) == 1
        ), f"{RS_NAMES[rs_type]}: should have 1 entry"

    # Flush all
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    # All RS should be empty
    for rs_type in ALL_RS_TYPES:
        assert dut_if.rs_empty_for(
            rs_type
        ), f"{RS_NAMES[rs_type]}: should be empty after flush_all"
        assert dut_if.rs_count_for(rs_type) == 0

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_partial_flush_across_all_rs(dut: Any) -> None:
    """Partial flush invalidates younger entries in ALL RS types."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: Partial Flush Across All RS ===")
    dut_if, model = await setup_test(dut)

    # Dispatch pre-branch instruction (ROB tag 0)
    req_pre = make_int_req(pc=0x1000, rd=5)
    await dut_if.dispatch(req_pre)
    model.dispatch(req_pre)

    # Branch with checkpoint (ROB tag 1)
    req_br = make_branch_req(pc=0x1004, predicted_taken=True, predicted_target=0x3000)
    cp_id = dut_if.checkpoint_alloc_id
    tag_br = await dut_if.dispatch(req_br, checkpoint_save=True)
    model.dispatch(req_br, checkpoint_save=True)

    # Dispatch post-branch entries into multiple RS types
    post_tags = {}
    for rs_type in [RS_INT, RS_MUL, RS_MEM]:
        req_post = make_int_req(pc=0x3000 + rs_type * 4, rd=10 + rs_type)
        tag_post = await dut_if.dispatch(req_post)
        model.dispatch(req_post)
        post_tags[rs_type] = tag_post

        dut_if.drive_rs_dispatch(
            rs_type=rs_type,
            rob_tag=tag_post,
            op=0,
            src1_ready=True,
            src1_value=0x1,
            src2_ready=True,
            src2_value=0x2,
            src3_ready=True,
        )
        model.rs_dispatch(
            rs_type=rs_type,
            rob_tag=tag_post,
            op=0,
            src1_ready=True,
            src1_value=0x1,
            src2_ready=True,
            src2_value=0x2,
            src3_ready=True,
        )
        await dut_if.step()
        dut_if.clear_rs_dispatch()

    # Verify entries exist in all three RS
    for rs_type in [RS_INT, RS_MUL, RS_MEM]:
        assert (
            dut_if.rs_count_for(rs_type) == 1
        ), f"{RS_NAMES[rs_type]}: should have 1 entry"

    # Misprediction: partial flush + checkpoint restore
    update = BranchUpdate(tag=tag_br, taken=False, target=0x1008, mispredicted=True)
    dut_if.drive_branch_update(update)
    model.branch_update(update)
    await dut_if.step()
    dut_if.clear_branch_update()

    dut_if.drive_flush_en(tag_br)
    dut_if.drive_checkpoint_restore(cp_id)
    model.misprediction_recovery(cp_id, tag_br)
    await dut_if.step()
    dut_if.clear_flush_en()
    dut_if.clear_checkpoint_restore()

    # All post-branch RS entries should be flushed
    for rs_type in [RS_INT, RS_MUL, RS_MEM]:
        assert dut_if.rs_empty_for(
            rs_type
        ), f"{RS_NAMES[rs_type]}: should be empty after partial flush"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_fmul_rs_three_source_fma(dut: Any) -> None:
    """FMUL_RS with 3 source operands (FMA), rounding mode, and CDB wakeup."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: FMUL_RS Three-Source FMA ===")
    dut_if, model = await setup_test(dut)

    # Allocate producer entry whose result the FMA will wait on (src3)
    producer_req = make_store_req(pc=0x1F00)
    producer_tag = await dut_if.dispatch(producer_req)
    model.dispatch(producer_req)

    # Dispatch FP instruction to ROB
    req = make_fp_req(pc=0x2000, fd=4)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # FMA dispatch to FMUL_RS: src1 ready, src2 ready, src3 pending (addend)
    fma_rm = 0b001  # RTZ rounding mode
    dut_if.drive_rs_dispatch(
        rs_type=RS_FMUL,
        rob_tag=tag,
        op=0x10,  # FMA opcode
        src1_ready=True,
        src1_value=0x3FF0000000000000,  # 1.0 double
        src2_ready=True,
        src2_value=0x4000000000000000,  # 2.0 double
        src3_ready=False,
        src3_tag=producer_tag,  # Waiting on producer
        rm=fma_rm,
    )
    model.rs_dispatch(
        rs_type=RS_FMUL,
        rob_tag=tag,
        op=0x10,
        src1_ready=True,
        src1_value=0x3FF0000000000000,
        src2_ready=True,
        src2_value=0x4000000000000000,
        src3_ready=False,
        src3_tag=producer_tag,
        rm=fma_rm,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    assert dut_if.rs_count_for(RS_FMUL) == 1

    # Should not issue yet (src3 not ready)
    dut_if.set_fu_ready(RS_FMUL, True)
    await Timer(1, unit="ps")
    assert not dut_if.rs_issue_valid_for(RS_FMUL), "Should not issue without src3"

    # CDB wakes src3 (also marks producer done in ROB)
    dut_if.drive_cdb_broadcast(tag=producer_tag, value=0x4008000000000000)  # 3.0 double
    model.cdb_snoop(tag=producer_tag, value=0x4008000000000000)
    await dut_if.step()
    dut_if.clear_cdb_broadcast()

    # Now it should issue
    await Timer(1, unit="ps")
    issue = dut_if.read_rs_issue_for(RS_FMUL)
    model_issue = model.rs_try_issue(rs_type=RS_FMUL, fu_ready=True)
    assert issue["valid"], "FMUL_RS should issue after src3 CDB wakeup"
    assert model_issue is not None
    assert issue["rob_tag"] == tag
    assert issue["rm"] == fma_rm, f"Rounding mode mismatch: {issue['rm']} != {fma_rm}"
    assert issue["src1_value"] == 0x3FF0000000000000
    assert issue["src2_value"] == 0x4000000000000000
    assert issue["src3_value"] == 0x4008000000000000

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_mixed_dispatch_and_issue_across_rs(dut: Any) -> None:
    """Dispatch to multiple RS types, issue from each independently."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: Mixed Dispatch and Issue Across RS ===")
    dut_if, model = await setup_test(dut)

    # Dispatch instructions to INT_RS and MEM_RS with sources ready
    req_int = make_int_req(pc=0x1000, rd=1)
    tag_int = await dut_if.dispatch(req_int)
    model.dispatch(req_int)

    dut_if.drive_rs_dispatch(
        rs_type=RS_INT,
        rob_tag=tag_int,
        op=0x01,
        src1_ready=True,
        src1_value=0xAA,
        src2_ready=True,
        src2_value=0xBB,
        src3_ready=True,
    )
    model.rs_dispatch(
        rs_type=RS_INT,
        rob_tag=tag_int,
        op=0x01,
        src1_ready=True,
        src1_value=0xAA,
        src2_ready=True,
        src2_value=0xBB,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    req_mem = make_int_req(pc=0x1004, rd=2)
    tag_mem = await dut_if.dispatch(req_mem)
    model.dispatch(req_mem)

    dut_if.drive_rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag_mem,
        op=0x02,
        src1_ready=True,
        src1_value=0xCC,
        src2_ready=True,
        src2_value=0xDD,
        src3_ready=True,
        is_fp_mem=True,
        mem_size=2,
        mem_signed=True,
    )
    model.rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag_mem,
        op=0x02,
        src1_ready=True,
        src1_value=0xCC,
        src2_ready=True,
        src2_value=0xDD,
        src3_ready=True,
        is_fp_mem=True,
        mem_size=2,
        mem_signed=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # Issue from INT_RS only (MEM_RS fu_ready=0)
    dut_if.set_fu_ready(RS_INT, True)
    dut_if.set_fu_ready(RS_MEM, False)
    await Timer(1, unit="ps")

    int_issue = dut_if.read_rs_issue_for(RS_INT)
    assert int_issue["valid"], "INT_RS should issue"
    assert int_issue["rob_tag"] == tag_int
    assert int_issue["op"] == 0x01

    mem_issue = dut_if.read_rs_issue_for(RS_MEM)
    assert not mem_issue["valid"], "MEM_RS should not issue (fu_ready=0)"

    model.rs_try_issue(rs_type=RS_INT, fu_ready=True)

    await dut_if.step()
    assert dut_if.rs_empty_for(RS_INT), "INT_RS should be empty after issue"
    assert dut_if.rs_count_for(RS_MEM) == 1, "MEM_RS should still have 1 entry"

    # Now issue from MEM_RS
    dut_if.set_fu_ready(RS_MEM, True)
    await Timer(1, unit="ps")

    mem_issue = dut_if.read_rs_issue_for(RS_MEM)
    model_mem_issue = model.rs_try_issue(rs_type=RS_MEM, fu_ready=True)
    assert mem_issue["valid"], "MEM_RS should issue now"
    assert mem_issue["rob_tag"] == tag_mem
    assert mem_issue["is_fp_mem"], "is_fp_mem should be set"
    assert mem_issue["mem_size"] == 2
    assert mem_issue["mem_signed"], "mem_signed should be set"
    assert model_mem_issue is not None

    await dut_if.step()
    assert dut_if.rs_empty_for(RS_MEM), "MEM_RS should be empty after issue"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_random_multi_rs_dispatch_execute_commit(dut: Any) -> None:
    """Constrained random with dispatch routed across all 6 RS types."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: Random Multi-RS Dispatch/Execute/Commit ===")
    seed = log_random_seed()
    dut_if, model = await setup_test(dut)

    dut_if.set_all_fu_ready(True)
    await Timer(1, unit="ps")
    num_dispatches = 0
    prev_was_flush = False
    pending_tags: set[int] = set()

    for cycle in range(300):
        dut_rob_full = dut_if.rob_full

        # Check RS issue from each type (skip after flush)
        # Only check RS types without integrated FU pipeline (INT_RS and
        # MUL_RS auto-complete via ALU/MUL/DIV and aren't manually driven).
        if not prev_was_flush:
            for rs_type in MANUAL_CDB_RS_TYPES:
                issue = dut_if.read_rs_issue_for(rs_type)
                model_issue = model.rs_try_issue(rs_type=rs_type, fu_ready=True)
                if model_issue is not None:
                    assert issue[
                        "valid"
                    ], f"Cycle {cycle}: {RS_NAMES[rs_type]} model issued but DUT did not"

        # Auto-commit ROB head
        c = model.try_commit()
        if c is not None and c["valid"]:
            pending_tags.discard(c["tag"])

        r = random.random()
        prev_was_flush = False

        # Dispatch to random RS type (~35%) — skip INT_RS and MUL_RS since
        # their FU pipelines auto-complete, conflicting with manual CDB drives.
        if r < 0.35 and not dut_rob_full:
            # Pick a random RS type and check if it's full
            rs_type = random.choice(MANUAL_CDB_RS_TYPES)
            if dut_if.rs_full_for(rs_type):
                await dut_if.step()
                continue

            ready, tag, _ = dut_if.read_alloc_response()
            if ready:
                rd = random.randint(1, 31)
                req = make_int_req(pc=0x1000 + num_dispatches * 4, rd=rd)

                dut_if.drive_alloc_request(req)
                if req.dest_valid:
                    dut_if.drive_rat_rename(req.dest_rf, req.dest_reg, tag)
                model.dispatch(req)
                pending_tags.add(tag)

                src1_ready = random.choice([True, False])
                src2_ready = random.choice([True, False])
                src3_ready = random.choice([True, False])
                src1_tag = random.randint(0, 31)
                src2_tag = random.randint(0, 31)
                src3_tag = random.randint(0, 31)
                src1_value = random.getrandbits(64) if src1_ready else 0
                src2_value = random.getrandbits(64) if src2_ready else 0
                src3_value = random.getrandbits(64) if src3_ready else 0

                dut_if.drive_rs_dispatch(
                    rs_type=rs_type,
                    rob_tag=tag,
                    op=0,
                    src1_ready=src1_ready,
                    src1_tag=src1_tag,
                    src1_value=src1_value,
                    src2_ready=src2_ready,
                    src2_tag=src2_tag,
                    src2_value=src2_value,
                    src3_ready=src3_ready,
                    src3_tag=src3_tag,
                    src3_value=src3_value,
                )
                model.rs_dispatch(
                    rs_type=rs_type,
                    rob_tag=tag,
                    op=0,
                    src1_ready=src1_ready,
                    src1_tag=src1_tag,
                    src1_value=src1_value,
                    src2_ready=src2_ready,
                    src2_tag=src2_tag,
                    src2_value=src2_value,
                    src3_ready=src3_ready,
                    src3_tag=src3_tag,
                    src3_value=src3_value,
                )
                await dut_if.step()
                dut_if.clear_alloc_request()
                dut_if.clear_rat_rename()
                dut_if.clear_rs_dispatch()
                num_dispatches += 1
            else:
                await dut_if.step()

        # CDB broadcast to a valid ROB entry (~30%)
        elif r < 0.65 and pending_tags:
            cdb_tag = random.choice(list(pending_tags))
            cdb_value = random.getrandbits(64)
            dut_if.drive_cdb(tag=cdb_tag, value=cdb_value)
            model.cdb_write_and_snoop(tag=cdb_tag, value=cdb_value)
            pending_tags.discard(cdb_tag)
            await dut_if.step()
            dut_if.clear_cdb()

        # Flush all (~5%)
        elif r < 0.70:
            prev_was_flush = True
            dut_if.drive_flush_all()
            model.flush_all()
            pending_tags.clear()
            await dut_if.step()
            dut_if.clear_flush_all()

        # Idle (~30%)
        else:
            await dut_if.step()

    # Final: flush and verify all RS are clean
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    assert dut_if.rob_empty
    for rs_type in ALL_RS_TYPES:
        assert dut_if.rs_empty_for(
            rs_type
        ), f"{RS_NAMES[rs_type]}: not empty after final flush"

    cocotb.log.info(
        f"=== Test Passed ({num_dispatches} dispatches across 4 RS, seed={seed}) ==="
    )


@cocotb.test()
async def test_multi_fu_arbitration_contention(dut: Any) -> None:
    """Multiple FU completions contend; highest-priority FU wins CDB grant."""
    if is_icarus(dut):
        cocotb.log.info(
            "SKIP: Multi-RS tests require Verilator (ICARUS has INT_RS only)"
        )
        return
    cocotb.log.info("=== Test: Multi-FU Arbitration Contention ===")
    dut_if, model = await setup_test(dut)

    # Allocate 3 instructions for contention test
    req_a = make_int_req(pc=0x1000, rd=1)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)

    req_b = make_int_req(pc=0x1004, rd=2)
    tag_b = await dut_if.dispatch(req_b)
    model.dispatch(req_b)

    req_c = make_int_req(pc=0x1008, rd=3)
    tag_c = await dut_if.dispatch(req_c)
    model.dispatch(req_c)

    # Drive 3 FU completions simultaneously (FP_ADD, FP_MUL, FP_DIV)
    # Arbiter latency-based priority: FP_DIV(6) > FP_MUL(5) > FP_ADD(4)
    # Note: FU_MEM (slot 3) is now internally driven by LQ adapter.
    # Assign tag_a (head) to lowest priority (FP_ADD) so it completes last,
    # preventing premature ROB commit during the arbitration test.
    dut_if.drive_fu_complete(FU_FP_ADD, tag=tag_a, value=0xAAAA)
    dut_if.drive_fu_complete(FU_FP_MUL, tag=tag_b, value=0xBBBB)
    dut_if.drive_fu_complete(FU_FP_DIV, tag=tag_c, value=0xCCCC)
    await Timer(1, unit="ps")

    # Round 1: FP_DIV should win (highest priority)
    cdb = dut_if.read_cdb_output()
    grant = dut_if.read_cdb_grant()
    assert cdb.valid, "CDB should be valid with 3 FUs completing"
    assert cdb.tag == tag_c, f"FP_DIV should win, got tag={cdb.tag} expected={tag_c}"
    assert cdb.value == 0xCCCC
    assert (grant >> FU_FP_DIV) & 1, "FP_DIV grant should be set"
    assert not ((grant >> FU_FP_MUL) & 1), "FP_MUL should not be granted"
    assert not ((grant >> FU_FP_ADD) & 1), "FP_ADD should not be granted"

    # Model: only the FP_DIV completion goes through this cycle
    model.fu_complete(FU_FP_DIV, tag=tag_c, value=0xCCCC)

    # Clock: arbiter result latched by ROB
    await dut_if.step()

    # Clear FP_DIV (granted), re-drive FP_ADD and FP_MUL
    dut_if.clear_fu_complete(FU_FP_DIV)
    dut_if.drive_fu_complete(FU_FP_ADD, tag=tag_a, value=0xAAAA)
    dut_if.drive_fu_complete(FU_FP_MUL, tag=tag_b, value=0xBBBB)
    await Timer(1, unit="ps")

    # Round 2: FP_MUL should win (higher priority than FP_ADD)
    cdb = dut_if.read_cdb_output()
    assert cdb.valid
    assert (
        cdb.tag == tag_b
    ), f"FP_MUL should win now, got tag={cdb.tag} expected={tag_b}"
    assert cdb.value == 0xBBBB

    model.fu_complete(FU_FP_MUL, tag=tag_b, value=0xBBBB)
    await dut_if.step()

    # Clear FP_MUL (granted), re-drive only FP_ADD
    dut_if.clear_fu_complete(FU_FP_MUL)
    dut_if.drive_fu_complete(FU_FP_ADD, tag=tag_a, value=0xAAAA)
    await Timer(1, unit="ps")

    # Round 3: FP_ADD is the only remaining contender
    cdb = dut_if.read_cdb_output()
    assert cdb.valid
    assert (
        cdb.tag == tag_a
    ), f"FP_ADD should win now, got tag={cdb.tag} expected={tag_a}"
    assert cdb.value == 0xAAAA

    model.fu_complete(FU_FP_ADD, tag=tag_a, value=0xAAAA)
    await dut_if.step()
    dut_if.clear_fu_complete(FU_FP_ADD)

    # All 3 entries now done — commit in order
    for expected_tag in [tag_a, tag_b, tag_c]:
        commit = await wait_for_commit(dut_if)
        model.try_commit()
        assert (
            commit["valid"] and commit["tag"] == expected_tag
        ), f"Expected commit tag={expected_tag}, got {commit['tag']}"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Integrated FU Pipeline Tests (ALU shim, MUL/DIV shim end-to-end)
# =============================================================================


@cocotb.test()
async def test_alu_shim_end_to_end(dut: Any) -> None:
    """ADD dispatched to INT_RS completes through ALU shim -> CDB -> ROB commit."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: Integrated FU tests require Verilator")
        return
    cocotb.log.info("=== Test: ALU Shim End-to-End ===")
    dut_if, model = await setup_test(dut)

    # Dispatch ROB entry
    req = make_int_req(pc=0x1000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Dispatch to INT_RS: ADD with src1=100, src2=42, both ready
    src1_val = 100
    src2_val = 42
    expected_result = (src1_val + src2_val) & 0xFFFFFFFF
    dut_if.drive_rs_dispatch(
        rs_type=RS_INT,
        rob_tag=tag,
        op=OP_ADD,
        src1_ready=True,
        src1_value=src1_val,
        src2_ready=True,
        src2_value=src2_val,
        src3_ready=True,
    )
    model.rs_dispatch(
        rs_type=RS_INT,
        rob_tag=tag,
        op=OP_ADD,
        src1_ready=True,
        src1_value=src1_val,
        src2_ready=True,
        src2_value=src2_val,
        src3_ready=True,
    )
    # Enable INT_RS FU ready so RS issues on the same cycle
    dut_if.set_fu_ready(RS_INT, True)
    await dut_if.step()

    # ALU is single-cycle: result appears on CDB combinationally at this
    # falling edge (same cycle as RS issue). Read before next rising edge
    # consumes it.
    cdb = dut_if.read_cdb_output()
    assert cdb.valid, "ALU result should be on CDB same cycle as issue"
    assert cdb.tag == tag, f"CDB tag mismatch: got {cdb.tag}, expected {tag}"
    assert (
        cdb.value == expected_result
    ), f"ALU ADD result mismatch: got {cdb.value:#x}, expected {expected_result:#x}"
    dut_if.clear_rs_dispatch()

    # Keep model in sync
    model.fu_complete(FU_ALU, tag=tag, value=expected_result)

    # Wait for commit (ROB latches CDB on next rising edge, then commits)
    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["tag"] == tag
    assert commit["value"] == expected_result

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_mul_shim_end_to_end(dut: Any) -> None:
    """MUL dispatched to MUL_RS completes through multiplier -> CDB -> ROB commit."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: Integrated FU tests require Verilator")
        return
    cocotb.log.info("=== Test: MUL Shim End-to-End ===")
    dut_if, model = await setup_test(dut)

    # Dispatch ROB entry
    req = make_int_req(pc=0x2000, rd=7)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Dispatch to MUL_RS: MUL with src1=7, src2=13
    # MUL result = low 32 bits of (7 * 13) = 91
    src1_val = 7
    src2_val = 13
    expected_result = (src1_val * src2_val) & 0xFFFFFFFF
    dut_if.drive_rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag,
        op=OP_MUL,
        src1_ready=True,
        src1_value=src1_val,
        src2_ready=True,
        src2_value=src2_val,
        src3_ready=True,
    )
    model.rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag,
        op=OP_MUL,
        src1_ready=True,
        src1_value=src1_val,
        src2_ready=True,
        src2_value=src2_val,
        src3_ready=True,
    )
    dut_if.set_fu_ready(RS_MUL, True)
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # Multiplier takes 4 cycles; wait for CDB broadcast
    cdb = await wait_for_cdb(dut_if, max_cycles=10)
    assert cdb.tag == tag, f"CDB tag mismatch: got {cdb.tag}, expected {tag}"
    assert (
        cdb.value == expected_result
    ), f"MUL result mismatch: got {cdb.value:#x}, expected {expected_result:#x}"

    model.fu_complete(FU_MUL, tag=tag, value=expected_result)

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["tag"] == tag
    assert commit["value"] == expected_result

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_div_shim_end_to_end(dut: Any) -> None:
    """DIV dispatched to MUL_RS completes through divider -> CDB -> ROB commit."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: Integrated FU tests require Verilator")
        return
    cocotb.log.info("=== Test: DIV Shim End-to-End ===")
    dut_if, model = await setup_test(dut)

    # Dispatch ROB entry
    req = make_int_req(pc=0x3000, rd=10)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Dispatch to MUL_RS: DIVU with src1=100, src2=7
    # DIVU result = 100 / 7 = 14 (unsigned integer division)
    src1_val = 100
    src2_val = 7
    expected_quotient = src1_val // src2_val  # 14
    dut_if.drive_rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag,
        op=OP_DIVU,
        src1_ready=True,
        src1_value=src1_val,
        src2_ready=True,
        src2_value=src2_val,
        src3_ready=True,
    )
    model.rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag,
        op=OP_DIVU,
        src1_ready=True,
        src1_value=src1_val,
        src2_ready=True,
        src2_value=src2_val,
        src3_ready=True,
    )
    dut_if.set_fu_ready(RS_MUL, True)
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # Divider takes 17 cycles; wait for CDB broadcast
    cdb = await wait_for_cdb(dut_if, max_cycles=25)
    assert cdb.tag == tag, f"CDB tag mismatch: got {cdb.tag}, expected {tag}"
    assert (
        cdb.value == expected_quotient
    ), f"DIVU result mismatch: got {cdb.value:#x}, expected {expected_quotient:#x}"

    model.fu_complete(FU_DIV, tag=tag, value=expected_quotient)

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["tag"] == tag
    assert commit["value"] == expected_quotient

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_integrated_fu_back_to_back(dut: Any) -> None:
    """Back-to-back ALU + MUL operations with CDB contention."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: Integrated FU tests require Verilator")
        return
    cocotb.log.info("=== Test: Integrated FU Back-to-Back ===")
    dut_if, model = await setup_test(dut)

    dut_if.set_fu_ready(RS_INT, True)
    dut_if.set_fu_ready(RS_MUL, True)

    # Dispatch instruction A: MUL (4-cycle latency, fires first)
    req_a = make_int_req(pc=0x4000, rd=1)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)
    dut_if.drive_rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag_a,
        op=OP_MUL,
        src1_ready=True,
        src1_value=6,
        src2_ready=True,
        src2_value=9,
        src3_ready=True,
    )
    model.rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag_a,
        op=OP_MUL,
        src1_ready=True,
        src1_value=6,
        src2_ready=True,
        src2_value=9,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()
    expected_mul = (6 * 9) & 0xFFFFFFFF  # 54

    # Dispatch instruction B: ADD (1-cycle latency)
    req_b = make_int_req(pc=0x4004, rd=2)
    tag_b = await dut_if.dispatch(req_b)
    model.dispatch(req_b)
    dut_if.drive_rs_dispatch(
        rs_type=RS_INT,
        rob_tag=tag_b,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1000,
        src2_ready=True,
        src2_value=0x2000,
        src3_ready=True,
    )
    model.rs_dispatch(
        rs_type=RS_INT,
        rob_tag=tag_b,
        op=OP_ADD,
        src1_ready=True,
        src1_value=0x1000,
        src2_ready=True,
        src2_value=0x2000,
        src3_ready=True,
    )
    await dut_if.step()
    expected_add = 0x3000

    # ALU result is combinational — read CDB at current falling edge
    cdb = dut_if.read_cdb_output()
    assert cdb.valid, "ADD result should be on CDB same cycle as issue"
    assert cdb.tag == tag_b, f"Expected ADD tag={tag_b}, got {cdb.tag}"
    assert (
        cdb.value == expected_add
    ), f"ADD result: got {cdb.value:#x}, expected {expected_add:#x}"
    dut_if.clear_rs_dispatch()
    model.fu_complete(FU_ALU, tag=tag_b, value=expected_add)

    # Wait for MUL result on CDB (multiplier ~4 cycles)
    cdb = await wait_for_cdb(dut_if, max_cycles=10)
    assert cdb.tag == tag_a, f"Expected MUL tag={tag_a}, got {cdb.tag}"
    assert (
        cdb.value == expected_mul
    ), f"MUL result: got {cdb.value:#x}, expected {expected_mul:#x}"
    model.fu_complete(FU_MUL, tag=tag_a, value=expected_mul)

    # Commit both in ROB order (MUL first since it was dispatched first)
    commit_a = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit_a["tag"] == tag_a, f"Expected tag_a={tag_a}, got {commit_a['tag']}"

    commit_b = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit_b["tag"] == tag_b, f"Expected tag_b={tag_b}, got {commit_b['tag']}"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_integrated_fu_flush_inflight(dut: Any) -> None:
    """Flush while MUL operation is in-flight suppresses stale results."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: Integrated FU tests require Verilator")
        return
    cocotb.log.info("=== Test: Integrated FU Flush In-Flight ===")
    dut_if, model = await setup_test(dut)

    dut_if.set_fu_ready(RS_MUL, True)

    # Dispatch a MUL operation (4-cycle latency)
    req = make_int_req(pc=0x5000, rd=3)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)
    dut_if.drive_rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag,
        op=OP_MUL,
        src1_ready=True,
        src1_value=10,
        src2_ready=True,
        src2_value=20,
        src3_ready=True,
    )
    model.rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag,
        op=OP_MUL,
        src1_ready=True,
        src1_value=10,
        src2_ready=True,
        src2_value=20,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # Wait 2 cycles (multiplier is mid-pipeline), then flush
    await dut_if.step()
    await dut_if.step()
    dut_if.drive_flush_all()
    model.flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    # Wait enough cycles for the multiplier to finish (it runs to completion
    # internally, but the shim should suppress the result)
    for _ in range(10):
        await dut_if.step()
        cdb = dut_if.read_cdb_output()
        assert (
            not cdb.valid
        ), f"Stale MUL result leaked to CDB after flush: tag={cdb.tag}"

    # Verify clean state
    assert dut_if.rob_empty, "ROB should be empty after flush"
    assert dut_if.rs_empty_for(RS_MUL), "MUL_RS should be empty after flush"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_integrated_fu_partial_flush_inflight(dut: Any) -> None:
    """Partial flush (i_flush_en) suppresses in-flight MUL while older entry survives."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: Integrated FU tests require Verilator")
        return
    cocotb.log.info("=== Test: Integrated FU Partial Flush In-Flight ===")
    dut_if, model = await setup_test(dut)

    dut_if.set_fu_ready(RS_MUL, True)

    # Dispatch instruction A (tag 0) — older, survives partial flush.
    # Dispatch to MEM_RS as a dummy (no integrated FU, will complete via CDB).
    req_a = make_int_req(pc=0x6000, rd=1)
    tag_a = await dut_if.dispatch(req_a)
    model.dispatch(req_a)

    # Dispatch instruction B (tag 1) — younger, will be flushed.
    # Dispatch to MUL_RS with MUL op (4-cycle multiplier).
    req_b = make_int_req(pc=0x6004, rd=2)
    tag_b = await dut_if.dispatch(req_b)
    model.dispatch(req_b)
    dut_if.drive_rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag_b,
        op=OP_MUL,
        src1_ready=True,
        src1_value=11,
        src2_ready=True,
        src2_value=13,
        src3_ready=True,
    )
    model.rs_dispatch(
        rs_type=RS_MUL,
        rob_tag=tag_b,
        op=OP_MUL,
        src1_ready=True,
        src1_value=11,
        src2_ready=True,
        src2_value=13,
        src3_ready=True,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # Multiplier is now in-flight for tag_b. Wait 2 cycles (mid-pipeline).
    await dut_if.step()
    await dut_if.step()

    # Partial flush: flush_tag = tag_a (0). Everything younger than tag_a
    # (i.e., tag_b = 1) should be flushed. Tag_a itself survives.
    # head_tag is 0 (tag_a), so is_younger(1, 0, 0) = (1-0) > (0-0) = true.
    dut_if.drive_flush_en(flush_tag=tag_a)
    # Update model: partial flush of ROB and all RS (no RAT checkpoint needed)
    model.rob.flush_partial(tag_a)
    for rs in model._all_rs():
        rs.partial_flush(tag_a, model.rob.head_idx)
    await dut_if.step()
    dut_if.clear_flush_en()

    # Wait for multiplier to finish (it runs to completion internally,
    # but the shim should suppress the result via partial flush tracking).
    for _ in range(10):
        await dut_if.step()
        cdb = dut_if.read_cdb_output()
        assert (
            not cdb.valid
        ), f"Stale MUL result leaked to CDB after partial flush: tag={cdb.tag}"

    # Tag_a (older) should still be in ROB and valid
    assert not dut_if.rob_empty, "ROB should still have tag_a"
    assert dut_if.rob_count == 1, f"Expected 1 ROB entry, got {dut_if.rob_count}"

    # Complete tag_a via external CDB (FU_FP_ADD — slot 3 is now internal LQ)
    dut_if.drive_fu_complete(FU_FP_ADD, tag=tag_a, value=0xBEEF)
    model.fu_complete(FU_FP_ADD, tag=tag_a, value=0xBEEF)
    await dut_if.step()
    dut_if.clear_fu_complete(FU_FP_ADD)

    commit = await wait_for_commit(dut_if)
    model.try_commit()
    assert commit["tag"] == tag_a, f"Expected commit tag={tag_a}, got {commit['tag']}"
    assert commit["value"] == 0xBEEF
    assert bool(dut_if.rob_empty), "ROB should be empty after committing tag_a"

    cocotb.log.info("=== Test Passed ===")


# =============================================================================
# Group F: Load Queue Integration Tests
# =============================================================================


@cocotb.test()
async def test_lq_end_to_end_lw(dut: Any) -> None:
    """Full LW flow: ROB alloc -> MEM_RS dispatch -> RS issue -> LQ addr -> mem -> CDB -> commit."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: LQ tests require Verilator")
        return
    cocotb.log.info("=== Test: LQ End-to-End LW ===")
    dut_if, model = await setup_test(dut)

    # Enable MEM_RS fu_ready so it can issue
    dut_if.set_fu_ready(RS_MEM, True)

    # Dispatch LW to ROB (rd=5, dest_valid=True)
    req = make_int_req(pc=0x2000, rd=5)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    # Dispatch to MEM_RS as LW with src1 ready (base address) and immediate
    base_addr = 0x1000
    imm = 0x10
    dut_if.drive_rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag,
        op=OP_LW,
        src1_ready=True,
        src1_value=base_addr,
        src2_ready=True,
        src3_ready=True,
        imm=imm,
        use_imm=True,
        mem_size=2,  # MEM_SIZE_WORD
        mem_signed=False,
    )
    model.rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag,
        op=OP_LW,
        src1_ready=True,
        src1_value=base_addr,
        src2_ready=True,
        src3_ready=True,
        imm=imm,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # MEM_RS should issue after operands ready
    for _ in range(3):
        issue = dut_if.read_rs_issue_for(RS_MEM)
        if issue["valid"]:
            break
        await dut_if.step()
    assert issue["valid"], "MEM_RS should have issued"
    assert issue["rob_tag"] == tag

    # After RS issue, the LQ should have received the address update
    # Wait for the LQ to present the SQ check
    await dut_if.step()
    dut_if.set_fu_ready(RS_MEM, False)  # Only needed one issue

    # LQ should present sq_check for disambiguation
    for _ in range(3):
        sq_check = dut_if.read_sq_check()
        if sq_check["valid"]:
            break
        await dut_if.step()

    assert sq_check["valid"], "LQ should present SQ check"
    expected_addr = (base_addr + imm) & 0xFFFFFFFF
    assert (
        sq_check["addr"] == expected_addr
    ), f"SQ check addr={sq_check['addr']:#x} expected={expected_addr:#x}"
    assert sq_check["rob_tag"] == tag

    # Drive SQ disambiguation: no match, all older known -> issue to memory
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")

    # Check memory request
    mem_req = dut_if.read_lq_mem_request()
    assert mem_req["en"], "LQ should issue memory read"
    assert mem_req["addr"] == expected_addr

    await dut_if.step()
    dut_if.clear_sq_forward()
    dut_if.drive_sq_all_older_known(False)

    # Provide memory response — don't step() before wait_for_cdb because
    # the CDB broadcast is combinationally valid for exactly one cycle after
    # data_valid is set, and step() would consume that window.
    mem_data = 0xDEAD_BEEF
    dut_if.drive_lq_mem_response(mem_data)
    cdb = await wait_for_cdb(dut_if)
    dut_if.clear_lq_mem_response()
    assert cdb.tag == tag, f"CDB tag={cdb.tag} expected={tag}"
    assert cdb.value == mem_data, f"CDB value={cdb.value:#x} expected={mem_data:#x}"

    # Wait for commit
    commit = await wait_for_commit(dut_if)
    assert commit["tag"] == tag
    assert commit["value"] == mem_data
    assert dut_if.rob_empty

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_lq_sq_forward_through_wrapper(dut: Any) -> None:
    """SQ forwards data to LQ, skipping memory, CDB broadcasts forwarded value."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: LQ tests require Verilator")
        return
    cocotb.log.info("=== Test: LQ SQ Forward Through Wrapper ===")
    dut_if, model = await setup_test(dut)

    dut_if.set_fu_ready(RS_MEM, True)

    # Dispatch LW
    req = make_int_req(pc=0x3000, rd=7)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    base_addr = 0x2000
    imm = 0x4
    dut_if.drive_rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag,
        op=OP_LW,
        src1_ready=True,
        src1_value=base_addr,
        src2_ready=True,
        src3_ready=True,
        imm=imm,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
    )
    model.rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag,
        op=OP_LW,
        src1_ready=True,
        src1_value=base_addr,
        src2_ready=True,
        src3_ready=True,
        imm=imm,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # Wait for MEM_RS issue
    for _ in range(3):
        issue = dut_if.read_rs_issue_for(RS_MEM)
        if issue["valid"]:
            break
        await dut_if.step()
    assert issue["valid"]
    await dut_if.step()
    dut_if.set_fu_ready(RS_MEM, False)

    # Wait for SQ check
    for _ in range(3):
        sq_check = dut_if.read_sq_check()
        if sq_check["valid"]:
            break
        await dut_if.step()
    assert sq_check["valid"], "LQ should present SQ check"

    # Drive SQ forward: match + can_forward with data
    forward_data = 0xCAFE_BABE
    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=True, can_forward=True, data=forward_data)
    await Timer(1, unit="ns")

    # Memory read should NOT have been issued (combinational: match prevents issue)
    mem_req = dut_if.read_lq_mem_request()
    assert not mem_req["en"], "LQ should not issue mem read when SQ forwards"

    # CDB broadcast appears same cycle as data_valid is set (next posedge).
    # Let wait_for_cdb catch it directly.
    cdb = await wait_for_cdb(dut_if)
    dut_if.clear_sq_forward()
    dut_if.drive_sq_all_older_known(False)
    assert cdb.tag == tag
    assert (
        cdb.value == forward_data
    ), f"CDB value={cdb.value:#x} expected={forward_data:#x}"

    # Wait for commit
    commit = await wait_for_commit(dut_if)
    assert commit["tag"] == tag
    assert dut_if.rob_empty

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_lq_flush_all_clears_lq(dut: Any) -> None:
    """flush_all empties LQ alongside ROB+RS."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: LQ tests require Verilator")
        return
    cocotb.log.info("=== Test: LQ Flush All Clears LQ ===")
    dut_if, model = await setup_test(dut)

    dut_if.set_fu_ready(RS_MEM, True)

    # Dispatch a LW so LQ has an entry
    req = make_int_req(pc=0x4000, rd=3)
    tag = await dut_if.dispatch(req)
    model.dispatch(req)

    dut_if.drive_rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag,
        op=OP_LW,
        src1_ready=True,
        src1_value=0x1000,
        src2_ready=True,
        src3_ready=True,
        imm=0,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
    )
    model.rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag,
        op=OP_LW,
        src1_ready=True,
        src1_value=0x1000,
        src2_ready=True,
        src3_ready=True,
        imm=0,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # LQ should have an entry
    assert dut_if.lq_count > 0, "LQ should not be empty after LW dispatch"

    # Flush all
    dut_if.drive_flush_all()
    await dut_if.step()
    dut_if.clear_flush_all()

    # Everything should be empty
    assert dut_if.lq_empty, "LQ should be empty after flush_all"
    assert dut_if.rob_empty, "ROB should be empty after flush_all"
    assert dut_if.rs_empty_for(RS_MEM), "MEM_RS should be empty after flush_all"

    cocotb.log.info("=== Test Passed ===")


@cocotb.test()
async def test_lq_cdb_arbitration(dut: Any) -> None:
    """LQ CDB result contends with external FP_ADD completion, arbiter resolves."""
    if is_icarus(dut):
        cocotb.log.info("SKIP: LQ tests require Verilator")
        return
    cocotb.log.info("=== Test: LQ CDB Arbitration ===")
    dut_if, model = await setup_test(dut)

    dut_if.set_fu_ready(RS_MEM, True)

    # Dispatch two instructions: LW (tag 0) and dummy INT (tag 1)
    req_lw = make_int_req(pc=0x5000, rd=4)
    tag_lw = await dut_if.dispatch(req_lw)
    model.dispatch(req_lw)

    req_int = make_int_req(pc=0x5004, rd=5)
    tag_int = await dut_if.dispatch(req_int)
    model.dispatch(req_int)

    # Dispatch LW to MEM_RS
    dut_if.drive_rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag_lw,
        op=OP_LW,
        src1_ready=True,
        src1_value=0x1000,
        src2_ready=True,
        src3_ready=True,
        imm=0,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
    )
    model.rs_dispatch(
        rs_type=RS_MEM,
        rob_tag=tag_lw,
        op=OP_LW,
        src1_ready=True,
        src1_value=0x1000,
        src2_ready=True,
        src3_ready=True,
        imm=0,
        use_imm=True,
        mem_size=2,
        mem_signed=False,
    )
    await dut_if.step()
    dut_if.clear_rs_dispatch()

    # Wait for MEM_RS issue
    for _ in range(3):
        issue = dut_if.read_rs_issue_for(RS_MEM)
        if issue["valid"]:
            break
        await dut_if.step()
    assert issue["valid"]
    await dut_if.step()
    dut_if.set_fu_ready(RS_MEM, False)

    # Complete the LQ load via disambig + memory
    for _ in range(3):
        sq_check = dut_if.read_sq_check()
        if sq_check["valid"]:
            break
        await dut_if.step()

    dut_if.drive_sq_all_older_known(True)
    dut_if.drive_sq_forward(match=False, can_forward=False)
    await Timer(1, unit="ns")
    await dut_if.step()
    dut_if.clear_sq_forward()
    dut_if.drive_sq_all_older_known(False)

    # Drive mem response AND FP_ADD completion simultaneously so both
    # are presented to the CDB arbiter on the same posedge.
    dut_if.drive_lq_mem_response(0x1111)
    dut_if.drive_fu_complete(FU_FP_ADD, tag=tag_int, value=0x2222)

    # wait_for_cdb catches the first winner on the posedge that
    # captures data_valid=1 (LQ) while FP_ADD is also valid.
    cdb1 = await wait_for_cdb(dut_if)
    assert cdb1.valid, "CDB should be valid"
    # FP_ADD (slot 4) has higher priority than MEM (slot 3)
    assert cdb1.tag == tag_int, f"FP_ADD should win CDB arbitration, got tag={cdb1.tag}"

    # Clear FP_ADD so MEM (adapter-held) can win on the next grant.
    # The MEM adapter latched the LQ result (wasn't granted on first cycle).
    # After clearing FP_ADD, the adapter's held result wins immediately.
    # Read CDB between posedges to observe it before the grant clears the adapter.
    dut_if.clear_fu_complete(FU_FP_ADD)
    dut_if.clear_lq_mem_response()
    await Timer(1, unit="ns")
    cdb2 = dut_if.read_cdb_output()
    assert cdb2.valid, "MEM adapter should present held result after FP_ADD cleared"
    assert cdb2.tag == tag_lw, f"Expected LQ tag={tag_lw}, got {cdb2.tag}"
    assert cdb2.value == 0x1111, f"Expected 0x1111, got {cdb2.value:#x}"

    # Advance to let the grant process and both results reach ROB
    await dut_if.step()

    # Both should commit in order
    commit1 = await wait_for_commit(dut_if)
    assert commit1["tag"] == tag_lw

    commit2 = await wait_for_commit(dut_if)
    assert commit2["tag"] == tag_int

    assert dut_if.rob_empty
    cocotb.log.info("=== Test Passed ===")

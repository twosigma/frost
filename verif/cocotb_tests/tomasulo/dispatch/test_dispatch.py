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

"""Unit tests for the Dispatch module.

Covers stall logic, RS routing, source operand resolution, RAT rename,
checkpoint management, immediate selection, memory attributes, flush,
CSR info, FP flags, prediction passthrough, and rounding mode resolution.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock

from .dispatch_interface import (
    DispatchInterface,
    pack_instr_t,
    # Op codes
    ADD,
    MUL,
    LW,
    LB,
    LBU,
    SW,
    BEQ,
    JAL,
    WFI,
    ADDI,
    FADD_S,
    FMUL_S,
    FDIV_S,
    CSRRW,
    RS_INT,
    RS_MUL,
    RS_MEM,
    RS_FP,
    RS_FMUL,
    RS_FDIV,
    MEM_SIZE_BYTE,
)

# OPC_OP = 0b0110011 (R-type integer)
OPC_OP = 0b0110011
# OPC_OP_IMM = 0b0010011 (I-type integer immediate)
OPC_OP_IMM = 0b0010011
# OPC_LOAD = 0b0000011
OPC_LOAD = 0b0000011
# OPC_STORE = 0b0100011
OPC_STORE = 0b0100011
# OPC_BRANCH = 0b1100011
OPC_BRANCH = 0b1100011
# OPC_JAL = 0b1101111
OPC_JAL = 0b1101111
# OPC_JALR = 0b1100111
OPC_JALR = 0b1100111
# OPC_OP_FP = 0b1010011
OPC_OP_FP = 0b1010011
# OPC_LOAD_FP = 0b0000111
OPC_LOAD_FP = 0b0000111
# OPC_STORE_FP = 0b0100111
OPC_STORE_FP = 0b0100111


async def _setup(dut: Any) -> DispatchInterface:
    """Create clock, instantiate interface, and reset."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut_if = DispatchInterface(dut)
    await dut_if.reset_dut(cycles=5)
    # Provide a default ROB alloc response: ready, tag=0, not full
    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=0, full=0)
    dut_if.drive_rob_alloc_resp_2(alloc_ready=1, alloc_tag=1, full=0)
    # Default: checkpoint available
    dut_if.drive_checkpoint(available=True, alloc_id=0)
    return dut_if


def _make_instr(
    dest_reg: int = 0,
    opcode: int = OPC_OP,
    funct3: int = 0,
    funct7: int = 0,
    source_reg_1: int = 0,
    source_reg_2: int = 0,
) -> int:
    """Pack an instruction word from individual fields."""
    return pack_instr_t(
        funct7=funct7,
        source_reg_2=source_reg_2,
        source_reg_1=source_reg_1,
        funct3=funct3,
        dest_reg=dest_reg,
        opcode=opcode,
    )


# =============================================================================
# Stall Tests
# =============================================================================


@cocotb.test()
async def test_stall_when_rob_full(dut: Any) -> None:
    """ROB full should stall dispatch and prevent alloc_valid."""
    dut_if = await _setup(dut)

    dut_if.set_rob_full(True)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()

    assert dut_if.stall, "Expected stall when ROB is full"
    req = dut_if.read_rob_alloc_req()
    assert req["alloc_valid"] == 0, "alloc_valid should be 0 when stalled"


@cocotb.test()
async def test_stall_when_rs_full(dut: Any) -> None:
    """Each RS type full should stall when that RS is targeted."""
    dut_if = await _setup(dut)

    # INT RS full + ADD (routes to INT RS)
    dut_if.set_int_rs_full(True)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()
    assert dut_if.stall, "Expected stall when INT RS is full for ADD"

    # Clear and try MUL RS
    dut_if.set_int_rs_full(False)
    dut_if.set_mul_rs_full(True)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=MUL,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()
    assert dut_if.stall, "Expected stall when MUL RS is full for MUL"

    # Clear and try MEM RS
    dut_if.set_mul_rs_full(False)
    dut_if.set_mem_rs_full(True)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=LW,
        is_load_instruction=1,
        instruction=_make_instr(dest_reg=5, opcode=OPC_LOAD),
    )
    await dut_if.step()
    assert dut_if.stall, "Expected stall when MEM RS is full for LW"


@cocotb.test()
async def test_stall_when_lq_full(dut: Any) -> None:
    """Load instruction + LQ full should stall."""
    dut_if = await _setup(dut)

    dut_if.set_lq_full(True)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=LW,
        is_load_instruction=1,
        instruction=_make_instr(dest_reg=5, opcode=OPC_LOAD),
    )
    await dut_if.step()
    assert dut_if.stall, "Expected stall when LQ is full for load"


@cocotb.test()
async def test_stall_when_sq_full(dut: Any) -> None:
    """Store instruction + SQ full should stall."""
    dut_if = await _setup(dut)

    dut_if.set_sq_full(True)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=SW,
        instruction=_make_instr(opcode=OPC_STORE),
    )
    await dut_if.step()
    assert dut_if.stall, "Expected stall when SQ is full for store"


@cocotb.test()
async def test_stall_when_no_checkpoint(dut: Any) -> None:
    """Branch with no checkpoint available should stall."""
    dut_if = await _setup(dut)

    dut_if.drive_checkpoint(available=False, alloc_id=0)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=BEQ,
        instruction=_make_instr(opcode=OPC_BRANCH),
    )
    await dut_if.step()
    assert dut_if.stall, "Expected stall when no checkpoint for branch"


@cocotb.test()
async def test_no_stall_when_invalid(dut: Any) -> None:
    """Invalid instruction should not stall even if resources are full."""
    dut_if = await _setup(dut)

    dut_if.set_rob_full(True)
    dut_if.set_int_rs_full(True)
    dut_if.drive_instruction(
        valid=False,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()
    assert not dut_if.stall, "Invalid instruction should not stall"


# =============================================================================
# RS Routing Tests
# =============================================================================


@cocotb.test()
async def test_add_dispatches_to_int_rs(dut: Any) -> None:
    """ADD instruction should route to INT_RS."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["valid"] == 1, "RS dispatch should be valid"
    assert rs["rs_type"] == RS_INT, f"Expected RS_INT, got {rs['rs_type']}"


@cocotb.test()
async def test_mul_dispatches_to_mul_rs(dut: Any) -> None:
    """MUL instruction should route to MUL_RS."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=MUL,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["valid"] == 1
    assert rs["rs_type"] == RS_MUL, f"Expected RS_MUL, got {rs['rs_type']}"


@cocotb.test()
async def test_load_dispatches_to_mem_rs(dut: Any) -> None:
    """LW instruction should route to MEM_RS."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=LW,
        is_load_instruction=1,
        instruction=_make_instr(dest_reg=5, opcode=OPC_LOAD),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["valid"] == 1
    assert rs["rs_type"] == RS_MEM, f"Expected RS_MEM, got {rs['rs_type']}"


@cocotb.test()
async def test_fadd_dispatches_to_fp_rs(dut: Any) -> None:
    """FADD_S instruction should route to FP_RS."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=FADD_S,
        is_fp_instruction=1,
        is_fp_compute=1,
        instruction=_make_instr(dest_reg=3, opcode=OPC_OP_FP),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["valid"] == 1
    assert rs["rs_type"] == RS_FP, f"Expected RS_FP, got {rs['rs_type']}"


@cocotb.test()
async def test_fmul_dispatches_to_fmul_rs(dut: Any) -> None:
    """FMUL_S instruction should route to FMUL_RS."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=FMUL_S,
        is_fp_instruction=1,
        is_fp_compute=1,
        instruction=_make_instr(dest_reg=3, opcode=OPC_OP_FP),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["valid"] == 1
    assert rs["rs_type"] == RS_FMUL, f"Expected RS_FMUL, got {rs['rs_type']}"


@cocotb.test()
async def test_fdiv_dispatches_to_fdiv_rs(dut: Any) -> None:
    """FDIV_S instruction should route to FDIV_RS."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=FDIV_S,
        is_fp_instruction=1,
        is_fp_compute=1,
        instruction=_make_instr(dest_reg=3, opcode=OPC_OP_FP),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["valid"] == 1
    assert rs["rs_type"] == RS_FDIV, f"Expected RS_FDIV, got {rs['rs_type']}"


@cocotb.test()
async def test_wfi_no_rs_dispatch(dut: Any) -> None:
    """WFI dispatches to ROB only (RS_NONE), RS dispatch valid=0."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=WFI,
        is_wfi=1,
        instruction=_make_instr(opcode=0b1110011),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["valid"] == 0, "WFI should not dispatch to RS (RS_NONE)"
    req = dut_if.read_rob_alloc_req()
    assert req["alloc_valid"] == 1, "WFI should still allocate ROB entry"
    assert req["is_wfi"] == 1


# =============================================================================
# Source Operand Resolution Tests
# =============================================================================


@cocotb.test()
async def test_source_ready_from_regfile(dut: Any) -> None:
    """RAT not renamed -> src_ready=1, value from regfile."""
    dut_if = await _setup(dut)

    # INT src1 not renamed, value=0xDEADBEEF
    dut_if.drive_int_src1(renamed=0, tag=0, value=0xDEADBEEF)
    dut_if.drive_int_src2(renamed=0, tag=0, value=0xCAFEBABE)

    dut_if.drive_instruction(
        valid=True,
        rs1_addr=1,
        rs2_addr=2,
        instruction_operation=ADD,
        instruction=_make_instr(
            dest_reg=5, opcode=OPC_OP, source_reg_1=1, source_reg_2=2
        ),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["src1_ready"] == 1, "src1 should be ready (not renamed)"
    assert rs["src1_value"] == 0xDEADBEEF, f"src1_value mismatch: {rs['src1_value']:#x}"
    assert rs["src2_ready"] == 1, "src2 should be ready (not renamed)"
    assert rs["src2_value"] == 0xCAFEBABE, f"src2_value mismatch: {rs['src2_value']:#x}"


@cocotb.test()
async def test_source_not_ready_renamed(dut: Any) -> None:
    """RAT renamed -> src_ready=0, tag set."""
    dut_if = await _setup(dut)

    # INT src1 renamed to ROB tag 7
    dut_if.drive_int_src1(renamed=1, tag=7, value=0)
    dut_if.drive_int_src2(renamed=0, tag=0, value=42)

    dut_if.drive_instruction(
        valid=True,
        rs1_addr=1,
        rs2_addr=2,
        instruction_operation=ADD,
        instruction=_make_instr(
            dest_reg=5, opcode=OPC_OP, source_reg_1=1, source_reg_2=2
        ),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["src1_ready"] == 0, "src1 should not be ready (renamed)"
    assert rs["src1_tag"] == 7, f"src1_tag mismatch: {rs['src1_tag']}"
    assert rs["src2_ready"] == 1, "src2 should be ready"


# =============================================================================
# Slot-2 Bundle Tests
# =============================================================================


@cocotb.test()
async def test_slot2_dual_int_dispatches_and_renames(dut: Any) -> None:
    """Slot 1 and slot 2 can dispatch integer ops in one cycle."""
    dut_if = await _setup(dut)

    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=6, full=0)
    dut_if.drive_rob_alloc_resp_2(alloc_ready=1, alloc_tag=7, full=0)
    dut_if.drive_int_src1(renamed=0, tag=0, value=0x11)
    dut_if.drive_int_src2(renamed=0, tag=0, value=0x22)
    dut_if.drive_int_src1_2(renamed=0, tag=0, value=0x33)

    dut_if.drive_instruction(
        valid=True,
        rs1_addr=1,
        rs2_addr=2,
        instruction_operation=ADD,
        program_counter=0x1000,
        instruction=_make_instr(
            dest_reg=5,
            opcode=OPC_OP,
            source_reg_1=1,
            source_reg_2=2,
        ),
    )
    dut_if.drive_instruction_2(
        valid=True,
        rs1_addr=3,
        instruction_operation=ADDI,
        immediate_i_type=12,
        program_counter=0x1004,
        instruction=_make_instr(
            dest_reg=6,
            opcode=OPC_OP_IMM,
            source_reg_1=3,
        ),
    )
    await dut_if.step()

    assert not dut_if.stall, "Dual integer bundle should fire"
    req1 = dut_if.read_rob_alloc_req()
    req2 = dut_if.read_rob_alloc_req_2()
    assert req1["alloc_valid"] == 1, "Slot 1 should allocate ROB"
    assert req2["alloc_valid"] == 1, "Slot 2 should allocate ROB"
    assert req2["pc"] == 0x1004
    assert req2["dest_valid"] == 1
    assert req2["dest_reg"] == 6

    assert dut_if.rat_alloc_valid, "Slot 1 should rename x5"
    assert dut_if.rat_alloc_dest_reg == 5
    assert dut_if.rat_alloc_rob_tag == 6
    assert dut_if.rat_alloc_valid_2, "Slot 2 should rename x6"
    assert dut_if.rat_alloc_dest_reg_2 == 6
    assert dut_if.rat_alloc_rob_tag_2 == 7

    slot1_rs = dut_if.read_int_rs_dispatch()
    slot2_rs = dut_if.read_int_rs_dispatch_2()
    assert slot1_rs["valid"] == 1
    assert slot1_rs["rs_type"] == RS_INT
    assert slot1_rs["rob_tag"] == 6
    assert slot2_rs["valid"] == 1
    assert slot2_rs["rs_type"] == RS_INT
    assert slot2_rs["rob_tag"] == 7
    assert slot2_rs["use_imm"] == 1
    assert slot2_rs["imm"] == 12
    assert slot2_rs["src1_ready"] == 1
    assert slot2_rs["src1_value"] == 0x33


@cocotb.test()
async def test_slot2_raw_source_uses_slot1_rob_tag(dut: Any) -> None:
    """Slot-2 source matching slot-1 dest should use slot-1's ROB tag."""
    dut_if = await _setup(dut)

    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=12, full=0)
    dut_if.drive_rob_alloc_resp_2(alloc_ready=1, alloc_tag=13, full=0)
    dut_if.drive_int_src1_2(renamed=0, tag=0, value=0xCAFE)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=9, opcode=OPC_OP),
    )
    dut_if.drive_instruction_2(
        valid=True,
        rs1_addr=9,
        instruction_operation=ADDI,
        immediate_i_type=1,
        instruction=_make_instr(dest_reg=10, opcode=OPC_OP_IMM, source_reg_1=9),
    )
    await dut_if.step()

    assert not dut_if.stall
    slot2_rs = dut_if.read_int_rs_dispatch_2()
    assert slot2_rs["valid"] == 1
    assert slot2_rs["src1_ready"] == 0, "RAW source should wait on slot-1 tag"
    assert slot2_rs["src1_tag"] == 12, f"Expected tag 12, got {slot2_rs['src1_tag']}"


@cocotb.test()
async def test_slot2_same_rs_full_for_2_stalls_bundle(dut: Any) -> None:
    """Same-RS bundles should stall when the room-for-2 signal is full."""
    dut_if = await _setup(dut)

    dut_if.set_int_rs_full_for_2(True)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    dut_if.drive_instruction_2(
        valid=True,
        instruction_operation=ADDI,
        instruction=_make_instr(dest_reg=6, opcode=OPC_OP_IMM),
    )
    await dut_if.step()

    assert dut_if.stall, "INT/INT bundle should stall when INT RS lacks room for 2"
    assert dut_if.read_rob_alloc_req()["alloc_valid"] == 0
    assert dut_if.read_rob_alloc_req_2()["alloc_valid"] == 0
    assert dut_if.read_int_rs_dispatch()["valid"] == 0
    assert dut_if.read_int_rs_dispatch_2()["valid"] == 0


@cocotb.test()
async def test_slot2_different_rs_ignores_unrelated_full_for_2(dut: Any) -> None:
    """Different-RS bundles should use plain fullness for the slot-2 RS."""
    dut_if = await _setup(dut)

    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=4, full=0)
    dut_if.drive_rob_alloc_resp_2(alloc_ready=1, alloc_tag=5, full=0)
    dut_if.set_int_rs_full_for_2(True)
    dut_if.set_mul_rs_full_for_2(True)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    dut_if.drive_instruction_2(
        valid=True,
        instruction_operation=MUL,
        instruction=_make_instr(dest_reg=6, opcode=OPC_OP),
    )
    await dut_if.step()

    assert not dut_if.stall, "INT/MUL should ignore unrelated room-for-2 flags"
    slot1_rs = dut_if.read_int_rs_dispatch()
    slot2_rs = dut_if.read_mul_rs_dispatch_2()
    assert slot1_rs["valid"] == 1
    assert slot2_rs["valid"] == 1
    assert slot2_rs["rs_type"] == RS_MUL
    assert slot2_rs["rob_tag"] == 5


@cocotb.test()
async def test_slot1_branch_blocks_slot2_bundle(dut: Any) -> None:
    """Slot 1 control flow should terminate the bundle before slot 2 fires."""
    dut_if = await _setup(dut)

    dut_if.drive_checkpoint(available=True, alloc_id=3)
    dut_if.drive_instruction(
        valid=True,
        rs1_addr=1,
        rs2_addr=2,
        instruction_operation=BEQ,
        instruction=_make_instr(
            opcode=OPC_BRANCH,
            source_reg_1=1,
            source_reg_2=2,
        ),
    )
    dut_if.drive_instruction_2(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()

    assert dut_if.stall, "Slot-1 branch with valid slot 2 should stall the bundle"
    assert dut_if.read_rob_alloc_req()["alloc_valid"] == 0
    assert dut_if.read_rob_alloc_req_2()["alloc_valid"] == 0
    assert not dut_if.checkpoint_save
    assert dut_if.read_int_rs_dispatch()["valid"] == 0
    assert dut_if.read_int_rs_dispatch_2()["valid"] == 0


@cocotb.test()
async def test_slot2_branch_saves_slot2_checkpoint(dut: Any) -> None:
    """Slot-2 branches should save a checkpoint using slot-2 metadata."""
    dut_if = await _setup(dut)

    dut_if.drive_checkpoint(available=True, alloc_id=5)
    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=2, full=0)
    dut_if.drive_rob_alloc_resp_2(alloc_ready=1, alloc_tag=3, full=0)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=8, opcode=OPC_OP),
    )
    dut_if.drive_instruction_2(
        valid=True,
        rs1_addr=1,
        rs2_addr=2,
        instruction_operation=BEQ,
        program_counter=0x2004,
        branch_target_precomputed=0x2080,
        btb_predicted_taken=1,
        btb_predicted_target=0x2070,
        ras_checkpoint_tos=6,
        ras_checkpoint_valid_count=7,
        instruction=_make_instr(
            opcode=OPC_BRANCH,
            source_reg_1=1,
            source_reg_2=2,
        ),
    )
    await dut_if.step()

    assert not dut_if.stall
    req2 = dut_if.read_rob_alloc_req_2()
    assert req2["alloc_valid"] == 1
    assert req2["is_branch"] == 1
    assert req2["branch_target"] == 0x2080
    assert req2["predicted_taken"] == 1
    assert req2["predicted_target"] == 0x2070

    assert dut_if.checkpoint_save, "Slot-2 branch should save checkpoint"
    assert dut_if.checkpoint_save_for_slot2
    assert dut_if.checkpoint_id == 5
    assert dut_if.checkpoint_branch_tag == 3
    assert dut_if.ras_tos_out == 6
    assert dut_if.ras_valid_count_out == 7
    assert dut_if.rob_checkpoint_valid
    assert dut_if.rob_checkpoint_id == 5

    slot2_rs = dut_if.read_int_rs_dispatch_2()
    assert slot2_rs["valid"] == 1
    assert slot2_rs["has_checkpoint"] == 1
    assert slot2_rs["checkpoint_id"] == 5


@cocotb.test()
async def test_slot2_fp_compute_serializes_off(dut: Any) -> None:
    """Slot-2 FP compute ops should not allocate while slot 1 fires."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    dut_if.drive_instruction_2(
        valid=True,
        instruction_operation=FADD_S,
        instruction=_make_instr(dest_reg=3, opcode=OPC_OP_FP),
    )
    await dut_if.step()

    assert not dut_if.stall, "Serialized slot-2 FP op should not block slot 1"
    assert dut_if.read_rob_alloc_req()["alloc_valid"] == 1
    assert dut_if.read_rob_alloc_req_2()["alloc_valid"] == 0
    assert not dut_if.rat_alloc_valid_2
    assert dut_if.read_int_rs_dispatch()["valid"] == 1
    assert dut_if.read_fp_rs_dispatch_2()["valid"] == 0


@cocotb.test()
async def test_slot2_memory_routes_to_mem_rs(dut: Any) -> None:
    """Slot-2 loads and stores should route to MEM_RS with LQ/SQ intent."""
    dut_if = await _setup(dut)

    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=8, full=0)
    dut_if.drive_rob_alloc_resp_2(alloc_ready=1, alloc_tag=9, full=0)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=1, opcode=OPC_OP),
    )
    dut_if.drive_instruction_2(
        valid=True,
        rs1_addr=2,
        instruction_operation=LW,
        immediate_i_type=16,
        instruction=_make_instr(dest_reg=5, opcode=OPC_LOAD, source_reg_1=2),
    )
    await dut_if.step()

    load_req = dut_if.read_rob_alloc_req_2()
    load_rs = dut_if.read_mem_rs_dispatch_2()
    assert load_req["alloc_valid"] == 1
    assert load_req["dest_valid"] == 1
    assert load_req["dest_reg"] == 5
    assert load_rs["valid"] == 1
    assert load_rs["rs_type"] == RS_MEM
    assert load_rs["mem_needs_lq"] == 1
    assert load_rs["mem_needs_sq"] == 0
    assert load_rs["use_imm"] == 1
    assert load_rs["imm"] == 16

    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=10, full=0)
    dut_if.drive_rob_alloc_resp_2(alloc_ready=1, alloc_tag=11, full=0)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=3, opcode=OPC_OP),
    )
    dut_if.drive_instruction_2(
        valid=True,
        rs1_addr=4,
        rs2_addr=5,
        instruction_operation=SW,
        immediate_s_type=32,
        instruction=_make_instr(
            opcode=OPC_STORE,
            source_reg_1=4,
            source_reg_2=5,
        ),
    )
    await dut_if.step()

    store_req = dut_if.read_rob_alloc_req_2()
    store_rs = dut_if.read_mem_rs_dispatch_2()
    assert store_req["alloc_valid"] == 1
    assert store_req["is_store"] == 1
    assert store_req["dest_valid"] == 0
    assert store_rs["valid"] == 1
    assert store_rs["rs_type"] == RS_MEM
    assert store_rs["mem_needs_lq"] == 0
    assert store_rs["mem_needs_sq"] == 1
    assert store_rs["use_imm"] == 1
    assert store_rs["imm"] == 32
    assert not dut_if.rat_alloc_valid_2


# =============================================================================
# RAT Rename Tests
# =============================================================================


@cocotb.test()
async def test_int_dest_rename(dut: Any) -> None:
    """ADD with rd=x5 should trigger RAT rename: dest_rf=0, dest_reg=5."""
    dut_if = await _setup(dut)

    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=3, full=0)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()

    assert dut_if.rat_alloc_valid, "RAT alloc should be valid for ADD with rd=x5"
    assert dut_if.rat_alloc_dest_rf == 0, "dest_rf should be 0 (INT)"
    assert dut_if.rat_alloc_dest_reg == 5, f"dest_reg={dut_if.rat_alloc_dest_reg}"
    assert dut_if.rat_alloc_rob_tag == 3, f"rob_tag={dut_if.rat_alloc_rob_tag}"


@cocotb.test()
async def test_fp_dest_rename(dut: Any) -> None:
    """FADD_S with rd=f3 should trigger RAT rename: dest_rf=1, dest_reg=3."""
    dut_if = await _setup(dut)

    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=10, full=0)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=FADD_S,
        is_fp_instruction=1,
        is_fp_compute=1,
        instruction=_make_instr(dest_reg=3, opcode=OPC_OP_FP),
    )
    await dut_if.step()

    assert dut_if.rat_alloc_valid, "RAT alloc should be valid for FP dest"
    assert dut_if.rat_alloc_dest_rf == 1, "dest_rf should be 1 (FP)"
    assert dut_if.rat_alloc_dest_reg == 3


@cocotb.test()
async def test_store_no_dest_rename(dut: Any) -> None:
    """SW has no destination register -> rat_alloc_valid=0."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=SW,
        instruction=_make_instr(dest_reg=0, opcode=OPC_STORE),
    )
    await dut_if.step()

    assert not dut_if.rat_alloc_valid, "SW should not rename a destination"


@cocotb.test()
async def test_x0_dest_no_rename(dut: Any) -> None:
    """ADD with rd=x0 should not rename (x0 is hardwired zero)."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=0, opcode=OPC_OP),
    )
    await dut_if.step()

    assert not dut_if.rat_alloc_valid, "ADD with rd=x0 should not trigger RAT rename"


# =============================================================================
# Checkpoint Tests
# =============================================================================


@cocotb.test()
async def test_branch_saves_checkpoint(dut: Any) -> None:
    """BEQ should trigger checkpoint save."""
    dut_if = await _setup(dut)

    dut_if.drive_checkpoint(available=True, alloc_id=2)
    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=7, full=0)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=BEQ,
        instruction=_make_instr(opcode=OPC_BRANCH),
    )
    await dut_if.step()

    assert dut_if.checkpoint_save, "BEQ should save checkpoint"
    assert dut_if.checkpoint_id == 2
    assert dut_if.checkpoint_branch_tag == 7


@cocotb.test()
async def test_jal_saves_checkpoint(dut: Any) -> None:
    """JAL should trigger checkpoint save."""
    dut_if = await _setup(dut)

    dut_if.drive_checkpoint(available=True, alloc_id=1)
    dut_if.drive_rob_alloc_resp(alloc_ready=1, alloc_tag=4, full=0)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=JAL,
        is_jump_and_link=1,
        instruction=_make_instr(dest_reg=1, opcode=OPC_JAL),
    )
    await dut_if.step()

    assert dut_if.checkpoint_save, "JAL should save checkpoint"
    assert dut_if.checkpoint_id == 1
    assert dut_if.checkpoint_branch_tag == 4


# =============================================================================
# Immediate Tests
# =============================================================================


@cocotb.test()
async def test_immediate_i_type(dut: Any) -> None:
    """ADDI should carry I-type immediate to RS dispatch."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADDI,
        immediate_i_type=42,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP_IMM),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["use_imm"] == 1, "ADDI should use immediate"
    assert rs["imm"] == 42, f"Expected imm=42, got {rs['imm']}"


@cocotb.test()
async def test_immediate_s_type(dut: Any) -> None:
    """SW should carry S-type immediate to RS dispatch."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=SW,
        immediate_s_type=100,
        instruction=_make_instr(opcode=OPC_STORE),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["use_imm"] == 1, "SW should use immediate"
    assert rs["imm"] == 100, f"Expected imm=100, got {rs['imm']}"


# =============================================================================
# Memory Attribute Tests
# =============================================================================


@cocotb.test()
async def test_memory_size_byte(dut: Any) -> None:
    """LB should set mem_size=MEM_SIZE_BYTE."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=LB,
        is_load_instruction=1,
        instruction=_make_instr(dest_reg=5, opcode=OPC_LOAD),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert (
        rs["mem_size"] == MEM_SIZE_BYTE
    ), f"Expected MEM_SIZE_BYTE, got {rs['mem_size']}"


@cocotb.test()
async def test_memory_signed(dut: Any) -> None:
    """LB sets mem_signed=1, LBU sets mem_signed=0."""
    dut_if = await _setup(dut)

    # LB: signed
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=LB,
        is_load_instruction=1,
        instruction=_make_instr(dest_reg=5, opcode=OPC_LOAD),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["mem_signed"] == 1, "LB should have mem_signed=1"

    # LBU: unsigned
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=LBU,
        is_load_instruction=1,
        instruction=_make_instr(dest_reg=5, opcode=OPC_LOAD),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["mem_signed"] == 0, "LBU should have mem_signed=0"


# =============================================================================
# Flush Test
# =============================================================================


@cocotb.test()
async def test_flush_prevents_dispatch(dut: Any) -> None:
    """Flush active should prevent dispatch from firing."""
    dut_if = await _setup(dut)

    dut_if.set_flush(True)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=ADD,
        instruction=_make_instr(dest_reg=5, opcode=OPC_OP),
    )
    await dut_if.step()

    assert not dut_if.stall, "Flush should not cause stall"
    req = dut_if.read_rob_alloc_req()
    assert req["alloc_valid"] == 0, "No dispatch should fire during flush"
    rs = dut_if.read_rs_dispatch()
    assert rs["valid"] == 0, "RS dispatch should not be valid during flush"


# =============================================================================
# CSR Info Test
# =============================================================================


@cocotb.test()
async def test_csr_info_in_rob_alloc(dut: Any) -> None:
    """CSR instruction stores csr_addr and csr_op in ROB alloc request."""
    dut_if = await _setup(dut)

    csr_addr_val = 0x300  # mstatus
    funct3_val = 0b001  # CSRRW

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=CSRRW,
        is_csr_instruction=1,
        csr_address=csr_addr_val,
        instruction=_make_instr(dest_reg=5, opcode=0b1110011, funct3=funct3_val),
    )
    await dut_if.step()

    req = dut_if.read_rob_alloc_req()
    assert req["alloc_valid"] == 1
    assert req["is_csr"] == 1, "Should be marked as CSR"
    assert req["csr_addr"] == csr_addr_val, f"csr_addr mismatch: {req['csr_addr']:#x}"
    assert req["csr_op"] == funct3_val, f"csr_op mismatch: {req['csr_op']}"


# =============================================================================
# FP Flags Test
# =============================================================================


@cocotb.test()
async def test_fp_flags_for_compute(dut: Any) -> None:
    """FP compute instruction should set has_fp_flags=1 in ROB alloc."""
    dut_if = await _setup(dut)

    dut_if.drive_instruction(
        valid=True,
        instruction_operation=FADD_S,
        is_fp_instruction=1,
        is_fp_compute=1,
        instruction=_make_instr(dest_reg=3, opcode=OPC_OP_FP),
    )
    await dut_if.step()

    req = dut_if.read_rob_alloc_req()
    assert req["has_fp_flags"] == 1, "FP compute should have has_fp_flags=1"


# =============================================================================
# Prediction Passthrough Test
# =============================================================================


@cocotb.test()
async def test_predicted_target_from_btb(dut: Any) -> None:
    """BTB prediction should pass through to RS dispatch."""
    dut_if = await _setup(dut)

    btb_target = 0x1000_0100
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=BEQ,
        btb_predicted_taken=1,
        btb_predicted_target=btb_target,
        instruction=_make_instr(opcode=OPC_BRANCH),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["predicted_taken"] == 1, "predicted_taken should be 1"
    assert (
        rs["predicted_target"] == btb_target
    ), f"predicted_target mismatch: {rs['predicted_target']:#x}"


# =============================================================================
# Dynamic Rounding Mode Test
# =============================================================================


@cocotb.test()
async def test_dynamic_rounding_mode(dut: Any) -> None:
    """FP instruction with rm=7 (DYN) should resolve from frm_csr."""
    dut_if = await _setup(dut)

    # Set frm CSR to RDN (0b010)
    dut_if.set_frm_csr(0b010)
    dut_if.drive_instruction(
        valid=True,
        instruction_operation=FADD_S,
        is_fp_instruction=1,
        is_fp_compute=1,
        fp_rm=0b111,  # DYN
        instruction=_make_instr(dest_reg=3, opcode=OPC_OP_FP),
    )
    await dut_if.step()

    rs = dut_if.read_rs_dispatch()
    assert rs["rm"] == 0b010, f"Expected resolved rm=0b010 (RDN), got {rs['rm']:#05b}"

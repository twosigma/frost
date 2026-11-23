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

"""Return-stack full-flush restore with EarlyJalrRecovery=0 and EarlyJalRecovery=1."""

from typing import Any

import cocotb
from cocotb_tests.integration.test_cpu_top import (
    System,
    addi,
    csr,
    load,
    store,
)


def _jal(rd: int, offset: int) -> int:
    """Encode a 32-bit JAL instruction."""
    imm20 = (offset >> 20) & 1
    imm10_1 = (offset >> 1) & 0x3FF
    imm11 = (offset >> 11) & 1
    imm19_12 = (offset >> 12) & 0xFF
    return (
        (imm20 << 31)
        | (imm10_1 << 21)
        | (imm11 << 20)
        | (imm19_12 << 12)
        | (rd << 7)
        | 0x6F
    )


def _divu(rd: int, rs1: int, rs2: int) -> int:
    """Encode a 64-bit DIVU instruction."""
    return (1 << 25) | (rs2 << 20) | (rs1 << 15) | (5 << 12) | (rd << 7) | 0x33


def _lui(rd: int, upper20: int) -> int:
    """Encode a LUI instruction."""
    return ((upper20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def _load_handler(s: System, handler: int) -> None:
    """Install a trap handler that reports mcause, mepc, mtval, x1, x6, and x7."""
    s.program(
        [
            csr(13, 0, 0x342, 2),  # csrr a3, mcause
            store(13, 12, 0x10, 3),
            csr(14, 0, 0x341, 2),  # csrr a4, mepc
            store(14, 12, 0x18, 3),
            csr(15, 0, 0x343, 2),  # csrr a5, mtval
            store(15, 12, 0x20, 3),
            store(1, 12, 0x28, 3),  # x1 (ra)
            store(6, 12, 0x30, 3),  # x6 (faulting address / quotient)
            store(7, 12, 0x38, 3),  # x7 (squashed callee marker)
            _jal(0, 0),
        ],
        handler,
    )


@cocotb.test()
async def direct_call_ras_push_restored_on_older_fault_without_early_jalr(
    dut: Any,
) -> None:
    """Restore the RAS after an older load fault discards an early-recovered JAL call.

    Built with EarlyJalrRecovery=0 and EarlyJalRecovery=1: a younger direct call
    launches early recovery and pushes its link onto the return stack, so a
    full flush for an older faulting load must restore the head's RAS snapshot.
    """
    s = System(dut)
    fault_address = 0x5000
    handler = s.boot + 0x100
    s.error_reads.add(fault_address)
    _load_handler(s, handler)

    # Eight instructions before call0 so call0 starts on an 8-byte boundary.
    setup = [
        0x0000_0517,  # auipc a0, 0
        addi(10, 10, 0x100),  # handler address
        csr(0, 10, 0x305),  # csrw mtvec, a0
        _lui(12, 0x40000),  # a2 = 0x4000_0000 (MMIO base)
        _lui(20, (fault_address * 9) >> 12),  # s4 = fault_address * 9
        addi(21, 0, 3),  # s5 = 3
        addi(1, 0, 0x234),  # ra = 0x234 (must survive squashed jal ra)
        addi(7, 0, 40),  # t2 = 40 (must survive squashed callee addi)
    ]
    call0_pc = s.boot + 4 * len(setup)
    ld_pc = call0_pc + 16
    call1_pc = call0_pc + 20
    jump_here = _jal(0, 0)
    body = [
        _jal(5, 8),  # jal t0, +8: pushes call0_pc + 4 onto RAS
        jump_here,
        _divu(6, 20, 21),  # two dependent divisions delay the faulting load
        _divu(6, 6, 21),
        load(11, 6, 0, 3),  # ld a1, 0(t1): faults at 0x5000
        _jal(1, 12),  # jal ra, +12: early JAL recovery pushes call1_pc + 4
        jump_here,
        jump_here,
        addi(7, 7, 1),  # squashed direct-call target
        jump_here,
    ]
    s.program(setup + body)

    cpu = dut.hart.cpu_inst
    front = cpu.if_stage_inst
    before_call: tuple[int, int, int] | None = None
    saw_speculative_push = False
    trap_cycle: int | None = None
    after_trap: tuple[int, int, int] | None = None

    def observe() -> None:
        nonlocal before_call, saw_speculative_push, trap_cycle, after_trap
        if (
            int(cpu.early_mispredict_active.value)
            and int(cpu.early_mispredict_pc.value) == call1_pc
        ):
            assert int(cpu.early_mispredict_is_jal.value) == 1
            assert int(cpu.early_mispredict_is_call.value) == 1
            before_call = (
                int(cpu.restored_ras_tos.value),
                int(cpu.restored_ras_valid_count.value),
                int(cpu.restored_ras_top.value),
            )
        if before_call is not None and trap_cycle is None:
            if (
                int(front.ras_checkpoint_valid_count.value) >= 2
                and int(front.ras_checkpoint_top.value) == call1_pc + 4
            ):
                saw_speculative_push = True
        if (
            trap_cycle is None
            and int(cpu.trap_taken.value)
            and int(cpu.rob_trap_pc.value) == ld_pc
        ):
            trap_cycle = s.cycle
        elif (
            trap_cycle is not None and after_trap is None and s.cycle >= trap_cycle + 3
        ):
            after_trap = (
                int(front.ras_checkpoint_tos.value),
                int(front.ras_checkpoint_valid_count.value),
                int(front.ras_checkpoint_top.value),
            )

    s.before_edge = observe
    await s.reset()
    await s.until_write(0x4000_0038)
    s.before_edge = None

    assert before_call is not None, "the younger direct call did not recover early"
    assert before_call[1] == 1 and before_call[2] == call0_pc + 4, before_call
    assert saw_speculative_push, "the early JAL call never pushed onto the RAS"
    assert after_trap is not None, "the older load did not trap"
    assert after_trap == before_call, (
        f"RAS leaked speculative JAL push across full flush: "
        f"before={before_call}, after={after_trap}"
    )

    values = {addr: value for _, addr, value in s.effects}
    assert values[0x4000_0010] == 5  # mcause: load access fault
    assert values[0x4000_0018] == ld_pc
    assert values[0x4000_0020] == fault_address
    assert values[0x4000_0028] == 0x234
    assert values[0x4000_0030] == fault_address
    assert values[0x4000_0038] == 40


@cocotb.test()
async def indirect_call_stays_commit_time_when_early_jalr_is_off(dut: Any) -> None:
    """Confirm EarlyJalrRecovery=0 in this build: a JALR does not recover early."""
    s = System(dut)
    fault_address = 0x5000
    handler = s.boot + 0x100
    s.error_reads.add(fault_address)
    _load_handler(s, handler)

    setup = [
        0x0000_0517,  # auipc a0, 0
        addi(10, 10, 0x100),  # handler address
        csr(0, 10, 0x305),  # csrw mtvec, a0
        _lui(12, 0x40000),  # a2 = 0x4000_0000
        _lui(20, (fault_address * 9) >> 12),  # s4 = fault_address * 9
        addi(21, 0, 3),  # s5 = 3
        addi(1, 0, 0x234),  # ra = 0x234
        addi(7, 0, 40),  # t2 = 40
        _lui(8, s.boot >> 12),  # s0 = 0x1000
        addi(8, 8, 4 * 10 + 32),  # s0 = target of jalr
    ]
    call0_pc = s.boot + 4 * len(setup)
    ld_pc = call0_pc + 16
    jalr_pc = call0_pc + 20
    jalr_target = call0_pc + 32
    jump_here = _jal(0, 0)
    body = [
        _jal(5, 8),
        jump_here,
        _divu(6, 20, 21),
        _divu(6, 6, 21),
        load(11, 6, 0, 3),
        (8 << 15) | (1 << 7) | 0x67,  # jalr ra, 0(s0)
        jump_here,
        jump_here,
        addi(7, 7, 1),
        jump_here,
    ]
    s.program(setup + body)

    cpu = dut.hart.cpu_inst
    recovery = cpu.early_misprediction_recovery_inst
    jalr_admitted: bool | None = None
    jalr_recovered_early = False

    def observe() -> None:
        nonlocal jalr_admitted, jalr_recovered_early
        if (
            int(recovery.i_is_jalr_issue.value)
            and int(recovery.i_branch_target_resolved.value) == jalr_target
        ):
            jalr_admitted = bool(int(recovery.jalr_admitted.value))
        if (
            int(cpu.early_mispredict_active.value)
            and int(cpu.early_mispredict_pc.value) == jalr_pc
        ):
            jalr_recovered_early = True

    s.before_edge = observe
    await s.reset()
    await s.until_write(0x4000_0038)
    s.before_edge = None

    assert jalr_admitted is False, f"expected EarlyJalrRecovery=0, got {jalr_admitted}"
    assert not jalr_recovered_early
    values = {addr: value for _, addr, value in s.effects}
    assert values[0x4000_0010] == 5
    assert values[0x4000_0018] == ld_pc
    assert values[0x4000_0028] == 0x234
    assert values[0x4000_0038] == 40

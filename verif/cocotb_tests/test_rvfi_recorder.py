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

"""Exercise retirement record capacity and delayed memory completion."""

from typing import Any

import cocotb
from cocotb.triggers import Timer

from cocotb_tests.cpu_structs import COMMIT_FIELDS
from cocotb_tests.test_rvfi_dii import decode_record

CAPACITY = 32


def commit(**fields: int) -> int:
    """Pack a retirement using the shared CPU field layout."""
    result = 0
    for name, width in COMMIT_FIELDS:
        result = (result << width) | fields.get(name, 0)
    return result


class Recorder:
    """Drive retirement and its delayed store and CSR observations."""

    def __init__(self, dut: Any) -> None:
        """Bind the harness."""
        self.dut = dut

    async def step(self, **inputs: int) -> None:
        """Apply one cycle, with all event strobes low unless specified."""
        d = self.dut
        d.i_clk.value = 0
        for name in (
            "commit_valid",
            "commit_2_valid",
            "xret_taken",
            "trap_taken",
            "trap_no_csr",
            "sq_commit_valid",
            "sq_commit_valid_2",
            "sq_write_en",
            "amo_write_en",
            "csr_wb_pending",
            "ma_assist_start",
            "ma_done",
            "ma_store",
            "ma_wb_valid",
            "ma_wb_fp",
            "ma_translate",
            "pc_update_en",
            "npc_sel",
        ):
            getattr(d, "i_" + name).value = 0
        for name, value in inputs.items():
            getattr(d, "i_" + name).value = value
        await Timer(2, unit="ns")
        d.i_clk.value = 1
        await Timer(2, unit="ns")

    async def reset(self, target: int, hang_limit: int = 200) -> None:
        """Clear the recorder and set the requested record count."""
        for signal in self.dut:
            if signal._name.startswith("i_"):
                signal.value = 0
        for index in range(16):
            self.dut.dii_insn[index].value = 0x13
        self.dut.dii_count.value = 16
        self.dut.event_target.value = target
        self.dut.hang_limit.value = hang_limit
        await self.step(rst=1)
        await self.step(rst=1)
        self.dut.i_rst.value = 0

    async def filler(self, count: int) -> None:
        """Retire compressed NOPs beyond the requested trace."""
        for index in range(count):
            await self.step(
                commit_valid=1,
                commit=commit(pc=0x100 + 2 * index, is_compressed=1),
            )

    def record(self, index: int) -> tuple:
        """Decode one stored retirement record."""
        return decode_record(int(self.dut.rvfi_record[index].value))


@cocotb.test()
async def delayed_store_tail(dut: Any) -> None:
    """Filler cannot overflow records while the last store drains."""
    r = Recorder(dut)
    await r.reset(3)
    await r.step(
        commit_valid=1,
        commit=commit(pc=0x40, is_store=1),
        commit_2_valid=1,
        commit_2=commit(pc=0x44),
    )
    await r.step(
        sq_commit_valid=1,
        commit_valid=1,
        commit=commit(pc=0x48),
        commit_2_valid=1,
        commit_2=commit(pc=0x4C),
    )
    assert int(dut.event_count.value) == 4
    assert r.record(2)[2]
    assert int(dut.rvfi_record[3].value) == 0
    await r.filler(2 * CAPACITY)
    assert not int(dut.done.value)
    assert not int(dut.error_flags.value)
    assert not r.record(0)[2]
    await r.step(
        sq_write_en=1,
        sq_write_addr=0x80000000,
        sq_write_data=0x123456789ABCDEF0,
        sq_write_strb=0xFF,
    )
    assert int(dut.done.value)
    record, next_pc, complete = r.record(0)
    assert complete
    assert (record.pc_rdata, next_pc) == (0x40, 0x44)
    assert (record.mem_addr, record.mem_wmask, record.mem_wdata) == (
        0x80000000,
        0xFF,
        0x123456789ABCDEF0,
    )
    assert r.record(2)[0].pc_rdata == 0x48
    assert int(dut.rvfi_record[3].value) == 0
    assert not int(dut.hung.value)


@cocotb.test()
async def missing_store_completion(dut: Any) -> None:
    """Filler retirement cannot conceal a store that never completes."""
    r = Recorder(dut)
    await r.reset(2, hang_limit=8)
    await r.step(commit_valid=1, commit=commit(pc=0x40, is_store=1))
    await r.step(sq_commit_valid=1, commit_valid=1, commit=commit(pc=0x44))
    await r.filler(12)
    assert int(dut.done.value)
    assert int(dut.hung.value)
    assert not r.record(0)[2]
    assert not int(dut.error_flags.value)


@cocotb.test()
async def full_capacity_dual_store_tail(dut: Any) -> None:
    """Both stores at the capacity boundary receive their ordered values."""
    r = Recorder(dut)
    await r.reset(CAPACITY)
    for index in range(0, CAPACITY - 2, 2):
        await r.step(
            commit_valid=1,
            commit=commit(pc=4 * index),
            commit_2_valid=1,
            commit_2=commit(pc=4 * (index + 1)),
        )
    await r.step(
        commit_valid=1,
        commit=commit(pc=120, is_store=1),
        commit_2_valid=1,
        commit_2=commit(pc=124, is_store=1),
    )
    await r.step(sq_commit_valid=1, sq_commit_valid_2=1)
    assert not int(dut.done.value)
    await r.filler(CAPACITY)
    assert not int(dut.error_flags.value)
    await r.step(
        sq_write_en=1,
        sq_write_addr=0x80000000,
        sq_write_data=0xAA,
        sq_write_strb=1,
    )
    assert not int(dut.done.value)
    await r.step(
        sq_write_en=1,
        sq_write_addr=0x80000000,
        sq_write_data=0x1122334455667788,
        sq_write_strb=0x30,
    )
    assert int(dut.done.value)
    a, _, a_complete = r.record(30)
    b, _, b_complete = r.record(31)
    assert a_complete and b_complete
    assert (a.pc_rdata, a.mem_addr, a.mem_wmask, a.mem_wdata) == (
        120,
        0x80000000,
        1,
        0xAA,
    )
    assert (b.pc_rdata, b.mem_addr, b.mem_wmask, b.mem_wdata) == (
        124,
        0x80000004,
        3,
        0x3344,
    )


@cocotb.test()
async def delayed_csr_tail(dut: Any) -> None:
    """Wait for the requested CSR record to receive its read value."""
    r = Recorder(dut)
    await r.reset(1)
    await r.step(
        commit_valid=1,
        commit=commit(pc=0x40, is_csr=1, dest_valid=1, dest_reg=5),
    )
    await r.filler(CAPACITY * 2)
    assert not int(dut.done.value)
    assert not int(dut.error_flags.value)
    await r.step(csr_wb_pending=1, csr_wb_data=0x1234)
    await r.step()
    assert int(dut.done.value)
    record, _, complete = r.record(0)
    assert complete
    assert (record.rd_addr, record.rd_wdata) == (5, 0x1234)


@cocotb.test()
async def excessive_requested_capacity(dut: Any) -> None:
    """Reject a request beyond the record array."""
    r = Recorder(dut)
    await r.reset(CAPACITY + 1)
    await r.step()
    assert int(dut.error_flags.value) & 2


@cocotb.test()
async def spaced_store_completions(dut: Any) -> None:
    """Reset the progress bound as each pending store completes."""
    r = Recorder(dut)
    await r.reset(3, hang_limit=8)
    await r.step(
        commit_valid=1,
        commit=commit(pc=0x40, is_store=1),
        commit_2_valid=1,
        commit_2=commit(pc=0x44, is_store=1),
    )
    await r.step(
        sq_commit_valid=1,
        sq_commit_valid_2=1,
        commit_valid=1,
        commit=commit(pc=0x48),
    )
    for address, value in ((0x80000000, 0x11), (0x80000008, 0x22)):
        await r.filler(6)
        assert not int(dut.done.value)
        assert not int(dut.hung.value)
        await r.step(
            sq_write_en=1,
            sq_write_addr=address,
            sq_write_data=value,
            sq_write_strb=0xFF,
        )
    assert int(dut.done.value)
    assert not int(dut.hung.value)
    assert not int(dut.error_flags.value)
    for index, value in enumerate((0x11, 0x22)):
        record, _, complete = r.record(index)
        assert complete
        assert (record.mem_addr, record.mem_wmask, record.mem_wdata) == (
            0x80000000 + 8 * index,
            0xFF,
            value,
        )


@cocotb.test()
async def misaligned_load_and_layout_advance(dut: Any) -> None:
    """Misaligned loads advance the stream layout on assist and retire once on completion."""
    r = Recorder(dut)
    await r.reset(3)
    dut.dii_insn[0].value = 0x00152503  # lw x10, 1(x10)
    dut.dii_insn[1].value = 0x00152187  # flw f3, 1(x10)
    dut.dii_insn[2].value = 0x00152003  # lw x0, 1(x10)
    await r.step(rst=1)
    dut.i_rst.value = 0

    # Integer load to x10.
    await r.step(
        ma_assist_start=1,
        trap_taken=1,
        trap_no_csr=1,
        trap_cause=4,
        trap_pc=0x80000000,
        trap_target=0x80000004,
        priv=3,
    )
    assert int(dut.event_count.value) == 0
    await r.step(pc_update_en=1, npc_sel=(1 << 1), trap_redirect_pc=0x80000004)
    assert int(dut.layout_pc.value) == 0x80000004
    assert int(dut.layout_index.value) == 1
    assert not int(dut.done.value)
    await r.step(
        ma_done=1,
        ma_wb_valid=1,
        ma_wb_fp=0,
        ma_wb_rd=10,
        ma_wb_data=0xFFFFFFFFDEADBEEF,
        priv=3,
    )
    assert int(dut.event_count.value) == 1
    rec0, next0, comp0 = r.record(0)
    assert comp0
    assert (rec0.pc_rdata, next0, rec0.insn, rec0.trap, rec0.mode) == (
        0x80000000,
        0x80000004,
        0x00152503,
        0,
        3,
    )
    assert (rec0.rd_addr, rec0.rd_wdata, rec0.mem_wmask) == (
        10,
        0xFFFFFFFFDEADBEEF,
        0,
    )

    # FP load leaves integer rd_addr and rd_wdata zero.
    await r.step(
        ma_assist_start=1,
        trap_taken=1,
        trap_no_csr=1,
        trap_cause=4,
        trap_pc=0x80000004,
        trap_target=0x80000008,
        priv=1,
    )
    await r.step(pc_update_en=1, npc_sel=(1 << 1), trap_redirect_pc=0x80000008)
    assert int(dut.layout_index.value) == 2
    await r.step(
        ma_done=1,
        ma_wb_valid=1,
        ma_wb_fp=1,
        ma_wb_rd=3,
        ma_wb_data=0xFFFFFFFF12345678,
        priv=1,
    )
    rec1, next1, comp1 = r.record(1)
    assert comp1
    assert (rec1.pc_rdata, next1, rec1.rd_addr, rec1.rd_wdata, rec1.mode) == (
        0x80000004,
        0x80000008,
        0,
        0,
        1,
    )

    # Load to x0 leaves rd_addr and rd_wdata zero.
    await r.step(
        ma_assist_start=1,
        trap_taken=1,
        trap_no_csr=1,
        trap_cause=4,
        trap_pc=0x80000008,
        trap_target=0x8000000C,
        priv=0,
    )
    await r.step(pc_update_en=1, npc_sel=(1 << 1), trap_redirect_pc=0x8000000C)
    await r.step(
        ma_done=1,
        ma_wb_valid=1,
        ma_wb_fp=0,
        ma_wb_rd=0,
        ma_wb_data=0x1122334455667788,
        priv=0,
    )
    await r.step()
    await r.step()
    assert int(dut.done.value)
    assert not int(dut.hung.value)
    assert not int(dut.error_flags.value)
    rec2, next2, comp2 = r.record(2)
    assert comp2
    assert (rec2.pc_rdata, next2, rec2.rd_addr, rec2.rd_wdata, rec2.mode) == (
        0x80000008,
        0x8000000C,
        0,
        0,
        0,
    )


@cocotb.test()
async def misaligned_store_within_and_across_page(dut: Any) -> None:
    """Misaligned stores report starting PA unless translated across a 4 KiB page."""
    r = Recorder(dut)
    await r.reset(4)
    cases = [
        # (pc, next_pc, size, translate, va, lower_pa, upper_pa, data, exp_addr, exp_mask, exp_data)
        (
            0x80000000,
            0x80000004,
            3,  # MEM_SIZE_DOUBLE
            0,  # Bare across 4 KiB boundary
            0x80001FFD,
            0x80001FFD,
            0x80002000,
            0x0123456789ABCDEF,
            0x80001FFD,
            0xFF,
            0x0123456789ABCDEF,
        ),
        (
            0x80000004,
            0x80000006,
            1,  # MEM_SIZE_HALF, compressed PC step +2
            1,  # Sv39 within page across 64-byte line
            0x0000103F,
            0x8020003F,
            0x80200040,
            0xFFFF_FFFF_FFFF_ABCD,
            0x8020003F,
            0x03,
            0x0000_0000_0000_ABCD,
        ),
        (
            0x80000006,
            0x8000000A,
            2,  # MEM_SIZE_WORD
            1,  # Sv39 cross-page: 3 low bytes, 1 high byte
            0x00001FFD,
            0x80200FFD,
            0x80205000,
            0xDEADBEEF_AABBCCDD,
            0x80205000,
            0x01,
            0x0000_0000_0000_00AA,
        ),
        (
            0x8000000A,
            0x8000000E,
            3,  # MEM_SIZE_DOUBLE
            1,  # Sv39 cross-page: 5 low bytes, 3 high bytes
            0x00001FFB,
            0x80200FFB,
            0x80209000,
            0x1122334455667788,
            0x80209000,
            0x07,
            0x0000_0000_0011_2233,
        ),
    ]
    for index, (
        pc,
        next_pc,
        size,
        translate,
        va,
        lower_pa,
        upper_pa,
        data,
        exp_addr,
        exp_mask,
        exp_data,
    ) in enumerate(cases):
        await r.step(
            ma_assist_start=1,
            trap_taken=1,
            trap_no_csr=1,
            trap_cause=6,
            trap_pc=pc,
            trap_target=next_pc,
            priv=3,
        )
        await r.step(pc_update_en=1, npc_sel=(1 << 1), trap_redirect_pc=next_pc)
        await r.step(
            ma_done=1,
            ma_store=1,
            ma_size=size,
            ma_translate=translate,
            ma_va=va,
            ma_lower_pa=lower_pa,
            ma_upper_pa=upper_pa,
            ma_store_data=data,
            priv=3,
        )
        rec, got_next, comp = r.record(index)
        assert comp
        assert (
            rec.pc_rdata,
            got_next,
            rec.trap,
            rec.rd_addr,
            rec.mem_addr,
            rec.mem_wmask,
            rec.mem_wdata,
        ) == (pc, next_pc, 0, 0, exp_addr, exp_mask, exp_data)
    await r.step()
    await r.step()
    assert int(dut.done.value)
    assert not int(dut.hung.value)
    assert not int(dut.error_flags.value)


@cocotb.test()
async def misaligned_second_part_fault(dut: Any) -> None:
    """Record one trap and reset the layout when a misaligned assist faults."""
    r = Recorder(dut)
    await r.reset(2)
    await r.step(
        ma_assist_start=1,
        trap_taken=1,
        trap_no_csr=1,
        trap_cause=4,
        trap_pc=0x80000000,
        trap_target=0x80000004,
        priv=1,
    )
    await r.step(pc_update_en=1, npc_sel=(1 << 1), trap_redirect_pc=0x80000004)
    assert (int(dut.layout_pc.value), int(dut.layout_index.value)) == (0x80000004, 1)
    # Second page faults: exception consumes word 0 and clears ma_active_q.
    await r.step(
        trap_taken=1,
        trap_no_csr=0,
        trap_cause=13,
        trap_pc=0x80000000,
        trap_target=0x80040000,
        priv=1,
    )
    assert int(dut.event_count.value) == 1
    await r.step(pc_update_en=1, npc_sel=(1 << 1), trap_redirect_pc=0x80040000)
    assert (int(dut.layout_pc.value), int(dut.layout_index.value)) == (0x80040000, 1)
    await r.step(commit_valid=1, commit=commit(pc=0x80040000), priv=3)
    await r.step()
    await r.step()
    assert int(dut.done.value)
    assert not int(dut.hung.value)
    assert not int(dut.error_flags.value)
    rec0, next0, comp0 = r.record(0)
    assert comp0
    assert (
        rec0.pc_rdata,
        next0,
        rec0.trap,
        rec0.rd_addr,
        rec0.mem_wmask,
        rec0.mode,
    ) == (
        0x80000000,
        0x80040000,
        1,
        0,
        0,
        1,
    )


@cocotb.test()
async def misaligned_assist_sequence_violation(dut: Any) -> None:
    """Completing a misaligned access without an active assist flags error bit 10."""
    r = Recorder(dut)
    await r.reset(1)
    await r.step(ma_done=1)
    assert int(dut.error_flags.value) & (1 << 10)

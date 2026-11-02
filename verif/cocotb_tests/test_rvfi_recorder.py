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
            "sq_commit_valid",
            "sq_commit_valid_2",
            "sq_write_en",
            "amo_write_en",
            "csr_wb_pending",
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

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

"""Full-core MOP state, dependent-consumer, privilege and reserved-parcel checks."""

from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge

from cocotb_tests.test_directed_traps import WfiBench
from encoders.instruction_encode import CSRAddress


class MopBench(WfiBench):
    """Observe retirement and side effects while feeding words to cpu_tb."""

    def __init__(self, dut: Any) -> None:
        """Start the fetch driver and retirement monitor."""
        super().__init__(dut)
        self.retired: set[int] = set()
        self.guard = False
        cocotb.start_soon(self.watch())

    async def watch(self) -> None:
        """Record both retirement slots and reject memory or CSR activity."""
        while True:
            await RisingEdge(self.clk)
            for slot in ("", "_2"):
                if int(getattr(self.core, f"dbg_commit{slot}_valid").value):
                    self.retired.add(
                        int(getattr(self.core, f"dbg_commit{slot}_pc").value)
                    )
                    if self.guard:
                        assert not (
                            int(
                                getattr(self.core, f"dbg_commit{slot}_dest_valid").value
                            )
                            and int(
                                getattr(self.core, f"dbg_commit{slot}_dest_rf").value
                            )
                        ), "MOP wrote an FP register"
            if self.guard:
                assert not int(self.core.csr_commit_fire.value), "MOP touched CSR state"
                assert not int(self.core.trap_taken.value), "MOP trapped"
                assert not int(self.dut.o_data_mem_read_enable.value), "MOP read memory"
                assert not int(self.dut.o_data_mem_bram_byte_wr_en.value), (
                    "MOP wrote memory"
                )

    async def word(self, value: int) -> int:
        """Feed a word at a word-aligned fetch PC and return that PC."""
        for _ in range(200):
            await FallingEdge(self.clk)
            await self.dut_if.wait_ready()
            pc = int(self.dut.o_pc.value)
            if not pc & 2:
                self.dut_if.instruction = value
                await RisingEdge(self.clk)
                return pc
            self.dut_if.instruction = 0x00010001
            await RisingEdge(self.clk)
        raise AssertionError("fetch did not reach a word boundary")

    async def drain(self) -> None:
        """Feed neutral words until the finite instruction stream has retired."""
        for _ in range(100):
            await self.feed(self.nop)

    def registers(self) -> list[int]:
        """Read all committed integer registers."""
        return [self.dut_if.read_register(reg) for reg in range(32)]

    def csrs(self) -> tuple[int, ...]:
        """Snapshot control and trap state, excluding advancing counters."""
        csr = self.core.csr_file_inst
        return tuple(
            int(getattr(csr, name).value)
            for name in (
                "mstatus",
                "mepc",
                "mcause",
                "mtval",
                "mscratch",
                "mtvec",
                "sepc",
                "scause",
                "stval",
                "sscratch",
                "stvec",
                "satp",
                "priv_q",
            )
        )


def _mop(n: int, rd: int, rr: bool) -> int:
    """Place the variant index into the ratified MOP opcode's free bits."""
    if rr:
        return (
            0x82004073 | (n >> 2) << 30 | (n & 3) << 26 | 31 << 20 | 31 << 15 | rd << 7
        )
    return (
        0x81C04073
        | (n >> 4) << 30
        | ((n >> 2) & 3) << 26
        | (n & 3) << 20
        | 31 << 15
        | rd << 7
    )


@cocotb.test()
async def test_mops_preserve_state_in_all_privileges(dut: Any) -> None:
    """Every MOP and NTL retires in M/S/U with only the specified GPR result.

    Each native MOP uses rd=x0 and rd=x31, with a later dependent ADDI.
    A preceding divide gives the named but unused source a live producer.
    Every compressed MOP also executes in both halfword positions.
    """
    bench = MopBench(dut)
    for mode in (3, 1, 0):
        bench.guard = False
        await bench.reset()
        await bench.write_csr(CSRAddress.MEPC, 3, 0x1000)
        await bench.write_csr(CSRAddress.MSTATUS, 4, mode << 11)
        if mode != 3:
            await bench.feed(bench.mret)
        await bench.drain()
        assert int(bench.core.csr_priv.value) == mode
        for reg in range(1, 32):
            await bench.word(bench.addi(reg, 0, reg * 7 + 1))
        await bench.drain()
        baseline_csrs = bench.csrs()
        bench.guard = True
        serial = 0
        cases: list[tuple[int, int | None]] = [
            (0x6001 | n << 7, None) for n in range(1, 16, 2)
        ]
        cases += [
            (_mop(n, rd, rr), rd)
            for rr, count in ((False, 32), (True, 8))
            for n in range(count)
            for rd in (0, 31)
        ]
        cases += [(0x33 | rs << 20, None) for rs in range(2, 6)]
        cases += [(0x9002 | rs << 2, None) for rs in range(2, 6)]
        for instruction, rd in cases:
            serial += 1
            bench.retired.clear()
            # DIV x31,x29,x28: creates a pending source tag before a MOP.
            await bench.word(0x02004033 | 28 << 20 | 29 << 15 | 31 << 7)
            expected = bench.registers()
            expected[31] = expected[29] // expected[28]
            pcs: list[int] = []
            if instruction & 3 != 3:
                pc = await bench.word(instruction | instruction << 16)
                pcs.extend((pc, pc + 2))
            else:
                pcs.append(await bench.word(instruction))
            if rd:
                expected[rd] = 0
            await bench.word(bench.addi(30, rd or 0, serial))
            expected[30] = serial
            await bench.drain()
            assert set(pcs) <= bench.retired, f"unretired {instruction:#x} mode={mode}"
            assert bench.registers() == expected, (
                f"GPR state {instruction:#x} mode={mode}"
            )
            assert bench.csrs() == baseline_csrs, (
                f"CSR state {instruction:#x} mode={mode}"
            )
        bench.guard = False


@cocotb.test()
async def test_reserved_compressed_mtval(dut: Any) -> None:
    """Reserved neighbours report their original parcel, not an expansion, in mtval."""
    bench = MopBench(dut)
    for parcel in (0x8C40, 0x9000, 0x9C79, 0x9C7D, 0x6201, 0x6801):
        await bench.reset()
        await bench.write_csr(CSRAddress.MTVEC, 3, 0x2000)
        await bench.drain()
        pc = await bench.word(parcel | 0x00010000)
        await bench.drain()
        csr = bench.core.csr_file_inst
        assert int(csr.mcause.value) == 2, f"cause {parcel:#x}"
        assert int(csr.mepc.value) == pc, f"PC {parcel:#x}"
        assert int(csr.mtval.value) == parcel, f"mtval {parcel:#x}"

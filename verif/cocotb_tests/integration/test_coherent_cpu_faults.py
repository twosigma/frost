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

"""Check coherent SC fault retirement through the CPU and its AXI ports."""

from typing import Any

import cocotb

from cocotb_tests.integration.test_cpu_top import System, addi, csr, load, trap_program


def literal(register: int, value: int) -> list[int]:
    """Encode an unsigned constant with eleven-bit immediate chunks."""
    chunks = []
    while value:
        chunks.append(value & 2047)
        value >>= 11
    result = [addi(register, 0, chunks.pop() if chunks else 0)]
    for chunk in reversed(chunks):
        result.append(
            (11 << 20) | (register << 15) | (1 << 12) | (register << 7) | 0x13
        )
        if chunk:
            result.append(
                (chunk << 20) | (register << 15) | (6 << 12) | (register << 7) | 0x13
            )
    return result


@cocotb.test()
async def sc_refill_fault_preserves_virtual_address(dut: Any) -> None:
    """Check SC cause, EPC, virtual fault address and completion disposal."""
    for translated in (False, True):
        s = System(dut)
        physical = 0x80000000
        virtual = 0x200000 if translated else physical
        body = []
        if translated:
            for address, pte in (
                (0x80002000, (0x80003 << 10) | 1),
                (0x80003008, (0x80000 << 10) | 0xC7),
            ):
                for byte in range(8):
                    s.memory[address + byte] = (pte >> (8 * byte)) & 255
            body += literal(11, (8 << 60) | 0x80002) + [csr(0, 11, 0x180), 0x12000073]
            body += literal(11, 0x20800) + [csr(0, 11, 0x300)]
        body += literal(4, virtual) + [addi(7, 0, 99)]
        body += [(2 << 27) | (4 << 15) | (3 << 12) | (5 << 7) | 0x2F]
        body += [load(8, 4, 128, 3)]
        fault_index = len(body)
        body += [(3 << 27) | (7 << 20) | (4 << 15) | (3 << 12) | (6 << 7) | 0x2F]
        assert len(body) < 56
        fault_pc = trap_program(s, body) + 4 * fault_index
        s.memory[physical] = 123
        await s.reset()
        for _ in range(20000):
            await s.step()
            if any(
                kind == "read" and addr == physical
                for _, kind, addr, *_ in s.transactions
            ):
                s.error_reads.add(physical)
                break
        else:
            raise AssertionError(
                f"LR did not reach memory: translated={translated}, effects={s.effects}, transactions={s.transactions[-25:]}"
            )
        assert await s.until_write(0x40000020) == virtual
        effects = {address: value for _, address, value in s.effects}
        assert effects[0x40000010] == 7
        assert effects[0x40000018] == fault_pc
        assert 0x40000008 not in effects
        assert physical not in effects
        assert (
            sum(
                kind == "read" and addr == physical
                for _, kind, addr, *_ in s.transactions
            )
            == 2
        )
        assert s.memory[physical] == 123


@cocotb.test()
async def debug_halt_waits_for_selected_sc(dut: Any) -> None:
    """Check delayed SC ownership and exact write completion before debug entry."""
    s = System(dut)
    address = 0x80000000
    body = literal(4, address) + [addi(7, 0, 99)]
    body += [(2 << 27) | (4 << 15) | (3 << 12) | (5 << 7) | 0x2F]
    body += [load(8, 4, 128, 3)]
    body += [(3 << 27) | (7 << 20) | (4 << 15) | (3 << 12) | (6 << 7) | 0x2F]
    s.program(body + [0x0000006F])
    s.memory[address] = 123
    await s.reset()
    for _ in range(20000):
        await s.step()
        if (
            sum(
                kind == "read" and addr == address
                for _, kind, addr, *_ in s.transactions
            )
            == 2
        ):
            assert int(dut.hart.coherent_atomic_live.value)
            s.reads = [
                (due + 100, ident, value, status)
                for due, ident, value, status in s.reads
            ]
            break
    else:
        raise AssertionError("The selected SC did not reach its refill")
    dut.i_dbg_haltreq.value = 1
    for _ in range(40):
        await s.step()
        assert not int(dut.o_dbg_parked.value)
        assert int(dut.hart.coherent_atomic_live.value)
    writes = 0
    for _ in range(20000):
        writes += int(dut.hart.coherent_sc_write_done.value)
        await s.step()
        if int(dut.o_dbg_parked.value):
            break
    else:
        raise AssertionError("Debug entry did not follow SC completion")
    assert writes == 1
    assert not int(dut.hart.coherent_atomic_live.value)
    assert not int(dut.hart.coherent_sc_pending.value)

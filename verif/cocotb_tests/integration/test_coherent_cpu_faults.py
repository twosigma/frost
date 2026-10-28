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

"""Check coherent atomic faults and debug entry through the CPU."""

from typing import Any

import cocotb

from cocotb_tests.integration.test_cpu_top import (
    System,
    addi,
    csr,
    load,
    store,
    trap_program,
)


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
async def sc_matches_cached_address_and_size(dut: Any) -> None:
    """Check exact cached LR/SC matching and uncached doubleword matching."""
    initial = 0x1122334455667788
    for cached in (False, True):
        for lr_size, sc_size, offset in ((2, 2, 4), (2, 3, 0), (3, 2, 0), (2, 2, 0)):
            system = System(dut)
            address = 0x80000000 if cached else 0x3000
            body = literal(4, address) + [addi(7, 0, 0x99), addi(9, 4, offset)]
            body += [(2 << 27) | (4 << 15) | (lr_size << 12) | (5 << 7) | 0x2F]
            body += [
                (3 << 27) | (7 << 20) | (9 << 15) | (sc_size << 12) | (6 << 7) | 0x2F
            ]
            body += [load(8, 4, 0, 3), 0x400005B7]
            body += [store(6, 11, 0x10, 3), store(8, 11, 0x18, 3), 0x0000006F]
            system.program(body)
            for byte in range(8):
                system.memory[address + byte] = (initial >> (8 * byte)) & 255
            await system.reset()
            observed = await system.until_write(0x40000018)
            effects = {addr: value for _, addr, value in system.effects}
            success = not cached or (lr_size == sc_size and offset == 0)
            mask = ((1 << (8 * (1 << sc_size))) - 1) << (8 * offset)
            expected = (
                (initial & ~mask) | (0x99 << (8 * offset)) if success else initial
            )
            context = (cached, lr_size, sc_size, offset)
            assert effects[0x40000010] == int(not success), context
            assert observed == expected, context


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


async def debug_go(system: System, address: int) -> None:
    """Redirect a parked CPU and hold GO through its acceptance edge."""
    dut = system.dut
    dut.i_dbg_go_addr.value = address
    dut.i_dbg_go.value = 1
    for _ in range(2000):
        await system.step()
        if int(dut.o_dbg_go_taken.value):
            break
    else:
        raise AssertionError("Debug command did not start")
    await system.step()
    dut.i_dbg_go.value = 0


@cocotb.test()
async def completed_step_precedes_following_atomic(dut: Any) -> None:
    """Check one stepped LR stops before a following SC or AMO can acquire."""
    for address, operation in (
        (0x80000000, 3),
        (0x80000000, 0),
        (0x3000, 3),
        (0x3000, 0),
    ):
        s = System(dut)
        stepped_pc = 0x2000
        s.program([0x0000006F])
        s.program([0x0000006F], 0x17C00)
        setup = literal(4, address) + [addi(7, 0, 99)]
        setup += literal(11, stepped_pc) + [csr(0, 11, 0x7B1)]
        setup += [addi(11, 0, 7), csr(0, 11, 0x7B0), 0x7B200073]
        s.program(setup, 0x1200)
        s.program(
            [csr(10, 0, 0x7B1, 2), 0x400005B7, store(10, 11, 0x30, 3), 0x00100073],
            0x1300,
        )
        s.program(
            [
                (2 << 27) | (4 << 15) | (3 << 12) | (5 << 7) | 0x2F,
                (operation << 27) | (7 << 20) | (4 << 15) | (3 << 12) | (6 << 7) | 0x2F,
                0x0000006F,
            ],
            stepped_pc,
        )
        s.memory[address] = 123
        await s.reset()
        dut.i_dbg_haltreq.value = 1
        for _ in range(2000):
            await s.step()
            if int(dut.o_dbg_parked.value):
                break
        else:
            raise AssertionError("Initial debug entry did not complete")
        dut.i_dbg_haltreq.value = 0
        await debug_go(s, 0x1200)
        for _ in range(2000):
            await s.step()
            if not int(dut.o_debug_mode.value):
                break
        else:
            raise AssertionError("Debug setup did not resume the stepped LR")
        retired = []
        for _ in range(2000):
            await s.step()
            valid = int(dut.o_debug_commit_valid.value)
            if valid & 1:
                retired.append(int(dut.o_debug_commit_pc.value))
            if valid & 2:
                retired.append(int(dut.o_debug_commit_2_pc.value))
            assert not int(dut.hart.coherent_atomic_live.value)
            if int(dut.o_dbg_parked.value):
                break
        else:
            raise AssertionError(
                f"Completed step did not enter debug: address={address:#x}, operation={operation}, retired={retired}"
            )
        assert s.memory[address] == 123
        assert retired == [stepped_pc], retired
        assert int(dut.hart.cpu_inst.csr_dpc.value) == stepped_pc + 4
        assert not int(dut.hart.cpu_inst.coherent_atomic_active.value)
        await debug_go(s, 0x1300)
        assert await s.until_write(0x40000030) == stepped_pc + 4
        for _ in range(2000):
            await s.step()
            if int(dut.o_dbg_parked.value):
                break
        else:
            raise AssertionError("Debug command did not finish after single-step entry")
        assert not int(dut.o_dbg_cmd_err.value)

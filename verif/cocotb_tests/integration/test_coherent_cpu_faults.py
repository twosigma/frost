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

"""Check coherent atomic faults, parked-hart service and reset through the CPU."""

from collections.abc import Callable
from typing import Any

import cocotb

from cocotb_tests.integration.test_cpu_top import (
    System as MemorySystem,
    addi,
    csr,
    load,
    store,
    trap_program,
)


class System(MemorySystem):
    """Enable DMA ingress while the CPU uses the shared home."""

    def __init__(self, dut: Any) -> None:
        """Keep the ordinary AXI memory and enable coherent observations."""
        super().__init__(dut, coherence=True)

    async def dma(
        self,
        address: int,
        data: int | None = None,
        check: Callable[[], None] | None = None,
    ) -> int:
        """Hold a line request through acceptance and collect its tagged response."""
        d = self.dut
        accepted = len(self.coherent_requests)
        returned = len(self.coherent_responses)
        d.i_coherent_req_addr.value = address
        d.i_coherent_req_id.value = 3
        d.i_coherent_req_write.value = int(data is not None)
        d.i_coherent_req_wdata.value = data or 0
        d.i_coherent_req_wstrb.value = 1 if data is not None else 0
        d.i_coherent_req_valid.value = 1
        for _ in range(20000):
            await self.step()
            if check:
                check()
            if len(self.coherent_requests) != accepted:
                break
        else:
            raise AssertionError("DMA request did not enter the home")
        d.i_coherent_req_valid.value = 0
        for _ in range(20000):
            if len(self.coherent_responses) != returned:
                ident, result, error = self.coherent_responses[returned]
                assert ident == 3 and not error
                return result
            await self.step()
            if check:
                check()
        raise AssertionError("DMA response did not complete")


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
async def misaligned_amo_does_not_arm(dut: Any) -> None:
    """Check an address fault precedes atomic ownership and memory effects."""
    for size, offset in ((2, 2), (3, 2), (3, 4)):
        system = System(dut)
        address = 0x80000000 + offset
        body = literal(4, address) + [addi(7, 0, 99)]
        fault_index = len(body)
        body += [(7 << 20) | (4 << 15) | (size << 12) | (6 << 7) | 0x2F]
        fault_pc = trap_program(system, body) + 4 * fault_index
        await system.reset()
        for _ in range(20000):
            await system.step()
            assert not int(dut.hart.cpu_inst.o_coherent_atomic_protected.value)
            effects = {addr: value for _, addr, value in system.effects}
            if 0x40000020 in effects:
                break
        else:
            raise AssertionError("Misaligned AMO did not report its exception")
        assert effects[0x40000010] == 6
        assert effects[0x40000018] == fault_pc
        assert effects[0x40000020] == address
        assert 0x40000008 not in effects
        assert not any(
            0x80000000 <= addr < 0x80000020 for _, _, addr, *_ in system.transactions
        )


@cocotb.test()
async def amo_refill_fault_releases_selected_owner(dut: Any) -> None:
    """Check a selected AMO reports its own clean fault without a write."""
    for size in (2, 3):
        system = System(dut)
        address = 0x80000000
        body = literal(4, address) + [addi(7, 0, 99)]
        fault_index = len(body)
        body += [(7 << 20) | (4 << 15) | (size << 12) | (6 << 7) | 0x2F]
        fault_pc = trap_program(system, body) + 4 * fault_index
        system.memory[address] = 123
        system.error_reads.add(address)
        await system.reset()
        protected = False
        for _ in range(20000):
            await system.step()
            protected |= bool(dut.hart.cpu_inst.o_coherent_atomic_protected.value)
            effects = {addr: value for _, addr, value in system.effects}
            if 0x40000020 in effects:
                break
        else:
            raise AssertionError("AMO refill fault did not report its exception")
        assert protected
        assert effects[0x40000010] == 7
        assert effects[0x40000018] == fault_pc
        assert effects[0x40000020] == 0
        assert 0x40000008 not in effects
        assert system.memory[address] == 123
        assert not int(dut.hart.coherent_atomic_live.value)
        assert not int(dut.hart.cpu_inst.o_coherent_atomic_protected.value)
        assert not any(
            kind == "write" and 0x80000000 <= addr < 0x80000020
            for _, kind, addr, *_ in system.transactions
        )


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


@cocotb.test()
async def parked_hart_serves_dirty_dma(dut: Any) -> None:
    """Service dirty DMA reads and byte writes during debug halt and WFI."""
    for debug in (True, False):
        s = System(dut)
        address = 0x80000000
        body = literal(4, address) + [addi(7, 0, 0x155), addi(8, 0, 0x166)]
        body += [store(7, 4, 0, 3), store(8, 4, 32, 3), 0x400005B7]
        body += [store(7, 11, 0x10, 3)]
        body += [0x0000006F] if debug else [0x10500073, 0x0000006F]
        s.program(body)
        s.program([0x0000006F], 0x17C00)
        await s.reset()
        assert await s.until_write(0x40000010) == 0x155
        if debug:
            dut.i_dbg_haltreq.value = 1
        for _ in range(2000):
            await s.step()
            parked = (
                bool(dut.o_dbg_parked.value)
                if debug
                else bool(dut.hart.cpu_inst.wfi_waiting_q.value)
            )
            if parked:
                break
        else:
            raise AssertionError(f"Hart did not park: debug={debug}")

        def check_parked() -> None:
            """Keep the selected park condition throughout coherence service."""
            if debug:
                assert int(dut.o_dbg_parked.value)
            else:
                assert int(dut.hart.cpu_inst.wfi_waiting_q.value)
                assert not int(dut.o_debug_mode.value)

        assert all(s.memory.get(address + offset, 0) == 0 for offset in range(64))
        assert await s.dma(address, check=check_parked) & ((1 << 64) - 1) == 0x155
        await s.dma(address + 32, 0x99, check=check_parked)
        assert await s.dma(address + 32, check=check_parked) & ((1 << 64) - 1) == 0x199
        assert await s.dma(address, check=check_parked) & ((1 << 64) - 1) == 0x155


@cocotb.test()
async def reset_drains_victim_before_id_reuse(dut: Any) -> None:
    """Drain an outstanding victim response across reset before its ID is reused."""
    s = System(dut)
    address = 0x80000000

    def program(first: int, second: int, marker: int = 0x28) -> None:
        """Dirty two lines that conflict in the shared array."""
        body = literal(4, address) + [addi(7, 0, first), addi(8, 0, second)]
        body += [store(7, 4, 0, 3), store(8, 4, 128, 3), 0x400005B7]
        body += [store(8, 11, marker, 3), 0x0000006F]
        s.program(body)

    program(0x55, 0x66, 0x20)
    await s.reset()
    for _ in range(20000):
        await s.step()
        victims = [r for r in s.replies if r[3] == address]
        if victims:
            break
    else:
        raise AssertionError("No dirty victim write reached memory")
    old = victims[0]
    assert not any(addr == address for _, addr in s.completed_writes)
    home = dut.cluster_memory.gen_coherent_tier.home
    assert int(home.wb_valid_q.value)
    s.replies = [
        (due + 2000, ident, status, addr) for due, ident, status, addr in s.replies
    ]
    request_cycles: list[int] = []
    aw_cycles: list[int] = []
    response_cycles: list[int] = []

    def observe_ownership() -> None:
        """Check request, AW and home response ownership before each clock edge."""
        if int(dut.i_rst.value):
            return
        completed = [cycle for cycle, addr in s.completed_writes if addr == address]
        if (
            int(home.o_mem_req_valid.value)
            and int(home.i_mem_req_ready.value)
            and int(home.o_mem_req_write.value)
        ):
            assert int(home.o_mem_req_addr.value) == address
            assert int(home.o_mem_req_id.value) == 16
            assert completed and completed[0] < s.cycle, "Home reused an undrained ID"
            request_cycles.append(s.cycle)
        if (
            int(dut.o_axi_awvalid.value)
            and int(dut.i_axi_awready.value)
            and (
                int(dut.o_axi_awaddr.value) == address
                or int(dut.o_axi_awid.value) == old[1]
            )
        ):
            assert int(dut.o_axi_awaddr.value) == address
            assert int(dut.o_axi_awid.value) == old[1]
            assert completed and completed[0] < s.cycle, "AW reused an undrained ID"
            aw_cycles.append(s.cycle)
        if int(home.i_mem_resp_valid.value) and int(home.i_mem_resp_id.value) & 16:
            assert len(completed) == 2, "Stale B completed the post-reset victim"
            assert request_cycles and aw_cycles
            assert not int(home.i_mem_resp_error.value)
            response_cycles.append(s.cycle)

    s.before_edge = observe_ownership
    dut.i_rst.value = 1
    program(0x77, 0x88)
    for _ in range(5):
        await s.step(reset=True)
    dut.i_rst.value = 0
    for _ in range(20000):
        await s.step()
        if response_cycles and not int(home.wb_valid_q.value):
            break
    else:
        raise AssertionError("Victim ID did not complete both ownership intervals")
    assert len(request_cycles) == len(aw_cycles) == len(response_cycles) == 1
    s.before_edge = None
    assert await s.until_write(0x40000028) == 0x88
    assert await s.dma(address) & ((1 << 64) - 1) == 0x77
    assert await s.dma(address + 128) & ((1 << 64) - 1) == 0x88

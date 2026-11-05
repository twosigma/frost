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
from cocotb_tests.cache.test_coherence_home import unpack


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
        # The evicting load depends on the LR's result, so its L2 refill
        # follows the LR's even when the L1D has several misses in flight.
        body += [(5 << 20) | (5 << 15) | (4 << 12) | (10 << 7) | 0x33]
        body += [(4 << 20) | (10 << 15) | (10 << 7) | 0x33]
        body += [load(8, 10, 128, 3)]
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

        l1d = dut.hart.gen_coherent_tier.hart_cache.l1d
        wrapper = dut.hart.cpu_inst.u_tomasulo
        cut_phases: set[int] = set()
        cut_captured = False
        cut_clean: bool | None = None
        cuts_completed = 0

        def check_cut_edges() -> None:
            """Follow the actual probe through capture, invalidation and reply."""
            nonlocal cut_captured, cut_clean, cuts_completed
            probe = unpack(
                int(l1d.i_p.value), (2, 6, 1, len(l1d.i_address), 2, 2, 9, 5, 3)
            )
            if int(l1d.i_p_valid.value) and int(l1d.o_p_ready.value) and probe[0] == 1:
                assert not cut_captured
                assert int(dut.hart.coherent_cut_hold.value)
                assert int(dut.hart.cut_addr.value) == probe[3]
                assert int(wrapper.u_lq.i_coherent_cut_addr.value) == probe[3]
                cut_captured = True
                cut_clean = None
                cut_phases.clear()
            if cut_captured:
                port = wrapper.u_coherence_port
                if int(port.o_admit_ready.value):
                    cut_clean = bool(int(port.o_admit_clean.value))
                phase = int(port.inval_phase_q.value)
                if phase:
                    cut_phases.add(phase)
                if int(l1d.o_r_valid.value) and int(l1d.i_r_ready.value):
                    # A clean admission skips the CPU invalidation phases.
                    assert cut_clean is not None
                    assert cut_phases == (set() if cut_clean else {1, 2, 3})
                    assert not int(dut.hart.coherent_cut_hold.value)
                    cut_captured = False
                    cuts_completed += 1

        s.before_edge = check_cut_edges
        assert all(s.memory.get(address + offset, 0) == 0 for offset in range(64))
        assert await s.dma(address, check=check_parked) & ((1 << 64) - 1) == 0x155
        await s.dma(address + 32, 0x99, check=check_parked)
        assert await s.dma(address + 32, check=check_parked) & ((1 << 64) - 1) == 0x199
        assert await s.dma(address, check=check_parked) & ((1 << 64) - 1) == 0x155
        assert cuts_completed == 1 and not cut_captured
        s.before_edge = None


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


@cocotb.test()
async def local_atomic_defers_control_entry_at_each_phase(dut: Any) -> None:
    """IRQ, debug and a younger exception preserve the local write exactly once."""
    address = 0x80000000
    cache = dut.hart.gen_coherent_tier.hart_cache.l1d
    cpu = dut.hart.cpu_inst
    for sc in (False, True):
        for entry in ("irq", "debug", "exception"):
            stages: tuple[int, ...] = (
                (1, 2, 9, 11, 12, 5, 6, 13) if sc else (1, 2, 9, 10, 11, 12, 5, 6, 13)
            )
            if entry == "exception":
                stages = (11,)
            for stage in stages:
                s = System(dut)
                body = literal(4, address) + [addi(7, 0, 11), store(7, 4, 0, 3)]
                body += [addi(2, 0, 8), csr(0, 2, 0x304), csr(0, 2, 0x300)]
                body += [addi(7, 0, 99)]
                if sc:
                    body += [(2 << 27) | (4 << 15) | (3 << 12) | (5 << 7) | 0x2F]
                atomic_offset = len(body) * 4
                body += [
                    ((3 << 27) if sc else 0)
                    | (7 << 20)
                    | (4 << 15)
                    | (3 << 12)
                    | (6 << 7)
                    | 0x2F
                ]
                body += [0 if entry == "exception" else 0x0000006F]
                atomic_pc = trap_program(s, body) + atomic_offset
                await s.reset()
                writes = 0
                triggered = False
                for _ in range(20000):
                    protected = int(cpu.coherent_atomic_active.value)
                    if protected and int(cache.phase_q.value) == stage:
                        # Only the atomic's lookup and write phases qualify.
                        op = int(cache.operation_q.value)
                        if int(cache.atomic_local_q.value) or op in (0, 6):
                            if entry == "irq":
                                dut.i_interrupts.value = 1
                            elif entry == "debug":
                                dut.i_dbg_haltreq.value = 1
                            triggered = True
                            break
                    await s.step()
                assert triggered, (sc, entry, stage)
                local_seen = bool(int(cache.atomic_local_q.value))
                for _ in range(20000):
                    writes += int(cache.atomic_done_q.value)
                    local_seen |= bool(int(cache.atomic_local_q.value))
                    if int(cpu.coherent_atomic_active.value):
                        assert not int(cpu.trap_taken.value)
                        assert not int(dut.o_dbg_parked.value)
                    if entry == "debug" and int(dut.o_dbg_parked.value):
                        break
                    if entry != "debug" and any(
                        addr == 0x40000020 for _, addr, _ in s.effects
                    ):
                        break
                    await s.step()
                else:
                    raise AssertionError(
                        f"control entry stalled: {sc=} {entry=} {stage=}"
                    )
                assert local_seen and writes == 1, (sc, entry, stage, writes)
                assert not int(cache.o_atomic_live.value)
                if entry != "debug":
                    effects = {addr: value for _, addr, value in s.effects}
                    assert effects[0x40000010] == (
                        (1 << 63) | 3 if entry == "irq" else 2
                    )
                    assert effects[0x40000018] == atomic_pc + 4
                    assert sum(addr == 0x40000010 for _, addr, _ in s.effects) == 1
                result = await s.dma(address)
                assert result & ((1 << 64) - 1) == (99 if sc else 110)


@cocotb.test()
async def atomic_latency_controls(dut: Any) -> None:
    """Measure warm Modified AMOs and SC on fresh Shared sectors."""
    cache = dut.hart.gen_coherent_tier.hart_cache.l1d
    cpu = dut.hart.cpu_inst
    for scenario in ("warm_amo", "warm_sc", "fresh_sc"):
        s = System(dut)
        address = 0x80000000
        body = literal(4, address) + [addi(7, 0, 1)]
        if scenario != "fresh_sc":
            body += [store(7, 4, 0, 3)]
        pcs = set()
        for index in range(8):
            if scenario != "warm_amo":
                body += [(2 << 27) | (4 << 15) | (3 << 12) | (5 << 7) | 0x2F]
            pcs.add(s.boot + 4 * len(body))
            body += [
                ((3 << 27) if scenario != "warm_amo" else 0)
                | (7 << 20)
                | (4 << 15)
                | (3 << 12)
                | (6 << 7)
                | 0x2F
            ]
            if scenario == "fresh_sc" and index != 7:
                body += [addi(4, 4, 32)]
        body += [0x400000B7, store(7, 1, 0x28, 3), 0x0000006F]
        s.program(body)
        await s.reset()
        reads = []
        retirements = []
        starts = []
        ends = []
        was_protected = False

        def observe() -> None:
            nonlocal was_protected
            protected = bool(int(cpu.coherent_atomic_active.value))
            if protected and not was_protected:
                starts.append(s.cycle)
            if was_protected and not protected:
                ends.append(s.cycle)
            was_protected = protected
            if (
                int(cache.i_read_valid.value) and int(cache.i_read_kind.value) == 2
            ) or (int(cache.i_sc_valid.value) and int(cache.o_sc_ready.value)):
                reads.append(s.cycle)
            valid = int(dut.o_debug_commit_valid.value)
            if valid & 1 and int(dut.o_debug_commit_pc.value) in pcs:
                retirements.append(s.cycle)
            if valid & 2 and int(dut.o_debug_commit_2_pc.value) in pcs:
                retirements.append(s.cycle)

        s.before_edge = observe
        assert await s.until_write(0x40000028) == 1
        assert len(reads) == len(retirements) == len(starts) == len(ends) == 8
        d_read = [b - a for a, b in zip(reads, retirements, strict=True)]
        d_guard = [b - a for a, b in zip(starts, ends, strict=True)]
        dut._log.info(
            "ATOMIC_TIMING %s request_to_retirement=%s protection=%s total=%d",
            scenario,
            d_read,
            d_guard,
            s.cycle,
        )


@cocotb.test()
async def reader_downgrade_sc_latency(dut: Any) -> None:
    """Measure successful SC after a coherent reader downgrades its sector."""
    s = System(dut)
    address = 0x80000000
    cache = dut.hart.gen_coherent_tier.hart_cache.l1d
    cpu = dut.hart.cpu_inst
    body = literal(4, address) + [addi(7, 0, 11), store(7, 4, 0, 3)]
    body += literal(9, 0x123456789ABCDEF) + [addi(10, 0, 3)]
    body += [(2 << 27) | (4 << 15) | (3 << 12) | (5 << 7) | 0x2F]
    body += [(1 << 25) | (10 << 20) | (9 << 15) | (5 << 12) | (9 << 7) | 0x33] * 3
    body += [addi(7, 0, 99)]
    sc_pc = s.boot + 4 * len(body)
    body += [(3 << 27) | (7 << 20) | (4 << 15) | (3 << 12) | (6 << 7) | 0x2F]
    body += [0x400000B7, store(6, 1, 0x28, 3), 0x0000006F]
    s.program(body)
    await s.reset()
    events: dict[str, int] = {}
    acquisitions = 0

    def observe() -> None:
        nonlocal acquisitions
        protected = bool(int(cpu.coherent_atomic_active.value))
        if protected:
            events.setdefault("guard_start", s.cycle)
        elif "guard_start" in events:
            events.setdefault("guard_end", s.cycle)
        if int(cache.i_sc_valid.value) and int(cache.o_sc_ready.value):
            assert "request" not in events
            events["request"] = s.cycle
        if "request" in events:
            acquisitions += bool(
                int(cache.o_d_valid.value) & int(cache.i_d_ready.value) & 1
            )
        valid = int(dut.o_debug_commit_valid.value)
        if (valid & 1 and int(dut.o_debug_commit_pc.value) == sc_pc) or (
            valid & 2 and int(dut.o_debug_commit_2_pc.value) == sc_pc
        ):
            assert "retire" not in events
            events["retire"] = s.cycle

    s.before_edge = observe
    for _ in range(20000):
        if int(cache.i_reservation_valid.value):
            break
        await s.step()
    else:
        raise AssertionError("LR did not establish a reservation")
    assert await s.dma(address) & ((1 << 64) - 1) == 11
    assert "request" not in events
    assert await s.until_write(0x40000028) == 0
    assert acquisitions == 1
    dut._log.info(
        "ATOMIC_TIMING reader_downgrade_sc request_to_retirement=%d protection=%d total=%d",
        events["retire"] - events["request"],
        events["guard_end"] - events["guard_start"],
        s.cycle,
    )
    assert await s.dma(address) & ((1 << 64) - 1) == 99


@cocotb.test()
async def local_amo_operators_widths_and_order_bits(dut: Any) -> None:
    """Every AMO W/D operator preserves neighbors for all aq/rl encodings."""
    initial = 0xF123456789ABCDEF
    operand = 0x812345670FEDCBA9
    address = 0x80000000
    for size, offset in ((2, 0), (2, 4), (3, 0)):
        bits = 8 * (1 << size)
        mask = (1 << bits) - 1
        old = (initial >> (offset * 8)) & mask
        rhs = operand & mask
        signed_old = old - (1 << bits) if old >> (bits - 1) else old
        signed_rhs = rhs - (1 << bits) if rhs >> (bits - 1) else rhs
        answers = {
            0: old + rhs,
            1: rhs,
            4: old ^ rhs,
            8: old | rhs,
            12: old & rhs,
            16: min(signed_old, signed_rhs),
            20: max(signed_old, signed_rhs),
            24: min(old, rhs),
            28: max(old, rhs),
        }
        for opcode, updated in answers.items():
            for order in range(4):
                s = System(dut)
                body = literal(4, address) + literal(7, initial)
                body += [store(7, 4, 0, 3), addi(9, 4, offset)]
                body += literal(7, operand)
                body += [
                    (opcode << 27)
                    | (order << 25)
                    | (7 << 20)
                    | (9 << 15)
                    | (size << 12)
                    | (6 << 7)
                    | 0x2F
                ]
                body += [
                    load(8, 4, 0, 3),
                    0x400000B7,
                    store(6, 1, 0x10, 3),
                    store(8, 1, 0x18, 3),
                    0x0000006F,
                ]
                s.program(body)
                await s.reset()
                result = await s.until_write(0x40000018)
                effects = {addr: value for _, addr, value in s.effects}
                expected = (initial & ~(mask << (offset * 8))) | (
                    (updated & mask) << (offset * 8)
                )
                assert result == expected, (size, offset, opcode, order)
                assert effects[0x40000010] == signed_old & ((1 << 64) - 1)

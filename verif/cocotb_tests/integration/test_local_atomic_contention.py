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

"""Exercise CPU SC completion while the cache defers competing home work."""

from typing import Any

import cocotb

from cocotb_tests.integration.test_coherent_cpu_faults import System, literal
from cocotb_tests.integration.test_cpu_top import addi, csr, load, store, trap_program


# operation_q's value for an SC.
SC_OPERATION = 6


@cocotb.test()
async def sc_retires_with_held_probe_grant_and_control_entry(dut: Any) -> None:
    """Complete a protected SC beside a younger same-set fill and DMA probe."""
    for debug in (False, True):
        s = System(dut)
        address = 0x80000000
        other = address + 256
        cache = dut.hart.gen_coherent_tier.hart_cache.l1d
        cpu = dut.hart.cpu_inst
        divider = cpu.u_tomasulo.u_muldiv_shim.u_divider
        body = literal(4, address) + literal(5, other)
        body += [addi(7, 0, 11), store(7, 4, 0, 3)]
        body += [addi(2, 0, 8), csr(0, 2, 0x304), csr(0, 2, 0x300)]
        body += literal(9, 0x123456789ABCDEF) + [addi(10, 0, 3)]
        body += [(2 << 27) | (4 << 15) | (3 << 12) | (6 << 7) | 0x2F]
        body += [(1 << 25) | (10 << 20) | (9 << 15) | (5 << 12) | (9 << 7) | 0x33] * 3
        body += [addi(7, 0, 99)]
        body += [(3 << 27) | (7 << 20) | (4 << 15) | (3 << 12) | (6 << 7) | 0x2F]
        body += [load(8, 5, 0, 3), 0x0000006F]
        trap_program(s, body)
        await s.reset()
        other_ids: set[int] = set()
        held_reads: list[tuple[int, int, int, int]] = []
        arm_cycle: int | None = None
        dma_offered = False
        control_offered = False
        overlap = False
        local_seen = False
        writes = 0
        divisions = 0
        release_memory = False
        overlap_phases: set[int] = set()

        def observe() -> None:
            nonlocal overlap, local_seen, writes, divisions
            if int(dut.o_axi_arvalid.value) and int(dut.i_axi_arready.value):
                if int(dut.o_axi_araddr.value) == other:
                    other_ids.add(int(dut.o_axi_arid.value))
            divisions += int(divider.i_start.value)
            local = bool(int(cache.atomic_local_q.value))
            local_seen |= local
            if local and int(cache.i_p_valid.value) and int(cache.grant_valid.value):
                assert not int(cache.o_p_ready.value)
                assert not int(cache.o_cut_hold.value)
                assert not int(cache.grant_ready.value)
                overlap = True
                overlap_phases.add(int(cache.phase_q.value))
            writes += int(cache.atomic_done_q.value)
            if int(cpu.coherent_atomic_active.value):
                assert not int(cpu.trap_taken.value) and not int(dut.o_dbg_parked.value)

        s.before_edge = observe
        for _ in range(20000):
            if arm_cycle is None and int(cpu.coherent_arm_valid.value):
                arm_cycle = s.cycle
            # Complete the younger fill once the SC's lookup starts. An earlier
            # forwarded grant would evict the SC's line from the single way.
            if divisions == 3 and int(cache.operation_q.value) == SC_OPERATION:
                release_memory = True
            if not release_memory:
                held_reads.extend(r for r in s.reads if r[1] in other_ids)
                s.reads = [r for r in s.reads if r[1] not in other_ids]
            elif held_reads:
                s.reads.extend(
                    (s.cycle, ident, value, status)
                    for _, ident, value, status in held_reads
                )
                held_reads.clear()
            if arm_cycle is not None and s.cycle >= arm_cycle and not dma_offered:
                dut.i_coherent_req_addr.value = address
                dut.i_coherent_req_id.value = 3
                dut.i_coherent_req_write.value = 0
                dut.i_coherent_req_valid.value = 1
                dma_offered = True
            if s.coherent_requests:
                dut.i_coherent_req_valid.value = 0
            if int(cache.atomic_local_q.value) and not control_offered:
                if debug:
                    dut.i_dbg_haltreq.value = 1
                else:
                    dut.i_interrupts.value = 1
                control_offered = True
            entered = (
                int(dut.o_dbg_parked.value)
                if debug
                else any(addr == 0x40000020 for _, addr, _ in s.effects)
            )
            if entered and s.coherent_responses:
                break
            await s.step()
        else:
            raise AssertionError(
                f"SC contention did not finish: {arm_cycle=} {other_ids=} {local_seen=} "
                f"{overlap=} {writes=} requests={s.coherent_requests} responses={s.coherent_responses}"
            )
        dut._log.info(
            "SC contention debug=%s overlap_phases=%s", debug, sorted(overlap_phases)
        )
        assert (
            other_ids and local_seen and overlap and control_offered and writes == 1
        ), overlap_phases
        assert {5, 6, 13} <= overlap_phases, overlap_phases
        assert s.coherent_responses == [(3, 99, 0)]
        assert not int(cache.o_atomic_live.value)

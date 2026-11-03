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

"""Capture MMU timing in application windows identified by sscratch."""

import json
from pathlib import Path
from typing import Any

from cocotb.triggers import RisingEdge, ReadOnly


async def capture(dut: Any, clock: Any, path: str) -> None:
    """Write translation, retirement, cancellation, and walk events as JSONL."""
    cpu = dut.cpu_and_memory_subsystem.cpu.hart.cpu_inst
    csr = cpu.csr_file_inst
    ptw = cpu.u_ptw
    dmmu = cpu.u_tomasulo.u_dmmu
    lq = cpu.u_tomasulo.u_lq
    immu = cpu.if_stage_inst.u_immu
    rob = cpu.u_tomasulo.u_rob
    output = Path(path).open("w", buffering=1)
    last_marker = 0
    last_fetch_vpn = -1
    allocations: dict[int, int] = {}
    pending: dict[int, dict[str, int]] = {}
    serial = 0
    flush_generation = 0
    try:
        while True:
            await RisingEdge(clock)
            await ReadOnly()
            marker = int(csr.sscratch.value)
            cycle = int(csr.cycle_counter.value)

            def emit(kind: str, **fields: Any) -> None:
                event = dict(cycle=cycle, marker=marker, kind=kind)
                event.update(fields)
                output.write(json.dumps(event) + "\n")

            if marker != last_marker:
                emit("marker", previous=last_marker)
                last_marker = marker
                last_fetch_vpn = -1
            for valid, tag_signal, value_signal in (
                (rob.o_commit_valid_raw, rob.head_idx, rob.head_value_eff),
                (rob.o_commit_2_valid_raw, rob.head_next_idx, rob.head_next_value_eff),
            ):
                if int(valid.value):
                    tag = int(tag_signal.value)
                    if tag in pending:
                        operation = pending.pop(tag)
                        assert operation["translated"] and not operation["fault"]
                        emit(
                            "data_retire",
                            tag=tag,
                            value=int(value_signal.value) & ((1 << 64) - 1),
                            **operation,
                        )
            full = int(rob.i_flush_all.value)
            partial = int(rob.i_flush_en.value)
            if full or partial:
                flush_generation += 1
                head = int(rob.head_idx.value)
                cut = int(rob.i_flush_tag.value)
                mask = (1 << len(rob.head_idx)) - 1
                after_commit = int(rob.i_flush_after_head_commit.value)
                if marker:
                    emit(
                        "flush",
                        generation=flush_generation,
                        full=full,
                        head=head,
                        cut=cut,
                    )
                for tag in list(pending):
                    if (
                        full
                        or after_commit
                        or ((tag - head) & mask) > ((cut - head) & mask)
                    ):
                        emit("data_cancel", tag=tag, **pending.pop(tag))
            for valid, tag_signal in (
                (rob.alloc_en, rob.tail_idx),
                (rob.alloc_en_2, rob.tail_idx_2),
            ):
                if int(valid.value):
                    tag = int(tag_signal.value)
                    assert tag not in pending
                    serial += 1
                    allocations[tag] = serial
            if int(dmmu.o_iss_out_valid.value):
                tag = int(dmmu.o_iss_out_rob_tag.value)
                if tag in pending:
                    operation = pending[tag]
                    assert not operation["translated"]
                    operation["translated"] = 1
                    operation["fault"] = int(dmmu.o_iss_out_fault.value)
                    emit(
                        "data_translation",
                        tag=tag,
                        pa=int(dmmu.o_iss_out_addr.value),
                        **operation,
                    )
            if not marker:
                continue
            if int(immu.i_active.value) and int(immu.o_pa_valid.value):
                vpn = int(immu.i_pc.value) >> 12
                if vpn != last_fetch_vpn:
                    emit("fetch_page_transition", vpn=vpn)
                    last_fetch_vpn = vpn
            if int(cpu.tlb_invalidate.value):
                emit("invalidate")
            if int(lq.o_l0_hit.value):
                emit("l0_hit")
            if int(lq.o_l0_fill.value):
                emit("l0_fill")
            if int(dmmu.i_iss_valid.value) and int(dmmu.i_active.value):
                tag = int(dmmu.i_iss_rob_tag.value)
                killed = bool(int(dmmu.i_flush_all.value) or int(dmmu.iss_killed.value))
                operation = dict(
                    identity=allocations[tag],
                    generation=flush_generation,
                    marker=marker,
                    translated=0,
                    fault=0,
                )
                emit(
                    "data_present",
                    va=int(dmmu.i_iss_va.value),
                    bypass=bool(int(dmmu.iss_can_bypass.value)),
                    tag=tag,
                    killed=killed,
                    **operation,
                )
                if not killed:
                    assert not int(dmmu.s0_valid_q.value)
                    assert tag not in pending
                    pending[tag] = operation
                    emit("data_accept", tag=tag, **operation)
            if int(ptw.i_req_valid.value) and int(ptw.o_req_ready.value):
                emit(
                    "walk",
                    vpn=int(ptw.i_req_vpn.value),
                    root=int(ptw.i_root_ppn.value),
                    instruction=not bool(int(cpu.walk_req_valid.value)),
                )
            if int(ptw.o_line_req_valid.value) and int(ptw.i_line_req_ready.value):
                emit(
                    "read",
                    level=int(ptw.level_q.value),
                    address=int(ptw.o_line_req_addr.value),
                    pte_address=int(ptw.pte_pa.value),
                )
            if int(ptw.i_line_resp_valid.value):
                emit("read_response", level=int(ptw.level_q.value))
            if int(ptw.o_resp_valid.value):
                emit("walk_response")
            if int(ptw.state_q.value) == 5:
                emit(
                    "cached_pte",
                    level=int(ptw.level_q.value),
                    discarded=int(ptw.discard_q.value),
                )
    finally:
        output.close()


async def capture_coherence(dut: Any, clock: Any, path: str) -> None:
    """Capture PTE reads and accepted home probe data without application markers."""
    top = dut.cpu_and_memory_subsystem.cpu
    hart = top.hart
    ptw = hart.cpu_inst.u_ptw
    cluster = top.cluster_memory
    pa_bits = len(ptw.o_line_req_addr)
    pa_mask = (1 << pa_bits) - 1
    with Path(path).open("w", buffering=1) as output:
        while True:
            await RisingEdge(clock)
            await ReadOnly()
            cycle = int(hart.cpu_inst.csr_file_inst.cycle_counter.value)

            def emit(kind: str, **fields: int) -> None:
                output.write(json.dumps(dict(cycle=cycle, kind=kind, **fields)) + "\n")

            if int(ptw.i_req_valid.value) and int(ptw.o_req_ready.value):
                emit(
                    "walk", vpn=int(ptw.i_req_vpn.value), root=int(ptw.i_root_ppn.value)
                )
            if int(ptw.o_line_req_valid.value) and int(ptw.i_line_req_ready.value):
                emit(
                    "read",
                    level=int(ptw.level_q.value),
                    pte_address=int(ptw.pte_pa.value),
                )
            if int(ptw.i_line_resp_valid.value):
                emit(
                    "read_response",
                    pte=int(ptw.pte_live.value),
                    error=int(ptw.i_line_resp_error.value),
                )
            if int(ptw.o_resp_valid.value):
                emit("walk_response", response=int(ptw.o_resp.value))
            if int(hart.o_coherent_d_valid.value) and int(
                hart.i_coherent_d_ready.value
            ):
                request = int(hart.o_coherent_d.value)
                if request >> (len(hart.o_coherent_d) - 4) == 6:
                    emit("read_once_ptw", address=(request >> 299) & pa_mask)
            if int(cluster.i_coherent_r_valid.value) and int(
                cluster.o_coherent_r_ready.value
            ):
                reply = int(cluster.i_coherent_r.value)
                if (reply >> 261) & 1:
                    # coh_r_t packs five status bits below its 256-bit data.
                    emit(
                        "probe_data",
                        address=(reply >> 265) & pa_mask,
                        data=(reply >> 5) & ((1 << 256) - 1),
                        error=reply & 1,
                    )

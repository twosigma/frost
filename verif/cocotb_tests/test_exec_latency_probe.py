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

"""Trace arithmetic issue, completion, and dependent-use cycles."""

import json
import os
import re
import subprocess
import struct
from dataclasses import asdict
from pathlib import Path
from typing import Any

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from cocotb_tests import test_real_program as program
from cocotb_tests.cpu_structs import ROB_ALLOC_REQ_FIELDS
from cocotb_tests.tomasulo.cdb_arbiter.cdb_arbiter_interface import (
    unpack_cdb_broadcast,
)
from cocotb_tests.tomasulo.fu_shims.fp_shim_interface import unpack_fu_complete
from cocotb_tests.tomasulo.reservation_station.rs_interface import unpack_rs_issue
from cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_interface import (
    unpack_alloc_response,
)


def unpack_fields(signal: Any, fields: list[tuple[str, int]]) -> dict[str, int]:
    """Decode a packed signal using its declared field widths."""
    assert len(signal) == sum(width for _, width in fields)
    value = int(signal.value)
    result = {}
    for name, width in reversed(fields):
        result[name] = value & ((1 << width) - 1)
        value >>= width
    return result


def expected_probe_result(phase: str, issue: dict[str, Any]) -> int:
    """Return the result for the probe's integer and exact double-precision vectors."""
    a, b, c = (issue[f"src{k}_value"] for k in (1, 2, 3))
    if phase.startswith("mulw"):
        word = a * b & 0xFFFFFFFF
        return (word if word < 0x80000000 else word - (1 << 32)) & ((1 << 64) - 1)
    if phase.startswith("mul"):
        return a * b & ((1 << 64) - 1)
    fa, fb, fc = (
        struct.unpack("<d", struct.pack("<Q", operand))[0] for operand in (a, b, c)
    )
    if phase.startswith("fadd"):
        result = fa + fb
    elif phase.startswith("fsub"):
        result = fa - fb
    elif phase.startswith("fmul"):
        result = fa * fb
    else:
        result = fa * fb + fc
    return struct.unpack("<Q", struct.pack("<d", result))[0]


@cocotb.test()
async def trace_exec_latency(dut: Any) -> None:
    """Run the arithmetic probe and record stable signals before each issue edge."""
    symbols = {
        name: int(address, 16)
        for address, name in re.findall(
            r"^([0-9a-f]+) \w (\S+)$",
            subprocess.check_output(
                ["riscv64-linux-nm", "-n", "../sw/apps/exec_latency_probe/sw.elf"],
                text=True,
            ),
            re.MULTILINE,
        )
    }
    await program.prepare_program_start(dut)
    program.start_clocks((dut.i_clk,), program.CLK_PERIOD_NS * 1000)
    program.start_cpu_clock(dut)
    cocotb.start_soon(program.generate_divided_clock(dut))
    program.hold_nic_without_mac_clocks(
        dut, (dut.cpu_and_memory_subsystem.soc.nic_access_q,)
    )
    dut.i_uart_rx.value = 1
    dut.i_external_interrupt.value = 0
    for _ in range(program.RESET_CYCLES):
        await RisingEdge(dut.i_clk)
    await program.wait_for_power_on_reset(dut)
    dut.i_rst_n.value = 1

    core = dut.cpu_and_memory_subsystem.cpu.hart.cpu_inst
    backend = core.u_tomasulo
    mul = backend.u_muldiv_shim
    fp = backend.u_fp_shim
    phases = (
        "mul_dep",
        "mulw_dep",
        "mul_ind",
        "fadd_dep",
        "fadd_gap_dep",
        "fmul_dep",
        "fma_dep",
        "fadd_ind",
        "fmul_ind",
        "fma_ind",
        "fmul_zero_dep",
        "fadd_inf_dep",
        "fadd_nan_dep",
        "fsub_zero_dep",
    )
    checks = {name: 0 for name in phases if name in symbols}
    pending: dict[int, tuple[str, int, set[str], set[str]]] = {}
    tag_to_pc: dict[int, int] = {}
    chains: dict[str, list[int]] = {
        name: [] for name in ("mul_dep", "mulw_dep") if name in symbols
    }
    default_trace = (
        "short.jsonl"
        if os.environ.get("FROST_EXECLAT_SHORT") == "1"
        else "baseline.jsonl"
    )
    output = Path(
        os.environ.get("FROST_EXECLAT_TRACE", f"../.exec_latency/{default_trace}")
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w") as stream:
        stream.write(json.dumps({"symbols": symbols}) + "\n")
        for cycle in range(100000):
            await FallingEdge(program.cpu_clock(dut))
            await ReadOnly()
            for suffix in ("", "_2"):
                req = unpack_fields(
                    getattr(backend, "i_alloc_req" + suffix), ROB_ALLOC_REQ_FIELDS
                )
                ready, tag, _ = unpack_alloc_response(
                    int(getattr(backend, "o_alloc_resp" + suffix).value)
                )
                if req["alloc_valid"] and ready:
                    tag_to_pc[tag] = req["pc"]
            row: dict[str, Any] = {
                "cycle": cycle,
                "mul_issue": unpack_rs_issue(int(backend.mul_rs_issue_w.value)),
                "fp_issue": unpack_rs_issue(int(backend.fp_rs_issue_w.value)),
                "mul_raw_valid": int(mul.multiplier_valid_output.value),
                "mul_tracker": [int(mul.mul_trk_valid[k].value) for k in range(6)],
                "mul_fifo_count": int(mul.mul_fifo_count.value),
                "mul_complete": unpack_fu_complete(int(mul.o_mul_fu_complete.value)),
                "fp_complete": unpack_fu_complete(int(backend.fp_shim_out.value)),
                "fp_adapter": unpack_fu_complete(
                    int(backend.fp_adapter_to_arbiter.value)
                ),
                "fp_state": int(fp.u_engine.state_q.value),
                "fp_busy": int(backend.fp_busy.value),
                "fp_pending": int(backend.fp_adapter_result_pending.value),
                "fp_ready": int(backend.fp_rs_fu_ready.value),
                "mul_ready": int(backend.mul_rs_fu_ready.value),
                "cdb_grant": int(backend.o_cdb_grant.value),
                "cdb_comb": asdict(
                    unpack_cdb_broadcast(int(backend.cdb_bus_comb.value))
                ),
                "cdb2_comb": asdict(
                    unpack_cdb_broadcast(int(backend.cdb_bus_2_comb.value))
                ),
                "cdb": asdict(
                    unpack_cdb_broadcast(int(backend.cdb_bus_qualified.value))
                ),
                "cdb2": asdict(
                    unpack_cdb_broadcast(int(backend.cdb_bus_2_qualified.value))
                ),
                "retire": int(core.dbg_commit_valid.value),
                "retire_pc": int(core.dbg_commit_pc.value),
                "retire2": int(core.dbg_commit_2_valid.value),
                "retire2_pc": int(core.dbg_commit_2_pc.value),
            }
            for name in ("mul_issue", "fp_issue"):
                if row[name]["valid"]:
                    row[name]["allocated_pc"] = tag_to_pc[row[name]["rob_tag"]]
            for name in ("mul_issue", "fp_issue"):
                issue = row[name]
                if not issue["valid"]:
                    continue
                for phase in checks:
                    if (
                        symbols[phase]
                        <= issue["allocated_pc"]
                        < symbols[phase + "_end"]
                    ):
                        tag = issue["rob_tag"]
                        assert tag not in pending, ("tag reused before completion", tag)
                        ports = (
                            {"mul_complete", "cdb"}
                            if name == "mul_issue"
                            else {"fp_complete", "fp_adapter", "cdb"}
                        )
                        pending[tag] = (
                            phase,
                            expected_probe_result(phase, issue),
                            ports,
                            set(),
                        )
                        break
            for name in ("mul_complete", "fp_complete", "fp_adapter", "cdb", "cdb2"):
                packet = row[name]
                if not packet["valid"] or packet["tag"] not in pending:
                    continue
                phase, expected, ports, seen = pending[packet["tag"]]
                port = "cdb" if name.startswith("cdb") else name
                if port not in ports:
                    continue
                assert packet["value"] == expected, (
                    phase,
                    cycle,
                    name,
                    packet,
                    expected,
                )
                assert packet["fp_flags"] == 0 and not packet["exception"], (
                    phase,
                    cycle,
                    name,
                    packet,
                )
                if port == "cdb":
                    assert port not in seen, ("duplicate CDB result", phase, packet)
                seen.add(port)
            for tag, (phase, _, ports, seen) in list(pending.items()):
                if ports == seen:
                    checks[phase] += 1
                    del pending[tag]
            for name, issues in chains.items():
                issue = row["mul_issue"]
                if (
                    issue["valid"]
                    and symbols[name] <= issue["allocated_pc"] < symbols[name + "_end"]
                ):
                    issues.append(cycle)
            stream.write(json.dumps(row) + "\n")
            pcs = [row["retire_pc"]] if row["retire"] else []
            if row["retire2"]:
                pcs.append(row["retire2_pc"])
            assert symbols["probe_fail"] not in pcs, "arithmetic probe failed"
            if symbols["probe_done"] in pcs:
                assert not pending, pending
                assert all(count == 64 for count in checks.values()), checks
                for name, issues in chains.items():
                    expected_interval = 8 if name == "mul_dep" else 5
                    assert len(issues) == 64, (name, issues)
                    intervals = [b - a for a, b in zip(issues, issues[1:])]
                    assert intervals == [expected_interval] * 63, (name, intervals)
                dut._log.info("EXECLAT arithmetic checks passed at cycle %d", cycle)
                return
    raise AssertionError("arithmetic probe timed out")

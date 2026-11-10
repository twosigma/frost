#    Copyright (c) 2026 John Goodacre
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

"""Debug probe: dump the cache hierarchy's registers once retirement stops.

Enabled with FROST_HANG_PROBE=<output file>. Every FROST_HANG_PROBE_STEP_NS
(default 5000 ns) the probe samples the CPU's retired-instruction count; once
it stays unchanged for FROST_HANG_PROBE_STEPS samples in a row (default 4), it
writes every signal of the L1D, its store buffer, the home and the home's
completion table to the file, twice, FROST_HANG_PROBE_GAP_NS apart (default
2000 ns), so the second dump shows what still moves, and then fails the test.
"""

import os
from typing import Any

import cocotb
from cocotb.triggers import RisingEdge, Timer
import cocotb.utils

L1D = "cpu_and_memory_subsystem.cpu.hart.gen_coherent_tier.hart_cache.l1d"
SCOPES = (
    L1D,
    L1D + ".store_buffer",
    "cpu_and_memory_subsystem.cpu.cluster_memory.gen_coherent_tier.home",
    "cpu_and_memory_subsystem.cpu.cluster_memory.gen_coherent_tier.home.completions",
    "cpu_and_memory_subsystem.cpu.hart.gen_coherent_tier.hart_cache",
    "cpu_and_memory_subsystem.cpu.hart.cpu_inst",
    *(f"{L1D}.gen_request[{ep}].request" for ep in range(6)),
)
RETIRED = (
    "cpu_and_memory_subsystem.cpu.hart.cpu_inst.csr_file_inst.instret_counter",
    "cpu_and_memory_subsystem.cpu.hart.cpu_inst.dbg_commit_pc",
)


def _resolve(dut: Any, path: str) -> Any:
    handle = dut
    for part in path.split("."):
        if part.endswith("]"):
            name, index = part[:-1].split("[")
            handle = getattr(handle, name)[int(index)]
        else:
            handle = getattr(handle, part)
    return handle


def _value(handle: Any) -> str | None:
    try:
        value = handle.value
    except Exception:
        return None
    try:
        return f"0x{int(value):x}"
    except Exception:
        try:
            return str(value)
        except Exception:
            return None


def _dump(dut: Any, out: Any, label: str) -> None:
    out.write(f"===== {label} =====\n")
    for scope in SCOPES:
        try:
            handle = _resolve(dut, scope)
        except (AttributeError, IndexError, KeyError, TypeError):
            out.write(f"## {scope}: not found\n")
            continue
        out.write(f"## {scope}\n")
        rows = []
        for child in handle:
            name = child._name
            text = _value(child)
            if text is not None:
                rows.append(f"{name} = {text}")
                continue
            try:
                length = len(child)
            except TypeError:
                length = 0
            if length and length <= 64:
                for index in range(length):
                    try:
                        element = _value(child[index])
                    except Exception:
                        element = None
                    if element is not None:
                        rows.append(f"{name}[{index}] = {element}")
        for row in sorted(rows):
            out.write(row + "\n")
    out.flush()


TRACE = (
    "phase_q",
    "operation_q",
    "grant_valid",
    "grant_ready",
    "grant_pick",
    "grant_ep_q",
    "ep_grant_valid",
    "ep_grant_ready",
    "live",
    "ld_done_q",
    "twin_fill_q",
    "twin_ep_q",
    "store_count",
    "store_head_index",
    "store_twin",
    "store_acquired",
    "wb_live",
    "probe_valid_q",
    "lane_busy_q",
    "grant_install",
    "store_pop",
)


async def l1d_trace(dut: Any, cpu_clock: Any, start: int, stop: int, path: str) -> None:
    """Log the L1D controller's handshakes on every CPU edge in [start, stop) ns."""
    await Timer(start, "ns")
    handles = []
    for name in TRACE:
        try:
            handles.append((name, _resolve(dut, f"{L1D}.{name}")))
        except Exception:
            continue
    last = None
    with open(path, "w", encoding="utf-8") as out:
        while True:
            await RisingEdge(cpu_clock)
            now = cocotb.utils.get_sim_time("ns")
            if now >= stop:
                break
            row = " ".join(f"{name}={_value(h)}" for name, h in handles)
            if row != last:
                out.write(f"{now:.1f} {row}\n")
                last = row


async def hang_probe(dut: Any, cpu_clock: Any) -> None:
    """Dump the hierarchy twice once retirement stops."""
    trace_from = os.environ.get("FROST_HANG_TRACE_FROM_NS")
    if trace_from:
        cocotb.start_soon(
            l1d_trace(
                dut,
                cpu_clock,
                int(trace_from),
                int(
                    os.environ.get(
                        "FROST_HANG_TRACE_TO_NS", str(int(trace_from) + 20000)
                    )
                ),
                os.environ["FROST_HANG_PROBE"] + ".trace",
            )
        )
    path = os.environ["FROST_HANG_PROBE"]
    step = int(os.environ.get("FROST_HANG_PROBE_STEP_NS", "5000"))
    steps = int(os.environ.get("FROST_HANG_PROBE_STEPS", "4"))
    gap = int(os.environ.get("FROST_HANG_PROBE_GAP_NS", "2000"))
    counter = None
    for candidate in RETIRED:
        try:
            counter = _resolve(dut, candidate)
            cocotb.log.info(f"HANG PROBE: watching {candidate}")
            break
        except AttributeError:
            continue
    assert counter is not None, "hang probe: no retirement signal"
    last = None
    same = 0
    while same < steps:
        await Timer(step, "ns")
        now = _value(counter)
        same = same + 1 if now == last else 0
        last = now
    cocotb.log.warning(f"HANG PROBE: retirement stopped at {last}")
    with open(path, "w", encoding="utf-8") as out:
        _dump(dut, out, "first")
        await Timer(gap, "ns")
        _dump(dut, out, "second")
    cocotb.log.warning(f"HANG PROBE: state written to {path}")
    raise AssertionError("retirement stopped (hang probe)")

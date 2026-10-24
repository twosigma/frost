# Copyright (c) 2026 John Goodacre.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Trace contract validation and coarse model/RTL event comparison."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any

EVENT_FIELDS = {
    "meta": {"rtl_commit", "clock_domain", "memory_configuration"},
    "dispatch": {"uops"},
    "retire": {"uops"},
    "cache_request": {"cache", "address", "is_write", "request_id"},
    "cache_response": {"cache", "request_id", "ok"},
    "mshr_allocate": {"cache", "slot", "line_address"},
    "mshr_release": {"cache", "slot", "line_address"},
    "axi_request": {"axi_id", "address", "is_write", "bytes"},
    "axi_response": {"axi_id", "ok"},
    "backpressure": {"resource", "reason"},
}


def read_trace(path: Path) -> list[dict[str, Any]]:
    """Read a JSONL trace and check it against the trace contract.

    Return the records in order. Raise ValueError for invalid JSON, a
    missing common or per-event field, an unknown event, a decreasing
    cycle, an AXI request that is not a 64-byte line, or a first record
    that is not the meta event.
    """
    events: list[dict[str, Any]] = []
    previous_cycle = -1
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"line {number}: invalid JSON: {error.msg}") from error
        if not isinstance(event, dict):
            raise ValueError(f"line {number}: event must be an object")
        missing = {"cycle", "event", "source"} - event.keys()
        if missing:
            raise ValueError(f"line {number}: missing common fields {sorted(missing)}")
        if not isinstance(event["cycle"], int) or event["cycle"] < previous_cycle:
            raise ValueError(f"line {number}: cycle must be a nondecreasing integer")
        if event["event"] not in EVENT_FIELDS:
            raise ValueError(f"line {number}: unsupported event {event['event']!r}")
        missing = EVENT_FIELDS[event["event"]] - event.keys()
        if missing:
            raise ValueError(
                f"line {number}: missing fields {sorted(missing)} for {event['event']}"
            )
        if event["event"] == "axi_request" and event["bytes"] != 64:
            raise ValueError(
                f"line {number}: AXI calibration requires 64-byte line requests"
            )
        previous_cycle = event["cycle"]
        events.append(event)
    if not events or events[0]["event"] != "meta":
        raise ValueError("first nonblank record must be a meta event")
    return events


def summarize(events: list[dict[str, Any]]) -> dict[str, Any]:
    """Return the trace's event counts, cycle span, and retired micro-ops."""
    counts = Counter(event["event"] for event in events)
    last_cycle = events[-1]["cycle"]
    return {
        "event_counts": dict(sorted(counts.items())),
        "cycles_observed": last_cycle + 1,
        "retired_uops": sum(
            event.get("uops", 0) for event in events if event["event"] == "retire"
        ),
    }


def compare_summary(
    observed: dict[str, Any], model: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Return the comparison record of a trace summary and a model run.

    With a model run, the record also holds the trace's cycles and
    retired micro-ops minus the model's.
    """
    result = {"observed": observed, "model": model, "status": "trace-valid"}
    if model:
        result["cycle_delta"] = observed["cycles_observed"] - int(
            model.get("cycles", 0)
        )
        result["retired_uop_delta"] = observed["retired_uops"] - int(
            model.get("retired", 0)
        )
        result["status"] = "comparison-recorded"
    return result


def rtl_figures(events: list[dict[str, Any]]) -> dict[str, Any]:
    """Return a trace's cycles, retired and dispatched micro-ops, IPC, and events."""
    summary = summarize(events)
    cycles = summary["cycles_observed"]
    retired = summary["retired_uops"]
    return {
        "cycles": cycles,
        "retired_uops": retired,
        "dispatched_uops": sum(
            event.get("uops", 0) for event in events if event["event"] == "dispatch"
        ),
        "ipc": retired / cycles if cycles > 0 else 0.0,
        "event_counts": summary["event_counts"],
    }


def model_figures(model: dict[str, Any]) -> dict[str, Any]:
    """Return a model run's cycles, retired micro-ops, and IPC."""
    cycles = int(model["cycles"])
    retired = int(model["retired"])
    return {
        "cycles": cycles,
        "retired_uops": retired,
        "ipc": retired / cycles if cycles > 0 else 0.0,
    }


def check_calibration(
    rtl: dict[str, Any],
    model: dict[str, Any],
    baseline: dict[str, Any],
    counters: dict[str, Any] | None = None,
) -> tuple[dict[str, float], list[str]]:
    """Compare a trace's figures with a model run's under a stored baseline.

    Return the deltas, as ratios minus one, and the reasons the check fails:
    a required event class missing from the trace, a trace whose cycles,
    micro-ops, or record counts disagree with the capture's pipeline
    counters, or a model IPC that differs from the RTL's by more than the
    baseline's ipc_tolerance.
    """
    failures = []
    missing = [
        name
        for name in baseline["required_events"]
        if not rtl["event_counts"].get(name)
    ]
    if missing:
        failures.append(f"the trace has no {', '.join(missing)} records")
    if counters is not None:
        events = rtl["event_counts"]
        dispatch = counters["dispatch_distribution"]
        commit = counters["commit_distribution"]
        axi = counters["axi_totals"]
        for figure, traced, counted in (
            ("cycles", rtl["cycles"], counters["cycles"]),
            ("retired_uops", rtl["retired_uops"], counters["retired_uops"]),
            (
                "dispatched_uops",
                rtl["dispatched_uops"],
                dispatch["total_dispatched_uops"],
            ),
            (
                "dispatch records",
                events.get("dispatch", 0),
                dispatch["cycles_1_uop"] + dispatch["cycles_2_uops"],
            ),
            (
                "retire records",
                events.get("retire", 0),
                commit["cycles_1_uop"] + commit["cycles_2_uops"],
            ),
            (
                "axi_request records",
                events.get("axi_request", 0),
                axi["ar_requests"] + axi["aw_requests"],
            ),
            (
                "axi_response records",
                events.get("axi_response", 0),
                axi["r_responses"] + axi["b_responses"],
            ),
        ):
            if traced != counted:
                failures.append(
                    f"the trace has {traced} {figure}, its counters {counted}"
                )
    if rtl["ipc"] <= 0 or model["ipc"] <= 0:
        failures.append("the trace or the model run retires nothing")
        return {}, failures
    stored_rtl, stored_model = baseline["rtl"], baseline["model"]
    deltas = {
        "model_vs_rtl_ipc": model["ipc"] / rtl["ipc"] - 1,
        "stored_model_vs_rtl_ipc": baseline["ipc_delta"],
        "rtl_ipc_since_stored": rtl["ipc"] / stored_rtl["ipc"] - 1,
        "rtl_cycles_since_stored": rtl["cycles"] / stored_rtl["cycles"] - 1,
        "model_ipc_since_stored": model["ipc"] / stored_model["ipc"] - 1,
    }
    tolerance = baseline["ipc_tolerance"]
    # The margin keeps a delta that equals the tolerance, but for rounding,
    # within it.
    if abs(deltas["model_vs_rtl_ipc"]) > tolerance + 1e-9:
        failures.append(
            f"the model's IPC differs from the RTL's by "
            f"{deltas['model_vs_rtl_ipc']:+.2%}, beyond the tolerance of {tolerance:.0%}"
        )
    return deltas, failures

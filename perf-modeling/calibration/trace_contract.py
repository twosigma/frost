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

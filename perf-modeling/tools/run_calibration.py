#!/usr/bin/env python3
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

"""Validate an RTL JSONL trace and write a provenance-bearing calibration record.

With --baseline, also check the trace against the model under a stored
baseline (perf-modeling/calibration/ci_baseline.json): print the model's and
the RTL's figures and their deltas, and exit with 1 if a required event
class is missing, the trace disagrees with --counters or --manifest, or the
model's IPC differs from the RTL's by more than the baseline's tolerance.
With --refresh as well, a passing check rewrites the baseline's figures.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from calibration.trace_contract import (
    check_calibration,
    compare_summary,
    model_figures,
    read_trace,
    rtl_figures,
    summarize,
)


def parse_args() -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--rtl-commit", required=True)
    parser.add_argument("--model-run", type=Path)
    parser.add_argument(
        "--baseline", type=Path, help="check the trace against this stored baseline"
    )
    parser.add_argument(
        "--counters", type=Path, help="the capture's pipeline counters to agree with"
    )
    parser.add_argument(
        "--manifest", type=Path, help="the capture's manifest, for the run's identity"
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="rewrite the baseline's figures if the check passes",
    )
    args = parser.parse_args()
    if (args.counters or args.manifest or args.refresh) and not args.baseline:
        parser.error("--counters, --manifest, and --refresh need --baseline")
    return args


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _model_run(workload: str, seed: int) -> dict[str, Any]:
    """Run the model's built-in workload with the baseline's seed."""
    import frost_perf_model

    return frost_perf_model.run_workload(frost_perf_model.ModelConfig(), workload, seed)


def _identity_failures(manifest: dict[str, Any], baseline: dict[str, Any]) -> list[str]:
    """Return the ways the capture's run differs from the baseline's."""
    failures = []
    if manifest["benchmark"] != baseline["benchmark"]:
        failures.append(
            f"the trace is of {manifest['benchmark']}, the baseline of "
            f"{baseline['benchmark']}"
        )
    tier = manifest["memory_configuration"]["tier"]
    if tier != baseline["memory_tier"]:
        failures.append(
            f"the trace is from the {tier} tier, the baseline from the "
            f"{baseline['memory_tier']} tier"
        )
    return failures


def _report(
    rtl: dict[str, Any],
    model: dict[str, Any],
    baseline: dict[str, Any],
    deltas: dict[str, float],
    failures: list[str],
) -> str:
    """Return the check's figures, deltas, and verdict as text."""
    stored_rtl, stored_model = baseline["rtl"], baseline["model"]
    lines = [
        f"RTL {baseline['benchmark']} ({baseline['memory_tier']}): "
        f"{rtl['cycles']} cycles, {rtl['retired_uops']} retired micro-ops, "
        f"IPC {rtl['ipc']:.4f} (stored {stored_rtl['ipc']:.4f})",
        f"model {baseline['model_workload']} (seed {baseline['model_seed']}): "
        f"{model['cycles']} cycles, {model['retired_uops']} retired micro-ops, "
        f"IPC {model['ipc']:.4f} (stored {stored_model['ipc']:.4f})",
    ]
    if deltas:
        lines += [
            f"model vs RTL IPC: {deltas['model_vs_rtl_ipc']:+.2%} "
            f"(stored {deltas['stored_model_vs_rtl_ipc']:+.2%}, "
            f"tolerance {baseline['ipc_tolerance']:.0%})",
            "since the stored figures: "
            f"RTL IPC {deltas['rtl_ipc_since_stored']:+.2%}, "
            f"RTL cycles {deltas['rtl_cycles_since_stored']:+.2%}, "
            f"model IPC {deltas['model_ipc_since_stored']:+.2%}",
        ]
    counts = ", ".join(
        f"{name} {rtl['event_counts'].get(name, 0)}"
        f" (stored {stored_rtl['event_counts'].get(name, 0)})"
        for name in baseline["required_events"]
    )
    lines.append(f"events: {counts}")
    lines += [f"FAIL: {reason}" for reason in failures] or ["PASS"]
    return "\n".join(lines)


def main() -> int:
    """Write the calibration record; with --baseline, run the check."""
    args = parse_args()
    events = read_trace(args.trace)
    if events[0]["rtl_commit"] != args.rtl_commit:
        raise SystemExit("trace meta rtl_commit does not match --rtl-commit")
    baseline = _read_json(args.baseline) if args.baseline else None
    if args.model_run:
        model = _read_json(args.model_run)
    elif baseline is not None:
        model = _model_run(baseline["model_workload"], baseline["model_seed"])
    else:
        model = None
    record = compare_summary(summarize(events), model)
    record.update(
        {
            "rtl_commit": args.rtl_commit,
            "trace": str(args.trace),
            "calibration_status": "valid trace only; fit parameters only with archived directed-case evidence",
        }
    )
    failures: list[str] = []
    if baseline is not None:
        assert model is not None
        rtl = rtl_figures(events)
        modelled = model_figures(model)
        counters = _read_json(args.counters) if args.counters else None
        deltas, failures = check_calibration(rtl, modelled, baseline, counters)
        if args.manifest:
            failures += _identity_failures(_read_json(args.manifest), baseline)
        record["check"] = {
            "baseline": str(args.baseline),
            "rtl": rtl,
            "model": modelled,
            "deltas": deltas,
            "failures": failures,
            "passed": not failures,
        }
        print(_report(rtl, modelled, baseline, deltas, failures))
        if args.refresh and not failures:
            baseline["rtl"] = {"commit": args.rtl_commit, **rtl}
            baseline["model"] = modelled
            baseline["ipc_delta"] = deltas["model_vs_rtl_ipc"]
            args.baseline.write_text(
                json.dumps(baseline, indent=2) + "\n", encoding="utf-8"
            )
            print(f"Rewrote the figures in {args.baseline}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

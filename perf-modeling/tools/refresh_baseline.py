#!/usr/bin/env python3
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

"""Capture the CI calibration trace on the current RTL and refresh its baseline.

Run it in the frost image after an intentional performance change:

    ./scripts/frost.py run python3 perf-modeling/tools/refresh_baseline.py

It cleans tests/, runs the baseline's test in its memory tier with the
calibration capture on and its default window and run, as CI's check does,
and runs run_calibration.py with --refresh, which rewrites the baseline's
figures if the check passes. The capture's files stay in tests/calibration/.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

PERF_MODELING = Path(__file__).resolve().parents[1]
REPO_ROOT = PERF_MODELING.parent
BASELINE = PERF_MODELING / "calibration" / "ci_baseline.json"
CAPTURE = REPO_ROOT / "tests" / "calibration"
# Settings that would move the capture's window or run away from CI's.
WINDOW_VARIABLES = (
    "FROST_CALIBRATION_TARGET_RUN",
    "FROST_CALIBRATION_START_PC",
    "FROST_CALIBRATION_STOP_PC",
)


def main() -> int:
    """Capture the trace, then check it and rewrite the baseline's figures."""
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    test = baseline["test"]
    files = {
        "FROST_CALIBRATION_TRACE_PATH": CAPTURE / f"{test}.jsonl",
        "FROST_CALIBRATION_COUNTERS_PATH": CAPTURE / f"{test}_counters.json",
        "FROST_CALIBRATION_MANIFEST_PATH": CAPTURE / f"{test}_manifest.json",
    }
    environment = {
        name: value
        for name, value in os.environ.items()
        if name not in WINDOW_VARIABLES
    }
    environment.update({name: str(path) for name, path in files.items()})
    environment["FROST_CALIBRATION_TEST"] = test
    environment["FROST_COCOTB_MEM_CONFIG"] = baseline["memory_tier"]
    tests = REPO_ROOT / "tests"
    # Files from an earlier capture must not stand in for this run's.
    for path in files.values():
        path.unlink(missing_ok=True)
    subprocess.run(["make", "clean"], cwd=tests, check=True)
    subprocess.run(
        ["./test_run_cocotb.py", test], cwd=tests, env=environment, check=True
    )
    commit = json.loads(
        files["FROST_CALIBRATION_TRACE_PATH"].open(encoding="utf-8").readline()
    )["rtl_commit"]
    return subprocess.run(
        [
            sys.executable,
            str(PERF_MODELING / "tools" / "run_calibration.py"),
            "--trace",
            str(files["FROST_CALIBRATION_TRACE_PATH"]),
            "--counters",
            str(files["FROST_CALIBRATION_COUNTERS_PATH"]),
            "--manifest",
            str(files["FROST_CALIBRATION_MANIFEST_PATH"]),
            "--baseline",
            str(BASELINE),
            "--rtl-commit",
            commit,
            "--out",
            str(CAPTURE / f"{test}_calibration.json"),
            "--refresh",
        ],
        check=False,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())

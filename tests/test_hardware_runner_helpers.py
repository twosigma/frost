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

"""Fast regression tests for hardware-runner policy helpers."""

import importlib.util
import os
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SW_APPS_DIR = Path(__file__).resolve().parents[1] / "sw" / "apps"
sys.path.insert(0, str(SW_APPS_DIR))
try:
    from software_registry import coremark_pro_hardware_timeout
finally:
    sys.path.pop(0)


def _load_sweep_coremark_pro() -> Any:
    """Load the standalone sweep script without leaking its import paths."""
    module_path = REPO_ROOT / "fpga" / "sweep_coremark_pro.py"
    spec = importlib.util.spec_from_file_location(
        "frost_sweep_coremark_pro_test", module_path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    original_path = sys.path.copy()
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = original_path
    return module


sweep_coremark_pro: Any = _load_sweep_coremark_pro()


def test_x3_zip_timeout_honors_workload_floor() -> None:
    """Official ZIP setup must not be mistaken for a 300-second hang."""
    assert coremark_pro_hardware_timeout("coremark_pro_zip", "x3", 300.0) == 600.0


def test_x3_zip_timeout_keeps_larger_base() -> None:
    """A caller's larger diagnostic budget must remain effective."""
    assert coremark_pro_hardware_timeout("coremark_pro_zip", "x3", 900.0) == 900.0


def test_timeout_floor_is_workload_and_board_specific() -> None:
    """Ordinary workloads and uncalibrated boards keep the common budget."""
    assert coremark_pro_hardware_timeout("coremark_pro_core", "x3", 17.0) == 17.0
    assert (
        coremark_pro_hardware_timeout("coremark_pro_zip", "future_board", 17.0) == 17.0
    )


def test_sweep_applies_timeout_floor_without_leaking_to_next_workload(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The sweep must pass each workload its independently resolved timeout."""
    observed_timeouts: list[tuple[str, float]] = []

    def fake_run_one(
        _repo: Path,
        _serial_fd: int,
        _board: str,
        app: str,
        mode: str,
        timeout_s: float,
        _loader_extra: list[str],
        _target: str,
    ) -> dict[str, Any]:
        observed_timeouts.append((app, timeout_s))
        return {
            "app": app,
            "workload": None,
            "mode": mode,
            "status": "PASS",
            "elapsed": 0.0,
            "iterations": None,
            "secs": None,
            "ips": None,
            "serial": "",
            "loader_tail": [],
        }

    serial_fd = os.open(os.devnull, os.O_RDONLY)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "sweep_coremark_pro.py",
            "--board",
            "x3",
            "-v1",
            "--timeout",
            "17",
            "coremark_pro_zip",
            "coremark_pro_core",
        ],
    )
    monkeypatch.setattr(sweep_coremark_pro, "serial_holders", lambda _serial: [])
    monkeypatch.setattr(
        sweep_coremark_pro, "configure_serial", lambda _serial: serial_fd
    )
    monkeypatch.setattr(sweep_coremark_pro, "run_one", fake_run_one)

    assert sweep_coremark_pro.main() == 0
    assert observed_timeouts == [
        ("coremark_pro_zip", 600.0),
        ("coremark_pro_core", 17.0),
    ]

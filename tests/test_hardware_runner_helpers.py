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

"""Tests for the CoreMark-PRO hardware timeout minimums and the sweep that uses them."""

import importlib.util
import os
import sys
from pathlib import Path
from types import SimpleNamespace
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
    """On x3, ZIP's timeout rises to the 600-second minimum that covers its setup."""
    assert coremark_pro_hardware_timeout("coremark_pro_zip", "x3", 300.0) == 600.0


def test_x3_zip_timeout_keeps_larger_base() -> None:
    """A base timeout above the minimum is kept."""
    assert coremark_pro_hardware_timeout("coremark_pro_zip", "x3", 900.0) == 900.0


def test_timeout_floor_is_workload_and_board_specific() -> None:
    """Workloads and boards with no listed minimum keep the base timeout."""
    assert coremark_pro_hardware_timeout("coremark_pro_core", "x3", 17.0) == 17.0
    assert (
        coremark_pro_hardware_timeout("coremark_pro_zip", "future_board", 17.0) == 17.0
    )


def test_sweep_applies_timeout_floor_without_leaking_to_next_workload(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Each workload in the sweep gets its own timeout; ZIP's minimum stays with ZIP."""
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


def _sweep_one_capture(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], uart: str
) -> tuple[str, str]:
    """Sweep coremark_pro_sha once over a scripted load and UART capture.

    The loader prints the load sentinel and exits, then the UART delivers
    ``uart``. Returns the RESULT and SUMMARY lines for the workload.
    """
    loader_fd, loader_write = os.pipe()
    serial_fd, serial_write = os.pipe()
    pending = {
        loader_fd: [f"{sweep_coremark_pro.LOAD_COMPLETE_SENTINEL}\n".encode()],
        serial_fd: [uart.encode()],
    }

    class FinishedLoader:
        returncode = 0

        def __init__(self, *_args: Any, **_kwargs: Any) -> None:
            self.stdout = SimpleNamespace(fileno=lambda: loader_fd)

        def poll(self) -> int:
            return 0

    def select(
        readable: list[int], _write: list[int], _error: list[int], _timeout: float
    ) -> tuple[list[int], list[int], list[int]]:
        # The UART reports data only once the loader is done, as on a board,
        # where the program starts after the load sentinel.
        if loader_fd in readable:
            return [], [], []
        return [fd for fd in readable if pending[fd]], [], []

    monkeypatch.setattr(
        sys,
        "argv",
        ["sweep_coremark_pro.py", "--board", "x3", "-v1", "coremark_pro_sha"],
    )
    monkeypatch.setattr(sweep_coremark_pro, "serial_holders", lambda _serial: [])
    monkeypatch.setattr(
        sweep_coremark_pro, "configure_serial", lambda _serial: serial_fd
    )
    monkeypatch.setattr(sweep_coremark_pro, "drain", lambda _fd: None)
    monkeypatch.setattr(
        sweep_coremark_pro,
        "read_available",
        lambda fd: pending[fd].pop(0) if pending[fd] else b"",
    )
    monkeypatch.setattr(sweep_coremark_pro, "select", SimpleNamespace(select=select))
    monkeypatch.setattr(sweep_coremark_pro.subprocess, "Popen", FinishedLoader)
    try:
        assert sweep_coremark_pro.main() == 0
    finally:
        for fd in (loader_fd, loader_write, serial_write):
            os.close(fd)
    lines = capsys.readouterr().out.splitlines()
    result = next(line for line in lines if line.startswith("RESULT x3 "))
    summary = next(line for line in lines if line.startswith("x3 coremark_pro_sha "))
    return result, summary


def _mith_report(workload_time: str, workload_line: bool = True) -> str:
    """Return a -v1 MITH report for sha-test: the workload block, then its item."""
    lines = [
        "-- Workload:sha-test=1234",
        "-- sha-test:time(ns)=15000",
        "-- sha-test:contexts=1",
        "-- sha-test:iterations=1",
    ]
    if workload_line:
        lines.append(f"-- sha-test:time(secs)={workload_time}")
    lines += [
        "-- sha-test:secs/workload= 1.5e-05",
        "-- sha-test:workloads/sec=   66666.7",
        "Info: This run was executed with verification turned on! For performance "
        "results, use -v0.",
        "-- sha:UID=5678",
        "-- sha:fails=0",
        "-- sha:time(secs)=  0.0625",
        "-- sha:secs/item=  0.0625",
        "-- Done:sha-test=1234",
        "<<PASS>>",
    ]
    return "\n".join(lines) + "\n"


def test_sweep_reports_a_workload_time_printed_in_exponent_form(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """RESULT and SUMMARY show the workload's time(secs), including %g exponents."""
    result, summary = _sweep_one_capture(monkeypatch, capsys, _mith_report(" 1.5e-05"))
    assert result.endswith("PASS time=1.5e-05")
    assert "PASS time=1.5e-05 " in summary


def test_sweep_never_reports_an_item_time_as_the_workload_time(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Without the workload's own time(secs) line, no time is shown.

    The -v1 item lines use the same key, and their times are not the
    workload's.
    """
    result, summary = _sweep_one_capture(
        monkeypatch, capsys, _mith_report("", workload_line=False)
    )
    assert result.endswith("PASS time=None")
    assert summary.endswith("PASS time=None")


def test_workload_perf_ignores_an_item_named_like_its_workload() -> None:
    """Only the workload block is parsed; CoreMark-PRO's core has an item named core.

    With the workload's own time(secs) line lost, alone or with every line up to
    the item's, the item's time must not stand in for it, or the iter/s, and so
    the official mark, would come from the item.
    """
    lines = [
        "-- Workload:core=490760323",
        "-- core:time(ns)=15000",
        "-- core:contexts=1",
        "-- core:iterations=10",
        "-- core:secs/workload=    0.25",
        "-- core:workloads/sec=       4",
        "Info: This run was executed with verification turned on! For performance "
        "results, use -v0.",
        "-- core:UID=1",
        "-- core:fails=0",
        "-- core:time(secs)=     1.5",
        "-- core:secs/item=     1.5",
        "-- Done:core=490760323",
        "<<PASS>>",
    ]
    lost = "\r\n".join(lines) + "\r\n"
    assert sweep_coremark_pro.parse_workload_perf(lost, "core") == {
        "iterations": None,
        "secs": None,
        "ips": None,
    }
    # A byte lost from the item's first line as well.
    garbled = lost.replace("-- core:UID=", "- core:UID=")
    assert sweep_coremark_pro.parse_workload_perf(garbled, "core")["secs"] is None
    # Everything from the workload's time line to the item's lost at once.
    spliced = "\r\n".join(lines[:4] + lines[9:]) + "\r\n"
    assert "iterations=10\r\n-- core:time(secs)=     1.5\r\n" in spliced
    assert sweep_coremark_pro.parse_workload_perf(spliced, "core")["secs"] is None
    lines.insert(4, "-- core:time(secs)=     2.5")
    intact = "\r\n".join(lines) + "\r\n"
    assert sweep_coremark_pro.parse_workload_perf(intact, "core") == {
        "iterations": 10,
        "secs": 2.5,
        "ips": 4.0,
    }


@pytest.mark.parametrize(
    ("iterations", "total", "each", "expected"),
    [
        ("10", " 1.5e-05", " 1.5e-06", (10, 1.5e-05)),
        ("10", "   1e-05", "   1e-06", (10, 1e-05)),
        ("10", "    12.5", "    1.25", (10, 12.5)),
        # Each time rounded to six digits, in opposite directions.
        ("11", " 1.10001", "     0.1", (11, 1.10001)),
        # A zero time, which cannot confirm the iteration count.
        ("10", "       0", "       0", (None, 0.0)),
        # Forms %g never prints.
        ("10", "  1.5e-", " 1.5e-06", (None, None)),
        ("10", "  1.5e-0", " 1.5e-06", (None, None)),
        ("10", "      12.", "     1.2", (None, None)),
        ("10", "     2.5?", "    0.25", (None, None)),
        ("1?", "     2.5", "    0.25", (None, None)),
        # Well-formed values that lost a digit or a decimal point.
        ("10", "     1.5", "    1.25", (None, None)),
        ("10", "     125", "    1.25", (None, None)),
        ("1", "    12.5", "    1.25", (None, None)),
        ("10", "    12.5", "     1.5", (None, None)),
    ],
)
def test_workload_perf_reads_a_damaged_value_as_missing(
    iterations: str, total: str, each: str, expected: tuple[int | None, float | None]
) -> None:
    """Values count only from an intact report of the workload's times.

    Every number must end its line in a form %g prints, and iterations times
    secs/workload must match time(secs) within %g's six-digit rounding. A number
    that lost UART bytes, such as ``1.5e-``, ``12.``, or ``12.5`` read as
    ``1.5`` or ``125``, makes both values read as missing instead of as others.
    A zero time reads as 0 with the iteration count missing.
    """
    lines = [
        "-- Workload:core=490760323",
        "-- core:contexts=1",
        f"-- core:iterations={iterations}",
        f"-- core:time(secs)={total}",
        f"-- core:secs/workload={each}",
        "-- core:workloads/sec=     0.8",
    ]
    perf = sweep_coremark_pro.parse_workload_perf("\r\n".join(lines) + "\r\n", "core")
    assert (perf["iterations"], perf["secs"]) == expected

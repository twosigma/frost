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

"""Tests for the real-program bench's calibration capture, on a stand-in DUT."""

import importlib
import json
import logging
import sys
from pathlib import Path
from typing import Any

import cocotb
import pytest

VERIF_DIR = Path(__file__).resolve().parents[1] / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

calibration_trace = importlib.import_module("cocotb_tests.calibration_trace")
cpu_structs = importlib.import_module("cocotb_tests.cpu_structs")
packed_structs = importlib.import_module("utils.packed_structs")

CORE = calibration_trace.CORE_PATH
CPU_TOP = calibration_trace.CPU_TOP_PATH
SLOT2 = f"{CORE}.from_id_to_ex_2"
SLOT2_WIDTH = sum(width for _, width in cpu_structs.ID_TO_EX_FIELDS)


class _Node:
    """A stand-in DUT scope and signal; any child path exists unless absent."""

    def __init__(self, path: str, absent: set[str], widths: dict[str, int]) -> None:
        self._path = path
        self._absent = absent
        self._widths = widths
        self._children: dict[str, _Node] = {}
        self.value: Any = 0

    def __getattr__(self, name: str) -> "_Node":
        if name.startswith("_"):
            raise AttributeError(name)
        path = f"{self._path}.{name}" if self._path else name
        if path in self._absent:
            raise AttributeError(name)
        if name not in self._children:
            self._children[name] = _Node(path, self._absent, self._widths)
        return self._children[name]

    def __len__(self) -> int:
        return self._widths.get(self._path, 1)


def _dut(absent: frozenset[str] = frozenset(), slot2_width: int = SLOT2_WIDTH) -> _Node:
    return _Node("", set(absent), {SLOT2: slot2_width})


def _drive(dut: _Node, values: dict[str, int]) -> None:
    """Set each named signal, and clear every other signal the capture reads."""
    for path in _SIGNALS:
        node: Any = dut
        for part in path.split("."):
            node = getattr(node, part)
        node.value = values.get(path, 0)


_SIGNALS = [
    f"{CORE}.dbg_commit_valid",
    f"{CORE}.dbg_commit_pc",
    f"{CORE}.dbg_commit_2_valid",
    f"{CORE}.dbg_commit_2_pc",
    calibration_trace.COMMIT_MISPREDICTION_PATH,
    f"{CORE}.dbg_rob_alloc_valid",
    f"{CORE}.dbg_dispatch_stall",
    f"{CORE}.dbg_pipeline_stall",
    f"{CORE}.rob_count",
    f"{CORE}.sq_count",
    SLOT2,
    *(
        f"{CPU_TOP}.{port}"
        for port in (
            "o_axi_arvalid",
            "i_axi_arready",
            "o_axi_arid",
            "o_axi_araddr",
            "o_axi_awvalid",
            "i_axi_awready",
            "o_axi_awid",
            "o_axi_awaddr",
            "i_axi_rvalid",
            "o_axi_rready",
            "i_axi_rid",
            "i_axi_rresp",
            "i_axi_bvalid",
            "o_axi_bready",
            "i_axi_bid",
            "i_axi_bresp",
        )
    ),
]


@pytest.fixture(autouse=True)
def _environment(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Give cocotb a log and clear the capture's settings."""
    monkeypatch.setattr(cocotb, "log", logging.getLogger("test"), raising=False)
    for name in (
        "FROST_CALIBRATION_TRACE_PATH",
        "FROST_CALIBRATION_COUNTERS_PATH",
        "FROST_CALIBRATION_MANIFEST_PATH",
        "FROST_CALIBRATION_TARGET_RUN",
        "FROST_CALIBRATION_START_PC",
        "FROST_CALIBRATION_STOP_PC",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.chdir(tmp_path)


def test_capture_is_off_without_a_trace_path_or_for_another_run(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Only the target run, the last one by default, records a trace."""
    trace = calibration_trace.CalibrationTrace
    assert trace.from_environment(_dut(), "hello_world", 2, 2) is None
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(tmp_path / "t.jsonl"))
    assert trace.from_environment(_dut(), "hello_world", 1, 2) is None
    assert trace.from_environment(_dut(), "hello_world", 2, 2) is not None
    monkeypatch.setenv("FROST_CALIBRATION_TARGET_RUN", "1")
    assert trace.from_environment(_dut(), "hello_world", 1, 2) is not None


def test_missing_signals_fail_the_capture(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A build without a signal the capture reads fails and names the signal."""
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(tmp_path / "t.jsonl"))
    absent = frozenset({f"{CORE}.rob_count", f"{CPU_TOP}.i_axi_bid"})
    with pytest.raises(
        AssertionError,
        match=(
            "FROST_CALIBRATION_TRACE_PATH needs signals this build does not expose: "
            f"{CORE}.rob_count, {CPU_TOP}.i_axi_bid$"
        ),
    ):
        calibration_trace.CalibrationTrace.from_environment(
            _dut(absent), "hello_world", 2, 2
        )


def test_a_slot2_layout_of_another_width_fails_the_capture(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The slot-2 packet must match its cpu_structs layout."""
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(tmp_path / "t.jsonl"))
    with pytest.raises(AssertionError, match="bits wide"):
        calibration_trace.CalibrationTrace.from_environment(
            _dut(slot2_width=SLOT2_WIDTH + 1), "hello_world", 2, 2
        )


def test_the_window_runs_from_the_start_pc_to_the_stop_pc(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The trace starts the cycle after the start PC retires and ends with the stop PC."""
    trace_path = tmp_path / "t.jsonl"
    counters_path = tmp_path / "counters.json"
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(trace_path))
    monkeypatch.setenv("FROST_CALIBRATION_COUNTERS_PATH", str(counters_path))
    monkeypatch.setenv("FROST_CALIBRATION_START_PC", "0x100")
    monkeypatch.setenv("FROST_CALIBRATION_STOP_PC", "0x200")
    dut = _dut()
    capture = calibration_trace.CalibrationTrace.from_environment(
        dut, "hello_world", 2, 2
    )
    assert capture is not None
    real_slot2 = packed_structs.pack_struct(cpu_structs.ID_TO_EX_FIELDS, {"is_real": 1})
    cycles = [
        # The start PC retires: the window opens on the next cycle.
        {f"{CORE}.dbg_commit_valid": 1, f"{CORE}.dbg_commit_pc": 0x100},
        # Two micro-ops dispatch, and an AXI read is accepted.
        {
            f"{CORE}.dbg_rob_alloc_valid": 1,
            SLOT2: real_slot2,
            f"{CORE}.rob_count": 4,
            f"{CPU_TOP}.o_axi_arvalid": 1,
            f"{CPU_TOP}.i_axi_arready": 1,
            f"{CPU_TOP}.o_axi_arid": 34,
            f"{CPU_TOP}.o_axi_araddr": 0x5880,
        },
        # Both slots retire, the second at the stop PC; a write waits.
        {
            f"{CORE}.dbg_commit_valid": 1,
            f"{CORE}.dbg_commit_pc": 0x1FC,
            f"{CORE}.dbg_commit_2_valid": 1,
            f"{CORE}.dbg_commit_2_pc": 0x200,
            f"{CORE}.dbg_dispatch_stall": 1,
            f"{CORE}.rob_count": 2,
            f"{CPU_TOP}.o_axi_awvalid": 1,
            f"{CPU_TOP}.i_axi_rvalid": 1,
            f"{CPU_TOP}.o_axi_rready": 1,
            f"{CPU_TOP}.i_axi_rid": 34,
        },
        # After the window: nothing more is recorded.
        {f"{CORE}.dbg_rob_alloc_valid": 1},
    ]
    for cycle, values in enumerate(cycles):
        _drive(dut, values)
        capture.sample(cycle)
    capture.finish("")

    records = [json.loads(line) for line in trace_path.read_text().splitlines()]
    assert records[0]["event"] == "meta"
    assert records[1:] == [
        {"cycle": 0, "event": "dispatch", "source": "rob", "uops": 2},
        {
            "cycle": 0,
            "event": "axi_request",
            "source": "axi",
            "axi_id": 34,
            "address": "0x00005880",
            "is_write": False,
            "bytes": 64,
        },
        {"cycle": 1, "event": "retire", "source": "rob", "uops": 2},
        {
            "cycle": 1,
            "event": "axi_response",
            "source": "axi",
            "axi_id": 34,
            "ok": True,
        },
    ]
    counters = json.loads(counters_path.read_text())
    assert counters["cycles"] == 2
    assert counters["retired_uops"] == 2
    assert counters["dispatch_distribution"]["cycles_2_uops"] == 1
    assert counters["stalls"]["dispatch_stall_cycles"] == 1
    assert counters["occupancy"]["mean_rob_occupancy"] == 3.0
    assert counters["axi_totals"]["aw_backpressure_cycles"] == 1

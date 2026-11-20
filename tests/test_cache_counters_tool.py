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

"""Tests for fpga/debug/cache_counters.py, the JTAG cache-counter reader."""

import importlib.util
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PROFILE_HEADER = REPO_ROOT / "sw/lib/include/tomasulo_profile.h"


def _load_tool() -> Any:
    """Load the standalone tool without leaking its import paths."""
    module_path = REPO_ROOT / "fpga" / "debug" / "cache_counters.py"
    spec = importlib.util.spec_from_file_location(
        "frost_cache_counters_test", module_path
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


tool: Any = _load_tool()


def _snapshot(time: int, **by_name: int) -> dict[int | str, int]:
    values: dict[int | str, int] = {"time": time}
    values.update({index: 0 for index in tool.CACHE_COUNTERS})
    for name, value in by_name.items():
        values[tool.INDEX[name]] = value
    return values


def _args(**overrides: Any) -> Any:
    fields = {
        "openocd": "openocd",
        "config": Path("x.cfg"),
        "commands": [],
        "timeout": 5,
    }
    fields.update(overrides)
    return type("Args", (), fields)()


def _counter_names(header: str) -> dict[int, str]:
    return {
        int(index): name
        for name, index in re.findall(r"TOMASULO_PERF_(\w+) = (\d+),", header)
    }


def test_names_follow_the_profile_header() -> None:
    """The tool names the cache block's counters as tomasulo_profile.h does."""
    header = PROFILE_HEADER.read_text()
    enum = _counter_names(header)
    match = re.search(r"TOMASULO_PROFILE_COUNTER_COUNT (\d+)U", header)
    assert match is not None
    assert {i: enum[i] for i in range(106, int(match.group(1)))} == tool.CACHE_COUNTERS


def test_snapshot_reads_the_profiling_csrs() -> None:
    """The OpenOCD procedures expose and use the CSR numbers csr.h defines."""
    csr_h = (REPO_ROOT / "sw/lib/include/csr.h").read_text()
    csrs = {
        name: int(value, 16)
        for name, value in re.findall(r"#define CSR_(MPERF\w+) (0x[0-9A-F]+)", csr_h)
    }
    tcl = tool.SNAPSHOT_TCL.read_text()
    assert "riscv expose_csrs 1984-1985,4032-4034" in tcl
    assert (csrs["MPERFSEL"], csrs["MPERFCTL"]) == (1984, 1985)
    assert (csrs["MPERFDATA"], csrs["MPERFDATAH"], csrs["MPERFCOUNT"]) == (
        4032,
        4033,
        4034,
    )
    for number in ("4034", "1985 1", "1984 $index", "4032", "4033"):
        assert number in tcl
    # ebreak stays with the hart's trap handlers after a snapshot.
    for mode in ("m", "s", "u"):
        assert f"riscv set_ebreak{mode} off" in tcl


@pytest.mark.parametrize("count", [0, 120, 121, 134])
def test_tcl_load_snapshot_uses_one_capture(tmp_path: Path, count: int) -> None:
    """Tcl captures once and reads the Python tuple's profile indices."""
    enum = _counter_names(PROFILE_HEADER.read_text())
    indices = tool.LOAD_WAIT_INDICES
    assert tuple(enum[i] for i in indices) == (
        "HEAD_WAIT_LOAD_OUTSTANDING",
        "HEAD_WAIT_LOAD_NO_OUTSTANDING",
        "L2_MISS_CYCLES_SUM",
    )
    harness = tmp_path / "snapshot.tcl"
    harness.write_text(
        """
proc riscv {args} {}
proc poll {} {}
proc target {args} { return mock_target }
proc mock_target {args} { return halted }

set count [lindex $argv 1]
set selector 0
set captures 0
proc get_reg {force name} {
    puts "read $name"
    set values [dict create csr4034 $::count time 1000 \
        csr1984 $::selector csr4032 $::selector csr4033 $::captures]
    return [dict create $name [dict get $values $name]]
}
proc set_reg {pair} {
    lassign $pair name value
    puts "write $name $value"
    switch -- $name {
        csr1984 { set ::selector $value }
        csr1985 { incr ::captures }
        default { error "unexpected CSR write to $name" }
    }
}
source [lindex $argv 0]
frost_load_snapshot
"""
    )
    result = subprocess.run(
        ["tclsh", str(harness), str(tool.SNAPSHOT_TCL), str(count)],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    *operations, reply = result.stdout.splitlines()
    if count <= max(indices):
        assert operations == ["read csr4034"]
        assert reply == "FROST_LOAD_SNAPSHOT absent"
        return
    expected = ["read csr4034", "write csr1985 1", "read time"]
    for index in indices:
        expected += [
            f"write csr1984 {index}",
            "read csr1984",
            "read csr4032",
            "read csr4033",
        ]
    assert operations == expected
    assert reply.startswith("FROST_LOAD_SNAPSHOT ")
    assert tool.parse_fields(
        reply.removeprefix("FROST_LOAD_SNAPSHOT "), required_indices=indices
    ) == {"time": 1000, **{index: (1 << 32) + index for index in indices}}


def test_parse_fields() -> None:
    """Snapshot and counter lines parse to integers keyed by index or name."""
    assert tool.parse_fields(" time=0x10 106=5 107=7") == {
        "time": 16,
        106: 5,
        107: 7,
    }
    assert tool.parse_fields(" absent") is None
    for bad in (" 106", " 106=", " 106=1 106=2", " 106=1 108=2", " 107=1"):
        with pytest.raises(ValueError):
            tool.parse_fields(bad)


def test_openocd_command_runs_one_procedure() -> None:
    """Commands come before the configuration, and the procedure ends the run."""
    command = tool.openocd_command(
        "openocd", Path("sim.cfg"), ["set FROST_RBB_PORT 3335"], "frost_cache_mark"
    )
    assert command[0] == "openocd"
    assert command.index("set FROST_RBB_PORT 3335") < command.index("sim.cfg")
    assert command[-10:] == [
        "-f",
        "sim.cfg",
        "-f",
        str(tool.SNAPSHOT_TCL),
        "-c",
        "init",
        "-c",
        "frost_cache_mark",
        "-c",
        "shutdown",
    ]


def _fake_openocd(
    monkeypatch: pytest.MonkeyPatch, output: str, returncode: int = 0
) -> list[list[str]]:
    calls: list[list[str]] = []

    def fake_run(command: list[str], **kwargs: Any) -> Any:
        calls.append(command)
        return type(
            "Result", (), {"returncode": returncode, "stdout": output, "stderr": ""}
        )()

    monkeypatch.setattr(tool.subprocess, "run", fake_run)
    return calls


def test_snapshot_reads_both_banks(monkeypatch: pytest.MonkeyPatch) -> None:
    """A snapshot returns the current bank with the time CSR, and the preceding bank."""
    calls = _fake_openocd(
        monkeypatch,
        "Info : Examined RISC-V core\n"
        "FROST_CACHE_SNAPSHOT time=900 106=7 107=5\n"
        "FROST_CACHE_PREVIOUS 106=2 107=1\n",
    )
    current, previous = tool.take_snapshot(_args())
    assert current == {"time": 900, 106: 7, 107: 5}
    assert previous == {106: 2, 107: 1}
    assert "frost_cache_snapshot" in calls[0]


def test_mark_returns_the_time(monkeypatch: pytest.MonkeyPatch) -> None:
    """A mark returns the time CSR; a core without counters is an error."""
    _fake_openocd(monkeypatch, "FROST_CACHE_MARK time=0x40\n")
    assert tool.take_mark(_args()) == 64
    _fake_openocd(monkeypatch, "FROST_CACHE_MARK absent\n")
    with pytest.raises(RuntimeError, match="no profiling counters"):
        tool.take_mark(_args())
    _fake_openocd(monkeypatch, "Error: failed to read register 'csr4034'\n", 1)
    with pytest.raises(RuntimeError, match="OpenOCD exited 1 in frost_cache_mark"):
        tool.take_mark(_args())


def test_sample_without_counters(monkeypatch: pytest.MonkeyPatch) -> None:
    """A core without counters prints no preceding bank, and the tool says why."""
    _fake_openocd(monkeypatch, "FROST_CACHE_SNAPSHOT absent\n")
    with pytest.raises(RuntimeError, match="no profiling counters"):
        tool.take_snapshot(_args())


@pytest.mark.parametrize(
    ("stop", "how"),
    [
        (tool.subprocess.TimeoutExpired(["openocd"], 5), "did not finish in 5 s"),
        (KeyboardInterrupt(), "was interrupted"),
    ],
)
def test_a_stopped_openocd_run_points_to_resume(
    monkeypatch: pytest.MonkeyPatch, stop: BaseException, how: str
) -> None:
    """An OpenOCD run stopped early is reported with the hart's risk and the fix."""

    def fake_run(command: list[str], **kwargs: Any) -> Any:
        raise stop

    monkeypatch.setattr(tool.subprocess, "run", fake_run)
    with pytest.raises(
        RuntimeError, match=f"OpenOCD {how} in frost_cache_mark"
    ) as info:
        tool.take_mark(_args())
    assert "can leave the hart halted; run cache_counters.py resume" in str(info.value)


def test_resume(monkeypatch: pytest.MonkeyPatch) -> None:
    """Resume reports whether it found the hart halted."""
    calls = _fake_openocd(monkeypatch, "FROST_CACHE_HART resumed\n")
    assert tool.resume_hart(_args()) == "resumed the halted hart"
    assert "frost_cache_resume" in calls[0]
    _fake_openocd(monkeypatch, "FROST_CACHE_HART running\n")
    assert tool.resume_hart(_args()) == "the hart is running; nothing to resume"
    assert "proc frost_cache_resume" in tool.SNAPSHOT_TCL.read_text()


def test_write_costs_from_deltas() -> None:
    """The report derives the fill share, slot-cycles, and held cycles."""
    start = _snapshot(1000, L2_ACCESS=10, L2_MISS=4)
    end = _snapshot(
        11000,
        L2_ACCESS=410,
        L2_MISS=204,
        L2_MISS_CYCLES_SUM=8000,
        L2_WRITE_FILL=50,
        L2_WRITE_FILL_CYCLES_SUM=2000,
        L2_WRITE_READ_WAIT=4,
        L2_WRITE_READ_WAIT_CYCLES=200,
    )
    change = tool.deltas(start, end)
    assert change["cycles"] == 10000
    assert change[tool.INDEX["L2_MISS"]] == 200
    lines = tool.report_lines(change)
    assert lines[0].startswith("FROST_CACHE_COUNTERS cycles=10000 106=0 ")
    assert (
        "  L2 write fills: 50, 25.00% of L2 misses, 3200 bytes read from DDR, "
        "40.0 slot-cycles each, 25.00% of L2 slot-cycles"
    ) in lines
    assert (
        "  L2 writes held behind reads: 4, 1.00% of L2 accesses, 200 cycles held, "
        "50.0 per write, 2.00% of all cycles"
    ) in lines


def test_deltas_reject_a_reset_or_a_mismatch() -> None:
    """A counter that went down means the core was reset during the window."""
    with pytest.raises(RuntimeError, match="L2_WRITE_FILL went down"):
        tool.deltas(_snapshot(0, L2_WRITE_FILL=5), _snapshot(10, L2_WRITE_FILL=2))
    short = _snapshot(0)
    del short[133]
    with pytest.raises(RuntimeError, match="cover different counters"):
        tool.deltas(short, _snapshot(10))


def test_write_costs_need_counters_130_to_133() -> None:
    """A core from before the write-cost counters reports them as n/a."""
    change: dict[int | str, int] = {"cycles": 5}
    change.update({index: 1 for index in range(106, 130)})
    assert tool.write_cost_lines(change) == [
        "L2 write costs: n/a (no L2_WRITE_FILL, L2_WRITE_FILL_CYCLES_SUM, "
        "L2_WRITE_READ_WAIT, L2_WRITE_READ_WAIT_CYCLES)"
    ]


def test_summarize_labels_each_sweep_section(tmp_path: Path) -> None:
    """Each FROST_CACHE_COUNTERS line is reported under its sweep heading and verdict."""
    change = _snapshot(
        0,
        L2_ACCESS=400,
        L2_MISS=200,
        L2_MISS_CYCLES_SUM=8000,
        L2_WRITE_FILL=50,
        L2_WRITE_FILL_CYCLES_SUM=2000,
        L2_WRITE_READ_WAIT=4,
        L2_WRITE_READ_WAIT_CYCLES=200,
    )
    fields = " ".join(f"{index}={change[index]}" for index in tool.CACHE_COUNTERS)
    log = tmp_path / "sweep.log"
    log.write_text(
        "===== x3 coremark_pro_core -v0 =====\n"
        f"FROST_CACHE_COUNTERS cycles=10000 {fields}\r\n"
        "<<PASS>>\n"
        "\nRESULT x3 coremark_pro_core -v0: PASS time=12.5\n"
        "===== x3 coremark_pro_sha -v0 =====\n"
        "FROST_CACHE_COUNTERS absent\n"
        "\nRESULT x3 coremark_pro_sha -v0: FAIL time=3.0\n"
        "===== x3 coremark_pro_zip -v0 =====\n"
        "\nRESULT x3 coremark_pro_zip -v0: LOAD_FAIL time=0\n"
    )
    lines = tool.summarize([log])
    assert lines[0] == "x3 coremark_pro_core -v0 (PASS):"
    assert lines[1] == f"  FROST_CACHE_COUNTERS cycles=10000 {fields}"
    assert (
        "    L2 writes held behind reads: 4, 1.00% of L2 accesses, 200 cycles held, "
        "50.0 per write, 2.00% of all cycles"
    ) in lines
    assert lines[-2:] == [
        "x3 coremark_pro_sha -v0 (FAIL):",
        "  profiling counters absent",
    ]


def test_summarize_needs_counter_lines(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A log without counter lines is an error, not an empty report."""
    log = tmp_path / "sweep.log"
    log.write_text("===== x3 coremark_pro_core -v0 =====\n<<PASS>>\n")
    assert tool.main(["summarize", str(log)]) == 1
    assert "no FROST_CACHE_COUNTERS lines" in capsys.readouterr().err


def _fake_window(
    monkeypatch: pytest.MonkeyPatch, events: list[str], command_result: Any
) -> None:
    start = _snapshot(0, L2_WRITE_FILL=4)
    del start["time"]
    end = _snapshot(600, L2_WRITE_FILL=7)

    def fake_mark(args: Any) -> int:
        events.append("mark")
        return 100

    def fake_snapshot(args: Any) -> tuple[dict[int | str, int], dict[int | str, int]]:
        events.append("snapshot")
        return end, start

    def fake_run(command: list[str], check: bool, timeout: float | None) -> Any:
        events.append(" ".join(command))
        if isinstance(command_result, BaseException):
            raise command_result
        return type("Result", (), {"returncode": command_result})()

    monkeypatch.setattr(tool, "take_mark", fake_mark)
    monkeypatch.setattr(tool, "take_snapshot", fake_snapshot)
    monkeypatch.setattr(tool.subprocess, "run", fake_run)


def test_window_runs_the_command_between_mark_and_snapshot(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    """Window marks, runs the command, then reads the snapshot and its predecessor."""
    events: list[str] = []
    _fake_window(monkeypatch, events, 0)
    monkeypatch.setattr(tool, "LOCK_PATH", tmp_path / "lock")
    assert tool.main(["window", "--", "ssh", "board", "true"]) == 0
    assert (tmp_path / "lock").exists()
    assert events == ["mark", "ssh board true", "snapshot"]
    output = capsys.readouterr().out
    assert output.startswith("FROST_CACHE_COUNTERS cycles=500 ")
    assert " 130=3 " in output
    assert output.splitlines()[-1].startswith("FROST_CACHE_SNAPSHOT time=600 106=0 ")


def test_window_reports_a_failed_or_stopped_command(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The deltas still print, but a failing or overlong command fails the run."""
    events: list[str] = []
    _fake_window(monkeypatch, events, 3)
    assert tool.main(["window", "--", "false"]) == 1
    captured = capsys.readouterr()
    assert captured.out.startswith("FROST_CACHE_COUNTERS cycles=500 ")
    assert "the command exited 3" in captured.err
    _fake_window(
        monkeypatch, events, tool.subprocess.TimeoutExpired(["sleep", "9"], 1.0)
    )
    assert tool.main(["window", "--run-timeout", "1", "--", "sleep", "9"]) == 1
    captured = capsys.readouterr()
    assert "ran past 1 s and was stopped" in captured.err
    assert events[-1] == "snapshot"


def test_window_needs_seconds_or_a_command() -> None:
    """Window refuses both and neither of --seconds and a command."""
    with pytest.raises(SystemExit):
        tool.main(["window"])
    with pytest.raises(SystemExit):
        tool.main(["window", "--seconds", "1", "--", "true"])


def test_load_wait_window_keeps_both_endpoints(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    """Each endpoint reads the same three indices from one capture."""
    events: list[str] = []
    snapshots = iter(
        [
            "FROST_LOAD_SNAPSHOT time=1000 79=32 80=20 120=0x8000000000000000\n",
            "FROST_LOAD_SNAPSHOT time=1043 79=44 80=29 120=0x8000000000000033\n",
        ]
    )

    def fake_openocd(args: Any, procedure: str) -> str:
        events.append(procedure)
        return next(snapshots)

    def fake_run(command: list[str], **kwargs: Any) -> Any:
        events.append(" ".join(command))
        return type("Result", (), {"returncode": 0})()

    monkeypatch.setattr(tool, "run_openocd", fake_openocd)
    monkeypatch.setattr(tool.subprocess, "run", fake_run)
    monkeypatch.setattr(tool, "LOCK_PATH", tmp_path / "lock")
    assert tool.main(["window", "--load-waits", "--", "run", "workload"]) == 0
    assert events == ["frost_load_snapshot", "run workload", "frost_load_snapshot"]
    assert capsys.readouterr().out.splitlines() == [
        "FROST_LOAD_WINDOW cycles=43 79=12 80=9 120=51",
        "FROST_LOAD_START time=1000 79=32 80=20 120=9223372036854775808",
        "FROST_LOAD_END time=1043 79=44 80=29 120=9223372036854775859",
    ]


def test_load_wait_window_unavailable(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    """An absent bank yields one unavailable result and skips the workload."""
    calls = _fake_openocd(monkeypatch, "FROST_LOAD_SNAPSHOT absent\n")
    monkeypatch.setattr(tool, "LOCK_PATH", tmp_path / "lock")
    assert tool.main(["window", "--load-waits", "--", "run", "workload"]) == 1
    assert len(calls) == 1
    assert "frost_load_snapshot" in calls[0]
    assert capsys.readouterr().out == "FROST_LOAD_WINDOW unavailable\n"


@pytest.mark.parametrize(
    "fields",
    ["79=4 80=5 120=15", "time=1000 79=4 120=15", "time=1000 79=4 80=5 120=15 121=0"],
)
def test_load_snapshot_requires_all_fields(
    monkeypatch: pytest.MonkeyPatch, fields: str
) -> None:
    """An incomplete or extra field makes a snapshot invalid."""
    _fake_openocd(monkeypatch, f"FROST_LOAD_SNAPSHOT {fields}\n")
    with pytest.raises(RuntimeError, match="requires time and counters"):
        tool.take_load_snapshot(_args())


@pytest.mark.parametrize("first", ["", "absent", "time=1 79=2 80=3 120=4"])
def test_load_snapshot_rejects_two_replies(
    monkeypatch: pytest.MonkeyPatch, first: str
) -> None:
    """One OpenOCD invocation must return exactly one snapshot line."""
    _fake_openocd(
        monkeypatch,
        f"FROST_LOAD_SNAPSHOT {first}\nFROST_LOAD_SNAPSHOT time=5 79=6 80=7 120=8\n",
    )
    with pytest.raises(RuntimeError, match="must print one result"):
        tool.take_load_snapshot(_args())


@pytest.mark.parametrize(
    "value", ["-1", "1_0", "0x1_0", "18446744073709551616", "0x10000000000000000"]
)
@pytest.mark.parametrize("field", ["time", "80"])
def test_load_snapshot_rejects_invalid_counter_values(
    monkeypatch: pytest.MonkeyPatch, value: str, field: str
) -> None:
    """Counter fields carry ordinary unsigned 64-bit integers."""
    fields = {"time": "1", "79": "2", "80": "3", "120": "4"}
    fields[field] = value
    reply = "FROST_LOAD_SNAPSHOT " + " ".join(f"{k}={v}" for k, v in fields.items())
    _fake_openocd(monkeypatch, reply + "\n")
    with pytest.raises(RuntimeError, match="invalid unsigned 64-bit value"):
        tool.take_load_snapshot(_args())


def test_load_snapshot_accepts_unsigned_limits(monkeypatch: pytest.MonkeyPatch) -> None:
    """Both decimal and hex cover the full unsigned 64-bit range."""
    _fake_openocd(
        monkeypatch,
        "FROST_LOAD_SNAPSHOT time=1 79=0 80=18446744073709551615 120=0xffffffffffffffff\n",
    )
    assert tool.take_load_snapshot(_args()) == {
        "time": 1,
        79: 0,
        80: (1 << 64) - 1,
        120: (1 << 64) - 1,
    }


@pytest.mark.parametrize(
    ("end", "message"),
    [
        (
            "time=1030 79=2 80=16 120=141",
            "79 went down: an isolated decrease suggests a 64-bit wrap",
        ),
        (
            "time=1030 79=2 80=1 120=141",
            "79, 80 went down: multiple decreases suggest a reset",
        ),
        (
            "time=3 79=2 80=16 120=141",
            "cycles, 79 went down: multiple decreases suggest a reset",
        ),
    ],
)
def test_load_window_diagnoses_decreases(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    end: str,
    message: str,
) -> None:
    """Other values distinguish an isolated wrap from concurrent decreases."""
    replies = iter(
        [
            "FROST_LOAD_SNAPSHOT time=1000 79=18446744073709551614 80=15 120=120\n",
            f"FROST_LOAD_SNAPSHOT {end}\n",
        ]
    )
    monkeypatch.setattr(tool, "run_openocd", lambda args, procedure: next(replies))
    monkeypatch.setattr(tool, "LOCK_PATH", tmp_path / "lock")
    assert tool.main(["window", "--load-waits", "--seconds", "0"]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert message in captured.err

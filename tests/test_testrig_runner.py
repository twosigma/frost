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

"""Fast checks that TestRIG requires completed, nonempty comparisons."""

import importlib
import io
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

testrig = importlib.import_module("test_testrig")
GENERATORS = ("atomics", "crypto", "zcb", "fp-ext", "mmu", "cmo", "vector", "svinval")


@pytest.mark.parametrize("vlen", (None, 128, 256, 512))
def test_frost_misa_matches_sail_configuration(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, vlen: int | None
) -> None:
    """The launched FROST model advertises V exactly when its Sail overlay does."""
    observed = []

    def from_config(config: Any) -> SimpleNamespace:
        observed.append(config)
        return SimpleNamespace(
            setup_environment=lambda: {},
            _get_sim_build_dir=lambda environment: tmp_path / "sim",
            _verilator_needs_rebuild=lambda directory: False,
            _update_verilator_toplevel_marker=lambda directory: None,
        )

    def popen(*args: Any, **kwargs: Any) -> SimpleNamespace:
        kwargs["stdout"].close()
        return SimpleNamespace()

    monkeypatch.setattr(testrig.CocotbRunner, "from_config", from_config)
    monkeypatch.setattr(testrig.subprocess, "Popen", popen)
    monkeypatch.delenv("FROST_VERILATOR_EXTRA_ARGS", raising=False)
    testrig.start_frost(0, tmp_path / "ready", tmp_path / "frost.log", 30, vlen)
    config = observed[0]
    runner = testrig.CocotbRunner(
        config.python_test_module,
        config.hdl_toplevel_module,
        config.app_name,
        config.verilator_extra_args,
    )
    sail = testrig.load_sail_json(testrig.write_sail_config(30, tmp_path, vlen=vlen))
    assert runner._expected_misa_v() == int(
        sail["extensions"]["V"]["support_level"] == "Full"
    )


@pytest.fixture
def session(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> SimpleNamespace:
    """Replace child processes and wire counters with controlled results."""
    state = SimpleNamespace(
        sail=[(2, 2)],
        frost=[(2, 2)],
        output="+++ OK, passed 1 test.\n",
        status=0,
        starts=0,
        commands=[],
        monitor_error=None,
        engine_running=False,
        engine_polls=0,
        stopped_running_engine=False,
    )

    class Process:
        def __init__(self, finished: bool = False, is_engine: bool = False) -> None:
            self.returncode = state.status if finished else None
            self.stdout = io.StringIO(state.output)
            self.is_engine = is_engine

        def poll(self) -> int | None:
            if self.is_engine:
                state.engine_polls += 1
                if state.engine_running and state.engine_polls >= 4:
                    self.returncode = state.status
            return self.returncode

        def wait(self, **kwargs: Any) -> int:
            return self.returncode if self.returncode is not None else state.status

    def popen(command: list[str], **kwargs: Any) -> Process:
        state.commands.append(command)
        state.starts += 1
        is_engine = command[0] == "QCVEngine"
        return Process(
            finished=is_engine and not state.engine_running, is_engine=is_engine
        )

    def start_frost(
        port: int,
        ready: Path,
        log: Path,
        *args: Any,
        **kwargs: Any,
    ) -> tuple[Process, Any]:
        state.starts += 1
        ready.touch()
        log.write_text("TESTS=1 PASS=1 FAIL=0\n")
        return Process(), lambda: None

    class Monitor:
        def __init__(self, name: str, port: int, timeout: float) -> None:
            self.name = name
            self.port = port
            self.errors: list[str] = []
            if state.monitor_error and name == "Sail":
                self.errors.append(state.monitor_error)
            counts = state.sail if name == "Sail" else state.frost
            self.traces = [
                SimpleNamespace(requested=requested, received=received)
                for requested, received in counts
            ]

        def close(self) -> None:
            pass

    monkeypatch.setattr(testrig.subprocess, "Popen", popen)
    monkeypatch.setattr(testrig, "start_frost", start_frost)

    def stop(process: Process | None, **kwargs: Any) -> None:
        if process is not None and process.is_engine and process.returncode is None:
            state.stopped_running_engine = True

    monkeypatch.setattr(testrig, "stop", stop)
    monkeypatch.setattr(testrig, "write_empty_images", lambda: [])
    monkeypatch.setattr(testrig, "TraceMonitor", Monitor, raising=False)
    monkeypatch.setattr(testrig, "tool_path", lambda name, variable: name)
    state.run = lambda argv: testrig.run(
        testrig.parse_arguments(
            ["--log-dir", str(tmp_path / "logs"), "--save-dir", str(tmp_path / "save")]
            + argv
        )
    )
    return state


@pytest.mark.parametrize(
    "option", ("tests", "test-length", "vector-length", *GENERATORS)
)
@pytest.mark.parametrize("count", ("0", "-1"))
def test_nonpositive_counts(option: str, count: str, capsys: Any) -> None:
    """Explicit counts and instruction limits must be positive."""
    with pytest.raises(SystemExit) as error:
        testrig.parse_arguments([f"--{option}", count])
    assert error.value.code == 2
    assert "expected" in capsys.readouterr().err


@pytest.mark.parametrize("kind", ("missing", "empty", "unmatched"))
def test_empty_trace_directory(
    kind: str, session: SimpleNamespace, tmp_path: Path, capsys: Any
) -> None:
    """Missing directories and directories without .S files fail before startup."""
    directory = tmp_path / "traces"
    if kind != "missing":
        directory.mkdir()
    if kind == "unmatched":
        (directory / "trace.s").write_text(".4byte 0x13\n")
        (directory / "notes.txt").write_text(".4byte 0x13\n")
    assert session.run(["--trace-dir", str(directory)]) != 0
    assert session.starts == 0
    output = capsys.readouterr().out
    assert "expected" in output and "found 0" in output


@pytest.mark.parametrize("contents", (None, "", "# .4byte 0x13\n"))
def test_empty_trace_file(
    contents: str | None, session: SimpleNamespace, tmp_path: Path, capsys: Any
) -> None:
    """A missing or instruction-free single trace cannot pass."""
    path = tmp_path / "empty.S"
    if contents is not None:
        path.write_text(contents)
    assert session.run(["--trace", str(path)]) != 0
    assert session.starts == 0
    assert "expected" in capsys.readouterr().out


@pytest.mark.parametrize(
    "sail,frost",
    (
        ([], []),
        ([(2, 0)], [(2, 2)]),
        ([(2, 2)], [(2, 0)]),
        ([(2, 0)], [(2, 0)]),
        ([(2, 1)], [(2, 1)]),
    ),
)
def test_incomplete_replay(
    sail: list[tuple[int, int]],
    frost: list[tuple[int, int]],
    session: SimpleNamespace,
    tmp_path: Path,
    capsys: Any,
) -> None:
    """Engine success cannot hide absent or short replies from either peer."""
    path = tmp_path / "trace.S"
    path.write_text(".4byte 0x13\n.2byte 0x1\n")
    session.sail, session.frost = sail, frost
    assert session.run(["--trace", str(path)]) != 0
    output = capsys.readouterr().out
    assert "TestRIG FAIL" in output and "expected" in output and "found" in output


def test_success_counts(session: SimpleNamespace, tmp_path: Path, capsys: Any) -> None:
    """A completed replay prints the numbers of paired traces and instructions."""
    path = tmp_path / "trace.S"
    path.write_text(".4byte 0x13\n.2byte 0x1\n")
    assert session.run(["--trace", str(path)]) == 0
    assert (
        "TestRIG PASS: compared 1 traces and 2 instructions" in capsys.readouterr().out
    )


@pytest.mark.parametrize("option", GENERATORS)
@pytest.mark.parametrize(
    "kind", ("missing", "empty", "unmatched", "zero_instructions", "too_few")
)
def test_incomplete_generator(
    option: str,
    kind: str,
    session: SimpleNamespace,
    monkeypatch: pytest.MonkeyPatch,
    capsys: Any,
) -> None:
    """Every generator must produce its requested number of nonempty traces."""
    module = getattr(
        testrig, {"zcb": "compressed_mops", "fp-ext": "fp_ext"}.get(option, option)
    )

    def write(directory: Path, *args: Any, **kwargs: Any) -> Any:
        if kind != "missing":
            directory.mkdir(exist_ok=True)
        if kind == "unmatched":
            (directory / "trace.txt").write_text(".4byte 0x13\n")
        if kind in ("zero_instructions", "too_few"):
            (directory / "trace.S").write_text(
                "# no instructions\n"
                if kind == "zero_instructions"
                else ".4byte 0x13\n"
            )
        return ([], []) if option in ("mmu", "cmo") else []

    method = "write_tests_with_strands" if option in ("mmu", "cmo") else "write_tests"
    monkeypatch.setattr(module, method, write)
    assert session.run([f"--{option}", "2" if kind == "too_few" else "1"]) != 0
    assert session.starts == 0
    assert "expected" in capsys.readouterr().out


@pytest.mark.parametrize("generated", (0, 11))
def test_vector_source_widths_require_all_generated_traces(
    generated: int,
    session: SimpleNamespace,
    monkeypatch: pytest.MonkeyPatch,
    capsys: Any,
) -> None:
    """The directed inputs cannot replace missing traces from the generator."""

    def write_tests(
        directory: Path, count: int, seed: int, length: int, vlen: int
    ) -> None:
        assert (count, seed, length, vlen) == (12, 42, 20, 128)
        directory.mkdir()
        for index in range(generated):
            (directory / f"vector_{index}.S").write_text(".4byte 0x13\n")

    monkeypatch.setattr(testrig.vector, "write_tests", write_tests)
    assert (
        session.run(["--vector", "12", "--vector-source-widths", "--seed", "42"]) == 1
    )
    assert session.starts == 0
    output = capsys.readouterr().out
    assert "expected at least 15 .S traces" in output
    assert f"found {generated + 3}" in output


@pytest.mark.parametrize(
    "sail,frost,diagnostic",
    (
        ([], [], "found 0 traces and 0 instructions"),
        ([(224, 224)], [(224, 224)], "found 1 traces and 224 instructions"),
        ([(224, 224)], [(224, 223)], "expected 224 instructions from FROST in trace 1"),
        ([(1, 1)] * 15, [(1, 1)] * 15, "found 15 traces and 15 instructions"),
    ),
)
def test_vector_source_widths_require_complete_replies(
    sail: list[tuple[int, int]],
    frost: list[tuple[int, int]],
    diagnostic: str,
    session: SimpleNamespace,
    capsys: Any,
) -> None:
    """An engine exit of zero still requires all vector reply records."""
    session.sail, session.frost = sail, frost
    assert (
        session.run(["--vector", "12", "--vector-source-widths", "--seed", "42"]) == 1
    )
    output = capsys.readouterr().out
    assert "TestRIG FAIL: expected at least 15 traces and 2788 instructions" in output
    assert diagnostic in output


@pytest.mark.parametrize(
    "sail,frost,passed",
    (
        ([], [], False),
        ([], [(2, 2), (2, 2)], False),
        ([(2, 2), (2, 2)], [], False),
        ([(2, 2)], [(2, 2)], False),
        ([(2, 2), (2, 0)], [(2, 2), (2, 2)], False),
        ([(2, 2), (2, 2)], [(2, 2), (2, 0)], False),
        ([(2, 2), (2, 1)], [(2, 2), (2, 2)], False),
        ([(2, 2), (2, 2)], [(2, 2), (2, 1)], False),
        ([(1, 1), (1, 1)], [(1, 1), (1, 1)], False),
        ([(2, 2), (2, 2)], [(2, 2), (2, 2)], True),
    ),
)
def test_svinval_comparison_counts(
    sail: list[tuple[int, int]],
    frost: list[tuple[int, int]],
    passed: bool,
    session: SimpleNamespace,
    monkeypatch: pytest.MonkeyPatch,
    capsys: Any,
) -> None:
    """Svinval requires the requested traces and instructions from both peers."""

    def write(directory: Path, count: int, seed: int, length: int) -> list[Path]:
        assert (count, seed, length) == (2, 7, 200)
        directory.mkdir()
        paths = [directory / f"trace{i}.S" for i in range(count)]
        for path in paths:
            path.write_text(".4byte 0x13\n.2byte 0x1\n")
        return paths

    monkeypatch.setattr(testrig.svinval, "write_tests", write)
    session.sail, session.frost = sail, frost
    # Even a successful engine exit cannot replace the actual comparisons.
    session.output = "+++ OK, passed 2 tests.\n"
    assert (session.run(["--svinval", "2", "--seed", "7"]) == 0) == passed
    output = capsys.readouterr().out
    assert "expected at least 2 traces and 4 instructions" in output
    if passed:
        assert "TestRIG PASS: compared 2 traces and 4 instructions" in output
    else:
        assert "TestRIG FAIL" in output


@pytest.mark.parametrize(
    "output,traces",
    (
        ("Warning: no tests selected\n", []),
        ("Warning: skipping arith since architecture requirements not met\n", []),
        ("arith -- Arithmetic:\n+++ OK, passed 0 tests.\n", []),
        ("arith -- Arithmetic:\n+++ OK, passed 1 test.\n", [(0, 0)]),
        ("arith -- Arithmetic:\n+++ OK, passed 2 tests.\n", [(0, 0), (0, 0)]),
        ("arith -- Arithmetic:\n+++ OK, passed 1 test.\n", [(2, 2)]),
    ),
)
def test_incomplete_templates(
    output: str,
    traces: list[tuple[int, int]],
    session: SimpleNamespace,
    capsys: Any,
) -> None:
    """Empty filters, empty sequences, and short template counts fail."""
    session.output = output
    session.sail = session.frost = traces
    assert session.run(["--tests", "2", "--include", "^arith$"]) != 0
    assert "TestRIG FAIL" in capsys.readouterr().out


@pytest.mark.parametrize("verbosity", ("0", "1", "2"))
def test_template_success(
    verbosity: str, session: SimpleNamespace, capsys: Any
) -> None:
    """Requested tests are counted per selected template at every verbosity."""
    session.output = (
        "arith -- Arithmetic:\n+++ OK, passed 2 tests.\n"
        "mem -- Memory:\n+++ OK, passed 2 tests.\n"
    )
    session.sail = session.frost = [(2, 2)] * 4
    assert session.run(["--tests", "2", "--verbosity", verbosity]) == 0
    assert "compared 4 traces and 8 instructions" in capsys.readouterr().out


def test_template_empty_size_case(session: SimpleNamespace, capsys: Any) -> None:
    """QuickCheck's size-zero case is permitted within a nonempty session."""
    session.output = "arith -- Arithmetic:\n+++ OK, passed 2 tests.\n"
    session.sail = session.frost = [(0, 0), (1, 1)]
    assert session.run(["--tests", "2", "--include", "^arith$"]) == 0
    assert "compared 2 traces and 1 instructions" in capsys.readouterr().out


def test_nested_replay(session: SimpleNamespace, tmp_path: Path, capsys: Any) -> None:
    """Directory discovery includes nested .S files, as the engine does."""
    directory = tmp_path / "traces" / "nested"
    directory.mkdir(parents=True)
    (directory / "trace.S").write_text(".4byte 0x13\n.2byte 0x1\n")
    assert session.run(["--trace-dir", str(directory.parent)]) == 0
    assert "compared 1 traces and 2 instructions" in capsys.readouterr().out


def test_engine_failure(session: SimpleNamespace, tmp_path: Path, capsys: Any) -> None:
    """Positive comparison counts cannot turn a mismatch into success."""
    path = tmp_path / "trace.S"
    path.write_text(".4byte 0x13\n.2byte 0x1\n")
    session.status = 3
    assert session.run(["--trace", str(path)]) == 3
    assert "TestRIG FAIL" in capsys.readouterr().out


@pytest.mark.parametrize("option", GENERATORS)
def test_counted_modes_cannot_hide_behind_sscofpmf(option: str) -> None:
    """The Sscofpmf replay exception permits only a single trace override."""
    with pytest.raises(SystemExit):
        testrig.parse_arguments(["--sscofpmf", "--trace", "x.S", f"--{option}", "1"])


@pytest.mark.parametrize("option", ("--trace", "--trace-dir"))
def test_empty_path_argument(option: str) -> None:
    """An explicitly empty replay path cannot select another mode."""
    with pytest.raises(SystemExit):
        testrig.parse_arguments([option, ""])


def test_empty_sscofpmf_trace(
    session: SimpleNamespace,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: Any,
) -> None:
    """The dedicated counter trace has the same input requirements as replays."""
    trace = tmp_path / "controls.S"
    trace.touch()
    monkeypatch.setattr(testrig, "SSCOFPMF_TRACE", trace)
    assert session.run(["--sscofpmf"]) != 0
    assert session.starts == 0
    assert "expected at least 1 instruction" in capsys.readouterr().out


def test_monitor_failure_stops_engine(
    session: SimpleNamespace, tmp_path: Path, capsys: Any
) -> None:
    """A closed proxy must stop an engine even when both peers remain alive."""
    path = tmp_path / "trace.S"
    path.write_text(".4byte 0x13\n")
    session.sail = session.frost = []
    session.monitor_error = "Sail: implementation did not listen"
    session.engine_running = True
    assert session.run(["--trace", str(path)]) != 0
    assert session.stopped_running_engine
    assert session.engine_polls < 4
    assert "found 0 traces and 0 instructions" in capsys.readouterr().out


@pytest.mark.parametrize("peer", ("sail", "frost"))
@pytest.mark.parametrize("received", (0, 39))
def test_incomplete_generated_replies(
    peer: str, received: int, session: SimpleNamespace, capsys: Any
) -> None:
    """Successful template output cannot hide missing execution packets."""
    session.output = "arith -- Arithmetic:\n+++ OK, passed 2 tests.\n"
    session.sail = [(0, 0), (40, 40)]
    session.frost = [(0, 0), (40, 40)]
    setattr(session, peer, [(0, 0), (40, received)])
    assert session.run(["--tests", "2", "--include", "^arith$"]) != 0
    output = capsys.readouterr().out
    assert "TestRIG FAIL" in output
    assert (
        f"expected 40 instructions from {peer.title() if peer == 'sail' else 'FROST'}"
        in output
    )


def test_five_tests_per_default_template(session: SimpleNamespace, capsys: Any) -> None:
    """Five tests for twenty selected templates require one hundred traces."""
    session.output = "".join(
        f"template{i} -- Verification:\n+++ OK, passed 5 tests.\n" for i in range(20)
    )
    session.sail = session.frost = [(n, n) for n in (0, 40, 80, 120, 160)] * 20
    assert session.run(["--tests", "5"]) == 0
    output = capsys.readouterr().out
    assert "compared 100 traces and 8000 instructions" in output
    assert "expected at least 100 traces" in output

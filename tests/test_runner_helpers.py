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

"""Fast regression tests for standalone simulation-runner result handling."""

import importlib.util
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest

import test_arch_compliance
import test_riscv_tests
import test_riscv_torture
import test_run_cocotb


def _failed_simulation() -> subprocess.CompletedProcess[str]:
    """Return a representative simulator infrastructure failure."""
    return subprocess.CompletedProcess(
        args=["make"],
        returncode=2,
        stdout="",
        stderr="Verilator build failed",
    )


def test_riscv_nonzero_simulator_exit_is_a_failure() -> None:
    """A broken simulator invocation must turn the standalone CI job red."""
    status, message = test_riscv_tests.check_pass_fail(_failed_simulation())

    assert status == "FAIL"
    assert "exit code 2" in message


def test_arch_timeout_is_a_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Architecture-test timeouts must not disappear into the skip count."""
    source = tmp_path / "add-01.S"
    reference = tmp_path / "add-01.reference_output"
    source.write_text("")
    reference.write_text("00000000\n")
    monkeypatch.setattr(test_arch_compliance, "get_reference_path", lambda _: reference)
    monkeypatch.setattr(
        test_arch_compliance, "compile_test", lambda *_, **__: (True, "")
    )
    monkeypatch.setattr(test_arch_compliance, "run_simulation", lambda **_: None)

    result = test_arch_compliance.run_single_test(source, "I")

    assert result.status == "FAIL"
    assert "timed out" in result.message


def test_arch_missing_reference_fails_the_run(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A selected arch test without a committed reference fails an extension run."""
    source = tmp_path / "fadd_b1-01.S"
    source.write_text("")
    monkeypatch.setattr(
        test_arch_compliance, "discover_tests", lambda *_, **__: [source]
    )
    monkeypatch.setattr(
        test_arch_compliance,
        "get_reference_path",
        lambda _: tmp_path / "fadd_b1-01.reference_output",
    )

    def compile_test(*_: object, **__: object) -> tuple[bool, str]:
        raise AssertionError("the runner built a test that has no reference")

    monkeypatch.setattr(test_arch_compliance, "compile_test", compile_test)
    monkeypatch.setattr(sys, "argv", ["test_arch_compliance.py", "--extensions", "F"])

    assert test_arch_compliance.main() == 1


def test_torture_timeout_is_a_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Torture-test timeouts must not make the direct CI runner succeed."""
    source = tmp_path / "test_0000.S"
    reference = tmp_path / "test_0000.reference_output"
    source.write_text("")
    reference.write_text("00000000\n")
    monkeypatch.setattr(test_riscv_torture, "get_reference_path", lambda *_: reference)
    monkeypatch.setattr(test_riscv_torture, "compile_test", lambda *_: True)
    monkeypatch.setattr(test_riscv_torture, "run_simulation", lambda *_: None)

    result = test_riscv_torture.run_single_test(source, "verilator")

    assert result.status == "FAIL"
    assert "timed out" in result.message


def test_arch_shards_partition_tests_by_case_count(tmp_path: Path) -> None:
    """Arch-test shards are disjoint, cover every test, and balance case counts."""
    tests = []
    for index, cases in enumerate((900, 500, 400, 300, 200, 100, 50)):
        source = tmp_path / f"t{index}-01.S"
        source.write_text("".join(f"inst_{n}:\n" for n in range(cases)))
        tests.append(source)

    shards = [test_arch_compliance.select_shard(tests, k, 3) for k in (1, 2, 3)]

    assert sorted(t for shard in shards for t in shard) == sorted(tests)
    loads = [
        sum(test_arch_compliance._count_test_cases(t) for t in shard)
        for shard in shards
    ]
    assert loads == [900, 800, 750]


def _generate_references() -> ModuleType:
    """Load sw/apps/arch_test/generate_references.py as a module."""
    path = test_arch_compliance.ARCH_TEST_APP_DIR / "generate_references.py"
    spec = importlib.util.spec_from_file_location("generate_references", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_arch_reference_paths_keep_the_suite() -> None:
    """Runner and generator map a test in a src subdirectory under its suite too."""
    generator = _generate_references()
    src = test_arch_compliance.SUITE_ROOT / "rv32i_m" / "F" / "src"
    refs = test_arch_compliance.REFERENCES_DIR / "rv32i_m" / "F"
    for test, reference in (
        (src / "fadd_b1-01.S", refs / "fadd_b1-01.reference_output"),
        (
            src / "fmadd_b15" / "fmadd_b15-001.S",
            refs / "fmadd_b15-001.reference_output",
        ),
    ):
        assert test_arch_compliance.get_reference_path(test) == reference
        assert generator.reference_path(test) == reference


def test_arch_empty_shard_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    """An empty --shard is a usage error, not an unsharded run."""

    def run_extension_tests(*_: object, **__: object) -> list[object]:
        raise AssertionError("the runner started tests")

    monkeypatch.setattr(
        test_arch_compliance, "run_extension_tests", run_extension_tests
    )
    monkeypatch.setattr(
        sys, "argv", ["test_arch_compliance.py", "--extensions", "F", "--shard", ""]
    )
    with pytest.raises(SystemExit) as exit_info:
        test_arch_compliance.main()
    assert exit_info.value.code == 2


def test_signature_alignment_accepts_a_commented_define(tmp_path: Path) -> None:
    """A trailing comment on FROST_SIG_ALIGN does not hide its value."""
    generator = _generate_references()
    header = (generator.SCRIPT_DIR / "model_test.h").read_text()
    commented = header.replace(
        "#define FROST_SIG_ALIGN 4", "#define FROST_SIG_ALIGN 4 // 16 B"
    )
    assert commented != header
    (tmp_path / "model_test.h").write_text(commented)
    assert generator._signature_alignment(tmp_path / "model_test.h") == (4, 4)


def test_signature_extractors_ignore_interspersed_logs() -> None:
    """Progress logging inside a UART dump must not truncate its signature."""
    output = "\n".join(
        (
            "00000001",
            "INFO cocotb: simulation is still running",
            "00000002",
            "<<PASS>>",
        )
    )

    assert test_arch_compliance.extract_signature(output) == ["00000001", "00000002"]
    assert test_riscv_torture.extract_signature(output) == ["00000001", "00000002"]


@pytest.mark.parametrize(
    "runner",
    (
        lambda: test_arch_compliance.run_extension_tests("I", parallel=2),
        lambda: test_riscv_tests.run_suite_tests("rv64ui", "verilator", parallel=2),
        lambda: test_riscv_torture.run_all_tests("verilator", parallel=2),
    ),
)
def test_unsafe_parallel_runner_modes_fail_before_starting(
    runner: Callable[[], object],
) -> None:
    """Parallel runs must fail before starting: workers would share build and result files."""
    with pytest.raises(ValueError, match="workers share application outputs"):
        runner()


def test_cocotb_runner_removes_every_program_memory_symlink(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A completed app run removes every program-memory symlink it made in tests/."""
    test_directory = tmp_path / "tests"
    app_directory = tmp_path / "sw" / "apps" / "sample"
    test_directory.mkdir()
    app_directory.mkdir(parents=True)
    for mem_name in test_run_cocotb.PROGRAM_MEMORY_FILENAMES:
        (app_directory / mem_name).write_text("00\n")

    runner = test_run_cocotb.CocotbRunner(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="sample",
    )
    runner.test_directory = test_directory
    runner.repository_root_directory = tmp_path
    monkeypatch.setattr(runner, "_compile_app", lambda: True)
    monkeypatch.setattr(
        runner,
        "_get_program_memory_file",
        lambda: "../sw/apps/sample/sw.mem",
    )
    monkeypatch.setattr(runner, "setup_environment", lambda: {})
    monkeypatch.setattr(runner, "_verilator_needs_rebuild", lambda _path: False)
    monkeypatch.setattr(runner, "_update_verilator_toplevel_marker", lambda _path: None)

    def simulation_run(
        *_args: object, **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        for mem_name in test_run_cocotb.PROGRAM_MEMORY_FILENAMES:
            assert (test_directory / mem_name).is_symlink()
        (test_directory / "results.xml").write_text(
            '<testsuites><testsuite><testcase name="sample"/></testsuite></testsuites>'
        )
        return subprocess.CompletedProcess(args=["make"], returncode=0)

    monkeypatch.setattr(subprocess, "run", simulation_run)

    runner.run_simulation()

    for mem_name in test_run_cocotb.PROGRAM_MEMORY_FILENAMES:
        assert not (test_directory / mem_name).exists()
        assert not (test_directory / mem_name).is_symlink()


@pytest.mark.parametrize(
    "fresh_report",
    (
        None,
        "invalid XML",
        "<testsuites/>",
        "<testsuites><testsuite><testcase><failure/></testcase></testsuite></testsuites>",
        "<testsuites><testsuite><testcase><error/></testcase></testsuite></testsuites>",
    ),
)
def test_cocotb_runner_rejects_zero_exit_without_fresh_passing_tests(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, fresh_report: str | None
) -> None:
    """A stale pass and zero make exit cannot stand in for a simulator run."""
    report_path = tmp_path / "custom-results.xml"
    report_path.write_text(
        '<testsuites><testsuite><testcase name="stale"/></testsuite></testsuites>'
    )
    runner = test_run_cocotb.CocotbRunner(
        python_test_module="cocotb_tests.test_sample",
        hdl_toplevel_module="cdb_arbiter",
    )
    runner.test_directory = tmp_path
    monkeypatch.setattr(
        runner, "setup_environment", lambda: {"COCOTB_RESULTS_FILE": str(report_path)}
    )
    monkeypatch.setattr(runner, "_verilator_needs_rebuild", lambda _path: False)

    def simulation_run(
        *_args: object, **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        assert not report_path.exists()
        if fresh_report is not None:
            report_path.write_text(fresh_report)
        return subprocess.CompletedProcess(args=["make"], returncode=0)

    monkeypatch.setattr(subprocess, "run", simulation_run)
    with pytest.raises(RuntimeError, match="report"):
        runner.run_simulation()

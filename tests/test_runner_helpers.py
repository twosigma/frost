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

import subprocess
from collections.abc import Callable
from pathlib import Path

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
    """Advertised concurrency must not race shared build and result artifacts."""
    with pytest.raises(ValueError, match="workers share application outputs"):
        runner()


def test_cocotb_runner_removes_every_program_memory_symlink(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A completed app run must not leave a stale data-BRAM image behind."""
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
        return subprocess.CompletedProcess(args=["make"], returncode=0)

    monkeypatch.setattr(subprocess, "run", simulation_run)

    runner.run_simulation()

    for mem_name in test_run_cocotb.PROGRAM_MEMORY_FILENAMES:
        assert not (test_directory / mem_name).exists()
        assert not (test_directory / mem_name).is_symlink()

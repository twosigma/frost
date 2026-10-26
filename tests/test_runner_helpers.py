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
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import replace
from pathlib import Path
from types import ModuleType

import pytest

import test_arch_compliance
import test_run_cocotb
import test_riscv_tests
import test_riscv_torture


def _failed_simulation() -> subprocess.CompletedProcess[str]:
    """Return a representative simulator infrastructure failure."""
    return subprocess.CompletedProcess(
        args=["make"],
        returncode=2,
        stdout="",
        stderr="Verilator build failed",
    )


def test_riscv_nonzero_simulator_exit_is_a_failure(
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A broken simulator invocation must turn the standalone CI job red."""
    status, message = test_riscv_tests.check_pass_fail(_failed_simulation())

    assert status == "FAIL"
    assert "exit code 2" in message
    assert "Verilator build failed" in capsys.readouterr().out


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


@pytest.mark.parametrize(
    ("signature", "status", "detail"),
    (
        ("00000001\n", "PASS", ""),
        ("00000002\n", "FAIL", "mismatch in run 1"),
        ("00000001 00000000\n", "FAIL", "actual=2 words"),
        ("00000001\n00000002\n", "FAIL", "run 2"),
        ("00000001\n\n", "FAIL", "run 2"),
        ("", "FAIL", "no signature"),
        (None, "FAIL", "no signature"),
    ),
)
def test_arch_checks_the_signature_the_bench_read(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    signature: str | None,
    status: str,
    detail: str,
) -> None:
    """Every run's signature must match the reference, and a missing one fails."""
    source = tmp_path / "add-01.S"
    reference = tmp_path / "add-01.reference_output"
    signature_file = tmp_path / "arch_signature.txt"
    source.write_text("")
    reference.write_text("00000001\n")
    monkeypatch.setattr(test_arch_compliance, "get_reference_path", lambda _: reference)
    monkeypatch.setattr(test_arch_compliance, "SIGNATURE_FILE", signature_file)
    monkeypatch.setattr(
        test_arch_compliance, "compile_test", lambda *_, **__: (True, "")
    )

    def run_simulation(**_: object) -> subprocess.CompletedProcess[str]:
        if signature is not None:
            signature_file.write_text(signature)
        return subprocess.CompletedProcess(["make"], 0, "<<PASS>>\n", "")

    monkeypatch.setattr(test_arch_compliance, "run_simulation", run_simulation)

    result = test_arch_compliance.run_single_test(source, "I")

    assert result.status == status
    assert detail in result.message


def test_arch_signature_location_comes_from_the_elf_symbols(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The bench reads end - begin bytes at frost_bram_signature."""
    symbols = (
        "000000000003ec90 A frost_bram_signature\n"
        "                 U undefined_symbol\n"
        "0000000080006000 D begin_signature\n"
        "0000000080007370 D end_signature\n"
    )
    commands: list[list[str]] = []

    def run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        commands.append(command)
        return subprocess.CompletedProcess(command, 0, symbols, "")

    monkeypatch.setenv("RISCV_PREFIX", "riscv64-unknown-elf-")
    monkeypatch.setattr(test_arch_compliance.subprocess, "run", run)

    location = test_arch_compliance.signature_location(tmp_path / "sw.elf")

    assert location == (0x3EC90, 0x1370)
    assert commands == [["riscv64-unknown-elf-nm", str(tmp_path / "sw.elf")]]


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
    monkeypatch.setattr(test_riscv_torture, "run_simulation", lambda *_, **__: None)

    result = test_riscv_torture.run_single_test(source, "verilator")

    assert result.status == "FAIL"
    assert "timed out" in result.message


def test_torture_signature_does_not_hide_a_simulator_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A failed bench must fail torture even after a matching signature dump."""
    source = tmp_path / "test_0000.S"
    reference = tmp_path / "test_0000.reference_output"
    reference.write_text("00000001\n")
    monkeypatch.setattr(test_riscv_torture, "get_reference_path", lambda *_: reference)
    monkeypatch.setattr(test_riscv_torture, "compile_test", lambda *_: True)
    monkeypatch.setattr(
        test_riscv_torture,
        "run_simulation",
        lambda *_, **__: subprocess.CompletedProcess(
            ["make"], 2, "00000001\n<<PASS>>\n", "NIC access guard failed"
        ),
    )

    result = test_riscv_torture.run_single_test(source, "verilator")

    assert result.status == "FAIL"
    assert "exit code 2" in result.message


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


def test_signature_extractor_ignores_interspersed_logs() -> None:
    """Progress logging inside a UART dump must not truncate its signature."""
    output = "\n".join(
        (
            "00000001",
            "INFO cocotb: simulation is still running",
            "00000002",
            "<<PASS>>",
        )
    )

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


@pytest.mark.parametrize("imem_images", (False, True))
def test_cocotb_runner_removes_every_program_memory_symlink(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, imem_images: bool
) -> None:
    """A completed app run removes every program-memory symlink it made in tests/.

    With GENERATE_IMEM_INIT=1, the run links the instruction memory's
    block-RAM images as well.
    """
    test_directory = tmp_path / "tests"
    app_directory = tmp_path / "sw" / "apps" / "sample"
    test_directory.mkdir()
    app_directory.mkdir(parents=True)
    monkeypatch.delenv("GENERATE_IMEM_INIT", raising=False)
    mem_names: tuple[str, ...] = test_run_cocotb.PROGRAM_MEMORY_FILENAMES
    if imem_images:
        mem_names += test_run_cocotb.IMEM_BANK_IMAGE_FILENAMES
    for mem_name in mem_names:
        (app_directory / mem_name).write_text("00\n")

    runner = test_run_cocotb.CocotbRunner(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="sample",
        extra_env=(("GENERATE_IMEM_INIT", "1"),) if imem_images else (),
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
        linked = {path.name for path in test_directory.iterdir() if path.is_symlink()}
        assert linked == set(mem_names)
        (test_directory / "results.xml").write_text(
            '<testsuites><testsuite><testcase name="sample"/></testsuite></testsuites>'
        )
        return subprocess.CompletedProcess(args=["make"], returncode=0)

    monkeypatch.setattr(subprocess, "run", simulation_run)

    runner.run_simulation()

    for mem_name in mem_names:
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


@pytest.mark.parametrize(
    "missing_marker",
    (None, ".last_toplevel", ".last_cocotb_libs", ".last_verilator_extra_args"),
)
def test_cocotb_partial_verilation_without_binary_requires_clean(
    tmp_path: Path, missing_marker: str | None
) -> None:
    """A failed compile's Vtop.mk must not build the next test's wrong model."""
    runner = test_run_cocotb.CocotbRunner(
        python_test_module="cocotb_tests.if_stage.test_instruction_aligner",
        hdl_toplevel_module="instruction_aligner",
    )
    (tmp_path / "Vtop.mk").write_text("# Generated before a fatal IMMU warning\n")
    if missing_marker is not None:
        runner._update_verilator_toplevel_marker(tmp_path)
        (tmp_path / missing_marker).unlink()

    assert not (tmp_path / "Vtop").exists()
    assert runner._verilator_needs_rebuild(tmp_path)


def test_cocotb_fresh_and_matching_builds_keep_incremental_compilation(
    tmp_path: Path,
) -> None:
    """Allow fresh builds and reuse only artifacts with matching metadata."""
    runner = test_run_cocotb.CocotbRunner(
        python_test_module="cocotb_tests.if_stage.test_instruction_aligner",
        hdl_toplevel_module="instruction_aligner",
    )
    build = tmp_path / "sim_build"
    assert not runner._verilator_needs_rebuild(build)
    build.mkdir()
    assert not runner._verilator_needs_rebuild(build)

    (build / "Vtop.mk").write_text("# Correct instruction_aligner build\n")
    runner._update_verilator_toplevel_marker(build)
    assert not runner._verilator_needs_rebuild(build)
    (build / ".last_toplevel").write_text("immu_test_harness")
    assert runner._verilator_needs_rebuild(build)


def _soc_runner(
    verilator_extra_args: tuple[str, ...] = (),
) -> test_run_cocotb.CocotbRunner:
    """Return a whole-SoC runner like the program tests use."""
    return test_run_cocotb.CocotbRunner(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="hello_world",
        verilator_extra_args=verilator_extra_args,
    )


@pytest.mark.parametrize("toplevel", ("frost", "dtm_core"))
def test_random_start_seed_and_build_reuse(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    toplevel: str,
) -> None:
    """Power-up seeds replay on SoC and unit tops without rebuilding per seed."""
    monkeypatch.delenv("FROST_RANDOM_START_SEED", raising=False)
    runner = test_run_cocotb.CocotbRunner(
        python_test_module="unused", hdl_toplevel_module=toplevel
    )
    ordinary_signature = runner._verilator_build_signature()
    assert "FROST_RANDOM_START" not in runner.setup_environment()

    monkeypatch.setenv("FROST_RANDOM_START_SEED", "job-123")
    environment = runner.setup_environment()
    signature = runner._verilator_build_signature()
    assert signature != ordinary_signature
    assert environment["FROST_RANDOM_START"] == "1"
    seed = environment["FROST_RANDOM_START_VERILATOR_SEED"]
    assert 1 <= int(seed) < 2**31
    assert runner.setup_environment()["FROST_RANDOM_START_VERILATOR_SEED"] == seed
    assert "FROST_RANDOM_START_SEED=job-123" in capsys.readouterr().out

    monkeypatch.setenv("FROST_RANDOM_START_SEED", "job-456")
    assert runner.setup_environment()["FROST_RANDOM_START_VERILATOR_SEED"] != seed
    assert runner._verilator_build_signature() == signature
    monkeypatch.delenv("FROST_RANDOM_START_SEED")
    assert runner._verilator_build_signature() == ordinary_signature


def test_ddr_model_seed_draws_repeatable_timing(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A seed selects the same timing every time, within range, and prints it."""
    seed = "123456-1-test-verilator-7"
    monkeypatch.setenv("FROST_DDR_MODEL_SEED", seed)
    monkeypatch.delenv("FROST_VERILATOR_EXTRA_ARGS", raising=False)
    monkeypatch.delenv("DDR_MODEL_LATENCY", raising=False)
    runner = _soc_runner()
    timing = test_run_cocotb.ddr_model_timing(seed)
    drawn = tuple(f"-G{name}={value}" for name, value in timing.items())
    assert runner.verilator_extra_args == drawn
    assert _soc_runner().verilator_extra_args == drawn
    # A new seed rebuilds the model rather than reusing another draw's build.
    assert all(argument in runner._verilator_build_signature() for argument in drawn)
    low, high = test_run_cocotb.DDR_MODEL_LATENCY_RANGE
    assert low <= timing["DDR_MODEL_LATENCY"] <= high
    jitter = timing["DDR_MODEL_LATENCY_JITTER"]
    assert jitter in test_run_cocotb.DDR_MODEL_JITTER_CHOICES
    assert timing["DDR_MODEL_REORDER"] in (0, 1)
    assert f"FROST_DDR_MODEL_SEED={seed}: " in capsys.readouterr().out


def test_ddr_model_seed_keeps_pinned_settings(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Registry pins, FROST_VERILATOR_EXTRA_ARGS, and DDR_MODEL_LATENCY win."""
    monkeypatch.setenv("FROST_DDR_MODEL_SEED", "7")
    monkeypatch.delenv("DDR_MODEL_LATENCY", raising=False)
    monkeypatch.setenv("FROST_VERILATOR_EXTRA_ARGS", "-GDDR_MODEL_REORDER=0")
    pinned = ("-GL2_CACHE_BYTES=4096", "-GDDR_MODEL_LATENCY=70")
    arguments = _soc_runner(pinned).verilator_extra_args
    # The draw comes first, so the pins after it win even in Verilator.
    assert arguments[-len(pinned) :] == pinned
    drawn = [argument.split("=")[0] for argument in arguments[: -len(pinned)]]
    assert drawn == ["-GDDR_MODEL_LATENCY_JITTER"]

    monkeypatch.delenv("FROST_VERILATOR_EXTRA_ARGS")
    monkeypatch.setenv("DDR_MODEL_LATENCY", "80")
    drawn = [argument.split("=")[0] for argument in _soc_runner().verilator_extra_args]
    assert drawn == ["-GDDR_MODEL_LATENCY_JITTER", "-GDDR_MODEL_REORDER"]


def test_ddr_model_timing_needs_a_seed_and_the_soc(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Without a seed, or for a unit bench, the build arguments do not change."""
    monkeypatch.delenv("FROST_DDR_MODEL_SEED", raising=False)
    assert _soc_runner(("-GPERF_COUNTERS=1",)).verilator_extra_args == (
        "-GPERF_COUNTERS=1",
    )
    monkeypatch.setenv("FROST_DDR_MODEL_SEED", "7")
    unit_bench = test_run_cocotb.CocotbRunner(
        python_test_module="cocotb_tests.if_stage.test_instruction_aligner",
        hdl_toplevel_module="instruction_aligner",
    )
    assert unit_bench.verilator_extra_args == ()


@pytest.mark.parametrize("outcome", ("pass", "exit", "timeout"))
def test_arch_simulation_signature_and_diagnostics(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    outcome: str,
) -> None:
    """Arch runs name the signature's low-BRAM bytes and its file, and run once.

    The UART carries only the pass marker, so frost.sv's dropped-byte check
    stays on.
    """
    monkeypatch.setenv("SIM", "verilator")
    signature_file = tmp_path / "tests" / "arch_signature.txt"
    monkeypatch.setattr(test_arch_compliance, "TESTS_DIR", tmp_path / "tests")
    monkeypatch.setattr(test_arch_compliance, "ARCH_TEST_APP_DIR", tmp_path / "app")
    monkeypatch.setattr(test_arch_compliance, "SIGNATURE_FILE", signature_file)
    (tmp_path / "tests").mkdir()
    signature_file.write_text("stale\n")
    elves: list[Path] = []

    def signature_location(elf: Path) -> tuple[int, int]:
        elves.append(elf)
        return 0x3EC90, 0x1370

    monkeypatch.setattr(test_arch_compliance, "signature_location", signature_location)
    runner_class = test_run_cocotb.CocotbRunner
    monkeypatch.setattr(
        runner_class, "setup_environment", lambda _self: {"COCOTB_PLUSARGS": "+seed"}
    )
    monkeypatch.setattr(runner_class, "_verilator_needs_rebuild", lambda *_: False)
    monkeypatch.setattr(
        runner_class, "_update_verilator_toplevel_marker", lambda *_: None
    )
    environments: list[dict[str, str]] = []

    def simulation_run(
        _command: list[str], *, env: dict[str, str], timeout: float
    ) -> subprocess.CompletedProcess[str]:
        environments.append(env)
        if outcome == "timeout":
            raise subprocess.TimeoutExpired(
                ["make"], timeout, output=b"boot progress\n", stderr=b"worker stalled\n"
            )
        return subprocess.CompletedProcess(
            args=["make"],
            returncode=0 if outcome == "pass" else 2,
            stdout="boot progress\n",
            stderr="worker stalled\n",
        )

    monkeypatch.setattr(test_arch_compliance, "run_in_process_group", simulation_run)

    result = test_arch_compliance.run_simulation()
    assert (result is None) == (outcome == "timeout")
    if result is not None:
        assert result.returncode == (0 if outcome == "pass" else 2)
    output = capsys.readouterr().out
    if outcome != "pass":
        assert "boot progress" in output
        assert "worker stalled" in output

    assert elves == [tmp_path / "app" / "sw.elf"]
    assert not signature_file.exists()
    assert [
        (
            env["FROST_ARCH_SIGNATURE"],
            env["FROST_ARCH_SIGNATURE_FILE"],
            env["COCOTB_NUM_RUNS"],
            env["COCOTB_PLUSARGS"],
        )
        for env in environments
    ] == [("0x3ec90:0x1370", str(signature_file), "1", "+seed")]


def test_run_in_process_group_returns_output() -> None:
    """A command that finishes in time returns its exit code and output."""
    result = test_run_cocotb.run_in_process_group(
        ["bash", "-c", "echo out; echo err >&2; exit 3"], env=os.environ, timeout=30
    )
    assert result.returncode == 3
    assert result.stdout == "out\n"
    assert result.stderr == "err\n"


def test_run_in_process_group_kills_grandchildren_on_timeout(tmp_path: Path) -> None:
    """A timeout kills the command's whole process group, not just its shell."""
    pid_file = tmp_path / "child.pid"
    with pytest.raises(subprocess.TimeoutExpired):
        test_run_cocotb.run_in_process_group(
            ["bash", "-c", f"sleep 60 & echo $! > {pid_file}; wait"],
            env=os.environ,
            timeout=1,
        )
    child = int(pid_file.read_text())
    for _ in range(50):
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    pytest.fail(f"grandchild {child} survived the timeout")


def test_seed_sweep_restores_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """A seed sweep undoes its registry entry's environment overrides."""
    from concurrent.futures import Future

    class _InlineExecutor:
        def __init__(self, max_workers: int) -> None:
            del max_workers

        def __enter__(self) -> "_InlineExecutor":
            return self

        def __exit__(self, *exc: object) -> None:
            return None

        def submit(
            self, function: Callable[..., object], *args: object
        ) -> Future[object]:
            del function
            worker_cores.append(os.environ.get("NUMBER_OF_CPU_CORES"))
            future: Future[object] = Future()
            future.set_result((args[1], True, ""))
            return future

    worker_cores: list[str | None] = []

    config = test_run_cocotb.CocotbRunConfig(
        python_test_module="cocotb_tests.sweep_probe",
        hdl_toplevel_module="sweep_probe",
        extra_env=(("FROST_SWEEP_ENV_PROBE", "set"),),
    )
    monkeypatch.setitem(test_run_cocotb.TEST_REGISTRY, "sweep_probe", config)
    monkeypatch.setattr(test_run_cocotb, "ProcessPoolExecutor", _InlineExecutor)
    monkeypatch.delenv("FROST_SWEEP_ENV_PROBE", raising=False)
    monkeypatch.delenv("NUMBER_OF_CPU_CORES", raising=False)
    monkeypatch.setattr(os, "cpu_count", lambda: 8)

    report = test_run_cocotb.run_seed_sweep("sweep_probe", num_seeds=2)

    assert report["passed"] == 2
    assert "FROST_SWEEP_ENV_PROBE" not in os.environ
    # The two workers split the eight cores for their builds, and the
    # setting ends with the sweep.
    assert worker_cores == ["4", "4"]
    assert "NUMBER_OF_CPU_CORES" not in os.environ


def test_coverage_runs_rebuild_and_write_a_file_each(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """FROST_COVERAGE changes the build and names one coverage file per run."""
    monkeypatch.delenv("FROST_DDR_MODEL_SEED", raising=False)
    monkeypatch.delenv("FROST_COCOTB_MEM_CONFIG", raising=False)
    monkeypatch.delenv("FROST_COVERAGE_FILE", raising=False)
    monkeypatch.delenv("FROST_COVERAGE", raising=False)
    monkeypatch.delenv("FROST_COVERAGE_TOGGLE", raising=False)
    monkeypatch.setenv("FROST_COVERAGE_DIR", str(tmp_path / "coverage"))
    runner = test_run_cocotb.CocotbRunner.for_test("dma_torture")
    plain_signature = runner._verilator_build_signature()
    assert "FROST_COVERAGE_FILE" not in runner.setup_environment()

    monkeypatch.setenv("FROST_COVERAGE", "1")
    assert "FROST_COVERAGE=1" in runner._verilator_build_signature()
    assert runner._verilator_build_signature() != plain_signature
    signatures = set()
    for mode in ("0", "1", "control"):
        monkeypatch.setenv("FROST_COVERAGE_TOGGLE", mode)
        signatures.add(runner._verilator_build_signature())
    assert len(signatures) == 3
    first = Path(runner.setup_environment()["FROST_COVERAGE_FILE"])
    assert first == tmp_path / "coverage" / "dma_torture_bram.dat"
    first.write_text("written by the first run")
    second = Path(runner.setup_environment()["FROST_COVERAGE_FILE"])
    assert second == tmp_path / "coverage" / "dma_torture_bram-2.dat"

    unit_bench = test_run_cocotb.CocotbRunner.for_test("load_queue")
    assert unit_bench.coverage_label == "load_queue"
    monkeypatch.setattr(test_run_cocotb, "REPOSITORY_ROOT", tmp_path)
    monkeypatch.setenv("FROST_COVERAGE_DIR", "relative/runs")
    assert test_run_cocotb.coverage_file("a b/c") == (
        tmp_path / "relative" / "runs" / "a_b_c.dat"
    )


def test_calibration_test_limits_the_capture_to_one_test(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """FROST_CALIBRATION_TEST keeps the capture's files from the other tests."""
    monkeypatch.delenv("FROST_DDR_MODEL_SEED", raising=False)
    monkeypatch.delenv("FROST_COVERAGE", raising=False)
    monkeypatch.delenv("FROST_CALIBRATION_TEST", raising=False)
    # coremark_profile's registry entry sets this when its runner is made.
    monkeypatch.setenv("FROST_EXPECT_PERF_COUNTERS", "")
    outputs = test_run_cocotb.CALIBRATION_OUTPUT_VARIABLES
    for name in outputs:
        monkeypatch.setenv(name, f"tests/calibration/{name}")
    coremark = test_run_cocotb.CocotbRunner.for_test("coremark")
    profile = test_run_cocotb.CocotbRunner.for_test("coremark_profile")
    assert all(name in profile.setup_environment() for name in outputs)

    monkeypatch.setenv("FROST_CALIBRATION_TEST", "coremark")
    assert all(name in coremark.setup_environment() for name in outputs)
    assert not any(name in profile.setup_environment() for name in outputs)
    assert all(os.environ[name] for name in outputs)


def test_real_programs_with_the_same_build_are_collected_together() -> None:
    """Each Verilator argument set is one run of the collection order."""
    arguments = [
        test_run_cocotb.TEST_REGISTRY[name].verilator_extra_args
        for name in test_run_cocotb.REAL_PROGRAM_TESTS
    ]
    changes = [arguments[0]] + [
        current
        for previous, current in zip(arguments, arguments[1:], strict=False)
        if current != previous
    ]
    assert len(changes) == len(set(changes))
    registered = [
        name
        for name, config in test_run_cocotb.TEST_REGISTRY.items()
        if config.app_name is not None and config.include_in_pytest
    ]
    for build in set(arguments):
        assert [
            name
            for name in test_run_cocotb.REAL_PROGRAM_TESTS
            if test_run_cocotb.TEST_REGISTRY[name].verilator_extra_args == build
        ] == [
            name
            for name in registered
            if test_run_cocotb.TEST_REGISTRY[name].verilator_extra_args == build
        ]


def test_rerun_setting_reaches_the_bench(monkeypatch: pytest.MonkeyPatch) -> None:
    """rerun_after_reset=False runs an application once; the default keeps two."""
    monkeypatch.delenv("COCOTB_NUM_RUNS", raising=False)
    config = test_run_cocotb.CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="hello_world",
    )
    twice = test_run_cocotb.CocotbRunner.from_config(config)
    twice.restore_environment()
    once = test_run_cocotb.CocotbRunner.from_config(
        replace(config, rerun_after_reset=False)
    )
    once.restore_environment()
    assert "COCOTB_NUM_RUNS" not in dict(twice.extra_env)
    assert dict(once.extra_env)["COCOTB_NUM_RUNS"] == "1"
    assert "COCOTB_NUM_RUNS" not in os.environ


def test_single_run_entries_are_the_ones_tests_readme_lists() -> None:
    """The table of applications that run once matches the registry."""
    readme = (Path(test_run_cocotb.__file__).parent / "README.md").read_text()
    table = readme.split("| Entries that run once | Reason |", 1)[1].split("\n\n", 1)[0]
    single = {
        name
        for name, config in test_run_cocotb.TEST_REGISTRY.items()
        if config.app_name is not None
        and config.include_in_pytest
        and not config.rerun_after_reset
    }
    assert set(re.findall(r"`([a-z0-9_]+)`", table)) == single


@pytest.mark.parametrize("clock_override", (None, "0", "1"))
def test_nic_clock_setting_reaches_the_bench(
    monkeypatch: pytest.MonkeyPatch, clock_override: str | None
) -> None:
    """The registry supplies a default and respects explicit clock settings."""
    monkeypatch.delenv("FROST_NIC_MAC_CLOCKS", raising=False)
    if clock_override is not None:
        monkeypatch.setenv("FROST_NIC_MAC_CLOCKS", clock_override)
    config = test_run_cocotb.CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="hello_world",
    )
    clocked = test_run_cocotb.CocotbRunner.from_config(config)
    clocked.restore_environment()
    unclocked = test_run_cocotb.CocotbRunner.from_config(
        replace(config, nic_mac_clocks=False)
    )
    assert os.environ["FROST_NIC_MAC_CLOCKS"] == (clock_override or "0")
    unclocked.restore_environment()
    assert "FROST_NIC_MAC_CLOCKS" not in dict(clocked.extra_env)
    assert os.environ.get("FROST_NIC_MAC_CLOCKS") == clock_override


@pytest.mark.parametrize(
    ("module", "app_directory", "arguments"),
    (
        (test_arch_compliance, "ARCH_TEST_APP_DIR", ()),
        (test_riscv_tests, "RISCV_TESTS_APP_DIR", ("verilator",)),
        (test_riscv_torture, "TORTURE_APP_DIR", ("verilator",)),
    ),
)
@pytest.mark.parametrize("clock_override", (None, "0", "1"))
def test_isa_runners_default_to_no_nic_clocks(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    module: ModuleType,
    app_directory: str,
    arguments: tuple[str, ...],
    clock_override: str | None,
) -> None:
    """Each ISA runner passes the default or explicit setting to the bench."""
    monkeypatch.setenv("SIM", "verilator")
    environment = {}
    if clock_override is not None:
        environment["FROST_NIC_MAC_CLOCKS"] = clock_override
    runner_class = test_run_cocotb.CocotbRunner
    monkeypatch.setattr(runner_class, "setup_environment", lambda _: dict(environment))
    monkeypatch.setattr(runner_class, "_verilator_needs_rebuild", lambda *_: False)
    monkeypatch.setattr(
        runner_class, "_update_verilator_toplevel_marker", lambda *_: None
    )
    monkeypatch.setattr(module, "TESTS_DIR", tmp_path)
    monkeypatch.setattr(module, app_directory, tmp_path / "app")
    monkeypatch.setattr(test_arch_compliance, "SIGNATURE_FILE", tmp_path / "signature")
    monkeypatch.setattr(test_arch_compliance, "signature_location", lambda _: (0, 4))

    def simulate(
        *_: object, env: dict[str, str], **__: object
    ) -> subprocess.CompletedProcess[str]:
        assert env["FROST_NIC_MAC_CLOCKS"] == (clock_override or "0")
        return subprocess.CompletedProcess(["make"], 0, "", "")

    monkeypatch.setattr(module, "run_in_process_group", simulate)
    assert module.run_simulation(*arguments).returncode == 0


def test_applications_that_name_the_nic_keep_its_clocks() -> None:
    """An application whose sources use the NIC's registers keeps the MAC clocks."""
    apps = Path(test_run_cocotb.__file__).resolve().parent.parent / "sw" / "apps"
    for name, config in test_run_cocotb.TEST_REGISTRY.items():
        if config.app_name is None or config.nic_mac_clocks:
            continue
        app_directory = apps / test_run_cocotb.app_build_directory_name(config.app_name)
        for source in sorted(app_directory.iterdir()):
            if source.suffix not in (".c", ".h", ".S") or source.name == "sw.S":
                continue
            text = source.read_text(errors="replace")
            assert not re.search(
                r"\bnic\.h\b|\bNIC_(BASE|ADDR)\b|\b0x4003_?0[0-9A-Fa-f]{3}", text
            ), f"{name} runs without the NIC's MAC clocks but {source} uses the NIC"

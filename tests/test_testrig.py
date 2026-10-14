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

"""Compare FROST with the Sail RISC-V model, instruction by instruction, in TestRIG.

QuickCheckVEngine generates random instruction sequences from templates and
sends each to two RVFI-DII implementations: the Sail model (implementation A)
and the simulated frost SoC (implementation B, cocotb test
cocotb_tests.test_rvfi_dii). It compares every retired instruction's
destination register, store, next PC, trap, and privilege mode, and shrinks a
mismatch to a short counterexample. Run in the frost image from the
repository root:

    ./scripts/frost.py run make -C tests clean
    ./scripts/frost.py run python3 tests/test_testrig.py
    ./scripts/frost.py run python3 tests/test_testrig.py --tests 200 --include 'arith|mem'
    ./scripts/frost.py run python3 tests/test_testrig.py --trace counterexample.S
    ./scripts/frost.py run python3 tests/test_testrig.py --atomics 200

The image provides sail_riscv_sim and QCVEngine. Counterexamples go to
--save-dir (tests/testrig_failures by default); replay one with --trace.
"""

import argparse
import importlib
import os
import random
import shutil
import signal
import socket
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

import pytest

from test_run_cocotb import TEST_REGISTRY, CocotbRunner

TESTS_DIR = Path(__file__).parent.resolve()
REPO_ROOT = TESTS_DIR.parent
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))
atomics = importlib.import_module("testrig.atomics")
SAIL_CONFIG = REPO_ROOT / "verif" / "testrig" / "sail_frost.json"
SAVED_TRACES_DIR = REPO_ROOT / "verif" / "testrig" / "traces"
DEFAULT_SAVE_DIR = TESTS_DIR / "testrig_failures"
DEFAULT_LOG_DIR = TESTS_DIR / "testrig_logs"

# QuickCheckVEngine's architecture string, which selects the templates and
# the instructions they generate: RV64 IMFDC with S and U modes (the "s" also
# enables the page-table templates), Zicsr, and Zifencei. FROST implements A,
# but the two implementations keep LR reservations under different rules that
# the specification allows (see verif/testrig/README.md), and the engine's
# atomic templates put traps between LR and SC, so random LR/SC sequences
# from them diverge. --atomics replays tests from verif/testrig/atomics.py
# instead, which keep traps out of those windows.
DEFAULT_ARCHITECTURE = "rv64imfdcs_zicsr_zifencei"
ATOMICS_ARCHITECTURE = "rv64imafdcs_zicsr_zifencei"

# Templates whose behavior the two implementations should agree on. The
# CHERI, unstructured (random 32-bit words, which reach FROST's custom CSRs
# and other implementation-defined encodings), and HPM-event templates are
# left out, as are the A-extension templates (atomic, atomic64, memAmo,
# memAmo64), which need A in --arch.
DEFAULT_TEST_INCLUDE = (
    "^(arith|arith64|mem|mem64|control|cache|cache64|muldiv|muldiv64|compressed|"
    "float|float64|double|double64|csr|fencei|fencei64|pte|all|random)$"
)

# CSRs the generators may access. Left out, as implementation-defined or
# nondeterministic between the two: the cycle and time counters (FROST counts
# clock cycles, Sail instructions); the interrupt enable and pending
# registers, since an interrupt consumes an instruction slot in Sail's
# RVFI-DII mode; stimecmp, whose timer compare depends on time; mtvec and
# stvec, whose reserved MODE values FROST and Sail legalize differently;
# mcause and scause, whose WLRL cause codes FROST keeps as written and Sail
# does not; and unnamed addresses, which include FROST's custom profiling
# CSRs.
DEFAULT_CSR_INCLUDE = (
    "^(fflags|frm|fcsr|instret|hpmcounter[0-9]+|sstatus|scounteren|senvcfg|"
    "sscratch|sepc|stval|satp|mvendorid|marchid|mimpid|mhartid|mstatus|misa|"
    "medeleg|mideleg|mcounteren|menvcfg|mscratch|mepc|mtval|pmpcfg[0-9]+|"
    "pmpaddr[0-9]+|minstret|mhpmcounter[0-9]+|mhpmevent[0-9]+|mcountinhibit)$"
)


def free_port() -> int:
    """Return a TCP port that was free a moment ago."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def tool_path(name: str, environment_variable: str) -> str:
    """Return a tool's path from the environment or PATH."""
    return os.environ.get(environment_variable, name)


def write_empty_images() -> list[Path]:
    """Write the memory images the frost toplevel loads at time zero.

    The rvfi_dii build fetches from the injected stream and clears memory on
    every reset, so the images only need to exist.
    """
    images = []
    for name, word in (("sw.mem", "00000000"), ("sw64.mem", "0000000000000000")):
        path = TESTS_DIR / name
        if path.is_symlink() or path.exists():
            path.unlink()
        path.write_text(f"{word}\n", encoding="ascii")
        images.append(path)
    return images


def start_frost(
    port: int, ready_file: Path, log_path: Path
) -> tuple[subprocess.Popen, Callable[[], None]]:
    """Build (if needed) and start the frost RVFI-DII simulation.

    Returns the process and a function that records a successful build, so
    the next run reuses it.
    """
    runner = CocotbRunner.from_config(TEST_REGISTRY["rvfi_dii"])
    environment = runner.setup_environment()
    sim_build_dir = runner._get_sim_build_dir(environment)
    environment["SIM_BUILD"] = str(sim_build_dir)
    environment["FROST_RVFI_DII_PORT"] = str(port)
    environment["FROST_RVFI_DII_READY_FILE"] = str(ready_file)
    if runner._verilator_needs_rebuild(sim_build_dir):
        subprocess.run(["make", "clean"], cwd=TESTS_DIR, check=False)
    command = (
        "make COCOTB_TEST_MODULES=cocotb_tests.test_rvfi_dii TOPLEVEL=frost && "
        "touch .rvfi_dii_build_ok"
    )
    log = log_path.open("w", encoding="utf-8")
    process = subprocess.Popen(
        ["bash", "-c", command],
        cwd=TESTS_DIR,
        env=environment,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    def record_build() -> None:
        runner._update_verilator_toplevel_marker(sim_build_dir)

    return process, record_build


def stop(process: subprocess.Popen | None, grace: float) -> None:
    """Wait briefly for a process group to exit, then kill it."""
    if process is None or process.poll() is not None:
        return
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def run(arguments: argparse.Namespace) -> int:
    """Run one TestRIG session and return QuickCheckVEngine's exit status."""
    save_dir = Path(arguments.save_dir).resolve()
    save_dir.mkdir(parents=True, exist_ok=True)
    work_dir = Path(arguments.log_dir).resolve()
    work_dir.mkdir(parents=True, exist_ok=True)
    sail_port = free_port()
    frost_port = free_port()
    ready_file = work_dir / "frost_ready"
    ready_file.unlink(missing_ok=True)
    frost_log = work_dir / "frost.log"
    sail_log = work_dir / "sail.log"
    images = write_empty_images()
    architecture = arguments.arch or (
        ATOMICS_ARCHITECTURE if arguments.atomics else DEFAULT_ARCHITECTURE
    )
    sail = frost = engine = None
    status = 1
    try:
        sail = subprocess.Popen(
            [
                tool_path("sail_riscv_sim", "FROST_SAIL_RISCV_SIM"),
                "--config-override",
                str(SAIL_CONFIG),
                # Injected streams trap to the same handler over and over.
                "--disable-trap-loop-detection",
                "--rvfi-dii",
                str(sail_port),
            ],
            stdout=sail_log.open("w", encoding="utf-8"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        frost, record_frost_build = start_frost(frost_port, ready_file, frost_log)
        print(f"Building and starting the frost RVFI-DII simulation (log: {frost_log})")
        deadline = time.monotonic() + arguments.startup_timeout
        while not ready_file.exists():
            if frost.poll() is not None:
                print(frost_log.read_text(encoding="utf-8", errors="replace")[-8000:])
                print("The frost simulation exited before listening")
                return 1
            if sail.poll() is not None:
                print(sail_log.read_text(encoding="utf-8", errors="replace"))
                print("The Sail model exited before the engine connected")
                return 1
            if time.monotonic() > deadline:
                print("Timed out waiting for the frost simulation to listen")
                return 1
            time.sleep(0.5)

        command = [
            tool_path("QCVEngine", "FROST_QCVENGINE"),
            "-a",
            str(sail_port),
            "-b",
            str(frost_port),
            "-r",
            architecture,
            "-v",
            str(arguments.verbosity),
            "-T",
            str(arguments.response_timeout * 1_000_000),
            "--csr-include-regex",
            arguments.csr_include,
            "-s",
            str(save_dir),
            "--statsFile",
            str(work_dir / "coverage_stats.txt"),
        ]
        if arguments.trace:
            command += ["-t", str(Path(arguments.trace).resolve())]
        elif arguments.trace_dir:
            command += ["-d", str(Path(arguments.trace_dir).resolve())]
        elif arguments.atomics:
            seed = arguments.seed
            if seed is None:
                seed = random.randrange(1 << 32)
            trace_dir = work_dir / "atomics"
            shutil.rmtree(trace_dir, ignore_errors=True)
            trace_dir.mkdir()
            atomics.write_tests(
                trace_dir, arguments.atomics, seed, arguments.test_length
            )
            print(
                f"Wrote {arguments.atomics} A-extension tests from seed {seed} "
                f"to {trace_dir} (--seed {seed} regenerates them)",
                flush=True,
            )
            command += ["-d", str(trace_dir)]
        else:
            command += [
                "-n",
                str(arguments.tests),
                "-L",
                str(arguments.test_length),
                "-I",
                arguments.include,
            ]
            if arguments.exclude:
                command += ["-x", arguments.exclude]
        if arguments.no_shrink:
            command.append("-S")
        if arguments.continue_on_fail:
            command.append("--continue-on-fail")
        print("Running:", " ".join(command), flush=True)
        # The engine writes last_failure.S to its working directory.
        engine = subprocess.Popen(
            command, stdin=subprocess.DEVNULL, cwd=work_dir, start_new_session=True
        )
        # The engine reads a closed connection forever, so stop it if the
        # simulation or the model exits first.
        while engine.poll() is None:
            if frost.poll() is not None or sail.poll() is not None:
                time.sleep(2)
                if engine.poll() is None:
                    print(
                        "An implementation exited during the run; stopping the engine"
                    )
                    stop(engine, grace=0)
                    engine.returncode = engine.returncode or 1
                break
            time.sleep(0.5)
        status = engine.wait()
        # The engine closes both connections when it finishes, which ends the
        # simulation and the model.
        stop(frost, grace=120)
        stop(sail, grace=10)
        frost_text = frost_log.read_text(encoding="utf-8", errors="replace")
        if (TESTS_DIR / ".rvfi_dii_build_ok").exists():
            record_frost_build()
        harness_failed = "FAIL=0" not in frost_text or "harness errors" in frost_text
        if harness_failed:
            print(frost_text[-8000:])
            print("The frost RVFI-DII simulation reported an error")
            status = status or 1
        print(f"QuickCheckVEngine exit status {status}; logs in {work_dir}")
        return status
    finally:
        stop(engine, grace=0)
        stop(frost, grace=1)
        stop(sail, grace=1)
        for image in images:
            image.unlink(missing_ok=True)
        (TESTS_DIR / ".rvfi_dii_build_ok").unlink(missing_ok=True)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--tests", type=int, default=50, help="tests per template (default 50)"
    )
    parser.add_argument(
        "--test-length",
        type=int,
        default=200,
        help="maximum instructions per test (default 200)",
    )
    parser.add_argument(
        "--arch",
        help="architecture the templates target (default "
        f"{DEFAULT_ARCHITECTURE}, or {ATOMICS_ARCHITECTURE} with --atomics)",
    )
    parser.add_argument(
        "--include", default=DEFAULT_TEST_INCLUDE, help="template name regex"
    )
    parser.add_argument("--exclude", default="", help="template names to skip")
    parser.add_argument(
        "--csr-include",
        default=DEFAULT_CSR_INCLUDE,
        help="regex of CSR names the templates may access",
    )
    parser.add_argument("--trace", help="replay one saved trace instead")
    parser.add_argument("--trace-dir", help="replay every .S trace in a directory")
    parser.add_argument(
        "--atomics",
        type=int,
        default=0,
        help="instead of the templates, replay this many random A-extension "
        "tests from verif/testrig/atomics.py",
    )
    parser.add_argument(
        "--seed",
        type=int,
        help="seed for --atomics (default: random, printed)",
    )
    parser.add_argument(
        "--save-dir",
        default=str(DEFAULT_SAVE_DIR),
        help="where to write counterexamples",
    )
    parser.add_argument(
        "--log-dir",
        default=str(DEFAULT_LOG_DIR),
        help="where to write the simulation, model, and coverage logs",
    )
    parser.add_argument(
        "--no-shrink", action="store_true", help="report failures unshrunk"
    )
    parser.add_argument(
        "--continue-on-fail",
        action="store_true",
        help="keep testing after a failure",
    )
    parser.add_argument("--verbosity", type=int, default=1)
    parser.add_argument(
        "--startup-timeout",
        type=int,
        default=3600,
        help="seconds to wait for the simulation build (default 3600)",
    )
    parser.add_argument(
        "--response-timeout",
        type=int,
        default=600,
        help="seconds the engine waits for one test's trace (default 600)",
    )
    return parser.parse_args(argv)


@pytest.mark.cocotb
@pytest.mark.slow
def test_testrig_saved_traces() -> None:
    """Replay the saved counterexamples on FROST and Sail."""
    for name, variable in (
        ("sail_riscv_sim", "FROST_SAIL_RISCV_SIM"),
        ("QCVEngine", "FROST_QCVENGINE"),
    ):
        if shutil.which(tool_path(name, variable)) is None:
            pytest.skip(f"{name} is not installed (it is in the frost image)")
    arguments = ["--trace-dir", str(SAVED_TRACES_DIR), "--continue-on-fail"]
    assert run(parse_arguments(arguments)) == 0


def main() -> int:
    """Parse arguments and run TestRIG."""
    sys.stdout.reconfigure(line_buffering=True)  # type: ignore[union-attr]
    return run(parse_arguments())


if __name__ == "__main__":
    sys.exit(main())

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
    ./scripts/frost.py run python3 tests/test_testrig.py --mmu 100
    ./scripts/frost.py run python3 tests/test_testrig.py --cmo 100
    ./scripts/frost.py run python3 tests/test_testrig.py --wfi
    ./scripts/frost.py run python3 tests/test_testrig.py --sscofpmf

The image provides sail_riscv_sim and QCVEngine. Counterexamples go to
--save-dir (tests/testrig_failures by default); replay one with --trace.
"""

import argparse
import importlib
import json
import os
import random
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import TYPE_CHECKING, Any

import pytest

from test_run_cocotb import TEST_REGISTRY, CocotbRunner

if TYPE_CHECKING:
    from testrig.wfi import WfiStrand

TESTS_DIR = Path(__file__).parent.resolve()
REPO_ROOT = TESTS_DIR.parent
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))
atomics = importlib.import_module("testrig.atomics")
cmo = importlib.import_module("testrig.cmo")
crypto = importlib.import_module("testrig.crypto")
mmu = importlib.import_module("testrig.mmu")
rvfi_dii = importlib.import_module("testrig.rvfi_dii")
vector = importlib.import_module("testrig.vector")
compressed_mops = importlib.import_module("testrig.compressed_mops")
fp_ext = importlib.import_module("testrig.fp_ext")
svinval = importlib.import_module("testrig.svinval")
wfi = importlib.import_module("testrig.wfi")
run_stats = importlib.import_module("testrig.run_stats")
TraceMonitor = run_stats.TraceMonitor
SAIL_CONFIG = REPO_ROOT / "verif" / "testrig" / "sail_frost.json"
DEFAULT_VECTOR_LENGTH = 128
SAVED_TRACES_DIR = REPO_ROOT / "verif" / "testrig" / "traces"
VECTOR_SOURCE_WIDTH_TRACES = tuple(
    VERIF_DIR / "testrig" / f"vector_source_widths_{family}.S"
    for family in ("integer", "fp", "memory")
)
VECTOR_DIRECTED_TRACES = tuple(
    VERIF_DIR / "testrig" / f"vector_{family}.S"
    for family in (
        "state_results",
        "fractional_lmul",
        "fp_results_flags",
        "fma",
        "fp_compare",
        "fp_convert",
        "cached_load",
        "cached_store",
        "unit_stride",
        "int_compare",
        "strided",
        "indexed",
    )
)
SSCOFPMF_TRACE = REPO_ROOT / "verif" / "testrig" / "sscofpmf" / "controls.S"
DEFAULT_SAVE_DIR = TESTS_DIR / "testrig_failures"
DEFAULT_LOG_DIR = TESTS_DIR / "testrig_logs"
DEFAULT_DDR_CAPACITY_LOG2_BYTES = 30

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

# HPM event selectors 3..10 have implementation-defined WARL values and are
# checked by the CSR, privilege and --sscofpmf traces; leaving them untouched
# in random traces keeps every HPM counter disabled so mhpmcounter3..31,
# hpmcounter3..31 and scountovf can be compared directly.
# CSRs the generators may access. Left out, as implementation-defined or
# nondeterministic between the two: the cycle and time counters (FROST counts
# clock cycles, Sail instructions); the interrupt enable and pending
# registers, since an interrupt consumes an instruction slot in Sail's
# RVFI-DII mode; mtvec and
# stvec, whose reserved MODE values FROST and Sail legalize differently;
# mcause and scause, whose WLRL cause codes FROST keeps as written and Sail
# does not; and unnamed addresses, which include FROST's custom profiling
# CSRs.
DEFAULT_CSR_INCLUDE = (
    "^(fflags|frm|fcsr|instret|hpmcounter([3-9]|[12][0-9]|3[01])|sstatus|scounteren|senvcfg|"
    "sscratch|sepc|stval|satp|stimecmp|scountovf|mvendorid|marchid|mimpid|mhartid|mstatus|misa|"
    "medeleg|mideleg|mcounteren|menvcfg|mscratch|mepc|mtval|pmpcfg[0-9]+|"
    "pmpaddr[0-9]+|minstret|mhpmcounter[0-9]+|mhpmevent(1[1-9]|2[0-9]|3[01])|mcountinhibit)$"
)


def free_ports() -> tuple[int, int]:
    """Choose distinct Sail and FROST ports while both reservations are held.

    Closing the first probe before binding the second lets the OS assign
    the same ephemeral port twice. Release both only after choosing the pair.
    """
    with (
        socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sail,
        socket.socket(socket.AF_INET, socket.SOCK_STREAM) as frost,
    ):
        sail.bind(("127.0.0.1", 0))
        frost.bind(("127.0.0.1", 0))
        return sail.getsockname()[1], frost.getsockname()[1]


def tool_path(name: str, environment_variable: str) -> str:
    """Return a tool's path from the environment or PATH."""
    return os.environ.get(environment_variable, name)


def load_sail_json(path: Path) -> dict[str, Any]:
    """Read a Sail configuration file, which may carry // comment lines."""
    lines = path.read_text(encoding="utf-8").splitlines()
    return json.loads(
        "\n".join(line for line in lines if not line.lstrip().startswith("//"))
    )


def sail_vector_overlay(vlen: int) -> Path:
    """Return the settings that turn on the vector unit at one vector length."""
    if vlen not in vector.VECTOR_LENGTHS:
        raise ValueError(f"VLEN must be one of {vector.VECTOR_LENGTHS}, got {vlen}")
    return SAIL_CONFIG.with_name(f"sail_frost_vlen{vlen}.json")


def merge_settings(base: dict[str, Any], overlay: dict[str, Any]) -> None:
    """Merge overlay into base, replacing leaves and merging objects."""
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge_settings(base[key], value)
        else:
            base[key] = value


def write_sail_config(
    capacity_log2_bytes: int,
    work_dir: Path,
    *,
    sscofpmf: bool = False,
    vlen: int | None = None,
    wfi_mode: bool = False,
) -> Path:
    """Match DDR capacity and apply the selected test-mode overlays.

    `sscofpmf` selects the dedicated Sscofpmf control config filename suffix;
    the vector unit at `vlen` is for the --vector traces, which FROST must be
    built for with -GVECTOR=1 -GVLEN.
    """
    if capacity_log2_bytes not in range(30, 38):
        raise ValueError("DDR capacity must be 1, 2, 4, 8, 16, 32, 64 or 128 GiB")
    config = load_sail_json(SAIL_CONFIG)
    if vlen is not None:
        merge_settings(config, load_sail_json(sail_vector_overlay(vlen)))
    if wfi_mode:
        merge_settings(
            config, load_sail_json(SAIL_CONFIG.with_name("sail_frost_wfi.json"))
        )
    ddr_regions = [
        region
        for region in config["memory"]["regions"]
        if int(region["base"]["value"], 16) == 0x8000_0000
        and region["attributes"]["mem_type"] == "MainMemory"
    ]
    if len(ddr_regions) != 1:
        raise ValueError("Sail configuration must contain exactly one FROST DDR region")
    ddr_regions[0]["size"]["value"] = f"0x{1 << capacity_log2_bytes:x}"
    suffix = ("_sscofpmf" if sscofpmf else "") + (f"_v{vlen}" if vlen else "")
    if wfi_mode:
        suffix += "_wfi"
    path = work_dir / f"sail_frost_ddr{capacity_log2_bytes}{suffix}.json"
    path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    return path


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


def read_rvfi_log(path: Path) -> dict[str, dict[str, Any]]:
    """Read the per-trace observations written by test_rvfi_dii."""
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as stream:
        return {
            entry["digest"]: entry
            for entry in (json.loads(line) for line in stream if line.strip())
        }


def load_rvfi_records_log(path: Path) -> dict[str, list[Any]]:
    """Decode compact per-trace RVFI summaries for the MMU and CMO checks."""
    return {
        digest: [
            rvfi_dii.RvfiRecord(
                mode=mode, trap=trap, rd_addr=rd_addr, rd_wdata=rd_wdata
            )
            for mode, trap, rd_addr, rd_wdata in entry["records"]
        ]
        for digest, entry in read_rvfi_log(path).items()
    }


def start_frost(
    port: int,
    ready_file: Path,
    log_path: Path,
    capacity_log2_bytes: int,
    vlen: int | None = None,
    records_log: Path | None = None,
    *,
    wfi_timeout_cycles: int = 0,
) -> tuple[subprocess.Popen, Callable[[], None]]:
    """Build (if needed) and start the frost RVFI-DII simulation.

    Returns the process and a function that records a successful build, so
    the next run reuses it.
    """
    base_config = TEST_REGISTRY["rvfi_dii"]
    vector_args = ("-GVECTOR=1", f"-GVLEN={vlen}") if vlen else ()
    wfi_args = (
        (f"-DFROST_RVFI_DII_WFI_TIMEOUT={wfi_timeout_cycles}",)
        if wfi_timeout_cycles
        else ()
    )
    config = replace(
        base_config,
        verilator_extra_args=(
            *base_config.verilator_extra_args,
            f"-DFROST_DDR_CAPACITY_LOG2_BYTES={capacity_log2_bytes}",
            *vector_args,
            *wfi_args,
        ),
    )
    runner = CocotbRunner.from_config(config)
    runner.coverage_label = "testrig"
    environment = runner.setup_environment()
    sim_build_dir = runner._get_sim_build_dir(environment)
    environment["SIM_BUILD"] = str(sim_build_dir)
    environment["FROST_RVFI_DII_PORT"] = str(port)
    environment["FROST_RVFI_DII_READY_FILE"] = str(ready_file)
    if records_log is not None:
        environment["FROST_RVFI_DII_RECORDS_LOG"] = str(records_log)
    environment["FROST_RVFI_DII_WFI_OBSERVE"] = "1" if wfi_timeout_cycles else "0"
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


@dataclass
class TracePlan:
    """Engine inputs and the minimum amount of work a session must compare."""

    command: list[str]
    traces: int
    instructions: int
    generated: bool = False
    mode_check: tuple[str, tuple[str, ...], int, list[list[Any]]] | None = None
    wfi_strands: tuple["WfiStrand", ...] = ()


def prepare_inputs(
    arguments: argparse.Namespace, work_dir: Path, sail_config: Path
) -> TracePlan:
    """Generate or discover replay inputs before starting implementations."""
    command: list[str] = []
    mode_check = None
    wfi_strands = ()
    vector_traces: list[Path] = []
    if arguments.trace is not None:
        command += ["-t", str(Path(arguments.trace).resolve())]
    elif arguments.sscofpmf:
        command += ["-t", str(SSCOFPMF_TRACE)]
    elif arguments.trace_dir is not None:
        command += ["-d", str(Path(arguments.trace_dir).resolve())]
    elif arguments.wfi:
        trace_dir = work_dir / "wfi"
        shutil.rmtree(trace_dir, ignore_errors=True)
        wfi_strands = wfi.write_tests(trace_dir)
        print(
            f"Wrote {len(wfi_strands)} directed WFI traces to {trace_dir}", flush=True
        )
        command += ["-d", str(trace_dir)]
    elif arguments.zcb:
        seed = (
            arguments.seed if arguments.seed is not None else random.randrange(1 << 32)
        )
        trace_dir = work_dir / "compressed_mops"
        shutil.rmtree(trace_dir, ignore_errors=True)
        compressed_mops.write_tests(
            trace_dir, arguments.zcb, seed, arguments.test_length
        )
        print(
            f"Wrote {arguments.zcb} Zcb/Zcmop/Zimop/Zihintntl tests from seed {seed}",
            flush=True,
        )
        command += ["-d", str(trace_dir)]
    elif arguments.crypto:
        seed = (
            arguments.seed if arguments.seed is not None else random.randrange(1 << 32)
        )
        trace_dir = work_dir / "crypto"
        shutil.rmtree(trace_dir, ignore_errors=True)
        crypto.write_tests(trace_dir, arguments.crypto, seed, arguments.test_length)
        print(
            f"Wrote {arguments.crypto} scalar cryptography tests from seed {seed}",
            flush=True,
        )
        command += ["-d", str(trace_dir)]
    elif arguments.vector:
        seed = (
            arguments.seed if arguments.seed is not None else random.randrange(1 << 32)
        )
        trace_dir = work_dir / "vector"
        shutil.rmtree(trace_dir, ignore_errors=True)
        vector.write_tests(
            trace_dir,
            arguments.vector,
            seed,
            arguments.vector_length,
            arguments.vlen,
        )
        if arguments.vector_source_widths:
            vector_traces.extend(VECTOR_SOURCE_WIDTH_TRACES)
        if arguments.vector_directed:
            vector_traces.extend(VECTOR_DIRECTED_TRACES)
        for trace in vector_traces:
            shutil.copyfile(trace, trace_dir / trace.name)
        print(
            f"Wrote {arguments.vector} vector tests at VLEN {arguments.vlen} "
            f"from seed {seed} (--seed {seed} regenerates them)",
            flush=True,
        )
        command += ["-d", str(trace_dir)]
    elif arguments.fp_ext:
        seed = (
            arguments.seed if arguments.seed is not None else random.randrange(1 << 32)
        )
        trace_dir = work_dir / "fp_ext"
        shutil.rmtree(trace_dir, ignore_errors=True)
        fp_ext.write_tests(trace_dir, arguments.fp_ext, seed, arguments.test_length)
        print(
            f"Wrote {arguments.fp_ext} Zfhmin/Zfa tests from seed {seed}",
            flush=True,
        )
        command += ["-d", str(trace_dir)]
    elif arguments.svinval:
        seed = (
            arguments.seed if arguments.seed is not None else random.randrange(1 << 32)
        )
        trace_dir = work_dir / "svinval"
        shutil.rmtree(trace_dir, ignore_errors=True)
        svinval.write_tests(trace_dir, arguments.svinval, seed, arguments.test_length)
        print(
            f"Wrote {arguments.svinval} Svinval tests from seed {seed}",
            flush=True,
        )
        command += ["-d", str(trace_dir)]
    elif arguments.mmu:
        seed = (
            arguments.seed if arguments.seed is not None else random.randrange(1 << 32)
        )
        trace_dir = work_dir / "mmu"
        shutil.rmtree(trace_dir, ignore_errors=True)
        _, strands = mmu.write_tests_with_strands(
            trace_dir, arguments.mmu, seed, arguments.test_length
        )
        mode_check = ("mmu", mmu.STRAND_KINDS, mmu.MIN_FULL_SAMPLE, strands)
        print(
            f"Wrote {arguments.mmu} Sv39 MMU tests from seed {seed} "
            f"to {trace_dir} (--seed {seed} regenerates them)",
            flush=True,
        )
        command += ["-d", str(trace_dir)]
    elif arguments.cmo:
        seed = (
            arguments.seed if arguments.seed is not None else random.randrange(1 << 32)
        )
        trace_dir = work_dir / "cmo"
        shutil.rmtree(trace_dir, ignore_errors=True)
        _, strands = cmo.write_tests_with_strands(
            trace_dir, arguments.cmo, seed, arguments.test_length
        )
        mode_check = ("cmo", cmo.STRAND_KINDS, cmo.MIN_FULL_SAMPLE, strands)
        print(
            f"Wrote {arguments.cmo} CMO and Sstvala tests from seed {seed} "
            f"to {trace_dir} (--seed {seed} regenerates them)",
            flush=True,
        )
        command += ["-d", str(trace_dir)]
    elif arguments.atomics:
        seed = arguments.seed
        if seed is None:
            seed = random.randrange(1 << 32)
        trace_dir = work_dir / "atomics"
        shutil.rmtree(trace_dir, ignore_errors=True)
        trace_dir.mkdir()
        atomics.write_tests(
            trace_dir,
            arguments.atomics,
            seed,
            arguments.test_length,
            config_path=sail_config,
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
    if "-d" in command:
        directory = Path(command[command.index("-d") + 1])
        paths = sorted(p for p in directory.rglob("*.S") if p.is_file())
        requested = next(
            (
                count
                for count in (
                    arguments.atomics,
                    arguments.crypto,
                    arguments.zcb,
                    arguments.fp_ext,
                    arguments.svinval,
                    arguments.mmu,
                    arguments.cmo,
                    arguments.vector,
                )
                if count is not None
            ),
            max(1, len(paths), len(wfi_strands)),
        )
        requested += len(vector_traces)
        if not directory.is_dir() or len(paths) < requested:
            raise ValueError(
                f"expected at least {requested} .S traces in {directory}; "
                f"found {len(paths)}"
            )
    elif "-t" in command:
        paths = [Path(command[command.index("-t") + 1])]
        requested = 1
    else:
        return TracePlan(command, arguments.tests, 1, generated=True)
    instructions = 0
    for path in paths:
        if not path.is_file():
            raise ValueError(f"expected a trace file at {path}; found no file")
        # Trace comments and assertion descriptions can contain directive names.
        text = re.sub(r'"(?:\\.|[^"\\])*"|#(?!>)[^\n]*', "", path.read_text())
        count = len(re.findall(r"\.(?:2|4)byte\b", text))
        if count == 0:
            raise ValueError(f"expected at least 1 instruction in {path}; found 0")
        instructions += count
    return TracePlan(
        command, requested, instructions, mode_check=mode_check, wfi_strands=wfi_strands
    )


def comparison_counts(
    monitors: list[Any], plan: TracePlan, engine_log: Path, tests: int
) -> tuple[int, int, int, int, str]:
    """Validate both peers' completed replies and the engine's requested work."""
    expected_traces, expected_instructions = plan.traces, plan.instructions
    error = ""
    if plan.generated:
        templates = []
        successes = []
        with engine_log.open(encoding="utf-8", errors="replace") as log:
            for line in log:
                if re.match(r"^\w+ -- .+:$", line.rstrip()):
                    templates.append(line.split(" -- ", 1)[0])
                if match := re.search(r"\+\+\+ OK, passed (\d+) tests?\.", line):
                    successes.append(int(match[1]))
        expected_traces = tests * max(1, len(templates))
        expected_instructions = 1
        if (
            not templates
            or len(successes) != len(templates)
            or any(count < tests for count in successes)
        ):
            error = (
                f"expected {tests} successful tests per selected template; "
                f"found {len(templates)} templates with completed counts {successes}"
            )
    for monitor in monitors:
        if monitor.errors:
            error = error or monitor.errors[0]
        for index, trace in enumerate(monitor.traces, 1):
            # QuickCheck includes size-zero cases within a nonempty session.
            if (
                trace.requested < 1 and not plan.generated
            ) or trace.received != trace.requested:
                error = error or (
                    f"expected {max(1, trace.requested)} instructions from "
                    f"{monitor.name} in trace {index}; found {trace.received}"
                )
    paired = list(zip(*(monitor.traces for monitor in monitors), strict=False))
    traces = sum(
        a.requested == b.requested == a.received == b.received for a, b in paired
    )
    instructions = sum(
        min(a.requested, b.requested, a.received, b.received) for a, b in paired
    )
    if len(monitors[0].traces) != len(monitors[1].traces):
        error = (
            error
            or "expected matching trace counts from Sail and FROST; found different counts"
        )
    if traces < expected_traces or instructions < expected_instructions:
        error = error or "incomplete comparisons"
    return traces, instructions, expected_traces, expected_instructions, error


def run(arguments: argparse.Namespace) -> int:
    """Run TestRIG and require the requested nonempty comparisons to finish."""
    save_dir = Path(arguments.save_dir).resolve()
    save_dir.mkdir(parents=True, exist_ok=True)
    work_dir = Path(arguments.log_dir).resolve()
    work_dir.mkdir(parents=True, exist_ok=True)
    sail_config = write_sail_config(
        arguments.ddr_capacity_log2_bytes,
        work_dir,
        sscofpmf=arguments.sscofpmf,
        vlen=arguments.vlen,
        wfi_mode=arguments.wfi,
    )
    try:
        plan = prepare_inputs(arguments, work_dir, sail_config)
    except (OSError, ValueError) as input_error:
        print(f"TestRIG FAIL: {input_error}", flush=True)
        return 1
    sail_port, frost_port = free_ports()
    ready_file = work_dir / "frost_ready"
    ready_file.unlink(missing_ok=True)
    frost_log = work_dir / "frost.log"
    sail_log = work_dir / "sail.log"
    records_log = (
        work_dir / "rvfi_records.jsonl"
        if (arguments.mmu or arguments.cmo or arguments.wfi)
        else None
    )
    if records_log is not None:
        records_log.unlink(missing_ok=True)
    mode_check = plan.mode_check
    monitors: list[Any] = []
    output_thread = None
    images = write_empty_images()
    architecture = arguments.arch or (
        ATOMICS_ARCHITECTURE
        if (arguments.atomics or arguments.mmu or arguments.cmo)
        else vector.ARCHITECTURE
        if arguments.vector
        else DEFAULT_ARCHITECTURE
    )
    sail = frost = engine = None
    status = 1

    def startup_failed(message: str) -> int:
        print(
            f"TestRIG FAIL: expected at least {plan.traces} traces and "
            f"{plan.instructions} instructions; found 0 traces and 0 instructions "
            f"compared; {message}; logs in {work_dir}",
            flush=True,
        )
        return 1

    try:
        sail = subprocess.Popen(
            [
                tool_path("sail_riscv_sim", "FROST_SAIL_RISCV_SIM"),
                "--config-override",
                str(sail_config),
                # Injected streams trap to the same handler over and over.
                "--disable-trap-loop-detection",
                "--rvfi-dii",
                str(sail_port),
            ],
            stdout=sail_log.open("w", encoding="utf-8"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        frost, record_frost_build = start_frost(
            frost_port,
            ready_file,
            frost_log,
            arguments.ddr_capacity_log2_bytes,
            arguments.vlen,
            records_log=records_log,
            wfi_timeout_cycles=wfi.DUT_TIMEOUT_CYCLES if arguments.wfi else 0,
        )
        print(f"Building and starting the frost RVFI-DII simulation (log: {frost_log})")
        deadline = time.monotonic() + arguments.startup_timeout
        while not ready_file.exists():
            if frost.poll() is not None:
                print(frost_log.read_text(encoding="utf-8", errors="replace")[-8000:])
                return startup_failed("the frost simulation exited before listening")
            if sail.poll() is not None:
                print(sail_log.read_text(encoding="utf-8", errors="replace"))
                return startup_failed(
                    "the Sail model exited before the engine connected"
                )
            if time.monotonic() > deadline:
                return startup_failed(
                    "timed out waiting for the frost simulation to listen"
                )
            time.sleep(0.5)

        sail_monitor = run_stats.WfiTraceMonitor if arguments.wfi else TraceMonitor
        monitors = [
            sail_monitor("Sail", sail_port, arguments.response_timeout),
            TraceMonitor("FROST", frost_port, arguments.response_timeout),
        ]
        if arguments.vlen and not arguments.wfi:
            monitors[0].clear_vector_stores = True
        command = [
            tool_path("QCVEngine", "FROST_QCVENGINE"),
            "-a",
            str(monitors[0].port),
            "-b",
            str(monitors[1].port),
            "-r",
            architecture,
            "-v",
            str(max(1, arguments.verbosity)),
            "-T",
            str(arguments.response_timeout * 1_000_000),
            "--csr-include-regex",
            arguments.csr_include,
            "-s",
            str(save_dir),
            "--statsFile",
            str(work_dir / "coverage_stats.txt"),
        ]
        command += plan.command
        if arguments.no_shrink:
            command.append("-S")
        if arguments.continue_on_fail:
            command.append("--continue-on-fail")
        print("Running:", " ".join(command), flush=True)
        # The engine writes last_failure.S to its working directory.
        engine_log = work_dir / "engine.log"
        engine = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            cwd=work_dir,
            start_new_session=True,
        )

        def copy_engine_output() -> None:
            assert engine is not None and engine.stdout is not None
            with engine_log.open("w", encoding="utf-8") as log:
                while chunk := engine.stdout.read(4096):
                    log.write(chunk)
                    if arguments.verbosity > 0:
                        print(chunk, end="", flush=True)

        output_thread = threading.Thread(target=copy_engine_output, daemon=True)
        output_thread.start()
        # The engine reads a closed connection forever, so stop it if the
        # simulation or the model exits first.
        while engine.poll() is None:
            if any(monitor.errors for monitor in monitors):
                stop(engine, grace=0)
                engine.returncode = engine.returncode or 1
                break
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
        output_thread.join()
        for monitor in monitors:
            monitor.close()
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
        if mode_check is not None and records_log is not None:
            mode_name, catalog, min_sample, strands = mode_check
            summary = mmu.verify_mode_rvfi(
                mode_name,
                catalog,
                strands,
                load_rvfi_records_log(records_log),
                require_all_kinds=(len(strands) >= min_sample),
            )
            print(mmu.format_behavior_summary(summary), flush=True)
            if summary.errors and status == 0:
                for err in summary.errors[:20]:
                    print(f"RVFI strand check failed: {err}")
                status = 1
        if plan.wfi_strands and records_log is not None:
            observations = read_rvfi_log(records_log)
            for strand in plan.wfi_strands:
                observation = observations.get(strand.digest, {})
                errors = wfi.verify(strand, observation)
                checks = observation.get("wfi", {})
                counts = ", ".join(f"{key}={value}" for key, value in checks.items())
                print(f"WFI {strand.name}: {'FAIL' if errors else 'PASS'} {counts}")
                for error_message in errors:
                    print(f"WFI {strand.name}: {error_message}")
                if errors:
                    status = status or 1
        traces, instructions, expected_traces, expected_instructions, error = (
            comparison_counts(monitors, plan, engine_log, arguments.tests)
        )
        if error:
            status = status or 1
        if status:
            print(
                f"TestRIG FAIL: expected at least {expected_traces} traces and "
                f"{expected_instructions} instructions; found {traces} traces and "
                f"{instructions} instructions compared; "
                f"{error or f'engine or harness exit status {status}'}; logs in {work_dir}",
                flush=True,
            )
        else:
            print(
                f"TestRIG PASS: compared {traces} traces and {instructions} instructions; "
                f"expected at least {expected_traces} traces and {expected_instructions} "
                f"instructions; logs in {work_dir}",
                flush=True,
            )
        return status
    finally:
        stop(engine, grace=0)
        if output_thread is not None:
            output_thread.join(timeout=2)
        for monitor in monitors:
            monitor.close()
        stop(frost, grace=1)
        stop(sail, grace=1)
        for image in images:
            image.unlink(missing_ok=True)
        (TESTS_DIR / ".rvfi_dii_build_ok").unlink(missing_ok=True)


def positive_count(value: str) -> int:
    """Accept an explicit positive count or instruction limit."""
    count = int(value)
    if count < 1:
        raise argparse.ArgumentTypeError(f"expected a positive count; found {value}")
    return count


def nonempty_path(value: str) -> str:
    """Require a supplied replay path to name a file or directory."""
    if not value:
        raise argparse.ArgumentTypeError(
            "expected a replay path; found an empty string"
        )
    return value


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--tests",
        type=positive_count,
        default=50,
        help="tests per template (default 50)",
    )
    parser.add_argument(
        "--ddr-capacity-log2-bytes",
        type=int,
        choices=range(30, 38),
        default=DEFAULT_DDR_CAPACITY_LOG2_BYTES,
        help="DDR capacity exponent shared by FROST and Sail (default 30 = 1 GiB)",
    )
    parser.add_argument(
        "--test-length",
        type=positive_count,
        default=200,
        help="maximum instructions per test (default 200)",
    )
    parser.add_argument(
        "--arch",
        help="architecture the templates target (default "
        f"{DEFAULT_ARCHITECTURE}, or {ATOMICS_ARCHITECTURE} with --atomics, "
        "--mmu or --cmo)",
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
    parser.add_argument(
        "--trace", type=nonempty_path, help="replay one saved trace instead"
    )
    parser.add_argument(
        "--trace-dir", type=nonempty_path, help="replay every .S trace in a directory"
    )
    parser.add_argument(
        "--wfi",
        action="store_true",
        help="replay directed WFI wait, wake and trap traces",
    )
    parser.add_argument(
        "--sscofpmf",
        action="store_true",
        help="replay deterministic Sscofpmf controls and implemented counters "
        "(verif/testrig/sscofpmf/controls.S); --trace overrides the trace path",
    )
    parser.add_argument(
        "--crypto",
        type=positive_count,
        help="replay this many scalar cryptography tests from verif/testrig/crypto.py",
    )
    parser.add_argument(
        "--zcb",
        type=positive_count,
        help=(
            "replay this many random Zcb/Zcmop/Zimop/Zihintntl tests from "
            "verif/testrig/compressed_mops.py"
        ),
    )
    parser.add_argument(
        "--fp-ext",
        type=positive_count,
        help="replay this many Zfhmin/Zfa tests from verif/testrig/fp_ext.py",
    )
    parser.add_argument(
        "--svinval",
        type=positive_count,
        help="replay this many random Svinval tests from verif/testrig/svinval.py",
    )
    parser.add_argument(
        "--mmu",
        type=positive_count,
        help="instead of the templates, replay this many random Sv39 MMU, "
        "ASID, SFENCE.VMA, and Sstvala tests from verif/testrig/mmu.py",
    )
    parser.add_argument(
        "--cmo",
        type=positive_count,
        help="instead of the templates, replay this many random Zicbom, "
        "Zicbop, Zicboz, Zawrs, and Sstvala tests from verif/testrig/cmo.py",
    )
    parser.add_argument(
        "--atomics",
        type=positive_count,
        help="instead of the templates, replay this many random A-extension "
        "tests from verif/testrig/atomics.py",
    )
    parser.add_argument(
        "--vector",
        type=positive_count,
        help="replay this many random vector-instruction tests from "
        "verif/testrig/vector.py, on a core built with the vector unit "
        "(sets --vlen to 128 when it is not given)",
    )
    parser.add_argument(
        "--vector-length",
        type=positive_count,
        default=20,
        help="random vector operation groups per --vector test (default 20)",
    )
    parser.add_argument(
        "--vector-source-widths",
        action="store_true",
        help="add the directed integer, FP and memory source-width traces to --vector",
    )
    parser.add_argument(
        "--vector-directed",
        action="store_true",
        help="add directed vector state, scalar-result, fractional LMUL, FP, "
        "cached DDR and integer comparison traces",
    )
    parser.add_argument(
        "--vlen",
        type=int,
        choices=vector.VECTOR_LENGTHS,
        help="build FROST with the vector unit at this vector length and give "
        "Sail the same (needed to replay vector traces with --trace or "
        "--trace-dir)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        help=(
            "seed for --atomics, --crypto, --zcb, --fp-ext, --mmu, --cmo, --svinval "
            "or --vector (default: random, printed)"
        ),
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
    arguments = parser.parse_args(argv)
    if arguments.vector_source_widths and arguments.vector is None:
        parser.error("--vector-source-widths requires --vector")
    if arguments.vector_directed and arguments.vector is None:
        parser.error("--vector-directed requires --vector")
    if arguments.vector and arguments.vlen is None:
        arguments.vlen = DEFAULT_VECTOR_LENGTH
    active_modes = sum(
        bool(mode)
        for mode in (
            arguments.trace,
            arguments.trace_dir,
            arguments.wfi,
            arguments.sscofpmf,
            arguments.atomics,
            arguments.crypto,
            arguments.zcb,
            arguments.fp_ext,
            arguments.svinval,
            arguments.mmu,
            arguments.cmo,
            arguments.vector,
        )
    )
    if active_modes > 1 and not (
        active_modes == 2 and arguments.sscofpmf and arguments.trace
    ):
        parser.error(
            "--trace, --trace-dir, --wfi, --sscofpmf, --atomics, --crypto, --zcb, "
            "--fp-ext, --svinval, --mmu, --cmo and --vector are mutually exclusive "
            "(except --sscofpmf --trace)"
        )
    return arguments


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

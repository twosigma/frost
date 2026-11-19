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

"""Build and run the checked FROST models for generated vector programs."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGE_FILES = ("sw.mem", "sw64.mem", "sw_ddr.mem")
# The cocotb program loop counts from the edge that releases the 20-edge reset.
# The native harness counts from its first edge, including the preceding 19.
RESET_PREFIX = 19
NATIVE_INPUTS = (
    "sim/native/Makefile",
    "sim/native/frost_native.vlt",
    "sim/native/main.cpp",
    "sim/sim_assertions.cpp",
)


def file_sha256(path: Path) -> str:
    """Hash a file without loading an entire simulator into memory."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def native_source_identity(env: dict[str, str]) -> dict[str, object]:
    """Fingerprint working sources, including uncommitted file lists and headers."""
    hw = ROOT / "hw"
    files = {}

    def visit(directory: Path) -> None:
        for path in directory.iterdir():
            # The Makefile puts generated C++ and executables in this directory.
            if path == hw / "sim/native/sim_build":
                continue
            if path.is_dir():
                visit(path)
            else:
                files[path.relative_to(hw).as_posix()] = file_sha256(path)

    visit(hw)
    version = subprocess.check_output(["verilator", "--version"], env=env, text=True)
    return {
        "hw_tree_sha256": hashlib.sha256(
            json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
        "native_inputs_sha256": {name: files[name] for name in NATIVE_INPUTS},
        "verilator_version": version.strip(),
    }


@dataclass
class VectorTestResult:
    """Verdict and available evidence for one generated test."""

    name: str
    passed: bool
    message: str = ""
    cycles: int | None = None
    wall_seconds: float | None = None
    assertions_armed: bool | None = None
    image_sha256: str | None = None


def image_hash(directory: Path) -> str:
    """Hash the three memory files in load order with unambiguous boundaries."""
    digest = hashlib.sha256()
    for name in IMAGE_FILES:
        data = (directory / name).read_bytes()
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


class VectorSimulator:
    """One model shared by processes with independent program images and logs."""

    def __init__(
        self, backend: str, vlen: int, ddr_bytes: int, max_cycles: int
    ) -> None:
        """Use the system bench's DDR draw and select the test's geometry."""
        from test_run_cocotb import CocotbRunner

        self.backend = backend
        self.vlen = vlen
        self.max_cycles = max_cycles
        runner = CocotbRunner("cocotb_tests.test_real_program", "frost", None)
        self.env = runner.setup_environment()
        self.env.setdefault("FROST_NIC_MAC_CLOCKS", "0")
        if self.env.get("COCOTB_LOG_LEVEL", "").upper() in {
            "WARNING",
            "ERROR",
            "CRITICAL",
        }:
            self.env["COCOTB_LOG_LEVEL"] = (
                "INFO"  # Reset and cycle evidence are INFO messages.
            )
        self.env.update(
            ROOT=str(ROOT),
            TOPLEVEL="frost",
            SIM="verilator",
            DDR_MODEL_BYTES=str(ddr_bytes),
            COCOTB_TEST_MODULES="cocotb_tests.test_real_program",
            COCOTB_RESULTS_FILE="results.xml",
            COCOTB_NUM_RUNS="1",
            COCOTB_MAX_CYCLES=str(max_cycles),
        )
        args = self.env.get("FROST_VERILATOR_EXTRA_ARGS", "").split()
        if backend == "native":
            if any(not arg.startswith("-G") for arg in args):
                raise ValueError(
                    "native vector builds accept only -G parameter overrides"
                )
            if self.env.get("FROST_RANDOM_START") == "1" or self.env.get(
                "FROST_CPU_PERIOD_PS"
            ):
                raise ValueError(
                    "random startup and asynchronous clocks require the cocotb backend"
                )
        # Accept the matching -G options in callers' commands. An override of
        # any of these would invalidate the image size check or its geometry.
        for key, value in (
            ("VECTOR", 1),
            ("VLEN", vlen),
            ("DDR_MODEL_BYTES", ddr_bytes),
        ):
            prefix = f"-G{key}="
            if any(
                arg.startswith(prefix) and arg != f"{prefix}{value}" for arg in args
            ):
                raise ValueError(f"conflicting {key} in FROST_VERILATOR_EXTRA_ARGS")
            args = [arg for arg in args if not arg.startswith(prefix)]
        args.extend(("-GVECTOR=1", f"-GVLEN={vlen}"))
        self.env["FROST_VERILATOR_EXTRA_ARGS"] = " ".join(args)
        self.model_settings = {
            key: self.env.get(key, default)
            for key, default in (
                ("SIM_MEM_SIZE_BYTES", "262144"),
                ("ENABLE_CACHED_TIER", "1"),
                ("DDR_MODEL_BYTES", str(ddr_bytes)),
                ("DDR_MODEL_LATENCY", "80"),
                ("SIM_FAST_MAINT", "1"),
                ("MEMORY_LINK_STAGES", "0"),
                (
                    "MISALIGNED_HW",
                    "0" if self.env.get("ENABLE_CACHED_TIER") == "0" else "1",
                ),
                ("FROST_VERILATOR_EXTRA_ARGS", ""),
            )
        }
        self.binary = Path()
        self._native_manifest: dict[str, object] | None = None

    def build(self, directory: Path, threads: int = 1) -> None:
        """Build one simulator, enabling RTL assertions at compile time."""
        directory = directory.resolve()
        directory.mkdir(parents=True, exist_ok=True)
        if self.backend == "native":
            self._native_manifest = None
            sources = native_source_identity(self.env)
            # Make dependencies use timestamps. Keep objects from distinct source
            # trees and tool versions apart even when a checkout preserves mtimes.
            build_key = hashlib.sha256(
                json.dumps([sources, self.model_settings], sort_keys=True).encode()
            ).hexdigest()
            build_dir = directory / build_key
            command = [
                "make",
                "-C",
                str(ROOT / "hw/sim/native"),
                "build",
                f"SIM_BUILD={build_dir}",
                f"THREADS={threads}",
                "ASSERTIONS=1",
                "PORTABLE=1",
                "STATIC_RUNTIME=1",
                "SAVABLE=0",
            ]
            self.binary = (
                build_dir / f"model_t{threads}_a1_s0_x86_64_static/frost-native"
            )
        else:
            self.env["SIM_BUILD"] = str(directory / "sim_build")
            self.binary = directory / "sim_build/Vtop"
            command = ["make", "-C", str(directory), "-f", str(ROOT / "tests/Makefile")]
            self._make([*command, "clean"], directory / "clean.log")
            command.append(str(self.binary))
        self._make(command, directory / "build.log")
        if self.backend == "native":
            if native_source_identity(self.env) != sources:
                raise RuntimeError("native simulator sources changed during the build")
            self._native_manifest = {
                "settings": self.model_settings,
                "sources": sources,
                "sha256": file_sha256(self.binary),
            }

    def _make(self, command: list[str], log: Path) -> None:
        from test_run_cocotb import run_in_process_group

        result = run_in_process_group(command, env=self.env, timeout=1800)
        log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(
                f"simulator build failed: {log}\n{log.read_text()[-2000:]}"
            )

    def export_native(self, path: Path) -> None:
        """Publish the executable with the identity recorded when it was built."""
        if self._native_manifest is None:
            raise ValueError("build or verify a native simulator before exporting it")
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.binary, path)
        if file_sha256(path) != self._native_manifest["sha256"]:
            raise ValueError("native simulator checksum changed since the build")
        Path(f"{path}.json").write_text(
            json.dumps(self._native_manifest, indent=2) + "\n"
        )

    def use_native(self, path: Path) -> None:
        """Check the downloaded binary against the current checkout and simulator."""
        if not os.access(path, os.X_OK):
            raise ValueError(f"{path}: prebuilt simulator must be executable")
        manifest = json.loads(Path(f"{path}.json").read_text())
        if manifest.get("settings") != self.model_settings or manifest.get(
            "sha256"
        ) != file_sha256(path):
            raise ValueError(
                f"{path}: prebuilt simulator checksum or model settings differ"
            )
        if manifest.get("sources") != native_source_identity(self.env):
            raise ValueError(
                f"{path}: prebuilt simulator sources or Verilator version differ"
            )
        self.binary = path.resolve()
        self._native_manifest = manifest

    def run(self, directory: Path) -> VectorTestResult:
        """Run a fresh process and require a guest pass and armed assertions."""
        from test_run_cocotb import coverage_file, run_in_process_group

        directory = directory.resolve()
        result = VectorTestResult(
            directory.name, False, image_sha256=image_hash(directory)
        )
        log = directory / f"{self.backend}.log"
        summary = directory / "native-summary.json"
        env = self.env.copy()
        if self.backend == "native":
            summary.unlink(missing_ok=True)
            command = [
                str(self.binary),
                "--mem-dir",
                str(directory),
                "--summary-json",
                str(summary),
                "--max-cycles",
                str(self.max_cycles + RESET_PREFIX),
            ]
        else:
            (directory / "results.xml").unlink(missing_ok=True)
            if env.get("FROST_COVERAGE") == "1":
                env["FROST_COVERAGE_FILE"] = str(
                    coverage_file(f"riscv_vector_tests_v{self.vlen}_{directory.name}")
                )
            command = [
                "make",
                "-C",
                str(directory),
                "-f",
                str(ROOT / "tests/Makefile"),
                "results.xml",
            ]
        start = time.monotonic()
        with log.open("wb") as stream:
            try:
                if self.backend == "native":
                    # The native executable has no child processes. Keep it
                    # in the shard's group and save its output as it runs.
                    sim = subprocess.run(
                        command,
                        env=env,
                        stdout=stream,
                        stderr=subprocess.STDOUT,
                        text=True,
                        timeout=7200,
                    )
                else:
                    sim = run_in_process_group(command, env=env, timeout=7200)
                    stream.write((sim.stdout + sim.stderr).encode())
            except subprocess.TimeoutExpired as exc:
                result.message = "simulation timed out"
                for value in (exc.stdout, exc.stderr, result.message):
                    if value:
                        stream.write(
                            value if isinstance(value, bytes) else value.encode()
                        )
                return result
            finally:
                result.wall_seconds = time.monotonic() - start
        output = log.read_text(errors="replace")
        if self.backend == "native":
            if summary.is_file():
                info = json.loads(summary.read_text())
                result.assertions_armed = (
                    info["assertions_compiled"] is True
                    and info["assertions_armed"] is True
                )
                result.cycles = max(0, info["cycles"] - RESET_PREFIX)
                result.passed = info["passed"] is True and info["failed"] is False
        else:
            result.assertions_armed = (
                "Simulation assertions armed after reset" in output
            )
            count = re.search(r"Run 1 completed after (\d+) cycles", output)
            if count:
                result.cycles = int(count[1])
            result.passed = "Run 1 PASSED: Program printed success marker" in output
        result.passed = bool(
            result.passed
            and sim.returncode == 0
            and result.assertions_armed
            and result.cycles is not None
            and "<<PASS>>" in output
            and "<<FAIL>>" not in output
        )
        if not result.passed:
            detail = re.search(r"(?m)^.*(?:%Error|Assertion failed).*", output)
            reason = f"simulator exited {sim.returncode}, assertions armed={result.assertions_armed}"
            if detail:
                reason = detail[0].strip()
            elif "<<FAIL>>" in output:
                reason = "guest printed <<FAIL>>"
            elif (
                self.backend == "native"
                and result.cycles == self.max_cycles
                and "not reached within" in output
            ):
                reason = f"guest did not print a verdict within the {self.max_cycles}-cycle limit"
            result.message = f"{reason} ({log})"
        return result

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

"""Unified runner for cocotb simulations - works with pytest and standalone."""

import os
import random
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from collections.abc import Mapping

import pytest

# Simulators to test in CI (excluding questa which requires license)
CI_SIMULATORS = ["icarus", "verilator"]


# =============================================================================
# Test Configuration Registry
# =============================================================================


@dataclass(frozen=True)
class CocotbRunConfig:
    """Configuration for a cocotb test run."""

    python_test_module: str
    hdl_toplevel_module: str
    app_name: str | None = None  # Application name (compiled on demand)
    description: str = ""


# CPU testbench tests (multiple modules combined)
CPU_TEST_MODULES = ",".join(
    [
        "cocotb_tests.test_cpu",
        "cocotb_tests.test_directed_atomics",
        "cocotb_tests.test_directed_traps",
        "cocotb_tests.test_compressed",
        "cocotb_tests.test_directed_multicycle",
    ]
)

# Registry of all available tests - single source of truth
# Maps test name to its configuration
TEST_REGISTRY: dict[str, CocotbRunConfig] = {
    "cpu": CocotbRunConfig(
        python_test_module=CPU_TEST_MODULES,
        hdl_toplevel_module="cpu_tb",
        description="CPU random regression and directed tests",
    ),
    # Real program tests - all use same module/toplevel, differ only in app
    "branch_pred_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="branch_pred_test",
        description="Branch prediction test",
    ),
    "c_ext_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="c_ext_test",
        description="C extension test",
    ),
    "cf_ext_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="cf_ext_test",
        description="Compressed floating-point (C.F) test",
    ),
    "call_stress": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="call_stress",
        description="Call stress test",
    ),
    "coremark": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="coremark",
        description="Coremark benchmark",
    ),
    "csr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="csr_test",
        description="CSR test",
    ),
    "freertos_demo": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="freertos_demo",
        description="FreeRTOS demo",
    ),
    "fpu_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fpu_test",
        description="FPU compliance test",
    ),
    "fpu_assembly_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fpu_assembly_test",
        description="FPU assembly hazard tests",
    ),
    "hello_world": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="hello_world",
        description="Hello World program",
    ),
    "isa_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="isa_test",
        description="ISA compliance test suite",
    ),
    "memory_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="memory_test",
        description="Memory allocator test suite",
    ),
    "packet_parser": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="packet_parser",
        description="Packet parser test",
    ),
    "print_clock_speed": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="print_clock_speed",
        description="Print clock speed test",
    ),
    "spanning_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="spanning_test",
        description="Spanning instruction test",
    ),
    "strings_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="strings_test",
        description="String library test suite",
    ),
    "ras_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ras_test",
        description="Return Address Stack (RAS) comprehensive test suite",
    ),
    "ras_stress_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ras_stress_test",
        description="RAS stress test (calls, branches, and function pointers)",
    ),
    "uart_echo": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="uart_echo",
        description="UART RX echo demo (driven via cocotb UART input)",
    ),
    # Tomasulo unit tests
    "reorder_buffer": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.reorder_buffer.test_reorder_buffer",
        hdl_toplevel_module="reorder_buffer",
        description="Reorder Buffer unit tests (allocation, commit, flush, serialization)",
    ),
    "register_alias_table": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.register_alias_table.test_register_alias_table",
        hdl_toplevel_module="register_alias_table",
        description="Register Alias Table unit tests (rename, lookup, checkpoint, flush)",
    ),
    "rob_rat_wrapper": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.rob_rat_wrapper.test_rob_rat_wrapper",
        hdl_toplevel_module="rob_rat_wrapper",
        description="ROB-RAT integration block tests (commit bus, checkpoint lifecycle, misprediction recovery)",
    ),
}

# List of real program test names (excludes 'cpu' which uses different toplevel)
REAL_PROGRAM_TESTS = [name for name in TEST_REGISTRY if name != "cpu"]


# =============================================================================
# CocotbRunner Class
# =============================================================================


class CocotbRunner:
    """Run Cocotb (Coroutine-based Cosimulation TestBench) simulations.

    Manages simulator setup, environment configuration, and test execution
    for FROST CPU verification using Cocotb Python testbench.
    """

    def __init__(
        self,
        python_test_module: str,
        hdl_toplevel_module: str,
        app_name: str | None = None,
    ) -> None:
        """Initialize Cocotb test runner.

        Args:
            python_test_module: Python module containing Cocotb tests (e.g., "cocotb_tests.test_cpu")
            hdl_toplevel_module: Top-level HDL module name (e.g., "cpu_tb")
            app_name: Optional application name to compile and load (e.g., "hello_world")
        """
        self.python_test_module = python_test_module
        self.hdl_toplevel_module = hdl_toplevel_module
        self.app_name = app_name
        self.test_directory = Path(__file__).parent.resolve()
        self.repository_root_directory = self.test_directory.parent

    @classmethod
    def from_config(cls, config: CocotbRunConfig) -> "CocotbRunner":
        """Create a CocotbRunner from a CocotbRunConfig."""
        return cls(
            python_test_module=config.python_test_module,
            hdl_toplevel_module=config.hdl_toplevel_module,
            app_name=config.app_name,
        )

    def _compile_app(self) -> bool:
        """Compile the application if app_name is set.

        Returns:
            True if compilation succeeded or no app to compile, False on failure.
        """
        if not self.app_name:
            return True

        # Import compile_app from sw/apps directory
        apps_dir = self.repository_root_directory / "sw" / "apps"
        sys.path.insert(0, str(apps_dir))
        try:
            from compile_app import compile_app

            return compile_app(self.app_name, verbose=True)
        finally:
            sys.path.pop(0)

    def _get_program_memory_file(self) -> str | None:
        """Get the path to the program memory file for the current app."""
        if not self.app_name:
            return None
        return f"../sw/apps/{self.app_name}/sw.mem"

    def setup_environment(self) -> dict[str, str]:
        """Set up environment variables for HDL simulation.

        Returns:
            Dictionary of environment variables for subprocess
        """
        environment_variables = os.environ.copy()

        # Select HDL simulator (icarus or verilator)
        simulator_name = environment_variables.get("SIM", "icarus")
        if simulator_name == "":
            simulator_name = "icarus"

        # GUI mode flag (0 = batch, 1 = interactive waveform viewer)
        gui_mode = environment_variables.get("GUI", "0")
        if gui_mode == "":
            gui_mode = "0"

        environment_variables["SIM"] = simulator_name
        environment_variables["GUI"] = gui_mode
        environment_variables["ROOT"] = str(self.repository_root_directory)

        # Add verification infrastructure to Python path so cocotb_tests modules are importable
        verif_path = str(self.repository_root_directory / "verif")
        current_pythonpath = environment_variables.get("PYTHONPATH", "")
        if verif_path not in current_pythonpath:
            current_pythonpath = verif_path + ":" + current_pythonpath
        environment_variables["PYTHONPATH"] = current_pythonpath

        return environment_variables

    def check_for_failures(
        self, simulation_result: subprocess.CompletedProcess[str]
    ) -> bool:
        """Check if Cocotb reported any test failures.

        Args:
            simulation_result: Completed subprocess from simulation run

        Returns:
            True if test failures detected, False otherwise
        """
        # First check return code - non-zero indicates failure
        if simulation_result.returncode != 0:
            return True

        # If output wasn't captured (standalone mode), trust the return code
        has_captured_output = (
            simulation_result.stdout is not None
            and simulation_result.stderr is not None
        )
        if not has_captured_output:
            return False

        # Check for Cocotb failure indicators in output
        failure_indicator_strings = [
            "FAILED",
            "ERROR",
            "Test Failed:",
            "AssertionError",
            "** TEST FAILED **",
            "FAIL:",
            "failed:",
        ]

        combined_output = (simulation_result.stdout or "") + (
            simulation_result.stderr or ""
        )
        for failure_indicator in failure_indicator_strings:
            if failure_indicator in combined_output:
                # Verify it's an actual test failure, not just in a file path
                output_lines = combined_output.splitlines()
                for line in output_lines:
                    if failure_indicator in line and (
                        "test" in line.lower()
                        or "fail" in line.lower()
                        or "error" in line.lower()
                    ):
                        return True

        # Check for cocotb summary line showing failures
        if "passed=0" in combined_output or "failed=" in combined_output:
            # Look for failed=N where N > 0
            match = re.search(r"failed=(\d+)", combined_output)
            if match and int(match.group(1)) > 0:
                return True

        return False

    def _get_sim_build_dir(self, env: Mapping[str, str] | None = None) -> Path:
        """Return sim_build directory, honoring SIM_BUILD if set."""
        env_map = os.environ if env is None else env
        sim_build = env_map.get("SIM_BUILD", "")
        if sim_build:
            return Path(sim_build).expanduser().resolve()
        return self.test_directory / "sim_build"

    def _verilator_needs_rebuild(self, sim_build_dir: Path) -> bool:
        """Check if Verilator needs a full rebuild due to toplevel change.

        Returns:
            True if rebuild needed (toplevel changed), False for incremental build.
        """
        toplevel_marker = sim_build_dir / ".last_toplevel"
        verilator_binary = sim_build_dir / "Vtop"

        # If sim_build exists with a binary but no marker, force rebuild
        # (this handles stale state from before marker tracking was added)
        if verilator_binary.exists() and not toplevel_marker.exists():
            return True

        if not toplevel_marker.exists():
            return False  # No previous build, let make handle it

        try:
            last_toplevel = toplevel_marker.read_text().strip()
            return last_toplevel != self.hdl_toplevel_module
        except OSError:
            return False

    def _update_verilator_toplevel_marker(self, sim_build_dir: Path) -> None:
        """Record the current toplevel for future incremental build checks."""
        sim_build_dir.mkdir(exist_ok=True)
        toplevel_marker = sim_build_dir / ".last_toplevel"
        toplevel_marker.write_text(self.hdl_toplevel_module)

    def run_simulation(
        self, check: bool = True, capture_output: bool = True
    ) -> subprocess.CompletedProcess[str]:
        """Run the cocotb simulation."""
        # Compile the application first if needed
        if self.app_name and not self._compile_app():
            raise RuntimeError(f"Failed to compile application: {self.app_name}")

        original_dir = os.getcwd()
        os.chdir(self.test_directory)
        env = self.setup_environment()
        sim_build_dir = self._get_sim_build_dir(env)
        env["SIM_BUILD"] = str(sim_build_dir)

        try:
            # For Verilator, skip clean to enable incremental builds when RTL unchanged.
            # However, if the toplevel module changed, we must rebuild.
            # For other simulators, always clean to ensure fresh state.
            simulator = env.get("SIM", "icarus")
            needs_clean = simulator != "verilator" or self._verilator_needs_rebuild(
                sim_build_dir
            )

            if needs_clean:
                # Don't fail on clean errors (e.g., permission denied on root-owned files)
                subprocess.run(["make", "clean"], check=False)

            # Set up program memory symlink if needed
            program_memory_file = self._get_program_memory_file()
            if program_memory_file:
                sw_mem_path = Path("sw.mem")
                if sw_mem_path.exists() or sw_mem_path.is_symlink():
                    sw_mem_path.unlink()
                sw_mem_path.symlink_to(program_memory_file)

            # Run the simulation
            # Explicitly export PYTHONPATH so it's available to child processes (simulator)
            pythonpath = env.get("PYTHONPATH", "")
            cmd = f"export PYTHONPATH='{pythonpath}' && make COCOTB_TEST_MODULES='{self.python_test_module}' TOPLEVEL={self.hdl_toplevel_module}"

            if capture_output:
                result = subprocess.run(
                    ["bash", "-c", cmd],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=check,
                )
            else:
                # Let output stream directly to console
                result = subprocess.run(
                    ["bash", "-c", cmd],
                    env=env,
                    check=check,
                    text=True,
                    stdout=None,  # Don't capture, let it stream to terminal
                    stderr=None,  # Don't capture, let it stream to terminal
                )

            # For Verilator, update the toplevel marker only after successful build.
            # This ensures we don't mark a toplevel as built if compilation failed.
            if simulator == "verilator" and result.returncode == 0:
                self._update_verilator_toplevel_marker(sim_build_dir)

            return result

        finally:
            # Clean up
            if self.app_name:
                sw_mem_path = Path("sw.mem")
                if sw_mem_path.exists() or sw_mem_path.is_symlink():
                    sw_mem_path.unlink()
            os.chdir(original_dir)


# =============================================================================
# Helper function for running tests
# =============================================================================


def run_test_with_simulator(
    test_name: str, simulator: str, capsys: Any | None = None
) -> None:
    """Run a test with the specified simulator.

    Args:
        test_name: Name of the test from TEST_REGISTRY
        simulator: Simulator to use ("icarus", "verilator", "questa")
        capsys: Optional pytest capsys fixture for output control

    Raises:
        pytest.fail: If the test fails
        KeyError: If test_name is not in TEST_REGISTRY
    """
    os.environ["SIM"] = simulator
    config = TEST_REGISTRY[test_name]
    runner = CocotbRunner.from_config(config)

    if capsys is not None:
        with capsys.disabled():
            print(f"\nRunning {test_name} with {simulator} simulator...")
            result = runner.run_simulation(check=False, capture_output=False)
    else:
        print(f"\nRunning {test_name} with {simulator} simulator...")
        result = runner.run_simulation(check=False, capture_output=False)

    if runner.check_for_failures(result):
        pytest.fail(f"Cocotb test failed with {simulator}. Check output for details.")


# =============================================================================
# Pytest Test Classes
# =============================================================================


@pytest.mark.cocotb
class TestCPU:
    """Test cases for RISC-V CPU core (random regression + directed tests)."""

    @pytest.mark.slow
    @pytest.mark.parametrize("simulator", CI_SIMULATORS)
    def test_cpu(self, simulator: str, capsys: Any) -> None:
        """Run the CPU test through cocotb with different simulators."""
        run_test_with_simulator("cpu", simulator, capsys)


@pytest.mark.cocotb
class TestRealPrograms:
    """Test cases for running real programs on the CPU.

    All real program tests use the same test module and toplevel,
    differing only in which program memory file is loaded.
    """

    @pytest.mark.slow
    @pytest.mark.parametrize("simulator", CI_SIMULATORS)
    @pytest.mark.parametrize("test_name", REAL_PROGRAM_TESTS)
    def test_real_program(self, test_name: str, simulator: str, capsys: Any) -> None:
        """Run a real program test through cocotb.

        This parametrized test replaces 14 nearly-identical test methods.
        Pytest will generate test IDs like:
            test_real_program[hello_world-icarus]
            test_real_program[coremark-verilator]
        """
        run_test_with_simulator(test_name, simulator, capsys)


# =============================================================================
# Seed Sweep Support
# =============================================================================


def _run_single_seed(
    test_name: str,
    simulator: str,
    seed: int,
    testcase: str | None,
    temp_dir: str,
) -> tuple[int, bool, str]:
    """Run a single simulation with the given seed.

    This function is designed to be called from a separate process.

    Args:
        test_name: Name of the test from TEST_REGISTRY
        simulator: Simulator to use
        seed: Random seed for this run
        testcase: Optional specific test case to run
        temp_dir: Temporary directory for build artifacts

    Returns:
        Tuple of (seed, passed, error_message)
    """
    # Set up environment for this specific run
    os.environ["SIM"] = simulator
    os.environ["GUI"] = "0"
    os.environ["COCOTB_RANDOM_SEED"] = str(seed)
    os.environ["SIM_BUILD"] = os.path.join(temp_dir, f"sim_build_{seed}")

    if testcase:
        os.environ["COCOTB_TEST_FILTER"] = f"{testcase}$"

    config = TEST_REGISTRY[test_name]
    runner = CocotbRunner.from_config(config)

    try:
        result = runner.run_simulation(check=False, capture_output=True)
        passed = not runner.check_for_failures(result)
        error_msg = ""
        if not passed:
            # Extract relevant error info from output
            combined = (result.stdout or "") + (result.stderr or "")
            # Get last 20 lines for context
            lines = combined.strip().split("\n")
            error_msg = "\n".join(lines[-20:]) if lines else "Unknown error"
        return (seed, passed, error_msg)
    except Exception as e:
        return (seed, False, str(e))


def run_seed_sweep(
    test_name: str,
    simulator: str,
    num_seeds: int,
    testcase: str | None = None,
    max_workers: int | None = None,
) -> dict[str, Any]:
    """Run multiple simulations with different random seeds in parallel.

    Args:
        test_name: Name of the test from TEST_REGISTRY
        simulator: Simulator to use
        num_seeds: Number of different seeds to test
        testcase: Optional specific test case to run
        max_workers: Maximum number of parallel workers (default: num_seeds)

    Returns:
        Dictionary with results summary
    """
    # Generate random seeds
    seeds = [random.randint(0, 2**31 - 1) for _ in range(num_seeds)]

    print(f"\n{'='*60}")
    print(f"Seed Sweep: Running {num_seeds} simulations in parallel")
    print(f"Test: {test_name}, Simulator: {simulator}")
    print(f"Seeds: {seeds}")
    print(f"{'='*60}\n")

    results: dict[int, tuple[bool, str]] = {}
    workers = max_workers if max_workers else min(num_seeds, os.cpu_count() or 4)

    with tempfile.TemporaryDirectory(prefix="frost_seed_sweep_") as temp_dir:
        with ProcessPoolExecutor(max_workers=workers) as executor:
            # Submit all jobs
            futures = {
                executor.submit(
                    _run_single_seed, test_name, simulator, seed, testcase, temp_dir
                ): seed
                for seed in seeds
            }

            # Collect results as they complete
            for future in as_completed(futures):
                seed = futures[future]
                try:
                    ret_seed, passed, error_msg = future.result()
                    results[ret_seed] = (passed, error_msg)
                    status = "PASSED" if passed else "FAILED"
                    print(f"  Seed {ret_seed}: {status}")
                except Exception as e:
                    results[seed] = (False, str(e))
                    print(f"  Seed {seed}: FAILED (exception: {e})")

    # Generate report
    passed_seeds = [s for s, (p, _) in results.items() if p]
    failed_seeds = [s for s, (p, _) in results.items() if not p]

    print(f"\n{'='*60}")
    print("SEED SWEEP REPORT")
    print(f"{'='*60}")
    print(f"Total runs: {num_seeds}")
    print(f"Passed: {len(passed_seeds)}")
    print(f"Failed: {len(failed_seeds)}")
    print()

    if passed_seeds:
        print(f"Passing seeds: {sorted(passed_seeds)}")
    if failed_seeds:
        print(f"Failing seeds: {sorted(failed_seeds)}")
        print("\nTo reproduce a failure, run:")
        for seed in sorted(failed_seeds):
            print(
                f"  ./test_run_cocotb.py {test_name} --sim={simulator} --random-seed={seed}"
            )

    print(f"{'='*60}\n")

    return {
        "total": num_seeds,
        "passed": len(passed_seeds),
        "failed": len(failed_seeds),
        "passed_seeds": passed_seeds,
        "failed_seeds": failed_seeds,
        "details": results,
    }


# =============================================================================
# Command-line Interface
# =============================================================================


def main() -> None:
    """Run cocotb simulation from command line."""
    import argparse

    # Build choices list from registry
    test_choices = sorted(TEST_REGISTRY.keys())

    parser = argparse.ArgumentParser(
        description="Run cocotb simulations for Frost RISC-V CPU",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s cpu                    # Run CPU test with default simulator (icarus)
  %(prog)s hello_world --sim=verilator  # Run Hello World with Verilator
  %(prog)s isa_test --sim=icarus  # Run ISA compliance tests
  %(prog)s coremark --sim=questa --gui  # Run Coremark with Questa in GUI mode
  %(prog)s cpu --sim=verilator --seed-sweep 10  # Run 10 seeds in parallel, report results
  %(prog)s --list-tests           # Show available tests from TEST_REGISTRY and exit

Note: GUI mode only works with questa simulator.
      Seed sweep runs simulations in parallel and reports pass/fail for each seed.

Available tests:
"""
        + "\n".join(
            f"  {name:20} - {cfg.description}"
            for name, cfg in sorted(TEST_REGISTRY.items())
        ),
    )
    parser.add_argument(
        "test",
        nargs="?",
        choices=test_choices,
        help="Which test to run",
    )
    parser.add_argument(
        "--list-tests",
        action="store_true",
        help="List available tests and exit",
    )
    parser.add_argument(
        "--sim",
        default="icarus",
        choices=["icarus", "verilator", "questa"],
        help="Simulator to use (default: icarus)",
    )
    parser.add_argument(
        "--gui", action="store_true", help="Enable GUI mode (questa only)"
    )
    parser.add_argument(
        "--testcase",
        default=None,
        help="Specific cocotb test function to run (sets COCOTB_TEST_FILTER env var)",
    )
    parser.add_argument(
        "--random-seed",
        default=None,
        help="Random seed for reproducibility (sets COCOTB_RANDOM_SEED env var)",
    )
    parser.add_argument(
        "--seed-sweep",
        type=int,
        default=None,
        metavar="N",
        help="Run N simulations with different random seeds in parallel and report results",
    )
    parser.add_argument(
        "--max-workers",
        type=int,
        default=None,
        metavar="W",
        help="Maximum parallel workers for seed sweep (default: min(N, cpu_count))",
    )

    args = parser.parse_args()

    if args.list_tests:
        print("Available cocotb tests (from TEST_REGISTRY):")
        for name, cfg in sorted(TEST_REGISTRY.items()):
            print(f"  {name:20} - {cfg.description}")
        sys.exit(0)

    if args.test is None:
        parser.error("the following arguments are required: test")

    # Handle seed sweep mode
    if args.seed_sweep:
        if args.seed_sweep < 1:
            print("Error: --seed-sweep requires a positive integer")
            sys.exit(1)
        if args.random_seed:
            print("Error: --seed-sweep and --random-seed are mutually exclusive")
            sys.exit(1)
        if args.gui:
            print("Error: --seed-sweep does not support GUI mode")
            sys.exit(1)

        results = run_seed_sweep(
            test_name=args.test,
            simulator=args.sim,
            num_seeds=args.seed_sweep,
            testcase=args.testcase,
            max_workers=args.max_workers,
        )

        if results["failed"] > 0:
            sys.exit(1)
        sys.exit(0)

    # Set environment based on args
    os.environ["SIM"] = args.sim
    os.environ["GUI"] = "1" if args.gui else "0"
    if args.testcase:
        # Anchor at end for exact match (COCOTB_TEST_FILTER uses regex).
        # We only anchor at end because cocotb may prefix with module path.
        os.environ["COCOTB_TEST_FILTER"] = f"{args.testcase}$"
    if args.random_seed:
        os.environ["COCOTB_RANDOM_SEED"] = args.random_seed

    # Get test configuration from registry
    config = TEST_REGISTRY[args.test]
    runner = CocotbRunner.from_config(config)

    # Run simulation
    result = runner.run_simulation(check=False, capture_output=False)

    if runner.check_for_failures(result):
        print("\nSimulation FAILED! Check output above for details.")
        sys.exit(1)
    else:
        print("\nSimulation completed successfully!")


if __name__ == "__main__":
    main()

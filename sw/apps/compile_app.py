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

"""Compile a FROST app for cocotb or Yosys.

FPGA flows compile independently through their board-specific paths.
"""

import os
import subprocess
import sys
from pathlib import Path

from software_registry import app_build_directory_name, coremark_pro_make_vars

# Simulation-only Make overrides.
APP_SIM_SETTINGS: dict[str, dict[str, str]] = {
    "coremark": {
        # Keep simulation short.
        "ITERATIONS": "1",
        # Avoid timing-calculation overflow.
        "FPGA_CPU_CLK_FREQ": "30000",
    },
}

# linux_boot may spend 30–60 minutes building its first toolchain/kernel/rootfs.
DEFAULT_CLEAN_TIMEOUT_SECONDS = 30
DEFAULT_BUILD_TIMEOUT_SECONDS = 120
APP_TIMEOUTS_SECONDS: dict[str, tuple[int, int]] = {
    "linux_boot": (300, 5400),
    # The first build compiles OpenSBI (cached under build/ afterwards).
    "opensbi_smoke": (60, 900),
}


def get_apps_directory() -> Path:
    """Return the sw/apps path."""
    return Path(__file__).parent


def _app_timeouts(app_name: str) -> tuple[int, int]:
    """Return the clean and build timeouts for an application."""
    return APP_TIMEOUTS_SECONDS.get(
        app_name,
        (DEFAULT_CLEAN_TIMEOUT_SECONDS, DEFAULT_BUILD_TIMEOUT_SECONDS),
    )


def _report_command_failure(
    app_name: str,
    action: str,
    result: subprocess.CompletedProcess[str],
) -> None:
    """Report a failed make action, including captured output when available."""
    print(
        f"Error: {action} failed for {app_name} (exit code {result.returncode})",
        file=sys.stderr,
    )
    for output in (result.stdout, result.stderr):
        if output:
            print(output.rstrip(), file=sys.stderr)


def compile_app(
    app_name: str,
    verbose: bool = False,
    mem_config: str = "bram",
    clean_first: bool = False,
) -> bool:
    """Compile an application for simulation.

    Args:
        app_name: Application name, such as ``hello_world``.
        verbose: Print compiler output.
        mem_config: ``bram`` (default) or ``ddr`` for a program behind the ROM stub.
        clean_first: Run ``make clean`` first. Cocotb and the CLI enable this.
            Direct incremental builds rely instead on the build-config stamp
            that common.mk keeps.

    Returns:
        Whether compilation succeeded.
    """
    apps_dir = get_apps_directory()
    app_dir_name = app_build_directory_name(app_name)
    app_dir = apps_dir / app_dir_name
    # When set (for example COCOTB_COREMARK_PRO_HW_ARGS="-v0 -i1"), build with
    # the official EEMBC datasets instead of the FASTEST inputs and pass the
    # given run arguments. Unset builds the fast verified simulation recipe.
    coremark_pro_hw_args = os.environ.get("COCOTB_COREMARK_PRO_HW_ARGS", "")
    if coremark_pro_hw_args:
        make_vars = coremark_pro_make_vars(
            app_name, hardware=True, hardware_mode="validation"
        )
        if make_vars:
            make_vars["COREMARK_PRO_RUN_ARGS"] = coremark_pro_hw_args
    else:
        make_vars = coremark_pro_make_vars(app_name, hardware=False)
    clean_timeout, build_timeout = _app_timeouts(app_name)

    if not app_dir.exists():
        print(f"Error: Application directory not found: {app_dir}", file=sys.stderr)
        return False

    makefile = app_dir / "Makefile"
    if not makefile.exists():
        print(f"Error: Makefile not found: {makefile}", file=sys.stderr)
        return False

    env = os.environ.copy()
    if "RISCV_PREFIX" not in env:
        env["RISCV_PREFIX"] = "riscv-none-elf-"

    if app_name in APP_SIM_SETTINGS:
        for key, value in APP_SIM_SETTINGS[app_name].items():
            env[key] = value
            if verbose:
                print(f"  Setting {key}={value} for simulation")

    action = "Build"
    action_timeout = build_timeout
    try:
        if verbose:
            print(f"Compiling {app_name}...")
            for key, value in make_vars.items():
                print(f"  Setting {key}={value}")

        # Clean when the caller asks (the cocotb and CLI paths always do) and
        # whenever this build differs from a plain one: app-specific simulation
        # settings, CoreMark-PRO variables, or a non-bram tier. Direct
        # incremental builds rely on common.mk's build-config stamp instead.
        if (
            clean_first
            or app_name in APP_SIM_SETTINGS
            or make_vars
            or mem_config != "bram"
        ):
            action = "Clean"
            action_timeout = clean_timeout
            clean_result = subprocess.run(
                ["make", "clean"],
                cwd=app_dir,
                env=env,
                capture_output=True,
                text=True,
                timeout=clean_timeout,
            )
            if clean_result.returncode != 0:
                _report_command_failure(app_name, action, clean_result)
                return False

        action = "Build"
        action_timeout = build_timeout
        make_command = ["make", f"MEM_CONFIG={mem_config}"]
        make_command.extend(f"{key}={value}" for key, value in make_vars.items())
        result = subprocess.run(
            make_command,
            cwd=app_dir,
            env=env,
            capture_output=not verbose,
            text=True,
            timeout=build_timeout,
        )

        if result.returncode != 0:
            _report_command_failure(app_name, action, result)
            return False

        # Both memory images must exist. The cocotb runner symlinks sw.mem and
        # sw_ddr.mem for every app; a missing sw_ddr.mem would leave a dangling
        # link and the simulation would run with zeroed DDR without complaint.
        # Every app's build emits both files (sw_ddr.mem is a single zero word
        # when the app has no DDR data).
        for mem_name in ("sw.mem", "sw_ddr.mem"):
            if not (app_dir / mem_name).exists():
                print(f"Error: {mem_name} not created for {app_name}", file=sys.stderr)
                return False

        if verbose:
            print(f"Successfully compiled {app_name}")

        return True

    except subprocess.TimeoutExpired:
        print(
            f"Error: {action} timed out for {app_name} after {action_timeout} seconds",
            file=sys.stderr,
        )
        return False
    except Exception as e:
        print(f"Error compiling {app_name}: {e}", file=sys.stderr)
        return False


def main(argv: list[str] | None = None) -> int:
    """Parse the command line and compile one application."""
    import argparse

    parser = argparse.ArgumentParser(description="Compile a FROST software application")
    parser.add_argument(
        "app_name",
        help="Name of the application to compile (e.g., hello_world)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Show compilation output",
    )
    parser.add_argument(
        "--mem-config",
        choices=("bram", "ddr"),
        default="bram",
        help="Memory tier: bram (low BRAM, default) or ddr (cached DDR region)",
    )
    args = parser.parse_args(argv)

    success = compile_app(
        args.app_name,
        verbose=args.verbose,
        mem_config=args.mem_config,
        clean_first=True,
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())

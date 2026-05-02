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

"""Compile a FROST software application.

This module provides a function to compile applications in sw/apps/.
Used by test_run_cocotb.py, test_run_yosys.py, load_software.py, and build.py
to ensure binaries are always up-to-date before simulation, synthesis, or FPGA loading.
"""

import os
import subprocess
import sys
from pathlib import Path

# App-specific build settings for simulation
# These override defaults when compiling for cocotb simulation
APP_SIM_SETTINGS: dict[str, dict[str, str]] = {
    "coremark": {
        # Use 1 iteration for simulation to complete quickly
        "ITERATIONS": "1",
        # Use low clock frequency so timing calculations don't overflow
        "FPGA_CPU_CLK_FREQ": "30000",
    },
}


def get_apps_directory() -> Path:
    """Get the path to the sw/apps directory."""
    return Path(__file__).parent


def compile_app(app_name: str, verbose: bool = False) -> bool:
    """Compile a software application for simulation.

    Args:
        app_name: Name of the application (e.g., "hello_world", "coremark")
        verbose: If True, print compilation output

    Returns:
        True if compilation succeeded, False otherwise

    Note:
        This function applies simulation-specific settings for certain apps.
        For example, coremark is compiled with ITERATIONS=1 for fast simulation.
    """
    apps_dir = get_apps_directory()
    app_dir = apps_dir / app_name

    if not app_dir.exists():
        print(f"Error: Application directory not found: {app_dir}", file=sys.stderr)
        return False

    makefile = app_dir / "Makefile"
    if not makefile.exists():
        print(f"Error: Makefile not found: {makefile}", file=sys.stderr)
        return False

    # Set up environment with RISC-V prefix if not already set
    env = os.environ.copy()
    if "RISCV_PREFIX" not in env:
        # Default to riscv-none-elf- (xPack bare-metal toolchain)
        # Users can override with RISCV_PREFIX environment variable
        env["RISCV_PREFIX"] = "riscv-none-elf-"

    # Apply app-specific simulation settings
    if app_name in APP_SIM_SETTINGS:
        for key, value in APP_SIM_SETTINGS[app_name].items():
            env[key] = value
            if verbose:
                print(f"  Setting {key}={value} for simulation")

    try:
        if verbose:
            print(f"Compiling {app_name}...")

        # Clean first if app has special settings to ensure recompilation
        if app_name in APP_SIM_SETTINGS:
            subprocess.run(
                ["make", "clean"],
                cwd=app_dir,
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )

        # Run make in the application directory
        result = subprocess.run(
            ["make"],
            cwd=app_dir,
            env=env,
            capture_output=not verbose,
            text=True,
            timeout=120,  # 2 minute timeout
        )

        if result.returncode != 0:
            if not verbose and result.stderr:
                print(f"Compilation failed for {app_name}:", file=sys.stderr)
                print(result.stderr, file=sys.stderr)
            return False

        # Verify the output file was created
        sw_mem = app_dir / "sw.mem"
        if not sw_mem.exists():
            print(f"Error: sw.mem not created for {app_name}", file=sys.stderr)
            return False

        if verbose:
            print(f"Successfully compiled {app_name}")

        return True

    except subprocess.TimeoutExpired:
        print(f"Error: Compilation timed out for {app_name}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error compiling {app_name}: {e}", file=sys.stderr)
        return False


def main() -> int:
    """Command-line interface for compiling applications."""
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
    args = parser.parse_args()

    success = compile_app(args.app_name, verbose=args.verbose)
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())

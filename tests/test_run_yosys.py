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

"""Unified runner for Yosys synthesis - works with pytest and standalone.

Tests synthesis across all Yosys-supported targets to verify RTL portability.
This ensures FROST can be synthesized for any FPGA vendor or ASIC flow.
"""

import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest


def _compile_hello_world(root_dir: Path) -> bool:
    """Compile hello_world application for synthesis.

    Args:
        root_dir: Path to the repository root directory

    Returns:
        True if compilation succeeded, False on failure.
    """
    # Import compile_app from sw/apps directory
    apps_dir = root_dir / "sw" / "apps"
    sys.path.insert(0, str(apps_dir))
    try:
        from compile_app import compile_app

        return compile_app("hello_world", verbose=True)
    finally:
        sys.path.pop(0)


# Synthesis targets for pytest runs
# Additional targets can be run manually: ./test_run_yosys.py --target <name>
SYNTHESIS_TARGETS = [
    ("generic", "synth", "Generic/ASIC (technology-independent)"),
    ("xilinx_7series", "synth_xilinx -family xc7", "Xilinx 7-series"),
    ("xilinx_ultrascale", "synth_xilinx -family xcu", "Xilinx UltraScale"),
    ("xilinx_ultrascale_plus", "synth_xilinx -family xcup", "Xilinx UltraScale+"),
]

# Design file lists available for synthesis
DESIGN_FILELISTS = {
    "frost": "hw/rtl/cpu_and_mem/cpu_and_mem.f",
    "tomasulo": "hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo.f",
}


class YosysRunner:
    """Run Yosys synthesis with proper environment setup."""

    def __init__(self, filelist_key: str = "frost") -> None:
        """Initialize runner with paths.

        Args:
            filelist_key: Key from DESIGN_FILELISTS dict (e.g., "frost", "tomasulo").
        """
        self.test_dir = Path(__file__).parent.resolve()
        self.root_dir = self.test_dir.parent
        self.filelist_key = filelist_key

        if filelist_key not in DESIGN_FILELISTS:
            raise ValueError(
                f"Unknown filelist key '{filelist_key}'. "
                f"Available: {list(DESIGN_FILELISTS.keys())}"
            )

        self.filelist = self.root_dir / DESIGN_FILELISTS[filelist_key]

        # Create symlink to sw.mem only for designs that need it (frost has BRAM init)
        if filelist_key == "frost":
            self.setup_sw_mem()

    def setup_sw_mem(self) -> None:
        """Compile hello_world and set up sw.mem symlink for synthesis."""
        # Compile hello_world to ensure sw.mem exists
        if not _compile_hello_world(self.root_dir):
            raise RuntimeError("Failed to compile hello_world for synthesis")

        sw_mem_target = self.root_dir / "sw" / "apps" / "hello_world" / "sw.mem"
        sw_mem_link = self.test_dir / "sw.mem"

        if sw_mem_link.exists() or sw_mem_link.is_symlink():
            sw_mem_link.unlink()
        sw_mem_link.symlink_to(sw_mem_target)

    def parse_filelist(self, filelist_path: Path) -> list[str]:
        """Parse a filelist file and return list of Verilog files."""
        files = []

        with open(filelist_path) as f:
            for line in f:
                line = line.strip()

                # Skip empty lines and comments
                if not line or line.startswith("#") or line.startswith("//"):
                    continue

                # Handle nested filelists with -f flag
                if line.startswith("-f "):
                    nested_filelist = line[3:].strip()
                    nested_filelist = nested_filelist.replace(
                        "$(ROOT)", str(self.root_dir)
                    )
                    nested_files = self.parse_filelist(Path(nested_filelist))
                    files.extend(nested_files)
                else:
                    # Replace $(ROOT) with actual root directory
                    file_path = line.replace("$(ROOT)", str(self.root_dir))
                    files.append(file_path)

        return files

    def run_synthesis(
        self, capture_output: bool = True, synth_command: str = "synth_xilinx"
    ) -> subprocess.CompletedProcess[str]:
        """Run Yosys synthesis on the design.

        Args:
            capture_output: If True, capture stdout/stderr. If False, stream to console.
            synth_command: Yosys synthesis command (e.g., "synth", "synth_xilinx",
                          "synth_intel_alm", "synth_ice40").
        """
        if not self.filelist.exists():
            raise FileNotFoundError(f"Filelist not found: {self.filelist}")

        # Parse the filelist
        verilog_files = self.parse_filelist(self.filelist)

        if not verilog_files:
            raise ValueError("No Verilog files found in filelist")

        # Enable Xilinx primitive instantiations only for synth_xilinx targets.
        # Generic/ASIC synthesis stays technology-agnostic.
        xilinx_define = (
            "-DFROST_XILINX_PRIMS" if synth_command.startswith("synth_xilinx") else ""
        )

        # Build Yosys script
        yosys_script = []

        # Read all Verilog files with SystemVerilog support for .sv files
        for vfile in verilog_files:
            if vfile.endswith(".sv"):
                yosys_script.append(f"read_verilog -sv {xilinx_define} {vfile}".strip())
            else:
                yosys_script.append(f"read_verilog {xilinx_define} {vfile}".strip())

        # Add synthesis command
        yosys_script.append(synth_command)

        # Join all commands with newlines
        script_content = "\n".join(yosys_script)

        # Run Yosys
        print(f"Parsing filelist: {self.filelist}")
        print(f"Using ROOT: {self.root_dir}")
        print(f"Found {len(verilog_files)} Verilog files")

        shell_cmd = ["yosys", "-p", script_content]

        if capture_output:
            result = subprocess.run(
                shell_cmd,
                capture_output=True,
                text=True,
                cwd=self.test_dir,
                timeout=300,  # 5 minute timeout
            )
        else:
            # Let output stream to console
            result = subprocess.run(
                shell_cmd,
                cwd=self.test_dir,
                timeout=300,  # 5 minute timeout
                text=True,
            )

        return result

    def check_for_errors(
        self, result: subprocess.CompletedProcess[str]
    ) -> tuple[bool, list[str]]:
        """Check synthesis output for errors."""
        has_error = False
        error_lines = []

        # Check stdout for errors
        if result.stdout and "ERROR:" in result.stdout:
            has_error = True
            for line in result.stdout.splitlines():
                if "ERROR:" in line:
                    error_lines.append(line)

        # Check stderr for errors
        if result.stderr and "ERROR:" in result.stderr:
            has_error = True
            for line in result.stderr.splitlines():
                if "ERROR:" in line:
                    error_lines.append(line)

        # Check return code
        if result.returncode != 0:
            has_error = True
            if not error_lines:
                error_lines.append(f"Yosys exited with code {result.returncode}")

        return has_error, error_lines


# Pytest test class
@pytest.mark.synthesis
class TestYosysSynthesis:
    """Test cases for Yosys synthesis."""

    def test_yosys_installed(self) -> None:
        """Test that Yosys is installed and available."""
        try:
            result = subprocess.run(
                ["yosys", "-V"], capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                pytest.fail(
                    "Yosys not found or failed to run - required for synthesis tests"
                )
            assert (
                "Yosys" in result.stdout or "yosys" in result.stdout.lower()
            ), "Yosys version output not as expected"
        except FileNotFoundError:
            pytest.fail("Yosys not installed - required for synthesis tests")
        except subprocess.TimeoutExpired:
            pytest.fail("Yosys version check timed out")

    @pytest.mark.parametrize(
        "target_name,synth_command,description",
        SYNTHESIS_TARGETS,
        ids=[t[0] for t in SYNTHESIS_TARGETS],
    )
    def test_synthesis(
        self, target_name: str, synth_command: str, description: str, capsys: Any
    ) -> None:
        """Run synthesis for a specific target and check for errors."""
        runner = YosysRunner()

        # Check if Yosys is available
        try:
            subprocess.run(["yosys", "-V"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            pytest.fail("Yosys not installed - required for synthesis tests")

        with capsys.disabled():
            print(f"\nRunning Yosys synthesis for {description}...")

        try:
            result = runner.run_synthesis(
                capture_output=True, synth_command=synth_command
            )

            # Check for errors
            has_error, error_lines = runner.check_for_errors(result)

            # Print summary for debugging
            with capsys.disabled():
                if has_error:
                    print(f"\nSynthesis for {target_name} failed with errors:")
                    for line in error_lines:
                        print(f"  {line}")
                else:
                    print(f"\nSynthesis for {target_name} completed successfully")
                    if result.stdout and "End of script" in result.stdout:
                        # Extract and print statistics if available
                        for line in result.stdout.splitlines():
                            if "Number of cells:" in line or "Number of wires:" in line:
                                print(f"  {line.strip()}")

            # Assert no errors
            if has_error:
                error_msg = f"Yosys synthesis for {target_name} failed:\n" + "\n".join(
                    error_lines
                )
                pytest.fail(error_msg)

        except subprocess.TimeoutExpired:
            pytest.fail(f"Yosys synthesis for {target_name} timed out after 5 minutes")
        except Exception as e:
            pytest.fail(f"Unexpected error during {target_name} synthesis: {e}")


@pytest.mark.synthesis
class TestYosysTomasuloSynthesis:
    """Test cases for Yosys synthesis of Tomasulo out-of-order modules."""

    @pytest.mark.parametrize(
        "target_name,synth_command,description",
        SYNTHESIS_TARGETS,
        ids=[t[0] for t in SYNTHESIS_TARGETS],
    )
    def test_tomasulo_synthesis(
        self, target_name: str, synth_command: str, description: str, capsys: Any
    ) -> None:
        """Run synthesis for Tomasulo modules on a specific target."""
        runner = YosysRunner(filelist_key="tomasulo")

        # Check if Yosys is available
        try:
            subprocess.run(["yosys", "-V"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            pytest.fail("Yosys not installed - required for synthesis tests")

        with capsys.disabled():
            print(f"\nRunning Yosys Tomasulo synthesis for {description}...")

        try:
            result = runner.run_synthesis(
                capture_output=True, synth_command=synth_command
            )

            # Check for errors
            has_error, error_lines = runner.check_for_errors(result)

            # Print summary for debugging
            with capsys.disabled():
                if has_error:
                    print(f"\nTomasulo synthesis for {target_name} failed with errors:")
                    for line in error_lines:
                        print(f"  {line}")
                else:
                    print(
                        f"\nTomasulo synthesis for {target_name} completed successfully"
                    )
                    if result.stdout and "End of script" in result.stdout:
                        # Extract and print statistics if available
                        for line in result.stdout.splitlines():
                            if "Number of cells:" in line or "Number of wires:" in line:
                                print(f"  {line.strip()}")

            # Assert no errors
            if has_error:
                error_msg = (
                    f"Yosys Tomasulo synthesis for {target_name} failed:\n"
                    + "\n".join(error_lines)
                )
                pytest.fail(error_msg)

        except subprocess.TimeoutExpired:
            pytest.fail(
                f"Yosys Tomasulo synthesis for {target_name} timed out after 5 minutes"
            )
        except Exception as e:
            pytest.fail(
                f"Unexpected error during {target_name} Tomasulo synthesis: {e}"
            )


# Command-line interface for standalone execution
def main() -> int:
    """Run Yosys synthesis from command line."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Run Yosys synthesis for Frost RISC-V CPU",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                           # Run frost targets (generic, xilinx)
  %(prog)s --design tomasulo         # Run tomasulo out-of-order modules
  %(prog)s --target xilinx           # Run synthesis for Xilinx only
  %(prog)s --target generic          # Run generic/ASIC synthesis
  %(prog)s --target ice40            # Run iCE40 synthesis (any Yosys target works)
  %(prog)s --verbose                 # Show full Yosys output

This script can also be run via pytest:
  pytest test_run_yosys.py                        # Run all synthesis tests
  pytest test_run_yosys.py::TestYosysSynthesis    # Run frost only
  pytest test_run_yosys.py::TestYosysTomasuloSynthesis  # Run tomasulo only
""",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Show full Yosys output"
    )
    parser.add_argument(
        "--design",
        "-d",
        default="frost",
        choices=list(DESIGN_FILELISTS.keys()),
        help=f"Design to synthesize (default: frost). Available: {list(DESIGN_FILELISTS.keys())}",
    )
    parser.add_argument(
        "--target",
        "-t",
        default=None,
        help="Synthesis target (any Yosys synth_* target, e.g., xilinx, ice40, ecp5)",
    )

    args = parser.parse_args()

    # Check if Yosys is installed
    try:
        result = subprocess.run(["yosys", "-V"], capture_output=True, text=True)
        if result.returncode != 0:
            print("Error: Yosys not found or failed to run")
            return 1
        print(f"Found: {result.stdout.strip()}")
    except FileNotFoundError:
        print("Error: Yosys is not installed or not in PATH")
        return 1

    runner = YosysRunner(filelist_key=args.design)
    print(f"Design: {args.design} ({runner.filelist})")

    # Determine which targets to run
    if args.target:
        # Check if it's one of the default targets
        matching = [t for t in SYNTHESIS_TARGETS if t[0] == args.target]
        if matching:
            targets = matching
        else:
            # Allow any Yosys synth_* target
            synth_cmd = f"synth_{args.target}" if args.target != "generic" else "synth"
            targets = [(args.target, synth_cmd, args.target)]
    else:
        targets = SYNTHESIS_TARGETS

    # Run synthesis for each target
    failed_targets = []
    for target_name, synth_command, description in targets:
        try:
            print(f"\n{'=' * 60}")
            print(f"Running Yosys synthesis for {description}...")
            print(f"{'=' * 60}")

            result = runner.run_synthesis(
                capture_output=not args.verbose, synth_command=synth_command
            )

            # Check for errors
            has_error, error_lines = runner.check_for_errors(result)

            if not args.verbose and result.stdout:
                # Print summary of output
                lines = result.stdout.splitlines()

                # Look for final statistics
                for line in lines[-50:]:
                    if (
                        "End of script" in line
                        or "Number of cells:" in line
                        or "ERROR:" in line
                    ):
                        print(line)

            if has_error:
                print(f"\nSynthesis for {target_name} FAILED with errors:")
                for line in error_lines:
                    print(f"  {line}")
                failed_targets.append(target_name)
            else:
                print(f"\nSynthesis for {target_name} completed successfully!")

        except Exception as e:
            print(f"\nError during {target_name} synthesis: {e}")
            failed_targets.append(target_name)

    # Summary
    print(f"\n{'=' * 60}")
    print("SYNTHESIS SUMMARY")
    print(f"{'=' * 60}")
    passed = len(targets) - len(failed_targets)
    print(f"Passed: {passed}/{len(targets)}")
    if failed_targets:
        print(f"Failed: {', '.join(failed_targets)}")
        return 1
    else:
        print("All synthesis targets passed!")
        return 0


if __name__ == "__main__":
    sys.exit(main())

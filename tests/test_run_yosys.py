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

"""Run configured Yosys targets to check RTL portability."""

import os
import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

import pytest


def _compile_hello_world(root_dir: Path) -> bool:
    """Compile hello_world application for synthesis.

    Args:
        root_dir: Path to the repository root directory

    Returns:
        True if compilation succeeded, False on failure.
    """
    apps_dir = root_dir / "sw" / "apps"
    sys.path.insert(0, str(apps_dir))
    try:
        from compile_app import compile_app

        return compile_app("hello_world", verbose=True)
    finally:
        sys.path.pop(0)


def _is_generic_synth_command(synth_command: str) -> bool:
    """Return true for Yosys' generic synth command, with optional flags."""
    command = synth_command.strip()
    return command == "synth" or command.startswith("synth ")


def _xilinx_family(synth_command: str) -> str | None:
    """Return the synth_xilinx -family value, if this is a Xilinx command."""
    parts = synth_command.split()
    if not parts or parts[0] != "synth_xilinx":
        return None

    for i, part in enumerate(parts[:-1]):
        if part == "-family":
            return parts[i + 1]
    return None


def _hierarchy_command(synth_command: str) -> str:
    """Build the Yosys hierarchy command(s) for this synthesis target.

    The supported Xilinx target is synthesized in the X3 hardware shape: the
    cached tier is enabled with its AXI export because the behavioral DDR
    model is simulation-only. Other targets keep the module defaults.

    Apply the parameters with `chparam -set`, rather than `hierarchy -chparam`:
    the latter triggers a duplicate-module assertion in Yosys 0.64 when the
    cache/walker hierarchy is reprocessed. Yosys 0.68 may still specialize
    and rename this top, so later checks must follow its top attribute.
    """
    family = _xilinx_family(synth_command)
    commands = []
    if family == "xcup":
        commands.append("chparam -set ENABLE_CACHED_TIER 1 cpu_and_mem")
        commands.append("chparam -set USE_BEHAVIORAL_DDR 0 cpu_and_mem")
    commands.append("hierarchy -top cpu_and_mem")
    return "\n".join(commands)


def _get_timeout_seconds(synth_command: str) -> int:
    """Get synthesis timeout in seconds, with target-aware defaults.

    Defaults:
      - Generic target (synth): 1800s
      - Other non-Xilinx targets: 7200s
      - Xilinx targets (synth_xilinx*): 7200s (the full CPU/NIC target takes
        about 50 minutes locally; allow margin for CI host variation)

    Environment overrides:
      - FROST_YOSYS_GENERIC_TIMEOUT_SEC
      - FROST_YOSYS_TIMEOUT_SEC
      - FROST_YOSYS_XILINX_TIMEOUT_SEC
    """
    default_generic_timeout = 1800
    default_timeout = 7200
    default_xilinx_timeout = 7200

    if _is_generic_synth_command(synth_command):
        env_name = "FROST_YOSYS_GENERIC_TIMEOUT_SEC"
        fallback = default_generic_timeout
    elif synth_command.startswith("synth_xilinx"):
        env_name = "FROST_YOSYS_XILINX_TIMEOUT_SEC"
        fallback = default_xilinx_timeout
    else:
        env_name = "FROST_YOSYS_TIMEOUT_SEC"
        fallback = default_timeout

    raw = os.environ.get(env_name)
    if raw is None and _is_generic_synth_command(synth_command):
        env_name = "FROST_YOSYS_TIMEOUT_SEC"
        raw = os.environ.get(env_name)
    if raw is None:
        return fallback

    try:
        timeout = int(raw)
        if timeout <= 0:
            raise ValueError
        return timeout
    except ValueError:
        print(f"Warning: invalid {env_name}={raw!r}; using {fallback}s")
        return fallback


# Synthesis targets for pytest runs
# Additional targets can be run manually: ./test_run_yosys.py --target <name>
#
# Full generic `synth` maps RAMs and wide state arrays into generic flops and
# gates.  For the full CPU that can spend hours in repeated OPT passes before
# ABC.  Keep the generic target as a technology-independent front-end/coarse
# synthesis check; the Xilinx target below still exercises complete synthesis.
GENERIC_SYNTH_COMMAND = "synth -top cpu_and_mem -run coarse"
SYNTHESIS_TARGETS = [
    ("generic", GENERIC_SYNTH_COMMAND, "Generic/ASIC (coarse synthesis)"),
    ("xilinx_ultrascale_plus", "synth_xilinx -family xcup", "Xilinx UltraScale+"),
]

# Use the complete integration filelist even though cpu_and_mem remains the
# synthesis top: its cached tier instantiates the NIC and MAC/PCS, whose
# dependencies are listed before cpu_and_mem.f in frost.f.
DESIGN_FILELISTS = {
    "frost": "hw/rtl/frost.f",
}


class YosysRunner:
    """Run Yosys synthesis on a design filelist."""

    def __init__(self, filelist_key: str = "frost") -> None:
        """Initialize runner with paths.

        Args:
            filelist_key: Key from DESIGN_FILELISTS dict (currently only "frost").
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
        """Compile hello_world and set up sw.mem/sw64.mem symlinks for synthesis.

        The imem BRAM $readmemh's sw.mem (32-bit words) and the 64-bit data
        BRAM $readmemh's sw64.mem (dword tokens; see "Data-tier bus contract"
        in hw/rtl/README.md). Both come from the hello_world build.
        """
        if not _compile_hello_world(self.root_dir):
            raise RuntimeError("Failed to compile hello_world for synthesis")

        for mem_name in ("sw.mem", "sw64.mem"):
            mem_target = self.root_dir / "sw" / "apps" / "hello_world" / mem_name
            mem_link = self.test_dir / mem_name

            if mem_link.exists() or mem_link.is_symlink():
                mem_link.unlink()
            mem_link.symlink_to(mem_target)

    def parse_filelist(self, filelist_path: Path) -> list[str]:
        """Parse a filelist file and return deduplicated list of Verilog files.

        Sub-module filelists are self-contained (they include their own package
        and RAM primitive dependencies) so they work standalone for cocotb unit
        tests. Nested inside a full-chip filelist they produce duplicates that
        Yosys rejects as module redefinitions, so the list is deduplicated here
        in first-occurrence order.
        """
        seen: set[str] = set()
        files: list[str] = []

        self._parse_filelist_recursive(filelist_path, files, seen)
        return files

    def _parse_filelist_recursive(
        self, filelist_path: Path, files: list[str], seen: set[str]
    ) -> None:
        """Recursively parse filelist, deduplicating by resolved path."""
        with open(filelist_path) as f:
            for line in f:
                line = line.strip()

                if not line or line.startswith("#") or line.startswith("//"):
                    continue

                if line.startswith("-f "):
                    nested_filelist = line[3:].strip()
                    nested_filelist = nested_filelist.replace(
                        "$(ROOT)", str(self.root_dir)
                    )
                    self._parse_filelist_recursive(Path(nested_filelist), files, seen)
                else:
                    file_path = line.replace("$(ROOT)", str(self.root_dir))
                    resolved = str(Path(file_path).resolve())
                    if resolved not in seen:
                        seen.add(resolved)
                        files.append(file_path)

    def _convert_nic_sources(
        self, verilog_files: list[str], directory: Path, defines: str, timeout: int
    ) -> list[str]:
        """Lower NIC/MAC SystemVerilog with the image's pinned sv2v frontend.

        Yosys read_verilog cannot parse the MAC's package imports/function
        returns or the NIC's packed multidimensional ports. Convert this
        subtree together so packages resolve; the CPU and library sources
        continue through the existing Yosys frontend. Lower always_comb to
        always @* ourselves: sv2v's explicit sensitivity list can contain a
        whole unpacked array, which read_verilog rejects. Keeping always_comb
        instead makes Yosys reject sv2v's otherwise unused loop-index latches.
        """
        nic_directories = {
            self.root_dir / "hw/rtl/net10g",
            self.root_dir / "hw/rtl/peripherals/nic",
        }
        nic_sources = [
            source for source in verilog_files if Path(source).parent in nic_directories
        ]
        if not nic_sources:
            return verilog_files

        converted = directory / "nic.v"
        subprocess.run(
            [
                "sv2v",
                *defines.split(),
                "--exclude=Always",
                f"--write={converted}",
                *nic_sources,
                "+RTS",
                "-N2",
                "-M2G",
                "-RTS",
            ],
            check=True,
            text=True,
            timeout=timeout,
        )
        converted.write_text(
            re.sub(r"\balways_comb\b", "always @*", converted.read_text())
        )
        converted_sources = set(nic_sources)
        return [str(converted)] + [
            source for source in verilog_files if source not in converted_sources
        ]

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

        verilog_files = self.parse_filelist(self.filelist)

        if not verilog_files:
            raise ValueError("No Verilog files found in filelist")

        # -DSYNTHESIS is the usual guard that excludes simulation-only code
        # ($warning, assertions) from synthesis. -DFROST_XILINX_PRIMS enables
        # Xilinx primitive instantiations for synth_xilinx targets only, so
        # generic/ASIC synthesis stays technology-agnostic.
        defines = "-DSYNTHESIS"
        if synth_command.startswith("synth_xilinx"):
            defines += " -DFROST_XILINX_PRIMS"

        print(f"Parsing filelist: {self.filelist}")
        print(f"Using ROOT: {self.root_dir}")
        print(f"Found {len(verilog_files)} Verilog files")
        timeout_sec = _get_timeout_seconds(synth_command)
        print(f"Using timeout: {timeout_sec}s")

        with TemporaryDirectory(prefix="frost-yosys-") as temp_dir:
            verilog_files = self._convert_nic_sources(
                verilog_files, Path(temp_dir), defines, timeout_sec
            )
            yosys_script = []
            for vfile in verilog_files:
                yosys_script.append(f"read_verilog -sv {defines} {vfile}")

            yosys_script.append(_hierarchy_command(synth_command))
            # The eight-lane RX parser's symbolic next-state logic makes FSM
            # transition-table extraction expand unnecessarily. Preserve its
            # encoding, as in the standalone net10g synthesis check.
            yosys_script.append(
                'setattr -set fsm_encoding "none" *eth10g_mac_rx*/w:state'
            )
            yosys_script.append(synth_command)
            # Coarse generic synthesis does not reject unresolved modules on
            # its own. Check after synthesis so Xilinx primitive definitions
            # have been loaded too. Unused sv2v loop-index latches must be gone;
            # reject any surviving generic or mapped Xilinx latch cells.
            yosys_script.append("hierarchy -check")
            yosys_script.append(
                "select -assert-none t:$dlatch* t:$adlatch* t:$_DLATCH* t:LD*"
            )
            script_content = "\n".join(yosys_script)

            result = subprocess.run(
                ["yosys", "-p", script_content],
                capture_output=capture_output,
                text=True,
                cwd=self.test_dir,
                timeout=timeout_sec,
            )

        return result

    def check_for_errors(
        self, result: subprocess.CompletedProcess[str]
    ) -> tuple[bool, list[str]]:
        """Check synthesis output for errors."""
        has_error = False
        error_lines = []

        if result.stdout and "ERROR:" in result.stdout:
            has_error = True
            for line in result.stdout.splitlines():
                if "ERROR:" in line:
                    error_lines.append(line)

        if result.stderr and "ERROR:" in result.stderr:
            has_error = True
            for line in result.stderr.splitlines():
                if "ERROR:" in line:
                    error_lines.append(line)

        if result.returncode != 0:
            has_error = True
            if not error_lines:
                error_lines.append(f"Yosys exited with code {result.returncode}")

        return has_error, error_lines


def test_synthesis_filelist_includes_cached_tier_dependencies(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Catch omitted NIC dependencies without waiting for full synthesis."""
    monkeypatch.setattr(YosysRunner, "setup_sw_mem", lambda self: None)
    runner = YosysRunner()
    sources = runner.parse_filelist(runner.filelist)
    names = {Path(source).name for source in sources}
    assert {
        "cpu_and_mem.sv",
        "nic_pkg.sv",
        "nic_top.sv",
        "eth10g_crc_pkg.sv",
        "eth10g_pcs_pkg.sv",
        "eth10g_mac_pcs.sv",
        "async_fifo.sv",
        "cdc_sync.sv",
        "sdp_block_ram.sv",
    } <= names
    assert len(sources) == len(set(sources)), "Yosys rejects duplicate modules"
    assert all(Path(source).is_file() for source in sources)


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

            has_error, error_lines = runner.check_for_errors(result)

            with capsys.disabled():
                if has_error:
                    print(f"\nSynthesis for {target_name} failed with errors:")
                    for line in error_lines:
                        print(f"  {line}")
                else:
                    print(f"\nSynthesis for {target_name} completed successfully")
                    if result.stdout and "End of script" in result.stdout:
                        for line in result.stdout.splitlines():
                            if "Number of cells:" in line or "Number of wires:" in line:
                                print(f"  {line.strip()}")

            if has_error:
                error_msg = f"Yosys synthesis for {target_name} failed:\n" + "\n".join(
                    error_lines
                )
                pytest.fail(error_msg)

        except subprocess.TimeoutExpired:
            timeout_sec = _get_timeout_seconds(synth_command)
            pytest.fail(
                f"Yosys synthesis for {target_name} timed out after {timeout_sec}s"
            )
        except Exception as e:
            pytest.fail(f"Unexpected error during {target_name} synthesis: {e}")


@pytest.mark.synthesis
@pytest.mark.parametrize("fault", ["missing_module", "observable_latch"])
def test_synthesis_rejects_invalid_nic(
    fault: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Missing dependencies and real latches must fail even the coarse target."""
    monkeypatch.setattr(YosysRunner, "setup_sw_mem", lambda self: None)
    runner = YosysRunner()
    runner.root_dir = tmp_path
    runner.test_dir = tmp_path
    runner.filelist = tmp_path / "design.f"
    top = tmp_path / "cpu_and_mem.sv"
    top.write_text(
        "module cpu_and_mem(input logic en, data, output logic value);\n"
        "  nic_top nic(.en(en), .data(data), .value(value));\n"
        "endmodule\n"
    )
    sources = [str(top)]
    if fault == "observable_latch":
        nic = tmp_path / "hw/rtl/peripherals/nic/nic_top.sv"
        nic.parent.mkdir(parents=True)
        nic.write_text(
            "module nic_top(input logic en, data, output logic value);\n"
            "  wire kept_always_comb_name = en;\n"
            "  always_comb if (kept_always_comb_name) value = data;\n"
            "endmodule\n"
        )
        sources.append(str(nic))
    runner.filelist.write_text("\n".join(sources) + "\n")

    result = runner.run_synthesis(synth_command=GENERIC_SYNTH_COMMAND)
    has_error, errors = runner.check_for_errors(result)
    assert has_error, f"Synthesis accepted {fault}"
    if fault == "missing_module":
        assert any(
            "nic_top" in error and "not part of the design" in error for error in errors
        )
    else:
        assert any("selection is not empty" in error for error in errors)


@pytest.mark.synthesis
def test_synthesis_accepts_specialized_top(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The final check must retain the top selected by Xilinx elaboration."""
    monkeypatch.setattr(YosysRunner, "setup_sw_mem", lambda self: None)
    runner = YosysRunner()
    runner.root_dir = tmp_path
    runner.test_dir = tmp_path
    runner.filelist = tmp_path / "design.f"
    top = tmp_path / "cpu_and_mem.sv"
    top.write_text(
        "module cpu_and_mem #(parameter ENABLE_CACHED_TIER=1, "
        "USE_BEHAVIORAL_DDR=1)(input data, output value);\n"
        "  assign value = data;\n"
        "endmodule\n"
    )
    runner.filelist.write_text(str(top) + "\n")
    # Model the top-name change caused by reprocessing the cache/walker
    # hierarchy, without elaborating the complete CPU in this small test.
    result = runner.run_synthesis(
        synth_command="synth_xilinx -family xcup -run begin:begin\n"
        "rename -top specialized_cpu_and_mem"
    )
    has_error, errors = runner.check_for_errors(result)
    assert not has_error, errors


# Command-line interface for standalone execution
def main() -> int:
    """Run Yosys synthesis from command line."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Run Yosys synthesis for Frost RISC-V CPU",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                           # Run standard targets (generic, UltraScale+)
  %(prog)s --target xilinx_ultrascale_plus  # Run the supported Xilinx target
  %(prog)s --target generic          # Run generic/ASIC synthesis
  %(prog)s --target ice40            # Run iCE40 synthesis (any Yosys target works)
  %(prog)s --verbose                 # Show full Yosys output

This script can also be run via pytest:
  pytest test_run_yosys.py                        # Run all synthesis tests
  pytest test_run_yosys.py::TestYosysSynthesis    # Run specific class
""",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Show full Yosys output"
    )
    parser.add_argument(
        "--target",
        "-t",
        default=None,
        help="Synthesis target (any Yosys synth_* target, e.g., xilinx, ice40, ecp5)",
    )

    args = parser.parse_args()

    try:
        result = subprocess.run(["yosys", "-V"], capture_output=True, text=True)
        if result.returncode != 0:
            print("Error: Yosys not found or failed to run")
            return 1
        print(f"Found: {result.stdout.strip()}")
    except FileNotFoundError:
        print("Error: Yosys is not installed or not in PATH")
        return 1

    runner = YosysRunner()
    print(f"Design: frost ({runner.filelist})")

    if args.target:
        matching = [t for t in SYNTHESIS_TARGETS if t[0] == args.target]
        if matching:
            targets = matching
        else:
            # Allow any Yosys synth_* target
            synth_cmd = (
                GENERIC_SYNTH_COMMAND
                if args.target == "generic"
                else f"synth_{args.target}"
            )
            targets = [(args.target, synth_cmd, args.target)]
    else:
        targets = SYNTHESIS_TARGETS

    failed_targets = []
    for target_name, synth_command, description in targets:
        try:
            print(f"\n{'=' * 60}")
            print(f"Running Yosys synthesis for {description}...")
            print(f"{'=' * 60}")

            result = runner.run_synthesis(
                capture_output=not args.verbose, synth_command=synth_command
            )

            has_error, error_lines = runner.check_for_errors(result)

            if not args.verbose and result.stdout:
                lines = result.stdout.splitlines()

                # The statistics block is at the tail of the log.
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

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

"""Exercise the real cocotb make rules with a tiny simulator stand-in."""

from pathlib import Path
import subprocess
import sys


def test_parallel_make_runs_simulator_with_existing_results(tmp_path: Path) -> None:
    """Every make invocation must execute the simulator, even with a prior XML."""
    root = Path(__file__).resolve().parents[1]
    build = tmp_path / "sim_build"
    build.mkdir()
    # Prebuilt stand-in avoids compiling RTL in the fast Python suite. Its
    # report follows cocotb's XML contract, so the real result checker runs.
    (build / "Vtop.mk").touch()
    simulator = build / "Vtop"
    simulator.write_text(
        f"#!{sys.executable}\n"
        "from pathlib import Path\n"
        "import os\n"
        "with Path('invocations').open('a') as log:\n"
        "    log.write('simulate\\n')\n"
        "Path(os.environ['COCOTB_RESULTS_FILE']).write_text(\n"
        "    '<testsuites><testsuite><testcase name=\"stand_in\" '"
        "'classname=\"make_test\"/></testsuite></testsuites>')\n"
    )
    simulator.chmod(0o755)
    command = [
        "make",
        "--no-print-directory",
        "-j8",
        "-f",
        str(root / "tests/Makefile"),
        f"ROOT={root}",
        "TOPLEVEL=cdb_arbiter",
        f"SIM_BUILD={build}",
        f"COCOTB_RESULTS_FILE={tmp_path / 'results.xml'}",
        "sim",
    ]
    for expected_runs in (1, 2, 3):
        result = subprocess.run(
            command, cwd=tmp_path, capture_output=True, text=True, timeout=30
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert (tmp_path / "invocations").read_text().splitlines() == [
            "simulate"
        ] * expected_runs

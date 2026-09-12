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

"""Run the production post-opt helper against bounded native-command fixtures."""

from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "scenario",
    (
        "positive",
        "constant",
        "missing_last",
        "wrong_driver",
        "bad_init",
        "placed",
        "protected",
        "case_zero",
        "split_group",
        "strict_missing",
        "native_error",
        "create_failure",
        "connect_failure",
        "release_failure",
        "restore_failure",
        "changed_source",
        "changed_macro",
    ),
)
def test_post_opt_copy_guards(scenario: str, tmp_path: Path) -> None:
    """Exercise complete ownership and failures before and during mutation."""
    result = subprocess.run(
        [
            "tclsh",
            str(ROOT / "tests/fixtures/x3_nic_placement.tcl"),
            scenario,
            str(ROOT / "fpga/build/x3_nic_placement.tcl"),
            str(tmp_path / "audit.tcldict"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"PASS {scenario}" in result.stdout

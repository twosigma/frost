#!/usr/bin/env python3

#    Copyright 2026 John Goodacre
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

"""Exercise the shared strict frontend checker and its read-set extraction.

All RTL reads run directly in FROST's Yosys; missing tools fail. Use
``./scripts/frost.py run python3 tests/slang_frontend.py`` for the manual CLI.
"""

import subprocess
from pathlib import Path

import pytest

import slang_frontend as slang


def test_filelist_expansion_lists_each_file_once() -> None:
    """Nested dependencies occur once in their first-seen order."""
    entries = slang.expand_filelist(slang.ROOT / "hw/rtl/frost.f")
    assert len(entries) == len(set(entries))
    assert str(slang.ROOT / "hw/rtl/frost.sv") in entries


def test_recursive_filelist_is_an_error(tmp_path: Path) -> None:
    """A recursive source list fails instead of recursing indefinitely."""
    filelist = tmp_path / "recursive.f"
    filelist.write_text("-f recursive.f\n")
    with pytest.raises(ValueError, match="recursive filelist"):
        slang.expand_filelist(filelist)


def test_formal_read_sets_preserve_task_defines_and_parameters(tmp_path: Path) -> None:
    """Task tags and per-read implicit defines retain the proof source view."""
    formal = tmp_path / "formal"
    formal.mkdir()
    (formal / "dut.sv").touch()
    (formal / "dut.sby").write_text(
        "[tasks]\nprove proof\ncover\n[script]\n"
        "read -define PERSISTENT\nproof: verilog_defines -D PROOF=1\n"
        "read -sv dut.sv\nproof: read -formal -nosynthesis -D LOCAL dut.sv\n"
        "proof: chparam -set WIDTH 72 dut\n"
        "delete t:child\nprep -top dut\n[files]\ndut.sv\n"
    )
    prove, cover = slang.formal_cases(tmp_path)
    assert prove.parameters == (("WIDTH", "72"),)
    assert prove.abstracts == ("child",)
    assert "-DSYNTHESIS" in prove.units[0].options
    assert "-DFORMAL" in prove.units[1].options
    assert "-DSYNTHESIS" not in prove.units[1].options
    assert "-DLOCAL" in prove.units[1].options
    assert all("-DPERSISTENT" in u.options for u in prove.units)
    assert "-DPROOF=1" in prove.units[1].options
    assert len(cover.units) == 1
    assert "-DPROOF=1" not in cover.units[0].options


def test_formal_design_reset_splits_views(tmp_path: Path) -> None:
    """A script that resets the design compares two views of one source."""
    formal = tmp_path / "formal"
    formal.mkdir()
    (formal / "dut.sv").touch()
    (formal / "twin.sby").write_text(
        "[tasks]\nboth\n[script]\n"
        "read -sv -D SYNTHESIS dut.sv\nchparam -set WIDTH 8 dut\n"
        "hierarchy -top dut\ndesign -reset\n"
        "read -sv -D SYNTHESIS -D MACRO dut.sv\nhierarchy -top dut\n"
        "[files]\ndut.sv\n"
    )
    gold, gate = slang.formal_cases(tmp_path)
    assert (gold.name, gate.name) == ("formal/twin/both/1", "formal/twin/both/2")
    assert gold.parameters == (("WIDTH", "8"),)
    assert gate.parameters == ()
    assert "-DMACRO" not in gold.units[0].options
    assert "-DMACRO" in gate.units[0].options


def test_missing_tool_is_an_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """A missing frontend is a failure, never a pytest skip."""
    monkeypatch.setattr(slang.shutil, "which", lambda name: None)
    with pytest.raises(RuntimeError, match="yosys is missing"):
        slang.check()


def test_nonzero_exit_is_never_waived(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Even a nonzero exit without a source diagnostic fails the check."""

    def fail(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess([], 3, "", "front end stopped")

    monkeypatch.setattr(slang.subprocess, "run", fail)
    result = slang.run_case(slang.SlangCase("failure", "dut", ()))
    assert result["returncode"] == 3
    assert "yosys exited with status 3" in result["errors"]


@pytest.mark.parametrize(
    "source",
    [
        "module dut(output logic y); assign y = later; logic later; endmodule",
        "module dut(output wire y); assign y = undeclared; endmodule",
        "module dut(output logic [3:0] y); assign y = 4'b1 << 4; endmodule",
    ],
)
def test_rejects_semantic_errors_and_promoted_warnings(
    tmp_path: Path, source: str
) -> None:
    """Real frontend diagnostics reject bad source and overflow warnings."""
    path = tmp_path / "dut.sv"
    path.write_text(source)
    case = slang.SlangCase(
        "synthesis/mutation/dut", "dut", (slang.ReadUnit((), (str(path),)),)
    )
    result = slang.run_case(case)
    assert result["returncode"] != 0
    assert result["errors"]


def test_slang_reads_the_rtl() -> None:
    """Run every required view through the shared checker inside FROST."""
    assert slang.check() == 0


if __name__ == "__main__":
    raise SystemExit(slang.main())

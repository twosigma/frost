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

"""Check control toggle selection against Verilator's elaboration and coverage."""

import json
from pathlib import Path
import subprocess
from typing import Any

import coverage_toggle


SOURCE = """module control_probe (
    input logic i_clk,
    input logic i_valid,
    input logic i_ready,
    input logic [7:0] i_payload,
    output logic o_ready,
    output logic [3:3] o_valid
);
  typedef enum logic [1:0] {IDLE, BUSY} state_t;
  typedef logic flag_t;
  state_t state_q;
  flag_t pending_q;
  logic carry_q;
  logic f_expected_ready;
  logic shared_data, shared_valid;
  wire [7:0] initialized_data =
      i_valid ? (i_ready ? 8'h12 : 8'h34) : 8'h56;
  always_ff @(posedge i_clk) begin
    state_q <= i_valid ? BUSY : IDLE;
    pending_q <= i_valid && !i_ready;
    carry_q <= i_payload[0];
    f_expected_ready <= i_ready;
    shared_data <= i_payload[1];
    shared_valid <= i_valid;
    cover (i_valid && i_ready);
  end
  assign o_ready = pending_q;
  assign o_valid = i_valid;
endmodule
"""


def elaborate(
    source: Path, output: Path, control: Path | None = None
) -> tuple[Path, Path]:
    """Elaborate the fixture with real line, user, and bounded toggle instrumentation."""
    output.mkdir()
    tree = output / "tree.json"
    metadata = output / "meta.json"
    command = [
        "verilator",
        "--json-only",
        "--MMD",
        "--MP",
        "--Mdir",
        str(output),
        "--json-only-output",
        str(tree),
        "--json-only-meta-output",
        str(metadata),
        "--top-module",
        "control_probe",
        "--public-flat-rw",
        "--coverage-line",
        "--coverage-user",
        "--coverage-toggle",
        "--coverage-max-width",
        "8",
    ]
    if control is not None:
        command.append(str(control))
    file_list = output / "inputs.f"
    file_list.write_text(f"{source}\n")
    command.extend(("-f", str(file_list)))
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    return tree, metadata


def inventory(tree_path: Path, metadata_path: Path) -> tuple[set[Any], set[Any]]:
    """Return source toggle declarations and every field of each non-toggle point."""
    tree = json.loads(tree_path.read_text())
    files = json.loads(metadata_path.read_text())["files"]
    toggles = set()
    other = set()
    for node in coverage_toggle.nodes(tree):
        if node.get("type") == "COVERTOGGLEDECL":
            toggles.add(coverage_toggle.source_line(node, files))
        elif node.get("type") == "COVEROTHERDECL":
            fields = {
                key: value for key, value in node.items() if key not in ("addr", "loc")
            }
            other.add(
                (
                    coverage_toggle.source_line(node, files),
                    node["loc"].partition(",")[2],
                    json.dumps(fields, sort_keys=True),
                )
            )
    return toggles, other


def test_control_filter_preserves_executable_coverage_and_selected_signals(
    tmp_path: Path,
) -> None:
    """Ports, aliases, state, shared lines, and multiline initializers survive selection."""
    source = tmp_path / "control_probe.sv"
    source.write_text(SOURCE)
    full_tree, full_meta = elaborate(source, tmp_path / "full")
    tree = json.loads(full_tree.read_text())
    metadata = json.loads(full_meta.read_text())
    config = json.loads(coverage_toggle.CONFIG.read_text())
    disabled = coverage_toggle.exclusions(tree, metadata, config)
    variables = {
        node["origName"]: coverage_toggle.source_line(node, metadata["files"])
        for node in coverage_toggle.nodes(tree)
        if node.get("type") == "VAR" and node.get("varType") != "MODULETEMP"
    }
    assert {
        variables[name]
        for name in ("i_clk", "i_payload", "carry_q", "f_expected_ready")
    } <= disabled
    for name in (
        "i_valid",
        "i_ready",
        "o_ready",
        "o_valid",
        "state_q",
        "pending_q",
        "shared_data",
        "shared_valid",
        "initialized_data",
    ):
        assert variables[name] not in disabled, name
    control = tmp_path / "control.vlt"
    coverage_toggle.write_control(
        full_tree,
        full_meta,
        control,
        config,
        tmp_path / "full" / "Vcontrol_probe__ver.d",
    )
    selected_tree, selected_meta = elaborate(source, tmp_path / "selected", control)
    full_toggle, full_other = inventory(full_tree, full_meta)
    selected_toggle, selected_other = inventory(selected_tree, selected_meta)
    assert full_other and selected_other == full_other
    assert selected_toggle == full_toggle - disabled
    dependencies = control.with_suffix(".vlt.d").read_text()
    assert dependencies.startswith(f"{control} : ")
    assert str(source) in dependencies
    assert str(tmp_path / "full" / "inputs.f") in dependencies

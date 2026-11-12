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

"""Every FROST_XILINX_PRIMS block has a formal check against its portable form.

The FPGA build defines FROST_XILINX_PRIMS and instantiates Xilinx primitives
(LUT, MUXF, FDRE, CARRY8) where simulation, most formal tasks and the ASIC flow
see the portable branch. Nothing else would notice if the two branches
drifted apart. This test lists every primitive block in hw/rtl and requires
each one to appear in COVERAGE (a formal file that defines the macro and
compares the two forms) or in NOT_COVERED (a block with no such check yet, with
the reason), or to be a guard that instantiates no primitive (NON_LOGIC).

A block is named by the first primitive instance in its primitive arm, as
`relative/path.sv::instance_name`; a second block with the same name in one
file is `instance_name#2`. A block with no primitive instance is named by its
first line of code. A COVERAGE value of None covers every block in the file.
"""

from pathlib import Path
import re

import pytest

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "hw/rtl"
FORMAL = ROOT / "formal"
RUN_FORMAL = Path(__file__).with_name("test_run_formal.py")

CPU = "cpu_and_mem/cpu/"
LQ = CPU + "tomasulo/load_queue/load_queue.sv"
MACRO = "FROST_XILINX_PRIMS"
PRIMITIVE = re.compile(r"\b(?:LUT[1-6]|MUXF[789]|FD[RSCP]E|CARRY[48])\b")
CONDITIONAL = re.compile(rf"^\s*`(ifdef|ifndef)\s+{MACRO}\b(.*)$")
NESTED = re.compile(r"^\s*`(?:ifdef|ifndef)\b")
ELSE = re.compile(r"^\s*`else\b")
ENDIF = re.compile(r"^\s*`endif\b")

# sby file -> {RTL file: instance names it covers, or None for every block}.
# The sby file must define the macro, read Yosys's cell models, list the RTL
# file, and be registered in tests/test_run_formal.py.
COVERAGE: dict[str, dict[str, tuple[str, ...] | None]] = {
    # Older proofs of small helper cones: pin-level references or a mux reference.
    "data_mem_response_mux.sby": {"cpu_and_mem/data_mem_response_mux.sv": None},
    "line_arbiter_grant.sby": {"lib/cache/line_port_arbiter.sv": None},
    "served_window_coverage.sby": {CPU + "if_stage/served_window_coverage.sv": None},
    "fetch_pc_mux.sby": {CPU + "if_stage/pc_controller.sv": ("u_nonseq",)},
    "pc_register_mux.sby": {
        CPU + "if_stage/pc_controller.sv": ("u_without_live_valid", "u_base", "u_final")
    },
    "pc_increment_holdoff.sby": {CPU + "if_stage/pc_increment_calculator.sv": None},
    "lq_l0_lookup.sby": {CPU + "tomasulo/load_queue/lq_l0_cache.sv": None},
    "lq_age_groups.sby": {
        CPU + "tomasulo/load_queue/coherent_lq_issue_selector.sv": None
    },
    "lq_capture_pins.sby": {
        LQ: (
            "u_late_capture",
            "u_late_inflight",
            "u_bypass_source",
            "u_entry_release",
            "u_staged_match_select",
            "u_candidate_data",
            "u_candidate_write",
        )
    },
    "lq_result_pins.sby": {
        LQ: ("u_late_completion", "u_late_response", "u_late_allocation")
    },
    "coherence_home_forward_pins.sby": {
        "lib/cache/coherence_home.sv": ("u_below_ready", "u_pick")
    },
    # Whole-module comparisons of the module as shipped and with the macro.
    "coherence_control.sby": {"lib/cache/coherence_read_select.sv": None},
    "coherence_home_twin.sby": {"lib/cache/coherence_home.sv": None},
    "coherence_home_engine_twin.sby": {"lib/cache/coherence_home_engine.sv": None},
    "coherence_l1d_twin.sby": {"lib/cache/coherence_l1d.sv": None},
    "decoded_bundle_queue_twin.sby": {
        CPU + "cpu_ooo/frontend_control/decoded_bundle_queue.sv": None
    },
    "cached_tier_adapter_twin.sby": {
        CPU + "cpu_ooo/memory_if/cached_tier_adapter.sv": None
    },
    "data_mem_request_router_twin.sby": {
        CPU + "cpu_ooo/memory_if/data_mem_request_router.sv": None
    },
    "csr_file_twin.sby": {CPU + "csr/csr_file.sv": None},
    "dmmu_twin.sby": {CPU + "mmu/dmmu.sv": None},
    "immu_twin.sby": {CPU + "mmu/immu.sv": None},
    "fp_engine_twin.sby": {CPU + "ex_stage/fpu/fp_engine.sv": None},
    "control_flow_tracker_twin.sby": {CPU + "if_stage/control_flow_tracker.sv": None},
    "pd_target_candidate_twin.sby": {CPU + "if_stage/pd_target_candidate.sv": None},
    "pc_controller_twin.sby": {
        CPU + "if_stage/pc_controller.sv": None,
        CPU + "if_stage/pc_increment_calculator.sv": None,
        CPU + "if_stage/control_flow_tracker.sv": None,
    },
    "branch_predictor_twin.sby": {
        CPU + "if_stage/branch_prediction/branch_predictor.sv": None
    },
    "store_queue_twin.sby": {CPU + "tomasulo/store_queue/store_queue.sv": None},
    "reservation_station_twin.sby": {
        CPU + "tomasulo/reservation_station/reservation_station.sv": None
    },
}

# Blocks with no check, as `file::name` -> why. Remove an entry in the change
# that adds its check.
NOT_COVERED: dict[str, str] = {
    "cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv::u_slot2_staged_uses_ras": "in-context twin does not close (slot-2 relation cones stay unproven); the LUT truth table was checked by hand",
    "cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv::u_slot2_candidate": "in-context twin does not close (slot-2 relation cones stay unproven); the LUT truth table was checked by hand",
    "cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv::u_prediction_metadata_prepare": "its inputs include the slot-2 candidate select above, so the in-context twin does not close",
    "cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv::u_select": "load queue twin leaves FDRE-paired registers unproven and takes over seven minutes",
    "cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv::sq_check_pending_ff": "load queue twin leaves FDRE-paired registers unproven and takes over seven minutes",
    "cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv::sq_check_idx_ff": "load queue twin leaves FDRE-paired registers unproven and takes over seven minutes",
    "cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv::cs_inval_ff": "load queue twin leaves FDRE-paired registers unproven and takes over seven minutes",
    "cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv::u_mem_live_valid": "needs the whole Tomasulo wrapper elaborated; its twin did not finish in half an hour",
    "cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv::u_int_issue_valid_0": "needs the whole Tomasulo wrapper elaborated; its twin did not finish in half an hour",
    "cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv::u_tag": "needs the whole Tomasulo wrapper elaborated; its twin did not finish in half an hour",
    "cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv::u_zero": "needs the whole Tomasulo wrapper elaborated; its twin did not finish in half an hour",
    "cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv::u_allow": "needs the whole Tomasulo wrapper elaborated; its twin did not finish in half an hour",
    "soc_top/soc_top.sv::mmio_read_data_ff": "needs the whole SoC elaborated; an enable flop with reset tied low",
}

# Guards that instantiate no primitive: module attributes, INIT localparams and
# the selection of an XPM memory. They have no portable twin to compare.
NON_LOGIC: dict[str, str] = {
    'cpu_and_mem/cpu/ex_stage/fpu/fp_engine.sv::nonlogic:(* keep_hierarchy = "yes" *)': "module attribute under the macro",
    "cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv::nonlogic:localparam logic [63:0] LateSelRegInit = 64'hff1": "INIT constants used by the covered LUT blocks",
    'cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv::nonlogic:(* keep_hierarchy = "yes" *)': "module attribute under the macro",
    'cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv::nonlogic:(* keep_hierarchy = "yes" *)#2': "module attribute under the macro",
    'cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv::nonlogic:(* keep_hierarchy = "yes" *)': "module attribute under the macro",
    'cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv::nonlogic:(* keep = "true" *) logic [DEPTH-1:0] sq_sent_la': "signal declaration used by the covered LUT blocks",
    'cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv::nonlogic:(* keep_hierarchy = "yes" *)': "module attribute under the macro",
    'lib/cache/coherence_l1d.sv::nonlogic:(* extract_enable = "no", extract_reset = "yes",': "register attributes under the macro",
    'lib/cache/coherence_read_select.sv::nonlogic:(* keep_hierarchy = "yes" *)': "module attribute under the macro",
    "lib/ram/sdp_packed_tag_uram.sv::nonlogic:`ifdef FROST_VIVADO_SYNTH": "selects an XPM RAM only in Vivado synthesis; no portable twin",
    "lib/ram/sdp_ram_byte_en.sv::nonlogic:`ifdef FROST_VIVADO_SYNTH": "selects an XPM RAM only in Vivado synthesis; no portable twin",
}


def arms(text: str) -> list[tuple[int, str]]:
    """Return (line, primitive arm text) for each FROST_XILINX_PRIMS block."""
    lines = text.split("\n")
    found: list[tuple[int, str]] = []
    index = 0
    while index < len(lines):
        match = CONDITIONAL.match(lines[index])
        if not match:
            index += 1
            continue
        negated = match.group(1) == "ifndef"
        depth = 1
        first: list[str] = [match.group(2)]
        second: list[str] = []
        current = first
        has_else = False
        scan = index + 1
        while scan < len(lines) and depth:
            line = lines[scan]
            if NESTED.match(line):
                depth += 1
            elif ENDIF.match(line):
                depth -= 1
                if not depth:
                    break
            elif depth == 1 and ELSE.match(line):
                current = second
                has_else = True
                scan += 1
                continue
            current.append(line)
            scan += 1
        # An ifndef with no else is portable-only text; its primitive arm is
        # a separate ifdef block.
        if not negated or has_else:
            found.append((index + 1, "\n".join(second if negated else first)))
        index = scan + 1
    return found


def code_lines(arm: str) -> list[str]:
    """Return the arm's lines without comments and blanks."""
    kept = []
    for raw in arm.split("\n"):
        line = re.sub(r"//.*", "", raw).strip()
        if line:
            kept.append(line)
    return kept


def instance_name(arm: str) -> str | None:
    """Return the first primitive instance's name, or None."""
    text = re.sub(r"//.*", "", arm)
    text = re.sub(r"\(\*.*?\*\)", "", text, flags=re.S)
    match = PRIMITIVE.search(text)
    if not match:
        return None
    position = match.end()
    while text[position].isspace():
        position += 1
    if text[position] == "#":
        position = text.index("(", position)
        depth = 0
        while True:
            depth += (text[position] == "(") - (text[position] == ")")
            position += 1
            if not depth:
                break
    name = re.match(r"\s*(\w+)", text[position:])
    return name.group(1) if name else None


def blocks_of(path: Path) -> list[str]:
    """Return the block names of one file, in order."""
    names: list[str] = []
    for _, arm in arms(path.read_text()):
        name = instance_name(arm)
        if name is None:
            body = code_lines(arm)
            name = "nonlogic:" + (" ".join(body[0].split())[:48] if body else "empty")
        count = sum(1 for earlier in names if earlier.split("#")[0] == name)
        names.append(name if not count else f"{name}#{count + 1}")
    return names


def rtl_blocks() -> dict[str, list[str]]:
    """Return {relative path: block names} for every RTL file with blocks."""
    result = {}
    for path in sorted(RTL.rglob("*.sv")):
        if MACRO in path.read_text():
            names = blocks_of(path)
            if names:
                result[str(path.relative_to(RTL))] = names
    return result


def covered(file: str, name: str) -> bool:
    """Whether a registered check covers this block."""
    if name.startswith("nonlogic:"):
        return False
    for files in COVERAGE.values():
        if file not in files:
            continue
        names = files[file]
        if names is None or name.split("#")[0] in names:
            return True
    return False


def test_every_primitive_block_has_a_check() -> None:
    """A new block needs a formal comparison, or an allowlist entry and reason."""
    missing = []
    for file, names in rtl_blocks().items():
        for name in names:
            key = f"{file}::{name}"
            if not (covered(file, name) or key in NOT_COVERED or key in NON_LOGIC):
                missing.append(key)
    assert not missing, (
        "add a primitive-twin check (see formal/README.md) or an entry in "
        "NOT_COVERED:\n" + "\n".join(missing)
    )


def test_allowlists_have_no_stale_entries() -> None:
    """A block that gained a check or disappeared leaves the allowlists."""
    present = {
        f"{file}::{name}" for file, names in rtl_blocks().items() for name in names
    }
    stale = [key for key in {*NOT_COVERED, *NON_LOGIC} if key not in present]
    assert not stale, "remove from the allowlists:\n" + "\n".join(sorted(stale))
    now_covered = [
        key for key in NOT_COVERED if covered(*key.split("::", 1)) or key in NON_LOGIC
    ]
    assert not now_covered, "already covered or non-logic:\n" + "\n".join(now_covered)
    for key, reason in {**NOT_COVERED, **NON_LOGIC}.items():
        assert len(reason.split()) >= 3, f"give {key} a one-line reason"
    for key in NON_LOGIC:
        assert key.split("::", 1)[1].startswith("nonlogic:"), key


def test_coverage_entries_name_real_blocks() -> None:
    """An instance list that no longer matches the RTL fails instead of passing."""
    blocks = rtl_blocks()
    problems = []
    for sby, files in COVERAGE.items():
        for file, names in files.items():
            if file not in blocks:
                problems.append(f"{sby}: {file} has no primitive block")
                continue
            have = {name.split("#")[0] for name in blocks[file]}
            problems += [
                f"{sby}: {file}::{name}" for name in (names or ()) if name not in have
            ]
    assert not problems, "\n".join(problems)


@pytest.mark.parametrize("sby", sorted(COVERAGE))
def test_covering_file_defines_the_macro(sby: str) -> None:
    """The covering formal file compares the primitive form and is registered."""
    path = FORMAL / sby
    assert path.is_file(), sby
    text = path.read_text()
    assert MACRO in text, f"{sby} never defines {MACRO}"
    assert "xilinx/cells_sim.v" in text, f"{sby} does not read the Xilinx cell models"
    listed = text.split("[files]", 1)[1]
    for file in COVERAGE[sby]:
        assert Path(file).name in listed, f"{sby} does not list {file}"
    assert f'"{sby}"' in RUN_FORMAL.read_text(), f"{sby} is not registered"


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        (
            "`ifdef FROST_XILINX_PRIMS\nLUT6 #(.INIT(64'h1)) u_a (.O(x));\n`endif",
            ["u_a"],
        ),
        (
            '`ifdef FROST_XILINX_PRIMS\n(* dont_touch = "true" *) LUT3 #(.INIT(8\'hca)) '
            "u_a (.O(x));\n`else\nassign x = y;\n`endif",
            ["u_a"],
        ),
        (
            "`ifndef FROST_XILINX_PRIMS\nassign x = y;\n`else\nFDRE q_ff (.Q(q));\n`endif",
            ["q_ff"],
        ),
        (
            "`ifdef FROST_XILINX_PRIMS\nLUT2 #(.INIT(4'h8)) u_a (.O(x));\n`endif\n"
            "`ifdef FROST_XILINX_PRIMS\nLUT2 #(.INIT(4'h8)) u_a (.O(y));\n`endif",
            ["u_a", "u_a#2"],
        ),
        (
            '`ifdef FROST_XILINX_PRIMS\n(* keep_hierarchy = "yes" *)\n`endif\nmodule m;',
            ["nonlogic:"],
        ),
        (
            "`ifdef FROST_XILINX_PRIMS\n`ifdef OTHER\nLUT1 #(.INIT(2'h1)) u_in (.O(x));\n"
            "`endif\n`else\nassign x = 1;\n`endif",
            ["u_in"],
        ),
        ("`ifdef SYNTHESIS\nLUT6 u (.O(x));\n`endif", []),
        ("// `ifdef FROST_XILINX_PRIMS in a comment", []),
    ],
)
def test_block_detection(tmp_path: Path, source: str, expected: list[str]) -> None:
    """The scanner names primitive arms, takes the macro's arm of ifndef, and nests."""
    path = tmp_path / "m.sv"
    path.write_text(source + "\n")
    names = [
        name if not name.startswith("nonlogic:") else "nonlogic:"
        for name in blocks_of(path)
    ]
    assert names == expected

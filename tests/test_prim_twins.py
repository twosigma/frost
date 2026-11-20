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

import sby_config

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "hw/rtl"
FORMAL = ROOT / "formal"
RUN_FORMAL = Path(__file__).with_name("test_run_formal.py")

CPU = "cpu_and_mem/cpu/"
LQ = CPU + "tomasulo/load_queue/load_queue.sv"
MACRO = "FROST_XILINX_PRIMS"
PRIMITIVE = re.compile(r"\b(?:LUT[1-6]|MUXF[789]|FD[RSCP]E|CARRY[48])\b")
DIRECTIVE = re.compile(r"^\s*`(ifdef|ifndef|elsif|else|endif)\b(.*)$")
MACRO_USE = re.compile(rf"^\s*`(?:ifdef|ifndef|elsif)\s+{MACRO}\b")

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
    "coherent_store_pma_twin.sby": {
        CPU + "tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv": ("u_zero", "u_allow")
    },
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
    'cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv::nonlogic:(* keep_hierarchy = "yes" *)': "module attribute under the macro",
    'lib/cache/coherence_l1d.sv::nonlogic:(* extract_enable = "no", extract_reset = "yes",': "register attributes under the macro",
    'lib/cache/coherence_read_select.sv::nonlogic:(* keep_hierarchy = "yes" *)': "module attribute under the macro",
    "lib/ram/sdp_packed_tag_uram.sv::nonlogic:`ifdef FROST_VIVADO_SYNTH": "selects an XPM RAM only in Vivado synthesis; no portable twin",
    "lib/ram/sdp_ram_byte_en.sv::nonlogic:`ifdef FROST_VIVADO_SYNTH": "selects an XPM RAM only in Vivado synthesis; no portable twin",
}


def arms(text: str) -> list[tuple[int, str]]:
    """Return (line, primitive arm text) for each arm where the macro is defined.

    A chain `ifdef MACRO ... else ...` has one such arm, `ifndef MACRO ... else
    ...` has the arms after the first, and `ifdef OTHER ... elsif MACRO ...` has
    the elsif arm. An ifndef without an else yields none: its text is portable
    only, and the primitive arm is a separate ifdef block.
    """
    found: list[tuple[int, int, str]] = []
    # One frame per open conditional: a list of [kind, macro?, start line, lines].
    stack: list[list[list]] = []
    for number, raw in enumerate(text.split("\n"), 1):
        match = DIRECTIVE.match(raw)
        kind = match.group(1) if match else None
        # The line belongs to every enclosing arm; a chain's own directive
        # belongs only to the chains around it.
        closes = kind in ("elsif", "else", "endif")
        for frame in stack[:-1] if closes else stack:
            frame[-1][3].append(raw)
        if kind is None:
            continue
        assert match is not None
        rest = match.group(2)
        if kind in ("ifdef", "ifndef", "elsif"):
            name = re.match(r"\s*(\w+)(.*)", rest)
            condition = name.group(1) if name else ""
            rest = name.group(2) if name else rest
            arm = [kind, condition == MACRO, number, [rest]]
            if kind == "elsif":
                stack[-1].append(arm)
            else:
                stack.append([arm])
        elif kind == "else":
            stack[-1].append(["else", False, number, []])
        else:
            frame = stack.pop()
            for position, arm in enumerate(frame):
                first = frame[0]
                defined = (
                    (position == 0 and first[0] == "ifdef" and first[1])
                    or (arm[0] == "elsif" and arm[1])
                    or (position > 0 and first[0] == "ifndef" and first[1])
                )
                if defined:
                    found.append((arm[2], number, "\n".join(arm[3])))
    found.sort()
    return [(start, body) for start, _, body in found]


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
    for _, arm in arms(sby_config.read_checked_text(path)):
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
        if MACRO in sby_config.read_checked_text(path):
            names = blocks_of(path)
            if names:
                result[str(path.relative_to(RTL))] = names
    return result


def macro_uses_outside_directives() -> list[str]:
    """Return RTL lines that use the macro in a form the scanner does not parse."""
    problems = []
    for path in sorted(RTL.rglob("*.sv*")):
        text = re.sub(
            r"/\*.*?\*/",
            lambda m: "\n" * m.group(0).count("\n"),
            sby_config.read_checked_text(path),
            flags=re.S,
        )
        for number, raw in enumerate(text.split("\n"), 1):
            line = re.sub(r"//.*", "", raw)
            if MACRO in line and not MACRO_USE.match(line):
                problems.append(f"{path.relative_to(RTL)}:{number}: {raw.strip()}")
    return problems


def covered(file: str, name: str) -> bool:
    """Whether a registered check covers this block."""
    if name.startswith("nonlogic:"):
        return False
    for files in COVERAGE.values():
        if file not in files:
            continue
        names = files[file]
        if names is None or name in names:
            return True
    return False


def test_every_macro_use_is_a_parsed_directive() -> None:
    """A form like `if defined(...)` would hide a block from the scanner."""
    assert not macro_uses_outside_directives()


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
            have = set(blocks[file])
            problems += [
                f"{sby}: {file}::{name}" for name in (names or ()) if name not in have
            ]
    assert not problems, "\n".join(problems)


def reads_with_macro(args: list[str], filename: str) -> bool:
    """Report whether a read command reads filename with MACRO defined on it."""
    if not args or args[0] not in ("read", "read_verilog", "read_slang"):
        return False
    if args[0] == "read" and "-define" in args:
        return False
    defines: set[str] = set()
    sources: set[str] = set()
    index = 1
    while index < len(args):
        word = args[index]
        if word == "-D" and index + 1 < len(args):
            defines.add(args[index + 1].split("=", 1)[0])
            index += 2
            continue
        if word in ("-I", "--top", "-top", "-G") and index + 1 < len(args):
            index += 2
            continue
        if word.startswith("-D") and len(word) > 2:
            defines.add(word[2:].split("=", 1)[0])
        elif not word.startswith("-"):
            sources.add(word)
        index += 1
    return MACRO in defines and filename in sources


_SV_MODULE = re.compile(
    r"\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_]*)\b(.*?)\bendmodule\b",
    re.S,
)
_SV_IDENT = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")


def _sv_module_refs(path: Path) -> dict[str, set[str]]:
    """Return {module_name: referenced_identifiers} for each module in path."""
    clean = re.sub(r"/\*.*?\*/", " ", sby_config.read_checked_text(path), flags=re.S)
    clean = re.sub(r"//[^\n]*", " ", clean)
    clean = re.sub(r'"(?:\\.|[^"\\])*"', '""', clean)
    return {
        match[1]: set(_SV_IDENT.findall(match[2])) - {match[1]}
        for match in _SV_MODULE.finditer(clean)
    }


def _resolve_sv_path(
    name: str, files: dict[str, str] | None, base_dir: Path
) -> Path | None:
    """Resolve a read source basename to its file path."""
    if files is not None:
        rel = files.get(name)
        if rel is None:
            return None
        candidate = base_dir / rel
        return candidate if candidate.is_file() else None
    direct = base_dir / name
    if direct.is_file():
        return direct
    matches = list(RTL.rglob(name))
    return matches[0] if len(matches) == 1 else None


def covers_with_models(
    commands: list[list[str]],
    filename: str,
    files: dict[str, str] | None = None,
    base_dir: Path = FORMAL,
) -> bool:
    """Report whether a retained or compared top keeps a module from filename with MACRO."""
    has_models = False
    macro_files: set[str] = set()
    read_files: list[str] = []
    current_top: str | None = None
    current_retained = False
    saved: dict[str, tuple[str | None, bool]] = {}
    copied_modules: set[str] = set()
    compared_in_script = False

    def elaborate(top: str) -> bool:
        mod_file: dict[str, str] = {}
        mod_refs: dict[str, set[str]] = {}
        for source_name in read_files:
            disk = _resolve_sv_path(source_name, files, base_dir)
            if disk is None:
                continue
            for mod_name, refs in _sv_module_refs(disk).items():
                mod_file[mod_name] = source_name
                mod_refs[mod_name] = refs
        if top not in mod_file:
            return False
        reachable = {top}
        stack = [top]
        while stack:
            cur = stack.pop()
            for callee in mod_refs.get(cur, set()) & mod_file.keys():
                if callee not in reachable:
                    reachable.add(callee)
                    stack.append(callee)
        return (
            has_models
            and filename in macro_files
            and any(mod_file[mod] == filename for mod in reachable)
        )

    for args in commands:
        if args[:2] == ["design", "-reset"]:
            has_models = False
            macro_files = set()
            read_files = []
            current_top = None
            current_retained = False
            copied_modules = set()
        elif args[:2] == ["design", "-save"] and len(args) == 3:
            saved[args[2]] = (current_top, current_retained)
        elif args[:2] == ["design", "-stash"] and len(args) == 3:
            saved[args[2]] = (current_top, current_retained)
            has_models = False
            macro_files = set()
            read_files = []
            current_top = None
            current_retained = False
            copied_modules = set()
        elif args[:2] == ["design", "-load"] and len(args) == 3:
            current_top, current_retained = saved.get(args[2], (None, False))
            copied_modules = set()
        elif args[:2] == ["design", "-delete"] and len(args) == 3:
            saved.pop(args[2], None)
        elif args[0] == "design" and "-copy-from" in args:
            slot = args[args.index("-copy-from") + 1]
            dst = args[args.index("-as") + 1]
            src_mod = args[-1]
            saved_top, saved_ok = saved.get(slot, (None, False))
            if saved_ok and saved_top == src_mod:
                copied_modules.add(dst)
        elif args[0] == "rename" and "-top" in args:
            if current_top is not None:
                current_top = args[args.index("-top") + 1]
        elif args[0] in ("hierarchy", "prep") and "-top" in args:
            top = args[args.index("-top") + 1]
            if current_top is None or read_files:
                current_top = top
                if read_files:
                    current_retained = elaborate(top)
        elif args[0] == "equiv_make" and len(args) == 4:
            if {args[1], args[2]} & copied_modules:
                compared_in_script = True
        elif args == ["read_verilog", "-formal", "+/xilinx/cells_sim.v"]:
            has_models = True
        elif (
            args[0] in ("read", "read_verilog", "read_slang") and "-define" not in args
        ):
            idx = 1
            while idx < len(args):
                word = args[idx]
                if word in ("-D", "-I", "--top", "-top", "-G"):
                    idx += 2
                    continue
                if not word.startswith("-") and word != "+/xilinx/cells_sim.v":
                    read_files.append(word)
                idx += 1
            if reads_with_macro(args, filename):
                macro_files.add(filename)
    return compared_in_script or current_retained


@pytest.mark.parametrize("sby", sorted(COVERAGE))
def test_covering_file_defines_the_macro(sby: str) -> None:
    """The covering formal file retains each covered module with MACRO and models."""
    path = FORMAL / sby
    assert path.is_file(), sby
    configs = sby_config.resolved(path)
    tasks = [(cfg.commands(path.parent), cfg.files) for cfg in configs.values()]
    listed = {dest for _, files in tasks for dest in files}
    for file in COVERAGE[sby]:
        filename = Path(file).name
        assert filename in listed, f"{sby} does not list {file}"
        assert any(
            covers_with_models(commands, filename, files, path.parent)
            for commands, files in tasks
        ), f"{sby} has no task that retains {filename} with models and -D {MACRO}"
    assert f'"{sby}"' in RUN_FORMAL.read_text(), f"{sby} is not registered"


@pytest.mark.parametrize(
    ("line", "parsed"),
    [
        ("`ifdef FROST_XILINX_PRIMS", True),
        ("  `ifndef FROST_XILINX_PRIMS (* keep_hierarchy *)", True),
        ("`elsif FROST_XILINX_PRIMS", True),
        ("`ifdef FROST_XILINX_PRIMS_OTHER", False),
        ("`if defined(FROST_XILINX_PRIMS)", False),
        ("`ifdef (A && FROST_XILINX_PRIMS)", False),
    ],
)
def test_directive_forms(line: str, parsed: bool) -> None:
    """Only the forms the scanner understands count as parsed uses of the macro."""
    assert bool(MACRO_USE.match(line)) is parsed


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
        (
            "`ifdef OTHER\nassign x = 1;\n`elsif FROST_XILINX_PRIMS\n"
            "LUT1 #(.INIT(2'h1)) u_e (.O(x));\n`endif",
            ["u_e"],
        ),
        (
            "`ifndef FROST_XILINX_PRIMS\nassign x = y;\n`elsif OTHER\n"
            "LUT1 #(.INIT(2'h1)) u_b (.O(x));\n`else\nLUT1 #(.INIT(2'h1)) u_c (.O(x));\n`endif",
            ["u_b", "u_c"],
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


def test_commented_macro_does_not_count(tmp_path: Path) -> None:
    """A commented-out primitive read leaves a script without the primitive form."""
    path = tmp_path / "commented.sby"
    path.write_text(
        "[tasks]\nbmc_xilinx\n[options]\nmode bmc\ndepth 1\n[engines]\nsmtbmc boolector\n[script]\n"
        "# read_verilog -formal +/xilinx/cells_sim.v\n"
        "# read -formal -D FROST_XILINX_PRIMS -sv top.sv\n"
        "read -formal -sv top.sv\nprep -top top\n[files]\ntop.sv\n"
    )
    (tmp_path / "top.sv").write_text("module top;\nendmodule\n")
    (cfg,) = sby_config.resolved(path).values()
    commands = cfg.commands(path.parent)
    assert not covers_with_models(commands, "top.sv")
    assert reads_with_macro(["read", "-formal", "-D", MACRO, "-sv", "top.sv"], "top.sv")
    assert reads_with_macro(
        ["read_slang", "--top", "top", "--single-unit", f"-D{MACRO}=1", "top.sv"],
        "top.sv",
    )


@pytest.mark.parametrize(
    ("script_body", "covered"),
    [
        # Macro defined after reading the covered file.
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "read -formal -sv top.sv\n"
            "verilog_defines -DFROST_XILINX_PRIMS\n"
            "prep -top top\n",
            False,
        ),
        # Persistent define instead of -D on the read command itself.
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "read -define FROST_XILINX_PRIMS\n"
            "read -formal -sv top.sv\n"
            "prep -top top\n",
            False,
        ),
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "verilog_defines -D FROST_XILINX_PRIMS\n"
            "read -formal -sv top.sv\n"
            "prep -top top\n",
            False,
        ),
        # Macro defined on a different file's read command.
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "read -formal -D FROST_XILINX_PRIMS -sv pkg.sv\n"
            "read -formal -sv top.sv\n"
            "prep -top top\n",
            False,
        ),
        # Primitive models cleared by design -reset before reading top.sv.
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "design -reset\n"
            "read -formal -D FROST_XILINX_PRIMS -sv top.sv\n"
            "prep -top top\n",
            False,
        ),
        # Primitive design discarded by design -reset instead of handed to solver.
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "read -formal -D FROST_XILINX_PRIMS -sv top.sv\n"
            "design -reset\n"
            "read -formal -sv top.sv\n"
            "prep -top top\n",
            False,
        ),
        # Covered file read with MACRO, then dropped by hierarchy -top on another module.
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "read -formal -D FROST_XILINX_PRIMS -sv top.sv unused.sv\n"
            "hierarchy -top unused\n"
            "prep -top unused\n",
            False,
        ),
        # Stashed primitive top copied under an uncompared module name.
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "read -formal -D FROST_XILINX_PRIMS -sv top.sv\n"
            "prep -top top\n"
            "rename -top gate\n"
            "design -stash gate\n"
            "read -formal -sv unused.sv\n"
            "prep -top unused\n"
            "design -copy-from gate -as sideline gate\n"
            "equiv_make unused unused equiv\n",
            False,
        ),
        # Valid primitive coverage read.
        (
            "read_verilog -formal +/xilinx/cells_sim.v\n"
            "read -formal -D FROST_XILINX_PRIMS -sv top.sv\n"
            "prep -top top\n",
            True,
        ),
    ],
)
def test_macro_must_be_on_covered_file_read(
    tmp_path: Path, script_body: str, covered: bool
) -> None:
    """Require -D FROST_XILINX_PRIMS on a retained or compared module read."""
    (tmp_path / "pkg.sv").write_text("package pkg;\nendpackage\n")
    (tmp_path / "top.sv").write_text("module top;\nendmodule\n")
    (tmp_path / "unused.sv").write_text("module unused;\nendmodule\n")
    path = tmp_path / "case.sby"
    path.write_text(
        "[tasks]\nbmc_xilinx\n[options]\nmode bmc\ndepth 1\n[engines]\nsmtbmc boolector\n[script]\n"
        + script_body
        + "[files]\npkg.sv\ntop.sv\nunused.sv\n"
    )
    (cfg,) = sby_config.resolved(path).values()
    assert (
        covers_with_models(cfg.commands(tmp_path), "top.sv", cfg.files, tmp_path)
        is covered
    )
    read_select_cfg = sby_config.resolved(FORMAL / "coherence_control.sby")[
        "coh_read_select_xilinx_prove"
    ]
    read_select_cmds = read_select_cfg.commands(FORMAL)
    assert covers_with_models(read_select_cmds, "coherence_read_select.sv")
    assert not covers_with_models(read_select_cmds, "coherence_d_arbiter.sv")

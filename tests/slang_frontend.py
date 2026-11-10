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
#
# Filelist expansion is adapted from the original frontend checker.
# Copyright 2026 John Goodacre

"""Strict yosys-slang elaboration shared by CI, fast checks, and the manual hook.

Run inside the pinned FROST image. The matrix compiles the full AST;
additional default-top smoke cases import RTLIL with initial blocks omitted. This is
an elaboration check, not a replay of SymbiYosys transformations or solvers.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import shlex
import shutil
import subprocess
import tempfile
import time
from collections import defaultdict
from dataclasses import dataclass, replace
from pathlib import Path
from typing import TypedDict

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT_SECONDS = 60
UNROLL_LIMIT = 1 << 24
WARNING_ERRORS = (
    "implicit-net",
    "port-width-expand",
    "port-width-trunc",
    "width-trunc",
    "inferred-latch",
    "case-overlap",
    "case-incomplete",
    "unconnected-input-port",
    "shift-count-overflow",
)
PRIMITIVES = ROOT / "tests/slang/xilinx_primitives.sv"


@dataclass(frozen=True)
class ReadUnit:
    """One Yosys read command, with its independent macro environment."""

    options: tuple[str, ...]
    sources: tuple[str, ...]


@dataclass(frozen=True)
class SlangCase:
    """An elaboration top, source units, and final-top parameter overrides."""

    name: str
    top: str
    units: tuple[ReadUnit, ...]
    parameters: tuple[tuple[str, str], ...] = ()
    abstracts: tuple[str, ...] = ()
    tasks: tuple[str, ...] = ()
    ast_only: bool = True


def expand_filelist(filelist: Path, root: Path = ROOT) -> list[str]:
    """Expand nested FROST lists, preserving the first occurrence of each entry."""
    entries: list[str] = []
    seen: set[str] = set()
    active: set[Path] = set()

    def read(path: Path) -> None:
        path = path.resolve()
        if path in active:
            raise ValueError(f"recursive filelist: {path}")
        active.add(path)
        for raw in path.read_text().splitlines():
            line = (
                raw.split("//")[0].split("#")[0].strip().replace("$(ROOT)", str(root))
            )
            if not line:
                continue
            if line.startswith("-f "):
                nested = Path(line[3:].strip())
                read(nested if nested.is_absolute() else path.parent / nested)
                continue
            if line.startswith("+incdir+"):
                line = "-I" + line[len("+incdir+") :]
            if line not in seen:
                seen.add(line)
                entries.append(line)
        active.remove(path)

    read(filelist)
    return entries


def top_cases(root: Path = ROOT) -> list[SlangCase]:
    """Both default tops in synthesis/simulation and all primitive/SRAM combinations."""
    cases = []
    for simulation in (False, True):
        for xilinx, sram, variant in (
            (False, False, "generic"),
            (True, False, "xilinx"),
            (False, True, "sram"),
            (True, True, "both"),
        ):
            for top, filelist in (
                ("cpu_top", "hw/rtl/cpu_top/cpu_top.f"),
                ("platform_top", "hw/rtl/frost.f"),
            ):
                entries = expand_filelist(root / filelist, root)
                options = [x for x in entries if x.startswith("-I")]
                if not simulation:
                    options.append("-DSYNTHESIS")
                if xilinx:
                    options.append("-DFROST_XILINX_PRIMS")
                    entries.append(str(root / PRIMITIVES.relative_to(ROOT)))
                if sram:
                    options.append("-DFROST_SRAM_MACROS")
                    entries += [
                        str(p)
                        for p in sorted((root / "asic/sram").glob("frost_sram_*.sv"))
                    ]
                    entries += [
                        str(p)
                        for p in sorted((root / "asic/sram/macros").glob("*/*.v"))
                    ]
                units = (
                    ReadUnit(
                        tuple(options),
                        tuple(x for x in entries if not x.startswith("-I")),
                    ),
                )
                view = "simulation" if simulation else "synthesis"
                cases.append(SlangCase(f"{view}/{variant}/{top}", top, units))
    return cases


# Additional simulation roots alongside the complete CPU/platform views.
SIMULATION_MODULES = (
    "misprediction_flush_controller",
    "frontend_validity_tracker",
    "cached_tier_adapter",
    "data_mem_request_router",
    "csr_file",
    "immu",
    "branch_predictor",
    "if_stage",
    "pc_controller",
    "pd_stage",
    "load_queue",
    "coherence_l1d",
    "lq_l0_cache",
    "reorder_buffer",
    "debug_module",
    "fetch_provider",
    "cpu_memory_fabric",
    "axi_behavioral_memory",
    "frost_cache",
    "line_port_arbiter",
    "aplic",
    "nic_csr",
)


def simulation_module_cases() -> list[SlangCase]:
    """Gate additional module roots alongside the complete CPU/platform views."""
    cases = []
    for base in top_cases():
        if not base.name.startswith("simulation/") or base.top != "platform_top":
            continue
        variant = base.name.split("/")[1]
        cases += [
            replace(base, name=f"simulation-module/{variant}/{top}", top=top)
            for top in SIMULATION_MODULES
        ]
    return cases


def _sections(path: Path) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = defaultdict(list)
    section = ""
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        elif line:
            sections[section].append(line)
    return sections


def _task_line(line: str, tags: set[str]) -> str:
    if not re.match(r"^~?[A-Za-z0-9_]+:", line):
        return line
    tag, command = line.split(":", 1)
    selected = tag[1:] not in tags if tag.startswith("~") else tag in tags
    return command.strip() if selected else ""


def formal_cases(root: Path = ROOT) -> list[SlangCase]:
    """Extract actual .sby read/define/top views; deduplicate identical inputs.

    Preserve per-read FORMAL/SYNTHESIS and persistent read/verilog_defines
    settings. Replay final-top chparam settings only. Secondary-module
    rewrites, deletes, renames, cutpoints, and solver commands are not replayed.
    Deleted child types get their real typed interface as a black box.
    """
    cases: dict[tuple[object, ...], SlangCase] = {}
    for sby in sorted((root / "formal").glob("*.sby")):
        sections = _sections(sby)
        filemap = {}
        for line in sections["files"]:
            words = shlex.split(line)
            source = (sby.parent / words[-1]).resolve()
            filemap[words[0] if len(words) > 1 else source.name] = source
        includes = tuple(
            "-I" + str(p)
            for p in sorted({sby.parent} | {p.parent for p in filemap.values()})
        )
        for task in sections["tasks"] or ["default"]:
            tags = set(task.split())
            name = task.split()[0]
            persistent: list[str] = []
            units: list[ReadUnit] = []
            parameters: dict[str, dict[str, str]] = defaultdict(dict)
            abstracts: set[str] = set()
            top = ""
            for raw in sections["script"]:
                line = _task_line(raw, tags)
                # Yosys decimal Verilog literals contain a bare apostrophe.
                words = line.split()
                if not words:
                    continue
                if words[0] == "read" and "-define" in words:
                    persistent += [
                        "-D" + v for v in words[words.index("-define") + 1 :]
                    ]
                    continue
                if words[0] == "verilog_defines":
                    i = 1
                    while i < len(words):
                        if words[i] == "-D":
                            persistent.append("-D" + words[i + 1])
                            i += 2
                        elif words[i].startswith("-D"):
                            persistent.append(words[i])
                            i += 1
                        else:
                            raise ValueError(
                                f"{sby}:{name}: unsupported define: {line}"
                            )
                    continue
                if words[0] in ("read", "read_verilog"):
                    options = [
                        "-DYOSYS",
                        *(["-DFORMAL"] if "-formal" in words else []),
                        *(
                            []
                            if "-formal" in words or "-nosynthesis" in words
                            else ["-DSYNTHESIS"]
                        ),
                        *persistent,
                        *includes,
                    ]
                    sources = []
                    i = 1
                    while i < len(words):
                        word = words[i]
                        if word in ("-D", "-I"):
                            options.append(word + words[i + 1])
                            i += 2
                            continue
                        if word.startswith(("-D", "-I")):
                            options.append(word)
                        elif word == "+/xilinx/cells_sim.v":
                            sources.append(str(root / PRIMITIVES.relative_to(ROOT)))
                        elif word in filemap:
                            sources.append(str(filemap[word]))
                        elif word not in (
                            "-formal",
                            "-sv",
                            "-noautowire",
                            "-noblackbox",
                            "-lib",
                            "-nosynthesis",
                        ):
                            raise ValueError(
                                f"{sby}:{name}: unsupported read argument: {word}"
                            )
                        i += 1
                    if sources:
                        units.append(ReadUnit(tuple(options), tuple(sources)))
                elif words[0] == "chparam":
                    for i, word in enumerate(words):
                        if word == "-set":
                            parameters[words[-1]][words[i + 1]] = words[i + 2]
                elif words[0] in ("prep", "hierarchy") and "-top" in words:
                    top = words[words.index("-top") + 1]
                elif words[0] == "delete":
                    abstracts.update(
                        w[2:].lstrip("*")
                        for w in words[1:]
                        if w.startswith("t:") and not w[2:].startswith("$")
                    )
            if not units or not top:
                raise ValueError(f"{sby}:{name}: missing read sets or top")
            case = SlangCase(
                f"formal/{sby.stem}/{name}",
                top,
                tuple(units),
                tuple(sorted(parameters[top].items())),
                tuple(sorted(abstracts)),
                (f"{sby.name}:{name}",),
            )
            key = (case.top, case.units, case.parameters, case.abstracts)
            if key in cases:
                cases[key] = replace(cases[key], tasks=cases[key].tasks + case.tasks)
            else:
                cases[key] = case
    return list(cases.values())


class SlangResult(TypedDict):
    """One complete frontend outcome, without filtered errors."""

    name: str
    tasks: tuple[str, ...]
    returncode: int
    seconds: float
    errors: list[str]
    output: str


def run_case(case: SlangCase, yosys: str = "yosys") -> SlangResult:
    """Run the pinned frontend; every nonzero exit fails, with no error waivers."""
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="frost-slang-") as directory:
        temp = Path(directory)
        options = [
            "--error-limit=0",
            f"--unroll-limit={UNROLL_LIMIT}",
            "--no-synthesis-define",
            "--top",
            case.top,
        ]
        # These promotions were audited for production tops. Proof harnesses
        # deliberately use partial ports and narrow abstract geometries.
        if case.name.startswith(("synthesis/", "lower/")):
            options += ["-Werror=" + group for group in WARNING_ERRORS]
        if case.ast_only:
            options.append("--ast-compilation-only")
        else:
            # Import RTLIL processes without the much more expensive proc pass.
            options += ["--no-proc", "--best-effort-hierarchy", "--ignore-initial"]
        if case.tasks:
            options += ["--define-system-task", "function bit $initstate()"]
        if case.top == "async_fifo":
            # Yosys supplies $global_clock. Slang requires a standard global
            # clocking scope, so give the unchanged DUT a containing scope.
            wrapper = temp / "global_clock.sv"
            parameters = ", ".join(f".{k}({v})" for k, v in case.parameters)
            wrapper.write_text(
                "module frost_slang_global_clock;\nlogic clk;\n"
                "global clocking @(posedge clk); endclocking\n"
                f"async_fifo #({parameters}) dut ();\nendmodule\n"
            )
            options[options.index("--top") + 1] = "frost_slang_global_clock"
            options.append(str(wrapper))
        for name, value in () if case.top == "async_fifo" else case.parameters:
            if value.isdigit() and int(value) > 2147483647:
                value = "64'd" + value
            options.append(f"-G{name}={value}")
        for i, unit in enumerate(case.units):
            if not case.tasks:
                options += [*unit.options, *unit.sources]
                continue
            path = temp / f"unit{i}.f"
            path.write_text(shlex.join((*unit.options, *unit.sources)) + "\n")
            options += ["-C", str(path)]
        for module in case.abstracts:
            sources = list((ROOT / "hw/rtl").rglob(module + ".sv"))
            if len(sources) != 1:
                raise ValueError(
                    f"{case.name}: cannot resolve abstracted module {module}"
                )
            # The proof deletes this type. Use its actual parameter/port types
            # while leaving its implementation outside this read-set check.
            options += ["--blackboxed-module", module]
            if not any(str(sources[0]) in u.sources for u in case.units):
                # A typed empty module avoids elaborating dependencies of a
                # proof's deliberately removed child in compiler-only mode.
                source = re.sub(
                    r"/\*.*?\*/|//[^\n]*", "", sources[0].read_text(), flags=re.S
                )
                start = source.index("module " + module)
                end = source.index(";", start) + 1
                interface = temp / (module + ".sv")
                interface.write_text(source[start:end] + "\nendmodule\n")
                options.append(str(interface))
        command_file = temp / "options.f"
        command_file.write_text(shlex.join(options) + "\n")
        script = "read_slang -f " + str(command_file)
        if not case.ast_only:
            script += "; stat"
        result = subprocess.run(
            [yosys, "-Q", "-T", "-p", script],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
        output = result.stdout + result.stderr
        errors = sorted(
            {line for line in output.splitlines() if re.search(r"\berror:", line, re.I)}
        )
        if result.returncode and not errors:
            errors = [f"yosys exited with status {result.returncode}", output[-3000:]]
        return {
            "name": case.name,
            "tasks": case.tasks,
            "returncode": result.returncode,
            "seconds": time.monotonic() - started,
            "errors": errors,
            "output": output,
        }


def check(
    *,
    patterns: list[str] | None = None,
    report: Path | None = None,
    include_deferred: bool = False,
    lower: bool = False,
) -> int:
    """Run selected cases; missing Yosys/read_slang is a hard failure."""
    yosys = shutil.which("yosys")
    if yosys is None:
        raise RuntimeError(
            "yosys is missing; run through ./scripts/frost.py in the FROST image"
        )
    cases = top_cases() + simulation_module_cases() + formal_cases()
    cases += [
        replace(c, name=c.name.replace("synthesis/", "lower/"), ast_only=False)
        for c in top_cases()
        if c.name.startswith("synthesis/generic/")
    ]
    deferred = {
        r["name"] for r in json.loads((ROOT / "tests/slang/deferred.json").read_text())
    }
    stale = deferred - {c.name for c in cases}
    if stale:
        raise ValueError(f"stale deferred views: {sorted(stale)}")
    if not include_deferred:
        cases = [c for c in cases if c.name not in deferred]
    if lower:
        cases = [replace(c, ast_only=False) for c in cases]
    if patterns:
        cases = [
            c for c in cases if any(fnmatch.fnmatchcase(c.name, p) for p in patterns)
        ]
    if not cases:
        raise ValueError("no slang cases selected")
    results = []
    for case in cases:
        result = run_case(case, yosys)
        results.append(result)
        if result["returncode"] or result["errors"]:
            print(f"{case.name}: FAILED", flush=True)
            print("\n".join(result["errors"]), flush=True)
    if report:
        report.write_text(json.dumps(results, indent=2) + "\n")
    failures = sum(bool(r["returncode"] or r["errors"]) for r in results)
    seconds = sum(float(r["seconds"]) for r in results)
    print(
        f"yosys-slang: {len(results) - failures}/{len(results)} cases passed in {seconds:.2f}s; {len(deferred)} deferred views",
        flush=True,
    )
    return int(failures != 0)


def main() -> int:
    """Run the shared checker CLI with optional case selection and JSON evidence."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", help="case glob (repeatable)")
    parser.add_argument(
        "--include-deferred",
        action="store_true",
        help="also check the explicitly deferred views",
    )
    parser.add_argument(
        "--lower", action="store_true", help="also import RTLIL for selected cases"
    )
    parser.add_argument(
        "--report",
        type=Path,
        help="write per-case diagnostics and elapsed times as JSON",
    )
    args = parser.parse_args()
    try:
        return check(
            patterns=args.case,
            report=args.report,
            include_deferred=args.include_deferred,
            lower=args.lower,
        )
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"yosys-slang: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

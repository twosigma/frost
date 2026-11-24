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

"""Verify selective VPI visibility, bench path coverage, retirement trace gating, and thread caps."""

from __future__ import annotations

import ast
import asyncio
import fnmatch
import functools
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from types import SimpleNamespace

import pytest
import yaml  # type: ignore[import-untyped]

ROOT = Path(__file__).resolve().parents[1]
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
VISIBILITY_FILE = ROOT / "hw" / "sim" / "frost_cocotb_visibility.vlt"
REORDER_BUFFER_SV = (
    ROOT
    / "hw"
    / "rtl"
    / "cpu_and_mem"
    / "cpu"
    / "tomasulo"
    / "reorder_buffer"
    / "reorder_buffer.sv"
)
RULE_RE = re.compile(
    r'^(public_flat_rw|public_flat_rd)\s+-module\s+"([^"]+)"\s+-var\s+"([^"]+)"$'
)
MOD_RE = re.compile(r"\b(module|interface)\s+(?:automatic\s+|static\s+)?([A-Za-z_]\w*)")
END_RE = re.compile(r"\bend(module|interface)\b")
DOTTED_PATH_RE = re.compile(
    r"^[A-Za-z_]\w*(?:\[\d+\])?(?:\.[A-Za-z_]\w*(?:\[\d+\])?)+$"
)
ANY_SIGNAL_PATH_RE = re.compile(
    r"^[A-Za-z_]\w*(?:\[\d+\])?(?:\.[A-Za-z_]\w*(?:\[\d+\])?)*$"
)
MAX_LOG_READ_BYTES = 1024 * 1024

SV_KEYWORDS = frozenset(
    """
    always always_comb always_ff always_latch assign begin end if else for foreach
    while case casez casex endcase generate endgenerate genvar localparam parameter
    input output inout wire reg logic bit int integer function endfunction task
    endtask module endmodule return typedef struct union enum packed signed unsigned
    initial final assert assume cover property sequence default posedge negedge or
    and not import export package endpackage var automatic static const string real
    realtime time unique priority void modport interface endinterface do break
    continue forever repeat disable fork join join_any join_none wait
    """.split()
)

COCOTB_HANDLE_ATTRS = frozenset(
    {
        "append",
        "value",
        "_name",
        "_path",
        "_handle",
        "_log",
        "_type",
        "_def_name",
        "_def_file",
        "setimmediatevalue",
        "_discover_all",
        "_sub_handles",
        "_get",
        "_id",
        "_keys",
        "_items",
        "_values",
        "is_resolvable",
        "integer",
        "signed_integer",
        "binstr",
    }
)

NON_SIGNAL_EXTENSIONS = frozenset(
    {
        "S",
        "bin",
        "cfg",
        "elf",
        "fst",
        "gdb",
        "json",
        "jsonl",
        "log",
        "mem",
        "py",
        "sv",
        "txt",
        "v",
    }
)

FROST_PLATFORMS = ("platform_top", "frost_rvfi_platform")
SHARED_ALT_TOPS = ("cpu_tb", "soc_top")


def _strip_sv_comments_and_strings(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', text)


def _skip_balanced_parens(text: str, start: int) -> int:
    depth = 0
    idx = start
    length = len(text)
    while idx < length:
        ch = text[idx]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return idx + 1
        idx += 1
    return length


@functools.cache
def build_rtl_hierarchy() -> dict[str, dict[str, object]]:
    """Parse RTL modules, child instances, generate scopes, and declared identifiers."""
    modules: dict[str, dict[str, object]] = {}
    for subdir in ("hw", "asic", "verif"):
        base = ROOT / subdir
        for ext in ("*.sv", "*.v", "*.svh"):
            for path in base.rglob(ext):
                raw = path.read_text(encoding="utf-8", errors="replace")
                cleaned = _strip_sv_comments_and_strings(raw)
                pos = 0
                while True:
                    match = MOD_RE.search(cleaned, pos)
                    if match is None:
                        break
                    mod_name = match.group(2)
                    end_match = END_RE.search(cleaned, match.end())
                    body_end = end_match.start() if end_match else len(cleaned)
                    body = cleaned[match.end() : body_end]
                    pos = end_match.end() if end_match else len(cleaned)
                    entry = modules.setdefault(
                        mod_name,
                        {"inst": {}, "gen": set(), "idents": set(), "bodies": []},
                    )
                    entry["bodies"].append(body)  # type: ignore[attr-defined]

    known_modules = set(modules)
    decl_ident_re = re.compile(r"(?<![.:])\b([A-Za-z_]\w*)\b(?!\s*::)")
    for entry in modules.values():
        inst_map: dict[str, set[str]] = entry["inst"]  # type: ignore[assignment]
        gen_set: set[str] = entry["gen"]  # type: ignore[assignment]
        ident_set: set[str] = entry["idents"]  # type: ignore[assignment]
        for body in entry["bodies"]:  # type: ignore[attr-defined]
            for ident in decl_ident_re.findall(body):
                if ident not in SV_KEYWORDS and ident not in known_modules:
                    ident_set.add(ident)
            for gen_m in re.finditer(r"\bbegin\s*:\s*([A-Za-z_]\w*)", body):
                gen_set.add(gen_m.group(1))
            for gen_m in re.finditer(r"\b([A-Za-z_]\w*)\s*:\s*(?:if|for|case)\b", body):
                gen_set.add(gen_m.group(1))
            for tok in re.finditer(r"\b([A-Za-z_]\w*)\b", body):
                mod_type = tok.group(1)
                if mod_type not in known_modules or mod_type in SV_KEYWORDS:
                    continue
                idx = tok.end()
                while idx < len(body) and body[idx].isspace():
                    idx += 1
                if idx < len(body) and body[idx] == "#":
                    idx += 1
                    while idx < len(body) and body[idx].isspace():
                        idx += 1
                    if idx < len(body) and body[idx] == "(":
                        idx = _skip_balanced_parens(body, idx)
                    else:
                        continue
                    while idx < len(body) and body[idx].isspace():
                        idx += 1
                inst_m = re.match(r"([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*\(", body[idx:])
                if inst_m:
                    inst_name = inst_m.group(1)
                    if inst_name not in SV_KEYWORDS:
                        inst_map.setdefault(inst_name, set()).add(mod_type)
        ident_set.difference_update(inst_map)
        ident_set.difference_update(gen_set)
        del entry["bodies"]
    return modules


@functools.cache
def _scalar_replica_names() -> tuple[str, ...]:
    """Load SCALAR_REPLICA_BITS names from generate_imem_predecode_init.py."""
    script_path = ROOT / "sw" / "common" / "generate_imem_predecode_init.py"
    spec = importlib.util.spec_from_file_location("imem_predecode_init", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return tuple(name for name, _ in module.SCALAR_REPLICA_BITS)


def parse_vlt_rules(vlt_text: str) -> list[tuple[str, str, str, int]]:
    """Parse (directive, module_pattern, var_pattern, line_no) tuples from .vlt text."""
    rules: list[tuple[str, str, str, int]] = []
    for line_no, raw in enumerate(vlt_text.splitlines(), start=1):
        match = RULE_RE.match(raw.strip())
        if match:
            rules.append((match.group(1), match.group(2), match.group(3), line_no))
    return rules


def check_dead_rules(
    modules: dict[str, dict[str, object]],
    rules: list[tuple[str, str, str, int]],
) -> list[str]:
    """Return rules whose -module or -var pattern matches no RTL declaration."""
    dead: list[str] = []
    for directive, mod_pat, var_pat, line_no in rules:
        matched_mods = [m for m in modules if fnmatch.fnmatchcase(m, mod_pat)]
        matched_vars = [
            v
            for m in matched_mods
            for v in modules[m]["idents"]  # type: ignore[attr-defined]
            if fnmatch.fnmatchcase(v, var_pat)
        ]
        if not matched_mods or not matched_vars:
            dead.append(
                f'line {line_no}: {directive} -module "{mod_pat}" -var "{var_pat}"'
            )
    return dead


@functools.cache
def _discover_frost_benches_and_helpers() -> tuple[
    tuple[Path, ...], tuple[tuple[Path, tuple[str, ...]], ...]
]:
    """Find every TOPLEVEL=frost bench and any helpers imported from non-frost tests."""
    tests_dir = str(ROOT / "tests")
    if tests_dir not in sys.path:
        sys.path.insert(0, tests_dir)
    from test_run_cocotb import TEST_REGISTRY

    frost_mods: set[str] = set()
    non_frost_mods: set[str] = set()
    for config in TEST_REGISTRY.values():
        if config.hdl_toplevel_module == "frost":
            frost_mods.add(config.python_test_module)
        else:
            non_frost_mods.add(config.python_test_module)
    frost_mods.add("cocotb_tests.test_random_start_smoke")

    visited: set[str] = set()
    shared_helpers: dict[str, set[str]] = {}
    queue = list(frost_mods)
    while queue:
        mod_name = queue.pop()
        if (
            mod_name in visited
            or (mod_name in non_frost_mods and mod_name not in frost_mods)
            or mod_name in ("cocotb_tests.hang_probe", "config")
            or mod_name.endswith("_interface")
        ):
            continue
        py_path = ROOT / "verif" / (mod_name.replace(".", "/") + ".py")
        if not py_path.is_file():
            continue
        visited.add(mod_name)
        tree = ast.parse(py_path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                target_py = ROOT / "verif" / (node.module.replace(".", "/") + ".py")
                if target_py.is_file():
                    if node.module in non_frost_mods and node.module not in frost_mods:
                        shared_helpers.setdefault(node.module, set()).update(
                            alias.name for alias in node.names if alias.name != "*"
                        )
                    else:
                        queue.append(node.module)
                for alias in node.names:
                    sub = f"{node.module}.{alias.name}"
                    if (ROOT / "verif" / (sub.replace(".", "/") + ".py")).is_file():
                        queue.append(sub)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    if (
                        ROOT / "verif" / (alias.name.replace(".", "/") + ".py")
                    ).is_file():
                        queue.append(alias.name)
    full_files = tuple(
        sorted(ROOT / "verif" / (m.replace(".", "/") + ".py") for m in visited)
    )
    helper_files = tuple(
        sorted(
            (ROOT / "verif" / (m.replace(".", "/") + ".py"), tuple(sorted(names)))
            for m, names in shared_helpers.items()
            if m not in visited and names
        )
    )
    return full_files, helper_files


@functools.cache
def discover_frost_bench_files() -> tuple[Path, ...]:
    """Find every Python bench and helper imported by TOPLEVEL=frost tests."""
    return _discover_frost_benches_and_helpers()[0]


@functools.cache
def discover_frost_shared_helpers() -> tuple[tuple[Path, tuple[str, ...]], ...]:
    """Find helper functions imported by frost benches from non-frost test modules."""
    return _discover_frost_benches_and_helpers()[1]


def resolve_rtl_path(
    modules: dict[str, dict[str, object]], path: str, top: str = "frost"
) -> list[tuple[str, str]]:
    """Resolve a dotted HDL path from `top`; return (module_name, leaf_or_SCOPE) pairs."""
    parts = [re.sub(r"\[[^\]]*\]$", "", p) for p in path.split(".") if p]
    if not parts:
        return []
    states: list[str] = [top]
    for idx, part in enumerate(parts):
        is_last = idx == len(parts) - 1
        next_states: list[str] = []
        leaves: list[tuple[str, str]] = []
        for mod in states:
            ent = modules.get(mod)
            if ent is None:
                continue
            inst_map: dict[str, set[str]] = ent["inst"]  # type: ignore[assignment]
            gen_set: set[str] = ent["gen"]  # type: ignore[assignment]
            ident_set: set[str] = ent["idents"]  # type: ignore[assignment]
            if mod == "frost" and part == "cpu_and_memory_subsystem":
                if is_last:
                    leaves.append((mod, "<SCOPE>"))
                else:
                    next_states.extend(FROST_PLATFORMS)
                continue
            if part in inst_map:
                if is_last:
                    leaves.append((mod, "<SCOPE>"))
                else:
                    next_states.extend(sorted(inst_map[part]))
            elif part in gen_set:
                if is_last:
                    leaves.append((mod, "<SCOPE>"))
                else:
                    next_states.append(mod)
            elif is_last and part in ident_set:
                leaves.append((mod, part))
        if is_last:
            return leaves
        states = list(dict.fromkeys(next_states))
        if not states:
            return []
    return []


@functools.cache
def extract_bench_dut_paths(
    py_path: Path,
    only_functions: tuple[str, ...] | None = None,
) -> tuple[tuple[tuple[int, str, bool], ...], tuple[str, ...]]:
    """Extract (line, path, written) accesses and unresolvable f-string fields."""
    src = py_path.read_text(encoding="utf-8")
    tree = ast.parse(src)
    found: list[tuple[int, str, bool]] = []
    unresolved: set[str] = set()
    hierarchy = build_rtl_hierarchy()
    dut_roots = {"cpu_and_memory_subsystem"}
    for top in ("frost", *FROST_PLATFORMS, *SHARED_ALT_TOPS):
        dut_roots.update(hierarchy[top]["inst"])  # type: ignore[arg-type]
        dut_roots.update(hierarchy[top]["gen"])  # type: ignore[arg-type]

    def _is_frost_toplevel_check(node: ast.AST) -> bool | None:
        if (
            isinstance(node, ast.Compare)
            and len(node.ops) == 1
            and len(node.comparators) == 1
            and isinstance(node.ops[0], (ast.Eq, ast.NotEq))
        ):
            left_src = ast.unparse(node.left)
            right = node.comparators[0]
            if (
                "COCOTB_TOPLEVEL" in left_src
                and isinstance(right, ast.Constant)
                and isinstance(right.value, str)
            ):
                is_eq = isinstance(node.ops[0], ast.Eq)
                return (right.value == "frost") if is_eq else (right.value != "frost")
        return None

    module_bool_consts: dict[str, bool] = {}
    for stmt in tree.body:
        if (
            isinstance(stmt, ast.Assign)
            and len(stmt.targets) == 1
            and isinstance(stmt.targets[0], ast.Name)
        ):
            val_bool = _is_frost_toplevel_check(stmt.value)
            if val_bool is not None:
                module_bool_consts[stmt.targets[0].id] = val_bool

    def _eval_bool_const(node: ast.AST) -> bool | None:
        if isinstance(node, ast.Constant) and isinstance(node.value, bool):
            return node.value
        if isinstance(node, ast.Name) and node.id in module_bool_consts:
            return module_bool_consts[node.id]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            inner = _eval_bool_const(node.operand)
            return None if inner is None else not inner
        return _is_frost_toplevel_check(node)

    def _is_skipped_on_frost(fn: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
        for dec in fn.decorator_list:
            if isinstance(dec, ast.Call) and ast.unparse(dec.func) == "cocotb.test":
                for kw in dec.keywords:
                    if kw.arg == "skip" and _eval_bool_const(kw.value) is True:
                        return True
        return False

    # When auditing a shared non-frost test module, restrict to imported helpers
    # and the local helpers/classes they reference.
    if only_functions is not None:
        top_defs = {
            stmt.name: stmt
            for stmt in tree.body
            if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
        }
        keep_names: set[str] = set()
        fn_queue = [name for name in only_functions if name in top_defs]
        while fn_queue:
            cur = fn_queue.pop()
            if cur in keep_names:
                continue
            keep_names.add(cur)
            for node in ast.walk(top_defs[cur]):
                if (
                    isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Name)
                    and node.func.id in top_defs
                    and node.func.id not in keep_names
                ):
                    fn_queue.append(node.func.id)
        active_body = [
            stmt
            for stmt in tree.body
            if not isinstance(
                stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
            )
            or stmt.name in keep_names
        ]
        tree = ast.Module(body=active_body, type_ignores=[])
    else:
        active_body = [
            stmt
            for stmt in tree.body
            if not (
                isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef))
                and _is_skipped_on_frost(stmt)
            )
        ]
        tree = ast.Module(body=active_body, type_ignores=[])

    module_str_consts: dict[str, set[str]] = {
        "parity": {"even", "odd"},
        "port": {"0", "1"},
        "ep": {"0"},
        "pc_tap": {"dbg_rob_commit_reg_pc", "dbg_rob_commit_2_reg_pc"},
    }
    # Load imported string-tuple constants from local verif/ modules
    # (e.g. `from testrig.wfi import COUNTERS as WFI_COUNTERS`).
    for stmt in tree.body:
        if isinstance(stmt, ast.ImportFrom) and stmt.module:
            mod_py = ROOT / "verif" / (stmt.module.replace(".", "/") + ".py")
            if not mod_py.is_file():
                continue
            mod_tree = ast.parse(mod_py.read_text(encoding="utf-8"))
            wanted = {
                alias.name: (alias.asname or alias.name)
                for alias in stmt.names
                if alias.name != "*"
            }
            for mod_stmt in mod_tree.body:
                if (
                    isinstance(mod_stmt, ast.Assign)
                    and len(mod_stmt.targets) == 1
                    and isinstance(mod_stmt.targets[0], ast.Name)
                    and mod_stmt.targets[0].id in wanted
                    and isinstance(mod_stmt.value, (ast.Tuple, ast.List))
                ):
                    vals = {
                        elt.value
                        for elt in mod_stmt.value.elts
                        if isinstance(elt, ast.Constant) and isinstance(elt.value, str)
                    }
                    if vals:
                        module_str_consts.setdefault(
                            wanted[mod_stmt.targets[0].id], set()
                        ).update(vals)
        elif (
            isinstance(stmt, ast.Assign)
            and len(stmt.targets) == 1
            and isinstance(stmt.targets[0], ast.Name)
            and isinstance(stmt.value, (ast.Tuple, ast.List))
        ):
            vals = {
                elt.value
                for elt in stmt.value.elts
                if isinstance(elt, ast.Constant) and isinstance(elt.value, str)
            }
            if vals:
                module_str_consts.setdefault(stmt.targets[0].id, set()).update(vals)
    class_signal_lists: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef):
            for item in node.body:
                if (
                    isinstance(item, ast.Assign)
                    and len(item.targets) == 1
                    and isinstance(item.targets[0], ast.Name)
                    and item.targets[0].id == "SIGNALS"
                    and isinstance(item.value, (ast.Tuple, ast.List))
                ):
                    vals = {
                        elt.value
                        for elt in item.value.elts
                        if isinstance(elt, ast.Constant) and isinstance(elt.value, str)
                    }
                    if vals:
                        class_signal_lists[node.name] = vals

    def constant_strings(node: ast.AST, env: dict[str, set[str]]) -> set[str]:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return {node.value}
        if isinstance(node, ast.Name):
            return set(env.get(node.id, set()))
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            left = constant_strings(node.left, env)
            right = constant_strings(node.right, env)
            if left and right:
                return {a + b for a in left for b in right}
            return set()
        if isinstance(node, ast.IfExp):
            return constant_strings(node.body, env) | constant_strings(node.orelse, env)
        if isinstance(node, ast.JoinedStr):
            prefixes = {""}
            for value in node.values:
                part = constant_strings(
                    value.value if isinstance(value, ast.FormattedValue) else value,
                    env,
                )
                if not part:
                    return set()
                prefixes = {p + suffix for p in prefixes for suffix in part}
            return prefixes
        return set()

    def _direct_nodes(
        stmts: list[ast.stmt],
    ) -> tuple[list[ast.Assign], list[ast.JoinedStr]]:
        """Collect Assign and JoinedStr nodes directly in `stmts` (skip nested defs)."""
        assigns: list[ast.Assign] = []
        jnodes: list[ast.JoinedStr] = []

        def _walk(node: ast.AST) -> None:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                return
            if isinstance(node, ast.Assign) and len(node.targets) == 1:
                assigns.append(node)
            elif isinstance(node, ast.JoinedStr):
                jnodes.append(node)
            for child in ast.iter_child_nodes(node):
                _walk(child)

        for stmt in stmts:
            _walk(stmt)
        return assigns, jnodes

    def _propagate_str_assigns(
        assigns: list[ast.Assign], env: dict[str, set[str]]
    ) -> None:
        for _ in range(len(assigns) + 1):
            changed_constants = False
            for assignment in assigns:
                target, value = assignment.targets[0], assignment.value
                bindings = (
                    list(zip(target.elts, value.elts))
                    if isinstance(target, ast.Tuple) and isinstance(value, ast.Tuple)
                    else [(target, value)]
                )
                for target, value in bindings:
                    if isinstance(target, ast.Name):
                        values = constant_strings(value, env)
                        if not values:
                            continue
                        known = env.setdefault(target.id, set())
                        if not values.issubset(known):
                            known.update(values)
                            changed_constants = True
            if not changed_constants:
                break

    mod_assigns, _ = _direct_nodes(tree.body)
    _propagate_str_assigns(mod_assigns, module_str_consts)

    # Scope local string constants per function/method to avoid cross-function
    # collisions (e.g. two functions binding different `base` prefixes).
    fstr_vars: dict[int, dict[str, set[str]]] = {}
    scope_str_consts: dict[int, dict[str, set[str]]] = {}

    def _build_str_scopes(
        stmts: list[ast.stmt],
        parent_env: dict[str, set[str]],
        cls_name: str = "",
    ) -> None:
        for stmt in stmts:
            if isinstance(stmt, ast.ClassDef):
                cls_env = {k: set(v) for k, v in parent_env.items()}
                if stmt.name in class_signal_lists:
                    cls_env["name"] = set(class_signal_lists[stmt.name])
                cls_assigns, cls_jnodes = _direct_nodes(stmt.body)
                _propagate_str_assigns(cls_assigns, cls_env)
                for jn in cls_jnodes:
                    fstr_vars[id(jn)] = {k: set(v) for k, v in cls_env.items() if v}
                _build_str_scopes(stmt.body, cls_env, stmt.name)
            elif isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
                fn_env = {k: set(v) for k, v in parent_env.items()}
                for call in ast.walk(tree):
                    if (
                        isinstance(call, ast.Call)
                        and isinstance(call.func, ast.Name)
                        and call.func.id == stmt.name
                    ):
                        call_bindings = [
                            (arg.arg, value)
                            for arg, value in zip(
                                [*stmt.args.posonlyargs, *stmt.args.args], call.args
                            )
                        ]
                        call_bindings.extend(
                            (kw.arg, kw.value)
                            for kw in call.keywords
                            if kw.arg is not None
                        )
                        for arg_name, arg_val in call_bindings:
                            vals = constant_strings(arg_val, parent_env)
                            if vals:
                                fn_env.setdefault(arg_name, set()).update(vals)
                fn_assigns, fn_jnodes = _direct_nodes(stmt.body)
                _propagate_str_assigns(fn_assigns, fn_env)
                scope_str_consts[id(stmt)] = fn_env
                for jn in fn_jnodes:
                    fstr_vars[id(jn)] = {k: set(v) for k, v in fn_env.items() if v}
                _build_str_scopes(stmt.body, fn_env, cls_name)

    _build_str_scopes(tree.body, module_str_consts)

    def expand_fstr(
        jnode: ast.JoinedStr,
        extra_vars: dict[str, set[str]] | None = None,
        *,
        required: bool = False,
    ) -> list[str]:
        variables = {
            **module_str_consts,
            **fstr_vars.get(id(jnode), {}),
            **(extra_vars or {}),
        }
        prefixes = [""]
        unknown: set[str] = set()
        for idx, val in enumerate(jnode.values):
            if isinstance(val, ast.Constant) and isinstance(val.value, str):
                prefixes = [p + val.value for p in prefixes]
            elif isinstance(val, ast.FormattedValue) and isinstance(
                val.value, ast.Name
            ):
                var_name = val.value.id
                if val.conversion != -1 or val.format_spec is not None:
                    unknown.update(
                        field.id
                        for field in ast.walk(val)
                        if isinstance(field, ast.Name)
                    )
                cands: set[str] | None = None
                if var_name in variables:
                    cands = variables[var_name]
                elif var_name == "name":
                    next_val = (
                        jnode.values[idx + 1] if idx + 1 < len(jnode.values) else None
                    )
                    next_const = (
                        next_val.value
                        if isinstance(next_val, ast.Constant)
                        and isinstance(next_val.value, str)
                        else ""
                    )
                    prev_val = jnode.values[idx - 1] if idx > 0 else None
                    prev_const = (
                        prev_val.value
                        if isinstance(prev_val, ast.Constant)
                        and isinstance(prev_val.value, str)
                        else ""
                    )
                    if next_const == "_bank":
                        cands = set(_scalar_replica_names())
                    elif prev_const == "_":
                        cands = {"cold", "frontend_hot", "sideband", "compressed"}
                if not cands:
                    unknown.add(var_name)
                    cands = {"0" if prefixes[0].endswith("[") else "unresolved"}
                prefixes = [p + c for p in prefixes for c in sorted(cands)]
            else:
                unknown.add(ast.unparse(val))
                prefixes = [p + "unresolved" for p in prefixes]
        if unknown:
            if required or (
                any(
                    is_candidate(p, False) and p.split(".", 1)[0] in dut_roots
                    for p in prefixes
                )
            ):
                unresolved.update(
                    f"{jnode.lineno}: unresolvable f-string variable {var!r}"
                    for var in unknown
                )
            return []
        return prefixes

    fstr_child_constants: set[int] = {
        id(val)
        for node in ast.walk(tree)
        if isinstance(node, ast.JoinedStr)
        for val in node.values
        if isinstance(val, ast.Constant)
    }

    non_dut_roots = {
        "cocotb_tests",
        "utils",
        "encoders",
        "testrig",
        "cpu_inst",
        "_log",
    }

    def is_candidate(raw_path: str, allow_single_segment: bool) -> bool:
        regex = ANY_SIGNAL_PATH_RE if allow_single_segment else DOTTED_PATH_RE
        if not regex.match(raw_path):
            return False
        parts = raw_path.split(".")
        first = parts[0].split("[", 1)[0]
        if first in non_dut_roots or first.startswith("_"):
            return False
        if len(parts) == 2 and parts[1] in NON_SIGNAL_EXTENSIONS:
            return False
        return True

    def add_candidate(lineno: int, raw_path: str, allow_single_segment: bool) -> None:
        if is_candidate(raw_path, allow_single_segment):
            found.append((lineno, raw_path, False))

    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and id(node) not in fstr_child_constants
        ):
            add_candidate(node.lineno, node.value, allow_single_segment=False)
        elif isinstance(node, ast.JoinedStr):
            for expanded in expand_fstr(node):
                add_candidate(node.lineno, expanded, allow_single_segment=False)

    # Also capture single-segment or f-string paths passed to probing helpers,
    # including class-scoped SIGNALS tuples (e.g. WfiRecoveryWatch).
    for cls_node in [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]:
        cls_extra = (
            {"name": class_signal_lists[cls_node.name]}
            if cls_node.name in class_signal_lists
            else None
        )
        if cls_extra:
            for jnode in [
                n for n in ast.walk(cls_node) if isinstance(n, ast.JoinedStr)
            ]:
                for expanded in expand_fstr(jnode, extra_vars=cls_extra):
                    add_candidate(jnode.lineno, expanded, allow_single_segment=True)

    for call_node in [n for n in ast.walk(tree) if isinstance(n, ast.Call)]:
        if isinstance(call_node.func, ast.Name) and call_node.func.id in (
            "_get_signal",
            "_lookup_signal",
            "_first_signal",
            "_signal",
            "_packed_struct",
            "_struct_field",
        ):
            if len(call_node.args) >= 2:
                arg = call_node.args[1]
                arg_nodes = (
                    arg.elts if isinstance(arg, (ast.List, ast.Tuple)) else [arg]
                )
                for call_arg in arg_nodes:
                    if isinstance(call_arg, ast.Constant) and isinstance(
                        call_arg.value, str
                    ):
                        add_candidate(
                            call_arg.lineno, call_arg.value, allow_single_segment=True
                        )
                    elif isinstance(call_arg, ast.JoinedStr):
                        for expanded in expand_fstr(call_arg, required=True):
                            add_candidate(
                                call_arg.lineno, expanded, allow_single_segment=True
                            )

    scopes = [
        n
        for n in ast.walk(tree)
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
    ]
    classes = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)}
    class_inits: dict[str, ast.FunctionDef] = {}
    for cls_name, cls_node in classes.items():
        for item in cls_node.body:
            if isinstance(item, ast.FunctionDef) and item.name == "__init__":
                class_inits[cls_name] = item
    scope_classes = {
        id(fn): cls.name
        for cls in ast.walk(tree)
        if isinstance(cls, ast.ClassDef)
        for fn in ast.walk(cls)
        if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    nested_scopes = {
        id(child)
        for fn in scopes
        for child in ast.walk(fn)
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
        and child is not fn
    }
    functions = {n.name: n for n in scopes if id(n) not in scope_classes}
    class_methods: dict[str, ast.FunctionDef | ast.AsyncFunctionDef] = {
        f"{scope_classes[id(n)]}.{n.name}": n for n in scopes if id(n) in scope_classes
    }
    nested_functions: dict[str, ast.FunctionDef | ast.AsyncFunctionDef] = {
        n.name: n for n in scopes if id(n) in nested_scopes
    }
    local_calls = {
        call.func.id
        for fn in scopes
        for call in ast.walk(fn)
        if isinstance(call, ast.Call)
        and isinstance(call.func, ast.Name)
        and call.func.id != fn.name
    }
    parameters: dict[str, dict[str, set[str]]] = {name: {} for name in functions}
    for cls_name in class_inits:
        parameters[f"{cls_name}.__init__"] = {}
    returns: dict[str, set[str]] = {}
    members: dict[str, dict[str, set[str]]] = {}
    changed = False
    active_str_consts: dict[str, set[str]] = module_str_consts
    active_cls = ""
    inline_stack: set[int] = set()

    def _resolves_anywhere(path: str) -> bool:
        if resolve_rtl_path(hierarchy, path):
            return True
        if any(resolve_rtl_path(hierarchy, path, alt) for alt in SHARED_ALT_TOPS):
            return True
        if not path.startswith("cpu_and_memory_subsystem") and resolve_rtl_path(
            hierarchy, f"cpu_and_memory_subsystem.{path}"
        ):
            return True
        if path.startswith("cpu_and_memory_subsystem.") and not path.startswith(
            "cpu_and_memory_subsystem.soc."
        ):
            rest = path.removeprefix("cpu_and_memory_subsystem.")
            if resolve_rtl_path(hierarchy, f"cpu_and_memory_subsystem.soc.{rest}"):
                return True
        return False

    def merge_paths(dest: dict[str, set[str]], key: str, paths: set[str]) -> None:
        nonlocal changed
        if not paths.issubset(dest.get(key, set())):
            dest.setdefault(key, set()).update(paths)
            changed = True

    def _string_compare_cond(
        node: ast.AST, aliases: dict[str, set[str]]
    ) -> bool | None:
        if (
            isinstance(node, ast.Compare)
            and len(node.ops) == 1
            and len(node.comparators) == 1
            and isinstance(node.ops[0], (ast.Eq, ast.NotEq))
        ):
            left = string_values(node.left, aliases)
            right = string_values(node.comparators[0], aliases)
            if len(left) == 1 and len(right) == 1:
                eq = left[0] == right[0]
                return eq if isinstance(node.ops[0], ast.Eq) else not eq
        return None

    def string_values(
        node: ast.AST, aliases: dict[str, set[str]], *, required: bool = False
    ) -> list[str]:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return [node.value]
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            left = string_values(node.left, aliases, required=required)
            right = string_values(node.right, aliases, required=required)
            if left and right:
                return sorted({a + b for a in left for b in right})
            return []
        if isinstance(node, ast.IfExp):
            cond = _string_compare_cond(node.test, aliases)
            if cond is True:
                return string_values(node.body, aliases, required=required)
            if cond is False:
                return string_values(node.orelse, aliases, required=required)
            return sorted(
                set(string_values(node.body, aliases, required=required))
                | set(string_values(node.orelse, aliases, required=required))
            )
        if isinstance(node, ast.JoinedStr):
            return expand_fstr(
                node,
                {
                    k.removeprefix("__STR__:"): v
                    for k, v in aliases.items()
                    if k.startswith("__STR__:")
                },
                required=required,
            )
        if isinstance(node, (ast.Tuple, ast.List)):
            return [
                s
                for elt in node.elts
                for s in string_values(elt, aliases, required=required)
            ]
        if isinstance(node, ast.Name):
            return sorted(
                aliases.get(f"__STR__:{node.id}", active_str_consts.get(node.id, set()))
            )
        return []

    def expr_prefixes(node: ast.AST, aliases: dict[str, set[str]]) -> set[str]:
        if isinstance(node, ast.Name):
            return set(aliases.get(node.id, set()))
        if isinstance(node, ast.Subscript):
            return expr_prefixes(node.value, aliases)
        if isinstance(node, ast.Attribute):
            key = ast.unparse(node)
            if key in aliases:
                return set(aliases[key])
            if isinstance(node.value, ast.Name):
                inst_classes = aliases.get(f"__CLS__:{node.value.id}", set())
                if inst_classes:
                    out_cls: set[str] = set()
                    for cls_name in inst_classes:
                        out_cls |= members.get(cls_name, {}).get(
                            f"self.{node.attr}", set()
                        )
                    if out_cls:
                        return out_cls
            bases = expr_prefixes(node.value, aliases)
            if node.attr in COCOTB_HANDLE_ATTRS or node.attr.startswith("_"):
                return set()
            return {f"{b}.{node.attr}".lstrip(".") for b in bases}
        if isinstance(node, (ast.List, ast.Tuple)):
            return {p for elt in node.elts for p in expr_prefixes(elt, aliases)}
        if isinstance(node, (ast.ListComp, ast.SetComp, ast.GeneratorExp)):
            comp_aliases = {k: set(v) for k, v in aliases.items()}
            for gen in node.generators:
                if isinstance(gen.target, ast.Name):
                    comp_aliases[gen.target.id] = expr_prefixes(gen.iter, comp_aliases)
                    if isinstance(gen.iter, (ast.Tuple, ast.List)):
                        str_elts = {
                            e.value
                            for e in gen.iter.elts
                            if isinstance(e, ast.Constant) and isinstance(e.value, str)
                        }
                        if str_elts:
                            comp_aliases[f"__STR__:{gen.target.id}"] = str_elts
            return expr_prefixes(node.elt, comp_aliases)
        if isinstance(node, ast.IfExp):
            cond = frost_condition(node.test, aliases)
            if cond is None:
                cond = _string_compare_cond(node.test, aliases)
            if cond is True:
                return expr_prefixes(node.body, aliases)
            if cond is False:
                return expr_prefixes(node.orelse, aliases)
            return expr_prefixes(node.body, aliases) | expr_prefixes(
                node.orelse, aliases
            )
        if isinstance(node, ast.Call):
            fn = ast.unparse(node.func)
            if fn == "_program_soc" and node.args:
                return {
                    "cpu_and_memory_subsystem.soc",
                    "cpu_and_memory_subsystem",
                }
            if fn == "_nic_engine" and node.args:
                bases = expr_prefixes(node.args[0], aliases)
                resolved = {b for b in bases if _resolves_anywhere(b)} | {
                    f"{b}.u_engine"
                    for b in bases
                    if _resolves_anywhere(f"{b}.u_engine")
                }
                return resolved or bases
            if fn in ("tuple", "list", "enumerate") and node.args:
                return expr_prefixes(node.args[0], aliases)
            if (
                fn
                in (
                    "getattr",
                    "_get_signal",
                    "_lookup_signal",
                    "_first_signal",
                    "_signal",
                )
                and len(node.args) >= 2
            ):
                bases = expr_prefixes(node.args[0], aliases)
                attrs = (
                    string_values(node.args[1], aliases, required=True) if bases else []
                )
                has_default = fn == "getattr" and len(node.args) >= 3
                out: set[str] = set()
                for b in bases:
                    for a in attrs:
                        if not a or a.startswith("_"):
                            continue
                        cand = f"{b}.{a}".lstrip(".")
                        if has_default and b and _resolves_anywhere(b):
                            if not _resolves_anywhere(cand):
                                continue
                        out.add(cand)
                if has_default:
                    out |= expr_prefixes(node.args[2], aliases)
                return out
            if fn in functions:
                return set(returns.get(fn, set()))
        return set()

    def frost_condition(node: ast.AST, aliases: dict[str, set[str]]) -> bool | None:
        if isinstance(node, ast.Constant) and isinstance(node.value, bool):
            return node.value
        if isinstance(node, ast.Name):
            values = aliases.get(f"__BOOL__:{node.id}", set())
            if len(values) == 1:
                return next(iter(values)) == "1"
            if node.id in module_bool_consts:
                return module_bool_consts[node.id]
            return None
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            value = frost_condition(node.operand, aliases)
            return None if value is None else not value
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "hasattr"
            and len(node.args) == 2
            and expr_prefixes(node.args[0], aliases) == {""}
            and isinstance(node.args[1], ast.Constant)
            and isinstance(node.args[1].value, str)
        ):
            return bool(resolve_rtl_path(hierarchy, node.args[1].value))
        return _is_frost_toplevel_check(node)

    def visit_expr(expr: ast.AST, aliases: dict[str, set[str]]) -> None:
        if isinstance(expr, ast.IfExp):
            visit_expr(expr.test, aliases)
            cond = frost_condition(expr.test, aliases)
            if cond is None:
                cond = _string_compare_cond(expr.test, aliases)
            if cond is True:
                visit_expr(expr.body, aliases)
            elif cond is False:
                visit_expr(expr.orelse, aliases)
            else:
                visit_expr(expr.body, aliases)
                visit_expr(expr.orelse, aliases)
            return

        if isinstance(
            expr, (ast.ListComp, ast.SetComp, ast.GeneratorExp, ast.DictComp)
        ):
            comp_aliases = {k: set(v) for k, v in aliases.items()}
            for gen in expr.generators:
                visit_expr(gen.iter, comp_aliases)
                if isinstance(gen.target, ast.Name):
                    prefs = {
                        p
                        for p in expr_prefixes(gen.iter, comp_aliases)
                        if not p.startswith("__SELF__")
                    }
                    if prefs:
                        comp_aliases[gen.target.id] = prefs
                    str_elts = set(string_values(gen.iter, comp_aliases))
                    if str_elts:
                        comp_aliases[f"__STR__:{gen.target.id}"] = str_elts
                for gen_if in gen.ifs:
                    visit_expr(gen_if, comp_aliases)
            if isinstance(expr, ast.DictComp):
                visit_expr(expr.key, comp_aliases)
                visit_expr(expr.value, comp_aliases)
            else:
                visit_expr(expr.elt, comp_aliases)
            return

        if isinstance(expr, ast.Attribute):
            is_value = expr.attr == "value"
            paths = expr_prefixes(expr.value if is_value else expr, aliases)
            found.extend(
                (expr.lineno, p, is_value and isinstance(expr.ctx, ast.Store))
                for p in paths
                if p and not p.startswith("__SELF__")
            )
        elif (
            isinstance(expr, ast.Call)
            and ast.unparse(expr.func)
            in (
                "getattr",
                "hasattr",
                "_get_signal",
                "_lookup_signal",
                "_first_signal",
                "_signal",
                "_packed_struct",
                "_struct_field",
            )
            and len(expr.args) >= 2
        ):
            call_fn = ast.unparse(expr.func)
            bases = expr_prefixes(expr.args[0], aliases)
            if call_fn == "hasattr" and frost_condition(expr, aliases) is False:
                return
            has_default = call_fn == "getattr" and len(expr.args) >= 3
            attrs = string_values(expr.args[1], aliases, required=True) if bases else []
            for b in bases:
                if not b.startswith("__SELF__"):
                    for attr_name in attrs:
                        if (
                            attr_name
                            and attr_name not in COCOTB_HANDLE_ATTRS
                            and not attr_name.startswith("_")
                        ):
                            cand = f"{b}.{attr_name}".lstrip(".")
                            if has_default and b and _resolves_anywhere(b):
                                if not _resolves_anywhere(cand):
                                    continue
                            found.append((expr.lineno, cand, False))

        if isinstance(expr, ast.Call):
            if isinstance(expr.func, ast.Attribute) and expr.func.attr in (
                "set",
                "setimmediatevalue",
            ):
                found.extend(
                    (expr.lineno, p, True)
                    for p in expr_prefixes(expr.func.value, aliases)
                    if p and not p.startswith("__SELF__")
                )

            def _bind_call(
                target_key: str,
                target_fn: ast.FunctionDef | ast.AsyncFunctionDef,
                *,
                drop_self: bool = False,
            ) -> None:
                all_args = [*target_fn.args.posonlyargs, *target_fn.args.args]
                if drop_self and all_args and all_args[0].arg in ("self", "cls"):
                    all_args = all_args[1:]
                bindings = list(zip((a.arg for a in all_args), expr.args))
                bindings.extend(
                    (kw.arg, kw.value) for kw in expr.keywords if kw.arg is not None
                )
                for name, value in bindings:
                    merge_paths(
                        parameters[target_key], name, expr_prefixes(value, aliases)
                    )

            def _inline_single_return(
                target_fn: ast.FunctionDef | ast.AsyncFunctionDef,
                *,
                drop_self: bool = False,
                inherit_aliases: bool = False,
            ) -> bool:
                if id(target_fn) in inline_stack:
                    return False
                body_stmts = [
                    s
                    for s in target_fn.body
                    if not (
                        isinstance(s, ast.Expr)
                        and isinstance(s.value, ast.Constant)
                        and isinstance(s.value.value, str)
                    )
                ]
                if len(body_stmts) != 1 or not isinstance(body_stmts[0], ast.Return):
                    return False
                if body_stmts[0].value is None:
                    return False
                all_args = [*target_fn.args.posonlyargs, *target_fn.args.args]
                if drop_self and all_args and all_args[0].arg in ("self", "cls"):
                    all_args = all_args[1:]
                bindings = list(zip((a.arg for a in all_args), expr.args))
                bindings.extend(
                    (kw.arg, kw.value) for kw in expr.keywords if kw.arg is not None
                )
                call_aliases = (
                    {k: set(v) for k, v in aliases.items()} if inherit_aliases else {}
                )
                for name, value in bindings:
                    prefs = {
                        p
                        for p in expr_prefixes(value, aliases)
                        if not p.startswith("__SELF__")
                    }
                    if prefs:
                        call_aliases[name] = prefs
                    else:
                        call_aliases.pop(name, None)
                    str_vals = set(string_values(value, aliases))
                    if str_vals:
                        call_aliases[f"__STR__:{name}"] = str_vals
                    else:
                        call_aliases.pop(f"__STR__:{name}", None)
                inline_stack.add(id(target_fn))
                try:
                    visit_expr(body_stmts[0].value, call_aliases)
                finally:
                    inline_stack.discard(id(target_fn))
                return True

            fn = ast.unparse(expr.func)
            if fn in functions:
                _bind_call(fn, functions[fn])
            elif fn in nested_functions:
                _inline_single_return(nested_functions[fn], inherit_aliases=True)
            elif fn in class_inits:
                _bind_call(f"{fn}.__init__", class_inits[fn], drop_self=True)
            elif (
                isinstance(expr.func, ast.Attribute)
                and isinstance(expr.func.value, ast.Name)
                and expr.func.value.id == "self"
                and active_cls
                and f"{active_cls}.{expr.func.attr}" in class_methods
            ):
                _inline_single_return(
                    class_methods[f"{active_cls}.{expr.func.attr}"], drop_self=True
                )

        for child in ast.iter_child_nodes(expr):
            if (
                isinstance(expr, ast.Call)
                and child is expr.func
                and isinstance(child, ast.Attribute)
                and child.attr in ("set", "setimmediatevalue", "read")
            ):
                child = child.value
            visit_expr(child, aliases)

    def _bind_target(
        tgt: ast.AST, value: ast.AST, aliases: dict[str, set[str]]
    ) -> None:
        if (
            isinstance(tgt, ast.Tuple)
            and isinstance(value, ast.Tuple)
            and len(tgt.elts) == len(value.elts)
        ):
            for sub_tgt, sub_val in zip(tgt.elts, value.elts):
                _bind_target(sub_tgt, sub_val, aliases)
            return
        visit_expr(tgt, aliases)
        key = ast.unparse(tgt)
        condition = frost_condition(value, aliases)
        if isinstance(tgt, ast.Name) and condition is not None:
            aliases[f"__BOOL__:{key}"] = {str(int(condition))}
        if (
            isinstance(tgt, ast.Name)
            and isinstance(value, ast.Call)
            and isinstance(value.func, ast.Name)
            and value.func.id in classes
        ):
            aliases[f"__CLS__:{key}"] = {value.func.id}
        if not isinstance(tgt, ast.Name) and not (
            isinstance(tgt, ast.Attribute)
            and isinstance(tgt.value, ast.Name)
            and tgt.value.id == "self"
            and tgt.attr != "value"
        ):
            return
        prefs = {
            p for p in expr_prefixes(value, aliases) if not p.startswith("__SELF__")
        }
        if prefs:
            aliases[key] = prefs
        else:
            aliases.pop(key, None)
            if isinstance(tgt, ast.Name):
                str_vals = string_values(value, aliases)
                if str_vals:
                    aliases[f"__STR__:{key}"] = set(str_vals)

    def visit_stmts(stmts: list[ast.stmt], aliases: dict[str, set[str]]) -> bool:
        for stmt in stmts:
            if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for key, paths in aliases.items():
                    merge_paths(parameters.setdefault(stmt.name, {}), key, paths)
                continue
            if isinstance(stmt, ast.ClassDef):
                continue
            if isinstance(stmt, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
                if stmt.value is None:
                    continue
                visit_expr(stmt.value, aliases)
                targets = (
                    stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
                )
                for tgt in targets:
                    _bind_target(tgt, stmt.value, aliases)
                continue
            if isinstance(stmt, ast.Return):
                if stmt.value is not None:
                    visit_expr(stmt.value, aliases)
                    aliases.setdefault("__RETURN__", set()).update(
                        expr_prefixes(stmt.value, aliases)
                    )
                return True
            if isinstance(stmt, ast.Raise):
                for child in ast.iter_child_nodes(stmt):
                    visit_expr(child, aliases)
                return True
            if (
                isinstance(stmt, ast.Expr)
                and isinstance(stmt.value, ast.Call)
                and isinstance(stmt.value.func, ast.Attribute)
                and stmt.value.func.attr == "append"
                and isinstance(stmt.value.func.value, ast.Name)
                and stmt.value.args
            ):
                visit_expr(stmt.value, aliases)
                prefs = {
                    p
                    for p in expr_prefixes(stmt.value.args[0], aliases)
                    if not p.startswith("__SELF__")
                }
                if prefs:
                    aliases.setdefault(stmt.value.func.value.id, set()).update(prefs)
                continue
            if isinstance(stmt, ast.If):
                condition = frost_condition(stmt.test, aliases)
                if condition is not None:
                    visit_expr(stmt.test, aliases)
                    if visit_stmts(stmt.body if condition else stmt.orelse, aliases):
                        return True
                    continue
                visit_expr(stmt.test, aliases)
                body_aliases = {k: set(v) for k, v in aliases.items()}
                else_aliases = {k: set(v) for k, v in aliases.items()}
                body_exits = visit_stmts(stmt.body, body_aliases)
                else_exits = visit_stmts(stmt.orelse, else_aliases)
                if body_exits and else_exits:
                    return True
                for k in set(body_aliases) | set(else_aliases):
                    aliases[k] = body_aliases.get(k, set()) | else_aliases.get(k, set())
                continue
            if isinstance(stmt, (ast.For, ast.AsyncFor)):
                visit_expr(stmt.iter, aliases)
                iter_node = stmt.iter
                if (
                    isinstance(stmt.target, ast.Name)
                    and isinstance(iter_node, (ast.Tuple, ast.List))
                    and iter_node.elts
                    and all(
                        isinstance(e, ast.Constant) and isinstance(e.value, str)
                        for e in iter_node.elts
                    )
                ):
                    for str_elt in iter_node.elts:
                        assert isinstance(str_elt, ast.Constant)
                        assert isinstance(str_elt.value, str)
                        loop_aliases = {k: set(v) for k, v in aliases.items()}
                        loop_aliases[f"__STR__:{stmt.target.id}"] = {str_elt.value}
                        visit_stmts(stmt.body, loop_aliases)
                        visit_stmts(stmt.orelse, loop_aliases)
                        for k, v in loop_aliases.items():
                            if not k.startswith("__STR__:"):
                                aliases.setdefault(k, set()).update(v)
                    continue
                loop_aliases = {k: set(v) for k, v in aliases.items()}
                if (
                    isinstance(iter_node, ast.Call)
                    and isinstance(iter_node.func, ast.Name)
                    and iter_node.func.id == "enumerate"
                    and iter_node.args
                    and isinstance(stmt.target, ast.Tuple)
                    and len(stmt.target.elts) == 2
                    and isinstance(stmt.target.elts[1], ast.Name)
                ):
                    prefs = expr_prefixes(iter_node.args[0], loop_aliases)
                    if prefs:
                        loop_aliases[stmt.target.elts[1].id] = prefs
                elif isinstance(stmt.target, ast.Name):
                    prefs = {
                        p
                        for p in expr_prefixes(iter_node, loop_aliases)
                        if not p.startswith("__SELF__")
                    }
                    if prefs:
                        loop_aliases[stmt.target.id] = prefs
                visit_stmts(stmt.body, loop_aliases)
                visit_stmts(stmt.orelse, loop_aliases)
                for k, v in loop_aliases.items():
                    if not k.startswith("__STR__:"):
                        aliases.setdefault(k, set()).update(v)
                continue
            if isinstance(stmt, ast.While):
                visit_expr(stmt.test, aliases)
                visit_stmts(stmt.body, aliases)
                visit_stmts(stmt.orelse, aliases)
                continue
            if isinstance(stmt, (ast.With, ast.AsyncWith)):
                for item in stmt.items:
                    visit_expr(item.context_expr, aliases)
                visit_stmts(stmt.body, aliases)
                continue
            if isinstance(stmt, ast.Try):
                visit_stmts(stmt.body, aliases)
                for handler in stmt.handlers:
                    visit_stmts(handler.body, aliases)
                visit_stmts(stmt.orelse, aliases)
                visit_stmts(stmt.finalbody, aliases)
                continue
            for child in ast.iter_child_nodes(stmt):
                visit_expr(child, aliases)
        return False

    # Propagate handle arguments, helper returns, and class members to writes.
    for _ in range(len(scopes) + 2):
        changed = False
        for fn_node in scopes:
            active_str_consts = scope_str_consts.get(id(fn_node), module_str_consts)
            cls = scope_classes.get(id(fn_node), "")
            active_cls = cls
            entry = id(fn_node) not in nested_scopes and (
                bool(cls)
                or fn_node.name not in local_calls
                or any(
                    isinstance(dec, ast.Call) and ast.unparse(dec.func) == "cocotb.test"
                    for dec in fn_node.decorator_list
                )
            )
            aliases: dict[str, set[str]] = (
                {"dut": {""}, "self.dut": {""}} if entry else {}
            )
            aliases.update({k: set(v) for k, v in members.get(cls, {}).items()})
            param_key = (
                fn_node.name
                if id(fn_node) in nested_scopes
                else (f"{cls}.{fn_node.name}" if cls else fn_node.name)
            )
            aliases.update(
                {k: set(v) for k, v in parameters.get(param_key, {}).items()}
            )
            arg_names = [a.arg for a in fn_node.args.args]
            if "soc" in arg_names and "dut" not in arg_names:
                aliases.setdefault("soc", {"cpu_and_memory_subsystem.soc"})
            if "memory" in arg_names and "dut" not in arg_names:
                aliases.setdefault(
                    "memory", {"cpu_and_memory_subsystem.soc.instruction_memory"}
                )
            if "bank" in arg_names and "dut" not in arg_names:
                aliases.setdefault(
                    "bank",
                    {"cpu_and_memory_subsystem.soc.instruction_memory.u_even_cold"},
                )
            if "bridge" in arg_names:
                aliases.setdefault(
                    "bridge",
                    {"cpu_and_memory_subsystem.soc.gen_cached_tier.dma_bridge"},
                )
            if "ingress" in arg_names:
                aliases.setdefault(
                    "ingress",
                    {
                        "cpu_and_memory_subsystem.cpu.cluster_memory"
                        ".gen_coherent_tier.gen_dma_ingress.ingress"
                    },
                )
            visit_stmts(fn_node.body, aliases)
            merge_paths(returns, fn_node.name, aliases.get("__RETURN__", set()))
            if cls:
                for key, paths in aliases.items():
                    if key.startswith("self."):
                        merge_paths(members.setdefault(cls, {}), key, paths)
        if not changed:
            break
    else:
        unresolved.add("1: handle alias analysis did not converge")

    earliest: dict[tuple[str, bool], int] = {}
    for lineno, p, written in found:
        access_key = (p, written)
        if access_key not in earliest or lineno < earliest[access_key]:
            earliest[access_key] = lineno
    return tuple(sorted((ln, p, wr) for (p, wr), ln in earliest.items())), tuple(
        sorted(unresolved)
    )


def check_bench_paths_against_rules(
    modules: dict[str, dict[str, object]],
    rules: list[tuple[str, str, str, int]],
    bench_files: tuple[Path, ...],
    shared_helpers: tuple[tuple[Path, tuple[str, ...]], ...] = (),
) -> tuple[list[str], list[str]]:
    """Return (unresolved_paths, uncovered_leaves) across all frost bench files."""
    unresolved: list[str] = []
    uncovered: list[str] = []

    @functools.cache
    def resolve(path: str, top: str = "frost") -> list[tuple[str, str]]:
        return resolve_rtl_path(modules, path, top)

    @functools.cache
    def covered(mod: str, var: str, written: bool) -> bool:
        return any(
            fnmatch.fnmatchcase(mod, mp)
            and fnmatch.fnmatchcase(var, vp)
            and (not written or directive == "public_flat_rw")
            for directive, mp, vp, _ in rules
        )

    targets: list[tuple[Path, tuple[str, ...] | None]] = [
        (bf, None) for bf in bench_files
    ]
    targets.extend(shared_helpers)

    for bf, only_functions in targets:
        rel = bf.relative_to(ROOT) if bf.is_relative_to(ROOT) else bf
        paths, unresolvable = extract_bench_dut_paths(bf, only_functions)
        unresolved.extend(f"{rel}:{message}" for message in unresolvable)
        for lineno, path, written in paths:
            if rel.name == "test_frost_visibility_probes.py" and path.endswith(
                ".prog_port_imem_we"
            ):
                continue
            frost_leaves = list(resolve(path))
            if not frost_leaves:
                frost_leaves = [
                    leaf for alt in SHARED_ALT_TOPS for leaf in resolve(path, alt)
                ]
                if not path.startswith("cpu_and_memory_subsystem"):
                    frost_leaves.extend(resolve(f"cpu_and_memory_subsystem.{path}"))
                if path.startswith("cpu_and_memory_subsystem.") and not path.startswith(
                    "cpu_and_memory_subsystem.soc."
                ):
                    rest = path.removeprefix("cpu_and_memory_subsystem.")
                    frost_leaves.extend(resolve(f"cpu_and_memory_subsystem.soc.{rest}"))
            if not frost_leaves:
                unresolved.append(f"{rel}:{lineno}: {path}")
                continue
            for mod, var in sorted(set(frost_leaves)):
                if var == "<SCOPE>":
                    continue
                if not covered(mod, var, written):
                    uncovered.append(
                        f"{rel}:{lineno}: {path} "
                        f"(leaf {mod}.{var} requires "
                        f"{'public_flat_rw for write' if written else 'a visibility rule'} "
                        "in frost_cocotb_visibility.vlt)"
                    )
    return unresolved, uncovered


def _ensure_verilator_stub_if_needed(tmp_path: Path) -> list[str]:
    """Use the ambient Verilator when it supports -fico-change-detect, else a 5.052 stub."""
    ambient = shutil.which("verilator")
    if ambient is not None:
        probe = subprocess.run(
            [ambient, "-E", "-fico-change-detect", "/dev/null"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if probe.returncode == 0:
            return []
    stub_dir = tmp_path / "verilator_5052_stub"
    stub_dir.mkdir(exist_ok=True)
    stub = stub_dir / "verilator"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        'if [[ "$1" == "--version" ]]; then echo "Verilator 5.052 2026-09-05 rev v5.052"; exit 0; fi\n'
        "exit 0\n",
        encoding="utf-8",
    )
    stub.chmod(0o755)
    return [f"VERILATOR_BIN_DIR={stub_dir}"]


def _make_dry_run(tmp_path: Path, toplevel: str, *extra: str) -> str:
    """Return the Verilator command line that tests/Makefile emits."""
    if shutil.which("cocotb-config") is None:
        pytest.skip("cocotb-config is not on PATH")
    build = tmp_path / "sim_build"
    build.mkdir(exist_ok=True)
    stub_args = _ensure_verilator_stub_if_needed(tmp_path)
    cmd = [
        "make",
        "--no-print-directory",
        "-f",
        str(ROOT / "tests" / "Makefile"),
        f"ROOT={ROOT}",
        f"TOPLEVEL={toplevel}",
        f"SIM_BUILD={build}",
        "NUMBER_OF_CPU_CORES=4",
        *stub_args,
        *extra,
        f"{build}/Vtop.mk",
        "-n",
    ]
    env = os.environ.copy()
    for key in (
        "WAVES",
        "FROST_COVERAGE",
        "FROST_COVERAGE_TOGGLE",
        "FROST_FULL_VISIBILITY",
        "FROST_HANG_PROBE",
        "FROST_RETIRE_TRACE",
        "FROST_VERILATOR_THREADS",
        "FROST_VERILATOR_EXTRA_ARGS",
    ):
        env.pop(key, None)
    result = subprocess.run(
        cmd, cwd=tmp_path, env=env, capture_output=True, text=True, timeout=30
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return next(line for line in result.stdout.splitlines() if " -cc --exe " in line)


def test_visibility_file_well_formed() -> None:
    """Check syntax, pragma safety, uniqueness, and sorting of the vlt list."""
    lines = VISIBILITY_FILE.read_text(encoding="utf-8").splitlines()
    config_seen = False
    rw_rules: list[tuple[str, str]] = []
    rd_rules: list[tuple[str, str]] = []

    for line_no, raw in enumerate(lines, start=1):
        stripped = raw.strip()
        if not stripped:
            continue
        if stripped.startswith("//"):
            assert not stripped[2:].lstrip().lower().startswith("verilator"), (
                f"line {line_no} starts a comment with 'verilator', which "
                "Verilator parses as an inline pragma"
            )
            continue
        if stripped == "`verilator_config":
            config_seen = True
            continue
        assert config_seen, f"rule before `verilator_config on line {line_no}"
        match = RULE_RE.match(stripped)
        assert match is not None, f"malformed rule on line {line_no}: {raw}"
        directive, module, var = match.groups()
        if directive == "public_flat_rw":
            assert not rd_rules, (
                f"public_flat_rw after public_flat_rd on line {line_no}"
            )
            rw_rules.append((module, var))
        else:
            rd_rules.append((module, var))

    assert config_seen
    assert ("frost", "i_*") in rw_rules
    assert ("frost", "o_*") in rd_rules
    assert len(rw_rules) == len(set(rw_rules)), "duplicate public_flat_rw rule"
    assert len(rd_rules) == len(set(rd_rules)), "duplicate public_flat_rd rule"
    assert rw_rules == sorted(rw_rules), "public_flat_rw rules are unsorted"
    assert rd_rules == sorted(rd_rules), "public_flat_rd rules are unsorted"

    modules = build_rtl_hierarchy()
    referenced_modules = {
        module for module, _ in (*rw_rules, *rd_rules) if "*" not in module
    }
    missing_modules = sorted(referenced_modules - set(modules))
    assert not missing_modules, f"unknown modules in visibility file: {missing_modules}"


def test_frost_benches_and_visibility_rules_resolve() -> None:
    """Every frost bench DUT path must have a .vlt rule, and every rule must match RTL."""
    modules = build_rtl_hierarchy()
    rules = parse_vlt_rules(VISIBILITY_FILE.read_text(encoding="utf-8"))
    dead = check_dead_rules(modules, rules)
    assert not dead, "dead rules in frost_cocotb_visibility.vlt:\n  " + "\n  ".join(
        dead
    )

    bench_files = discover_frost_bench_files()
    shared_helpers = discover_frost_shared_helpers()
    assert len(bench_files) >= 24, f"unexpectedly few frost bench files: {bench_files}"
    unresolved, uncovered = check_bench_paths_against_rules(
        modules, rules, bench_files, shared_helpers
    )
    assert not unresolved, "unresolved DUT paths in frost benches:\n  " + "\n  ".join(
        unresolved
    )
    assert not uncovered, (
        "unlisted DUT signals touched by frost benches:\n  " + "\n  ".join(uncovered)
    )


def test_visibility_resolver_detects_missing_and_dead_rules() -> None:
    """Deleting a live rule or adding a dead rule must fail and name the path or rule."""
    modules = build_rtl_hierarchy()
    bench_files = discover_frost_bench_files()
    vlt_text = VISIBILITY_FILE.read_text(encoding="utf-8")

    # Deleting a rule used via _get_signal must fail and name the bench path.
    shared_helpers = discover_frost_shared_helpers()
    without_mtime = "\n".join(
        line
        for line in vlt_text.splitlines()
        if line.strip() != 'public_flat_rd -module "soc_top" -var "mtime"'
    )
    assert without_mtime != vlt_text
    unresolved, uncovered = check_bench_paths_against_rules(
        modules, parse_vlt_rules(without_mtime), bench_files, shared_helpers
    )
    assert not unresolved
    assert any(
        "test_real_program.py" in item
        and "cpu_and_memory_subsystem.soc.mtime" in item
        and "soc_top.mtime" in item
        for item in uncovered
    ), uncovered

    # Deleting a rule used via direct attribute chain must also fail and name the path.
    without_reset_seen = "\n".join(
        line
        for line in vlt_text.splitlines()
        if line.strip() != 'public_flat_rw -module "nic_dma_front" -var "reset_seen_q"'
    )
    _, uncovered_chain = check_bench_paths_against_rules(
        modules, parse_vlt_rules(without_reset_seen), bench_files, shared_helpers
    )
    assert any(
        "reset_seen_q" in item and "nic_dma_front.reset_seen_q" in item
        for item in uncovered_chain
    ), uncovered_chain

    # Adding a rule whose variable does not exist in RTL must fail check_dead_rules.
    with_dead_rule = (
        vlt_text + '\npublic_flat_rw -module "frost_sram_2rw" -var "memory"\n'
    )
    dead = check_dead_rules(modules, parse_vlt_rules(with_dead_rule))
    assert len(dead) == 1
    assert 'public_flat_rw -module "frost_sram_2rw" -var "memory"' in dead[0]


def test_forceable_overlays_have_public_flat_rw_rules() -> None:
    """Every per-test forceable .vlt rule must also be public_flat_rw in frost_cocotb_visibility.vlt."""
    rw_rules = [
        (mod, var)
        for directive, mod, var, _ in parse_vlt_rules(
            VISIBILITY_FILE.read_text(encoding="utf-8")
        )
        if directive == "public_flat_rw"
    ]
    forceable_re = re.compile(r'^forceable\s+-module\s+"([^"]+)"\s+-var\s+"([^"]+)"$')
    overlay_files = sorted((ROOT / "verif" / "cocotb_tests").glob("*.vlt"))
    assert overlay_files, "expected per-test forceable .vlt overlays"
    checked = 0
    for overlay in overlay_files:
        for line_no, raw in enumerate(
            overlay.read_text(encoding="utf-8").splitlines(), start=1
        ):
            match = forceable_re.match(raw.strip())
            if not match:
                continue
            checked += 1
            mod, var = match.groups()
            assert any(
                fnmatch.fnmatchcase(mod, mp) and fnmatch.fnmatchcase(var, vp)
                for mp, vp in rw_rules
            ), (
                f"{overlay.relative_to(ROOT)}:{line_no}: forceable target {mod}.{var} "
                "requires public_flat_rw in hw/sim/frost_cocotb_visibility.vlt so "
                "Verilator registers a VPI handle for cocotb Force()"
            )
    assert checked >= 5


def test_visibility_resolver_handles_tuples_classes_early_return_and_concat(
    tmp_path: Path,
) -> None:
    """Tuple unpacking, class members, early-return guards, and string concat resolve."""
    bench = tmp_path / "structured_bench.py"
    bench.write_text(
        "class Watcher:\n"
        "    def __init__(self, top):\n"
        "        self.soc = top.cpu_and_memory_subsystem.soc\n"
        "    def sample(self):\n"
        "        s, = (self.soc,)\n"
        "        return int(getattr(s, 'm' + 'time').value)\n"
        "def bench(dut):\n"
        "    if hasattr(dut, 'i_rst_n'):\n"
        "        w = Watcher(dut)\n"
        "        w.sample()\n"
        "        return int(w.soc.mtimecmp.value)\n"
        "    dut.i_axi_awvalid.value = 1\n",
        encoding="utf-8",
    )
    modules = build_rtl_hierarchy()
    unresolved, uncovered = check_bench_paths_against_rules(modules, [], (bench,))
    assert not unresolved, unresolved
    leaves = {item.split("(leaf ", 1)[1].split(" ", 1)[0] for item in uncovered}
    assert leaves == {"frost.i_rst_n", "soc_top.mtime", "soc_top.mtimecmp"}, uncovered


@pytest.mark.parametrize(
    "expression",
    [
        '_get_signal(dut, f"cpu_and_memory_subsystem.soc.{unknown_tap}")',
        '_get_signal(dut, f"{unknown_tap}")',
        'getattr(dut.cpu_and_memory_subsystem.soc, f"{unknown_tap}")',
        'f"cpu_and_memory_subsystem.soc.{unknown_tap}"',
    ],
)
def test_visibility_resolver_rejects_unknown_fstring_variables(
    tmp_path: Path, expression: str
) -> None:
    """Unresolvable path fields must name the bench, line, and variable."""
    bench = tmp_path / "unknown_fstring.py"
    bench.write_text(f"def bench(dut):\n    path = {expression}\n", encoding="utf-8")
    unresolved, _ = check_bench_paths_against_rules(build_rtl_hierarchy(), [], (bench,))
    assert unresolved == [f"{bench}:2: unresolvable f-string variable 'unknown_tap'"]


def test_visibility_resolver_rejects_unknown_fields_in_exported_paths(
    tmp_path: Path,
) -> None:
    """A path constant requires resolution even without a local DUT handle."""
    bench = tmp_path / "path_constants.py"
    bench.write_text(
        'PATH = f"cpu_and_memory_subsystem.soc.{unknown_tap}"\n', encoding="utf-8"
    )
    unresolved, _ = check_bench_paths_against_rules(build_rtl_hierarchy(), [], (bench,))
    assert unresolved == [f"{bench}:1: unresolvable f-string variable 'unknown_tap'"]


def test_visibility_resolver_rejects_fstring_format_fields(tmp_path: Path) -> None:
    """Formatting a known path field cannot hide unknown formatting variables."""
    bench = tmp_path / "formatted_path.py"
    bench.write_text(
        'def bench(dut):\n    _get_signal(dut, f"cpu_and_memory_subsystem.cpu.hart.cpu_inst.{pc_tap:{unknown_width}}")\n',
        encoding="utf-8",
    )
    rules = parse_vlt_rules(VISIBILITY_FILE.read_text(encoding="utf-8"))
    unresolved, _ = check_bench_paths_against_rules(
        build_rtl_hierarchy(), rules, (bench,)
    )
    assert f"{bench}:2: unresolvable f-string variable 'unknown_width'" in unresolved


@pytest.mark.parametrize(
    ("path", "module", "signal"),
    [
        ("instruction_from_testbench", "cpu_tb", "instruction_from_testbench"),
        ("mtime", "soc_top", "mtime"),
        ("soc.mtime", "soc_top", "mtime"),
        ("cpu_and_memory_subsystem.local_state_q", "soc_top", "local_state_q"),
    ],
)
def test_visibility_resolver_checks_alternative_roots(
    tmp_path: Path, path: str, module: str, signal: str
) -> None:
    """Shared tops and implicit platform prefixes require matching rules."""
    bench = tmp_path / "alternative_root.py"
    bench.write_text(
        f'def bench(dut):\n    _get_signal(dut, "{path}")\n', encoding="utf-8"
    )
    modules = build_rtl_hierarchy()
    assert not resolve_rtl_path(modules, path)
    unresolved, uncovered = check_bench_paths_against_rules(modules, [], (bench,))
    assert not unresolved
    assert any(
        f"{bench}:2: {path}" in item and f"{module}.{signal}" in item
        for item in uncovered
    )
    assert check_bench_paths_against_rules(
        modules,
        [
            *parse_vlt_rules(VISIBILITY_FILE.read_text(encoding="utf-8")),
            ("public_flat_rd", module, signal, 1),
        ],
        (bench,),
    ) == ([], [])


@pytest.mark.parametrize(
    "body",
    [
        "    signal.value = 1",
        "    signal.value = Force(1)",
        "    signal.value = Release()",
        "    signal.value += 1",
        "    signal.set(Force(1))",
        "    signal.set(Release())",
        "    signal.setimmediatevalue(1)",
        '    _get_signal(dut, "cpu_and_memory_subsystem.soc.mtime").value = 1',
        '    _first_signal(dut, ["cpu_and_memory_subsystem.soc.mtime"]).value = 1',
        '    getattr(dut.cpu_and_memory_subsystem.soc, "mtime").value = 1',
        "    _load_image(signal)\ndef _load_image(target):\n    target.value = Immediate(1)",
        "    alias = _handle(signal)\n    alias.value = 1\ndef _handle(target):\n    return target",
        "    array = [signal]\n    for element in array:\n        element.value = 1",
        "    signal[0].value = 1",
        "    self.saved = signal\n    self.saved.value = 1",
    ],
)
def test_visibility_resolver_requires_writable_rules(tmp_path: Path, body: str) -> None:
    """Deposits, forced values, releases, and image loads require public_flat_rw."""
    bench = tmp_path / "readonly_write.py"
    bench.write_text(
        "def bench(dut):\n    signal = dut.cpu_and_memory_subsystem.soc.mtime\n"
        + body
        + "\n",
        encoding="utf-8",
    )
    modules = build_rtl_hierarchy()
    rd_rules = [("public_flat_rd", "soc_top", "mtime", 1)]
    unresolved, uncovered = check_bench_paths_against_rules(modules, rd_rules, (bench,))
    assert not unresolved
    assert any(
        "soc_top.mtime requires public_flat_rw for write" in item for item in uncovered
    ), uncovered
    assert check_bench_paths_against_rules(
        modules, [("public_flat_rw", "soc_top", "mtime", 1)], (bench,)
    ) == ([], [])


def test_visibility_resolver_allows_readonly_reads(tmp_path: Path) -> None:
    """Sampling a signal does not require public_flat_rw."""
    bench = tmp_path / "readonly_read.py"
    bench.write_text(
        "def bench(dut):\n    return int(dut.cpu_and_memory_subsystem.soc.mtime.value)\n",
        encoding="utf-8",
    )
    assert check_bench_paths_against_rules(
        build_rtl_hierarchy(), [("public_flat_rd", "soc_top", "mtime", 1)], (bench,)
    ) == ([], [])


def test_visibility_resolver_checks_only_active_shared_top_branches(
    tmp_path: Path,
) -> None:
    """A shared helper's alternate-top writes are checked when the helper is called."""
    bench = tmp_path / "shared_top.py"
    source = (
        "def other_top(dut):\n    dut.instruction_from_testbench.value = 1\n"
        "def bench(dut):\n    is_frost = hasattr(dut, 'i_rst_n')\n"
        "    if not is_frost:\n        other_top(dut)\n"
    )
    bench.write_text(source, encoding="utf-8")
    modules = build_rtl_hierarchy()
    rules = parse_vlt_rules(VISIBILITY_FILE.read_text(encoding="utf-8"))
    assert check_bench_paths_against_rules(modules, rules, (bench,)) == ([], [])

    unguarded = tmp_path / "unguarded_top.py"
    unguarded.write_text(source + "    other_top(dut)\n", encoding="utf-8")
    unresolved, uncovered = check_bench_paths_against_rules(
        modules, rules, (unguarded,)
    )
    assert not unresolved
    assert any(
        "cpu_tb.instruction_from_testbench requires public_flat_rw for write" in item
        for item in uncovered
    ), uncovered


@pytest.mark.parametrize("name", ["read", "set"])
def test_visibility_resolver_distinguishes_methods_from_signal_names(
    tmp_path: Path, name: str
) -> None:
    """A handle method name can also name an HDL leaf in a hierarchy."""
    bench = tmp_path / "method_name.py"
    bench.write_text(f"def bench(dut):\n    dut.{name}.value = 1\n", encoding="utf-8")
    modules: dict[str, dict[str, object]] = {
        "frost": {"inst": {}, "gen": set(), "idents": {name}}
    }
    unresolved, uncovered = check_bench_paths_against_rules(
        modules, [("public_flat_rd", "frost", name, 1)], (bench,)
    )
    assert not unresolved
    assert any(
        f"frost.{name} requires public_flat_rw for write" in item for item in uncovered
    ), uncovered
    assert check_bench_paths_against_rules(
        modules, [("public_flat_rw", "frost", name, 1)], (bench,)
    ) == ([], [])


@pytest.mark.parametrize(
    ("module", "signal"),
    [
        (mod, var)
        for directive, mod, var, _ in parse_vlt_rules(
            VISIBILITY_FILE.read_text(encoding="utf-8")
        )
        if directive == "public_flat_rw"
    ],
)
def test_visibility_resolver_detects_downgraded_write_rules(
    module: str, signal: str
) -> None:
    """Every driven rule must be checked as writable in the full bench inventory."""
    rules = [
        (
            "public_flat_rd" if (mod, var) == (module, signal) else directive,
            mod,
            var,
            line,
        )
        for directive, mod, var, line in parse_vlt_rules(
            VISIBILITY_FILE.read_text(encoding="utf-8")
        )
    ]
    unresolved, uncovered = check_bench_paths_against_rules(
        build_rtl_hierarchy(),
        rules,
        discover_frost_bench_files(),
        discover_frost_shared_helpers(),
    )
    assert not unresolved, unresolved
    assert any("requires public_flat_rw for write" in item for item in uncovered), (
        module,
        signal,
        uncovered,
    )


def test_selective_visibility_makefile_and_thread_flags(tmp_path: Path) -> None:
    """Check selective visibility, waveform preservation, full-visibility overrides, and Verilator 5.052 check."""
    default_frost = _make_dry_run(tmp_path, "frost")
    assert "--public-flat-rw" not in default_frost
    assert "-fico-change-detect" in default_frost
    assert "+define+FROST_NO_RETIRE_TRACE" in default_frost
    assert "--threads" not in default_frost
    assert default_frost.index("frost_cocotb_visibility.vlt") < default_frost.index(
        " -f "
    )

    retire_on = _make_dry_run(tmp_path, "frost", "FROST_RETIRE_TRACE=1")
    assert "+define+FROST_NO_RETIRE_TRACE" not in retire_on
    assert "--public-flat-rw" not in retire_on

    # WAVES=1 stays on the selective build, remains single-threaded, and passes --trace at runtime.
    waves_cmd = _make_dry_run(tmp_path, "frost", "WAVES=1", "FROST_VERILATOR_THREADS=4")
    assert "--public-flat-rw" not in waves_cmd
    assert "frost_cocotb_visibility.vlt" in waves_cmd
    assert "-fico-change-detect" in waves_cmd
    assert "--trace-fst" in waves_cmd
    assert "--threads" not in waves_cmd

    waves_build = tmp_path / "waves_sim_build"
    waves_build.mkdir(exist_ok=True)
    (waves_build / "Vtop.mk").write_text("", encoding="utf-8")
    (waves_build / "Vtop").write_text("", encoding="utf-8")
    waves_run = subprocess.run(
        [
            "make",
            "--no-print-directory",
            "-f",
            str(ROOT / "tests" / "Makefile"),
            f"ROOT={ROOT}",
            "TOPLEVEL=frost",
            f"SIM_BUILD={waves_build}",
            "NUMBER_OF_CPU_CORES=4",
            *_ensure_verilator_stub_if_needed(tmp_path),
            "WAVES=1",
            "results.xml",
            "-n",
        ],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert waves_run.returncode == 0, waves_run.stdout + waves_run.stderr
    assert any(
        f"{waves_build}/Vtop" in line and " --trace " in f" {line} "
        for line in waves_run.stdout.splitlines()
    ), waves_run.stdout

    for override in (
        "FROST_COVERAGE=1",
        "FROST_FULL_VISIBILITY=1",
        "FROST_HANG_PROBE=1",
    ):
        full_cmd = _make_dry_run(
            tmp_path, "frost", override, "FROST_VERILATOR_THREADS=4"
        )
        assert "--public-flat-rw" in full_cmd, override
        assert "frost_cocotb_visibility.vlt" not in full_cmd, override
        assert "-fico-change-detect" not in full_cmd, override
        assert "--threads" not in full_cmd, override

    unit_cmd = _make_dry_run(
        tmp_path, "cdb_arbiter", "FROST_VERILATOR_THREADS=4", "FROST_RETIRE_TRACE=0"
    )
    assert "--public-flat-rw" in unit_cmd
    assert "frost_cocotb_visibility.vlt" not in unit_cmd
    assert "+define+FROST_NO_RETIRE_TRACE" not in unit_cmd
    assert "--threads" not in unit_cmd

    threaded_capped = _make_dry_run(
        tmp_path, "frost", "FROST_VERILATOR_THREADS=8", "NUMBER_OF_CPU_CORES=2"
    )
    assert "--threads 2 -Wno-UNOPTTHREADS" in threaded_capped

    threaded_single = _make_dry_run(
        tmp_path, "frost", "FROST_VERILATOR_THREADS=4", "NUMBER_OF_CPU_CORES=1"
    )
    assert "--threads" not in threaded_single

    # A Verilator lacking -fico-change-detect (e.g. 5.045) must fail with one clear sentence.
    old_vlt_dir = tmp_path / "verilator_5045_stub"
    old_vlt_dir.mkdir()
    old_vlt = old_vlt_dir / "verilator"
    old_vlt.write_text(
        "#!/usr/bin/env bash\n"
        'if [[ "$1" == "--version" ]]; then echo "Verilator 5.045 devel"; exit 0; fi\n'
        'for arg in "$@"; do\n'
        '  if [[ "$arg" == "-fico-change-detect" ]]; then exit 1; fi\n'
        "done\n"
        "exit 0\n",
        encoding="utf-8",
    )
    old_vlt.chmod(0o755)
    old_proc = subprocess.run(
        [
            "make",
            "--no-print-directory",
            "-f",
            str(ROOT / "tests" / "Makefile"),
            f"ROOT={ROOT}",
            "TOPLEVEL=frost",
            f"SIM_BUILD={tmp_path / 'old_vlt_build'}",
            f"VERILATOR_BIN_DIR={old_vlt_dir}",
            "-n",
        ],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert old_proc.returncode != 0
    assert (
        "Selective-visibility frost builds require Verilator 5.052 or newer for "
        "-fico-change-detect" in old_proc.stderr
    )
    assert "5.045" in old_proc.stderr
    assert "FROST_FULL_VISIBILITY=1" in old_proc.stderr

    for bad_arg, expected in (
        ("FROST_FULL_VISIBILITY=2", "FROST_FULL_VISIBILITY must be 0 or 1"),
        ("FROST_RETIRE_TRACE=yes", "FROST_RETIRE_TRACE must be 0 or 1"),
        (
            "FROST_VERILATOR_THREADS=0",
            "FROST_VERILATOR_THREADS must be a positive integer",
        ),
    ):
        proc = subprocess.run(
            [
                "make",
                "--no-print-directory",
                "-f",
                str(ROOT / "tests" / "Makefile"),
                f"ROOT={ROOT}",
                "TOPLEVEL=frost",
                f"SIM_BUILD={tmp_path / 'bad'}",
                *_ensure_verilator_stub_if_needed(tmp_path),
                bad_arg,
                "-n",
            ],
            cwd=tmp_path,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert proc.returncode != 0
        assert expected in proc.stderr


def test_selective_visibility_error_message_and_probing_helpers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Check HierarchyObject.__getattr__, _get_signal, _first_signal, and UartMonitor."""
    verif_dir = str(ROOT / "verif")
    if verif_dir not in sys.path:
        sys.path.insert(0, verif_dir)
    import cocotb_tests  # noqa: F401
    from cocotb.handle import HierarchyObject
    from cocotb_tests import test_real_program

    fake = object.__new__(HierarchyObject)
    object.__setattr__(fake, "_sub_handles", {})
    object.__setattr__(fake, "_discovered", True)
    object.__setattr__(fake, "_path", "frost.cpu_and_memory_subsystem.soc")

    monkeypatch.setenv("FROST_SELECTIVE_VISIBILITY", "1")
    assert not hasattr(fake, "unlisted_wire")
    with pytest.raises(AttributeError) as exc_info:
        _ = fake.unlisted_wire
    message = str(exc_info.value)
    assert "hw/sim/frost_cocotb_visibility.vlt" in message
    assert "FROST_FULL_VISIBILITY=1" in message

    dut = SimpleNamespace(
        i_clk=object(),
        cpu_and_memory_subsystem=SimpleNamespace(soc=SimpleNamespace()),
    )
    with pytest.raises(AttributeError, match="frost_cocotb_visibility.vlt"):
        test_real_program._get_signal(dut, "cpu_and_memory_subsystem.soc.mtime")
    with pytest.raises(AttributeError, match="frost_cocotb_visibility.vlt"):
        test_real_program._first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.soc.mmio_read_pulse",
                "cpu_and_memory_subsystem.cpu.hart.cpu_inst.o_mmio_read_pulse",
            ],
        )
    # Optional per-platform prefixes still return None cleanly when absent.
    assert (
        test_real_program._get_signal(
            dut,
            "cpu_and_memory_subsystem.soc.gen_behavioral_ddr.ddr_model.i_axi_awvalid",
        )
        is None
    )

    # UartMonitor must re-raise AttributeError under selective visibility.
    monkeypatch.setattr(test_real_program, "RisingEdge", lambda clk: clk)
    monitor = test_real_program.UartMonitor(dut)
    with pytest.raises(AttributeError):
        asyncio.run(monitor._monitor_uart())

    monkeypatch.setenv("FROST_SELECTIVE_VISIBILITY", "0")
    assert (
        test_real_program._get_signal(dut, "cpu_and_memory_subsystem.soc.mtime") is None
    )
    with pytest.raises(AttributeError) as plain_exc:
        _ = fake.unlisted_wire
    assert "hw/sim/frost_cocotb_visibility.vlt" not in str(plain_exc.value)


def test_reorder_buffer_preprocessed_views_match_without_guard(
    tmp_path: Path,
) -> None:
    """Check synthesis, formal, and unit preprocessed views of reorder_buffer.sv."""
    verilator = shutil.which("verilator")
    if verilator is None:
        pytest.skip("verilator is not on PATH")

    source = REORDER_BUFFER_SV.read_text(encoding="utf-8")
    guard_pattern = re.compile(
        r"`ifndef FROST_NO_RETIRE_TRACE\n(.*?)\n(\s*)`endif\n", re.DOTALL
    )
    match = guard_pattern.search(source)
    assert match is not None, "missing FROST_NO_RETIRE_TRACE guard in reorder_buffer.sv"
    unguarded_source = (
        source[: match.start()] + match.group(1) + "\n" + source[match.end() :]
    )
    assert unguarded_source != source

    unguarded_file = tmp_path / "reorder_buffer_unguarded.sv"
    unguarded_file.write_text(unguarded_source, encoding="utf-8")

    packages = [
        str(ROOT / "hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv"),
        str(
            ROOT
            / "hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/sfence_operand_store.sv"
        ),
    ]

    def preprocess(target: Path, *defines: str) -> str:
        proc = subprocess.run(
            [verilator, "-E", "-P", *defines, *packages, str(target)],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        )
        return proc.stdout

    for flag in ("-DSYNTHESIS", "-DFORMAL", ""):
        extra = (flag,) if flag else ()
        actual = preprocess(REORDER_BUFFER_SV, *extra)
        reference = preprocess(unguarded_file, *extra)
        assert actual == reference, f"preprocessed view differs for {flag or 'unit'}"

    unit_view = preprocess(REORDER_BUFFER_SV)
    assert "retire_trace_fd" in unit_view
    suppressed_view = preprocess(REORDER_BUFFER_SV, "-DFROST_NO_RETIRE_TRACE")
    assert "retire_trace_fd" not in suppressed_view


def test_ci_workflow_verilator_threads_bounded() -> None:
    """Check that CI thread settings are 1 everywhere in Part A and forwarded to Docker."""
    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    jobs = workflow["jobs"]
    expected_jobs = (
        "build-sim-models",
        "test-verilator",
        "test-pa-width",
        "test-arch-compliance",
        "test-riscv-tests",
        "test-riscv-benchmarks",
        "test-riscv-torture",
        "test-testrig",
        "test-testrig-vector",
        "test-native",
    )
    for job_id in expected_jobs:
        job = jobs[job_id]
        candidate_envs = [
            job.get("env", {}),
            *(step.get("env", {}) for step in job.get("steps", [])),
        ]
        env_maps = [
            env_map
            for env_map in candidate_envs
            if isinstance(env_map, dict) and "FROST_VERILATOR_THREADS" in env_map
        ]
        assert env_maps, f"{job_id} is missing FROST_VERILATOR_THREADS"
        for env_map in env_maps:
            expr = str(env_map["FROST_VERILATOR_THREADS"]).strip()
            assert expr == "1", (
                f"{job_id} must set FROST_VERILATOR_THREADS to 1 in Part A, got: {expr}"
            )

        for step in job.get("steps", []):
            run_cmd = str(step.get("run", ""))
            if "docker run" in run_cmd and "FROST_VERILATOR_THREADS" in step.get(
                "env", {}
            ):
                assert "-e FROST_VERILATOR_THREADS" in run_cmd, (
                    f"{job_id} docker run does not forward FROST_VERILATOR_THREADS"
                )


def _run_negative_probe(tmp_path: Path, test_name: str) -> tuple[int, str]:
    """Execute one negative probe through test_run_cocotb.py into a log file."""
    env = os.environ.copy()
    for key in (
        "WAVES",
        "FROST_COVERAGE",
        "FROST_COVERAGE_TOGGLE",
        "FROST_FULL_VISIBILITY",
        "FROST_HANG_PROBE",
        "COCOTB_TEST_FILTER",
    ):
        env.pop(key, None)
    log_path = tmp_path / f"{test_name}.log"
    with log_path.open("w", encoding="utf-8") as log_file:
        subprocess.run(
            ["make", "clean"],
            cwd=ROOT / "tests",
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            timeout=60,
            check=True,
        )
        result = subprocess.run(
            [sys.executable, str(ROOT / "tests" / "test_run_cocotb.py"), test_name],
            cwd=ROOT / "tests",
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            timeout=900,
            check=False,
        )
    with log_path.open("rb") as log_bytes:
        size = log_path.stat().st_size
        if size > MAX_LOG_READ_BYTES:
            log_bytes.seek(size - MAX_LOG_READ_BYTES)
        output = log_bytes.read(MAX_LOG_READ_BYTES).decode("utf-8", errors="replace")
    return result.returncode, output


@pytest.mark.cocotb
@pytest.mark.slow
def test_unlisted_signal_probe_fails_with_clear_message(tmp_path: Path) -> None:
    """Touching an unlisted internal signal fails and names the visibility file."""
    returncode, output = _run_negative_probe(tmp_path, "frost_unlisted_signal_probe")
    assert returncode != 0, output
    assert "prog_port_imem_we" in output
    assert "hw/sim/frost_cocotb_visibility.vlt" in output
    assert "FROST_FULL_VISIBILITY=1" in output


@pytest.mark.cocotb
@pytest.mark.slow
def test_deliberate_assertion_violation_fires_in_selective_flow(
    tmp_path: Path,
) -> None:
    """Tripping nic_engine's assertion control fires its post-reset assertion."""
    returncode, output = _run_negative_probe(
        tmp_path, "frost_deliberate_assertion_violation"
    )
    assert returncode != 0, output
    assert "nic_rst_q is not the registered reset OR the RESET pulse" in output

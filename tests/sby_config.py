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

"""Read the repository's SBY dialect, resolve tasks, and parse closed Yosys scripts."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from collections.abc import Iterable
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

NAME = r"[A-Za-z0-9_]+"
FILENAME = r"[A-Za-z0-9_][A-Za-z0-9_.-]*"
HEADER = re.compile(rf"\[(tasks|options|engines|script|files|file {FILENAME})\]")
BLANK = re.compile(r"[ \t]*")
COMMENT = re.compile(r"[ \t]*#.*")
TASKS_ENTRY = re.compile(
    rf"[ \t]*({NAME}(?:[ \t]+{NAME})*)(:[ \t]*(?:{NAME}(?:[ \t]+{NAME})*)?)?[ \t]*"
)
TAG = re.compile(rf"(~?)({NAME}):(.*)")
BLOCK_END = re.compile(r"[ \t]*--[ \t]*")
FILE_PATH = re.compile(rf"(?:(?:\.\.|{FILENAME})/)*{FILENAME}")
OPTION_ENTRY = re.compile(r"[A-Za-z0-9_]+(?:[ \t]+[^\s#]+)+")
ENGINE_ENTRY = re.compile(r"[A-Za-z0-9_]+(?:[ \t]+[^\s#]+)*")

# Argument token patterns for the closed Yosys command language.
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
INT = re.compile(r"[0-9]+")
ONE = re.compile(r"1")
DOTDOT = re.compile(r"\.\.")
QUOTED_WORD = re.compile(r'"[A-Za-z0-9_]+"')
DEFINE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:=[A-Za-z0-9_'+-]+)?")
SLANG_PARAM = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=[0-9]+")
PARAM_VALUE = re.compile(
    r'(?:[0-9]+|\d+\'[sS]?[bBoOdDhH][0-9a-fA-F_]+|"[A-Za-z0-9_]+")'
)
SOURCE_FILE = re.compile(r"(?:\+/xilinx/cells_sim\.v|[A-Za-z0-9_][A-Za-z0-9_.-]*\.s?v)")
YS_FILE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\.ys")
SELECTION = re.compile(r"[A-Za-z0-9_$%*@\\][A-Za-z0-9_$%*@\\./:=\[\]+-]*")
AT_SELECTION = re.compile(r"@[A-Za-z_][A-Za-z0-9_]*")
PERCENT_DESIGN = re.compile(r"%[A-Za-z_][A-Za-z0-9_]*")
RTLIL_IDENT = re.compile(r"\\[A-Za-z_][A-Za-z0-9_]*")
UNDEFINED_CONSTANT = re.compile(r"\d*'[sS]?[bBoOdDhH]?[0-9a-fA-F_xXzZ?]*[xXzZ?]")
CONNECT_EXPR = re.compile(
    r"(?!.*(?:\d*'[sS]?[bBoOdDhH]?[0-9a-fA-F_xXzZ?]*[xXzZ?]))"
    r"[A-Za-z0-9_$\\{}'\[\].:,]+"
)
SAT_EXPR = re.compile(r"[A-Za-z_][A-Za-z0-9_\[\]:]*")
JSON_OUTPUT = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\.json")
RTLIL_OUTPUT = re.compile(r"(?:\.\./model/)?[A-Za-z0-9_][A-Za-z0-9_.-]*\.il")
LOG_FIRST_WORD = re.compile(r"(?!End$)[A-Za-z_][A-Za-z0-9_.,:/-]*")
LOG_WORD = re.compile(r"[A-Za-z0-9_.,:/-]+")
ATTR_SET_NAME = re.compile(r"(?:keep|from_prim)")
ATTR_UNSET_NAME = re.compile(r"(?:init|keep|keep_hierarchy|dont_touch)")
EQX_SOURCE = re.compile(r"\$(?:eqx|nex)")
EQX_TARGET = re.compile(r"\$(?:eq|ne)")
AND_GATE = re.compile(r"AND")
POS_INT = re.compile(r"[1-9][0-9]*")

ALLOWED_FILE_SUFFIXES: tuple[str, ...] = (".sv", ".v", ".svh", ".vh", ".ys")
DEFINE_INPUTS_PATH = Path("tests/formal_define_inputs.json")

# Closed [options] keys and value patterns across all formal/*.sby tasks.
OPTION_SPECS: dict[str, re.Pattern[str]] = {
    "mode": re.compile(r"bmc|prove|cover"),
    "depth": POS_INT,
    "timeout": POS_INT,
    "aigsmt": re.compile(r"boolector"),
    "multiclock": re.compile(r"on"),
    "vcd": re.compile(r"off"),
    "vcd_sim": re.compile(r"on"),
    "skip": POS_INT,
}

# Closed [engines] forms mapped to the [options] modes in which each may run.
ENGINE_FORMS: dict[tuple[str, ...], frozenset[str]] = {
    ("smtbmc", "boolector"): frozenset({"bmc", "prove", "cover"}),
    ("smtbmc", "z3"): frozenset({"bmc", "prove", "cover"}),
    ("smtbmc", "--nopresat", "boolector"): frozenset({"bmc"}),
    ("smtbmc", "--nopresat", "boolector", "--", "--noincr"): frozenset({"prove"}),
    ("btor", "btormc"): frozenset({"bmc", "cover"}),
    ("abc", "bmc3"): frozenset({"bmc"}),
    ("abc", "bmc3", "-c"): frozenset({"bmc"}),
    ("abc", "bmc3", "-c", "-S", "139"): frozenset({"bmc"}),
    ("abc", "bmc3", "-g"): frozenset({"bmc"}),
    ("abc", "pdr"): frozenset({"prove"}),
    ("abc", "pdr", "-r"): frozenset({"prove"}),
    ("abc", "lcorr;", "pdr"): frozenset({"prove"}),
}

FRONT_END_SAFE = "reads sources; the design it builds is the design the proof checks"
UNCHANGED_SAFE = "changes nothing in the design"


class ConfigError(ValueError):
    """A script uses syntax or commands outside the repository's proof dialect."""


def check_text_bytes(raw: bytes, origin: str) -> str:
    """Decode raw bytes as ASCII and refuse CR, NUL, control, and non-ASCII bytes.

    Allowed bytes are horizontal tab (0x09), line feed (0x0A), and printable
    ASCII (0x20..0x7E). Refusing CR (0x0D) and every other control byte ensures
    Python readers, SymbiYosys, and Yosys's fgets split every line identically.
    """
    line_no = 1
    for byte in raw:
        if byte == 0x0A:
            line_no += 1
        elif byte != 0x09 and not (0x20 <= byte <= 0x7E):
            raise ConfigError(f"{origin}:{line_no}: disallowed byte 0x{byte:02x}")
    return raw.decode("ascii")


def read_checked_text(path: Path) -> str:
    """Read path as raw bytes and validate every byte against check_text_bytes."""
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise ConfigError(f"{path.name}: {error}") from error
    return check_text_bytes(raw, path.name)


def split_lf_lines(text: str, origin: str) -> list[str]:
    """Validate text against the byte rule and split lines on LF (0x0A) only."""
    try:
        raw = text.encode("ascii")
    except UnicodeEncodeError as error:
        bad = text[error.start]
        line_no = text.count("\n", 0, error.start) + 1
        raise ConfigError(
            f"{origin}:{line_no}: disallowed character U+{ord(bad):04X}"
        ) from error
    check_text_bytes(raw, origin)
    if not text:
        return []
    return text.removesuffix("\n").split("\n")


@dataclass(frozen=True)
class CommandForm:
    """One allowed Yosys command form, with its state transition and properties."""

    id: str
    command: str
    flags: frozenset[str] = frozenset()
    required_flags: frozenset[str] = frozenset()
    any_of_flags: frozenset[str] = frozenset()
    max_optional_flags: int | None = None
    opt_args: tuple[tuple[str, tuple[re.Pattern[str], ...]], ...] = ()
    required_opts: frozenset[str] = frozenset()
    repeatable_opts: frozenset[str] = frozenset()
    prefix_opts: tuple[tuple[str, re.Pattern[str]], ...] = ()
    min_options: int = 0
    pos_arity: str = "0"
    pos_pattern: re.Pattern[str] | None = None
    first_pos_pattern: re.Pattern[str] | None = None
    safe_reason: str | None = None
    rejected_reason: str | None = None
    writes_file: bool = False
    transition: str = "act"
    log_kind: str = "pass"

    def __post_init__(self) -> None:
        """Require each form to be either don't-care safe or explicitly rejected."""
        assert (self.safe_reason is not None) != (self.rejected_reason is not None), (
            self.id
        )
        assert self.any_of_flags <= self.flags, self.id

    @property
    def is_safe(self) -> bool:
        """Report whether this form preserves undefined initial and input values."""
        return self.safe_reason is not None

    def matches(self, args: tuple[str, ...] | list[str]) -> bool:
        """Report whether args match this command, every option, and every argument."""
        if not args or args[0] != self.command:
            return False
        opt_map = dict(self.opt_args)
        seen_flags: set[str] = set()
        seen_opts: set[str] = set()
        option_count = 0
        positional: list[str] = []
        index = 1
        while index < len(args):
            token = args[index]
            if token in self.flags or token in self.required_flags:
                if token in seen_flags:
                    return False
                seen_flags.add(token)
                option_count += 1
                index += 1
                continue
            if token in opt_map:
                if token in seen_opts and token not in self.repeatable_opts:
                    return False
                patterns = opt_map[token]
                if index + len(patterns) >= len(args):
                    return False
                for offset, pattern in enumerate(patterns, 1):
                    if not pattern.fullmatch(args[index + offset]):
                        return False
                seen_opts.add(token)
                option_count += 1
                index += 1 + len(patterns)
                continue
            matched_prefix = False
            for prefix, pattern in self.prefix_opts:
                if token.startswith(prefix) and len(token) > len(prefix):
                    if not pattern.fullmatch(token[len(prefix) :]):
                        return False
                    matched_prefix = True
                    option_count += 1
                    break
            if matched_prefix:
                index += 1
                continue
            if token.startswith("-"):
                return False
            positional.append(token)
            index += 1
        if not (self.required_flags <= seen_flags and self.required_opts <= seen_opts):
            return False
        if self.any_of_flags and not (seen_flags & self.any_of_flags):
            return False
        if option_count < self.min_options:
            return False
        if (
            self.max_optional_flags is not None
            and len(seen_flags - self.required_flags) > self.max_optional_flags
        ):
            return False
        if self.pos_arity == "0":
            return len(positional) == 0
        assert self.pos_pattern is not None
        if not all(self.pos_pattern.fullmatch(word) for word in positional):
            return False
        if (
            positional
            and self.first_pos_pattern is not None
            and not self.first_pos_pattern.fullmatch(positional[0])
        ):
            return False
        if self.pos_arity == "0..1":
            return len(positional) <= 1
        if self.pos_arity == "1":
            return len(positional) == 1
        if self.pos_arity == "3":
            return len(positional) == 3
        if self.pos_arity == "0+":
            return True
        if self.pos_arity == "1+":
            return len(positional) >= 1
        raise AssertionError(self.pos_arity)


# Closed language of every command form used by the formal scripts on main.
# No command, option or argument outside this tuple may appear in [script], an
# inline [file ...] script, or an included .ys script.
SCRIPT_FORMS: tuple[CommandForm, ...] = (
    # Source reading, macro definitions, parameter overrides, and elaboration.
    CommandForm(
        "read_sources",
        "read",
        flags=frozenset({"-formal", "-sv", "-noautowire", "-nosynthesis"}),
        any_of_flags=frozenset({"-formal", "-sv"}),
        opt_args=(("-D", (DEFINE,)),),
        repeatable_opts=frozenset({"-D"}),
        prefix_opts=(("-D", DEFINE),),
        pos_arity="1+",
        pos_pattern=SOURCE_FILE,
        safe_reason=FRONT_END_SAFE,
        transition="source",
        log_kind="verilog",
    ),
    CommandForm(
        "read_define",
        "read",
        required_flags=frozenset({"-define"}),
        pos_arity="1+",
        pos_pattern=IDENT,
        safe_reason="sets macros for the readers that follow",
        transition="define",
        log_kind="none",
    ),
    CommandForm(
        "read_verilog",
        "read_verilog",
        flags=frozenset({"-formal", "-sv"}),
        any_of_flags=frozenset({"-formal", "-sv"}),
        opt_args=(("-D", (DEFINE,)),),
        repeatable_opts=frozenset({"-D"}),
        pos_arity="1+",
        pos_pattern=SOURCE_FILE,
        safe_reason=FRONT_END_SAFE,
        transition="source",
        log_kind="verilog",
    ),
    CommandForm(
        "read_slang",
        "read_slang",
        flags=frozenset({"--no-synthesis-define"}),
        required_flags=frozenset({"--single-unit"}),
        opt_args=(("--top", (IDENT,)), ("--blackboxed-module", (IDENT,))),
        required_opts=frozenset({"--top"}),
        repeatable_opts=frozenset({"--blackboxed-module"}),
        prefix_opts=(("-D", DEFINE), ("-G", SLANG_PARAM)),
        pos_arity="1+",
        pos_pattern=SOURCE_FILE,
        safe_reason=FRONT_END_SAFE,
        transition="source",
        log_kind="slang",
    ),
    CommandForm(
        "verilog_defines",
        "verilog_defines",
        opt_args=(("-D", (DEFINE,)),),
        repeatable_opts=frozenset({"-D"}),
        prefix_opts=(("-D", DEFINE),),
        min_options=1,
        safe_reason="sets macros for the readers that follow",
        transition="define",
        log_kind="none",
    ),
    CommandForm(
        "chparam",
        "chparam",
        opt_args=(("-set", (IDENT, PARAM_VALUE)),),
        required_opts=frozenset({"-set"}),
        repeatable_opts=frozenset({"-set"}),
        pos_arity="1",
        pos_pattern=IDENT,
        safe_reason="elaborates the module again with the parameters it sets",
        transition="source",
        log_kind="chparam",
    ),
    CommandForm(
        "hierarchy_top",
        "hierarchy",
        flags=frozenset({"-check"}),
        opt_args=(("-top", (IDENT,)),),
        required_opts=frozenset({"-top"}),
        safe_reason="elaborates the hierarchy below the top",
        transition="elaborate",
        log_kind="hierarchy",
    ),
    CommandForm(
        "hierarchy_chparam",
        "hierarchy",
        opt_args=(("-top", (IDENT,)), ("-chparam", (IDENT, PARAM_VALUE))),
        required_opts=frozenset({"-top", "-chparam"}),
        repeatable_opts=frozenset({"-chparam"}),
        safe_reason="elaborates the top with the parameter values it sets",
        transition="source",
        log_kind="hierarchy",
    ),
    CommandForm(
        "script",
        "script",
        pos_arity="1",
        pos_pattern=YS_FILE,
        safe_reason=UNCHANGED_SAFE,
        transition="open",
        log_kind="script",
    ),
    # Preparation, process lowering, and hierarchy flattening.
    CommandForm(
        "prep",
        "prep",
        flags=frozenset({"-flatten"}),
        opt_args=(("-top", (IDENT,)),),
        required_opts=frozenset({"-top"}),
        safe_reason=(
            "runs hierarchy -check, proc, check and flatten (with -flatten), future, "
            "opt_expr -keepdc, check, opt_clean, opt -noff -keepdc, wreduce -keepdc, "
            "opt_clean, memory_collect, opt -noff -keepdc -fast, sort, stat and check"
        ),
        transition="prep",
        log_kind="pass",
    ),
    CommandForm(
        "proc",
        "proc",
        flags=frozenset({"-noopt"}),
        safe_reason="lowers processes into cells and registers with the same initial values",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_clean",
        "proc_clean",
        safe_reason="removes empty switches; it folds only defined switch signals",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_rmdead",
        "proc_rmdead",
        safe_reason="removes cases that cannot match; a case label with x never matches",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_prune",
        "proc_prune",
        safe_reason="removes assignments that a later one overrides on every path",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_init",
        "proc_init",
        safe_reason="turns initial assignments into initial values",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_arst",
        "proc_arst",
        safe_reason="finds asynchronous resets",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_mux",
        "proc_mux",
        safe_reason=(
            "turns decision trees into multiplexers, with x only for the bits a full "
            "case leaves unassigned"
        ),
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_dlatch",
        "proc_dlatch",
        safe_reason="turns incomplete combinational assignments into latches",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_dff",
        "proc_dff",
        safe_reason="turns clocked processes into registers with the same initial values",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "proc_memwr",
        "proc_memwr",
        safe_reason="turns memory writes in processes into write ports",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "flatten",
        "flatten",
        safe_reason="inlines submodules with their initial values",
        transition="act",
        log_kind="pass",
    ),
    # Don't-care-preserving optimizations and cell lowering.
    CommandForm(
        "opt_keepdc",
        "opt",
        required_flags=frozenset({"-keepdc"}),
        flags=frozenset({"-fast", "-noff", "-purge"}),
        safe_reason=(
            "with -keepdc, opt_merge and opt_dff keep registers without a defined "
            "initial value and opt_expr skips rewrites that consume undefined bits"
        ),
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "opt_clean",
        "opt_clean",
        flags=frozenset({"-purge"}),
        safe_reason="removes unused cells and wires, leaving undefined drivers free",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "opt_expr",
        "opt_expr",
        required_flags=frozenset({"-keepdc"}),
        flags=frozenset({"-noclkinv"}),
        pos_arity="0+",
        pos_pattern=SELECTION,
        safe_reason="with -keepdc it skips rewrites that consume undefined bits",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "opt_muxtree",
        "opt_muxtree",
        safe_reason="removes multiplexer ports that cannot be selected",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "memory_map_keepdc",
        "memory_map",
        required_flags=frozenset({"-keepdc"}),
        safe_reason=(
            "with -keepdc a word without a defined initial value becomes a register, "
            "which SymbiYosys makes free"
        ),
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "setundef_anyseq",
        "setundef",
        required_flags=frozenset({"-anyseq"}),
        flags=frozenset({"-undriven"}),
        safe_reason=(
            "gives each undefined bit, and with -undriven each undriven net, its own "
            "$anyseq, as SymbiYosys's preparation does"
        ),
        transition="free_async",
        log_kind="pass",
    ),
    CommandForm(
        "setundef_anyseq_selected",
        "setundef",
        required_flags=frozenset({"-anyseq"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason="gives each selected undefined bit its own $anyseq",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "techmap",
        "techmap",
        safe_reason="maps cells to gates with the built-in library",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "async2sync",
        "async2sync",
        safe_reason=(
            "turns asynchronous resets, loads and set-reset into synchronous logic "
            "with the same initial values, writing x where set and reset are both active"
        ),
        transition="async",
        log_kind="pass",
    ),
    CommandForm(
        "dffunmap",
        "dffunmap",
        pos_arity="0+",
        pos_pattern=SELECTION,
        safe_reason="turns enables and synchronous resets into multiplexers",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "formalff",
        "formalff",
        required_flags=frozenset({"-clk2ff"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason="turns clocked flip-flops into $ff cells with the same initial values",
        transition="act",
        log_kind="pass",
    ),
    # Property selection, explicit netlist edits, attributes, and renaming.
    CommandForm(
        "chformal_remove",
        "chformal",
        required_flags=frozenset({"-remove"}),
        flags=frozenset({"-assert", "-assume", "-cover"}),
        pos_arity="0+",
        pos_pattern=SELECTION,
        safe_reason="removes the property cells it selects",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "chformal_coverenable",
        "chformal",
        required_flags=frozenset({"-assert", "-coverenable"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason="adds a cover of each selected assertion's enable signal",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "chformal_assert2assume",
        "chformal",
        required_flags=frozenset({"-assert2assume"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason="relabels selected assertions as assumptions",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "chformal_lower",
        "chformal",
        required_flags=frozenset({"-lower"}),
        safe_reason="lowers property cells without adding state",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "connect_set",
        "connect",
        flags=frozenset({"-nounset", "-nomap"}),
        opt_args=(("-set", (CONNECT_EXPR, CONNECT_EXPR)),),
        required_opts=frozenset({"-set"}),
        safe_reason="connects the nets the script names to defined signals or constants",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "connect_port",
        "connect",
        opt_args=(("-port", (IDENT, RTLIL_IDENT, RTLIL_IDENT)),),
        required_opts=frozenset({"-port"}),
        safe_reason="connects the cell port the script names",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "cutpoint",
        "cutpoint",
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason="drives each cut signal from its own $anyseq",
        transition="passive",
        log_kind="pass",
    ),
    CommandForm(
        "cutpoint_blackbox",
        "cutpoint",
        required_flags=frozenset({"-blackbox"}),
        safe_reason="drives blackbox outputs from unconstrained values",
        transition="passive",
        log_kind="pass",
    ),
    CommandForm(
        "delete",
        "delete",
        flags=frozenset({"-input", "-output", "-port"}),
        max_optional_flags=1,
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason=(
            "removes what it selects; what a removed cell drove is left undriven, "
            "which SymbiYosys makes free"
        ),
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "expose",
        "expose",
        required_flags=frozenset({"-dff", "-cut"}),
        pos_arity="1",
        pos_pattern=SELECTION,
        safe_reason="turns flip-flop outputs into module inputs, which are free",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "setattr_set",
        "setattr",
        opt_args=(("-set", (ATTR_SET_NAME, ONE)),),
        required_opts=frozenset({"-set"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason="sets an attribute that decides only what may be removed or selected",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "setattr_unset",
        "setattr",
        flags=frozenset({"-mod"}),
        opt_args=(("-unset", (ATTR_UNSET_NAME,)),),
        required_opts=frozenset({"-unset"}),
        pos_arity="0+",
        pos_pattern=SELECTION,
        safe_reason="removes the attribute; a register without init starts free",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "rename_top",
        "rename",
        opt_args=(("-top", (IDENT,)),),
        required_opts=frozenset({"-top"}),
        safe_reason="renames the top module",
        transition="rename_top",
        log_kind="none",
    ),
    CommandForm(
        "rename_hide",
        "rename",
        required_flags=frozenset({"-hide"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason="hides internal wire names after opening",
        transition="act",
        log_kind="none",
    ),
    CommandForm(
        "autoname",
        "autoname",
        pos_arity="1",
        pos_pattern=re.compile(r"t:\$anyseq"),
        rejected_reason="public free-cell names decide which values equiv_make pairs",
        transition="act",
        log_kind="pass",
    ),
    # Design management.
    CommandForm(
        "design_stash",
        "design",
        opt_args=(("-stash", (IDENT,)),),
        required_opts=frozenset({"-stash"}),
        safe_reason="stashes an opened design under a name and clears the current design",
        transition="design_stash",
        log_kind="none",
    ),
    CommandForm(
        "design_save",
        "design",
        opt_args=(("-save", (IDENT,)),),
        required_opts=frozenset({"-save"}),
        safe_reason="saves a copy of an opened design under a name",
        transition="design_save",
        log_kind="none",
    ),
    CommandForm(
        "design_load",
        "design",
        opt_args=(("-load", (IDENT,)),),
        required_opts=frozenset({"-load"}),
        safe_reason="loads a saved opened design",
        transition="design_load",
        log_kind="none",
    ),
    CommandForm(
        "design_reset",
        "design",
        required_flags=frozenset({"-reset"}),
        safe_reason="clears the current design",
        transition="design_reset",
        log_kind="none",
    ),
    CommandForm(
        "design_delete",
        "design",
        opt_args=(("-delete", (IDENT,)),),
        required_opts=frozenset({"-delete"}),
        safe_reason="drops a saved design slot",
        transition="design_delete",
        log_kind="none",
    ),
    CommandForm(
        "design_copy_from",
        "design",
        opt_args=(("-copy-from", (IDENT,)), ("-as", (IDENT,))),
        required_opts=frozenset({"-copy-from", "-as"}),
        pos_arity="1",
        pos_pattern=IDENT,
        safe_reason="copies a module from a saved design without changing its cells",
        transition="design_copy_from",
        log_kind="none",
    ),
    # Equivalence construction, selection assertions, scoping, checks, and outputs.
    CommandForm(
        "equiv_make",
        "equiv_make",
        pos_arity="3",
        pos_pattern=IDENT,
        safe_reason="builds the module that compares two designs; undriven nets become x",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "equiv_status",
        "equiv_status",
        required_flags=frozenset({"-assert"}),
        pos_arity="0..1",
        pos_pattern=AT_SELECTION,
        safe_reason=UNCHANGED_SAFE,
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "select_assert_count",
        "select",
        opt_args=(("-assert-count", (INT,)),),
        required_opts=frozenset({"-assert-count"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason=UNCHANGED_SAFE,
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "select_assert_min",
        "select",
        opt_args=(("-assert-min", (INT,)),),
        required_opts=frozenset({"-assert-min"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason=UNCHANGED_SAFE,
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "select_assert_none",
        "select",
        required_flags=frozenset({"-assert-none"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason=UNCHANGED_SAFE,
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "select_set",
        "select",
        opt_args=(("-set", (IDENT,)),),
        required_opts=frozenset({"-set"}),
        pos_arity="1+",
        pos_pattern=SELECTION,
        safe_reason="saves a named selection without changing the active selection",
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "select_module",
        "select",
        opt_args=(("-module", (IDENT,)),),
        required_opts=frozenset({"-module"}),
        safe_reason="sets the active module selection",
        transition="scope_module",
        log_kind="none",
    ),
    CommandForm(
        "select_clear",
        "select",
        required_flags=frozenset({"-clear"}),
        safe_reason="resets the selection and active module to the whole design",
        transition="scope_clear",
        log_kind="none",
    ),
    CommandForm(
        "cd_module",
        "cd",
        pos_arity="1",
        pos_pattern=IDENT,
        safe_reason="enters a module scope",
        transition="scope_module",
        log_kind="none",
    ),
    CommandForm(
        "cd_up",
        "cd",
        pos_arity="1",
        pos_pattern=DOTDOT,
        safe_reason="returns to the whole-design scope",
        transition="scope_clear",
        log_kind="none",
    ),
    CommandForm(
        "check",
        "check",
        required_flags=frozenset({"-assert"}),
        safe_reason=UNCHANGED_SAFE,
        transition="passive",
        log_kind="pass",
    ),
    CommandForm(
        "log",
        "log",
        required_flags=frozenset({"-stderr"}),
        pos_arity="1+",
        pos_pattern=LOG_WORD,
        first_pos_pattern=LOG_FIRST_WORD,
        safe_reason=UNCHANGED_SAFE,
        transition="passive",
        log_kind="none",
    ),
    CommandForm(
        "write_rtlil",
        "write_rtlil",
        pos_arity="1",
        pos_pattern=RTLIL_OUTPUT,
        safe_reason=UNCHANGED_SAFE,
        writes_file=True,
        transition="passive",
        log_kind="rtlil_backend",
    ),
    CommandForm(
        "write_json",
        "write_json",
        pos_arity="1",
        pos_pattern=JSON_OUTPUT,
        safe_reason=UNCHANGED_SAFE,
        writes_file=True,
        transition="passive",
        log_kind="json_backend",
    ),
    # Pinned forms that resolve don't-cares or merge cells; allowed only when
    # pinned in order for the task in DONT_CARE_OPEN.
    CommandForm(
        "opt_plain",
        "opt",
        flags=frozenset({"-fast", "-full", "-purge"}),
        max_optional_flags=1,
        rejected_reason=(
            "without -keepdc, or with -full, opt resolves undefined values as don't-cares"
        ),
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "opt_fine",
        "opt",
        required_flags=frozenset({"-keepdc", "-mux_bool", "-fine"}),
        rejected_reason="-fine merges equal multiplexer output bits with constant x",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "memory_map_plain",
        "memory_map",
        rejected_reason="without -keepdc, an unwritten word without an initial value is x",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "setundef_zero",
        "setundef",
        required_flags=frozenset({"-zero"}),
        flags=frozenset({"-init"}),
        rejected_reason="-zero picks 0 for undefined bits and -init sets initial values",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "abc",
        "abc",
        opt_args=(("-g", (AND_GATE,)),),
        rejected_reason="replaces every undefined bit with 0",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "peepopt",
        "peepopt",
        rejected_reason="reads the x bits of a constant operand as 0",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "sim_reset",
        "sim",
        required_flags=frozenset({"-w"}),
        opt_args=(("-clock", (IDENT,)), ("-n", (ONE,))),
        required_opts=frozenset({"-clock", "-n"}),
        rejected_reason="with -w writes simulated values as initial values",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "chtype_map_eqx",
        "chtype",
        opt_args=(("-map", (EQX_SOURCE, EQX_TARGET)),),
        required_opts=frozenset({"-map"}),
        rejected_reason="retypes exact x-comparisons into $eq or $ne",
        transition="act",
        log_kind="none",
    ),
    CommandForm(
        "chtype_set",
        "chtype",
        opt_args=(("-set", (IDENT,)),),
        required_opts=frozenset({"-set"}),
        pos_arity="1",
        pos_pattern=AT_SELECTION,
        rejected_reason="changes cell types to the module the script names",
        transition="act",
        log_kind="none",
    ),
    CommandForm(
        "techmap_map",
        "techmap",
        opt_args=(("-max_iter", (ONE,)), ("-map", (PERCENT_DESIGN,))),
        required_opts=frozenset({"-max_iter", "-map"}),
        rejected_reason="with -map, the map design decides what cells replace the target",
        transition="techmap_map",
        log_kind="pass",
    ),
    CommandForm(
        "sat_asserts",
        "sat",
        required_flags=frozenset({"-prove-asserts", "-verify"}),
        opt_args=(("-seq", (INT,)), ("-timeout", (INT,))),
        required_opts=frozenset({"-seq", "-timeout"}),
        rejected_reason="its proof reads an undefined bit as 0 without -enable_undef",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "sat_signals",
        "sat",
        required_flags=frozenset({"-verify"}),
        opt_args=(("-seq", (INT,)), ("-prove", (SAT_EXPR, SAT_EXPR))),
        required_opts=frozenset({"-seq", "-prove"}),
        repeatable_opts=frozenset({"-prove"}),
        pos_arity="1",
        pos_pattern=IDENT,
        rejected_reason="its proof reads an undefined bit as 0 without -enable_undef",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "equiv_simple",
        "equiv_simple",
        pos_arity="0..1",
        pos_pattern=AT_SELECTION,
        rejected_reason="its proof reads an undefined bit as 0 without -undef",
        transition="act",
        log_kind="pass",
    ),
    CommandForm(
        "equiv_struct",
        "equiv_struct",
        required_flags=frozenset({"-icells"}),
        rejected_reason="merges structurally equal cells, free inputs included",
        transition="act",
        log_kind="pass",
    ),
)

FORMS_BY_COMMAND: dict[str, tuple[CommandForm, ...]] = {}
for _form in SCRIPT_FORMS:
    FORMS_BY_COMMAND[_form.command] = (*FORMS_BY_COMMAND.get(_form.command, ()), _form)


@dataclass(frozen=True)
class ParsedCommand:
    """One Yosys command parsed into its unique CommandForm."""

    args: tuple[str, ...]
    form: CommandForm
    included_from: tuple[str, ...] = ()


def match_command_form(args: tuple[str, ...] | list[str]) -> CommandForm:
    """Return the unique CommandForm matching args, or raise ConfigError."""
    if not args:
        raise ConfigError("empty command")
    word = args[0]
    if word.startswith(("!", "-", "+", ":", '"')) or word.endswith(":"):
        raise ConfigError(f"unsupported command syntax: {' '.join(args)!r}")
    candidates = [form for form in FORMS_BY_COMMAND.get(word, ()) if form.matches(args)]
    if len(candidates) != 1:
        raise ConfigError(f"command outside SCRIPT_FORMS: {' '.join(args)!r}")
    return candidates[0]


def parse_script_lines(
    lines: Iterable[str],
    origin: str = "[script]",
    included_from: tuple[str, ...] = (),
) -> list[ParsedCommand]:
    """Parse Yosys script lines strictly into SCRIPT_FORMS commands.

    Line continuations join before comment stripping, as in Yosys. Semicolons,
    labels, shell escapes, wrappers and any command, option or argument outside
    SCRIPT_FORMS raise ConfigError.
    """
    raw_lines = list(lines)
    parsed: list[ParsedCommand] = []
    index = 0
    while index < len(raw_lines):
        start = index + 1
        line = raw_lines[index]
        index += 1
        if not line.isascii() or any(not c.isprintable() and c != "\t" for c in line):
            raise ConfigError(f"{origin}:{start}: invalid character: {line!r}")
        while line.endswith("\\"):
            if index >= len(raw_lines):
                raise ConfigError(f"{origin}:{start}: trailing continuation: {line!r}")
            nxt = raw_lines[index]
            index += 1
            if not nxt.isascii() or any(not c.isprintable() and c != "\t" for c in nxt):
                raise ConfigError(f"{origin}:{index}: invalid character: {nxt!r}")
            line = line[:-1] + nxt
        stripped = line.lstrip(" \t")
        if not stripped or stripped.startswith("#"):
            continue
        # Strip a whitespace-preceded comment outside tokens; refuse '"' except
        # as a standalone "[A-Za-z0-9_]+" token and refuse ';' anywhere.
        body = re.split(r"[ \t]+#", stripped, maxsplit=1)[0].rstrip(" \t")
        if ";" in body:
            raise ConfigError(f"{origin}:{start}: semicolon in script: {body!r}")
        tokens = tuple(body.split())
        for token in tokens:
            if '"' in token and not QUOTED_WORD.fullmatch(token):
                raise ConfigError(
                    f"{origin}:{start}: unsupported quote in {token!r}: {body!r}"
                )
            if token.startswith("#"):
                raise ConfigError(
                    f"{origin}:{start}: unexpected '#' in token {token!r}: {body!r}"
                )
        try:
            form = match_command_form(tokens)
        except ConfigError as error:
            raise ConfigError(f"{origin}:{start}: {error}") from error
        parsed.append(ParsedCommand(tokens, form, included_from))
    return parsed


def define_inputs(commands: Iterable[ParsedCommand]) -> tuple[str, ...]:
    """Record explicit defines and their source-read positions in command order."""
    result = []
    design = 0
    read = 0
    persistent = False
    for command in commands:
        form = command.form.id
        if form in ("design_stash", "design_reset", "design_load"):
            design += 1
        if form == "read_define":
            result.append(
                f"design {design} before read {read + 1}: {' '.join(command.args)}"
            )
            persistent = True
            continue
        if form not in (
            "verilog_defines",
            "read_sources",
            "read_verilog",
            "read_slang",
        ):
            continue

        words = iter(command.args[1:])
        arguments = tuple(
            f"-D{next(words)}" if word == "-D" else word for word in words
        )
        if form == "verilog_defines":
            result.append(
                f"design {design} before read {read + 1}: verilog_defines {' '.join(arguments)}"
            )
            persistent = True
            continue

        read += 1
        if persistent or any(word.startswith("-D") for word in arguments):
            scope = (
                word
                for word in arguments
                if word.startswith("-D")
                or SOURCE_FILE.fullmatch(word)
                or word in ("-formal", "-sv", "-nosynthesis", "--no-synthesis-define")
            )
            result.append(
                f"design {design} read {read}: {command.args[0]} {' '.join(scope)}"
            )
    return tuple(result)


def read_define_inputs(root: Path) -> dict[str, tuple[str, ...]]:
    """Load the independent, checked-in define declaration for every task."""
    path = root / DEFINE_INPUTS_PATH

    def unique(entries: list[tuple[str, object]]) -> dict[str, object]:
        rows = dict(entries)
        if len(rows) != len(entries):
            raise ValueError("duplicate task declaration")
        return rows

    try:
        rows = json.loads(path.read_text(), object_pairs_hook=unique)
    except (OSError, ValueError) as error:
        raise ConfigError(f"{DEFINE_INPUTS_PATH}: {error}") from error
    if not isinstance(rows, dict):
        raise ConfigError(f"{DEFINE_INPUTS_PATH}: expected a task map")
    declarations = {}
    for task, steps in rows.items():
        if not (
            re.fullmatch(rf"{FILENAME}:{NAME}", task)
            and isinstance(steps, list)
            and all(isinstance(step, str) for step in steps)
        ):
            raise ConfigError(f"{DEFINE_INPUTS_PATH}: invalid declaration for {task!r}")
        declarations[task] = tuple(steps)
    return declarations


@dataclass(frozen=True)
class TaskConfig:
    """A resolved SymbiYosys task with private raw script lines."""

    _script: tuple[str, ...]
    files: dict[str, str]
    _inline: dict[str, tuple[str, ...]]
    options: dict[str, str]
    engines: list[list[str]]

    @classmethod
    def from_raw(
        cls,
        *,
        script: Iterable[str],
        files: dict[str, str],
        inline: dict[str, Iterable[str]],
        options: dict[str, str],
        engines: list[list[str]],
    ) -> TaskConfig:
        """Build a TaskConfig from SymbiYosys or Source resolution fields."""
        return cls(
            _script=tuple(script),
            files=dict(files),
            _inline={name: tuple(body) for name, body in inline.items()},
            options=dict(options),
            engines=[list(words) for words in engines],
        )

    @property
    def inline_files(self) -> frozenset[str]:
        """Return the destination names of inline [file ...] sections."""
        return frozenset(self._inline)

    def validate_files(self) -> None:
        """Enforce closed [files] and inline [file ...] rules on this task."""
        for dest, source_rel in self.files.items():
            if not FILE_PATH.fullmatch(source_rel) or not dest.endswith(
                ALLOWED_FILE_SUFFIXES
            ):
                raise ConfigError(f"[files]: disallowed file entry {source_rel!r}")
        for name in self._inline:
            if not YS_FILE.fullmatch(name):
                raise ConfigError(f"[file {name}]: inline file must be a .ys script")

    def validate(self) -> None:
        """Enforce closed [options], [engines], and [files] rules on this task."""
        for key, value in self.options.items():
            pattern = OPTION_SPECS.get(key)
            if pattern is None or not pattern.fullmatch(value):
                raise ConfigError(f"[options]: disallowed entry '{key} {value}'")
        mode = self.options.get("mode")
        if mode is None:
            raise ConfigError("[options]: missing required 'mode'")
        if len(self.engines) != 1:
            raise ConfigError(
                f"[engines]: expected one engine entry, got {len(self.engines)}"
            )
        engine = tuple(self.engines[0])
        allowed_modes = ENGINE_FORMS.get(engine)
        if allowed_modes is None:
            raise ConfigError(
                f"[engines]: engine outside ENGINE_FORMS: {' '.join(engine)!r}"
            )
        if mode not in allowed_modes:
            raise ConfigError(
                f"[engines]: {' '.join(engine)!r} is not allowed in mode {mode!r}"
            )
        if (mode in ("bmc", "cover") or engine[0] != "abc") and (
            "depth" not in self.options
        ):
            raise ConfigError(
                f"[options]: missing required 'depth' for mode {mode!r} with {engine[0]!r}"
            )
        if "aigsmt" in self.options and mode not in ("bmc", "prove"):
            raise ConfigError(f"[options]: 'aigsmt' is not allowed in mode {mode!r}")
        if "skip" in self.options:
            if mode != "cover" or engine[0] not in ("smtbmc", "btor"):
                raise ConfigError(
                    "[options]: 'skip' is allowed only in cover mode with smtbmc or btor"
                )
            if int(self.options["skip"]) >= int(self.options["depth"]):
                raise ConfigError(
                    f"[options]: skip {self.options['skip']} must be less than depth {self.options['depth']}"
                )
        self.validate_files()

    def parsed(
        self,
        directory: Path,
        *,
        expand_opening: bool = True,
        keep_script_entries: bool = False,
    ) -> list[ParsedCommand]:
        """Validate and expand this task's script and every mapped .ys file."""
        self.validate_files()
        if self.options or self.engines:
            self.validate()
        ys_bodies: dict[str, list[str]] = {}
        for dest, source_rel in self.files.items():
            disk_path = directory / source_rel
            if disk_path.is_file():
                checked_text = read_checked_text(disk_path)
                if dest.endswith(".ys"):
                    ys_bodies[dest] = split_lf_lines(checked_text, dest)
        for name, lines in self._inline.items():
            for idx, line in enumerate(lines, 1):
                if "\n" in line or "\r" in line:
                    raise ConfigError(
                        f"{name}:{idx}: disallowed newline in inline line"
                    )
                split_lf_lines(line, f"{name}:{idx}")
            ys_bodies[name] = list(lines)

        # Every mapped or inline .ys file must parse into SCRIPT_FORMS even if
        # no `script <file.ys>` line includes it.
        parsed_ys: dict[str, list[ParsedCommand]] = {
            name: parse_script_lines(lines, origin=name, included_from=(name,))
            for name, lines in ys_bodies.items()
        }
        top_commands = parse_script_lines(self._script, origin="[script]")

        def expand(
            items: list[ParsedCommand], active: tuple[str, ...]
        ) -> list[ParsedCommand]:
            out: list[ParsedCommand] = []
            for item in items:
                if item.form.id == "script":
                    target = item.args[1]
                    if target in active:
                        raise ConfigError(f"recursive script include: {target!r}")
                    if target not in self.files and target not in self._inline:
                        raise ConfigError(f"script {target}: not in [files]")
                    if not expand_opening and target == "free_undefined.ys":
                        out.append(ParsedCommand(item.args, item.form, active))
                        continue
                    if target not in parsed_ys:
                        raise ConfigError(f"script {target}: file not found")
                    if keep_script_entries:
                        out.append(ParsedCommand(item.args, item.form, active))
                    nested = [
                        ParsedCommand(cmd.args, cmd.form, (*active, target))
                        for cmd in parsed_ys[target]
                    ]
                    out.extend(expand(nested, (*active, target)))
                else:
                    if item.form.id in ("read_sources", "read_verilog", "read_slang"):
                        for token in item.args[1:]:
                            if (
                                not token.startswith("-")
                                and SOURCE_FILE.fullmatch(token)
                                and token != "+/xilinx/cells_sim.v"
                                and token not in self.files
                            ):
                                raise ConfigError(
                                    f"{' '.join(item.args)}: {token!r} is not in [files]"
                                )
                    out.append(item)
            return out

        return expand(top_commands, ())

    def commands(self, directory: Path) -> list[list[str]]:
        """Return the validated, include-expanded command list of this task."""
        return [list(cmd.args) for cmd in self.parsed(directory, expand_opening=True)]

    def sections(self, directory: Path) -> dict[str, list[str]]:
        """Return task sections with [script] built from parsed commands."""
        return {
            "[options]": [f"{key} {value}" for key, value in self.options.items()],
            "[engines]": [" ".join(words) for words in self.engines],
            "[script]": [" ".join(args) for args in self.commands(directory)],
            "[files]": list(self.files.values()),
            **{
                f"[file {name}]": [
                    " ".join(cmd.args) for cmd in parse_script_lines(lines, origin=name)
                ]
                for name, lines in self._inline.items()
            },
        }


@dataclass
class Source:
    """Validated sections and the groups active for each named task."""

    sections: dict[str, list[str]]
    tasks: dict[str, set[str]]

    def task(self, name: str) -> TaskConfig:
        """Resolve literal task selectors for tools that run outside the image."""
        active = self.tasks[name]
        resolved: dict[str, list[str]] = {}
        for section, lines in self.sections.items():
            if section in ("", "tasks"):
                continue
            body: list[str] = []
            block = True
            for line in lines:
                if BLOCK_END.fullmatch(line):
                    block = True
                    continue
                match = TAG.fullmatch(line)
                if match:
                    negate, tag, rest = match.groups()
                    selected = (tag in active) != bool(negate)
                    line = rest.lstrip()
                    if not line:
                        block = selected
                        continue
                    if not selected:
                        continue
                if block:
                    body.append(line)
            resolved[section] = body

        def strip_comment(raw: str) -> str:
            return re.split(r"(?:^|[ \t])#", raw, maxsplit=1)[0].strip()

        def words(section: str) -> list[list[str]]:
            return [
                cleaned.split()
                for raw in resolved.get(section, [])
                if (cleaned := strip_comment(raw))
            ]

        return TaskConfig.from_raw(
            script=[line.rstrip() for line in resolved.get("script", [])],
            files={Path(src).name: src for (src,) in words("files")},
            inline={
                key[5:]: body
                for key, body in resolved.items()
                if key.startswith("file ")
            },
            options=dict(
                cleaned.split(maxsplit=1)
                for raw in resolved.get("options", [])
                if (cleaned := strip_comment(raw))
            ),
            engines=words("engines"),
        )


@lru_cache(maxsize=512)
def read_source(path: Path, text: str) -> Source:
    """Validate an .sby file with one reject-by-default grammar."""
    sections: dict[str, list[str]] = {"": []}
    tasks: dict[str, set[str]] = {}
    tags: set[str] = set()
    destinations: set[str] = set()
    section = ""
    block = 0
    for number, line in enumerate(split_lf_lines(text, path.name), 1):

        def refuse(reason: str) -> None:
            raise ConfigError(f"{path.name}:{number}: {reason}: {line!r}")

        if not line.isascii() or any(not c.isprintable() and c != "\t" for c in line):
            refuse("invalid character")

        header = HEADER.fullmatch(line)
        if header is not None:
            next_section = header[1]
            if next_section in sections or block:
                refuse("repeated section or section inside a tag block")
            if next_section == "tasks" and len(sections) != 1:
                refuse("[tasks] must precede other sections")
            if next_section.startswith("file "):
                dest = next_section[5:]
                if not YS_FILE.fullmatch(dest):
                    refuse("inline [file ...] must be a .ys script")
                if dest in destinations:
                    refuse("duplicate file destination")
                destinations.add(dest)
            section = next_section
            sections[section] = []
            continue

        if line.lstrip().startswith("[") or line.lstrip().startswith("--pycode"):
            refuse("unsupported section header or directive")

        if BLANK.fullmatch(line):
            sections[section].append(line)
            continue

        if COMMENT.fullmatch(line):
            if section in ("", "tasks") and not line.startswith("#"):
                refuse("indented comment before or inside [tasks]")
            if (
                tags
                and section != "tasks"
                and line.startswith("#")
                and line.split()[0].endswith(":")
            ):
                refuse("comment read as a task selector")
            sections[section].append(line)
            continue

        if not section:
            refuse("expected a section")

        if section == "tasks":
            entry = TASKS_ENTRY.fullmatch(line)
            if entry is None:
                refuse("expected literal task and tag names")
            assert entry is not None
            lhs_words = entry[1].split()
            if entry[2] is None:
                names, groups = lhs_words[:1], lhs_words[1:]
            else:
                names, groups = lhs_words, entry[2][1:].split()
            for name in names:
                if name in tasks:
                    refuse("duplicate task")
                tasks[name] = {name, *set(groups).difference({"default"})}
                tags.update(tasks[name])
            sections[section].append(line)
            continue

        if BLOCK_END.fullmatch(line):
            if not block or section not in ("options", "engines", "script"):
                refuse("unmatched end of tag block")
            block = 0
            sections[section].append(line)
            continue

        payload = line
        tag = TAG.fullmatch(line)
        if tag is not None:
            if tag[2] not in tags or section not in ("options", "engines", "script"):
                refuse("unknown or misplaced task tag")
            payload = tag[3].lstrip()
            if not payload:
                if block:
                    refuse("nested tag block")
                block = number
                sections[section].append(line)
                continue
        elif line[:1] not in ("", " ", "\t") and line.split()[0].endswith(":"):
            refuse("unsupported task selector or label")

        if payload.lstrip().startswith(("[", "--")):
            refuse("header or directive inside section")

        if section == "files":
            source_rel = payload.strip()
            if not FILE_PATH.fullmatch(source_rel):
                refuse("expected one source path")
            dest = Path(source_rel).name
            if not dest.endswith(ALLOWED_FILE_SUFFIXES):
                refuse(f"disallowed [files] extension in {dest}")
            if dest in destinations:
                refuse(f"duplicate file destination {dest}")
            destinations.add(dest)
        elif section == "options":
            body = re.split(r"(?:^|[ \t])#", payload, maxsplit=1)[0].strip()
            if not OPTION_ENTRY.fullmatch(body):
                refuse("unsupported [options] entry")
            opt_key, opt_val = body.split(maxsplit=1)
            opt_pat = OPTION_SPECS.get(opt_key)
            if opt_pat is None or not opt_pat.fullmatch(opt_val):
                refuse(f"disallowed [options] entry '{opt_key} {opt_val}'")
        elif section == "engines":
            body = re.split(r"(?:^|[ \t])#", payload, maxsplit=1)[0].strip()
            if not ENGINE_ENTRY.fullmatch(body):
                refuse("unsupported [engines] entry")
            if tuple(body.split()) not in ENGINE_FORMS:
                refuse(f"disallowed [engines] entry {body!r}")
        elif section == "script":
            if (
                not payload.strip()
                or payload.lstrip().startswith("#")
                and tag is not None
            ):
                refuse("empty tagged [script] line")
        elif section.startswith("file "):
            pass
        else:
            refuse(f"unexpected section {section!r}")

        sections[section].append(line)

    if block:
        raise ConfigError(f"{path.name}:{block}: unterminated tag block")
    if "tasks" in sections and not tasks:
        raise ConfigError(f"{path.name}: [tasks] names no task")
    if len(sections) == 1:
        raise ConfigError(f"{path.name}: configuration defines no section")
    return Source(sections, tasks or {"": set()})


def source(path: Path) -> Source:
    """Read and validate a checkout configuration."""
    return read_source(path, read_checked_text(path))


def proof_inputs(path: Path) -> list[Path]:
    """List a proof and the source paths it declares relative to its directory."""
    definition = source(path)
    # The repository's [files] section is shared by every task.
    files = definition.task(next(iter(definition.tasks))).files
    return [path, *(path.parent / name for name in files.values())]


def cmo_replay_helper(path: Path, task: str | None = None) -> Path | None:
    """Locate the Python runner needed by a CMO cover or its whole-script fixture."""
    if path.name != "coherence_home.sby":
        return None
    covers = {"coh_home_cmo_cover", "coh_home_cmo_fast_cover"}
    if task in covers or (task is None and bool(covers & set(source(path).tasks))):
        return path.parent.parent / "tests" / "coherence_home_cmo_replay.py"
    return None


def store_completion_cone_helper(path: Path) -> Path | None:
    """Locate the source projection for the wrapper's store-completion proof."""
    if path.name == "store_completion_cofactor.sby":
        return path.parent.parent / "tests" / "store_completion_cofactor.py"
    return None


def stage_proof(path: Path, root: Path, fixture: Path) -> Path:
    """Copy a proof and all its inputs into a private checkout layout.

    SymbiYosys stages every external input from [files], including sources
    read by nested Yosys scripts. Inline [file] bodies travel with the proof.
    The source projection and witness replay travel in the tests directory.
    """
    root = Path(os.path.abspath(root))
    sources = proof_inputs(path)
    if replay := cmo_replay_helper(path):
        sources.append(replay)
    if projection := store_completion_cone_helper(path):
        sources.append(projection)
    destinations = [
        fixture / Path(os.path.abspath(source_file)).relative_to(root)
        for source_file in sources
    ]
    for source_file, destination in zip(sources, destinations, strict=True):
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_file, destination)
    return destinations[0]


# Only configurations are cached. The checks read the mapped files on each use.
_resolved: dict[Path, tuple[str, dict[str, TaskConfig]]] = {}


def sby_outcomes(texts: dict[str, str]) -> dict[str, dict]:
    """Return SymbiYosys's verdict on each configuration text, unchecked.

    Each value is {"error": message} when SymbiYosys refuses the text, else
    {"tasks": {task: configuration fields}}.
    """
    driver = Path(__file__).with_name("sby_dump.sby")
    run = subprocess.run(
        ["sby", "--dumpcfg", str(driver)],
        input=json.dumps(texts),
        capture_output=True,
        text=True,
        timeout=90,
    )
    if run.returncode:
        raise ConfigError(f"SymbiYosys: {run.stderr.strip()}")
    outcome = json.loads(run.stdout)
    if outcome.keys() != texts.keys():
        raise ConfigError("SymbiYosys returned a different set of files")
    return outcome


def resolve_files(paths: Iterable[Path]) -> None:
    """Resolve changed configurations in one SymbiYosys process."""
    pending: dict[str, str] = {}
    for path in paths:
        text = read_checked_text(path)
        if path not in _resolved or _resolved[path][0] != text:
            read_source(path, text)
            pending[str(path)] = text
    if not pending:
        return
    for name, outcome in sby_outcomes(pending).items():
        if "error" in outcome:
            raise ConfigError(f"SymbiYosys: {name}: {outcome['error']}")
        tasks_map = {
            task: TaskConfig.from_raw(**entry)
            for task, entry in outcome["tasks"].items()
        }
        for cfg in tasks_map.values():
            cfg.validate()
        _resolved[Path(name)] = (pending[name], tasks_map)


def resolved(path: Path) -> dict[str, TaskConfig]:
    """Resolve every named task, including those outside the default set."""
    resolve_files([path])
    return _resolved[path][1]

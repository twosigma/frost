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

"""Keep reset out of combinational RTL.

Reset belongs at the flop, as `if (rst) ... else ...`. It stays in
combinational logic only where a receiver is not reset by the same signal, with
a one-line comment saying why. This test reads the synthesized view of hw/rtl
and lists every reset term outside an always_ff block. The list must equal
tests/combinational_reset_allowlist.txt, so a new term fails here and a removed
term shrinks the allowlist.

A reset passed unchanged to a port or an alias, inverted or not, is not a term,
except at a LUT primitive, and neither are the reset pins of the FD* primitives
or an unused-signal sink.
"""

from pathlib import Path
import re

import pytest

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "hw/rtl"
ALLOWLIST = Path(__file__).with_name("combinational_reset_allowlist.txt")

# i_rst, i_rst_n, i_axi_rst, i_rst_div4, rst_n, i_reset, the pipeline control
# struct's reset field, and the SoC's distributed resets.
RESET = re.compile(
    r"(?<![\w.$])(?:i_(?:\w+_)?rst(?:_\w+)?|rst(?:_n)?|i_reset|(?:i_)?pipeline_ctrl\.reset|"
    r"rst_core|soc_cpu_rst|soc_axi_rst|cpu_cache_rst|o_cpu_rst|o_cpu_axi_rst|debug_cpu_rst|"
    r"debug_soc_rst|rx_rst|tx_rst|core_rst_dom)(?![\w])"
)
# Passed through whole: `i_rst`, `!i_rst_n`, `~i_rst`, `(i_rst)`.
WHOLE_RESET = re.compile(rf"^[(\s]*[!~]?\s*(?:{RESET.pattern})[)\s]*$")
# Implementation choices with a build on each side. Every other macro is off,
# except SYNTHESIS, which is on.
BOTH_ARMS = {
    "FROST_XILINX_PRIMS",
    "FROST_SRAM_MACROS",
    "FROST_VIVADO_SYNTH",
    "FROST_SDP_RAM_USE_XPM",
    "FROST_PACKED_TAG_USE_XPM",
}
SKIPPED_STATEMENTS = (
    "module",
    "package",
    "interface",
    "function",
    "task",
    "typedef",
    "parameter",
    "localparam",
    "import",
    "initial",
)
DECLARATION = re.compile(
    r"^(?:wire|logic|reg|bit|var|int|integer|automatic|signed|unsigned|\w+::\w+)\b"
)
PRIMITIVE_FLOP = re.compile(r"^FD[RSCP]E$")
PRIMITIVE_LUT = re.compile(r"^LUT\d$")


def strip_comments(text: str) -> str:
    """Blank comments, strings and attributes, keeping line numbers."""

    def blank(match: re.Match[str]) -> str:
        return "\n" * match.group(0).count("\n")

    return re.sub(
        r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\(\*.*?\*\)', blank, text, flags=re.S
    )


def synthesized_lines(text: str) -> str:
    """Blank the conditional-compilation arms that synthesis does not read."""
    arms: list[tuple[str, bool]] = []
    kept = []
    for line in text.split("\n"):
        directive = re.match(r"\s*`(ifdef|ifndef|elsif|else|endif)\b\s*(\w*)", line)
        if directive is None:
            kept.append(line if all(on for _, on in arms) else "")
            continue
        kept.append("")
        keyword, macro = directive.groups()
        if keyword == "endif":
            arms.pop()
        elif keyword == "else":
            name, on = arms.pop()
            arms.append((name, name in BOTH_ARMS or not on))
        elif keyword == "elsif":
            name, _ = arms.pop()
            arms.append((name, name in BOTH_ARMS or macro in BOTH_ARMS))
        else:
            on = macro in BOTH_ARMS or (macro == "SYNTHESIS") == (keyword == "ifdef")
            arms.append((macro, on))
    return "\n".join(kept)


def closing(text: str, start: int) -> int:
    """Return the index just past the bracket that matches text[start]."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] in "([{":
            depth += 1
        elif text[index] in ")]}":
            depth -= 1
            if depth == 0:
                return index + 1
    raise ValueError(f"unbalanced bracket at offset {start}")


def blank_always_ff(text: str) -> str:
    """Blank every always_ff body."""
    pieces = []
    position = 0
    for match in re.finditer(r"\balways_ff\b", text):
        if match.start() < position:
            continue
        pieces.append(text[position : match.start()])
        index = closing(text, text.index("(", match.end()))
        depth = 0
        for token in re.finditer(
            r"\b(?:begin|case|casez|end|endcase)\b|;", text[index:]
        ):
            if token.group(0) in ("begin", "case", "casez"):
                depth += 1
            elif token.group(0) in ("end", "endcase"):
                depth -= 1
            if depth == 0 and token.group(0) in ("end", "endcase", ";"):
                position = index + token.end()
                break
        pieces.append(re.sub(r"[^\n]", " ", text[match.start() : position]))
    pieces.append(text[position:])
    return "".join(pieces)


def split_statements(text: str) -> list[str]:
    """Split on semicolons outside brackets."""
    statements = []
    start = 0
    depth = 0
    for index, character in enumerate(text):
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif character == ";" and depth == 0:
            statements.append(text[start:index])
            start = index + 1
    return statements


def normalize(text: str) -> str:
    """Collapse white space."""
    return " ".join(text.split())


def strip_control(statement: str, terms: set[str]) -> str:
    """Remove the control flow in front of a statement, noting reset conditions."""
    prefix = re.compile(
        r"^\s*(?:(?:unique|priority)\s+)?(if|for|case|casez|while)\s*\(|"
        r"^\s*(?:begin|end|fork|join|else|generate|endgenerate|endcase|default\s*:?)\b"
        r"(?:\s*:\s*\w+)?|"
        r"^\s*always_comb\b|^\s*always\s*@\s*\*|^\s*always\s*@\s*\(\s*\*\s*\)|"
        r"^\s*endmodule\b|^\s*endfunction\b|^\s*endtask\b|^\s*endpackage\b|"
        r"^\s*[\w:'.]+(?:\s*,\s*[\w:'.]+)*\s*:(?!:)"
    )
    remainder = statement
    while True:
        match = prefix.match(remainder)
        if match is None:
            return remainder.strip()
        if match.group(1) is None:
            remainder = remainder[match.end() :]
            continue
        end = closing(remainder, match.end() - 1)
        condition = remainder[match.end() : end - 1]
        if RESET.search(condition):
            terms.add(f"{match.group(1)} ({normalize(condition)})")
        remainder = remainder[end:]


def instance_terms(statement: str, terms: set[str]) -> None:
    """Note the reset terms in one instance's port connections."""
    header = re.match(r"^([\w:]+)\s*(?:#\s*\()?", statement)
    if header is None:
        return
    body = statement[header.end() :]
    if header.group(0).endswith("("):
        body = statement[closing(statement, header.end() - 1) :]
    name = re.match(r"^\s*(\w+)\s*(?:\[[^]]*\]\s*)?\(", body)
    if name is None or PRIMITIVE_FLOP.match(header.group(1)):
        return
    ports = body[name.end() - 1 :]
    primitive_lut = PRIMITIVE_LUT.match(header.group(1))
    for port in re.finditer(r"\.(\w+)\s*\(", ports):
        expression = ports[port.end() : closing(ports, port.end() - 1) - 1]
        if RESET.search(expression) and (
            primitive_lut or not WHOLE_RESET.match(expression)
        ):
            terms.add(f"{name.group(1)}.{port.group(1)}")


def statement_terms(statement: str, terms: set[str]) -> None:
    """Note the reset terms in one statement without control flow."""
    if not RESET.search(statement) or statement.startswith(SKIPPED_STATEMENTS):
        return
    declared = DECLARATION.match(statement)
    assignment = re.match(
        r"^(?:assign\s+)?(?:[\w:]+\s+)*?(?:\[[^=]*\]\s*)*([\w.]+(?:\[[^=]*\])?)\s*(?:<=|=)(.*)$",
        statement,
        flags=re.S,
    )
    if (
        statement.startswith("assign")
        or declared
        or (assignment and "(" not in statement[:1])
    ):
        if assignment is None:
            return
        lint_sink = re.fullmatch(r"_?unused\w*", assignment.group(1))
        if (
            RESET.search(assignment.group(2))
            and not WHOLE_RESET.match(assignment.group(2))
            and not lint_sink
        ):
            terms.add(normalize(assignment.group(1)))
        return
    instance_terms(statement, terms)


def file_terms(path: Path) -> set[str]:
    """Return the keys of the reset terms outside always_ff blocks in one file."""
    text = blank_always_ff(synthesized_lines(strip_comments(path.read_text())))
    terms: set[str] = set()
    for statement in split_statements(text):
        statement_terms(strip_control(statement, terms), terms)
    return terms


def rtl_files() -> list[Path]:
    """Return the synthesizable RTL, without the test harnesses."""
    return sorted(
        path for path in RTL.rglob("*.sv") if not path.stem.endswith("_test_harness")
    )


def current_terms() -> set[str]:
    """Return one `path: key` line for each reset term in hw/rtl."""
    return {
        f"{path.relative_to(ROOT)}: {term}"
        for path in rtl_files()
        for term in file_terms(path)
    }


def allowed_terms() -> set[str]:
    """Return the allowlist's entries."""
    lines = ALLOWLIST.read_text().splitlines()
    return {line for line in lines if line and not line.startswith("#")}


def test_no_new_combinational_reset_terms() -> None:
    """A new term needs moving to the flop, or an allowlist entry and a comment."""
    new = sorted(current_terms() - allowed_terms())
    assert not new, "reset in combinational logic:\n" + "\n".join(new)


def test_allowlist_has_no_stale_entries() -> None:
    """A removed term leaves the allowlist with the change that removes it."""
    stale = sorted(allowed_terms() - current_terms())
    assert not stale, "remove from the allowlist:\n" + "\n".join(stale)


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("assign o_valid = !i_rst && v;", {"o_valid"}),
        ("wire go = i_rst_n && v;", {"go"}),
        ("assign x = i_pipeline_ctrl.reset || y;", {"x"}),
        ("assign x = !rst_core && y;", {"x"}),
        ("assign rst_n = ~i_rst;", set()),
        ("wire _unused = &{1'b0, i_rst};", set()),
        (
            "always_comb begin\n  if (i_rst) x = 1'b0;\n  else x = y;\nend",
            {"if (i_rst)"},
        ),
        ("always_comb x = i_reset ? boot : y;", {"x"}),
        (
            "always_ff @(posedge i_clk) begin\n  if (i_rst) q <= 0;\n  else q <= d;\nend",
            set(),
        ),
        (
            "always_ff @(posedge i_clk) q <= i_rst ? 0 : d;\nassign z = i_rst || y;",
            {"z"},
        ),
        ("foo u_foo (\n  .i_clk,\n  .i_rst(i_rst),\n  .i_rst_n(!i_rst)\n);", set()),
        ("foo #(.W(2)) u_foo (.i_clear(!i_rst_n || i_flush));", {"u_foo.i_clear"}),
        (
            "FDRE #(.INIT(1'b0)) q_ff (.C(c), .CE(1'b1), .D(d), .Q(q), .R(!i_rst_n || f));",
            set(),
        ),
        ("LUT2 #(.INIT(4'h4)) u_gate (.I0(i_rst), .I1(y), .O(x));", {"u_gate.I0"}),
        ("`ifndef SYNTHESIS\nassign x = i_rst && y;\n`endif", set()),
        (
            "`ifdef FORMAL\nassign x = i_rst && y;\n`else\nassign z = i_rst && y;\n`endif",
            {"z"},
        ),
        ("assign first_valid = i_first && i_burst;", set()),
        ("// assign x = i_rst && y;\nassign z = y;", set()),
    ],
)
def test_term_detection(tmp_path: Path, source: str, expected: set[str]) -> None:
    """The scanner finds reset terms and leaves flops and pass-throughs alone."""
    path = tmp_path / "module_under_test.sv"
    path.write_text(f"module m (input logic i_clk);\n{source}\nendmodule\n")
    assert file_terms(path) == expected

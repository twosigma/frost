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


"""Keep attributes off net declarations that carry an initialiser.

Some SystemVerilog front ends reject `(* keep = "true" *) wire x = expr;`,
although the language allows it. Declare the net with its attribute and drive
it with a separate continuous assignment:

    (* keep = "true" *) wire x;
    assign x = expr;

The two forms are the same net. This test reads every SystemVerilog file under
hw/ and boards/ and fails on an attributed net declaration with an initialiser.
Variables such as `(* ASYNC_REG = "TRUE" *) logic [1:0] sync = '0;` are not
nets: their initial value is a power-on value, and they are not checked.
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = ("hw", "boards")
SUFFIXES = (".sv", ".v", ".svh")
NET_KINDS = r"(?:wire|tri|tri0|tri1|triand|trior|trireg|wand|wor|uwire|supply0|supply1)"
# The start of the next port in a module header.
PORT_DIRECTION = re.compile(r"\s*(?:input|output|inout|ref)\b")
# One or more attribute instances, then a net kind. `@(*)` is not an attribute.
ATTRIBUTED_NET = re.compile(rf"(?:\(\*(?!\)).*?\*\)\s*)+{NET_KINDS}\b", re.S)


def strip_comments(text: str) -> str:
    """Blank comments and strings, keeping attributes and line numbers."""

    def blank(match: re.Match[str]) -> str:
        return " " * (len(match.group(0)) - match.group(0).count("\n")) + "\n" * (
            match.group(0).count("\n")
        )

    return re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', blank, text, flags=re.S)


def has_initialiser(text: str, start: int) -> bool:
    """Report whether the declaration starting at `start` has a top-level `=`."""
    depth = 0
    for position in range(start, len(text)):
        char = text[position]
        if char == "," and depth == 0 and PORT_DIRECTION.match(text, position + 1):
            return False
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth < 0:
                return False
        elif depth == 0 and char == ";":
            return False
        elif depth == 0 and char == "=":
            return True
    return False


def find_offenders(text: str) -> list[int]:
    """Return the line numbers of attributed net declarations with an initialiser."""
    # Attribute values are strings, so blank them before looking for the
    # attribute's closing bracket, then match on the blanked copy.
    blanked = strip_comments(text)
    lines = []
    for match in ATTRIBUTED_NET.finditer(blanked):
        if has_initialiser(blanked, match.end()):
            lines.append(blanked.count("\n", 0, match.end()) + 1)
    return lines


def test_attributed_nets_have_no_initialiser() -> None:
    """Fail on `(* attr *) wire x = expr;` anywhere in hw/ or boards/."""
    offenders = []
    for directory in SOURCE_DIRS:
        for path in sorted((ROOT / directory).rglob("*")):
            if path.suffix not in SUFFIXES or not path.is_file():
                continue
            if "submodules" in path.parts or "sim_build" in path.parts:
                continue
            for line in find_offenders(path.read_text(errors="replace")):
                offenders.append(f"{path.relative_to(ROOT)}:{line}")
    assert not offenders, (
        "an attributed net declaration carries an initialiser; declare the net "
        "with its attribute and drive it with a separate `assign` "
        '(`(* keep = "true" *) wire x;` then `assign x = expr;`):\n  '
        + "\n  ".join(offenders)
    )


def test_checker_recognises_the_forbidden_form() -> None:
    """The scan flags an initialiser, also across lines, and passes the split form."""
    bad = '(* keep = "true" *)\n  wire [3:0] x =\n      a & b;\n'
    assert find_offenders(bad) == [2]
    assert find_offenders('(* keep = "true" *) wire y = f(a, b);\n') == [1]
    assert find_offenders('(* keep = "true" *) wire x;\nassign x = a;\n') == []
    assert find_offenders('(* ASYNC_REG = "TRUE" *) logic [1:0] s = \'0;\n') == []
    assert find_offenders("wire z = a; // (* keep *) wire w = b;\n") == []
    assert find_offenders("always @(*) q = a;\nwire z;\n") == []
    ports = "module m(input a, (* keep *) wire b, input c = 1'b0);\n"
    assert find_offenders(ports) == []

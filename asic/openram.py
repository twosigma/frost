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

"""Generate the ASIC flow's SRAM macros with OpenRAM on FreePDK45.

``./asic/openram.py generate`` runs OpenRAM in the ORFS image that
asic/orfs.py pins, as the invoking user, and copies each macro's abstract
LEF, Liberty timing model, and Verilog model into asic/sram/macros/<macro>/,
which git tracks. The flow reads those views and never runs OpenRAM.
Everything else OpenRAM writes, including each macro's GDS, stays in
asic/build/openram.

``build`` is the part that runs inside the image: it installs OpenRAM's
Python packages from asic/sram/requirements.txt into a virtual environment,
fetches OpenRAM at OPENRAM_COMMIT, and runs it on each macro.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

try:
    from asic import orfs
except ImportError:  # run as a script from asic/
    import orfs  # type: ignore[import-not-found,no-redef]

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SRAM_DIRECTORY = REPOSITORY_ROOT / "asic" / "sram"
MACRO_DIRECTORY = SRAM_DIRECTORY / "macros"
REQUIREMENTS = SRAM_DIRECTORY / "requirements.txt"
BUILD_DIRECTORY = REPOSITORY_ROOT / "asic" / "build" / "openram"

# OpenRAM's dev branch, version 1.2.49, as of 2026-10-16. The last release,
# 1.2.48 (January 2024), connects every cell of an array to its supply nets
# in quadratic time, so that a 4,096-word macro takes hours to build, and
# caps the slew at the address pins at 0.04 ns, the largest slew its timing
# tables cover. Fetching a commit by its hash pins its contents.
OPENRAM_REPOSITORY = "https://github.com/VLSIDA/OpenRAM.git"
OPENRAM_COMMIT = "3cbe56ad50021d441fb203e89acca66c44f376da"

# The corner of the Nangate45 platform's Liberty library: typical process,
# 1.1 V, 25 C. OpenRAM's analytical delay model characterizes the macros, so
# no SPICE simulator is needed.
PROCESS_CORNER = "TT"
SUPPLY_VOLTAGE = 1.1
TEMPERATURE = 25
LIBERTY_SUFFIX = "TT_1p1V_25C"

# The loads and slews of the Liberty tables, as multiples of FreePDK45's
# flip-flop input capacitance in OpenRAM, 0.2091 fF, and of its 5 ps rise
# time. OpenRAM's defaults stop at 0.84 fF and 40 ps, and the largest load
# becomes the read data's maximum capacitance, below that of any Nangate45
# gate, so no buffer could meet it. These reach 53.5 fF, about what a
# Nangate45 X1 gate may drive, and 0.5 ns, the inputs' maximum transition.
# OpenRAM sets a macro's minimum clock period to 3.7 times its read delay at
# the largest load.
LOAD_SCALES = (4, 32, 256)
SLEW_SCALES = (1, 10, 100)

# The Verilog models' delays, in ns, set so that their read data settles
# before the next rising edge of the simulations' 3 ns core clock: the data
# goes undefined T_HOLD after a rising edge and holds the word read DELAY
# after the falling edge.
MODEL_DELAY_NS = "0.5"
MODEL_HOLD_NS = "0.1"


@dataclass(frozen=True)
class Macro:
    """One OpenRAM SRAM macro.

    ports is "1w1r", one write port (port 0) and one read port (port 1), or
    "2rw", two read and write ports. write_size is the number of bits that
    each write-mask bit enables, or None for whole-word writes.
    """

    ports: str
    words: int
    bits: int
    write_size: int | None

    @property
    def name(self) -> str:
        """Return the macro's module, LEF, and Liberty cell name."""
        mask = f"_m{self.write_size}" if self.write_size else ""
        return f"sram_{self.ports}_{self.words}x{self.bits}{mask}"

    @property
    def port_counts(self) -> tuple[int, int, int]:
        """Return OpenRAM's (read-write, write, read) port counts."""
        if self.ports == "1w1r":
            return 0, 1, 1
        if self.ports == "2rw":
            return 2, 0, 0
        raise ValueError(f"unknown port configuration {self.ports}")


# The macros that asic/sram/frost_sram_1w1r.sv and frost_sram_2rw.sv build
# the RAM wrappers' memories from, with the memories each one builds, in
# rows by columns of macros.
MACROS = (
    # L2 data: 1 row of 8, each a 64-bit slice of every {way, set} line;
    # the NIC's transmit frame buffer: 1 macro
    Macro("1w1r", 4096, 64, 8),
    # L1D data: 1 row of 4 in each way's bank. The L1 macros are 64 bits
    # wide because OpenRAM could not route the pins of a 512 by 128 macro to
    # its edges.
    Macro("1w1r", 1024, 64, 8),
    # L1D tags: one in each way
    Macro("1w1r", 1024, 19, None),
    # L2 tags: 1 row of 4, a column for each way of a set
    Macro("1w1r", 1024, 18, None),
    # The NIC's receive and transmit FIFOs
    Macro("1w1r", 512, 68, None),
    # The BTB's three slot-2 payload tables
    Macro("1w1r", 256, 36, None),
    # L1I data: 1 row of 4 in each way's bank
    Macro("1w1r", 128, 64, 8),
    # Instruction memory: 2 rows of 1 in each parity's cold bank, written on
    # the program-loading clock and read on the core's. A bank of OpenRAM
    # holds at most 8,192 words, 512 rows of 16.
    Macro("1w1r", 8192, 28, None),
    # Instruction memory: 2 rows of 1 in each parity's frontend-hot and
    # compressed banks
    Macro("1w1r", 8192, 4, None),
    # The NIC's receive packet buffer: one macro per independently addressed
    # byte lane
    Macro("1w1r", 4096, 8, None),
    # Data memory: 4 rows of 1, with the program-loading port and the core's
    Macro("2rw", 4096, 64, 8),
)


def openram_config(macro: Macro, output_directory: Path) -> str:
    """Return the OpenRAM configuration file that builds macro."""
    rw_ports, w_ports, r_ports = macro.port_counts
    lines = [
        f"word_size = {macro.bits}",
        f"num_words = {macro.words}",
        f"num_rw_ports = {rw_ports}",
        f"num_w_ports = {w_ports}",
        f"num_r_ports = {r_ports}",
        'tech_name = "freepdk45"',
        f'process_corners = ["{PROCESS_CORNER}"]',
        f"supply_voltages = [{SUPPLY_VOLTAGE}]",
        f"temperatures = [{TEMPERATURE}]",
        f"load_scales = {list(LOAD_SCALES)}",
        f"slew_scales = {list(SLEW_SCALES)}",
        # A supply ring on metal3 and metal4, and the signal pins on the
        # macro's edges, where the flow's power grid and router reach them.
        "route_supplies = True",
        'supply_pin_type = "ring"',
        "perimeter_pins = True",
        # No DRC or LVS: they need Magic and Netgen, which the image lacks.
        "check_lvsdrc = False",
        # The tools come from the image, not from Nix.
        "use_nix = False",
        f'output_name = "{macro.name}"',
        f'output_path = "{output_directory}"',
    ]
    if macro.write_size is not None:
        lines.insert(1, f"write_size = {macro.write_size}")
    return "\n".join(lines) + "\n"


# A collision warning of OpenRAM's models: a port reading the address that
# the other port writes in the same cycle.
_COLLISION_WARNING = re.compile(
    r"(\n\s+)if \((![^\n]*\(addr\d == addr\d\))\)"
    r'(\n\s+\$display\(\$time," WARNING: Writing and reading)'
)


def simulation_model(model: str) -> str:
    """Return OpenRAM's Verilog model with quiet logging and short delays.

    The model logs every access, and every read of an address being written,
    unless VERBOSE is 0; frost_sram_1w1r's simulation checks make such reads
    X instead. Its default delays of 3 and 1 time units do not fit a 3 ns
    clock; the timescale makes the delays ns whatever the simulator's default.
    """
    replacements = (
        ("  parameter DELAY = 3 ;\n", f"  parameter DELAY = {MODEL_DELAY_NS} ;\n"),
        ("  parameter VERBOSE = 1 ;", "  parameter VERBOSE = 0 ;"),
        ("  parameter T_HOLD = 1 ;", f"  parameter T_HOLD = {MODEL_HOLD_NS} ;"),
    )
    for old, new in replacements:
        if model.count(old) != 1:
            raise ValueError(f"the OpenRAM model does not set {old.strip()!r} once")
        model = model.replace(old, new)
    model, warnings = _COLLISION_WARNING.subn(r"\1if (VERBOSE && \2)\3", model)
    if warnings == 0:
        raise ValueError("the OpenRAM model has no collision warning")
    header = (
        "// Generated by asic/openram.py from OpenRAM's model: VERBOSE is 0 and\n"
        "// also gates the collision warnings, and the delays are "
        f"{MODEL_HOLD_NS} ns (T_HOLD)\n// and {MODEL_DELAY_NS} ns (DELAY).\n"
        "`timescale 1ns / 1ps\n"
    )
    return header + model


def view_paths(macro: Macro, directory: Path = MACRO_DIRECTORY) -> dict[str, Path]:
    """Return the committed views of macro: its LEF, Liberty, and Verilog files."""
    base = directory / macro.name / macro.name
    return {
        "lef": base.with_suffix(".lef"),
        "lib": base.with_suffix(".lib"),
        "v": base.with_suffix(".v"),
    }


# Nangate45's manufacturing grid, in units of 0.1 nm. OpenRAM draws FreePDK45
# on a 2.5 nm grid, and OpenROAD's router rejects a pin shape off the
# platform's 5 nm grid.
MANUFACTURING_GRID = 50
_LEF_RECT = re.compile(r"^(\s*RECT\s+)(\S+) (\S+) (\S+) (\S+)(\s*;)", re.M)
_LEF_SIZE = re.compile(r"^(\s*SIZE\s+)(\S+) BY (\S+)(\s*;)", re.M)


def _tenths_of_nm(value: str) -> int:
    """Return a LEF coordinate in microns as a whole number of 0.1 nm."""
    whole, _, fraction = value.partition(".")
    if len(fraction) > 4 or not (whole + fraction).isdigit():
        raise ValueError(f"unexpected LEF coordinate {value}")
    return int(whole) * 10000 + int(fraction.ljust(4, "0"))


def _microns(tenths: int) -> str:
    """Format a whole number of 0.1 nm as microns, as OpenRAM writes them."""
    whole, fraction = divmod(tenths, 10000)
    return f"{whole}.{fraction:04d}".rstrip("0") if fraction else f"{whole}.0"


def on_manufacturing_grid(lef: str) -> str:
    """Return the abstract LEF with its outline and rectangles on the 5 nm grid.

    Each edge off the grid moves outward by 2.5 nm, so the outline still
    covers the macro, a pin its metal, and an obstruction its shapes.
    """

    def down(value: int) -> int:
        return value // MANUFACTURING_GRID * MANUFACTURING_GRID

    def up(value: int) -> int:
        return -(-value // MANUFACTURING_GRID) * MANUFACTURING_GRID

    def widen(match: re.Match[str]) -> str:
        x1, y1, x2, y2 = (_tenths_of_nm(match[i]) for i in range(2, 6))
        corners = (down(x1), down(y1), up(x2), up(y2))
        return f"{match[1]}{' '.join(_microns(value) for value in corners)}{match[6]}"

    def grow(match: re.Match[str]) -> str:
        width, height = (up(_tenths_of_nm(match[i])) for i in (2, 3))
        return f"{match[1]}{_microns(width)} BY {_microns(height)}{match[4]}"

    return _LEF_SIZE.sub(grow, _LEF_RECT.sub(widen, lef))


def install_views(macro: Macro, output_directory: Path) -> None:
    """Copy one macro's views from OpenRAM's output into asic/sram."""
    views = view_paths(macro)
    views["lef"].parent.mkdir(parents=True, exist_ok=True)
    lef = (output_directory / f"{macro.name}.lef").read_text()
    views["lef"].write_text(on_manufacturing_grid(lef))
    shutil.copyfile(
        output_directory / f"{macro.name}_{LIBERTY_SUFFIX}.lib", views["lib"]
    )
    model = (output_directory / f"{macro.name}.v").read_text()
    views["v"].write_text(simulation_model(model))


def run(command: Sequence[str]) -> None:
    """Run a command, failing on a nonzero status."""
    subprocess.run(list(command), check=True)


def prepare_environment(build_directory: Path) -> tuple[Path, Path]:
    """Install the pinned packages and OpenRAM; return (python, OpenRAM)."""
    venv = build_directory / "venv"
    python = venv / "bin" / "python3"
    stamp = venv / "requirements.txt"
    requirements = REQUIREMENTS.read_text()
    if not stamp.exists() or stamp.read_text() != requirements:
        shutil.rmtree(venv, ignore_errors=True)
        run([sys.executable, "-m", "venv", str(venv)])
        run(
            [
                str(python),
                *("-m", "pip", "install", "--quiet", "--no-deps"),
                *("--only-binary", ":all:", "--require-hashes"),
                *("--requirement", str(REQUIREMENTS)),
            ]
        )
        stamp.write_text(requirements)

    source = build_directory / "OpenRAM"
    git = ["git", "-C", str(source)]
    head = subprocess.run(
        [*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=False
    ).stdout.strip()
    if head != OPENRAM_COMMIT:
        shutil.rmtree(source, ignore_errors=True)
        source.mkdir(parents=True)
        run([*git, "init", "--quiet"])
        fetch = [*git, "fetch", "--quiet", "--depth", "1"]
        run([*fetch, OPENRAM_REPOSITORY, OPENRAM_COMMIT])
        run([*git, "checkout", "--quiet", "--detach", "FETCH_HEAD"])
        head = subprocess.run(
            [*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True
        ).stdout.strip()
        if head != OPENRAM_COMMIT:
            raise RuntimeError(f"fetched OpenRAM {head}, not {OPENRAM_COMMIT}")
    return python, source


def build_macro(macro: Macro, python: Path, source: Path, build_directory: Path) -> int:
    """Run OpenRAM on one macro and install its views; return the status."""
    directory = build_directory / macro.name
    shutil.rmtree(directory, ignore_errors=True)
    output = directory / "out"
    temporary = directory / "tmp"
    output.mkdir(parents=True)
    temporary.mkdir()
    config = directory / f"{macro.name}_config.py"
    config.write_text(openram_config(macro, output))
    environment = {
        **os.environ,
        "OPENRAM_HOME": str(source / "compiler"),
        "OPENRAM_TECH": str(source / "technology"),
        "OPENRAM_TMP": str(temporary),
        # OpenRAM writes shapes in the order of Python sets, which string
        # hashing shuffles from run to run; a fixed seed fixes the order.
        "PYTHONHASHSEED": "0",
    }
    with (directory / "openram.log").open("w") as log:
        status = subprocess.run(
            [str(python), str(source / "sram_compiler.py"), "-v", str(config)],
            stdout=log,
            stderr=subprocess.STDOUT,
            env=environment,
            cwd=directory,
            check=False,
        ).returncode
    if status == 0:
        install_views(macro, output)
        print(f"{macro.name}: done", flush=True)
    else:
        print(
            f"{macro.name}: OpenRAM failed with status {status}; see "
            f"{directory.relative_to(REPOSITORY_ROOT)}/openram.log",
            flush=True,
        )
    return status


def selected_macros(names: Sequence[str]) -> list[Macro]:
    """Return the macros named, or all of them for an empty list."""
    by_name = {macro.name: macro for macro in MACROS}
    unknown = [name for name in names if name not in by_name]
    if unknown:
        raise ValueError(f"unknown macros: {', '.join(unknown)}")
    return [by_name[name] for name in names] if names else list(MACROS)


def build(names: Sequence[str], jobs: int) -> int:
    """Build the named macros, jobs at a time; run inside the ORFS image."""
    macros = selected_macros(names)
    BUILD_DIRECTORY.mkdir(parents=True, exist_ok=True)
    python, source = prepare_environment(BUILD_DIRECTORY)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        statuses = list(
            pool.map(
                lambda macro: build_macro(macro, python, source, BUILD_DIRECTORY),
                macros,
            )
        )
    return max(statuses, default=0)


def generate(names: Sequence[str], jobs: int) -> int:
    """Run build in the pinned ORFS image as the invoking user."""
    selected_macros(names)
    BUILD_DIRECTORY.mkdir(parents=True, exist_ok=True)
    command = [
        *("docker", "run", "--rm", "--init"),
        *("--user", f"{os.getuid()}:{os.getgid()}"),
        *("--env", "HOME=/tmp"),
        *("--volume", f"{REPOSITORY_ROOT}:{orfs.CONTAINER_ROOT}"),
        *("--workdir", str(orfs.CONTAINER_ROOT)),
        orfs.ORFS_IMAGE,
        *("python3", "asic/openram.py", "build", "--jobs", str(jobs), *names),
    ]
    return subprocess.run(command, check=False).returncode


def _positive_integer(text: str) -> int:
    """Parse a job count for argparse."""
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError(f"expected a positive integer, got {text}")
    return value


def _argument_parser() -> argparse.ArgumentParser:
    """Create the command-line parser."""
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest="command", required=True)
    for command, help_text in (
        ("generate", "build macros in the ORFS image and update asic/sram"),
        ("build", "build macros; runs inside the ORFS image"),
    ):
        subparser = commands.add_parser(command, help=help_text)
        subparser.add_argument(
            "macros", nargs="*", help="macros to build (default: all of them)"
        )
        subparser.add_argument(
            "--jobs",
            type=_positive_integer,
            default=len(MACROS),
            help="OpenRAM runs at once, one thread each (default: %(default)s)",
        )
    commands.add_parser("list", help="list the macros")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run the selected command."""
    args = _argument_parser().parse_args(argv)
    if args.command == "list":
        for macro in MACROS:
            print(macro.name)
        return 0
    try:
        if args.command == "build":
            return build(args.macros, args.jobs)
        return generate(args.macros, args.jobs)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

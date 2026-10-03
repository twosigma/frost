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

"""Report the X3 DDR4 controller's ECC state over JTAG.

The X3's DDR4 is 72 bits wide, so the controller checks ECC on every read. A
location not written since power-up holds a check code unrelated to its data,
and reading it latches an error here. ``boards/x3/x3_ddr_init.sv`` writes the
whole region after calibration to prevent that; a clean report after a cold
power cycle and a run confirms it. The report covers only addresses that were
actually read.

A report is clean when ECC_ON_OFF enables checking and ECC_STATUS and CE_CNT
are zero. With checking off the controller captures nothing, so zero counters
are reported as a failure. ECC_STATUS bit 0 is the uncorrectable error and
bit 1 the correctable one. CE_CNT saturates at 255, so a full counter means at
least that many correctable errors. There is no uncorrectable-error counter;
such an error shows in ECC_STATUS and the UE captures.

Exits with status 2 when the report is not clean and 1 when the read fails.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent.parent

sys.path.insert(0, str(SCRIPT_DIR.parent / "common"))
from hw_target import (  # noqa: E402
    add_target_args,
    select_target,
    validate_target_args,
)

TCL_SCRIPT = SCRIPT_DIR / "ddr_ecc_status.tcl"

# ECC register offsets within the controller's management window, taken from
# the generated IP's register map: status and the correctable-error counter
# first, then the captures that record where an error was and what it held.
ECC_REGISTERS: tuple[tuple[str, int], ...] = (
    ("ECC_STATUS", 0x000),
    ("ECC_EN_IRQ", 0x004),
    ("ECC_ON_OFF", 0x008),
    ("CE_CNT", 0x00C),
    ("CE_FFA_31_00", 0x1C0),
    ("CE_FFA_63_32", 0x1C4),
    ("CE_FFE", 0x180),
    ("UE_FFA_31_00", 0x2C0),
    ("UE_FFA_63_32", 0x2C4),
    ("UE_FFE", 0x280),
)

# The registers that decide whether the report is clean: whether an error
# happened, and whether checking was on. The captures only describe an error.
VERDICT_REGISTERS = ("ECC_STATUS", "CE_CNT", "ECC_ON_OFF")

# ECC_STATUS bit order is the controller's: bit 0 uncorrectable, bit 1
# correctable (mem_v1_4_axi_ctrl_reg_bank.sv, the ECC_STATUS write logic).
ECC_STATUS_UE = 0x1
ECC_STATUS_CE = 0x2

CE_CNT_SATURATION = 0xFF

RESULT_PATTERN = re.compile(
    r"^FROST_ECC(?P<after>_AFTER)? (?P<name>\w+)=(?P<value>[0-9a-fA-F]+)$"
)


def parse_report(output: str) -> tuple[dict[str, int], dict[str, int], str]:
    """Split the Tcl transcript into before values, after values and the master."""
    before: dict[str, int] = {}
    after: dict[str, int] = {}
    master = ""
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("FROST_ECC_MASTER "):
            master = line.split(" ", 1)[1]
            continue
        match = RESULT_PATTERN.match(line)
        if match:
            target = after if match.group("after") else before
            target[match.group("name")] = int(match.group("value"), 16)
    return before, after, master


def verdict(values: dict[str, int]) -> tuple[bool, list[str]]:
    """Return whether the report is clean, and the reasons it is not."""
    problems: list[str] = []
    missing = [name for name in VERDICT_REGISTERS if name not in values]
    if missing:
        return False, [f"{name} was not read" for name in missing]

    if not values["ECC_ON_OFF"] & 0x1:
        # With checking off the controller captures nothing, so zero counters
        # below would prove nothing.
        problems.append("ECC checking is disabled, so the counters mean nothing")

    status = values["ECC_STATUS"]
    if status & ECC_STATUS_CE:
        problems.append("a correctable error is latched in ECC_STATUS")
    if status & ECC_STATUS_UE:
        problems.append("an uncorrectable error is latched in ECC_STATUS")

    count = values["CE_CNT"]
    if count >= CE_CNT_SATURATION:
        problems.append(f"CE_CNT is saturated at {count}, so at least that many")
    elif count:
        problems.append(f"CE_CNT is {count}")
    return not problems, problems


def format_report(values: dict[str, int], heading: str) -> str:
    """Format one line per register, with the values aligned."""
    lines = [heading]
    for name, _ in ECC_REGISTERS:
        if name in values:
            lines.append(f"  {name:<14} 0x{values[name]:08x}")
    return "\n".join(lines)


def main() -> int:
    """Read the ECC registers and report whether the array has been read clean."""
    parser = argparse.ArgumentParser(
        description="Report the X3 DDR4 controller's ECC state over JTAG",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  ddr_ecc_status.py\n"
            "  ddr_ecc_status.py --clear        # report, then clear for a fresh start\n"
            "  ddr_ecc_status.py --json\n"
        ),
    )
    parser.add_argument("board", nargs="?", default="x3", choices=["x3"])
    parser.add_argument(
        "--clear",
        action="store_true",
        help=(
            "After reading, clear ECC_STATUS and CE_CNT and report the cleared "
            "values too; the result reflects the values before clearing"
        ),
    )
    parser.add_argument("--json", action="store_true", help="Print the values as JSON")
    parser.add_argument(
        "remote_host",
        nargs="?",
        default="",
        help="Remote server hostname or IP (port 3121 will be used)",
    )
    parser.add_argument(
        "--vivado-path",
        default="vivado",
        help="Path to Vivado executable (default: vivado from PATH)",
    )
    add_target_args(parser, managed=True)
    args = parser.parse_args()
    validate_target_args(parser, args)

    target_options = dict(
        hw_server_url=args.hw_server_url,
        target_exact=args.target_exact,
        non_interactive=args.non_interactive,
    )
    if args.list_targets:
        select_target(
            args.vivado_path,
            args.remote_host,
            list_only=True,
            board=args.board,
            **target_options,
        )
        return 0

    selected_target = select_target(
        args.vivado_path,
        args.remote_host,
        target_pattern=args.target,
        board=args.board,
        **target_options,
    )

    register_list = " ".join(f"{name}:{offset:#05x}" for name, offset in ECC_REGISTERS)
    command = [
        args.vivado_path,
        "-mode",
        "batch",
        "-nojournal",
        "-nolog",
        "-source",
        str(TCL_SCRIPT),
        "-tclargs",
        str(selected_target),
        "1" if args.clear else "0",
        register_list,
        args.remote_host or "",
        args.hw_server_url or "",
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    before, after, master = parse_report(completed.stdout)
    if completed.returncode != 0 or "FROST_ECC_DONE" not in completed.stdout:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        print("ECC read failed: the controller's registers were not reported")
        return 1

    clean, problems = verdict(before)
    if args.json:
        print(
            json.dumps(
                {
                    "master": master,
                    "clean": clean,
                    "problems": problems,
                    "registers": {name: value for name, value in before.items()},
                    "after_clear": {name: value for name, value in after.items()},
                },
                indent=2,
            )
        )
    else:
        print(format_report(before, f"DDR4 ECC state (read over {master}):"))
        if after:
            print(format_report(after, "After clearing:"))
        if clean:
            print("Clean: no ECC error has been reported since the last clear.")
        else:
            for problem in problems:
                print(f"Not clean: {problem}")
    return 0 if clean else 2


if __name__ == "__main__":
    sys.exit(main())

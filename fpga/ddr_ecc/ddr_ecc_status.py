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

"""Report the board's DDR4 controller ECC state over JTAG.

The 72-bit DDR4 interface checks ECC on reads. Unwritten locations have
uninitialized check codes, so the board initializes DDR after calibration.
Reports cover addresses read since the status was cleared.

A clean report requires checking enabled and ECC_STATUS and CE_CNT zero.
With checking disabled, zero counters cannot establish a clean read. ECC_STATUS
bit 0 is uncorrectable and bit 1 correctable. CE_CNT saturates at 255; there is
no uncorrectable-error counter, only status and UE capture registers.

The X3 ECC reader (boards/x3/x3_ecc_reader.sv) polls the same registers. It
clears ECC_STATUS's correctable bit after reading the captured address, so
after a corrected error only CE_CNT may show it, and it writes CE_CNT back to
1, never 0, once it reaches 128. It never clears the uncorrectable bit.

Exit 2 for a non-clean report, or 1 if the read fails.
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

# Each design assigns C0_REG in the DDR JTAG master's address space.
ECC_WINDOW_DESIGNS = {
    "x3": PROJECT_ROOT / "fpga/build/x3_ddr_bd.tcl",
    "vcu118": PROJECT_ROOT / "fpga/build/vcu118_ddr_bd.tcl",
}
CONTROL_SEGMENT = "C0_DDR4_MEMORY_MAP_CTRL/C0_REG"
DATA_SEGMENT = "C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK"
JTAG_ASSIGNMENT = re.compile(
    r"^[ \t]*assign_bd_address\s+-offset\s+(0x[0-9a-fA-F]+)\s+"
    r"-range\s+(0x[0-9a-fA-F]+)\s+"
    r"-target_address_space\s+\[get_bd_addr_spaces\s+jtag_axi_ddr/Data\]\s+"
    rf"\[get_bd_addr_segs\s+ddr4_0/({CONTROL_SEGMENT}|{DATA_SEGMENT})\]"
    r"(?:\s+-force)?[ \t]*$",
    re.MULTILINE,
)

# Both designs use the DDR4 2.2 controller's 32-bit ECC register bank.
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

# Status, error count, and checking enable decide whether the report is clean.
# Capture registers only describe errors.
VERDICT_REGISTERS = ("ECC_STATUS", "CE_CNT", "ECC_ON_OFF")

# ECC_STATUS bit order is the controller's: bit 0 uncorrectable, bit 1
# correctable (mem_v1_4_axi_ctrl_reg_bank.sv, the ECC_STATUS write logic).
ECC_STATUS_UE = 0x1
ECC_STATUS_CE = 0x2

CE_CNT_SATURATION = 0xFF
REGISTER_MASKS = {
    "ECC_STATUS": ECC_STATUS_UE | ECC_STATUS_CE,
    "ECC_EN_IRQ": ECC_STATUS_UE | ECC_STATUS_CE,
    "ECC_ON_OFF": 0x1,
    "CE_CNT": CE_CNT_SATURATION,
}

RESULT_PATTERN = re.compile(
    r"(FROST_ECC(?:_AFTER)?) (\w+)@(0x[0-9a-fA-F]{8})=([0-9a-fA-F]{8})"
)


def ecc_window_base(board: str) -> int:
    """Read the ECC window assigned to the board's DDR JTAG master."""
    design = ECC_WINDOW_DESIGNS[board]
    assignments = JTAG_ASSIGNMENT.findall(design.read_text().replace("\\\n", " "))
    windows: dict[str, tuple[int, int]] = {}
    for segment in (CONTROL_SEGMENT, DATA_SEGMENT):
        ranges = [(base, size) for base, size, name in assignments if name == segment]
        if len(ranges) != 1:
            raise ValueError(
                f"{design}: expected one {segment.split('/')[-1]} assignment for "
                f"jtag_axi_ddr/Data, found {len(ranges)}"
            )
        base, size = ranges[0]
        windows[segment] = int(base, 16), int(size, 16)
    base, size = windows[CONTROL_SEGMENT]
    if base % 4 or size < max(offset for _, offset in ECC_REGISTERS) + 4:
        raise ValueError(f"{design}: ECC window must cover aligned 32-bit registers")
    if base + size > 1 << 32:
        raise ValueError(f"{design}: ECC window exceeds the 32-bit JTAG address space")
    data_base, data_size = windows[DATA_SEGMENT]
    if not data_size or data_base + data_size > 1 << 32:
        raise ValueError(f"{design}: invalid DDR data window in the JTAG address space")
    if max(base, data_base) < min(base + size, data_base + data_size):
        raise ValueError(f"{design}: ECC window overlaps the DDR data window")
    return base


def parse_sample(
    records: list[str], marker: str, addresses: dict[str, int]
) -> dict[str, int]:
    """Require a complete sample with one 32-bit reply at each expected address."""
    values: dict[str, int] = {}
    for line in records:
        match = RESULT_PATTERN.fullmatch(line)
        if match is None or match[1] != marker:
            raise ValueError(f"malformed {marker} register reply: {line}")
        _, name, address, data = match.groups()
        if name not in addresses:
            raise ValueError(f"unexpected register in {marker}: {name}")
        if name in values:
            raise ValueError(f"duplicate {name} in {marker}")
        expected = addresses[name]
        if int(address, 16) != expected:
            raise ValueError(
                f"{name} reported address {address}, expected {expected:#010x}"
            )
        value = int(data, 16)
        if name in REGISTER_MASKS and value & ~REGISTER_MASKS[name]:
            raise ValueError(f"{name} has nonzero reserved bits: 0x{data}")
        values[name] = value
    missing = [name for name in addresses if name not in values]
    if missing:
        raise ValueError(f"missing {marker} register replies: {', '.join(missing)}")
    return values


def parse_report(
    output: str, window_base: int, *, clear: bool
) -> tuple[dict[str, int], dict[str, int], str]:
    """Validate the Tcl transcript and return the samples and DDR master."""
    records = [
        line
        for raw in output.splitlines()
        if (line := raw.strip()).startswith("FROST_ECC")
    ]
    if not records or records[-1] != "FROST_ECC_DONE":
        raise ValueError("missing final FROST_ECC_DONE line")
    master_tag, _, master = records[0].partition(" ")
    if master_tag != "FROST_ECC_MASTER" or not master:
        raise ValueError("missing FROST_ECC_MASTER line")
    samples = records[1:-1]
    addresses = {name: window_base + offset for name, offset in ECC_REGISTERS}
    after: dict[str, int] = {}
    if clear:
        if samples.count("FROST_ECC_CLEARED") != 1:
            raise ValueError("expected one FROST_ECC_CLEARED line")
        split = samples.index("FROST_ECC_CLEARED")
        after = parse_sample(samples[split + 1 :], "FROST_ECC_AFTER", addresses)
        samples = samples[:split]
    before = parse_sample(samples, "FROST_ECC", addresses)
    return before, after, master


def verdict(values: dict[str, int]) -> tuple[bool, list[str]]:
    """Return whether the report is clean, and the reasons it is not."""
    problems: list[str] = []
    missing = [name for name in VERDICT_REGISTERS if name not in values]
    if missing:
        return False, [f"{name} was not read" for name in missing]

    if not values["ECC_ON_OFF"] & 0x1:
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
        description="Report the board's DDR4 controller ECC state over JTAG",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  ddr_ecc_status.py\n"
            "  ddr_ecc_status.py --clear        # report, then clear for a fresh start\n"
            "  ddr_ecc_status.py vcu118 --json\n"
        ),
    )
    parser.add_argument(
        "board",
        nargs="?",
        default="x3",
        choices=ECC_WINDOW_DESIGNS,
        help="Target FPGA board (default: x3)",
    )
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
    parser.add_argument("--window-spec", action="store_true", help=argparse.SUPPRESS)
    add_target_args(parser, managed=True)
    args = parser.parse_args()
    validate_target_args(parser, args)

    if args.window_spec:
        # Tcl reads the same design before accepting an address or issuing AXI traffic.
        try:
            window_base = ecc_window_base(args.board)
        except (OSError, ValueError) as error:
            print(f"ECC read failed: {error}", file=sys.stderr)
            return 1
        registers = " ".join(f"{name}:{offset:#05x}" for name, offset in ECC_REGISTERS)
        print(f"{window_base:#010x} {registers}")
        return 0

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

    try:
        window_base = ecc_window_base(args.board)
    except (OSError, ValueError) as error:
        print(f"ECC read failed: {error}", file=sys.stderr)
        return 1

    selected_target = select_target(
        args.vivado_path,
        args.remote_host,
        target_pattern=args.target,
        board=args.board,
        **target_options,
    )

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
        f"{window_base:#010x}",
        args.board,
        args.remote_host or "",
        args.hw_server_url or "",
        sys.executable,
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    try:
        if completed.returncode != 0:
            raise ValueError(f"Vivado exited with status {completed.returncode}")
        before, after, master = parse_report(
            completed.stdout, window_base, clear=args.clear
        )
    except ValueError as error:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        print(f"ECC read failed: {error}", file=sys.stderr)
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

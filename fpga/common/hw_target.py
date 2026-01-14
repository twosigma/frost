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

"""Shared utilities for hardware target selection with multiple FPGAs."""

import subprocess
import sys
from pathlib import Path

# Map board names to expected vendor string in hardware target path
BOARD_VENDOR_FILTER = {
    "nexys_a7": "Digilent",
    "genesys2": "Digilent",
    "x3": "Xilinx",
}


def get_available_targets(vivado_path: str, remote_host: str = "") -> list[str]:
    """Query Vivado for available hardware targets.

    Args:
        vivado_path: Path to Vivado executable
        remote_host: Optional remote hardware server hostname

    Returns:
        List of hardware target names (e.g., 'localhost:3121/xilinx_tcf/Digilent/210299A8B4D1')
    """
    tcl_script = Path(__file__).parent / "list_hw_targets.tcl"

    vivado_command = [
        vivado_path,
        "-mode",
        "batch",
        "-nojournal",
        "-nolog",
        "-source",
        str(tcl_script),
    ]

    if remote_host:
        vivado_command.extend(["-tclargs", remote_host])

    result = subprocess.run(
        vivado_command,
        capture_output=True,
        text=True,
    )

    # Parse target list from stdout - look for lines starting with "TARGET:"
    targets = []
    for line in result.stdout.splitlines():
        if line.startswith("TARGET:"):
            targets.append(line[7:].strip())  # Remove "TARGET:" prefix

    return targets


def filter_targets(targets: list[str], pattern: str) -> list[str]:
    """Filter targets by pattern (case-insensitive substring or index).

    Args:
        targets: List of target names
        pattern: Filter pattern - either an index (0, 1, 2...) or substring to match

    Returns:
        List of matching targets
    """
    # Check if pattern is a numeric index
    if pattern.isdigit():
        index = int(pattern)
        if 0 <= index < len(targets):
            return [targets[index]]
        return []

    # Otherwise treat as case-insensitive substring match
    pattern_lower = pattern.lower()
    return [t for t in targets if pattern_lower in t.lower()]


def print_target_list(
    targets: list[str], header: str = "Available hardware targets:"
) -> None:
    """Print formatted list of targets with indices."""
    print(header)
    for i, target in enumerate(targets):
        print(f"  [{i}] {target}")


def prompt_target_selection(targets: list[str]) -> str:
    """Prompt user to select a target from list.

    Args:
        targets: List of target names to choose from

    Returns:
        Selected target name
    """
    print_target_list(targets)
    print()

    while True:
        try:
            selection = input("Enter target index: ").strip()
            if not selection.isdigit():
                print("Please enter a numeric index")
                continue

            index = int(selection)
            if 0 <= index < len(targets):
                return targets[index]
            print(f"Index must be between 0 and {len(targets) - 1}")
        except (EOFError, KeyboardInterrupt):
            print("\nAborted")
            sys.exit(1)


def select_target(
    vivado_path: str,
    remote_host: str = "",
    target_pattern: str | None = None,
    list_only: bool = False,
    board: str | None = None,
) -> str | None:
    """Select hardware target, prompting user if needed.

    Args:
        vivado_path: Path to Vivado executable
        remote_host: Optional remote hardware server hostname
        target_pattern: Optional pattern to filter targets (index or substring)
        list_only: If True, just list targets and return None
        board: Optional board name to auto-filter by vendor (e.g., 'nexys_a7' filters for 'Digilent')

    Returns:
        Selected target name, or None if list_only=True
    """
    all_targets = get_available_targets(vivado_path, remote_host)

    if not all_targets:
        print("Error: No hardware targets found", file=sys.stderr)
        print("  - Ensure JTAG cable is connected", file=sys.stderr)
        print("  - Check that the board is powered on", file=sys.stderr)
        if remote_host:
            print(f"  - Verify hw_server is running on {remote_host}", file=sys.stderr)
        sys.exit(1)

    # Apply board-based vendor filter if board is specified
    vendor_filter = BOARD_VENDOR_FILTER.get(board) if board else None
    if vendor_filter:
        targets = filter_targets(all_targets, vendor_filter)
        if not targets:
            print(
                f"Error: No {vendor_filter} targets found for board '{board}'",
                file=sys.stderr,
            )
            print_target_list(all_targets, header="All available targets:")
            sys.exit(1)
    else:
        targets = all_targets

    # List-only mode
    if list_only:
        if vendor_filter:
            print_target_list(
                targets, header=f"Available {vendor_filter} targets for '{board}':"
            )
        else:
            print_target_list(targets)
        return None

    # If user pattern provided, filter further
    if target_pattern is not None:
        matching = filter_targets(targets, target_pattern)

        if not matching:
            print(
                f"Error: No targets match pattern '{target_pattern}'", file=sys.stderr
            )
            print_target_list(targets, header="Available targets:")
            sys.exit(1)

        if len(matching) == 1:
            print(f"Selected target: {matching[0]}")
            return matching[0]

        # Multiple matches - prompt user
        print(f"Multiple targets match pattern '{target_pattern}':")
        return prompt_target_selection(matching)

    # No user pattern - auto-select if only one, otherwise prompt
    if len(targets) == 1:
        print(f"Using target: {targets[0]}")
        return targets[0]

    # Multiple targets after board filter - prompt user
    if vendor_filter:
        print(f"Multiple {vendor_filter} targets detected for board '{board}'.")
    else:
        print("Multiple hardware targets detected.")
    return prompt_target_selection(targets)


def add_target_args(parser) -> None:
    """Add --target and --list-targets arguments to an argument parser.

    Args:
        parser: argparse.ArgumentParser instance
    """
    parser.add_argument(
        "--target",
        metavar="PATTERN",
        help="Hardware target to use - index (0,1,2..) or pattern to match (e.g., 'Digilent', 'Xilinx', or serial number)",
    )
    parser.add_argument(
        "--list-targets",
        action="store_true",
        help="List available hardware targets and exit",
    )

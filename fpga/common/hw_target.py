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

"""Discover and select Vivado hardware targets."""

import subprocess
import sys
from pathlib import Path

# Board name -> (vendor filter, display name). X3 needs a delimited pattern
# because every target contains ``xilinx_tcf``.
BOARD_VENDOR_INFO = {
    "genesys2": ("Digilent", "Digilent"),
    "x3": ("/Xilinx/", "Xilinx"),
}


def get_available_targets(vivado_path: str, remote_host: str = "") -> list[str]:
    """Return target names reported by local or remote Vivado."""
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

    # Parse the machine-readable lines emitted by list_hw_targets.tcl.
    targets = []
    for line in result.stdout.splitlines():
        if line.startswith("TARGET:"):
            targets.append(line[7:].strip())

    return targets


def filter_targets(targets: list[str], pattern: str) -> list[str]:
    """Filter targets by numeric index or case-insensitive substring."""
    # Numeric patterns index the already vendor-filtered list.
    if pattern.isdigit():
        index = int(pattern)
        if 0 <= index < len(targets):
            return [targets[index]]
        return []

    # Other patterns match any case-insensitive substring.
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
    """Prompt for and return one target."""
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
    """Select a target, prompting on ambiguous matches; list only if requested."""
    all_targets = get_available_targets(vivado_path, remote_host)

    if not all_targets:
        print("Error: No hardware targets found", file=sys.stderr)
        print("  - Ensure JTAG cable is connected", file=sys.stderr)
        print("  - Check that the board is powered on", file=sys.stderr)
        if remote_host:
            print(f"  - Verify hw_server is running on {remote_host}", file=sys.stderr)
        sys.exit(1)

    # Apply the board's vendor filter before any user pattern.
    vendor_info = BOARD_VENDOR_INFO.get(board) if board else None
    if vendor_info:
        vendor_pattern, vendor_name = vendor_info
        targets = filter_targets(all_targets, vendor_pattern)
        if not targets:
            print(
                f"Error: No {vendor_name} targets found for board '{board}'",
                file=sys.stderr,
            )
            print_target_list(all_targets, header="All available targets:")
            sys.exit(1)
    else:
        vendor_name = None
        targets = all_targets

    # List mode stops before target selection.
    if list_only:
        if vendor_name:
            print_target_list(
                targets, header=f"Available {vendor_name} targets for '{board}':"
            )
        else:
            print_target_list(targets)
        return None

    # Apply an explicit index or substring pattern.
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

        # Ambiguous patterns require a choice.
        print(f"Multiple targets match pattern '{target_pattern}':")
        return prompt_target_selection(matching)

    # Auto-select a sole vendor match.
    if len(targets) == 1:
        print(f"Using target: {targets[0]}")
        return targets[0]

    # Otherwise prompt within the vendor-filtered list.
    if vendor_name:
        print(f"Multiple {vendor_name} targets detected for board '{board}'.")
    else:
        print("Multiple hardware targets detected.")
    return prompt_target_selection(targets)


def add_target_args(parser) -> None:
    """Add hardware-target selection arguments to ``parser``."""
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

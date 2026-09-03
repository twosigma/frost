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

"""Program a supported FPGA board over JTAG."""

import argparse
import subprocess
import sys
from pathlib import Path

# Import shared hardware-target selection.
sys.path.insert(0, str(Path(__file__).parent.parent / "common"))
from hw_target import BOARD_VENDOR_INFO, add_target_args, select_target


def main() -> None:
    """Load a compiled bitstream into FPGA configuration memory."""
    parser = argparse.ArgumentParser(
        description="Program FPGA bitstream to specified board via JTAG"
    )
    parser.add_argument(
        "board",
        choices=list(BOARD_VENDOR_INFO),
        help="Target board",
    )
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
    add_target_args(parser)
    args = parser.parse_args()

    # Listing targets does not require programming a device.
    if args.list_targets:
        select_target(
            args.vivado_path, args.remote_host, list_only=True, board=args.board
        )
        return

    # Select by board vendor and optional target pattern.
    selected_target = select_target(
        args.vivado_path,
        args.remote_host,
        target_pattern=args.target,
        board=args.board,
    )

    # Resolve the generated bitstream and programming script.
    script_dir = Path(__file__).parent.resolve()
    project_root = (
        script_dir.parent.parent
    )  # fpga/program_bitstream -> fpga -> frost root
    tcl_script = script_dir / "program_bitstream.tcl"

    # Vivado options must precede -tclargs or Tcl receives them as arguments.
    vivado_command = [
        args.vivado_path,
        "-mode",
        "batch",
        "-nojournal",
        "-nolog",
        "-source",
        str(tcl_script),
        "-tclargs",
        str(project_root),
        args.board,
        selected_target,
    ]

    if args.remote_host:
        vivado_command.append(args.remote_host)

    # Run Vivado and propagate programming failures.
    subprocess.run(vivado_command, check=True)


if __name__ == "__main__":
    main()

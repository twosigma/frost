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

"""Load software application to FPGA instruction memory via JTAG."""

import argparse
import os
import subprocess
import sys
from pathlib import Path

# Add common directory to path for shared modules
sys.path.insert(0, str(Path(__file__).parent.parent / "common"))
from hw_target import add_target_args, select_target

# Valid software applications
VALID_APPS = [
    "branch_pred_test",
    "c_ext_test",
    "call_stress",
    "coremark",
    "csr_test",
    "freertos_demo",
    "hello_world",
    "isa_test",
    "memory_test",
    "packet_parser",
    "print_clock_speed",
    "spanning_test",
    "strings_test",
    "uart_echo",
]

# Board configurations: clock frequency in Hz and CoreMark iterations
# Iterations are calibrated for ~10 second runtime on each board
BOARD_CONFIG = {
    "x3": {"clock_freq": 322265625, "coremark_iterations": 11000},
    "genesys2": {"clock_freq": 133333333, "coremark_iterations": 3000},
    "nexys_a7": {"clock_freq": 80000000, "coremark_iterations": 2000},
}


def compile_app_for_board(
    app_name: str, app_dir: Path, clock_freq: int, coremark_iterations: int
) -> bool:
    """Compile the application with board-specific settings.

    Args:
        app_name: Name of the application to compile
        app_dir: Path to the application directory
        clock_freq: CPU clock frequency for this board
        coremark_iterations: Number of iterations for CoreMark

    Returns:
        True if compilation succeeded, False otherwise
    """
    # Set up environment
    env = os.environ.copy()
    if "RISCV_PREFIX" not in env:
        env["RISCV_PREFIX"] = "riscv-none-elf-"

    # Set board-specific variables
    env["FPGA_CPU_CLK_FREQ"] = str(clock_freq)
    if app_name == "coremark":
        env["ITERATIONS"] = str(coremark_iterations)

    try:
        # Clean first to force recompilation with new settings
        subprocess.run(
            ["make", "clean"],
            cwd=app_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

        # Build with board-specific settings
        print(f"Compiling {app_name}...")
        result = subprocess.run(
            ["make"],
            cwd=app_dir,
            env=env,
            capture_output=False,  # Show output
            text=True,
            timeout=120,
        )

        if result.returncode != 0:
            return False

        # Verify the output file was created
        sw_mem = app_dir / "sw.mem"
        if not sw_mem.exists():
            print(f"Error: sw.mem not created for {app_name}", file=sys.stderr)
            return False

        return True

    except subprocess.TimeoutExpired:
        print(f"Error: Compilation timed out for {app_name}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error compiling {app_name}: {e}", file=sys.stderr)
        return False


def main() -> None:
    """Load software application to FPGA instruction memory via JTAG.

    Writes compiled program to BRAM through JTAG interface without reprogramming FPGA.
    """
    parser = argparse.ArgumentParser(
        description="Load software application to FPGA instruction memory via JTAG"
    )
    parser.add_argument(
        "board",
        choices=list(BOARD_CONFIG.keys()),
        help="Target FPGA board",
    )
    parser.add_argument(
        "software_app",
        nargs="?",
        choices=VALID_APPS,
        help="Software application to load",
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

    # Handle --list-targets: just list and exit (doesn't require software_app)
    if args.list_targets:
        select_target(
            args.vivado_path, args.remote_host, list_only=True, board=args.board
        )
        return

    # software_app is required for actual loading
    if not args.software_app:
        parser.error("software_app is required unless using --list-targets")

    # Select hardware target (may prompt user if multiple targets)
    # Auto-filters by vendor based on board (e.g., nexys_a7 -> Digilent, x3 -> Xilinx)
    selected_target = select_target(
        args.vivado_path,
        args.remote_host,
        target_pattern=args.target,
        board=args.board,
    )

    # Get board configuration
    board_config = BOARD_CONFIG[args.board]
    clock_freq = board_config["clock_freq"]
    coremark_iterations = board_config["coremark_iterations"]

    # Compute absolute paths based on script location
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent  # fpga/load_software -> fpga -> frost root
    tcl_script = script_dir / "load_software.tcl"
    app_dir = project_root / "sw" / "apps" / args.software_app

    if not app_dir.exists():
        print(f"Error: Application directory not found: {app_dir}", file=sys.stderr)
        sys.exit(1)

    # Compile the application before loading
    print(f"Compiling {args.software_app} for {args.board} ({clock_freq} Hz)...")
    if args.software_app == "coremark":
        print(f"  CoreMark iterations: {coremark_iterations}")
    if not compile_app_for_board(
        args.software_app, app_dir, clock_freq, coremark_iterations
    ):
        print(f"Error: Failed to compile {args.software_app}", file=sys.stderr)
        sys.exit(1)

    # Construct Vivado command to run load script
    # Note: -nojournal and -nolog must come BEFORE -tclargs, otherwise they get
    # passed to the TCL script as arguments instead of being interpreted by Vivado
    vivado_command = [
        args.vivado_path,
        "-mode",
        "batch",  # Non-interactive mode
        "-nojournal",
        "-nolog",
        "-source",
        str(tcl_script),
        "-tclargs",
        str(project_root),  # Pass project root as first arg
        args.software_app,
        selected_target,  # Pass selected hardware target
    ]

    if args.remote_host:
        vivado_command.append(args.remote_host)

    # Execute Vivado command (will raise exception on failure)
    subprocess.run(vivado_command, check=True)


if __name__ == "__main__":
    main()

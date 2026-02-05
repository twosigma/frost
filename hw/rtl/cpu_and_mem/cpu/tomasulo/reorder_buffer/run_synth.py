#!/usr/bin/env python3
"""Run standalone Vivado synthesis for reorder_buffer @ 300MHz."""

import subprocess
import sys
from pathlib import Path


def main():
    """Run Vivado batch synthesis and return exit code."""
    script_dir = Path(__file__).parent.resolve()
    work_dir = script_dir / "synth_work"
    tcl_script = script_dir / "synth_standalone.tcl"

    print("Running Vivado synthesis for reorder_buffer @ 300MHz...")
    print(f"Working directory: {script_dir}")
    print()

    # Ensure work directory exists for log files
    work_dir.mkdir(exist_ok=True)

    cmd = [
        "vivado",
        "-mode",
        "batch",
        "-source",
        str(tcl_script),
        "-log",
        str(work_dir / "vivado.log"),
        "-journal",
        str(work_dir / "vivado.jou"),
    ]

    result = subprocess.run(cmd, cwd=script_dir)

    if result.returncode == 0:
        print()
        print("Synthesis completed. Check synth_work/ for detailed reports.")
    else:
        print()
        print(f"Synthesis failed with exit code {result.returncode}")
        print("Check synth_work/vivado.log for details.")

    return result.returncode


if __name__ == "__main__":
    sys.exit(main())

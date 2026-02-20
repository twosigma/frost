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

"""Run standalone Vivado synthesis for tomasulo_wrapper @ 300MHz."""

import subprocess
import sys
from pathlib import Path


def main():
    """Run Vivado batch synthesis and return exit code."""
    script_dir = Path(__file__).parent.resolve()
    work_dir = script_dir / "synth_work"
    tcl_script = script_dir / "synth_standalone.tcl"

    print("Running Vivado synthesis for tomasulo_wrapper @ 300MHz...")
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

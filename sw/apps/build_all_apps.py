#!/usr/bin/env python3
#
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

"""Build all software applications in the sw/apps directory."""

import subprocess
import sys
from pathlib import Path


def main() -> int:
    """Build all applications by running 'make clean && make' in each subdirectory."""
    # Get the directory where this script lives (sw/apps)
    apps_dir = Path(__file__).parent.resolve()

    # Directories to skip: __pycache__ and apps that require special parameters
    skip_dirs = {"__pycache__", "arch_test"}

    # Find all subdirectories (excluding hidden directories and skip list)
    app_dirs = sorted(
        d
        for d in apps_dir.iterdir()
        if d.is_dir() and not d.name.startswith(".") and d.name not in skip_dirs
    )

    failed = []
    for app_dir in app_dirs:
        print(f"Building in {app_dir.name}...")
        try:
            subprocess.run(
                ["make", "clean"],
                cwd=app_dir,
                check=True,
            )
            subprocess.run(
                ["make"],
                cwd=app_dir,
                check=True,
            )
        except subprocess.CalledProcessError as e:
            print(f"Error: Build failed in {app_dir.name} (exit code {e.returncode})")
            failed.append(app_dir.name)

    if failed:
        print(f"\nFailed to build: {', '.join(failed)}")
        return 1

    print(f"\nSuccessfully built {len(app_dirs)} applications")
    return 0


if __name__ == "__main__":
    sys.exit(main())

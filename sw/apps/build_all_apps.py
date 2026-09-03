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

"""Build ordinary standalone applications in the sw/apps directory."""

import argparse
import subprocess
import sys
from pathlib import Path

# These suites do not have a meaningful parameter-free `make` invocation. Their
# dedicated runners choose a source test and, where applicable, compare a
# signature against a reference model.
PARAMETERIZED_APP_SKIP_REASONS = {
    "arch_test": "parameterized suite; use tests/test_arch_compliance.py",
    "riscv_tests": "parameterized suite; use tests/test_riscv_tests.py",
    "riscv_torture": "parameterized suite; use tests/test_riscv_torture.py",
}

LINUX_BOOT_SKIP_REASON = (
    "first build runs Buildroot for 30-60 minutes; pass --include-linux-boot to opt in"
)


def discover_app_directories(apps_dir: Path) -> list[Path]:
    """Return non-hidden application directories that contain a Makefile."""
    return sorted(
        d
        for d in apps_dir.iterdir()
        if d.is_dir() and not d.name.startswith(".") and (d / "Makefile").is_file()
    )


def main(argv: list[str] | None = None) -> int:
    """Clean and build each ordinary standalone application."""
    parser = argparse.ArgumentParser(
        description="Clean and build ordinary standalone FROST software applications"
    )
    parser.add_argument(
        "--include-linux-boot",
        action="store_true",
        help="include the 30-60 minute first-time Buildroot/Linux image build",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        dest="list_only",
        help="list selected and skipped applications without building",
    )
    args = parser.parse_args(argv)

    apps_dir = Path(__file__).parent.resolve()

    discovered_app_dirs = discover_app_directories(apps_dir)
    skip_reasons = dict(PARAMETERIZED_APP_SKIP_REASONS)
    if not args.include_linux_boot:
        skip_reasons["linux_boot"] = LINUX_BOOT_SKIP_REASON

    skipped_app_dirs = [d for d in discovered_app_dirs if d.name in skip_reasons]
    app_dirs = [d for d in discovered_app_dirs if d.name not in skip_reasons]

    if args.list_only:
        print("Applications selected for build:")
        for app_dir in app_dirs:
            print(f"  {app_dir.name}")
        if skipped_app_dirs:
            print("\nApplications skipped:")
            for app_dir in skipped_app_dirs:
                print(f"  {app_dir.name}: {skip_reasons[app_dir.name]}")
        return 0

    for app_dir in skipped_app_dirs:
        print(f"Skipping {app_dir.name}: {skip_reasons[app_dir.name]}")

    failed = []
    for app_dir in app_dirs:
        print(f"Building in {app_dir.name}...")
        action = "clean"
        try:
            subprocess.run(
                ["make", "clean"],
                cwd=app_dir,
                check=True,
            )
            action = "build"
            subprocess.run(
                ["make"],
                cwd=app_dir,
                check=True,
            )
        except subprocess.CalledProcessError as e:
            print(
                f"Error: {action} failed in {app_dir.name} (exit code {e.returncode})"
            )
            failed.append(app_dir.name)
        except OSError as e:
            print(f"Error: could not {action} {app_dir.name}: {e}")
            failed.append(app_dir.name)

    if failed:
        print(f"\nFailed to build: {', '.join(failed)}")
        return 1

    print(f"\nSuccessfully built {len(app_dirs)} applications")
    if skipped_app_dirs:
        print(f"Skipped {len(skipped_app_dirs)} special applications")
    return 0


if __name__ == "__main__":
    sys.exit(main())

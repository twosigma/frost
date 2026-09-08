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

"""Read trusted FROST repository metadata without running any hardware flow."""

import argparse
import contextlib
import json
from pathlib import Path
import re
import runpy
import sys
from typing import Any

MARKER = "FROST_REPOSITORY_METADATA="


def repository_metadata(repo_root: Path) -> dict[str, Any]:
    """Read loader applications, debug eligibility, and shared board defaults.

    The scripts receive non-main module names, so their CLI entry points,
    builds, Linux prerequisite probes, and hardware discovery do not run.
    Repository Python is executable code and requires a trusted workspace.
    """
    root = repo_root.resolve(strict=True)
    with contextlib.redirect_stdout(sys.stderr):
        loader = runpy.run_path(
            str(root / "fpga/load_software/load_software.py"),
            run_name="frost_metadata_loader",
        )
        defaults = runpy.run_path(
            str(root / "fpga/common/hw_defaults.py"),
            run_name="frost_metadata_defaults",
        )

    apps = loader.get("VALID_APPS")
    if (
        not isinstance(apps, list | tuple)
        or not apps
        or len(apps) > 1024
        or any(
            not isinstance(app, str)
            or len(app) > 128
            or re.fullmatch(r"[a-z][a-z0-9_]*", app) is None
            for app in apps
        )
        or len(set(apps)) != len(apps)
    ):
        raise ValueError("Loader VALID_APPS must contain unique application names")

    coremark = loader.get("COREMARK_PRO_APP_NAMES")
    ddr_apps = loader.get("DDR_APPS")
    for name, values in (("COREMARK_PRO_APP_NAMES", coremark), ("DDR_APPS", ddr_apps)):
        if not isinstance(values, list | tuple | set | frozenset) or any(
            not isinstance(app, str) or app not in apps for app in values
        ):
            raise ValueError(f"Loader {name} must reference accepted applications")

    debug_apps = loader.get("DEBUG_APPS")
    if not isinstance(debug_apps, list | tuple | set | frozenset) or any(
        not isinstance(app, str) or app not in apps for app in debug_apps
    ):
        raise ValueError("Loader DEBUG_APPS must reference accepted applications")
    debug_unsupported = loader.get("DEBUG_UNSUPPORTED")
    if not isinstance(debug_unsupported, dict) or any(
        app not in apps
        or not isinstance(reason, str)
        or not reason.strip()
        or len(reason) > 4096
        or any(character in reason for character in "\0\r\n")
        for app, reason in debug_unsupported.items()
    ):
        raise ValueError("Loader DEBUG_UNSUPPORTED must provide an app and reason")
    if set(debug_apps) & set(debug_unsupported) or set(debug_apps) | set(
        debug_unsupported
    ) != set(apps):
        raise ValueError("Loader debug eligibility must partition every application")

    directory_for_app = loader.get("app_build_directory_name")
    if not callable(directory_for_app):
        raise ValueError("Loader must expose app_build_directory_name")
    directories = {app: directory_for_app(app) for app in apps}
    if any(
        not isinstance(directory, str)
        or len(directory) > 128
        or re.fullmatch(r"[a-z][a-z0-9_]*", directory) is None
        for directory in directories.values()
    ):
        raise ValueError("Application build directories must be safe basenames")

    boards = loader.get("BOARD_CONFIG")
    if not isinstance(boards, dict) or not isinstance(boards.get("x3"), dict):
        raise ValueError("Loader BOARD_CONFIG must contain the X3 board")
    board = boards["x3"]
    has_ddr = board.get("has_ddr")
    if not isinstance(has_ddr, bool):
        raise ValueError("Loader BOARD_CONFIG must declare X3 DDR support")
    serials = defaults.get("DEFAULT_SERIALS")
    if not isinstance(serials, dict):
        raise ValueError("DEFAULT_SERIALS must contain board UART defaults")
    serial = serials.get("x3")
    if (
        not isinstance(serial, str)
        or not serial
        or len(serial) > 4096
        or any(character in serial for character in "\0\r\n")
    ):
        raise ValueError("DEFAULT_SERIALS must contain an X3 UART device")

    return {
        "apps": list(apps),
        "defaultSerial": serial,
        "coremarkProApps": [app for app in apps if app in coremark],
        "ddrApps": [app for app in apps if app in ddr_apps],
        "hasDdr": has_ddr,
        "debugApps": [app for app in apps if app in debug_apps],
        "debugUnsupported": debug_unsupported,
        "appBuildDirectories": directories,
    }


def main() -> None:
    """Emit one tagged JSON record for the extension's bounded query."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo_root", type=Path)
    args = parser.parse_args()
    print(
        MARKER + json.dumps(repository_metadata(args.repo_root), separators=(",", ":"))
    )


if __name__ == "__main__":
    main()

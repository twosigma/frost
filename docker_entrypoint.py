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

"""Docker entrypoint script for FROST development container.

Initializes every configured git submodule if needed before running the command.
Tooling-only jobs may set ``FROST_SKIP_SUBMODULE_INIT=1`` to avoid fetching
submodules they do not consume.
"""

import os
import subprocess
import sys
from pathlib import Path

WORKSPACE = Path("/workspace")
SKIP_SUBMODULE_INIT_ENV = "FROST_SKIP_SUBMODULE_INIT"


def submodules_need_init() -> bool:
    """Return whether any configured (including nested) submodule is uninitialized."""
    gitmodules = WORKSPACE / ".gitmodules"
    if not gitmodules.exists():
        return False

    result = subprocess.run(
        ["git", "-C", str(WORKSPACE), "submodule", "status", "--recursive"],
        check=True,
        capture_output=True,
        text=True,
    )
    # `git submodule status` prefixes an uninitialized worktree with `-`.
    return any(line.startswith("-") for line in result.stdout.splitlines())


def init_submodules() -> None:
    """Initialize git submodules."""
    print("Initializing git submodules...")
    subprocess.run(
        ["git", "-C", str(WORKSPACE), "submodule", "update", "--init", "--recursive"],
        check=True,
    )


def main() -> int:
    """Run entrypoint logic."""
    # Initialize git submodules if needed
    if os.environ.get(SKIP_SUBMODULE_INIT_ENV) != "1" and submodules_need_init():
        init_submodules()

    # Execute the command passed to docker run
    if len(sys.argv) > 1:
        os.execvp(sys.argv[1], sys.argv[1:])

    return 0


if __name__ == "__main__":
    sys.exit(main())

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

"""Check that U-Boot accepted the requested board settings."""

import argparse
from pathlib import Path


def validate_config(requested: Path, generated: Path) -> None:
    """Reject requested options omitted or changed by Kconfig."""
    actual = set(generated.read_text().splitlines())
    values = dict(line.split("=", 1) for line in actual if line.startswith("CONFIG_"))
    missing = []
    for line in requested.read_text().splitlines():
        if line.startswith("CONFIG_") and line not in actual:
            missing.append(line)
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            symbol = line[2 : -len(" is not set")]
            if values.get(symbol, "n") != "n":
                missing.append(line)
    if missing:
        raise ValueError("U-Boot did not apply: " + ", ".join(missing))


def main() -> None:
    """Validate a defconfig against its generated .config."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("requested", type=Path)
    parser.add_argument("generated", type=Path)
    args = parser.parse_args()
    try:
        validate_config(args.requested, args.generated)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()

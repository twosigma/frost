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

"""Check the AXI bridge roster and stable ownership across source edits."""

import json
from pathlib import Path
import subprocess
import sys

from formal.update_axi_bridge_groups import (
    ASSIGNMENTS,
    COMMAND,
    HELD,
    identities,
    update_assignments,
)

ROOT = Path(__file__).resolve().parents[1]


def test_axi_bridge_roster_is_up_to_date() -> None:
    """The checked-in roster is byte-identical to regeneration from the design."""
    result = subprocess.run(
        [sys.executable, "formal/update_axi_bridge_groups.py", "--check"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=150,
    )
    assert result.returncode == 0, (
        f"AXI bridge assertion roster is stale. Run: {COMMAND}\n"
        f"{result.stdout}{result.stderr}"
    )


def test_assertion_identity_ignores_layout_and_generated_numbers() -> None:
    """Source layout and unroll-number shifts preserve the instance identities."""
    before = "assert (value == other);"
    after = "assert ( value /* explanation */ == other );"
    original = {
        f"$assert$bridge.sv:1${number}": {
            "type": "$assert",
            "attributes": {"src": f"bridge.sv:1.1-1.{len(before) + 1}"},
        }
        for number in [10, 2, 20]
    }
    edited = {
        f"$assert$bridge.sv:2${number}": {
            "type": "$assert",
            "attributes": {"src": f"bridge.sv:2.1-2.{len(after) + 1}"},
        }
        for number in [50, 30, 40]
    }
    old = identities(original, {"bridge.sv": before})
    current = identities(edited, {"bridge.sv": "\n" + after})
    assert old.keys() == current.keys()
    assert list(old.values()) == [
        f"$assert$bridge.sv:1${number}" for number in [2, 10, 20]
    ]
    assert list(current.values()) == [
        f"$assert$bridge.sv:2${number}" for number in [30, 40, 50]
    ]


def test_assertion_addition_and_removal_preserve_other_owners() -> None:
    """Only added assertions enter the smallest group; the held check stays alone."""
    previous = json.loads((ROOT / "formal" / ASSIGNMENTS).read_text())
    owner = {
        key: index for index, group in enumerate(previous["groups"]) for key in group
    }
    removed = previous["groups"][0][0]
    current = {key: key for key in owner if key != removed}
    additions = ["label:added_a", "label:added_b", "label:added_c"]
    current.update({key: key for key in additions})
    updated = update_assignments(previous, current)
    new_owner = {
        key: index for index, group in enumerate(updated["groups"]) for key in group
    }
    assert new_owner.keys() == current.keys()
    assert all(new_owner[key] == owner[key] for key in owner if key != removed)
    assert updated["groups"][8] == [HELD]
    counts = [len(group) - (removed in group) for group in previous["groups"]]
    for key in additions:
        expected = min(range(8), key=lambda index: (counts[index], index))
        assert new_owner[key] == expected
        counts[expected] += 1

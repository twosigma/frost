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

"""Cocotb block, directed CPU, and compiled-program tests.

Use targets in ``tests/test_run_cocotb.py`` through ``scripts/frost.py cocotb``;
see ``verif/README.md`` for the directed CPU targets and shared helpers.
"""

import os
from typing import Any

from cocotb.handle import HierarchyObject
from cocotb_tests.test_common import TestConfig
from cocotb_tests.test_state import TestState
from cocotb_tests.test_helpers import DUTInterface, TestStatistics

_ORIGINAL_HIERARCHY_GETATTR = HierarchyObject.__getattr__


def _selective_visibility_getattr(self: HierarchyObject, name: str) -> Any:
    """Explain how to expose an unlisted HDL signal in selective-visibility builds."""
    try:
        return _ORIGINAL_HIERARCHY_GETATTR(self, name)
    except AttributeError as exc:
        if (
            not name.startswith("_")
            and os.environ.get("FROST_SELECTIVE_VISIBILITY") == "1"
        ):
            raise AttributeError(
                f"{self._path} contains no child object named {name} "
                "(selective-visibility frost build; list the signal in "
                "hw/sim/frost_cocotb_visibility.vlt or run with "
                "FROST_FULL_VISIBILITY=1)"
            ) from None
        raise exc


if HierarchyObject.__getattr__ is not _selective_visibility_getattr:
    HierarchyObject.__getattr__ = _selective_visibility_getattr  # type: ignore[method-assign]

__all__ = [
    "TestConfig",
    "TestState",
    "DUTInterface",
    "TestStatistics",
]

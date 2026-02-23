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

"""Pytest configuration for tests."""

import os
import sys
from typing import Any

import pytest


def pytest_configure(config: Any) -> None:
    """Register custom pytest markers."""
    config.addinivalue_line("markers", "cocotb: mark test as a cocotb simulation test")
    config.addinivalue_line("markers", "synthesis: mark test as a synthesis test")
    config.addinivalue_line(
        "markers", "formal: mark test as a formal verification test"
    )
    config.addinivalue_line("markers", "slow: mark test as slow running")


def pytest_addoption(parser: Any) -> None:
    """Add custom command line options for tests."""
    parser.addoption(
        "--sim",
        action="store",
        default=None,
        help="Simulator to use (verilator or icarus). "
        "When set, only parametrized tests for this simulator are run.",
    )


@pytest.fixture(scope="session", autouse=True)
def setup_cocotb_env(request: Any) -> None:
    """Set up environment variables for cocotb from command line options."""
    # Set SIM if explicitly provided via command line.
    # Parametrized tests override this in run_test_with_simulator().
    sim = request.config.getoption("--sim")
    if sim:
        os.environ["SIM"] = sim


def pytest_collection_modifyitems(config: Any, items: Any) -> None:
    """Filter cocotb tests by simulator and mark unsupported Python versions."""
    # Filter parametrized cocotb tests by --sim option.
    # Tests parametrized with "simulator" (e.g., test_cpu[verilator], test_cpu[icarus])
    # are deselected if they don't match the requested --sim value.
    sim = config.getoption("--sim")
    if sim:
        selected = []
        deselected = []
        for item in items:
            # Check if this test has a "simulator" parameter from parametrize
            callspec = getattr(item, "callspec", None)
            if callspec and "simulator" in callspec.params:
                if callspec.params["simulator"] != sim:
                    deselected.append(item)
                    continue
            selected.append(item)
        if deselected:
            config.hook.pytest_deselected(items=deselected)
            items[:] = selected

    if sys.version_info[:2] == (3, 11):
        reason = (
            f"Cocotb tests not supported for Python 3.11, "
            f"running {sys.version_info.major}.{sys.version_info.minor}"
        )
        xfail_cocotb = pytest.mark.xfail(reason=reason, raises=Exception)
        for item in items:
            if "cocotb" in item.keywords:
                item.add_marker(xfail_cocotb)

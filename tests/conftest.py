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

"""Pytest markers and session setup for the tests in this directory."""

import os
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
    config.addinivalue_line(
        "markers", "cocotb_real_program: mark cocotb real-program tests"
    )
    config.addinivalue_line("markers", "cocotb_unit: mark cocotb unit-bench tests")
    config.addinivalue_line(
        "markers", "coremark_pro: mark CoreMark-PRO real-program tests"
    )


@pytest.fixture(scope="session", autouse=True)
def setup_cocotb_env() -> None:
    """Select Verilator as the cocotb simulator."""
    os.environ["SIM"] = "verilator"


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(items: list[Any]) -> None:
    """Allocate startup seeds across the selected system configurations."""
    if os.environ.get("FROST_STARTUP_SWEEP") != "1":
        return
    from random_start_sweep import plan_startup_sweeps
    from test_run_cocotb import DDR_TIER_EXCLUDE, TEST_REGISTRY

    names = []
    for item in items:
        callspec = getattr(item, "callspec", None)
        name = callspec.params.get("test_name") if callspec else None
        if name not in TEST_REGISTRY:
            continue
        if (
            os.environ.get("FROST_COCOTB_MEM_CONFIG") == "ddr"
            and name in DDR_TIER_EXCLUDE
        ):
            continue
        names.append(name)
    plan_startup_sweeps(names)

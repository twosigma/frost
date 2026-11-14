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

"""Control Verilator checks at the system bench's reset boundary."""

import ctypes
import os

import cocotb


def enable_simulation_assertions() -> None:
    """Enable runtime checks after the bench has applied a complete reset."""
    simulator = ctypes.CDLL(None)
    if os.environ.get("FROST_STARTUP_BASELINE") == "1" and not hasattr(
        simulator, "frost_sim_assertions_enable"
    ):
        return
    simulator.frost_sim_assertions_enable.argtypes = []
    simulator.frost_sim_assertions_enable.restype = None
    simulator.frost_sim_assertions_enabled.argtypes = []
    simulator.frost_sim_assertions_enabled.restype = ctypes.c_bool
    simulator.frost_sim_assertions_enable()
    assert simulator.frost_sim_assertions_enabled(), "simulation checks did not arm"
    cocotb.log.info("Simulation assertions armed after reset")

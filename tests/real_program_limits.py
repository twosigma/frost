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

"""Cycle limits shared by the real-program bench and its CI shard checks."""

from collections.abc import Mapping

_DEFAULT_LIMIT = ("COCOTB_MAX_CYCLES", 500_000)
_COREMARK_LIMIT = ("COCOTB_COREMARK_MAX_CYCLES", 15_000_000)
_NIC_LIMIT = ("COCOTB_NIC_LOOPBACK_MAX_CYCLES", 4_000_000)
_PROGRAM_LIMITS = {
    "dma_torture": ("COCOTB_MAX_CYCLES", 1_500_000),
    "sprintf_test": (None, 2_000_000),
    "pde_return_hazard": ("COCOTB_MAX_CYCLES", 2_000_000),
    "wfi_lost_tick": (None, 2_000_000),
    "restore_window_stress": ("COCOTB_MAX_CYCLES", 1_500_000),
    "amo_irq_torture": ("COCOTB_AMO_TORTURE_MAX_CYCLES", 6_000_000),
    "nic_loopback": _NIC_LIMIT,
    "nic_cmo_loopback": _NIC_LIMIT,
    "nic_sg_loopback": _NIC_LIMIT,
    "nic_rate": _NIC_LIMIT,
    "nic_echo": _NIC_LIMIT,
    "tick_torture": ("COCOTB_TICK_TORTURE_MAX_CYCLES", 6_000_000),
    "mem_divergence_probe": ("COCOTB_MEM_DIVERGENCE_PROBE_MAX_CYCLES", 20_000_000),
    "misaligned_test": ("COCOTB_MAX_CYCLES", 2_000_000),
    "vec_mem_test": ("COCOTB_MAX_CYCLES", 2_000_000),
    # Allow headroom for the exhaustive unit-stride and alignment sweeps.
    "vec_mem_reserved_forms_test": ("COCOTB_MAX_CYCLES", 1_500_000),
    "linux_irq_active_ddr_test": ("COCOTB_MAX_CYCLES", 2_000_000),
}


def real_program_cycle_limit(app_name: str | None, env: Mapping[str, str]) -> int:
    """Return the cycle ceiling for one run of the named application."""
    variable, default = (
        _COREMARK_LIMIT
        if (app_name or "").startswith("coremark")
        else _PROGRAM_LIMITS.get(app_name or "", _DEFAULT_LIMIT)
    )
    return int(env.get(variable, default)) if variable is not None else default

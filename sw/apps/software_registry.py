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

"""Shared software application metadata."""

from dataclasses import dataclass

COREMARK_PRO_BASE_APP = "coremark_pro"


@dataclass(frozen=True)
class CoremarkProProgram:
    """A user-facing CoreMark-PRO program backed by the shared Makefile."""

    app_name: str
    workload: str
    description: str
    hardware_iterations: int
    hardware_supported: bool = True
    hardware_unsupported_reason: str = ""

    @property
    def simulation_run_args(self) -> str:
        """Simulation keeps the default verified single-iteration run."""
        return ""

    @property
    def hardware_performance_run_args(self) -> str:
        """Hardware performance runs use score mode and explicit iterations."""
        return f"-v0 -i{self.hardware_iterations}"

    @property
    def hardware_validation_run_args(self) -> str:
        """Hardware validation runs use CoreMark-PRO verification mode."""
        return "-v1"


COREMARK_PRO_PROGRAMS = (
    CoremarkProProgram(
        app_name="coremark_pro_core",
        workload="core",
        description="CoreMark-PRO core workload",
        hardware_iterations=1,
    ),
    CoremarkProProgram(
        app_name="coremark_pro_cjpeg",
        workload="cjpeg-rose7-preset",
        description="CoreMark-PRO JPEG compression workload",
        # 41 iterations ~= 10.2s, the minimum over the 10s score rule
        # (calibrated against the pre-DDR 1936 KiB heap; the DDR heap no
        # longer constrains iterations -- recalibrate with the sweep tooling).
        hardware_iterations=41,
    ),
    CoremarkProProgram(
        app_name="coremark_pro_linear_alg",
        workload="linear_alg-mid-100x100-sp",
        description="CoreMark-PRO LINPACK single-precision workload",
        # 0.96 s/iteration on the X3 300MHz build; 12 iterations ~= 11.6s.
        hardware_iterations=12,
    ),
    CoremarkProProgram(
        app_name="coremark_pro_loops",
        workload="loops-all-mid-10k-sp",
        description="CoreMark-PRO Livermore loops single-precision workload",
        # ~6 MiB heap, satisfied by the DDR-backed cached region (heap ~1 GiB).
        # Iteration count to be recalibrated on hardware with the sweep tooling.
        hardware_iterations=5000,
    ),
    CoremarkProProgram(
        app_name="coremark_pro_nnet",
        workload="nnet_test",
        description="CoreMark-PRO neural net workload",
        hardware_iterations=1,
    ),
    CoremarkProProgram(
        app_name="coremark_pro_parser",
        workload="parser-125k",
        description="CoreMark-PRO XML parser workload",
        # Parser runtime is heap-size sensitive (timings shifted with each
        # heap-size change pre-DDR); -i10 ~= 10.2s on the 1936 KiB heap --
        # recalibrate on the DDR heap with the sweep tooling.
        hardware_iterations=10,
    ),
    CoremarkProProgram(
        app_name="coremark_pro_radix2",
        workload="radix2-big-64k",
        description="CoreMark-PRO radix-2 FFT workload",
        # The ~800 KiB of constant FFT data is placed in the cached region
        # (.ddr_rodata via the unified linker) and delivered through the
        # sw_ddr.mem image. Iteration count to be recalibrated on hardware.
        hardware_iterations=1000,
    ),
    CoremarkProProgram(
        app_name="coremark_pro_sha",
        workload="sha-test",
        description="CoreMark-PRO SHA-256 workload",
        hardware_iterations=75,
    ),
    CoremarkProProgram(
        app_name="coremark_pro_zip",
        workload="zip-test",
        description="CoreMark-PRO zlib workload",
        # ~3.3 MiB heap, satisfied by the DDR-backed cached region.
        # Iteration count to be recalibrated on hardware with the sweep tooling.
        hardware_iterations=5000,
    ),
)

COREMARK_PRO_PROGRAM_BY_APP = {
    program.app_name: program for program in COREMARK_PRO_PROGRAMS
}
COREMARK_PRO_APP_NAMES = tuple(program.app_name for program in COREMARK_PRO_PROGRAMS)


def is_coremark_pro_program(app_name: str) -> bool:
    """Return True if app_name is a user-facing CoreMark-PRO program."""
    return app_name in COREMARK_PRO_PROGRAM_BY_APP


def app_build_directory_name(app_name: str) -> str:
    """Return the sw/apps directory that builds/stores app_name's artifacts."""
    if is_coremark_pro_program(app_name):
        return COREMARK_PRO_BASE_APP
    return app_name


def coremark_pro_hardware_error(app_name: str) -> str | None:
    """Return the hardware support error for app_name, or None if supported."""
    program = COREMARK_PRO_PROGRAM_BY_APP.get(app_name)
    if program is None or program.hardware_supported:
        return None
    return program.hardware_unsupported_reason


def coremark_pro_make_vars(
    app_name: str, *, hardware: bool, hardware_mode: str = "performance"
) -> dict[str, str]:
    """Return Makefile overrides for a CoreMark-PRO program alias."""
    program = COREMARK_PRO_PROGRAM_BY_APP.get(app_name)
    if program is None:
        return {}

    if hardware:
        if hardware_mode == "performance":
            run_args = program.hardware_performance_run_args
        elif hardware_mode == "validation":
            run_args = program.hardware_validation_run_args
        else:
            raise ValueError(f"Unknown CoreMark-PRO hardware mode: {hardware_mode}")
    else:
        run_args = program.simulation_run_args

    make_vars = {
        "WORKLOAD": program.workload,
        "COREMARK_PRO_RUN_ARGS": run_args,
    }
    if hardware:
        make_vars["COREMARK_PRO_OFFICIAL"] = "1"
    return make_vars

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
    # -v0 iteration count per board (keys match BOARD_CONFIG in load_software.py).
    # Each is calibrated so the score run clears CoreMark-PRO's ~10s score-rule
    # minimum on that board; the slower genesys2 (133MHz) needs fewer iterations
    # than X3 (300MHz) to reach it.
    hardware_iterations: dict[str, int]
    hardware_supported: bool = True
    hardware_unsupported_reason: str = ""

    def iterations_for(self, board: str) -> int:
        """Return the calibrated -v0 iteration count for board."""
        try:
            return self.hardware_iterations[board]
        except KeyError:
            raise ValueError(
                f"{self.app_name}: no CoreMark-PRO iteration count calibrated for "
                f"board '{board}'; add it to hardware_iterations."
            ) from None

    @property
    def simulation_run_args(self) -> str:
        """Simulation keeps the default verified single-iteration run."""
        return ""

    def hardware_performance_run_args(self, board: str) -> str:
        """Hardware performance runs use score mode and per-board iterations."""
        return f"-v0 -i{self.iterations_for(board)}"

    @property
    def hardware_validation_run_args(self) -> str:
        """Hardware validation runs use CoreMark-PRO verification mode."""
        return "-v1"


COREMARK_PRO_PROGRAMS = (
    CoremarkProProgram(
        app_name="coremark_pro_core",
        workload="core",
        description="CoreMark-PRO core workload",
        # One iteration runs ~60s on genesys2 / well over 10s on X3.
        hardware_iterations={"x3": 1, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_cjpeg",
        workload="cjpeg-rose7-preset",
        description="CoreMark-PRO JPEG compression workload",
        # X3: 41 iters ~= 10.2s (pre-DDR 1936 KiB heap calibration).
        # genesys2: 0.586 s/iter measured at -v0, so 18 iters ~= 10.5s.
        hardware_iterations={"x3": 41, "genesys2": 18},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_linear_alg",
        workload="linear_alg-mid-100x100-sp",
        description="CoreMark-PRO LINPACK single-precision workload",
        # X3: 0.96 s/iter, 12 iters ~= 11.6s.
        # genesys2: 2.535 s/iter measured at -v0, so 4 iters ~= 10.1s.
        hardware_iterations={"x3": 12, "genesys2": 4},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_loops",
        workload="loops-all-mid-10k-sp",
        description="CoreMark-PRO Livermore loops single-precision workload",
        # ~6 MiB heap, satisfied by the DDR-backed cached region (heap ~1 GiB).
        # A single pass already clears the 10s score-rule minimum (~17s on X3,
        # ~39s on genesys2), so one iteration suffices on both.
        hardware_iterations={"x3": 1, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_nnet",
        workload="nnet_test",
        description="CoreMark-PRO neural net workload",
        # One iteration runs ~40s on genesys2 / well over 10s on X3.
        hardware_iterations={"x3": 1, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_parser",
        workload="parser-125k",
        description="CoreMark-PRO XML parser workload",
        # Parser runtime is heap-size sensitive (per-iteration isn't constant).
        # X3: -i10 ~= 10.2s on the pre-DDR 1936 KiB heap (recheck on the DDR
        # heap). genesys2: 3 iters measured 13.2s at -v0 (2 fell short at 7.6s).
        hardware_iterations={"x3": 10, "genesys2": 3},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_radix2",
        workload="radix2-big-64k",
        description="CoreMark-PRO radix-2 FFT workload",
        # The ~800 KiB of constant FFT data is placed in the cached region
        # (.ddr_rodata via the unified linker) and delivered through the
        # sw_ddr.mem image. Measured at -v0: X3 0.166 s/iter -> 61 iters ~= 10.1s;
        # genesys2 0.94 s/iter -> 11 iters ~= 10.3s.
        hardware_iterations={"x3": 61, "genesys2": 11},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_sha",
        workload="sha-test",
        description="CoreMark-PRO SHA-256 workload",
        # X3: 75 iters. genesys2: 0.312 s/iter measured at -v0, 33 iters ~= 10.3s.
        hardware_iterations={"x3": 75, "genesys2": 33},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_zip",
        workload="zip-test",
        description="CoreMark-PRO zlib workload",
        # ~3.3 MiB heap, satisfied by the DDR-backed cached region. Measured at
        # -v0: X3 0.582 s/iter -> 18 iters ~= 10.5s; genesys2 1.45 s/iter ->
        # 7 iters ~= 10.2s.
        hardware_iterations={"x3": 18, "genesys2": 7},
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
    app_name: str,
    *,
    hardware: bool,
    hardware_mode: str = "performance",
    board: str | None = None,
) -> dict[str, str]:
    """Return Makefile overrides for a CoreMark-PRO program alias.

    ``board`` is required only for hardware performance (-v0) runs, which use a
    per-board iteration count; validation and simulation ignore it.
    """
    program = COREMARK_PRO_PROGRAM_BY_APP.get(app_name)
    if program is None:
        return {}

    if hardware:
        if hardware_mode == "performance":
            if board is None:
                raise ValueError(
                    "board is required for CoreMark-PRO performance (-v0) make vars"
                )
            run_args = program.hardware_performance_run_args(board)
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

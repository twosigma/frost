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
    # minimum on that board, with at least ~0.1s headroom where integer
    # granularity permits. The slower genesys2 (133MHz) needs fewer iterations
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


# INTERIM (-O3 recalibration in flight): the -O2-calibrated counts below are
# pre-scaled ~1.4x (integer) / ~1.5x (FP) toward a ~10.5s target so the first
# -O3 -v0 sweep clears the 10s floor in one pass (X3 counts also predate the
# M1 64-bit data tier, which further speeds the FP workloads). Per-workload
# comments still quote the -O2 measurements; replace counts and comments with
# measured -O3 times once that sweep lands.
COREMARK_PRO_PROGRAMS = (
    CoremarkProProgram(
        app_name="coremark_pro_core",
        workload="core",
        description="CoreMark-PRO core workload",
        # One iteration measured 24.231s on X3 / 54.520s on genesys2.
        hardware_iterations={"x3": 1, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_cjpeg",
        workload="cjpeg-rose7-preset",
        description="CoreMark-PRO JPEG compression workload",
        # X3: 49 iters measured 10.242s (41 fell short at 8.571s).
        # genesys2: 22 iters measured 10.347s (18 fell short at 8.467s).
        hardware_iterations={"x3": 71, "genesys2": 32},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_linear_alg",
        workload="linear_alg-mid-100x100-sp",
        description="CoreMark-PRO LINPACK single-precision workload",
        # X3: 24 iters measured 10.248s (12 fell short at 5.124s).
        # genesys2: 11 iters measured 10.568s (4 fell short at 3.843s).
        hardware_iterations={"x3": 37, "genesys2": 17},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_loops",
        workload="loops-all-mid-10k-sp",
        description="CoreMark-PRO Livermore loops single-precision workload",
        # ~6 MiB heap, satisfied by the DDR-backed cached region (heap ~1 GiB).
        # X3: 2 iterations measured 17.284s (1 fell short at 8.635s).
        # genesys2: one iteration measured 24.732s.
        hardware_iterations={"x3": 2, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_nnet",
        workload="nnet_test",
        description="CoreMark-PRO neural net workload",
        # One iteration measured 16.251s on X3 / 36.564s on genesys2. X3 gets 2
        # iterations: FP64-heavy, so M1 + -O3 could push one iteration to ~10s.
        hardware_iterations={"x3": 2, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_parser",
        workload="parser-125k",
        description="CoreMark-PRO XML parser workload",
        # Parser runtime is heap-size sensitive (per-iteration isn't constant).
        # X3: 18 iters measured 10.358s (17 fell short at 9.821s).
        # genesys2: 4 iters measured 11.066s (3 fell short at 9.039s).
        hardware_iterations={"x3": 26, "genesys2": 6},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_radix2",
        workload="radix2-big-64k",
        description="CoreMark-PRO radix-2 FFT workload",
        # The ~800 KiB of constant FFT data is placed in the cached region
        # (.ddr_rodata via the unified linker) and delivered through the
        # sw_ddr.mem image. X3: 63 iters measured 10.165s (61 fell short at
        # 9.842s). genesys2: 11 iters measured 10.201s.
        hardware_iterations={"x3": 98, "genesys2": 17},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_sha",
        workload="sha-test",
        description="CoreMark-PRO SHA-256 workload",
        # X3: 103 iters measured 10.104s (75 fell short at 7.357s).
        # genesys2: 44 iters measured 10.176s (33 fell short at 7.632s).
        hardware_iterations={"x3": 150, "genesys2": 64},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_zip",
        workload="zip-test",
        description="CoreMark-PRO zlib workload",
        # ~3.3 MiB heap, satisfied by the DDR-backed cached region. Measured at
        # -v0: X3 21 iters took 10.470s (18 fell short at 8.975s). genesys2
        # 9 iters took 11.077s (7 fell short at 8.618s).
        hardware_iterations={"x3": 30, "genesys2": 12},
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

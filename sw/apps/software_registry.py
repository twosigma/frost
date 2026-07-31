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


COREMARK_PRO_PROGRAMS = (
    CoremarkProProgram(
        app_name="coremark_pro_core",
        workload="core",
        description="CoreMark-PRO core workload",
        # -O3: one iteration measured 24.927s on X3 / 56.087s on genesys2.
        hardware_iterations={"x3": 1, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_cjpeg",
        workload="cjpeg-rose7-preset",
        description="CoreMark-PRO JPEG compression workload",
        # -O3: X3 5.176 iter/s (71 iters measured 13.717s) -> 54 ~= 10.4s.
        # genesys2 2.300 iter/s (32 iters measured 13.911s) -> 24 ~= 10.4s.
        hardware_iterations={"x3": 54, "genesys2": 24},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_linear_alg",
        workload="linear_alg-mid-100x100-sp",
        description="CoreMark-PRO LINPACK single-precision workload",
        # -O3: X3 3.091 iter/s (37 iters measured 11.970s) -> 32 ~= 10.4s.
        # genesys2 1.374 iter/s (17 iters measured 12.375s) -> 14 ~= 10.2s.
        hardware_iterations={"x3": 32, "genesys2": 14},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_loops",
        workload="loops-all-mid-10k-sp",
        description="CoreMark-PRO Livermore loops single-precision workload",
        # ~6 MiB heap, satisfied by the DDR-backed cached region (heap ~1 GiB).
        # -O3: X3 2 iterations measured 16.440s (1 falls short at ~8.2s).
        # genesys2: one iteration measured 23.742s.
        hardware_iterations={"x3": 2, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_nnet",
        workload="nnet_test",
        description="CoreMark-PRO neural net workload",
        # -O3: X3 2 iterations measured 19.591s -- one iteration would run
        # ~9.8s, under the floor (FP64-heavy; the 64-bit data tier sped this
        # workload ~1.66x). genesys2: one iteration measured 22.051s.
        hardware_iterations={"x3": 2, "genesys2": 1},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_parser",
        workload="parser-125k",
        description="CoreMark-PRO XML parser workload",
        # Parser runtime is heap-size sensitive (per-iteration isn't constant),
        # so both counts keep extra margin above the usual ~10.4s target.
        # -O3: X3 1.786 iter/s (26 iters measured 14.555s) -> 19 ~= 10.6s.
        # genesys2 0.398 iter/s (6 iters measured 15.064s) -> 5 ~= 12.6s.
        hardware_iterations={"x3": 19, "genesys2": 5},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_radix2",
        workload="radix2-big-64k",
        description="CoreMark-PRO radix-2 FFT workload",
        # The ~800 KiB of constant FFT data is placed in the cached region
        # (.ddr_rodata via the unified linker) and delivered through the
        # sw_ddr.mem image. -O3: X3 10.475 iter/s (98 iters measured 9.356s,
        # under the floor -- the 64-bit data tier + -O3 sped this 1.69x) ->
        # 110 ~= 10.5s. genesys2 1.423 iter/s (17 iters measured 11.945s)
        # -> 15 ~= 10.5s.
        hardware_iterations={"x3": 110, "genesys2": 15},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_sha",
        workload="sha-test",
        description="CoreMark-PRO SHA-256 workload",
        # -O3: X3 10.516 iter/s (150 iters measured 14.264s) -> 110 ~= 10.5s.
        # genesys2 4.461 iter/s (64 iters measured 14.347s) -> 46 ~= 10.3s.
        hardware_iterations={"x3": 110, "genesys2": 46},
    ),
    CoremarkProProgram(
        app_name="coremark_pro_zip",
        workload="zip-test",
        description="CoreMark-PRO zlib workload",
        # ~3.3 MiB heap, satisfied by the DDR-backed cached region.
        # -O3: X3 2.083 iter/s (30 iters measured 14.401s) -> 22 ~= 10.6s.
        # genesys2 0.840 iter/s (12 iters measured 14.288s) -> 9 ~= 10.7s.
        hardware_iterations={"x3": 22, "genesys2": 9},
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

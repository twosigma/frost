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

"""Repeat the qualified placement natively with Vivado 2025.2.

By default, reuse the archived first placement. --regenerate-reference also
repeats the initial full placement from the archived post-opt checkpoint.
Neither mode runs phys_opt_design or route_design.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess


def sha256(path):
    """Return the checksum used to bind checkpoints and timing records."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def gate(directory, require_pass=True):
    """Check the saved gate's clock, uncertainty, and strict timing target."""
    values = dict(
        line.split("=", 1)
        for line in (directory / "post_place_gate.txt").read_text().splitlines()
    )
    slack = float(values["WORST_SLACK_NS"])
    if not math.isfinite(slack):
        raise RuntimeError("Non-finite timing result")
    if values["CPU_PERIOD_NS"] != "3.103":
        raise RuntimeError("Unexpected CPU clock period")
    if float(values["USER_SETUP_UNCERTAINTY_NS"]) != 0:
        raise RuntimeError("Added scoring uncertainty is not zero")
    if require_pass and (
        values["STATUS"] != "PASS"
        or values["STRICT_BELOW_GATE_PATHS"] != "0"
        or slack <= -0.200
    ):
        raise RuntimeError(f"Placement missed the strict target: {slack} ns")
    return values


def main():
    """Validate archived inputs, place the design, and verify a clean reopen."""
    package = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--artifacts",
        type=Path,
        default=package.parents[1] / "build/x3/post_place_20261003",
        help="Archived checkpoint bundle (see README.txt); not stored in Git",
    )
    parser.add_argument("--regenerate-reference", action="store_true")
    parser.add_argument("--vivado", default="/tools/Xilinx/2025.2/Vivado/bin/vivado")
    args = parser.parse_args()
    artifacts = args.artifacts.resolve()
    manifest = json.loads((package / "manifest.json").read_text())
    for name, expected in manifest["files_sha256"].items():
        root = artifacts if name.startswith("reference/") else package
        if not (root / name).is_file():
            raise RuntimeError(
                f"Missing archived input: {root / name}. "
                "Supply the checkpoint bundle with --artifacts (see README.txt)."
            )
        if sha256(root / name) != expected:
            raise RuntimeError(f"Archived input changed: {name}")
    version = subprocess.check_output([args.vivado, "-version"], text=True)
    if "vivado v2025.2 " not in version.lower():
        raise RuntimeError("This recipe requires Vivado 2025.2")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    post_opt = artifacts / "reference/post_opt.dcp"
    reference = artifacts / "reference/post_place.dcp"
    env = os.environ.copy()
    env.update(
        FROST_EXPERIMENT_CLOCK_ROOT="X1Y9",
        FROST_PLACE_SETUP_UNCERTAINTY="0.300",
        FROST_PLACE_CELL_BLOAT="",
    )

    def run(script, directory, arguments):
        directory.mkdir(parents=True, exist_ok=False)
        command = [
            args.vivado,
            "-mode",
            "batch",
            "-nojournal",
            "-source",
            str(package / "recipe" / script),
            "-tclargs",
            *map(str, arguments),
        ]
        print(f"Running {script}; log: {directory / 'run.log'}", flush=True)
        (directory / "command.json").write_text(
            json.dumps(
                {
                    "argv": command,
                    "env": {
                        key: value
                        for key, value in env.items()
                        if key.startswith("FROST_EXPERIMENT_")
                        or key
                        in {"FROST_PLACE_SETUP_UNCERTAINTY", "FROST_PLACE_CELL_BLOAT"}
                    },
                },
                indent=2,
            )
            + "\n"
        )
        with (directory / "run.log").open("w") as log:
            subprocess.run(
                command,
                cwd=directory,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
            )

    place_arguments = ["x3", "place", "ExtraNetDelay_high", post_opt, "0"]
    if args.regenerate_reference:
        seed = output / "seed"
        run("place_root.tcl", seed, place_arguments)
        gate(seed, require_pass=False)
        reference = seed / "post_place.dcp"
    env["FROST_EXPERIMENT_REFERENCE"] = str(reference)
    work = output / "work"
    run("place_mux_pins.tcl", work, place_arguments)
    original_gate = gate(work)
    verification = output / "verification"
    run("verify_place.tcl", verification, [work / "post_place.dcp", verification])
    if gate(verification) != original_gate:
        raise RuntimeError("Clean-reopen timing differs from the placement result")
    shutil.copy2(package / "netlist_config.json", work / "netlist_config.json")
    binding = {
        "schema": "x3_post_place_gate_binding_v1",
        "checkpoint_sha256": sha256(work / "post_place.dcp"),
        "gate_sha256": sha256(work / "post_place_gate.txt"),
    }
    (work / "post_place_gate_binding.json").write_text(
        json.dumps(binding, indent=2) + "\n"
    )
    result = {
        "gate": original_gate,
        "reference_regenerated": args.regenerate_reference,
        "reference_sha256": sha256(reference),
        "post_opt_sha256": sha256(post_opt),
        "checkpoint_sha256": binding["checkpoint_sha256"],
    }
    (output / "reproduction_result.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    print(f"Verified post-place WNS: {original_gate['WORST_SLACK_NS']} ns", flush=True)


if __name__ == "__main__":
    main()

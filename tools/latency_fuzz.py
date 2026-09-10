#!/usr/bin/env python3
"""Deterministic FROST timing-stress runner.

Runs a reproducible matrix of memory/fetch timing perturbations. Every run is
identified by a seed and the exact Verilator parameters are written to a JSON
manifest so a failing interleaving can be replayed verbatim.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tests" / "test_run_cocotb.py"

@dataclass(frozen=True)
class Profile:
    name: str
    latency: int
    jitter: int
    reorder: int
    fetch_fuzz: int

PROFILES = {
    "baseline": Profile("baseline", 30, 0, 0, 0),
    "ddr-jitter": Profile("ddr-jitter", 30, 19, 0, 0),
    "ddr-reorder": Profile("ddr-reorder", 30, 19, 1, 0),
    "fetch-jitter": Profile("fetch-jitter", 30, 19, 1, 7),
    "max-stress": Profile("max-stress", 7, 31, 1, 15),
}

def run_one(test: str, profile: Profile, seed: int) -> int:
    args = [
        sys.executable, str(RUNNER), test,
        "--random-seed", str(seed),
    ]
    params = [
        f"-GDDR_MODEL_LATENCY={profile.latency}",
        f"-GDDR_MODEL_LATENCY_JITTER={profile.jitter}",
        f"-GDDR_MODEL_JITTER_SEED={seed & 0xffff or 0xACE1}",
        f"-GDDR_MODEL_REORDER={profile.reorder}",
        f"-GFETCH_VALID_FUZZ={profile.fetch_fuzz}",
        f"-GFETCH_VALID_FUZZ_SEED={seed or 0xACE1}",
    ]
    env = os.environ.copy()
    env["FROST_VERILATOR_EXTRA_ARGS"] = " ".join(params)
    env["FROST_LATENCY_FUZZ_PROFILE"] = profile.name
    env["FROST_LATENCY_FUZZ_SEED"] = str(seed)
    return subprocess.call(args, cwd=ROOT, env=env)

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("test", help="registered cocotb test name")
    ap.add_argument("--profile", choices=sorted(PROFILES), default="max-stress")
    ap.add_argument("--seed", type=lambda x: int(x, 0), default=1)
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--manifest", type=Path, default=Path("build/latency-fuzz.json"))
    args = ap.parse_args()
    if args.count < 1:
        ap.error("--count must be >= 1")
    profile = PROFILES[args.profile]
    runs = []
    for i in range(args.count):
        seed = (args.seed + i) & 0xffffffff
        runs.append({"test": args.test, "seed": seed, **asdict(profile)})
    manifest = ROOT / args.manifest
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({"runs": runs}, indent=2) + "\n")
    for run in runs:
        rc = run_one(args.test, profile, run["seed"])
        if rc:
            print(f"LATENCY-FUZZ FAIL profile={profile.name} seed={run['seed']}", file=sys.stderr)
            print(f"Replay: {sys.executable} tools/latency_fuzz.py {args.test} --profile {profile.name} --seed {run['seed']}", file=sys.stderr)
            return rc
        print(f"LATENCY-FUZZ PASS profile={profile.name} seed={run['seed']}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

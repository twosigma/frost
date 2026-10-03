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

"""Check the Ethernet MAC/PCS with portable coarse synthesis in the frost image.

Run ``./scripts/frost.py run python3 tests/net10g/synthesize.py``. sv2v converts
a snapshot of the sources for Yosys. If the image lacks the pinned sv2v, the
script downloads its release archive, checks the SHA-256, and caches it in
sim_build/synthesis, where the logs, source hashes, converted Verilog, JSON
netlist, and summary.json also stay.

The check fails on latches, blackboxes, structural errors, and out-of-range bit
selects. It does not check device mapping, timing, or GTY interoperability. FSM
recoding stays disabled to avoid expanding the eight-lane RX parser's symbolic
transition logic.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import resource
import shutil
import subprocess
from typing import Any
import urllib.request
import zipfile


SV2V_VERSION = "v0.0.13"
SV2V_URL = (
    f"https://github.com/zachjs/sv2v/releases/download/{SV2V_VERSION}/sv2v-Linux.zip"
)
SV2V_SHA256 = "552799a1d76cd177b9b4cc63a3e77823a3d2a6eb4ec006569288abeff28e1ff8"
TOP = "eth10g_mac_pcs"
MAX_FRAME_BYTES = 9216


def fetch_frontend(directory: Path) -> Path:
    """Download the pinned sv2v release if needed, check it, and extract the binary.

    The release's LICENSE and NOTICE files are extracted with it.
    """
    archive = directory / "sv2v-Linux.zip"
    if not archive.exists():
        print(f"Downloading sv2v {SV2V_VERSION}", flush=True)
        with urllib.request.urlopen(SV2V_URL, timeout=60) as response:
            archive.write_bytes(response.read())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != SV2V_SHA256:
        raise SystemExit(
            f"sv2v archive SHA256 mismatch: {digest}; expected {SV2V_SHA256}"
        )
    binary = directory / "sv2v"
    with zipfile.ZipFile(archive) as release:
        binary.write_bytes(release.read("sv2v-Linux/sv2v"))
        (directory / "sv2v-LICENSE").write_bytes(release.read("sv2v-Linux/LICENSE"))
        (directory / "sv2v-NOTICE").write_bytes(release.read("sv2v-Linux/NOTICE"))
    binary.chmod(0o755)
    return binary


def locate_frontend(directory: Path) -> Path:
    """Use the image's sv2v if it is the pinned version; otherwise download it."""
    installed = shutil.which("sv2v")
    if installed is not None:
        result = subprocess.run(
            [installed, "--version"], capture_output=True, text=True, check=False
        )
        version = (result.stdout or result.stderr).strip()
        if result.returncode == 0 and version.startswith(f"sv2v {SV2V_VERSION}"):
            return Path(installed)
        print(
            f"Ignoring {installed} ({version or 'no version'}); "
            f"expected sv2v {SV2V_VERSION}",
            flush=True,
        )
    return fetch_frontend(directory)


def limit_memory() -> None:
    """Limit this process's address space to 8 GiB (run_logged's preexec_fn)."""
    maximum = 8 * 1024**3
    resource.setrlimit(resource.RLIMIT_AS, (maximum, maximum))


def run_logged(
    command: list[str], log: Path, timeout: int, address_limit: bool = True
) -> None:
    """Run a command with a timeout, writing all its output to a log.

    On failure or timeout, print the end of the log and re-raise.
    """
    print(f"Running {Path(command[0]).name}; log: {log}", flush=True)
    try:
        with log.open("w") as output:
            subprocess.run(
                command,
                check=True,
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=timeout,
                preexec_fn=limit_memory if address_limit else None,
            )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("\n".join(log.read_text(errors="replace").splitlines()[-70:]), flush=True)
        raise


def binary_value(value: str | int) -> int:
    """Decode the binary strings Yosys uses for cell and module parameters."""
    return value if isinstance(value, int) else int(value, 2)


def inspect_netlist(path: Path) -> dict[str, int]:
    """Check the netlist and return its cell and memory counts.

    Fails on a missing top, a top frame-limit default other than MAX_FRAME_BYTES,
    blackbox or whitebox modules, latches, unresolved cells, or less memory than
    four maximum frames.
    """
    design = json.loads(path.read_text())
    modules: dict[str, Any] = design["modules"]
    assert TOP in modules, "The top module is missing from the netlist"
    top_parameters = modules[TOP]["parameter_default_values"]
    assert binary_value(top_parameters["MAX_FRAME_BYTES"]) == MAX_FRAME_BYTES
    for name, module in modules.items():
        for attribute in ("blackbox", "whitebox"):
            assert binary_value(module.get("attributes", {}).get(attribute, 0)) == 0, (
                f"Unexpected {attribute}: {name}"
            )
        for cell in module["cells"].values():
            kind = cell["type"]
            assert "latch" not in kind.lower(), f"Inferred latch in {name}: {kind}"
            assert kind.startswith("$") or kind in modules, f"Unresolved cell: {kind}"

    def count_module(name: str) -> dict[str, int]:
        counts = {"cells": 0, "memory_cells": 0, "memory_bits": 0}
        for cell in modules[name]["cells"].values():
            kind = cell["type"]
            if kind in modules:
                child = count_module(kind)
                for key in counts:
                    counts[key] += child[key]
            else:
                counts["cells"] += 1
                if kind in ("$mem", "$mem_v2"):
                    counts["memory_cells"] += 1
                    params = cell["parameters"]
                    counts["memory_bits"] += binary_value(
                        params["WIDTH"]
                    ) * binary_value(params["SIZE"])
        return counts

    counts = count_module(TOP)
    assert counts["memory_cells"] > 0, "Coarse synthesis removed every memory"
    assert counts["memory_bits"] >= 4 * MAX_FRAME_BYTES * 8, (
        "Expected at least two full frames of buffering in each direction"
    )
    return counts


def main() -> None:
    """Snapshot and convert the sources, then check default-size coarse synthesis."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--timeout", type=int, default=300, help="timeout per tool in seconds"
    )
    args = parser.parse_args()
    if not Path("/.dockerenv").exists():
        parser.error(
            "run through ./scripts/frost.py run python3 tests/net10g/synthesize.py"
        )
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("the pinned sv2v release binary requires Linux x86_64")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    root = Path(__file__).resolve().parents[2]
    directory = root / "tests/net10g/sim_build/synthesis"
    source_directory = directory / "sources"
    source_directory.mkdir(parents=True, exist_ok=True)
    frontend = locate_frontend(directory)
    versions = {
        "sv2v": subprocess.check_output(
            [str(frontend), "--version"], text=True
        ).strip(),
        "yosys": subprocess.check_output(["yosys", "-V"], text=True).strip(),
    }
    assert versions["sv2v"].startswith(f"sv2v {SV2V_VERSION}")
    assert versions["yosys"].startswith("Yosys 0.69")
    print(json.dumps(versions, indent=2), flush=True)

    rtl = root / "hw/rtl/net10g"
    # The MAC/PCS modules, plus the library synchronizer its fault-status
    # crossing instantiates.
    sources = (
        sorted(rtl.glob("*_pkg.sv"))
        + sorted(path for path in rtl.glob("*.sv") if not path.name.endswith("_pkg.sv"))
        + [root / "hw/rtl/lib/cdc/cdc_sync.sv"]
    )
    manifest: dict[str, str] = {}
    snapshots = []
    for source in sources:
        content = source.read_bytes()
        snapshot = source_directory / source.name
        snapshot.write_bytes(content)
        snapshots.append(str(snapshot))
        manifest[str(source.relative_to(root))] = hashlib.sha256(content).hexdigest()
    (directory / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")

    converted = directory / "net10g.v"
    netlist = directory / "net10g.json"
    script = directory / "synthesis.ys"
    for stale in (converted, netlist, directory / "summary.json"):
        stale.unlink(missing_ok=True)
    run_logged(
        [
            str(frontend),
            # Leaves out simulation-only code ($error, assertions), as the CPU's
            # Yosys flow in tests/test_run_yosys.py does.
            "-DSYNTHESIS",
            f"--top={TOP}",
            f"--write={converted}",
            *snapshots,
            "+RTS",
            "-N2",
            "-M2G",
            "-RTS",
        ],
        directory / "sv2v.log",
        args.timeout,
        # sv2v's GHC runtime reserves a large virtual address range, so its
        # own limits (a 2 GiB heap, two workers) bound it instead of RLIMIT_AS.
        address_limit=False,
    )
    script.write_text(
        f"read_verilog {converted}\n"
        f"hierarchy -check -top {TOP}\n"
        f"synth -top {TOP} -nofsm -run coarse\n"
        "check -assert\n"
        "select -assert-none t:$dlatch t:$adlatch t:$_DLATCH_*\n"
        "stat\n"
        f"write_json {netlist}\n"
    )
    run_logged(
        ["yosys", "-Q", "-T", "-s", str(script)], directory / "yosys.log", args.timeout
    )
    assert "out of bounds" not in (directory / "yosys.log").read_text().lower(), (
        "Synthesis reported an out-of-range bit selection; inspect yosys.log"
    )
    counts = inspect_netlist(netlist)
    summary = {"top": TOP, "max_frame_bytes": MAX_FRAME_BYTES, **versions, **counts}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    print(
        "Coarse synthesis passed: no latches, blackboxes, or structural check failures",
        flush=True,
    )


if __name__ == "__main__":
    main()

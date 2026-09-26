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

"""Run the standalone Ethernet MAC/PCS benches in the frost image.

Each target is cleaned before it builds; its results go to sim_build/<target>/.
"""

import argparse
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


# Target: (top, test module, NET10G_MAX_FRAME_BYTES or None for the default).
TARGETS: dict[str, tuple[str, str, int | None]] = {
    "crc": ("eth10g_crc32_64", "test_crc", None),
    "codec": ("codec_tb", "test_codec", None),
    "scrambler": ("scrambler_tb", "test_scrambler", None),
    "sequence": ("sequence_tb", "test_sequence", None),
    "gearbox": ("gearbox_tb", "test_gearbox", None),
    "link": ("link_tb", "test_link", None),
    "tx_reconcile": ("eth10g_tx_reconcile", "test_tx_reconcile", None),
    "mac_tx": ("eth10g_mac_tx", "test_mac_tx", None),
    "mac_rx": ("eth10g_mac_rx", "test_mac_rx", None),
    # Small limits bring the receive MAC's storage limits within a few frames;
    # at both, the largest frame plus its FCS ends on a word boundary.
    "mac_rx_60": ("eth10g_mac_rx", "test_mac_rx", 60),
    "mac_rx_124": ("eth10g_mac_rx", "test_mac_rx", 124),
    "integration": ("eth10g_mac_pcs", "test_integration", None),
}


def main() -> None:
    """Build and run each requested bench and check its JUnit result."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", nargs="*", choices=[*TARGETS, "all"])
    args = parser.parse_args()
    if not Path("/.dockerenv").exists():
        parser.error(
            "run in the frost image: ./scripts/frost.py run python3 tests/net10g/run.py"
        )
    selected = args.targets or ["all"]
    if "all" in selected:
        selected = list(TARGETS)
    directory = Path(__file__).resolve().parent
    for target in selected:
        top, module, frame_limit = TARGETS[target]
        result = directory / "sim_build" / target / "results.xml"
        command = [
            "make",
            f"TOPLEVEL={top}",
            f"COCOTB_TEST_MODULES={module}",
            f"SIM_BUILD=sim_build/{target}",
            f"COCOTB_RESULTS_FILE={result}",
        ]
        subprocess.run([*command, "clean"], cwd=directory, check=True)
        result.parent.mkdir(parents=True, exist_ok=True)
        result.unlink(missing_ok=True)
        environment = os.environ.copy()
        if frame_limit is not None:
            environment["NET10G_MAX_FRAME_BYTES"] = str(frame_limit)
        subprocess.run(command, cwd=directory, env=environment, check=True)
        tree = ET.parse(result)
        cases = tree.findall(".//testcase")
        if not cases or tree.findall(".//failure") or tree.findall(".//error"):
            raise SystemExit(f"{target}: missing tests or failing cocotb result")
        print(f"{target}: {len(cases)} tests passed", flush=True)


if __name__ == "__main__":
    main()

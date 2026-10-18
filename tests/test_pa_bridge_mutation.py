# Copyright (c) 2026 John Goodacre.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Prove that the wide AXI offset assertions reject 32-bit truncation."""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "hw/rtl/lib/cache/line_port_axi_bridge.sv"
PROOF = ROOT / "formal/line_port_axi_bridge.sby"


@pytest.mark.formal
@pytest.mark.parametrize(
    ("channel", "assertion"),
    (("aw_addr_q", "p_aw_full_offset"), ("ar_addr_q", "p_ar_full_offset")),
)
def test_wide_bridge_rejects_32_bit_offset(
    tmp_path: Path, channel: str, assertion: str
) -> None:
    """A high-address request must expose truncation on either AXI channel."""
    if shutil.which("sby") is None:
        pytest.skip("SymbiYosys is unavailable")

    source = BRIDGE.read_text(encoding="utf-8")
    original = f"{channel}  <= AXI_ADDR_WIDTH'(i_req_addr - BASE_ADDR);"
    truncated = f"{channel}  <= AXI_ADDR_WIDTH'(32'(i_req_addr - BASE_ADDR));"
    assert source.count(original) == 1, "bridge address assignment changed"

    formal_dir = tmp_path / "formal"
    bridge_dir = tmp_path / "hw/rtl/lib/cache"
    formal_dir.mkdir(parents=True)
    bridge_dir.mkdir(parents=True)
    (bridge_dir / BRIDGE.name).write_text(
        source.replace(original, truncated), encoding="utf-8"
    )
    (formal_dir / PROOF.name).write_text(
        PROOF.read_text(encoding="utf-8"), encoding="utf-8"
    )

    result = subprocess.run(
        ["sby", "-f", PROOF.name, "bmc_64g"],
        cwd=formal_dir,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    output = result.stdout + result.stderr
    logfile = formal_dir / "line_port_axi_bridge_bmc_64g/logfile.txt"
    if logfile.exists():
        output += logfile.read_text(encoding="utf-8")
    assert result.returncode != 0, "truncated address escaped the formal check"
    assert assertion in output, output[-4000:]

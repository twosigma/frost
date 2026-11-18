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
from collections import deque
from pathlib import Path

import pytest

from sby_config import stage_proof

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path("hw/rtl/lib/cache/line_port_axi_bridge.sv")
PROOF = ROOT / "formal/line_port_axi_bridge.sby"


@pytest.mark.formal
@pytest.mark.parametrize(
    ("channel", "assertion"),
    (("aw_addr_q", "p_aw_full_offset"), ("ar_addr_q", "p_ar_full_offset")),
)
def test_wide_bridge_rejects_32_bit_offset(
    tmp_path: Path, channel: str, assertion: str
) -> None:
    """The 64 GiB proof reports the affected channel's full-offset assertion."""
    if shutil.which("sby") is None:
        pytest.skip("SymbiYosys is unavailable")

    source = (ROOT / BRIDGE).read_text(encoding="utf-8")
    original = f"{channel}  <= AXI_ADDR_WIDTH'(i_req_addr - BASE_ADDR);"
    truncated = f"{channel}  <= AXI_ADDR_WIDTH'(32'(i_req_addr - BASE_ADDR));"
    assert source.count(original) == 1, "bridge address assignment changed"

    proof = stage_proof(PROOF, ROOT, tmp_path)
    (tmp_path / BRIDGE).write_text(
        source.replace(original, truncated), encoding="utf-8"
    )

    logfile = tmp_path / "sby.log"
    with logfile.open("w", encoding="utf-8") as log:
        result = subprocess.run(
            ["sby", "-f", proof.name, "bmc_64g"],
            cwd=proof.parent,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
    assert result.returncode != 0, "truncated address escaped the formal check"
    with logfile.open(encoding="utf-8") as log:
        output = "".join(deque(log, maxlen=40))
    assert "DONE (FAIL," in output, output
    assert f"failed assertion line_port_axi_bridge.{assertion} at " in output, output

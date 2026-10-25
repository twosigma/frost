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

"""Elaborate coherent endpoints without selecting them in the CPU hierarchy."""

import subprocess
from pathlib import Path

import pytest

from test_run_yosys import YosysRunner


@pytest.mark.synthesis
@pytest.mark.parametrize(
    "address,harts,fills",
    [(32, 1, 4), (32, 2, 4), (56, 2, 16), (32, 2, 30), (32, 1, 43)],
)
def test_endpoint_synthesis(address: int, harts: int, fills: int) -> None:
    """Synthesize the endpoints and reject unresolved modules and latches."""
    root = Path(__file__).resolve().parents[1]
    cache = root / "hw/rtl/lib/cache"
    sources = [
        "coherence_pkg.sv",
        "coherence_channel.sv",
        "coherence_request_endpoint.sv",
        "coherence_home_endpoint.sv",
        "coherence_put_endpoint.sv",
        "coherence_endpoints_test_harness.sv",
    ]
    top = "coherence_endpoints_test_harness"
    script = (
        f"read_verilog -sv -DSYNTHESIS -I{cache} "
        + " ".join(str(cache / source) for source in sources)
        + f"; chparam -set ADDR_WIDTH {address} -set NUM_HARTS {harts} "
        f"-set L2_NUM_MSHR {fills} {top}; hierarchy -check -top {top}; "
        f"synth -top {top} -run coarse; check -assert; "
        f"select -assert-none t:$dlatch* t:$adlatch*; cd {top}; eval -show o_layout"
    )
    result = subprocess.run(
        ["yosys", "-p", script], capture_output=True, text=True, timeout=120
    )
    assert result.returncode == 0, result.stdout + result.stderr
    completions = 11 * harts + 8
    puts = completions + fills
    count = puts + 2 * harts
    layout = (completions << 21) | (completions << 14) | (puts << 7) | count
    assert f"Eval result: \\o_layout = 28'{layout:028b}." in result.stdout


def test_production_excludes_coherent_endpoints() -> None:
    """Production elaboration has no coherent endpoint sources."""
    runner = YosysRunner(memory_images=False)
    sources = runner.parse_filelist(runner.filelist)
    assert not any(Path(source).name.startswith("coherence_") for source in sources)


@pytest.mark.synthesis
@pytest.mark.parametrize(
    "module,parameter,value",
    [
        ("coherence_request_endpoint", "SOURCE", 4),
        ("coherence_request_endpoint", "PORT_CLASS", 4),
        ("coherence_request_endpoint", "SLOT", 8),
        ("coherence_home_endpoint", "TID", 64),
        ("coherence_home_endpoint", "NUM_HARTS", 3),
        ("coherence_home_endpoint", "L2_NUM_MSHR", 64),
        ("coherence_home_endpoint", "ADDR_WIDTH", 31),
        ("coherence_put_endpoint", "HART", 2),
        ("coherence_put_endpoint", "SLOT", 2),
        ("coherence_channel", "WIDTH", 0),
    ],
)
def test_reject_endpoint_configuration(module: str, parameter: str, value: int) -> None:
    """Reject parameter truncation and invalid resource geometry during elaboration."""
    cache = Path(__file__).resolve().parents[1] / "hw/rtl/lib/cache"
    script = (
        f"read_verilog -sv -DSYNTHESIS -I{cache} {cache}/coherence_pkg.sv "
        f"{cache}/{module}.sv; chparam -set {parameter} {value} {module}; "
        f"hierarchy -check -top {module}"
    )
    result = subprocess.run(
        ["yosys", "-p", script], capture_output=True, text=True, timeout=30
    )
    assert result.returncode != 0
    assert "$fatal" in result.stdout + result.stderr

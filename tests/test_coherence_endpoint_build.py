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

"""Coherent endpoints have explicit layouts and legal resource geometry."""

import json
import subprocess
from pathlib import Path

import pytest

from test_run_yosys import YosysRunner


@pytest.mark.synthesis
@pytest.mark.parametrize(
    "address,harts,fills",
    [(32, 1, 4), (32, 2, 4), (56, 2, 16), (32, 2, 24), (32, 1, 38)],
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
    completions = 12 * harts + 12
    puts = completions + fills
    count = puts + 2 * harts
    layout = (completions << 21) | (completions << 14) | (puts << 7) | count
    assert f"Eval result: \\o_layout = 28'{layout:028b}." in result.stdout


def test_cluster_sources_are_available() -> None:
    """Resolve the coherent hart and home from the CPU filelist."""
    runner = YosysRunner(memory_images=False)
    sources = runner.parse_filelist(runner.filelist)
    names = {Path(source).name for source in sources}
    assert {
        "coherent_hart_cache.sv",
        "coherence_home.sv",
        "coherence_grant_select.sv",
        "coherence_read_owners.sv",
        "debug_store_mirror_hold.sv",
        "coherence_c_payload.sv",
        "coherent_atomic_select.sv",
        "coherent_rs_capacity.sv",
        "coherent_rs_issue2_selector.sv",
        "coherent_rs_payload_store.sv",
        "debug_dirty_next.sv",
        "coherent_debug_request_count.sv",
    } <= names
    assert all(Path(source).is_file() for source in sources)


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


@pytest.mark.synthesis
@pytest.mark.parametrize("cached,dma", [(1, 1), (1, 0), (0, 0)])
def test_cpu_cache_configuration(cached: int, dma: int) -> None:
    """The coherent CPU elaborates with optional caches and DMA ingress."""
    runner = YosysRunner()
    checks = "select -assert-any *load_queue*/w:*; "
    controls = (
        "*load_queue*/c:gen_coherent_capture_choices.u_prepare",
        "*load_queue*/c:gen_coherent_capture_choices.gen_take*.u_select",
        "*load_queue*/c:gen_coherent_capture_choices.u_clear",
        "*load_queue*/w:*gen_coherent_drain_choice*",
        "*load_queue*/w:*gen_coherent_head_choice*",
        "*load_queue*/w:gen_coherent_forward_gate.*",
        "*load_queue*/w:gen_coherent_replace_gate.*",
        "*load_queue*/w:gen_coherent_issue_gate.*",
    )
    for control in controls:
        checks += f"select -assert-any {control}; "
    if not cached:
        checks += "select -assert-none t:*coherence_home* t:*coherence_l1d*; "
    result = runner.run_synthesis(
        synth_command="synth -top cpu_top -run begin:begin; "
        + checks
        + "synth -top cpu_top -run coarse",
        top_module="cpu_top",
        parameters={
            "ENABLE_CACHED_TIER": cached,
            "ENABLE_COHERENCE": dma,
        },
    )
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.synthesis
def test_soc_cache_configuration() -> None:
    """The coherent SoC elaborates its selected debug storage and controls."""
    runner = YosysRunner()
    result = runner.run_synthesis(
        synth_command="synth -top soc_top -run coarse",
        top_module="soc_top",
    )
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.synthesis
@pytest.mark.parametrize("address,line", [(32, 64), (56, 32)])
def test_coherent_cache_geometry(address: int, line: int) -> None:
    """The coherent cache path supports wide addresses and both line sizes."""
    runner = YosysRunner()
    cache = runner.root_dir / "hw/rtl/lib/cache"
    sources = runner.parse_filelist(cache / "coherence_home.f")
    top = "coherence_cluster_test_harness"
    script = f"read_verilog -sv -DSYNTHESIS -I{cache} " + " ".join(sources)
    script += f"; chparam -set ADDR_WIDTH {address} -set LINE_BYTES {line} {top}; "
    script += f"hierarchy -check -top {top}; synth -top {top} -run coarse; "
    script += "check -assert; select -assert-none t:$dlatch* t:$adlatch*"
    result = subprocess.run(
        ["yosys", "-p", script],
        capture_output=True,
        text=True,
        timeout=180,
        cwd=runner.test_dir,
    )
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.synthesis
@pytest.mark.parametrize(
    "address,line,ways,ultra", [(32, 64, 4, 1), (56, 32, 4, 0), (32, 32, 1, 1)]
)
def test_home_array_geometry(address: int, line: int, ways: int, ultra: int) -> None:
    """Independent array ports elaborate both RAM forms and packed tag groups."""
    runner = YosysRunner(memory_images=False)
    cache = runner.root_dir / "hw/rtl/lib/cache"
    sources = runner.parse_filelist(cache / "coherence_home.f")
    top = "coherence_home_array"
    script = f"read_verilog -sv -DSYNTHESIS -I{cache} " + " ".join(sources)
    script += f"; chparam -set ADDR_WIDTH {address} -set LINE_BYTES {line} "
    script += f"-set CACHE_BYTES 1024 -set WAYS {ways} -set ULTRA {ultra} {top}; "
    script += f"hierarchy -check -top {top}; synth -top {top} -flatten -run coarse; "
    script += "opt; check -assert; select -assert-none t:$dlatch* t:$adlatch*"
    result = subprocess.run(
        ["yosys", "-p", script],
        capture_output=True,
        text=True,
        timeout=180,
        cwd=runner.test_dir,
    )
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.synthesis
@pytest.mark.parametrize("address,banks", [(32, 2), (48, 2), (49, 4), (56, 4)])
@pytest.mark.parametrize("ultra", [False, True])
def test_l1d_array_tag_geometry(
    address: int, banks: int, ultra: bool, tmp_path: Path
) -> None:
    """Elaborate the four-way L1D at the packed tag's 36-bit boundary."""
    lib = Path(__file__).resolve().parents[1] / "hw/rtl/lib"
    sources = [
        lib / "ram/sdp_block_ram.sv",
        lib / "ram/sdp_packed_tag_uram.sv",
        lib / "ram/sdp_ram_byte_en.sv",
        lib / "cache/coherence_array.sv",
    ]
    netlist = tmp_path / "array.json"
    top = "coherence_array"
    script = (
        "read_verilog -sv -DSYNTHESIS "
        + " ".join(map(str, sources))
        + f"; chparam -set ADDR_WIDTH {address} -set ULTRA {int(ultra)} "
        f"-set WAYS 4 -set HIT_PORT {int(not ultra)} {top}; hierarchy -check -top {top}; "
        f"proc; memory_collect; check -assert; write_json {netlist}"
    )
    result = subprocess.run(
        ["yosys", "-q", "-p", script], capture_output=True, text=True, timeout=90
    )
    assert result.returncode == 0, result.stdout + result.stderr
    modules = json.loads(netlist.read_text())["modules"]
    (array,) = (
        module
        for module in modules.values()
        if int(module["attributes"].get("top", "0"), 2)
    )
    cells = array["cells"]
    # Four 32-byte ways in 128 KiB use 10 set bits and 5 offset bits.
    # Each tag carries its address, two permission bits and a snapshot bit.
    entry_bits = address - 15 + 3
    tags = [cell for name, cell in cells.items() if name.startswith("gen_tag_")]
    copies = [
        cell for name, cell in cells.items() if name.startswith("gen_hit_port.gen_copy")
    ]
    assert len(tags) == (1 if ultra else 4)
    assert len(copies) == (0 if ultra else 4)
    for copy in copies:
        assert len(copy["connections"]["i_write_data"]) == entry_bits
        assert len(copy["connections"]["o_read_data"]) == entry_bits
    for tag in tags:
        assert len(tag["connections"]["i_write_data"]) == entry_bits
        words = 4 if ultra else 1
        assert len(tag["connections"]["o_read_data"]) == entry_bits * words
    if ultra:
        storage = modules[tags[0]["type"]]["cells"]
        physical = [name for name in storage if name.endswith(".memory")]
        assert len(physical) == banks

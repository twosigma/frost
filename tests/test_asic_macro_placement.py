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

"""Exercise the macro placement script with the configured SRAM inventory."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def test_nic_transmit_macro_fits_the_floorplan(tmp_path: Path) -> None:
    """Every configured macro fits, without overlap, and preserves the logic band."""
    inventory: list[tuple[str, str]] = []

    def add(pattern: str, macro: str, count: int) -> None:
        inventory.extend((pattern.format(i=i), macro) for i in range(count))

    add(
        "home.array.gen_single.data_array.gen_column[{i}].u_macro",
        "sram_1w1r_4096x64_m8",
        8,
    )
    add("home.array.gen_tag_ultra.gen_column[{i}].u_macro", "sram_1w1r_1024x18", 4)
    add("soc.data_memory.gen_row[{i}].u_macro", "sram_2rw_4096x64_m8", 4)
    add("l1d.array.gen_data_bank[{i}].u_macro", "sram_1w1r_1024x64_m8", 16)
    add("l1d.array.gen_tag_block.gen_way[{i}].u_macro", "sram_1w1r_1024x19", 4)
    add("l1d.array.gen_hit_port.gen_copy[{i}].u_macro", "sram_1w1r_1024x19", 4)
    add("l1i.gen_data_banks.bank[{i}].u_macro", "sram_1w1r_128x64_m8", 16)
    add("nic.u_rx_fifo.storage.gen_row[{i}].u_macro", "sram_1w1r_512x68", 16)
    add("nic.u_tx_fifo.storage.gen_row[{i}].u_macro", "sram_1w1r_512x68", 1)
    add("nic.mac_rx.g_memory_lane[{i}].u_macro", "sram_1w1r_4096x8", 8)
    add("nic.mac_tx.u_frame_memory.gen_row[{i}].u_macro", "sram_1w1r_4096x64_m8", 1)
    add("btb_payload_ram[{i}].u_macro", "sram_1w1r_256x36", 3)
    for parity in ("even", "odd"):
        for bank, bits in (("cold", 28), ("frontend_hot", 4), ("compressed", 4)):
            add(
                f"instruction_memory.u_{parity}_{bank}.gen_row[{{i}}].u_macro",
                f"sram_1w1r_8192x{bits}",
                2,
            )
    core_match = re.search(
        r"export CORE_AREA = ([0-9. ]+)", (ROOT / "asic/config.mk").read_text()
    )
    assert core_match
    x0, y0, x1, y1 = (round(float(v) * 1000) for v in core_match[1].split())
    script = f"""
namespace eval ord {{proc get_db_block {{}} {{return block}}}}
proc block {{method}} {{
    switch $method {{
        getDefUnits {{return 1000}}
        getCoreArea {{return core}}
        getInsts {{return $::instances}}
    }}
}}
proc core {{method}} {{
    switch $method {{
        xMin {{return {x0}}}
        yMin {{return {y0}}}
        dx {{return {x1 - x0}}}
        dy {{return {y1 - y0}}}
    }}
}}
proc master {{id method}} {{
    switch $method {{
        isBlock {{return 1}}
        getWidth {{return $::width($id)}}
        getHeight {{return $::height($id)}}
    }}
}}
proc instance {{id method args}} {{
    switch $method {{
        getMaster {{return master$id}}
        getName {{return $::name($id)}}
        setLocation {{set ::location($id) $args}}
        setPlacementStatus {{}}
        setOrient {{}}
    }}
}}
set instances {{}}
"""
    sizes = []
    for index, (name, macro) in enumerate(inventory):
        lef = (ROOT / f"asic/sram/macros/{macro}/{macro}.lef").read_text()
        match = re.search(r"SIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)", lef)
        assert match
        width, height = (round(float(v) * 1000) for v in match.groups())
        sizes.append((width, height))
        script += f"""
set name({index}) {{{name}}}
set width({index}) {width}
set height({index}) {height}
interp alias {{}} master{index} {{}} master {index}
interp alias {{}} inst{index} {{}} instance {index}
lappend instances inst{index}
"""
    script += f"source {{{ROOT / 'asic/macro_placement.tcl'}}}\n"
    script += 'foreach id [array names location] {puts "LOCATION $id $location($id)"}\n'
    harness = tmp_path / "placement.tcl"
    harness.write_text(script)
    result = subprocess.run(
        ["tclsh", str(harness)], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stdout + result.stderr
    boxes = []
    for line in result.stdout.splitlines():
        if line.startswith("LOCATION "):
            _, ident, x, y = line.split()
            width, height = sizes[int(ident)]
            boxes.append((int(x), int(y), int(x) + width, int(y) + height))
    assert len(boxes) == len(inventory)
    for index, (left, bottom, right, top) in enumerate(boxes):
        for other_left, other_bottom, other_right, other_top in boxes[index + 1 :]:
            assert (
                right <= other_left
                or other_right <= left
                or top <= other_bottom
                or other_top <= bottom
            )


def test_home_array_sram_macro_names_match_floorplan(tmp_path: Path) -> None:
    """Elaborated home-array SRAM macros match the floorplan's selectors and slice order."""
    yosys = shutil.which("yosys")
    if yosys is None:
        pytest.skip("yosys is missing")
    libs = sorted((ROOT / "asic/sram/macros").glob("*/*.lib"))
    sources = (
        ROOT / "asic/sram/frost_sram_1w1r.sv",
        ROOT / "hw/rtl/lib/ram/sdp_dist_ram.sv",
        ROOT / "hw/rtl/lib/ram/sdp_block_ram.sv",
        ROOT / "hw/rtl/lib/ram/sdp_packed_tag_uram.sv",
        ROOT / "hw/rtl/lib/ram/sdp_ram_byte_en.sv",
        ROOT / "hw/rtl/lib/cache/coherence_pkg.sv",
        ROOT / "hw/rtl/lib/cache/coherence_home_array.sv",
    )
    netlist = tmp_path / "home_array.json"
    commands = [f"read_liberty -lib {lib}" for lib in libs]
    commands += [
        f"read_verilog -sv -DSYNTHESIS -DFROST_SRAM_MACROS {source}"
        for source in sources
    ]
    commands += [
        "hierarchy -check -top coherence_home_array "
        "-chparam CACHE_BYTES 262144 -chparam WAYS 4 -chparam LINE_BYTES 64 "
        "-chparam ULTRA 1",
        "proc; opt_expr; opt_clean; flatten; opt_clean",
        f"write_json {netlist}",
    ]
    result = subprocess.run(
        [yosys, "-Q", "-T", "-p", "; ".join(commands)],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    cells = json.loads(netlist.read_text())["modules"]["coherence_home_array"]["cells"]
    prefix = "cpu.cluster_memory.gen_coherent_tier.home.array."
    macros = sorted(
        (prefix + name, cell["type"])
        for name, cell in cells.items()
        if cell["type"].startswith("sram_")
    )
    assert [macro for _, macro in macros].count("sram_1w1r_4096x64_m8") == 8
    assert [macro for _, macro in macros].count("sram_1w1r_1024x18") == 4

    placement_source = (ROOT / "asic/macro_placement.tcl").read_text()
    selectors = placement_source[: placement_source.index("set frost_core_width")]
    tcl = (
        "namespace eval ord {proc get_db_block {} {return block}}\n"
        "proc block {method} {\n"
        "  switch $method {\n"
        "    getDefUnits {return 1000}\n"
        "    getCoreArea {return core}\n"
        "    getInsts {return $::instances}\n"
        "  }\n"
        "}\n"
        "proc master {id method} { return 1 }\n"
        "proc instance {id method} {\n"
        "  switch $method {\n"
        "    getMaster {return master$id}\n"
        "    getName {return $::name($id)}\n"
        "  }\n"
        "}\n"
        "set instances {}\n"
    )
    for index, (name, _) in enumerate(macros):
        tcl += (
            f"set name({index}) {{{name}}}\n"
            f"interp alias {{}} master{index} {{}} master {index}\n"
            f"interp alias {{}} inst{index} {{}} instance {index}\n"
            f"lappend instances inst{index}\n"
        )
    tcl += (
        selectors
        + 'puts "DATA [llength $frost_l2_data]"\n'
        + 'foreach inst $frost_l2_data {puts "SLICE [frost_index $inst gen_column] [$inst getName]"}\n'
        + 'puts "TAGS [llength $frost_l2_tags]"\n'
    )
    harness = tmp_path / "home_macros.tcl"
    harness.write_text(tcl)
    tcl_run = subprocess.run(
        ["tclsh", str(harness)], capture_output=True, text=True, check=False
    )
    assert tcl_run.returncode == 0, tcl_run.stdout + tcl_run.stderr
    lines = tcl_run.stdout.splitlines()
    assert "DATA 8" in lines, tcl_run.stdout
    assert "TAGS 4" in lines, tcl_run.stdout
    slices = [int(line.split()[1]) for line in lines if line.startswith("SLICE ")]
    assert slices == list(range(8))

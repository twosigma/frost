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

"""Tests for asic/openram.py and the SRAM macros' views in asic/sram."""

import re
from pathlib import Path

import pytest

import asic.openram as openram

SRAM_DIRECTORY = openram.SRAM_DIRECTORY


def _verilog_ports(model: str) -> set[str]:
    """Return the port names in the header of an OpenRAM Verilog model."""
    header = model[model.index("module ") : model.index(");")]
    header = re.sub(r"`ifdef USE_POWER_PINS.*?`endif", "", header, flags=re.S)
    header = re.sub(r"//[^\n]*", "", header)
    return set(re.findall(r"\b(\w+)\b", header.split("(", 1)[1]))


def _expected_ports(macro: openram.Macro) -> set[str]:
    """Return the ports OpenRAM gives a macro: port 0 writes, port 1 reads."""
    ports = {"clk0", "csb0", "addr0", "din0", "clk1", "csb1", "addr1", "dout1"}
    if macro.ports == "2rw":
        ports |= {"web0", "dout0", "web1", "din1"}
    if macro.write_size is not None:
        ports |= {"wmask0", "wmask1"} if macro.ports == "2rw" else {"wmask0"}
    return ports


def test_openram_and_its_packages_are_pinned() -> None:
    """A run fetches one OpenRAM commit and installs hashed wheels only."""
    assert re.fullmatch(r"[0-9a-f]{40}", openram.OPENRAM_COMMIT)
    requirements = [
        line
        for line in openram.REQUIREMENTS.read_text().splitlines()
        if line and not line.startswith("#")
    ]
    assert requirements
    for line in requirements:
        assert re.fullmatch(r"[\w-]+==[\w.]+ --hash=sha256:[0-9a-f]{64}", line), line


def test_macro_names_and_ports() -> None:
    """Names encode ports, words, bits, and write mask; ports map to OpenRAM's."""
    macro = openram.Macro("1w1r", 4096, 64, 8)
    assert macro.name == "sram_1w1r_4096x64_m8"
    assert macro.port_counts == (0, 1, 1)
    assert openram.Macro("2rw", 512, 20, None).name == "sram_2rw_512x20"
    assert openram.Macro("2rw", 512, 20, None).port_counts == (2, 0, 0)
    with pytest.raises(ValueError, match="unknown port"):
        openram.Macro("3rw", 512, 20, None).port_counts  # noqa: B018
    assert len({macro.name for macro in openram.MACROS}) == len(openram.MACROS)


def test_openram_config_builds_the_macro_at_the_platform_corner(
    tmp_path: Path,
) -> None:
    """The configuration names the macro, its ports, and Nangate45's corner."""
    config = openram.openram_config(openram.Macro("1w1r", 4096, 64, 8), tmp_path)
    settings = dict(line.split(" = ", 1) for line in config.splitlines())
    assert settings["word_size"] == "64"
    assert settings["num_words"] == "4096"
    assert settings["write_size"] == "8"
    assert (settings["num_rw_ports"], settings["num_w_ports"]) == ("0", "1")
    assert settings["num_r_ports"] == "1"
    assert settings["tech_name"] == '"freepdk45"'
    assert settings["supply_voltages"] == "[1.1]"
    # Tables wide enough for the read data to drive a buffer and a wire.
    assert settings["load_scales"] == "[4, 32, 256]"
    assert settings["slew_scales"] == "[1, 10, 100]"
    assert settings["route_supplies"] == "True"
    assert settings["output_name"] == '"sram_1w1r_4096x64_m8"'
    assert settings["output_path"] == f'"{tmp_path}"'
    config = openram.openram_config(openram.Macro("1w1r", 512, 20, None), tmp_path)
    assert "write_size" not in config


def test_simulation_model_is_quiet_and_fits_the_core_clock() -> None:
    """The model edits are exact: each parameter changes once, or nothing does."""
    model = (
        "module m(clk0);\n"
        "  parameter DELAY = 3 ;\n"
        "  parameter VERBOSE = 1 ; //Set to 0 to only display warnings\n"
        "  parameter T_HOLD = 1 ; //Delay to hold dout value after posedge.\n"
        "  always @(posedge clk1)\n"
        "  begin\n"
        "    if (!csb0 && !csb1 && (addr0 == addr1))\n"
        '         $display($time," WARNING: Writing and reading addr0=%b and '
        'addr1=%b simultaneously!",addr0,addr1);\n'
        "  end\n"
        "endmodule\n"
    )
    edited = openram.simulation_model(model)
    assert "`timescale 1ns / 1ps\n" in edited
    assert "parameter DELAY = 0.5 ;" in edited
    assert "parameter VERBOSE = 0 ;" in edited
    assert "parameter T_HOLD = 0.1 ;" in edited
    assert "if (VERBOSE && !csb0 && !csb1 && (addr0 == addr1))" in edited
    with pytest.raises(ValueError, match="DELAY"):
        openram.simulation_model(model.replace("DELAY = 3", "DELAY = 4"))
    with pytest.raises(ValueError, match="collision warning"):
        openram.simulation_model(model.replace("WARNING", "NOTE"))


def test_lef_shapes_widen_to_the_manufacturing_grid() -> None:
    """Off-grid edges, the outline's too, move outward by 2.5 nm; others stay."""
    lef = (
        "   SIZE 248.615 BY 143.4825 ;\n"
        "   PIN din0[0]\n"
        "         RECT  28.3625 0.0 28.5025 0.14 ;\n"
        "   OBS\n"
        "      RECT  0.14 0.14 167.455 237.07 ;\n"
        "      RECT  0.0025 1.0 2.0 3.9975 ;\n"
    )
    assert openram.on_manufacturing_grid(lef) == (
        "   SIZE 248.615 BY 143.485 ;\n"
        "   PIN din0[0]\n"
        "         RECT  28.36 0.0 28.505 0.14 ;\n"
        "   OBS\n"
        "      RECT  0.14 0.14 167.455 237.07 ;\n"
        "      RECT  0.0 1.0 2.0 4.0 ;\n"
    )
    with pytest.raises(ValueError, match="LEF coordinate"):
        openram.on_manufacturing_grid("   RECT  1.00001 0.0 2.0 2.0 ;\n")


@pytest.mark.parametrize("macro", openram.MACROS, ids=lambda macro: macro.name)
def test_committed_views_describe_the_macro(macro: openram.Macro) -> None:
    """Each macro has its LEF, Liberty, and Verilog views, for that macro."""
    views = openram.view_paths(macro)
    assert sorted(views["lef"].parent.iterdir()) == sorted(views.values())

    lef = views["lef"].read_text()
    assert re.search(rf"^MACRO {macro.name}$", lef, re.M)
    assert re.search(r"^\s+SIZE [\d.]+ BY [\d.]+ ;$", lef, re.M)
    # Every shape is on Nangate45's 5 nm manufacturing grid.
    assert openram.on_manufacturing_grid(lef) == lef
    # The power grid straps the supply ring (asic/sram_power.tcl).
    for supply in ("vdd", "gnd"):
        pin = re.search(rf"PIN {supply}\n(.*?)END {supply}", lef, re.S)
        assert pin is not None and "LAYER metal4" in pin[1]

    lib = views["lib"].read_text()
    assert f"cell ({macro.name})" in lib
    assert "voltage : 1.1 ;" in lib
    assert re.search(rf"address_width : {(macro.words - 1).bit_length()};", lib)
    assert f"word_width : {macro.bits};" in lib

    model = views["v"].read_text()
    assert f"module {macro.name}(" in model
    assert _verilog_ports(model) == _expected_ports(macro)
    # The generator's edits (simulation_model) are all in place.
    assert model.startswith("// Generated by asic/openram.py")
    for setting in ("DELAY = 0.5", "VERBOSE = 0", "T_HOLD = 0.1"):
        assert f"  parameter {setting} ;" in model
    warnings = model.count('$display($time," WARNING: Writing and reading')
    assert (
        warnings
        == model.count("if (VERBOSE && !csb")
        == (2 if macro.ports == "2rw" else 1)
    )


def test_every_macro_directory_is_a_generated_macro() -> None:
    """The flow reads every directory in asic/sram/macros; each is a macro."""
    assert sorted(path.name for path in openram.MACRO_DIRECTORY.iterdir()) == sorted(
        macro.name for macro in openram.MACROS
    )


def test_sram_modules_tile_onto_every_macro() -> None:
    """frost_sram_1w1r and frost_sram_2rw know exactly the generated macros."""
    sources = {
        name: (SRAM_DIRECTORY / f"{name}.sv").read_text()
        for name in ("frost_sram_1w1r", "frost_sram_2rw")
    }
    instantiated = {
        name: set(re.findall(r"^\s+(sram_\w+) u_macro \(", source, re.M))
        for name, source in sources.items()
    }
    assert instantiated["frost_sram_1w1r"] == {
        macro.name for macro in openram.MACROS if macro.ports == "1w1r"
    }
    assert instantiated["frost_sram_2rw"] == {
        macro.name for macro in openram.MACROS if macro.ports == "2rw"
    }
    # The 1W1R module's fits() calls give each macro's address bits, data
    # bits, and write-mask bits, in the order the generator lists them.
    fits = re.findall(r"fits\((\d+), (\d+), (\d+)\)", sources["frost_sram_1w1r"])
    assert [tuple(map(int, call)) for call in fits] == [
        ((macro.words - 1).bit_length(), macro.bits, macro.write_size or 0)
        for macro in openram.MACROS
        if macro.ports == "1w1r"
    ]


def test_gds_allow_empty_covers_every_macro() -> None:
    """The final GDS may leave every macro's cell empty, and nothing else."""
    config = (openram.REPOSITORY_ROOT / "asic" / "config.mk").read_text()
    match = re.search(r"^export GDS_ALLOW_EMPTY = (\S+)$", config, re.M)
    assert match is not None
    for macro in openram.MACROS:
        assert re.fullmatch(match[1], macro.name)
    assert not re.fullmatch(match[1], "NAND2_X1")


def test_selected_macros_by_name() -> None:
    """An empty list selects every macro; an unknown name is an error."""
    assert openram.selected_macros([]) == list(openram.MACROS)
    name = openram.MACROS[0].name
    assert openram.selected_macros([name]) == [openram.MACROS[0]]
    with pytest.raises(ValueError, match="unknown macros: sram_x"):
        openram.selected_macros(["sram_x"])

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

"""Tests for asic/orfs.py, which runs the OpenROAD flow in its pinned image."""

import json
import math
import os
import re
import subprocess
from pathlib import Path

import pytest

import asic.orfs as orfs

ASIC_DIRECTORY = orfs.REPOSITORY_ROOT / "asic"


def test_orfs_image_is_pinned_by_digest() -> None:
    """The flow runs one exact image, whatever the tag later points to."""
    assert re.fullmatch(r"openroad/orfs:[\w.-]+@sha256:[0-9a-f]{64}", orfs.ORFS_IMAGE)


def test_orfs_runs_as_host_user_with_checkout_mounted() -> None:
    """ORFS writes only into asic/build, as the invoking user."""
    command = orfs.orfs_command(["NUM_CORES=4", "finish"], uid=1234, gid=5678)

    assert command[:4] == ["docker", "run", "--rm", "--init"]
    assert ["--user", "1234:5678"] == command[4:6]
    assert ["--volume", f"{orfs.REPOSITORY_ROOT}:/workspace"] == command[8:10]
    assert ["--workdir", "/workspace/asic/build"] == command[10:12]
    assert command[12] == orfs.ORFS_IMAGE
    assert command[13:] == [
        "make",
        "--file=/OpenROAD-flow-scripts/flow/Makefile",
        "DESIGN_CONFIG=/workspace/asic/config.mk",
        "WORK_HOME=/workspace/asic/build",
        "NUM_CORES=4",
        "finish",
    ]


def test_make_goals_resume_with_unconditional_stage_targets() -> None:
    """A resumed run reruns each stage from --from through --target."""
    assert orfs.make_goals(None, "grt") == ["grt"]
    assert orfs.make_goals("place", "grt") == ["do-place", "do-cts", "do-grt"]
    # Detailed routing resumes from the global routing database.
    assert orfs.make_goals("route", "finish") == [
        "do-5_2_route",
        "do-5_3_fillcell",
        "do-5_route",
        "do-5_route.sdc",
        "do-finish",
        "do-gds",
    ]
    with pytest.raises(ValueError, match="comes after"):
        orfs.make_goals("route", "cts")


def test_clock_period_reaches_make_only_when_given() -> None:
    """The flow's make sees FROST_CORE_CLOCK_PERIOD only for --clock-period."""
    assert orfs.make_variables(4, None) == ["NUM_CORES=4"]
    assert orfs.make_variables(16, 1.6) == [
        "NUM_CORES=16",
        "FROST_CORE_CLOCK_PERIOD=1.6",
    ]
    # Every digit the SDC files keep reaches the flow.
    assert orfs.make_variables(1, 100.0001)[1] == "FROST_CORE_CLOCK_PERIOD=100.0001"
    assert orfs.format_period(3.0) == "3"


def _write_synthesized_build(build: Path, core_period: str) -> None:
    """Leave a build whose synthesis wrote its constraints with core_period."""
    results = build / orfs.FLOW_SUBDIRECTORY.format(kind="results")
    results.mkdir(parents=True)
    (results / "1_synth.sdc").write_text(
        "current_design cpu_and_mem\n"
        f"create_clock -name core_clk -period {core_period} [get_ports {{i_clk}}]\n"
    )
    (build / "sources.mk").write_text("export VERILOG_FILES =\n")


def test_run_refuses_a_build_with_another_clock_period(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Make does not track the period, so a changed period needs a new build.

    Resuming takes the period from the build, so --from rejects the option.
    """
    _write_synthesized_build(tmp_path, "3.1030")
    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path)

    assert orfs.built_clock_period(tmp_path) == pytest.approx(3.103)
    assert orfs.main(["run", "--clock-period", "1.6"]) == 2
    assert "with a 3.103 ns core clock" in capsys.readouterr().err
    assert orfs.main(["run", "--from", "cts", "--clock-period", "1.6"]) == 2
    assert "cannot be combined with --from" in capsys.readouterr().err

    monkeypatch.setattr(orfs, "BUILD_DIRECTORY", tmp_path / "other")
    _write_synthesized_build(tmp_path / "other", "1.6000")
    assert orfs.main(["run"]) == 2
    assert "delete it to run the flow at 3.103 ns" in capsys.readouterr().err


def test_clock_period_option_rejects_periods_the_sdc_refuses(
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The option rejects what the SDC would: four decimals keep div4 exact."""
    for period in (
        "0",
        "0.0",
        "-2",
        "nan",
        "inf",
        "fast",
        "1e-3",
        "08",
        "1.60004",
        "100",
        "1" * 400,
    ):
        with pytest.raises(SystemExit):
            orfs.main(["run", "--clock-period", period])
        assert "expected a positive period in ns" in capsys.readouterr().err


def test_sources_makefile_is_independent_of_the_mount_point(tmp_path: Path) -> None:
    """Sources are relative to the checkout; the converted NIC is in the build."""
    rtl = orfs.REPOSITORY_ROOT / "hw" / "rtl"
    converted = str(tmp_path / "nic.v")
    makefile = orfs.sources_makefile(
        [converted, str(rtl / "frost.sv"), str(rtl / "lib" / "cdc" / "cdc_sync.sv")],
        converted,
    )

    assert makefile.splitlines()[1:] == [
        "export VERILOG_FILES = \\",
        "  $(WORK_HOME)/src/nic.v \\",
        "  $(FROST_ROOT)/hw/rtl/frost.sv \\",
        "  $(FROST_ROOT)/hw/rtl/lib/cdc/cdc_sync.sv",
    ]
    with pytest.raises(ValueError, match="outside the repository"):
        orfs.sources_makefile([converted, "/elsewhere/top.sv"], converted)


# Stand-ins for the OpenSTA commands that asic/constraint.sdc calls. Each
# command prints what it constrains: "clock <name> <period>", "<input|output>
# <port> <clock> <delay>", or "false_path <hold|all> <ports>".
SDC_HARNESS = r"""
set clocks [dict create]
proc option {arguments name} {
    return [lindex $arguments [expr {[lsearch -exact $arguments $name] + 1}]]
}
proc create_clock {args} {
    dict set ::clocks [option $args -name] [option $args -period]
    puts "clock [option $args -name] [option $args -period] [lindex $args end]"
}
proc get_ports {patterns} {return $patterns}
proc get_clocks {names} {return $names}
proc set_clock_groups {args} {}
proc all_inputs {args} {return $::inputs}
proc all_outputs {} {return $::outputs}
proc get_full_name {object} {return $object}
proc get_property {clock property} {return [dict get $::clocks $clock]}
proc set_input_delay {delay args} {
    puts "input [lindex $args end] [option $args -clock] $delay"
}
proc set_output_delay {delay args} {
    puts "output [lindex $args end] [option $args -clock] $delay"
}
proc set_false_path {args} {
    set checks [expr {"-hold" in $args ? "hold" : "all"}]
    puts "false_path $checks [join [option $args -from] { }]"
}
set inputs {
    i_rst i_instr_mem_en i_instr_mem_wrdata[3] i_ddr_axi_rdata[7]
    i_nic_rx_raw_data[5] i_nic_rx_signal_ok i_jtag_tms i_jtag_tdi i_jtag_trst_n
    i_nic_tx_clk_ok i_nic_rx_clk_ok i_nic_phy_status[2]
}
set outputs {o_uart_wr_en o_ddr_axi_araddr[4] o_nic_tx_raw_data[9] o_jtag_tdo}
source [lindex $argv 0]
"""
# The clock that times each of the harness's ports.
PORT_CLOCKS = {
    "i_rst": "core_clk",
    "i_instr_mem_en": "core_clk_div4",
    "i_instr_mem_wrdata[3]": "core_clk_div4",
    "i_ddr_axi_rdata[7]": "core_clk",
    "i_nic_rx_raw_data[5]": "nic_rx_clk",
    "i_nic_rx_signal_ok": "nic_rx_clk",
    "i_jtag_tms": "jtag_tck",
    "i_jtag_tdi": "jtag_tck",
    "i_jtag_trst_n": "core_clk",
    "i_nic_tx_clk_ok": "core_clk",
    "i_nic_rx_clk_ok": "core_clk",
    "i_nic_phy_status[2]": "core_clk",
    "o_uart_wr_en": "core_clk",
    "o_ddr_axi_araddr[4]": "core_clk",
    "o_nic_tx_raw_data[9]": "nic_tx_clk",
    "o_jtag_tdo": "jtag_tck",
}


def _evaluate_sdc(
    tmp_path: Path, core_period: str | None = None
) -> subprocess.CompletedProcess[str]:
    """Run asic/constraint.sdc in tclsh with FROST_CORE_CLOCK_PERIOD set or not."""
    harness = tmp_path / "harness.tcl"
    harness.write_text(SDC_HARNESS)
    environment = {
        name: value
        for name, value in os.environ.items()
        if name != orfs.CLOCK_PERIOD_VARIABLE
    }
    if core_period is not None:
        environment[orfs.CLOCK_PERIOD_VARIABLE] = core_period
    return subprocess.run(
        ["tclsh", str(harness), str(ASIC_DIRECTORY / "constraint.sdc")],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env=environment,
    )


def _sdc_constraints(
    tmp_path: Path, core_period: str | None = None
) -> tuple[dict[str, float], dict[str, tuple[str, float]]]:
    """Return the clock periods and the ports' (clock, delay) that the SDC sets."""
    result = _evaluate_sdc(tmp_path, core_period)
    assert result.returncode == 0, result.stderr
    periods: dict[str, float] = {}
    delays: dict[str, tuple[str, float]] = {}
    for line in result.stdout.splitlines():
        kind, *fields = line.split()
        if kind == "clock":
            periods[fields[0]] = float(fields[1])
        elif kind in ("input", "output"):
            delays[fields[0]] = (fields[1], float(fields[2]))
    return periods, delays


def test_clock_periods_match_the_rtl_and_board(tmp_path: Path) -> None:
    """The core clock is CLK_FREQ_HZ; the NIC clocks are the Ethernet reference."""
    rtl = (orfs.REPOSITORY_ROOT / "hw/rtl/cpu_and_mem/cpu_and_mem.sv").read_text()
    match = re.search(r"parameter int unsigned CLK_FREQ_HZ = (\d+)", rtl)
    assert match is not None
    core_ns = 1e9 / int(match[1])
    periods, _ = _sdc_constraints(tmp_path)

    assert periods["core_clk"] == pytest.approx(core_ns, abs=5e-4)
    assert periods["core_clk"] == orfs.default_clock_period()
    assert periods["core_clk_div4"] == pytest.approx(4 * periods["core_clk"])
    for nic_clock in ("nic_tx_clk", "nic_rx_clk"):
        assert periods[nic_clock] == pytest.approx(1e3 / 161.1328125, abs=5e-4)


@pytest.mark.parametrize("core_period", [None, "1.6", "2.25", "1.6001"])
def test_core_clock_period_sets_the_core_clocks_and_their_ports(
    tmp_path: Path, core_period: str | None
) -> None:
    """The quarter-rate clock and every port's delay follow the core period.

    Ports take a fifth of their clock's period; the NIC and JTAG clocks stay.
    """
    periods, delays = _sdc_constraints(tmp_path, core_period)
    core = orfs.default_clock_period() if core_period is None else float(core_period)

    assert periods["core_clk"] == pytest.approx(core)
    assert periods["core_clk_div4"] == pytest.approx(4 * core)
    assert periods["nic_tx_clk"] == periods["nic_rx_clk"] == pytest.approx(6.206)
    assert periods["jtag_tck"] == pytest.approx(100.0)
    assert {port: clock for port, (clock, _) in delays.items()} == PORT_CLOCKS
    for port, (clock, delay) in delays.items():
        assert delay == pytest.approx(periods[clock] / 5), port


def test_only_the_core_clocks_inputs_skip_hold_checks(tmp_path: Path) -> None:
    """The asynchronous levels are untimed; other core clock inputs skip hold.

    Inputs on the NIC's and the JTAG clocks keep their hold checks.
    """
    result = _evaluate_sdc(tmp_path)
    assert result.returncode == 0, result.stderr
    false_paths: dict[str, set[str]] = {"hold": set(), "all": set()}
    for line in result.stdout.splitlines():
        kind, *fields = line.split()
        if kind == "false_path":
            false_paths[fields[0]].update(fields[1:])

    assert false_paths["all"] == {
        "i_jtag_trst_n",
        "i_nic_tx_clk_ok",
        "i_nic_rx_clk_ok",
        "i_nic_phy_status*",
    }
    assert false_paths["hold"] == {
        port
        for port, clock in PORT_CLOCKS.items()
        if port.startswith("i_") and clock in ("core_clk", "core_clk_div4")
    }


def test_core_clock_period_must_be_a_positive_number(tmp_path: Path) -> None:
    """A malformed period stops the flow instead of creating a broken clock."""
    for period in ("fast", "0", "0.0000", "-1.6", "1e-3", "08", "1.60004", "100"):
        result = _evaluate_sdc(tmp_path, period)
        assert result.returncode != 0
        assert "FROST_CORE_CLOCK_PERIOD must be a positive number" in result.stderr
    # An empty variable means the default.
    assert _sdc_constraints(tmp_path, "")[0]["core_clk"] == orfs.default_clock_period()


def test_abc_reads_the_default_core_period() -> None:
    """ORFS takes ABC's delay target from the SDC's first period, as sed reads it.

    Its rule is the first line that starts with "set clk_period" or holds
    "-period" and a word; comments count too.
    """
    for line in (ASIC_DIRECTORY / "constraint.sdc").read_text().splitlines():
        match = re.match(r"set\s+clk_period\s+(\S+)", line) or re.search(
            r"-period\s+(\S+)", line
        )
        if match:
            assert float(match[1]) == orfs.default_clock_period()
            break
    else:
        pytest.fail("ORFS finds no clock period in asic/constraint.sdc")


def test_quarter_rate_clock_is_related_to_the_core_clock(tmp_path: Path) -> None:
    """Crossings between the core clocks are timed; the other clocks are apart.

    The debug slice writer's dc_fifo needs the core clock and its quarter-rate
    programming clock timed together, as the X3 constraints do.
    """
    sdc = (ASIC_DIRECTORY / "constraint.sdc").read_text()
    groups = [
        set(members.split())
        for members in re.findall(r"-group \[get_clocks \{?([^\]}]+)\}?\]", sdc)
    ]

    assert sorted(map(sorted, groups)) == [
        ["core_clk", "core_clk_div4"],
        ["jtag_tck"],
        ["nic_rx_clk"],
        ["nic_tx_clk"],
    ]
    assert set().union(*groups) == set(_sdc_constraints(tmp_path)[0])


def test_mocked_memories_come_from_the_synthesis_log(tmp_path: Path) -> None:
    """The summary lists shrunk memories, largest first, with their dimensions."""
    log = tmp_path / "1_2_yosys.log"
    log.write_text(
        "Memory top/small has dimensions 32 x 64 = 2048\n"
        "Memory top/tags has dimensions 4096 x 17 = 69632\n"
        "Shrunk memory top/tags from 4096 rows to 1\n"
        "Memory top/data has dimensions 65536 x 256 = 16777216\n"
        "Shrunk memory top/data from 65536 rows to 1\n"
    )

    assert orfs.mocked_memories(log) == [
        ("top/data", 65536, 256),
        ("top/tags", 4096, 17),
    ]
    assert orfs.mocked_memories(tmp_path / "missing.log") == []


def test_sram_macros_come_from_the_synthesis_statistics(tmp_path: Path) -> None:
    """The summary counts each macro over the whole design."""
    statistics = tmp_path / "synth_stat.txt"
    statistics.write_text(
        "=== cpu_and_mem ===\n"
        "        2   1.27E+06        2   1.27E+06   sram_1w1r_4096x64_m8\n"
        "=== design hierarchy ===\n"
        "       68   4.32E+07       64   4.07E+07   sram_1w1r_4096x64_m8\n"
        "        2 1.31E+05        2 1.31E+05   sram_1w1r_4096x3\n"
        "   271588 5.06E+05   187232 3.49E+05   MUX2_X1\n"
    )

    assert orfs.sram_macros(statistics) == [
        ("sram_1w1r_4096x64_m8", 68),
        ("sram_1w1r_4096x3", 2),
    ]
    assert orfs.sram_macros(tmp_path / "missing.txt") == []


def test_macro_size_reads_the_lef() -> None:
    """The summary takes each macro's size from its committed LEF."""
    assert orfs.macro_size("sram_1w1r_4096x64_m8") == (751.9, 845.13)
    assert orfs.macro_size("sram_missing") is None


def test_summary_reports_a_partial_build(tmp_path: Path) -> None:
    """A run that stopped after synthesis still summarizes what it has."""
    logs = tmp_path / orfs.FLOW_SUBDIRECTORY.format(kind="logs")
    logs.mkdir(parents=True)
    (logs / "1_synth.json").write_text(
        json.dumps(
            {
                "synth__design__instance__count__stdcell": 1234567,
                "synth__design__instance__area__stdcell": 2345678.9,
            }
        )
    )

    summary = orfs.summary_markdown(tmp_path, "Total 42 1024")

    assert "| Standard cells | 1,234,567 | - |" in summary
    assert "| Standard-cell area (um^2) | 2,345,679 | - |" in summary
    assert "The final report has not run." in summary
    assert "Total 42 1024" in summary
    assert "Core clock period" not in summary

    _write_synthesized_build(tmp_path, "1.6000")
    assert "Core clock period: 1.6 ns." in orfs.summary_markdown(tmp_path, "")

    # A resumed build has only the stage databases it was given.
    results = tmp_path / orfs.FLOW_SUBDIRECTORY.format(kind="results")
    (results / "1_synth.sdc").rename(results / "5_1_grt.sdc")
    (results / "1_2_yosys.sdc").write_text(
        "create_clock -name core_clk -period $clk_period [get_ports i_clk]\n"
    )
    assert orfs.built_clock_period(tmp_path) == pytest.approx(1.6)


def test_blocks_follow_both_hierarchy_separators() -> None:
    """Blocks are the first three scopes, whether Yosys or OpenROAD named them."""
    assert (
        orfs.block("cpu_inst.u_tomasulo.u_rob/u_bank.g_banks[0].ram[0][7]$_DFFE_PP_")
        == "cpu_inst.u_tomasulo.u_rob"
    )
    assert orfs.block("cpu_inst.if_stage_inst.ras_q[63]$_DFF_P_") == (
        "cpu_inst.if_stage_inst"
    )
    assert orfs.block("data_memory.memory[0][23]$_DFFE_PP_") == "data_memory"
    assert orfs.block("data_memory_address_registered[25]$_DFF_P_") == "top"
    assert orfs.block("o_nic_tx_raw_data[42]", {"o_nic_tx_raw_data[42]"}) == "ports"
    assert orfs.port_names(
        "set_input_delay 0.32 -clock [get_clocks {core_clk}] -add_delay "
        "[get_ports {i_ddr_axi_bid[0]}]\nset_false_path -from [list "
        "[get_ports {i_jtag_trst_n}]]\n"
    ) == {"i_ddr_axi_bid[0]", "i_jtag_trst_n"}


def test_mocked_rows_are_single_row_memories_from_the_log() -> None:
    """Row 0 of a mocked memory counts; a same-named array with more rows does not."""
    points = {
        "data_memory.memory[0][23]$_DFFE_PP_",
        "cpu_inst.u_rob/u_alloc.g_banks[1].u_bank.ram[0][5]$_DFFE_PP_",
        "cpu_inst.u_fetch.u_side.memory[0]$_DFFE_PP_",
        "cpu_inst.u_fifo.memory[0][3]$_DFFE_PP_",
        "cpu_inst.u_fifo.memory[1][3]$_DFFE_PP_",
        "cpu_inst.u_rob/u_alloc.g_banks[1].u_bank.ram_q[2]$_DFF_P_",
        "i_rst",
    }
    memories = [
        "cpu_and_mem/data_memory.memory",
        "$paramod\\reorder_buffer/u_alloc.g_banks[1].u_bank.ram",
        "$paramod$0123\\imem_sideband_scalar_bank/memory",
    ]

    assert orfs.mocked_rows(points, memories) == {
        "data_memory.memory[0][23]$_DFFE_PP_",
        "cpu_inst.u_rob/u_alloc.g_banks[1].u_bank.ram[0][5]$_DFFE_PP_",
        "cpu_inst.u_fetch.u_side.memory[0]$_DFFE_PP_",
    }


def _path(slack: float, start: str, end: str, **fields: object) -> orfs.TimingPath:
    """Return a core clock path with the given slack and points."""
    values: dict[str, object] = {
        "capture": "core_clk",
        "launch": "core_clk",
        "slack": slack,
        "launched": 0.4,
        "arrival": 2.0,
        "required": 2.0 + slack,
        "skew": 0.0,
        "cells": 20,
        "buffers": 4,
        "startpoint": start,
        "endpoint": end,
    }
    values.update(fields)
    return orfs.TimingPath(**values)  # type: ignore[arg-type]


def test_path_report_ranks_blocks_and_families(tmp_path: Path) -> None:
    """The report gives each clock's slack, the core fmax, and the worst families."""
    table = tmp_path / "5_1_grt_paths.tsv"
    table.write_text(
        "capture\tlaunch\tslack\tlaunched\tarrival\trequired\tskew\tcells\t"
        "buffers\tstartpoint\tendpoint\n"
        "core_clk\tcore_clk\t-0.8\t0.5\t2.9\t2.1\t0.01\t31\t9\t"
        "cpu_inst.u_rob.head_q$_DFF_P_\tcpu_inst.u_int_rs.src_q[3]$_DFF_P_\n"
        "core_clk\tcore_clk\t-3.2e-05\t0.5\t2.1\t2.1\t0.01\t12\t2\t"
        "cpu_inst.u_lq.c_q$_DFF_P_\tcpu_inst.u_lq.d_q$_DFF_P_\n"
    )
    paths = orfs.read_paths(table) + [
        _path(
            -0.75, "cpu_inst.u_rob.tail_q$_DFF_P_", "cpu_inst.u_int_rs.src_q[4]$_DFF_P_"
        ),
        # An input with its I/O delay is worse than any register path.
        _path(
            -1.2,
            "i_instr_mem_en",
            "data_memory.memory[0][1]$_DFFE_PP_",
            launch="core_clk_div4",
        ),
        _path(0.2, "cpu_inst.u_lq.a_q$_DFF_P_", "cpu_inst.u_lq.b_q$_DFF_P_"),
        _path(
            -0.9,
            "gen.l2.q$_DFF_P_",
            "gen.l1.q$_DFF_P_",
            capture="core_clk_div4",
            launch="core_clk_div4",
        ),
        _path(
            1.0,
            "u_dtm.a$_DFF_P_",
            "u_dtm.b$_DFF_P_",
            capture="jtag_tck",
            launch="jtag_tck",
        ),
    ]
    register_paths = [
        paths[0],
        _path(
            -0.4,
            "imem.row[0][3]$_DFFE_PP_",
            "imem.side_q[3]$_DFF_P_",
            launch="core_clk_div4",
        ),
        paths[5],
    ]
    periods = {"core_clk": 1.6, "core_clk_div4": 6.4, "jtag_tck": 100.0}

    report = orfs.paths_markdown(
        "grt",
        paths,
        register_paths,
        periods,
        {"data_memory.memory[0][1]$_DFFE_PP_", "imem.row[0][3]$_DFFE_PP_"},
        {"i_instr_mem_en"},
    )

    # The worst register path needs 1.6 + 0.8 ns. The -0.9 ns path between
    # quarter-rate registers has four core periods, 6.4 + 0.9 ns.
    assert orfs.path_fmax(register_paths[0], 1.6) == pytest.approx(1e3 / 2.4)
    assert orfs.path_fmax(register_paths[2], 1.6) == pytest.approx(4e3 / 7.3)
    # Skew can leave a path no delay to fit, and so no limit.
    assert orfs.path_fmax(_path(1.7, "a$_DFF_P_", "b$_DFF_P_"), 1.6) == math.inf
    assert "Core clock fmax estimate: 416.7 MHz, from the paths between" in report
    assert "| core_clk | 1.6 | 5 | 4 | -1.200 | -2.8 |" in report
    assert "| core_clk_div4 | 6.4 | 1 | 1 | -0.900 | -0.9 |" in report
    assert (
        "| core_clk_div4 | core_clk | 1 | -0.400 | 500.0 | `imem.row[0][3]$_DFFE_PP_` "
        "| `imem.side_q[3]$_DFF_P_` | reads a mocked memory |" in report
    )
    assert "| `cpu_inst.u_int_rs` | 2 | 2 | 0 | -0.800 |" in report
    assert (
        "| `cpu_inst.u_rob` | `cpu_inst.u_int_rs` | 2 | -0.800 | 31 (9) |  |" in report
    )
    assert (
        "| `ports` | `data_memory` | 1 | -1.200 | 20 (4) | from core_clk_div4; "
        "writes a mocked memory; from an input |" in report
    )
    # Blocks and families come worst first.
    assert report.index("| `data_memory` | 1 |") < report.index(
        "`cpu_inst.u_int_rs` | 2"
    )


def test_path_notes_name_the_sram_macros() -> None:
    """A path from or to an SRAM macro (asic/sram's u_macro) says so."""
    macro = "l2.data_array.u_sram.gen_macros.gen_row[3].gen_column[5].gen_macro.u_macro"
    note = orfs._path_note(_path(0.1, macro, "l2.rd_pipe[0][7]$_DFF_P_"), set(), set())
    assert note == "from an SRAM macro"
    note = orfs._path_note(
        _path(0.1, "l2.raddr$_DFF_P_", macro.replace(".", "/")), set(), set()
    )
    assert note == "to an SRAM macro"
    assert (
        orfs._path_note(_path(0.1, "u_macro_q$_DFF_P_", "a$_DFF_P_"), set(), set())
        == ""
    )

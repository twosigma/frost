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
import re
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


def _sdc_periods() -> dict[str, float]:
    """Return the period of each clock that asic/constraint.sdc creates."""
    sdc = (ASIC_DIRECTORY / "constraint.sdc").read_text()
    return {
        name: float(period)
        for name, period in re.findall(
            r"^create_clock -name (\S+) -period (\S+)", sdc, re.MULTILINE
        )
    }


def test_clock_periods_match_the_rtl_and_board() -> None:
    """The core clock is CLK_FREQ_HZ; the NIC clocks are the Ethernet reference."""
    rtl = (orfs.REPOSITORY_ROOT / "hw/rtl/cpu_and_mem/cpu_and_mem.sv").read_text()
    match = re.search(r"parameter int unsigned CLK_FREQ_HZ = (\d+)", rtl)
    assert match is not None
    core_ns = 1e9 / int(match[1])
    periods = _sdc_periods()

    assert periods["core_clk"] == pytest.approx(core_ns, abs=5e-4)
    assert periods["core_clk_div4"] == pytest.approx(4 * periods["core_clk"])
    for nic_clock in ("nic_tx_clk", "nic_rx_clk"):
        assert periods[nic_clock] == pytest.approx(1e3 / 161.1328125, abs=5e-4)


def test_quarter_rate_clock_is_related_to_the_core_clock() -> None:
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
    assert set().union(*groups) == set(_sdc_periods())


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

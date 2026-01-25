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

"""Extract key timing and utilization metrics from Vivado reports.

Creates a sanitized summary file suitable for git tracking, without
machine-specific paths or hostnames. Also updates the main README.md
with utilization tables for all FPGA targets.
"""

import re
import sys
from pathlib import Path
from typing import Any

# Board metadata for README tables
BOARD_INFO = {
    "x3": {
        "name": "Alveo X3522PV",
        "family": "Virtex UltraScale+",
        "part": "xcvu35p",
    },
    "genesys2": {
        "name": "Digilent Genesys2",
        "family": "Kintex-7",
        "part": "xc7k325t",
    },
    "nexys_a7": {
        "name": "Digilent Nexys A7",
        "family": "Artix-7",
        "part": "xc7a100t",
    },
}

# Markers for README section
README_UTIL_START = "<!-- FPGA_UTILIZATION_START -->"
README_UTIL_END = "<!-- FPGA_UTILIZATION_END -->"


def extract_timing_summary(timing_rpt: str) -> dict[str, Any]:
    """Extract WNS, TNS, WHS, THS from timing report."""
    result: dict[str, Any] = {}

    # Find the Design Timing Summary table
    # Format: WNS(ns) TNS(ns) TNS Failing Endpoints ...
    pattern = r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+\s*-+.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)"
    match = re.search(pattern, timing_rpt)
    if match:
        result["wns_ns"] = float(match.group(1))
        result["tns_ns"] = float(match.group(2))
        result["tns_failing_endpoints"] = int(match.group(3))
        result["tns_total_endpoints"] = int(match.group(4))
        result["whs_ns"] = float(match.group(5))
        result["ths_ns"] = float(match.group(6))
        result["ths_failing_endpoints"] = int(match.group(7))
        result["ths_total_endpoints"] = int(match.group(8))

    # Only check setup timing (WNS)
    result["timing_met"] = result.get("wns_ns", float("-inf")) >= 0

    return result


def extract_clock_info(timing_rpt: str) -> dict[str, Any]:
    """Extract clock frequencies from timing report."""
    clocks: dict[str, Any] = {}

    # Find clock_from_mmcm period
    match = re.search(
        r"clock_from_mmcm\s+\{[\d. ]+\}\s+([\d.]+)\s+([\d.]+)", timing_rpt
    )
    if match:
        clocks["main_clock_period_ns"] = float(match.group(1))
        clocks["main_clock_freq_mhz"] = float(match.group(2))

    return clocks


def extract_worst_path(timing_rpt: str) -> dict[str, Any]:
    """Extract worst path details from timing report."""
    result: dict[str, Any] = {}

    # Find the clock_from_mmcm section (main clock, not debug)
    # Match both MET and VIOLATED slack - we want the worst path regardless
    mmcm_section = re.search(
        r"From Clock:\s+clock_from_mmcm\s*\n\s*To Clock:\s+clock_from_mmcm.*?"
        r"Max Delay Paths\s*\n-+\s*\n"
        r"Slack \((?:MET|VIOLATED)\) :\s+([-\d.]+)ns.*?"
        r"Source:\s+(\S+).*?"
        r"Destination:\s+(\S+).*?"
        r"Data Path Delay:\s+([\d.]+)ns\s+\(logic ([\d.]+)ns.*?route ([\d.]+)ns.*?"
        r"Logic Levels:\s+(\d+)",
        timing_rpt,
        re.DOTALL,
    )

    if mmcm_section:
        result["slack_ns"] = float(mmcm_section.group(1))
        result["source"] = mmcm_section.group(2)
        result["destination"] = mmcm_section.group(3)
        result["data_path_delay_ns"] = float(mmcm_section.group(4))
        result["logic_delay_ns"] = float(mmcm_section.group(5))
        result["route_delay_ns"] = float(mmcm_section.group(6))
        result["logic_levels"] = int(mmcm_section.group(7))

    return result


def extract_utilization(util_rpt: str) -> dict[str, Any]:
    """Extract resource utilization from utilization report."""
    result: dict[str, Any] = {}

    def parse_util_line(pattern: str) -> tuple[Any, Any, Any] | None:
        """Parse a utilization table row and return (used, available, percent)."""
        match = re.search(pattern, util_rpt)
        if match:
            used_str = match.group(1)
            avail_str = match.group(2)
            pct_str = match.group(3).replace("<", "")
            # Handle float vs int for used value
            used = float(used_str) if "." in used_str else int(used_str)
            avail = int(avail_str)
            pct = float(pct_str)
            return used, avail, pct
        return None

    # Table format: | Site Type | Used | Fixed | Prohibited | Available | Util% |

    # CLB LUTs (UltraScale+) or Slice LUTs (7-series)
    if parsed := parse_util_line(
        r"\|\s*(?:CLB|Slice) LUTs\*?\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["luts_used"], result["luts_available"], result["luts_percent"] = parsed

    # LUT as Logic
    if parsed := parse_util_line(
        r"\|\s*LUT as Logic\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        (
            result["lut_logic_used"],
            result["lut_logic_available"],
            result["lut_logic_percent"],
        ) = parsed

    # LUT as Memory (includes distributed RAM + shift registers)
    if parsed := parse_util_line(
        r"\|\s*LUT as Memory\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        (
            result["lut_mem_used"],
            result["lut_mem_available"],
            result["lut_mem_percent"],
        ) = parsed

    # LUT as Distributed RAM (subset of LUT as Memory)
    match = re.search(r"\|\s*LUT as Distributed RAM\s*\|\s*(\d+)", util_rpt)
    if match:
        result["lut_distram_used"] = int(match.group(1))

    # LUT as Shift Register (subset of LUT as Memory)
    match = re.search(r"\|\s*LUT as Shift Register\s*\|\s*(\d+)", util_rpt)
    if match:
        result["lut_srl_used"] = int(match.group(1))

    # CLB Registers (UltraScale+) or Slice Registers (7-series)
    if parsed := parse_util_line(
        r"\|\s*(?:CLB|Slice) Registers\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        (
            result["registers_used"],
            result["registers_available"],
            result["registers_percent"],
        ) = parsed

    # CARRY8 (UltraScale+) or CARRY4 (7-series)
    if parsed := parse_util_line(
        r"\|\s*CARRY[48]\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["carry_used"], result["carry_available"], result["carry_percent"] = (
            parsed
        )

    # F7 Muxes
    if parsed := parse_util_line(
        r"\|\s*F7 Muxes\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["f7mux_used"], result["f7mux_available"], result["f7mux_percent"] = (
            parsed
        )

    # F8 Muxes
    if parsed := parse_util_line(
        r"\|\s*F8 Muxes\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["f8mux_used"], result["f8mux_available"], result["f8mux_percent"] = (
            parsed
        )

    # Block RAM
    if parsed := parse_util_line(
        r"\|\s*Block RAM Tile\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["bram_used"], result["bram_available"], result["bram_percent"] = parsed

    # URAM (UltraScale+ only)
    if parsed := parse_util_line(
        r"\|\s*URAM\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["uram_used"], result["uram_available"], result["uram_percent"] = parsed

    # DSPs
    if parsed := parse_util_line(
        r"\|\s*DSPs\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["dsps_used"], result["dsps_available"], result["dsps_percent"] = parsed

    # Bonded IOB
    if parsed := parse_util_line(
        r"\|\s*Bonded IOB\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["io_used"], result["io_available"], result["io_percent"] = parsed

    # MMCM (UltraScale+: MMCM, 7-series: MMCME2_ADV)
    if parsed := parse_util_line(
        r"\|\s*(?:MMCM|MMCME2_ADV)\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["mmcm_used"], result["mmcm_available"], result["mmcm_percent"] = parsed

    # PLL (UltraScale+: PLL, 7-series: PLLE2_ADV)
    if parsed := parse_util_line(
        r"\|\s*(?:PLL|PLLE2_ADV)\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)"
    ):
        result["pll_used"], result["pll_available"], result["pll_percent"] = parsed

    return result


def fmt(value: Any, fmt_spec: str = ".3f") -> str:
    """Format a value with the given format spec, or return 'N/A' if missing."""
    if value is None or value == "N/A":
        return "N/A"
    return f"{value:{fmt_spec}}"


def format_summary(
    board: str, timing: dict, clocks: dict, worst_path: dict, util: dict
) -> str:
    """Format the extracted data as a markdown summary."""
    lines = [
        f"# FROST FPGA Build Summary: {board}",
        "",
        "## Timing",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Clock Frequency | {fmt(clocks.get('main_clock_freq_mhz'))} MHz |",
        f"| Clock Period | {fmt(clocks.get('main_clock_period_ns'))} ns |",
        f"| WNS (Setup) | {fmt(timing.get('wns_ns'))} ns |",
        f"| TNS (Setup) | {fmt(timing.get('tns_ns'))} ns ({timing.get('tns_failing_endpoints', 'N/A')} failing) |",
        f"| WHS (Hold) | {fmt(timing.get('whs_ns'))} ns |",
        f"| THS (Hold) | {fmt(timing.get('ths_ns'))} ns ({timing.get('ths_failing_endpoints', 'N/A')} failing) |",
        f"| Timing Met | {'Yes' if timing.get('timing_met') else 'No'} |",
        "",
        "## Worst Setup Path",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Slack | {fmt(worst_path.get('slack_ns'))} ns |",
        f"| Data Path Delay | {fmt(worst_path.get('data_path_delay_ns'))} ns |",
        f"| Logic Delay | {fmt(worst_path.get('logic_delay_ns'))} ns |",
        f"| Route Delay | {fmt(worst_path.get('route_delay_ns'))} ns |",
        f"| Logic Levels | {worst_path.get('logic_levels', 'N/A')} |",
        "",
        "### Path Endpoints",
        "",
        f"- **Source**: `{worst_path.get('source', 'N/A')}`",
        f"- **Destination**: `{worst_path.get('destination', 'N/A')}`",
        "",
        "## Resource Utilization",
        "",
        "| Resource | Used | Available | Util% |",
        "|----------|------|-----------|-------|",
        f"| LUTs | {util.get('luts_used', 'N/A')} | {util.get('luts_available', 'N/A')} | {fmt(util.get('luts_percent'), '.2f')}% |",
        f"| Registers | {util.get('registers_used', 'N/A')} | {util.get('registers_available', 'N/A')} | {fmt(util.get('registers_percent'), '.2f')}% |",
        f"| Block RAM | {util.get('bram_used', 'N/A')} | {util.get('bram_available', 'N/A')} | {fmt(util.get('bram_percent'), '.2f')}% |",
        f"| DSPs | {util.get('dsps_used', 'N/A')} | {util.get('dsps_available', 'N/A')} | {fmt(util.get('dsps_percent'), '.2f')}% |",
        "",
    ]
    return "\n".join(lines)


def collect_all_board_utilization(script_dir: Path) -> dict[str, dict[str, Any]]:
    """Collect utilization data from all boards' summary files.

    Prefers final data, falls back through earlier stages if not available.
    Returns dict mapping board name to utilization dict.
    """
    all_util: dict[str, dict[str, Any]] = {}

    for board in BOARD_INFO:
        board_dir = script_dir / board

        # Prefer final, fall back through stages
        for stage in [
            "final",
            "post_route",
            "post_place_physopt",
            "post_place",
            "post_opt",
            "post_synth",
        ]:
            util_rpt_path = board_dir / "work" / f"{stage}_util.rpt"
            timing_rpt_path = board_dir / "work" / f"{stage}_timing.rpt"

            if util_rpt_path.exists():
                util_rpt = util_rpt_path.read_text()
                util = extract_utilization(util_rpt)

                # Also get clock frequency if timing report exists
                if timing_rpt_path.exists():
                    timing_rpt = timing_rpt_path.read_text()
                    clocks = extract_clock_info(timing_rpt)
                    util["clock_freq_mhz"] = clocks.get("main_clock_freq_mhz")
                    timing = extract_timing_summary(timing_rpt)
                    util["timing_met"] = timing.get("timing_met", False)

                util["stage"] = stage
                all_util[board] = util
                break

    return all_util


def format_readme_utilization_section(all_util: dict[str, dict[str, Any]]) -> str:
    """Format utilization data as markdown tables for the README."""
    lines = [
        README_UTIL_START,
        "",
        "### FPGA Resource Utilization",
        "",
    ]

    # Order: x3 first (flagship), then genesys2, then nexys_a7
    board_order = ["x3", "genesys2", "nexys_a7"]

    def fmt_used(val: Any) -> str:
        """Format a 'used' value with commas if integer, one decimal if float."""
        if val is None or val == "—":
            return "—"
        if isinstance(val, float):
            # Show as int if it's a whole number, otherwise one decimal
            return f"{int(val):,}" if val == int(val) else f"{val:,.1f}"
        return f"{val:,}"

    def fmt_avail(val: Any) -> str:
        """Format an 'available' value with commas."""
        if val is None or val == "—":
            return "—"
        return f"{val:,}"

    def fmt_pct(val: Any) -> str:
        """Format a percentage value."""
        if val is None:
            return "—"
        return f"{val:.1f}%"

    for board in board_order:
        if board not in all_util:
            continue

        util = all_util[board]
        info = BOARD_INFO[board]

        # Header with Fmax if available
        fmax = util.get("clock_freq_mhz")
        fmax_str = f" @ {fmax:.0f} MHz" if fmax else ""
        lines.extend(
            [
                f"**{info['name']}** ({info['family']}{fmax_str})",
                "",
                "| Resource | Used | Available | Util% |",
                "|----------|-----:|----------:|------:|",
            ]
        )

        # Define resources to display: (display_name, used_key, avail_key, pct_key)
        # Use exact Vivado terminology which varies by device family
        is_ultrascale = "UltraScale" in info["family"]
        lut_name = "CLB LUTs" if is_ultrascale else "Slice LUTs"
        reg_name = "CLB Registers" if is_ultrascale else "Slice Registers"
        carry_name = "CARRY8" if is_ultrascale else "CARRY4"

        resources = [
            (lut_name, "luts_used", "luts_available", "luts_percent"),
            (
                "  LUT as Logic",
                "lut_logic_used",
                "lut_logic_available",
                "lut_logic_percent",
            ),
            ("  LUT as Distributed RAM", "lut_distram_used", None, None),
            ("  LUT as Shift Register", "lut_srl_used", None, None),
            (reg_name, "registers_used", "registers_available", "registers_percent"),
            ("Block RAM Tile", "bram_used", "bram_available", "bram_percent"),
            ("URAM", "uram_used", "uram_available", "uram_percent"),
            ("DSPs", "dsps_used", "dsps_available", "dsps_percent"),
            (carry_name, "carry_used", "carry_available", "carry_percent"),
            ("F7 Muxes", "f7mux_used", "f7mux_available", "f7mux_percent"),
            ("F8 Muxes", "f8mux_used", "f8mux_available", "f8mux_percent"),
            ("Bonded IOB", "io_used", "io_available", "io_percent"),
            ("MMCM", "mmcm_used", "mmcm_available", "mmcm_percent"),
            ("PLL", "pll_used", "pll_available", "pll_percent"),
        ]

        for name, used_key, avail_key, pct_key in resources:
            used = util.get(used_key)
            # Skip resources that aren't present or are zero (except main categories)
            is_main = not name.startswith("  ")
            if used is None:
                continue
            if used == 0 and not is_main:
                continue

            avail = util.get(avail_key) if avail_key else None
            pct = util.get(pct_key) if pct_key else None

            # For sub-items without avail/pct, just show used
            if avail is None:
                lines.append(f"| {name} | {fmt_used(used)} | — | — |")
            else:
                lines.append(
                    f"| {name} | {fmt_used(used)} | {fmt_avail(avail)} | {fmt_pct(pct)} |"
                )

        lines.append("")

    lines.append(README_UTIL_END)
    return "\n".join(lines)


def update_readme_utilization(
    script_dir: Path, all_util: dict[str, dict[str, Any]]
) -> bool:
    """Update the main README.md with utilization tables.

    Returns True if README was updated, False otherwise.
    """
    # Find repo root (script is in fpga/build/)
    repo_root = script_dir.parent.parent
    readme_path = repo_root / "README.md"

    if not readme_path.exists():
        print(f"Warning: README.md not found at {readme_path}")
        return False

    readme_content = readme_path.read_text()
    new_section = format_readme_utilization_section(all_util)

    # Check if markers exist
    if README_UTIL_START in readme_content and README_UTIL_END in readme_content:
        # Replace existing section
        pattern = re.compile(
            re.escape(README_UTIL_START) + r".*?" + re.escape(README_UTIL_END),
            re.DOTALL,
        )
        new_content = pattern.sub(new_section, readme_content)
    else:
        # Insert after "## Supported FPGA Boards" section
        # Find the section and its table, insert after
        match = re.search(
            r"(## Supported FPGA Boards\s*\n\s*\|[^\n]+\|\s*\n\s*\|[-| ]+\|\s*\n(?:\s*\|[^\n]+\|\s*\n)+)",
            readme_content,
        )
        if match:
            insert_pos = match.end()
            new_content = (
                readme_content[:insert_pos]
                + "\n"
                + new_section
                + "\n"
                + readme_content[insert_pos:]
            )
        else:
            print("Warning: Could not find 'Supported FPGA Boards' section in README")
            return False

    readme_path.write_text(new_content)
    print("Updated README.md with utilization tables")
    return True


def main() -> None:
    """Extract timing and utilization summaries from Vivado reports."""
    if len(sys.argv) < 2:
        print("Usage: extract_timing_and_util_summary.py <board>")
        print("  board: x3, genesys2, or nexys_a7")
        sys.exit(1)

    board = sys.argv[1]
    if board not in ["x3", "genesys2", "nexys_a7"]:
        print(
            f"Error: Invalid board '{board}'. Must be 'x3', 'genesys2', or 'nexys_a7'"
        )
        sys.exit(1)

    script_dir = Path(__file__).parent.resolve()
    board_dir = script_dir / board
    work_dir = board_dir / "work"

    # Process all available build stages
    stages = [
        "post_synth",
        "post_opt",
        "post_place",
        "post_place_physopt",
        "post_route",
        "final",
    ]

    summaries_written = 0
    for stage in stages:
        timing_rpt_path = work_dir / f"{stage}_timing.rpt"
        util_rpt_path = work_dir / f"{stage}_util.rpt"

        if not timing_rpt_path.exists() or not util_rpt_path.exists():
            continue

        timing_rpt = timing_rpt_path.read_text()
        util_rpt = util_rpt_path.read_text()

        timing = extract_timing_summary(timing_rpt)
        clocks = extract_clock_info(timing_rpt)
        worst_path = extract_worst_path(timing_rpt)
        util = extract_utilization(util_rpt)

        # Write combined summary to board_dir (tracked in git)
        summary = format_summary(f"{board} ({stage})", timing, clocks, worst_path, util)
        summary_path = board_dir / f"SUMMARY_{stage}.md"
        summary_path.write_text(summary)

        print(f"Summary written to: {summary_path}")
        summaries_written += 1

    if summaries_written == 0:
        print("Error: No timing/utilization reports found")
        sys.exit(1)

    print(f"\nWrote {summaries_written} summary file(s)")

    # Update README.md with utilization tables from all boards
    all_util = collect_all_board_utilization(script_dir)
    if all_util:
        update_readme_utilization(script_dir, all_util)


if __name__ == "__main__":
    main()

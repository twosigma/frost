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

"""Run configured Yosys targets to check RTL portability."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any
from collections.abc import Callable, Sequence

import pytest

import ci_reuse


def _compile_hello_world(root_dir: Path) -> bool:
    """Compile hello_world under root_dir for synthesis; return True on success."""
    apps_dir = root_dir / "sw" / "apps"
    sys.path.insert(0, str(apps_dir))
    try:
        from compile_app import compile_app

        return compile_app("hello_world", verbose=True)
    finally:
        sys.path.pop(0)


def _is_generic_synth_command(synth_command: str) -> bool:
    """Return true for Yosys' generic synth command, with optional flags."""
    command = synth_command.strip()
    return command == "synth" or command.startswith("synth ")


def _xilinx_family(synth_command: str) -> str | None:
    """Return the synth_xilinx -family value, if this is a Xilinx command."""
    parts = synth_command.split()
    if not parts or parts[0] != "synth_xilinx":
        return None

    for i, part in enumerate(parts[:-1]):
        if part == "-family":
            return parts[i + 1]
    return None


def _hierarchy_command(synth_command: str) -> str:
    """Build hierarchy commands for the target.

    The UltraScale+ target (-family xcup) enables the X3 cached tier and its
    AXI export; the DDR model is simulation-only. Other targets use module
    defaults.

    Use chparam -set: in Yosys 0.69, hierarchy -chparam failed a duplicate-module
    assertion (modules_.count(module->name) == 0) when reprocessing the cache and
    walker hierarchy. Later checks must follow the top attribute because Yosys
    may specialize and rename the top.
    """
    family = _xilinx_family(synth_command)
    commands = []
    if family == "xcup":
        commands.append("chparam -set ENABLE_CACHED_TIER 1 platform_top")
        commands.append("chparam -set USE_BEHAVIORAL_DDR 0 platform_top")
    if os.environ.get("FROST_ASYNC_CPU_CLOCK") == "1":
        commands.append("chparam -set ASYNC_CPU_CLOCK 1 platform_top")
    commands.append("hierarchy -top platform_top")
    return "\n".join(commands)


def _get_timeout_seconds(synth_command: str) -> int:
    """Return the synthesis timeout in seconds.

    Defaults are 1800 for generic synth, 10800 for Xilinx, and 7200 for other
    targets. Overrides:
    FROST_YOSYS_GENERIC_TIMEOUT_SEC for generic synth,
    FROST_YOSYS_XILINX_TIMEOUT_SEC for Xilinx, and FROST_YOSYS_TIMEOUT_SEC for
    other targets. Generic synth also falls back to FROST_YOSYS_TIMEOUT_SEC.
    """
    default_generic_timeout = 1800
    default_timeout = 7200
    default_xilinx_timeout = 10800

    if _is_generic_synth_command(synth_command):
        env_name = "FROST_YOSYS_GENERIC_TIMEOUT_SEC"
        fallback = default_generic_timeout
    elif synth_command.startswith("synth_xilinx"):
        env_name = "FROST_YOSYS_XILINX_TIMEOUT_SEC"
        fallback = default_xilinx_timeout
    else:
        env_name = "FROST_YOSYS_TIMEOUT_SEC"
        fallback = default_timeout

    raw = os.environ.get(env_name)
    if raw is None and _is_generic_synth_command(synth_command):
        env_name = "FROST_YOSYS_TIMEOUT_SEC"
        raw = os.environ.get(env_name)
    if raw is None:
        return fallback

    try:
        timeout = int(raw)
        if timeout <= 0:
            raise ValueError
        return timeout
    except ValueError:
        print(f"Warning: invalid {env_name}={raw!r}; using {fallback}s")
        return fallback


def _synthesis_defines() -> str:
    """Use the RTL's one DDR capacity setting for synthesis too."""
    raw_capacity = os.environ.get("FROST_DDR_CAPACITY_LOG2_BYTES")
    if raw_capacity is None:
        return "-DSYNTHESIS"
    try:
        capacity = int(raw_capacity)
    except ValueError as exc:
        raise ValueError("DDR capacity must be an integer log2 byte count") from exc
    if not 30 <= capacity <= 37:
        raise ValueError("DDR capacity must select 1-128 GiB (log2 bytes 30-37)")
    return f"-DSYNTHESIS -DFROST_DDR_CAPACITY_LOG2_BYTES={capacity}"


# Synthesis targets. Pytest runs the generic target whole and the Xilinx
# target in the partitions of XILINX_PARTITIONS; the command line runs each
# target whole, or any other Yosys target, with:
# ./scripts/frost.py synthesis --target <name>
#
# Stop generic synthesis before mapping RAMs and wide arrays to flops, for
# runtime. The Xilinx target performs full synthesis.
GENERIC_SYNTH_COMMAND = "synth -top platform_top -run coarse"
SYNTHESIS_TARGETS = [
    ("generic", GENERIC_SYNTH_COMMAND, "Generic/ASIC (coarse synthesis)"),
    ("xilinx_ultrascale_plus", "synth_xilinx -family xcup", "Xilinx UltraScale+"),
]
XILINX_TARGET = "xilinx_ultrascale_plus"
PYTEST_SYNTHESIS_TARGETS = [t for t in SYNTHESIS_TARGETS if t[0] != XILINX_TARGET]

# The Xilinx target's partitions: (name, root module). synth_xilinx keeps the
# design hierarchy (it runs without -flatten) and maps each module on its
# own, so a module goes through the same steps in whichever partition
# synthesizes it. Its netlist can still differ: the top of a partition gets
# I/O buffers, global clock buffers follow the clock loads synthesis sees,
# ABC's choice of LUTs follows the names synthesis generates, and cleanup
# removes an instance of another partition's root whose outputs are all
# unused, with the logic that only feeds it. Each partition elaborates the
# whole design from platform_top with the full-chip parameters, then
# synthesizes its root and everything below it, with the roots of the other
# partitions as black boxes. A root other than platform_top must elaborate
# to exactly one module (one parameter set); every module below platform_top
# is then mapped by the partition of the nearest root above it.
# test_xilinx_partitions_cover_the_design checks these rules, and CI's
# synthesis jobs run the partitions apart from the other synthesis tests.
XILINX_TOP = "platform_top"
XILINX_PARTITIONS = [
    # platform_top, soc_top without the NIC, and cpu_top and frost_hart
    # without the cluster memory, the hart's caches and the core.
    ("top", XILINX_TOP),
    ("nic_engine", "nic_engine"),
    ("nic_mac", "nic_mac_10g"),
    # The coherence home, prefetch agent and CPU memory fabric.
    ("cluster_memory", "frost_cluster_memory"),
    # The hart's instruction cache and L1 data cache.
    ("hart_cache", "coherent_hart_cache"),
    # The core without its out-of-order back end.
    ("core", "cpu_ooo"),
    # The back end: reservation stations, reorder buffer, load and store
    # queues, register alias table and functional units.
    ("core_backend", "tomasulo_wrapper"),
]


def module_variants(module: str) -> str:
    r"""Return a Yosys selection of every elaborated form of a module.

    Elaboration keeps a module without parameters under its own name and
    names a specialized one $paramod\<module>\<parameters>, or
    $paramod$<hash>\<module> when the parameter list is long.
    """
    return f"{module} $paramod*\\{module} $paramod\\{module}\\*"


def partition_block(root: str, boxes: Sequence[str]) -> list[str]:
    """Return the Yosys commands that keep root's part of the design.

    They run after elaboration from XILINX_TOP and make the modules in boxes
    black boxes. A root other than XILINX_TOP must have exactly one
    elaborated form, which becomes the top; the hierarchy pass then removes
    every module that is not below it.
    """
    commands = []
    if boxes:
        commands.append("blackbox " + " ".join(module_variants(m) for m in boxes))
    if root != XILINX_TOP:
        commands += [
            f"select -assert-mod-count 1 {module_variants(root)}",
            "setattr -mod -unset top =A:top",
            f"setattr -mod -set top 1 {module_variants(root)}",
            "hierarchy",
        ]
    return commands


def xilinx_partition_commands(root: str) -> list[str]:
    """Return the commands of root's partition, other roots as black boxes."""
    roots = [r for _, r in XILINX_PARTITIONS]
    if root not in roots:
        raise ValueError(f"{root} is not the root of a Xilinx partition")
    return partition_block(root, [r for r in roots if r not in (root, XILINX_TOP)])


def _named_modules(selection: str) -> list[str]:
    """Return the modules of a selection of module_variants() forms, or []."""
    modules = selection.split()[::3]
    if " ".join(module_variants(m) for m in modules) != selection:
        return []
    return modules


def xilinx_partition_gaps(
    full_script: str, scripts: dict[str, str], modules: set[str]
) -> list[str]:
    """Return how the partition scripts fall short of the full-chip script.

    Each partition script must be the full-chip script with a
    partition_block() after elaboration from XILINX_TOP, and together the
    partitions must read every source the full-chip script reads. Exactly
    one partition keeps XILINX_TOP as its top, the roots are distinct
    modules of the sources, and a module is a black box only where it is
    the root of another partition, so that none is a black box everywhere.
    """

    def sources(script: str) -> set[str]:
        return {
            token
            for line in script.splitlines()
            if line.startswith("read_verilog ")
            for token in line.split()[1:]
            if not token.startswith(("-", "+/"))
        }

    gaps = []
    read = set().union(*map(sources, scripts.values()))
    gaps += [f"no partition reads {s}" for s in sorted(sources(full_script) - read)]
    elaborate = f"hierarchy -top {XILINX_TOP}"
    full = full_script.splitlines()
    top_command = "setattr -mod -set top 1 "
    parts: dict[str, tuple[str, list[str]]] = {}
    for name, script in scripts.items():
        lines = script.splitlines()
        if elaborate not in full or elaborate not in lines:
            gaps.append(f"{name} does not elaborate from {XILINX_TOP}")
            continue
        start = lines.index(elaborate) + 1
        end = start + len(lines) - len(full)
        block = lines[start:end]
        root, boxes = XILINX_TOP, []
        for line in block:
            if line.startswith(top_command):
                root = "".join(_named_modules(line[len(top_command) :])[:1])
            elif line.startswith("blackbox "):
                boxes = _named_modules(line[len("blackbox ") :])
        if lines[:start] + lines[end:] != full or block != partition_block(root, boxes):
            gaps.append(f"{name} runs commands other than its partition's")
            continue
        parts[name] = (root, boxes)
    roots = [root for root, _ in parts.values()]
    if roots.count(XILINX_TOP) != 1:
        gaps.append(f"exactly one partition must keep {XILINX_TOP} as its top")
    gaps += [
        f"more than one partition has the root {root}"
        for root in sorted({r for r in roots if roots.count(r) > 1})
    ]
    for name, (root, boxes) in parts.items():
        if root not in modules:
            gaps.append(f"the root {root!r} of {name} is not a module of the sources")
        gaps += [
            f"{name} makes {module} a black box, and no other partition has it "
            "as its root"
            for module in boxes
            if module == root or module not in roots
        ]
    return gaps


# Use the complete integration filelist even though platform_top is the
# synthesis top: its cached tier instantiates the NIC and MAC/PCS, whose
# dependencies are listed before cpu_and_mem.f in frost.f.
DESIGN_FILELISTS = {
    "frost": "hw/rtl/frost.f",
}


def synthesis_reuse_key(
    root: Path, test_id: str, script: str, temp_dir: Path, timeout: int, tools_id: str
) -> str:
    """Return a Yosys run's reuse key, failing the test if it cannot be computed."""
    try:
        return ci_reuse.synthesis_key(
            root, test_id, script, root / "tests", temp_dir, timeout, tools_id
        )
    except ci_reuse.ReuseKeyError as error:
        pytest.fail(f"Cannot compute the reuse key of {test_id}: {error}")


class YosysRunner:
    """Run Yosys synthesis on a design filelist."""

    def __init__(
        self, filelist_key: str = "frost", *, memory_images: bool = True
    ) -> None:
        """Initialize paths for a filelist_key from DESIGN_FILELISTS.

        memory_images compiles hello_world for the block RAMs' $readmemh
        images. The ASIC flow, whose memories read none, turns it off.
        """
        self.test_dir = Path(__file__).parent.resolve()
        self.root_dir = self.test_dir.parent
        self.filelist_key = filelist_key

        if filelist_key not in DESIGN_FILELISTS:
            raise ValueError(
                f"Unknown filelist key '{filelist_key}'. "
                f"Available: {list(DESIGN_FILELISTS.keys())}"
            )

        self.filelist = self.root_dir / DESIGN_FILELISTS[filelist_key]

        # Only designs with BRAM init (frost) need the sw.mem/sw64.mem symlinks.
        if filelist_key == "frost" and memory_images:
            self.setup_sw_mem()

    def setup_sw_mem(self) -> None:
        """Compile hello_world and set up sw.mem/sw64.mem symlinks for synthesis.

        The imem BRAM $readmemh's sw.mem (32-bit words) and the 64-bit data
        BRAM $readmemh's sw64.mem (dword tokens; see "Data-tier bus contract"
        in hw/rtl/README.md). Both come from the hello_world build.
        """
        if not _compile_hello_world(self.root_dir):
            raise RuntimeError("Failed to compile hello_world for synthesis")

        for mem_name in ("sw.mem", "sw64.mem"):
            mem_target = self.root_dir / "sw" / "apps" / "hello_world" / mem_name
            mem_link = self.test_dir / mem_name

            if mem_link.exists() or mem_link.is_symlink():
                mem_link.unlink()
            mem_link.symlink_to(mem_target)

    def parse_filelist(self, filelist_path: Path) -> list[str]:
        """Return Verilog paths in first-occurrence order, removing duplicates.

        Standalone filelists repeat package and RAM dependencies when nested in the
        full-chip list. Yosys rejects those as module redefinitions.
        """
        seen: set[str] = set()
        files: list[str] = []
        self.include_dirs: set[str] = set()

        self._parse_filelist_recursive(filelist_path, files, seen)
        return files

    def _parse_filelist_recursive(
        self, filelist_path: Path, files: list[str], seen: set[str]
    ) -> None:
        """Recursively parse filelist, deduplicating by resolved path."""
        with open(filelist_path) as f:
            for line in f:
                line = line.strip()

                if not line or line.startswith("#") or line.startswith("//"):
                    continue

                if line.startswith("+incdir+"):
                    self.include_dirs.add(
                        line[8:].replace("$(ROOT)", str(self.root_dir))
                    )
                elif line.startswith("-f "):
                    nested_filelist = line[3:].strip()
                    nested_filelist = nested_filelist.replace(
                        "$(ROOT)", str(self.root_dir)
                    )
                    self._parse_filelist_recursive(Path(nested_filelist), files, seen)
                else:
                    file_path = line.replace("$(ROOT)", str(self.root_dir))
                    resolved = str(Path(file_path).resolve())
                    if resolved not in seen:
                        seen.add(resolved)
                        files.append(file_path)

    def convert_nic_sources(
        self, verilog_files: list[str], directory: Path, defines: str, timeout: int
    ) -> list[str]:
        """Lower NIC/MAC SystemVerilog with the image's pinned sv2v frontend.

        Yosys read_verilog cannot parse the MAC's package imports/function
        returns or the NIC's packed multidimensional ports. Convert this
        subtree together so packages resolve; the CPU and library sources
        go through Yosys's own frontend. Lower always_comb to
        always @* ourselves: sv2v's explicit sensitivity list can contain a
        whole unpacked array, which read_verilog rejects. Keeping always_comb
        instead makes Yosys reject sv2v's otherwise unused loop-index latches.
        The ASIC flow (asic/orfs.py) prepares its sources the same way.
        """
        nic_directories = {
            self.root_dir / "hw/rtl/net10g",
            self.root_dir / "hw/rtl/peripherals/nic",
        }
        nic_sources = [
            source for source in verilog_files if Path(source).parent in nic_directories
        ]
        if not nic_sources:
            return verilog_files

        converted = directory / "nic.v"
        subprocess.run(
            [
                "sv2v",
                *defines.split(),
                "--exclude=Always",
                f"--write={converted}",
                *nic_sources,
                "+RTS",
                "-N2",
                "-M2G",
                "-RTS",
            ],
            check=True,
            text=True,
            timeout=timeout,
        )
        converted.write_text(
            re.sub(r"\balways_comb\b", "always @*", converted.read_text())
        )
        converted_sources = set(nic_sources)
        return [str(converted)] + [
            source for source in verilog_files if source not in converted_sources
        ]

    def run_synthesis(
        self,
        capture_output: bool = True,
        synth_command: str = "synth_xilinx",
        *,
        top_module: str = "platform_top",
        parameters: dict[str, int] | None = None,
        reuse_hook: Callable[[str, Path, int, bool], None] | None = None,
        after_hierarchy: Sequence[str] = (),
    ) -> subprocess.CompletedProcess[str]:
        """Run Yosys synthesis on the design.

        Args:
            capture_output: If True, capture stdout/stderr. If False, stream to console.
            synth_command: Yosys synthesis command (e.g., "synth", "synth_xilinx",
                          "synth_intel_alm", "synth_ice40").
            reuse_hook: Called with the Yosys script, the directory of the
                converted sources, the timeout and False before Yosys runs, and
                with True after it returns. It may skip the test before the run.
            after_hierarchy: Yosys commands to run after elaboration, such as
                xilinx_partition_commands().
        """
        if not self.filelist.exists():
            raise FileNotFoundError(f"Filelist not found: {self.filelist}")

        verilog_files = self.parse_filelist(self.filelist)

        if not verilog_files:
            raise ValueError("No Verilog files found in filelist")

        # Exclude simulation-only code. Enable Xilinx primitives only for
        # synth_xilinx targets.
        defines = _synthesis_defines()
        defines += "".join(f" -I{directory}" for directory in sorted(self.include_dirs))
        if synth_command.startswith("synth_xilinx"):
            defines += " -DFROST_XILINX_PRIMS"

        print(f"Parsing filelist: {self.filelist}")
        print(f"Using ROOT: {self.root_dir}")
        print(f"Found {len(verilog_files)} Verilog files")
        timeout_sec = _get_timeout_seconds(synth_command)
        print(f"Using timeout: {timeout_sec}s")

        with TemporaryDirectory(prefix="frost-yosys-") as temp_dir:
            verilog_files = self.convert_nic_sources(
                verilog_files, Path(temp_dir), defines, timeout_sec
            )
            yosys_script = []
            if synth_command.startswith("synth_xilinx"):
                # Load primitive ports before parameter elaboration. Loading
                # them only inside synth_xilinx can rederive a parent after
                # hierarchy has discarded its unspecialized child modules.
                yosys_script.append("read_verilog -lib +/xilinx/cells_sim.v")
            for vfile in verilog_files:
                yosys_script.append(f"read_verilog -sv {defines} {vfile}")

            if parameters:
                for parameter, value in parameters.items():
                    yosys_script.append(
                        f"chparam -set {parameter} {value} {top_module}"
                    )
            if top_module == "platform_top":
                yosys_script.append(_hierarchy_command(synth_command))
            else:
                yosys_script.append(f"hierarchy -top {top_module}")
            yosys_script.extend(after_hierarchy)
            # Preserve RX parser encoding to avoid expanding its symbolic
            # transitions into a table.
            yosys_script.append(
                'setattr -set fsm_encoding "none" *eth10g_mac_rx*/w:state'
            )
            if synth_command.startswith("synth_xilinx"):
                # Vivado implements a rom_style="distributed" ROM in LUT
                # logic. Yosys's UltraScale+ LUTRAM library cannot hold every
                # such ROM (fp_engine's registered op decode has no valid
                # mapping), so give it the equivalent style: logic.
                yosys_script.append(
                    'setattr -set rom_style "logic" a:rom_style=distributed'
                )
            yosys_script.append(synth_command)
            # Coarse generic synthesis does not reject unresolved modules on
            # its own. Check after synthesis so Xilinx primitive definitions
            # have been loaded too. Unused sv2v loop-index latches must be gone;
            # reject any surviving generic or mapped Xilinx latch cells.
            yosys_script.append("hierarchy -check")
            yosys_script.append(
                "select -assert-none t:$dlatch* t:$adlatch* t:$_DLATCH* t:LD*"
            )
            script_content = "\n".join(yosys_script)
            if reuse_hook is not None:
                reuse_hook(script_content, Path(temp_dir), timeout_sec, False)

            result = subprocess.run(
                ["yosys", "-p", script_content],
                capture_output=capture_output,
                text=True,
                cwd=self.test_dir,
                timeout=timeout_sec,
            )
            if reuse_hook is not None:
                reuse_hook(script_content, Path(temp_dir), timeout_sec, True)

        return result

    def check_for_errors(
        self, result: subprocess.CompletedProcess[str]
    ) -> tuple[bool, list[str]]:
        """Check synthesis output for errors."""
        has_error = False
        error_lines = []

        if result.stdout and "ERROR:" in result.stdout:
            has_error = True
            for line in result.stdout.splitlines():
                if "ERROR:" in line:
                    error_lines.append(line)

        if result.stderr and "ERROR:" in result.stderr:
            has_error = True
            for line in result.stderr.splitlines():
                if "ERROR:" in line:
                    error_lines.append(line)

        if result.returncode != 0:
            has_error = True
            if not error_lines:
                error_lines.append(f"Yosys exited with code {result.returncode}")

        return has_error, error_lines


def test_store_queue_physical_address_assertions(tmp_path: Path) -> None:
    """The native frontend must retain a separately guarded check at each SQ slot."""
    from test_run_formal import formal_task_config

    formal = Path(__file__).resolve().parents[1] / "formal"
    setup = tmp_path / "setup"
    subprocess.run(
        ["sby", "--setup", "-d", str(setup), "store_queue.sby", "bmc"],
        cwd=formal,
        check=True,
        timeout=60,
    )
    src = setup / "src"
    commands = formal_task_config("store_queue", "bmc")["[script]"]
    script = tmp_path / "checks.ys"
    script.write_text("\n".join([*commands, "write_json model.json", ""]))
    subprocess.run(
        ["yosys", "-Q", "-q", "-s", str(script)], cwd=src, check=True, timeout=60
    )
    module = json.loads((src / "model.json").read_text())["modules"]["store_queue"]
    depth = len(module["netnames"]["sq_valid"]["bits"])
    lines = (src / "store_queue.sv").read_text().splitlines()
    first = next(
        i
        for i, line in enumerate(lines)
        if "begin : gen_cmo_order_address_check" in line
    )
    last = lines.index("  end", first + 1)
    checks = []
    for cell in module["cells"].values():
        if cell["type"] != "$check" or cell["parameters"]["FLAVOR"] != "assert":
            continue
        location = re.match(r"store_queue\.sv:(\d+)\.", cell["attributes"]["src"])
        if location and first < int(location[1]) <= last:
            checks.append(cell["connections"])
    assert depth > 1 and len(checks) == depth
    for port in ("A", "EN"):
        bits = [check[port][0] for check in checks]
        # Integer bit IDs are connected nets. JSON represents constants as strings.
        assert all(isinstance(bit, int) for bit in bits) and len(set(bits)) == depth


def test_synthesis_filelist_includes_cached_tier_dependencies(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Catch omitted NIC dependencies without waiting for full synthesis."""
    monkeypatch.setattr(YosysRunner, "setup_sw_mem", lambda self: None)
    runner = YosysRunner()
    sources = runner.parse_filelist(runner.filelist)
    names = {Path(source).name for source in sources}
    assert {
        "platform_top.sv",
        "nic_pkg.sv",
        "nic_engine.sv",
        "nic_mac_cdc.sv",
        "nic_mac_10g.sv",
        "nic_mac_1g.sv",
        "nic_top.sv",
        "eth10g_crc_pkg.sv",
        "eth10g_pcs_pkg.sv",
        "eth10g_mac_pcs.sv",
        "async_fifo.sv",
        "cdc_sync.sv",
        "sdp_block_ram.sv",
    } <= names
    assert len(sources) == len(set(sources)), "Yosys rejects duplicate modules"
    assert all(Path(source).is_file() for source in sources)


def _xilinx_scripts(
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[str, dict[str, str], set[str]]:
    """Build the full-chip and partition Xilinx scripts without running Yosys.

    Return them with the names of the modules the sources declare. The NIC
    sources stay unconverted, so the scripts name the files of the filelist.
    """
    monkeypatch.setattr(YosysRunner, "setup_sw_mem", lambda self: None)
    monkeypatch.setattr(
        YosysRunner,
        "convert_nic_sources",
        lambda self, files, directory, defines, timeout: files,
    )
    monkeypatch.delenv("FROST_DDR_CAPACITY_LOG2_BYTES", raising=False)
    monkeypatch.delenv("FROST_ASYNC_CPU_CLOCK", raising=False)
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda command, **kwargs: subprocess.CompletedProcess(command, 0, "", ""),
    )
    runner = YosysRunner()
    command = next(t[1] for t in SYNTHESIS_TARGETS if t[0] == XILINX_TARGET)

    def build(after_hierarchy: Sequence[str] = ()) -> str:
        scripts: list[str] = []
        runner.run_synthesis(
            synth_command=command,
            reuse_hook=lambda script, temp_dir, timeout, after: scripts.append(script),
            after_hierarchy=after_hierarchy,
        )
        return scripts[0]

    modules = {
        name
        for source in runner.parse_filelist(runner.filelist)
        for name in re.findall(
            r"^\s*module\s+(\w+)",
            _blank_strings_and_comments(Path(source).read_text()),
            flags=re.M,
        )
    }
    partitions = {
        name: build(xilinx_partition_commands(root)) for name, root in XILINX_PARTITIONS
    }
    return build(), partitions, modules


def test_xilinx_partitions_cover_the_design(monkeypatch: pytest.MonkeyPatch) -> None:
    """The partitions read every source and leave no module unmapped."""
    full, partitions, modules = _xilinx_scripts(monkeypatch)
    assert len(partitions) > 1
    assert not xilinx_partition_gaps(full, partitions, modules)


def test_xilinx_partition_gaps_are_found(monkeypatch: pytest.MonkeyPatch) -> None:
    """Negative controls: a source no partition reads, and a module boxed everywhere."""
    full, partitions, modules = _xilinx_scripts(monkeypatch)
    names = [name for name, _ in XILINX_PARTITIONS]
    roots = dict(XILINX_PARTITIONS)
    source = next(
        line for line in full.splitlines() if line.startswith("read_verilog -sv")
    )
    unread = {n: s.replace(source + "\n", "") for n, s in partitions.items()}
    assert f"no partition reads {source.split()[-1]}" in xilinx_partition_gaps(
        full, unread, modules
    )
    # A partition that makes a non-root module a black box.
    boxed = dict(partitions)
    boxed[names[0]] = full.replace(
        f"hierarchy -top {XILINX_TOP}\n",
        f"hierarchy -top {XILINX_TOP}\n"
        + "\n".join(partition_block(roots[names[0]], ["load_queue"]))
        + "\n",
    )
    assert any(
        "makes load_queue a black box" in gap
        for gap in xilinx_partition_gaps(full, boxed, modules)
    )
    # Without a partition, its root is a black box in every other one.
    dropped = next(n for n in reversed(names) if roots[n] != XILINX_TOP)
    missing = {n: s for n, s in partitions.items() if n != dropped}
    assert any(
        f"makes {roots[dropped]} a black box" in gap
        for gap in xilinx_partition_gaps(full, missing, modules)
    )
    # Other commands, a root without its single-form check, a second top.
    other = dict(partitions)
    other[dropped] = partitions[dropped].replace(
        "hierarchy -check\n", "delete t:*\nhierarchy -check\n"
    )
    unchecked = dict(partitions)
    unchecked[dropped] = partitions[dropped].replace(
        f"select -assert-mod-count 1 {module_variants(roots[dropped])}\n", ""
    )
    second = dict(partitions, extra=full)
    typo = {
        n: s.replace(module_variants(roots[dropped]), module_variants("no_such"))
        for n, s in partitions.items()
    }
    for scripts, expected in (
        (other, f"{dropped} runs commands other than its partition's"),
        (unchecked, f"{dropped} runs commands other than its partition's"),
        (second, f"exactly one partition must keep {XILINX_TOP} as its top"),
        (typo, f"the root 'no_such' of {dropped} is not a module of the sources"),
    ):
        assert expected in xilinx_partition_gaps(full, scripts, modules)


def test_synthesis_jobs_select_each_test_once() -> None:
    """CI's synthesis jobs together run each synthesis test exactly once."""
    import yaml  # type: ignore[import-untyped]
    from _pytest.mark.expression import Expression

    root = Path(__file__).resolve().parents[1]
    collected = subprocess.run(
        [sys.executable, "-m", "pytest", "tests", "--collect-only", "-q"]
        + ["-m", "synthesis", "-p", "no:cacheprovider"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    )
    nodes = [n for n in collected.stdout.splitlines() if n.startswith("tests/")]
    partitions = [n for n in nodes if "::test_xilinx_partition[" in n]
    assert len(partitions) == len(XILINX_PARTITIONS), partitions
    job = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())["jobs"][
        "test-synthesis"
    ]
    assert any(
        '-m synthesis -k "$PYTEST_FILTER"' in step.get("run", "")
        for step in job["steps"]
    )
    shards = job["strategy"]["matrix"]["include"]

    def selects(shard: dict[str, str], node: str) -> bool:
        def keyword(name: str, /, **kwargs: str | int | bool | None) -> bool:
            assert not kwargs
            return name.casefold() in node.casefold()

        return Expression.compile(shard["pytest_filter"]).evaluate(keyword)

    runs = {n: [s["shard"] for s in shards if selects(s, n)] for n in nodes}
    assert all(len(jobs) == 1 for jobs in runs.values()), {
        n: jobs for n, jobs in runs.items() if len(jobs) != 1
    }
    assert all(any(selects(s, n) for n in nodes) for s in shards)


def test_synthesis_capacity_uses_single_rtl_setting(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Do not silently synthesize the default when CI selects an endpoint."""
    monkeypatch.delenv("FROST_DDR_CAPACITY_LOG2_BYTES", raising=False)
    assert _synthesis_defines() == "-DSYNTHESIS"
    for capacity in (30, 36, 37):
        monkeypatch.setenv("FROST_DDR_CAPACITY_LOG2_BYTES", str(capacity))
        assert _synthesis_defines().endswith(
            f"-DFROST_DDR_CAPACITY_LOG2_BYTES={capacity}"
        )
    for invalid_capacity in ("29", "38", "invalid"):
        monkeypatch.setenv("FROST_DDR_CAPACITY_LOG2_BYTES", invalid_capacity)
        with pytest.raises(ValueError):
            _synthesis_defines()


@pytest.mark.synthesis
class TestYosysSynthesis:
    """Test cases for Yosys synthesis."""

    def test_yosys_installed(self) -> None:
        """Test that Yosys is installed and available."""
        try:
            result = subprocess.run(
                ["yosys", "-V"], capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                pytest.fail(
                    "Yosys not found or failed to run - required for synthesis tests"
                )
            assert "Yosys" in result.stdout or "yosys" in result.stdout.lower(), (
                "Yosys version output not as expected"
            )
        except FileNotFoundError:
            pytest.fail("Yosys not installed - required for synthesis tests")
        except subprocess.TimeoutExpired:
            pytest.fail("Yosys version check timed out")

    @pytest.mark.parametrize(
        "target_name,synth_command,description",
        PYTEST_SYNTHESIS_TARGETS,
        ids=[t[0] for t in PYTEST_SYNTHESIS_TARGETS],
    )
    def test_synthesis(
        self, target_name: str, synth_command: str, description: str, capsys: Any
    ) -> None:
        """Run synthesis for a specific target and check for errors."""
        self.synthesize_with_reuse(
            f"test_synthesis[{target_name}]",
            target_name,
            synth_command,
            description,
            capsys,
        )

    @pytest.mark.parametrize(
        "partition,root", XILINX_PARTITIONS, ids=[p[0] for p in XILINX_PARTITIONS]
    )
    def test_xilinx_partition(self, partition: str, root: str, capsys: Any) -> None:
        """Synthesize one partition of the Xilinx UltraScale+ target."""
        target = next(t for t in SYNTHESIS_TARGETS if t[0] == XILINX_TARGET)
        self.synthesize_with_reuse(
            f"test_xilinx_partition[{partition}]",
            f"{XILINX_TARGET} partition {partition}",
            target[1],
            f"{target[2]}, partition {partition} (root {root})",
            capsys,
            xilinx_partition_commands(root),
        )

    def synthesize_with_reuse(
        self,
        test_id: str,
        target_name: str,
        synth_command: str,
        description: str,
        capsys: Any,
        after_hierarchy: Sequence[str] = (),
    ) -> None:
        """Synthesize a target, or in CI skip it if it passed with its key."""
        runner = YosysRunner()
        # In CI, skip a target that passed before with the same key
        # (tests/README.md, "Reusing formal and synthesis results").
        reuse = ci_reuse.Reuse.from_env(runner.root_dir, "synthesis")
        state: dict[str, Any] = {}

        def reuse_hook(script: str, temp_dir: Path, timeout: int, after: bool) -> None:
            """Skip a reusable run; after a run, check its key is unchanged."""
            assert reuse is not None
            key = synthesis_reuse_key(
                runner.root_dir, test_id, script, temp_dir, timeout, reuse.tools_id
            )
            if after:
                state["stable"] = key == state["key"]
                return
            decision = reuse.decide(test_id, key)
            state.update(key=key, decision=decision)
            if decision.action == "reuse":
                assert decision.marker is not None
                reuse.report(test_id, "reused", key, decision.marker)
                origin = ci_reuse.describe_origin(decision.marker["origin"])
                pytest.skip(f"Passed with the same key in {origin}")

        try:
            subprocess.run(["yosys", "-V"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            pytest.fail("Yosys not installed - required for synthesis tests")

        with capsys.disabled():
            print(f"\nRunning Yosys synthesis for {description}...")

        try:
            state["completed"] = self.synthesize(
                runner,
                target_name,
                synth_command,
                capsys,
                reuse_hook if reuse is not None else None,
                after_hierarchy,
            )
        except pytest.fail.Exception as failure:
            if reuse is not None and "decision" in state:
                # A canary, or a forced run, of a target with a marker.
                if state["decision"].marker is not None:
                    reuse.store.drop(test_id)
                    reuse.report(test_id, "canary-failed", state["key"])
                    origin = ci_reuse.describe_origin(
                        state["decision"].marker["origin"]
                    )
                    pytest.fail(
                        f"CANARY: {test_id} had a pass marker for this exact key "
                        f"from {origin} but did not pass now. The key misses an "
                        "input of the run, or the tools are not what the key "
                        f"says.\n{failure}"
                    )
                reuse.report(test_id, "failed", state["key"])
            raise
        if reuse is not None:
            if not state.get("stable"):
                reuse.report(test_id, "failed", state["key"])
                pytest.fail(f"The inputs of {test_id} changed while it ran")
            if not state.get("completed"):
                # Only a run that printed Yosys's end-of-script line earns a
                # marker, and an earlier marker for this key no longer stands.
                reuse.store.drop(test_id)
                reuse.report(test_id, "proved-without-marker", state["key"])
                return
            reuse.store.record_pass(
                test_id, state["key"], ci_reuse.environment_origin()
            )
            status = "canary" if state["decision"].action == "canary" else "proved"
            reuse.report(test_id, status, state["key"])

    @staticmethod
    def synthesize(
        runner: YosysRunner,
        target_name: str,
        synth_command: str,
        capsys: Any,
        reuse_hook: Callable[[str, Path, int, bool], None] | None,
        after_hierarchy: Sequence[str] = (),
    ) -> bool:
        """Run one synthesis target and fail the test unless it succeeds.

        Return whether Yosys exited with 0 and printed its end-of-script line.
        """
        try:
            result = runner.run_synthesis(
                capture_output=True,
                synth_command=synth_command,
                reuse_hook=reuse_hook,
                after_hierarchy=after_hierarchy,
            )

            has_error, error_lines = runner.check_for_errors(result)

            with capsys.disabled():
                if has_error:
                    print(f"\nSynthesis for {target_name} failed with errors:")
                    for line in error_lines:
                        print(f"  {line}")
                else:
                    print(f"\nSynthesis for {target_name} completed successfully")
                    if result.stdout and "End of script" in result.stdout:
                        for line in result.stdout.splitlines():
                            if "Number of cells:" in line or "Number of wires:" in line:
                                print(f"  {line.strip()}")

            if has_error:
                error_msg = f"Yosys synthesis for {target_name} failed:\n" + "\n".join(
                    error_lines
                )
                pytest.fail(error_msg)
            return result.returncode == 0 and "End of script" in (result.stdout or "")

        except subprocess.TimeoutExpired:
            timeout_sec = _get_timeout_seconds(synth_command)
            pytest.fail(
                f"Yosys synthesis for {target_name} timed out after {timeout_sec}s"
            )
        except Exception as e:
            pytest.fail(f"Unexpected error during {target_name} synthesis: {e}")


@pytest.mark.synthesis
@pytest.mark.parametrize("fault", ["missing_module", "observable_latch"])
def test_synthesis_rejects_invalid_nic(
    fault: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Missing dependencies and real latches must fail even the coarse target."""
    monkeypatch.delenv("FROST_ASYNC_CPU_CLOCK", raising=False)
    monkeypatch.setattr(YosysRunner, "setup_sw_mem", lambda self: None)
    runner = YosysRunner()
    runner.root_dir = tmp_path
    runner.test_dir = tmp_path
    runner.filelist = tmp_path / "design.f"
    top = tmp_path / "platform_top.sv"
    top.write_text(
        "module platform_top(input logic en, data, output logic value);\n"
        "  nic_top nic(.en(en), .data(data), .value(value));\n"
        "endmodule\n"
    )
    sources = [str(top)]
    if fault == "observable_latch":
        nic = tmp_path / "hw/rtl/peripherals/nic/nic_top.sv"
        nic.parent.mkdir(parents=True)
        nic.write_text(
            "module nic_top(input logic en, data, output logic value);\n"
            "  wire kept_always_comb_name = en;\n"
            "  always_comb if (kept_always_comb_name) value = data;\n"
            "endmodule\n"
        )
        sources.append(str(nic))
    runner.filelist.write_text("\n".join(sources) + "\n")

    result = runner.run_synthesis(synth_command=GENERIC_SYNTH_COMMAND)
    has_error, errors = runner.check_for_errors(result)
    assert has_error, f"Synthesis accepted {fault}"
    if fault == "missing_module":
        assert any(
            "nic_top" in error and "not part of the design" in error for error in errors
        )
    else:
        assert any("selection is not empty" in error for error in errors)


@pytest.mark.synthesis
def test_every_module_maps_in_a_xilinx_partition(tmp_path: Path) -> None:
    """Together the partitions map every module of the elaborated design.

    Elaborate the Xilinx target once, then apply each partition's commands
    to a copy and list the modules left to map, as synth_xilinx's first
    step leaves them. Their union must be every module of the elaboration,
    and without any one partition some module is mapped nowhere.
    """
    runner = YosysRunner()
    listing = ["design -save elaborated"]
    for name, root in [("", XILINX_TOP), *XILINX_PARTITIONS]:
        if name:
            listing += ["design -load elaborated", *xilinx_partition_commands(root)]
            listing.append("hierarchy")
        listing.append(f"tee -q -o {tmp_path}/{name or 'design'}.txt ls")
    listing.append("design -load elaborated")
    command = next(t[1] for t in SYNTHESIS_TARGETS if t[0] == XILINX_TARGET)
    result = runner.run_synthesis(
        synth_command=f"{command} -run begin:begin", after_hierarchy=listing
    )
    has_error, errors = runner.check_for_errors(result)
    assert not has_error, errors

    def modules(name: str) -> set[str]:
        text = (tmp_path / f"{name}.txt").read_text()
        lines = text.split("modules:", 1)[1].splitlines()
        return {line.strip() for line in lines if line.strip()}

    def form_of(module: str, root: str) -> bool:
        return (
            module == root
            or module.startswith(f"$paramod\\{root}\\")
            or (module.startswith("$paramod$") and module.endswith(f"\\{root}"))
        )

    design = modules("design")
    mapped = {name: modules(name) for name, _ in XILINX_PARTITIONS}
    assert len(design) > 100
    assert set().union(*mapped.values()) == design
    for name, root in XILINX_PARTITIONS:
        assert any(form_of(m, root) for m in mapped[name]), (name, root)
        others = set().union(*(m for n, m in mapped.items() if n != name))
        assert mapped[name] - others, f"without {name} every module is still mapped"


@pytest.mark.synthesis
def test_synthesis_accepts_specialized_top(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The final check must retain the top selected by Xilinx elaboration."""
    monkeypatch.delenv("FROST_ASYNC_CPU_CLOCK", raising=False)
    monkeypatch.setattr(YosysRunner, "setup_sw_mem", lambda self: None)
    runner = YosysRunner()
    runner.root_dir = tmp_path
    runner.test_dir = tmp_path
    runner.filelist = tmp_path / "design.f"
    top = tmp_path / "platform_top.sv"
    top.write_text(
        "module platform_top #(parameter ENABLE_CACHED_TIER=1, "
        "USE_BEHAVIORAL_DDR=1)(input data, output value);\n"
        "  assign value = data;\n"
        "endmodule\n"
    )
    runner.filelist.write_text(str(top) + "\n")
    # Model the top-name change caused by reprocessing the cache/walker
    # hierarchy, without elaborating the complete CPU in this small test.
    result = runner.run_synthesis(
        synth_command="synth_xilinx -family xcup -run begin:begin\n"
        "rename -top specialized_platform_top"
    )
    has_error, errors = runner.check_for_errors(result)
    assert not has_error, errors


@pytest.mark.synthesis
def test_xilinx_pc_hierarchy_keeps_parameterized_dependencies(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Late primitive loading must not rederive a parent after child pruning."""
    monkeypatch.delenv("FROST_ASYNC_CPU_CLOCK", raising=False)
    monkeypatch.setattr(YosysRunner, "setup_sw_mem", lambda self: None)
    runner = YosysRunner()
    rtl = runner.root_dir / "hw/rtl/cpu_and_mem/cpu"
    runner.root_dir = tmp_path
    runner.test_dir = tmp_path
    runner.filelist = tmp_path / "design.f"
    top = tmp_path / "platform_top.sv"
    top.write_text(
        "module platform_top #(parameter ENABLE_CACHED_TIER=1, "
        "USE_BEHAVIORAL_DDR=1)(input reset, output [63:0] value);\n"
        "  pc_controller #(.PENDING_HANDOFF_EXCLUDES_SLOT2(1)) pc "
        "(.i_reset(reset), .o_pc(value));\n"
        "endmodule\n"
    )
    sources = [
        rtl / "riscv_pkg.sv",
        rtl / "if_stage/control_flow_tracker.sv",
        rtl / "if_stage/pc_reg_precompute.sv",
        rtl / "if_stage/pc_increment_calculator.sv",
        rtl / "if_stage/pc_controller.sv",
        top,
    ]
    runner.filelist.write_text("\n".join(map(str, sources)) + "\n")
    # A parent rederived after child pruning fails during hierarchy
    # elaboration, before logic mapping, so the begin step is enough.
    result = runner.run_synthesis(
        synth_command="synth_xilinx -family xcup -run begin:begin"
    )
    has_error, errors = runner.check_for_errors(result)
    assert not has_error, errors


# Element selects of packed arrays as read_verilog elaborates them, against
# the yosys-slang elaboration of the same text. Each case is (expected
# result, dut): "equivalent" cases must prove equal under a SAT miter. The
# others are forms read_verilog gets wrong: an element select of a
# multidimensional packed array declared in a generate block can stop with
# an error, or, when the array's type is a typedef, can become a bit select
# without one. test_rtl_generate_blocks_have_no_multidimensional_packed_arrays
# flags these declarations in hw/rtl.
PACKED_SELECT_CHILD = """\
module child #(parameter int unsigned W = 4) (
    input  logic [W-1:0] i_a,
    input  logic [  3:0] i_extra,
    output logic [W-1:0] o_y
);
  assign o_y = i_a ^ W'(i_extra);
endmodule
"""
_GENERATE_PORTS = """\
module dut (
    input  logic [ 3:0] i_a0, i_a1, i_k,
    output logic [11:0] o_arr,
    output logic [ 3:0] o_last, o_child
);
  {module_items}
  if (1) begin : gen_ports
    localparam int unsigned Last = 2;
    {declaration}
    child c0 (.i_a(i_a0), .i_extra('0), .o_y(arr[{port0}]));
    child c1 (.i_a(i_a1), .i_extra(4'd1), .o_y(arr[{port1}]));
    child c2 (.i_a(arr[{port0}]), .i_extra(4'd2), .o_y(o_child));
    assign arr[{last}] = i_k;
    assign o_arr = arr;
    assign o_last = arr[{last}];
  end
endmodule
"""
PACKED_SELECT_CASES = {
    # Module-scope arrays: assigned, connected, read and written by element.
    "module_scope": (
        "equivalent",
        """\
module dut (
    input  logic [ 3:0] i_a0, i_a1, i_k,
    input  logic [ 1:0] i_sel,
    output logic [15:0] o_arr,
    output logic [ 3:0] o_pick, o_child,
    output logic [ 7:0] o_proc
);
  logic [3:0][3:0] arr;
  logic [1:0][3:0] proc_arr;
  child c0 (.i_a(i_a0), .i_extra('0), .o_y(arr[0]));
  child c1 (.i_a(arr[0]), .i_extra(4'd3), .o_y(o_child));
  assign arr[1] = i_a1;
  assign arr[2] = i_k;
  assign arr[3] = ~i_k;
  assign o_arr = arr;
  assign o_pick = arr[i_sel];
  always_comb begin
    proc_arr = '0;
    proc_arr[1] = arr[2];
    proc_arr[0] = arr[1] & i_k;
  end
  assign o_proc = proc_arr;
endmodule
""",
    ),
    # A flat vector in a generate block, one part-select per port (soc_top).
    "generate_flat": (
        "equivalent",
        _GENERATE_PORTS.format(
            module_items="",
            declaration="logic [3*4-1:0] arr;",
            port0="0*4+:4",
            port1="1*4+:4",
            last="Last*4+:4",
        ),
    ),
    # A multidimensional array in a generate block, used only in connections.
    "generate_connections": (
        "equivalent",
        """\
module dut (
    input  logic [ 3:0] i_a0, i_a1, i_a2,
    output logic [11:0] o_arr,
    output logic [ 3:0] o_child
);
  if (1) begin : gen_ports
    logic [2:0][3:0] arr;
    child c0 (.i_a(i_a0), .i_extra('0), .o_y(arr[0]));
    child c1 (.i_a(i_a1), .i_extra(4'd1), .o_y(arr[1]));
    child c2 (.i_a(i_a2), .i_extra(4'd2), .o_y(arr[2]));
    child c3 (.i_a(arr[1]), .i_extra(4'd3), .o_y(o_child));
    child #(.W(12)) c4 (.i_a(arr), .i_extra(4'd0), .o_y(o_arr));
  end
endmodule
""",
    ),
    # A function's local multidimensional array.
    "function_local": (
        "equivalent",
        """\
module dut (
    input  logic [15:0] i_a,
    output logic [ 7:0] o_y
);
  function automatic logic [7:0] fold(input logic [15:0] a);
    logic [3:0][3:0] c;
    for (int b = 0; b < 4; b++) c[b] = a[4*b+:4] ^ 4'(b);
    fold = {c[3] ^ c[1], c[2] ^ c[0]};
  endfunction
  assign o_y = fold(i_a);
endmodule
""",
    ),
    "generate_multidimensional": (
        "rejected",
        _GENERATE_PORTS.format(
            module_items="",
            declaration="logic [2:0][3:0] arr;",
            port0="0",
            port1="1",
            last="Last",
        ),
    ),
    # A named element type with packed dimensions at the declaration.
    "generate_named_type": (
        "not equivalent",
        _GENERATE_PORTS.format(
            module_items="",
            declaration="typedef logic port_bit_t;\n    port_bit_t [2:0][3:0] arr;",
            port0="0",
            port1="1",
            last="Last",
        ),
    ),
    # The same with a type name that has no _t suffix.
    "generate_named_type_unsuffixed": (
        "not equivalent",
        _GENERATE_PORTS.format(
            module_items="",
            declaration="typedef logic port_bit;\n    port_bit [2:0][3:0] arr;",
            port0="0",
            port1="1",
            last="Last",
        ),
    ),
    # A module-scope typedef that holds both dimensions, declared in the block
    # without dimensions of its own.
    "generate_typedef_dimensions": (
        "not equivalent",
        _GENERATE_PORTS.format(
            module_items="typedef logic [2:0][3:0] ports_t;",
            declaration="ports_t arr;",
            port0="0",
            port1="1",
            last="Last",
        ),
    ),
}


def _packed_select_verdict(directory: Path, dut: str) -> tuple[str, str]:
    """Compare read_verilog's netlist of dut with yosys-slang's.

    Inputs are held to defined values; an x from yosys-slang's side is a
    don't-care. Return the verdict and the output of the last Yosys run.
    """
    (directory / "child.sv").write_text(PACKED_SELECT_CHILD)
    (directory / "dut.sv").write_text(dut)
    sources = f"{directory / 'child.sv'} {directory / 'dut.sv'}"
    gate, gold = directory / "gate.il", directory / "gold.il"
    scripts = [
        f"read_verilog -sv {sources}; hierarchy -top dut; proc; flatten; "
        f"rename dut gate; write_rtlil {gate}",
        f"read_slang --top dut {sources}; proc; flatten; "
        f"rename dut gold; write_rtlil {gold}",
        f"read_rtlil {gold}; read_rtlil {gate}; "
        "miter -equiv -flatten -make_assert -ignore_gold_x gold gate miter; "
        "hierarchy -top miter; "
        "sat -verify -prove-asserts -enable_undef -set-def-inputs miter",
    ]
    output = ""
    for step, script in enumerate(scripts):
        result = subprocess.run(
            ["yosys", "-q", "-p", script], capture_output=True, text=True, timeout=120
        )
        output = result.stdout + result.stderr
        if result.returncode == 0:
            continue
        if step < 2:
            return "rejected", output
        if "proof did fail" in output:
            return "not equivalent", output
        return "error", output
    return "equivalent", output


@pytest.mark.synthesis
@pytest.mark.parametrize("case", PACKED_SELECT_CASES)
def test_read_verilog_element_selects(case: str, tmp_path: Path) -> None:
    """read_verilog matches yosys-slang, or fails in the listed way."""
    expected, dut = PACKED_SELECT_CASES[case]
    verdict, output = _packed_select_verdict(tmp_path, dut)
    assert verdict == expected, (
        f"{case}: read_verilog gives {verdict!r}, expected {expected!r}. A change "
        "in a failing form means Yosys reads it differently now; review "
        "test_rtl_generate_blocks_have_no_multidimensional_packed_arrays.\n"
        + output[-3000:]
    )


_DIM = r"\[[^\[\];]*\]"
_SCALAR_TYPES = {"logic", "bit", "reg", "wire"}
_VECTOR_TYPES = {"int", "integer", "byte", "shortint", "longint", "time"}
# Words that can stand where a declaration's type does but are not types.
_NOT_TYPES = {
    "and",
    "assign",
    "automatic",
    "begin",
    "case",
    "const",
    "default",
    "disable",
    "do",
    "else",
    "end",
    "enum",
    "export",
    "for",
    "foreach",
    "force",
    "forever",
    "function",
    "genvar",
    "if",
    "import",
    "inout",
    "input",
    "interface",
    "localparam",
    "modport",
    "module",
    "negedge",
    "new",
    "not",
    "or",
    "output",
    "package",
    "packed",
    "parameter",
    "posedge",
    "ref",
    "release",
    "repeat",
    "return",
    "signed",
    "static",
    "struct",
    "task",
    "typedef",
    "union",
    "unsigned",
    "var",
    "virtual",
    "wait",
    "while",
}
_TYPE_NAME = r"(?:[A-Za-z_]\w*\s*::\s*)?[A-Za-z_]\w*"
_DECLARATION = re.compile(
    rf"\b(?P<type>{_TYPE_NAME})\s*(?:\b(?:signed|unsigned)\b\s*)?"
    rf"(?P<dims>(?:{_DIM}\s*)*)(?P<name>[A-Za-z_]\w*)\s*(?:{_DIM}\s*)*(?=[;,=)])"
)
_TYPEDEF_SIMPLE = re.compile(
    rf"\s*(?P<base>{_TYPE_NAME})\s*(?:\b(?:signed|unsigned)\b\s*)?"
    rf"(?P<dims>(?:{_DIM}\s*)*)(?P<name>[A-Za-z_]\w*)\s*(?:{_DIM}\s*)*;"
)
_SCOPE_TOKEN = re.compile(
    r"\b(?P<word>begin|end|function|endfunction|task|endtask|case|casez|casex|"
    r"endcase|always_comb|always_ff|always_latch|always|initial|final|else|"
    r"endmodule)\b|(?P<punct>[;()])"
)


def _blank_strings_and_comments(source: str) -> str:
    """Blank strings and comments, keeping line numbers."""
    return re.sub(
        r'"(?:[^"\\\n]|\\.)*"|/\*.*?\*/|//[^\n]*',
        lambda m: re.sub(r"[^\n]", " ", m.group(0)),
        source,
        flags=re.S,
    )


def _imported_packages(text: str) -> list[str]:
    """Return the packages that the import statements in text name."""
    return [
        name
        for statement in re.findall(r"\bimport\s+([^;]+);", text)
        for name in re.findall(r"(\w+)\s*::", statement)
    ]


def _type_dimensions(
    type_name: str,
    typedefs: dict[str, int],
    packages: dict[str, dict[str, int]],
    imports: list[str],
) -> int:
    """Packed dimensions of a type: a typedef's own count, 0 if unknown."""
    type_name = re.sub(r"\s+", "", type_name)
    if type_name in _SCALAR_TYPES:
        return 0
    if type_name in _VECTOR_TYPES:
        return 1
    if "::" in type_name:
        package, name = type_name.split("::", 1)
        return packages.get(package, {}).get(name, 0)
    if type_name in typedefs:
        return typedefs[type_name]
    for package in imports:
        if type_name in packages.get(package, {}):
            return packages[package][type_name]
    return 0


def _typedef_dimensions(
    text: str, packages: dict[str, dict[str, int]], imports: list[str]
) -> dict[str, int]:
    """Packed dimensions of every typedef in text, its base type's included.

    A struct, union or enum counts as one dimension.
    """
    typedefs: dict[str, int] = {}
    for match in re.finditer(r"\btypedef\b", text):
        start = match.end()
        if re.match(r"\s*(?:struct|union|enum)\b", text[start:]):
            brace = text.find("{", start)
            if brace < 0:
                continue
            depth, end = 0, brace
            while end < len(text):
                depth += {"{": 1, "}": -1}.get(text[end], 0)
                if depth == 0:
                    break
                end += 1
            tail = re.match(rf"\s*(?P<dims>(?:{_DIM}\s*)*)(\w+)", text[end + 1 :])
            if tail:
                dims = len(re.findall(_DIM, tail.group("dims")))
                typedefs[tail.group(2)] = 1 + dims
            continue
        simple = _TYPEDEF_SIMPLE.match(text, start)
        if simple:
            dims = len(re.findall(_DIM, simple.group("dims")))
            base = _type_dimensions(simple.group("base"), typedefs, packages, imports)
            name = simple.group("name")
            typedefs[name] = max(typedefs.get(name, 0), dims + base)
    return typedefs


def package_typedefs(sources: list[str]) -> dict[str, dict[str, int]]:
    """Packed dimensions of the typedefs of every package in the sources."""
    bodies = {}
    for source in sources:
        text = _blank_strings_and_comments(source)
        for match in re.finditer(
            r"\bpackage\s+(\w+)\s*;(.*?)\bendpackage\b", text, flags=re.S
        ):
            bodies[match.group(1)] = match.group(2)
    packages: dict[str, dict[str, int]] = {}
    for _ in range(4):  # a package's typedefs can build on another's
        for name, body in bodies.items():
            packages[name] = _typedef_dimensions(
                body, packages, _imported_packages(body)
            )
    return packages


def multidimensional_generate_arrays(
    source: str, packages: dict[str, dict[str, int]] | None = None
) -> list[tuple[int, str]]:
    """Return (line, name) of each multidimensional packed array in a generate block.

    A declaration counts with two or more packed dimensions, those of its
    type included (a typedef in the file, or in a package that the file
    imports or names), or with a named type and packed dimensions of its
    own. A begin-end or case block is procedural inside an always,
    initial or final statement (up to the semicolon or end that closes it,
    an else continuing it) or inside a function or task; any other is a
    generate block. The check reads source text; it is not a SystemVerilog
    parser.
    """
    packages = packages or {}
    text = _blank_strings_and_comments(source)
    imports = _imported_packages(text)
    typedefs = _typedef_dimensions(text, packages, imports)
    tokens = list(_SCOPE_TOKEN.finditer(text))
    stack: list[tuple[str, int, bool]] = []  # kind, start, opens the statement
    spans: list[tuple[int, int, str]] = []
    pending_depth = -1  # stack depth of an open always/initial/final statement
    parens = 0

    def next_word(i: int) -> str:
        return tokens[i + 1].group(0) if i + 1 < len(tokens) else ""

    for i, token in enumerate(tokens):
        word, punct = token.group("word"), token.group("punct")
        procedural = pending_depth >= 0 or any(k == "proc" for k, _, _ in stack)
        if punct == "(":
            parens += 1
        elif punct == ")":
            parens = max(parens - 1, 0)
        elif punct == ";":
            if parens == 0 and len(stack) == pending_depth and next_word(i) != "else":
                pending_depth = -1
        elif word in ("always_comb", "always_ff", "always_latch", "always"):
            if not procedural:
                pending_depth = len(stack)
        elif word in ("initial", "final"):
            if not procedural:
                pending_depth = len(stack)
        elif word in ("function", "task"):
            stack.append(("proc", token.start(), False))
        elif word in ("begin", "case", "casez", "casex"):
            kind = "proc" if procedural else "gen"
            stack.append((kind, token.start(), len(stack) == pending_depth))
        elif word in ("end", "endcase", "endfunction", "endtask") and stack:
            kind, start, opens = stack.pop()
            spans.append((start, token.end(), kind))
            if opens and next_word(i) != "else":
                pending_depth = -1
        elif word == "endmodule":
            stack.clear()
            pending_depth = -1
    found = []
    for match in _DECLARATION.finditer(text):
        type_name = re.sub(r"\s+", "", match.group("type"))
        if type_name in _NOT_TYPES:
            continue
        dims = len(re.findall(_DIM, match.group("dims")))
        if type_name in _SCALAR_TYPES | _VECTOR_TYPES or not dims:
            dims += _type_dimensions(type_name, typedefs, packages, imports)
        else:
            dims = 2  # a named type with packed dimensions of its own
        if dims < 2:
            continue
        inner = [s for s in spans if s[0] < match.start() < s[1]]
        if inner and max(inner)[2] == "gen":
            found.append((text.count("\n", 0, match.start()) + 1, match.group("name")))
    return found


def _rtl_sources() -> list[Path]:
    return sorted((Path(__file__).resolve().parents[1] / "hw/rtl").rglob("*.sv"))


def test_rtl_generate_blocks_have_no_multidimensional_packed_arrays() -> None:
    """Keep packed arrays read_verilog mis-reads (see PACKED_SELECT_CASES) out."""
    root = Path(__file__).resolve().parents[1]
    sources = {path: path.read_text() for path in _rtl_sources()}
    packages = package_typedefs(list(sources.values()))
    found = [
        f"{path.relative_to(root)}:{line}: {name}"
        for path, source in sources.items()
        for line, name in multidimensional_generate_arrays(source, packages)
    ]
    assert not found, (
        "Declare these at module scope, or as flat vectors with an explicit "
        "part-select for each element:\n" + "\n".join(found)
    )


def test_generate_array_check_flags_failing_select_cases() -> None:
    """Every form that read_verilog reads wrongly above is flagged."""
    for case, (expected, dut) in PACKED_SELECT_CASES.items():
        if expected != "equivalent":
            assert multidimensional_generate_arrays(dut), case


def test_generate_array_check_flags_only_generate_blocks() -> None:
    """The check flags generate blocks and leaves procedural and module scope."""
    package = """\
package demo_pkg;
  typedef logic [31:0] word_t;
  typedef word_t [3:0] quad_t;
endpackage
"""
    source = """\
module m #(parameter int N = 2) (input logic clk, input logic [7:0] d);
  import demo_pkg::*;
  typedef logic port_bit;
  typedef logic [1:0][3:0] pair_t;
  typedef logic [3:0] nibble_t;
  typedef struct packed { logic [3:0] a; logic b; } fields_s;
  typedef fields_s [1:0] fields_pair_t;
  logic [1:0][3:0] module_scope;  // no
  pair_t module_typedef;  // no
  if (N > 1) begin : gen_a
    logic [N-1:0][3:0] gen_if;  // yes
    logic [N*4-1:0] gen_flat;  // no
    ports_t [N-1:0] gen_named;  // yes
    port_bit [N-1:0][3:0] gen_unsuffixed;  // yes
    pair_t gen_typedef;  // yes
    nibble_t gen_nibble;  // no
    fields_s gen_struct;  // no
    fields_pair_t gen_struct_pair;  // yes
    demo_pkg::quad_t gen_scoped;  // yes
    quad_t gen_imported;  // yes
    word_t gen_word;  // no
    always_comb begin
      logic [1:0][3:0] always_local;  // no
      always_local = '0;
    end
  end
  always_ff @(posedge clk) if (d[0]) begin
    logic [1:0][1:0] if_local;  // no
  end else begin
    logic [1:0][1:0] else_local;  // no
  end
  always_comb for (int i = 0; i < 2; i++) begin
    logic [1:0][1:0] loop_local;  // no
  end
  initial $display("(begin;");
  for (genvar g = 0; g < N; g++) begin : gen_b
    logic [1:0][3:0] gen_for;  // yes
  end
  function automatic logic [7:0] f(input logic [7:0] x);
    logic [1:0][3:0] function_local;  // no
    f = x;
  endfunction
endmodule
"""
    expected = [
        (i + 1, line.split()[-3].rstrip(";"))
        for i, line in enumerate(source.splitlines())
        if line.endswith("// yes")
    ]
    packages = package_typedefs([package])
    assert packages == {"demo_pkg": {"word_t": 1, "quad_t": 2}}
    assert multidimensional_generate_arrays(source, packages) == expected


# Command-line interface for standalone execution
def main() -> int:
    """Run Yosys synthesis from command line."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Run Yosys synthesis for FROST",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                           # Run standard targets (generic, UltraScale+)
  %(prog)s --target xilinx_ultrascale_plus  # Run the supported Xilinx target
  %(prog)s --partition core          # Run one of its partitions, as CI does
  %(prog)s --target generic          # Run generic/ASIC synthesis
  %(prog)s --target ice40            # Run iCE40 synthesis (any Yosys target works)
  %(prog)s --verbose                 # Show full Yosys output

This script can also be run via pytest:
  pytest test_run_yosys.py                        # Run all synthesis tests
  pytest test_run_yosys.py::TestYosysSynthesis    # Run specific class
""",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Show full Yosys output"
    )
    parser.add_argument(
        "--target",
        "-t",
        default=None,
        help="Synthesis target (any Yosys synth_* target, e.g., xilinx, ice40, ecp5)",
    )
    parser.add_argument(
        "--partition",
        choices=[name for name, _ in XILINX_PARTITIONS],
        help="Run one partition of the Xilinx UltraScale+ target",
    )

    args = parser.parse_args()

    try:
        result = subprocess.run(["yosys", "-V"], capture_output=True, text=True)
        if result.returncode != 0:
            print("Error: Yosys not found or failed to run")
            return 1
        print(f"Found: {result.stdout.strip()}")
    except FileNotFoundError:
        print("Error: Yosys is not installed or not in PATH")
        return 1

    runner = YosysRunner()
    print(f"Design: frost ({runner.filelist})")

    targets: list[tuple[str, str, str, Sequence[str]]]
    if args.partition:
        root = dict(XILINX_PARTITIONS)[args.partition]
        name, command, description = next(
            t for t in SYNTHESIS_TARGETS if t[0] == XILINX_TARGET
        )
        targets = [
            (
                f"{name} partition {args.partition}",
                command,
                f"{description}, partition {args.partition} (root {root})",
                xilinx_partition_commands(root),
            )
        ]
    elif args.target:
        targets = [(n, c, d, ()) for n, c, d in SYNTHESIS_TARGETS if n == args.target]
        if not targets:
            # Allow any Yosys synth_* target
            synth_cmd = (
                GENERIC_SYNTH_COMMAND
                if args.target == "generic"
                else f"synth_{args.target}"
            )
            targets = [(args.target, synth_cmd, args.target, ())]
    else:
        targets = [(n, c, d, ()) for n, c, d in SYNTHESIS_TARGETS]

    failed_targets = []
    for target_name, synth_command, description, after_hierarchy in targets:
        try:
            print(f"\n{'=' * 60}")
            print(f"Running Yosys synthesis for {description}...")
            print(f"{'=' * 60}")

            result = runner.run_synthesis(
                capture_output=not args.verbose,
                synth_command=synth_command,
                after_hierarchy=after_hierarchy,
            )

            has_error, error_lines = runner.check_for_errors(result)

            if not args.verbose and result.stdout:
                lines = result.stdout.splitlines()

                # The statistics block is at the tail of the log.
                for line in lines[-50:]:
                    if (
                        "End of script" in line
                        or "Number of cells:" in line
                        or "ERROR:" in line
                    ):
                        print(line)

            if has_error:
                print(f"\nSynthesis for {target_name} FAILED with errors:")
                for line in error_lines:
                    print(f"  {line}")
                failed_targets.append(target_name)
            else:
                print(f"\nSynthesis for {target_name} completed successfully!")

        except Exception as e:
            print(f"\nError during {target_name} synthesis: {e}")
            failed_targets.append(target_name)

    # Summary
    print(f"\n{'=' * 60}")
    print("SYNTHESIS SUMMARY")
    print(f"{'=' * 60}")
    passed = len(targets) - len(failed_targets)
    print(f"Passed: {passed}/{len(targets)}")
    if failed_targets:
        print(f"Failed: {', '.join(failed_targets)}")
        return 1
    else:
        print("All synthesis targets passed!")
        return 0


if __name__ == "__main__":
    sys.exit(main())

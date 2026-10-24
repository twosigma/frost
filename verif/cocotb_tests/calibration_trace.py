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

"""Calibration traces of real-program runs for the performance model.

FROST_CALIBRATION_TRACE_PATH turns the capture on for one run of a program,
FROST_CALIBRATION_TARGET_RUN (the last run by default). The trace covers the
cycles from the retirement of FROST_CALIBRATION_START_PC to the retirement of
FROST_CALIBRATION_STOP_PC, or the whole run when no start PC is set; CoreMark
defaults to its timed region. FROST_CALIBRATION_COUNTERS_PATH and
FROST_CALIBRATION_MANIFEST_PATH name optional files for the window's pipeline
counters and the run's manifest. perf-modeling/README.md describes the trace
format.

The trace and the manifest record the commit from FROST_GIT_COMMIT, or else
from git. The manifest takes the tool versions from cocotb and the simulator,
the compiler from the program's ELF, the clock from the bench's clock period,
and the memory tier and DDR model settings from the environment that the
runner gives the simulation.
"""

import hashlib
import json
import os
import re
import struct
import subprocess
import time
from collections import Counter
from collections.abc import Mapping
from pathlib import Path
from typing import Any, TextIO

import cocotb

from cocotb_tests.cpu_structs import ID_TO_EX_FIELDS

CPU_TOP_PATH = "cpu_and_memory_subsystem.cpu"
CORE_PATH = f"{CPU_TOP_PATH}.hart.cpu_inst"
COMMIT_MISPREDICTION_PATH = (
    f"{CORE_PATH}.misprediction_flush_controller_inst.commit_is_misprediction"
)
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
# The DDR model settings that tests/Makefile and frost.sv give a run that
# does not set them.
DDR_MODEL_DEFAULTS = {
    "DDR_MODEL_LATENCY": 30,
    "DDR_MODEL_LATENCY_JITTER": 0,
    "DDR_MODEL_REORDER": 0,
}


def _signal(dut: Any, path: str) -> Any | None:
    """Return the signal at a dotted path, or None if the build has none."""
    handle = dut
    for part in path.split("."):
        if not hasattr(handle, part):
            return None
        handle = getattr(handle, part)
    return handle


def _read(handle: Any | None) -> int | None:
    """Return a signal's value, or None if it is missing or not resolvable."""
    if handle is None:
        return None
    try:
        return int(handle.value)
    except (AttributeError, ValueError):
        return None


def git_commit() -> str:
    """Return FROST_GIT_COMMIT, else the checkout's HEAD, else "unknown"."""
    commit = os.environ.get("FROST_GIT_COMMIT", "").strip()
    if commit:
        return commit
    try:
        result = subprocess.run(
            ["git", "-C", str(REPOSITORY_ROOT), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    head = result.stdout.strip()
    return head if result.returncode == 0 and head else "unknown"


def program_directory(app_name: str | None) -> Path | None:
    """Return the directory of the program the run loaded, if it is known.

    The runner links tests/sw.mem, the simulation's working directory's
    sw.mem, to the program's image.
    """
    image = Path("sw.mem")
    if image.is_symlink():
        return image.resolve().parent
    if app_name is not None and (REPOSITORY_ROOT / "sw" / "apps" / app_name).is_dir():
        return REPOSITORY_ROOT / "sw" / "apps" / app_name
    return None


def elf_comment(path: Path) -> str | None:
    """Return the first string in an ELF file's .comment section, or None.

    GCC records its version there, as "GCC: (<vendor>) <version>".
    """
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] not in (1, 2):
        return None
    order = "<" if data[5] == 1 else ">"
    if data[4] == 2:
        (shoff,) = struct.unpack_from(f"{order}Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from(f"{order}HHH", data, 0x3A)
        section = f"{order}IIQQQQ"
    else:
        (shoff,) = struct.unpack_from(f"{order}I", data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from(f"{order}HHH", data, 0x2E)
        section = f"{order}IIIIII"
    try:
        headers = [
            struct.unpack_from(section, data, shoff + index * shentsize)
            for index in range(shnum)
        ]
        names_offset = headers[shstrndx][4]
        for name, _type, _flags, _address, offset, size in headers:
            end = data.index(b"\0", names_offset + name)
            if data[names_offset + name : end] == b".comment":
                strings = data[offset : offset + size].split(b"\0")
                text = next((item for item in strings if item), b"")
                return text.decode("utf-8", "replace") or None
    except (IndexError, ValueError, struct.error):
        return None
    return None


def ddr_model_settings(environment: Mapping[str, str]) -> dict[str, int]:
    """Return the DDR model's latency, jitter, and reordering for a run.

    A -G argument in FROST_VERILATOR_EXTRA_ARGS sets a parameter, the last one
    winning as in Verilator; tests/Makefile passes DDR_MODEL_LATENCY ahead of
    those arguments. FROST_DDR_MODEL_SEED's draw reaches the simulation as
    such arguments.
    """
    settings = dict(DDR_MODEL_DEFAULTS)
    latency = environment.get("DDR_MODEL_LATENCY", "").strip()
    if latency:
        settings["DDR_MODEL_LATENCY"] = int(latency, 0)
    for argument in environment.get("FROST_VERILATOR_EXTRA_ARGS", "").split():
        match = re.fullmatch(r"-G(\w+)=(\S+)", argument)
        if match and match.group(1) in settings:
            settings[match.group(1)] = int(match.group(2), 0)
    return settings


def _field_slice(layout: list[tuple[str, int]], name: str) -> tuple[int, int]:
    """Return a packed-struct field's LSB and mask from its MSB-first layout."""
    lsb = sum(width for _, width in layout)
    for field_name, width in layout:
        lsb -= width
        if field_name == name:
            return lsb, (1 << width) - 1
    raise KeyError(name)


class CalibrationTrace:
    """Record one run's calibration trace, pipeline counters, and manifest.

    run_until_complete creates it before its cycle loop, calls sample once
    per cycle, and calls finish after a passing run.
    """

    @classmethod
    def from_environment(
        cls,
        dut: Any,
        *,
        app_name: str | None,
        run_number: int,
        num_runs: int,
        clock_period_ns: float,
    ) -> "CalibrationTrace | None":
        """Return the capture for this run, or None when it is off."""
        trace_path = os.environ.get("FROST_CALIBRATION_TRACE_PATH", "")
        target_run = int(os.environ.get("FROST_CALIBRATION_TARGET_RUN", str(num_runs)))
        if not trace_path or run_number != target_run:
            return None
        return cls(dut, Path(trace_path), app_name, run_number, clock_period_ns)

    def __init__(
        self,
        dut: Any,
        trace_path: Path,
        app_name: str | None,
        run_number: int,
        clock_period_ns: float,
    ) -> None:
        """Bind the signals and open the trace if the window starts at once.

        Raise AssertionError if the build lacks a signal that the capture
        reads.
        """
        self.trace_path = trace_path
        self.app_name = app_name
        self.run_number = run_number
        self.clock_period_ns = clock_period_ns
        self.is_coremark_like = app_name is not None and app_name.startswith("coremark")
        self.counters_path = os.environ.get("FROST_CALIBRATION_COUNTERS_PATH")
        self.manifest_path = os.environ.get("FROST_CALIBRATION_MANIFEST_PATH")
        self.start_pc = int(
            os.environ.get(
                "FROST_CALIBRATION_START_PC",
                "0x5848" if self.is_coremark_like else "0",
            ),
            0,
        )
        self.stop_pc = int(
            os.environ.get(
                "FROST_CALIBRATION_STOP_PC",
                "0x584c" if self.is_coremark_like else "0",
            ),
            0,
        )
        self.commit = git_commit()
        self.state = "ARMED" if self.start_pc else "ACTIVE"
        self.file: TextIO | None = None
        self.timed_cycle = 0
        self.start_sim_cycle = 0
        self.stop_sim_cycle = 0
        self.start_wall_time = time.perf_counter()
        self.counters: Counter[str] = Counter()
        self.rob_occupancy_sum = 0
        self.sq_occupancy_sum = 0

        missing: list[str] = []

        def bind(path: str) -> Any:
            handle = _signal(dut, path)
            if handle is None:
                missing.append(path)
            return handle

        core, cpu_top = CORE_PATH, CPU_TOP_PATH
        self.retire = bind(f"{core}.dbg_commit_valid")
        self.retire_pc = bind(f"{core}.dbg_commit_pc")
        self.retire_2 = bind(f"{core}.dbg_commit_2_valid")
        self.retire_2_pc = bind(f"{core}.dbg_commit_2_pc")
        self.retire_mispredict = bind(COMMIT_MISPREDICTION_PATH)
        self.dispatch = bind(f"{core}.dbg_rob_alloc_valid")
        self.dispatch_stall = bind(f"{core}.dbg_dispatch_stall")
        self.pipeline_stall = bind(f"{core}.dbg_pipeline_stall")
        self.rob_count = bind(f"{core}.rob_count")
        self.sq_count = bind(f"{core}.sq_count")
        self.slot2 = bind(f"{core}.from_id_to_ex_2")
        # cpu_top's AXI channels: each request channel's counter name, valid,
        # ready, ID, address, and direction, and each response channel's
        # counter name, valid, ready, ID, and response.
        self.axi_requests = (
            (
                "ar",
                bind(f"{cpu_top}.o_axi_arvalid"),
                bind(f"{cpu_top}.i_axi_arready"),
                bind(f"{cpu_top}.o_axi_arid"),
                bind(f"{cpu_top}.o_axi_araddr"),
                "false",
            ),
            (
                "aw",
                bind(f"{cpu_top}.o_axi_awvalid"),
                bind(f"{cpu_top}.i_axi_awready"),
                bind(f"{cpu_top}.o_axi_awid"),
                bind(f"{cpu_top}.o_axi_awaddr"),
                "true",
            ),
        )
        self.axi_responses = (
            (
                "r",
                bind(f"{cpu_top}.i_axi_rvalid"),
                bind(f"{cpu_top}.o_axi_rready"),
                bind(f"{cpu_top}.i_axi_rid"),
                bind(f"{cpu_top}.i_axi_rresp"),
            ),
            (
                "b",
                bind(f"{cpu_top}.i_axi_bvalid"),
                bind(f"{cpu_top}.o_axi_bready"),
                bind(f"{cpu_top}.i_axi_bid"),
                bind(f"{cpu_top}.i_axi_bresp"),
            ),
        )
        if missing:
            raise AssertionError(
                "FROST_CALIBRATION_TRACE_PATH needs signals this build does not "
                f"expose: {', '.join(missing)}"
            )
        layout_width = sum(width for _, width in ID_TO_EX_FIELDS)
        if len(self.slot2) != layout_width:
            raise AssertionError(
                f"{core}.from_id_to_ex_2 is {len(self.slot2)} bits wide, but its "
                f"cpu_structs layout adds up to {layout_width}"
            )
        self.slot2_real = _field_slice(ID_TO_EX_FIELDS, "is_real")
        if self.state == "ACTIVE":
            self._open()

    def _open(self) -> None:
        """Create the trace file and write its meta record."""
        self.trace_path.parent.mkdir(parents=True, exist_ok=True)
        self.file = open(self.trace_path, "w", buffering=1048576)
        self.file.write(
            f'{{"cycle":0,"event":"meta","source":"frost_perf_probe",'
            f'"rtl_commit":"{self.commit}","clock_domain":"cpu",'
            f'"memory_configuration":"axi_behavioral_memory"}}\n'
        )

    def sample(self, cycle: int) -> None:
        """Record the cycle that ended at the clock edge the loop awaited.

        cycle is the loop's 0-based count; the window's cycle stamps count
        from its first cycle.
        """
        r1_ret = bool(_read(self.retire))
        r2_ret = bool(_read(self.retire_2))
        r1_pc = _read(self.retire_pc) if r1_ret else None
        r2_pc = _read(self.retire_2_pc) if r2_ret else None

        if self.state == "ARMED":
            if (r1_ret and r1_pc == self.start_pc) or (
                r2_ret and r2_pc == self.start_pc
            ):
                self.state = "STARTING"
                self.start_sim_cycle = cycle + 1
        elif self.state == "STARTING":
            self.state = "ACTIVE"
            self.timed_cycle = 0
            self._open()

        if self.state != "ACTIVE":
            return
        trace = self.file
        assert trace is not None
        counters = self.counters
        stamp = self.timed_cycle
        is_stop_cycle = False
        if self.stop_pc:
            if (r1_ret and r1_pc == self.stop_pc) or (r2_ret and r2_pc == self.stop_pc):
                is_stop_cycle = True
                self.stop_sim_cycle = cycle + 1

        # A slot-1 ROB allocation dispatches slot 2 too if its packet is real.
        if _read(self.dispatch):
            uops = 1
            packet = _read(self.slot2)
            lsb, mask = self.slot2_real
            if packet is not None and (packet >> lsb) & mask:
                uops = 2
            trace.write(
                f'{{"cycle":{stamp},"event":"dispatch","source":"rob","uops":{uops}}}\n'
            )
            counters[f"dispatch_{uops}"] += 1
            counters["dispatched_uops"] += uops
        else:
            counters["dispatch_0"] += 1

        if _read(self.dispatch_stall):
            counters["dispatch_stall_cycles"] += 1
        if _read(self.pipeline_stall):
            counters["pipeline_stall_cycles"] += 1

        retired = int(r1_ret) + int(r2_ret)
        if retired:
            trace.write(
                f'{{"cycle":{stamp},"event":"retire","source":"rob","uops":{retired}}}\n'
            )
            counters[f"commit_{retired}"] += 1
            counters["retired_uops"] += retired
        else:
            counters["commit_0"] += 1

        if _read(self.retire_mispredict):
            counters["branch_mispredicts"] += 1

        for channel, valid, ready, axi_id, address, is_write in self.axi_requests:
            if not _read(valid):
                continue
            if _read(ready):
                trace.write(
                    f'{{"cycle":{stamp},"event":"axi_request","source":"axi",'
                    f'"axi_id":{_read(axi_id) or 0},'
                    f'"address":"0x{_read(address) or 0:08x}",'
                    f'"is_write":{is_write},"bytes":64}}\n'
                )
                counters[f"axi_{channel}"] += 1
            else:
                counters[f"axi_{channel}_backpressure_cycles"] += 1

        for channel, valid, ready, axi_id, response in self.axi_responses:
            if _read(valid) and _read(ready):
                ok = "true" if (_read(response) or 0) == 0 else "false"
                trace.write(
                    f'{{"cycle":{stamp},"event":"axi_response","source":"axi",'
                    f'"axi_id":{_read(axi_id) or 0},"ok":{ok}}}\n'
                )
                counters[f"axi_{channel}"] += 1

        rob_count = _read(self.rob_count)
        if rob_count is not None:
            self.rob_occupancy_sum += rob_count
        sq_count = _read(self.sq_count)
        if sq_count is not None:
            self.sq_occupancy_sum += sq_count

        self.timed_cycle += 1
        if is_stop_cycle:
            self.state = "DONE"
            trace.close()
            self.file = None
            cocotb.log.info(
                "Performance calibration: timed window finished! "
                f"{self.timed_cycle} cycles, {counters['retired_uops']} retired uops "
                f"-> {self.trace_path}"
            )

    def finish(self, uart_text: str) -> None:
        """Close the trace and write the counters and the manifest."""
        if self.file is not None:
            self.file.close()
            self.file = None
        counters = self.counters
        total_timed = self.timed_cycle
        wall_time_s = time.perf_counter() - self.start_wall_time
        retired = counters["retired_uops"]
        pipeline_counters = {
            "cycles": total_timed,
            "retired_uops": retired,
            "ipc": round(retired / max(1, total_timed), 6),
            "wall_time_seconds": round(wall_time_s, 3),
            "simulated_cycles_per_second": int(total_timed / max(1e-9, wall_time_s)),
            "branch_mispredicts": counters["branch_mispredicts"],
            "dispatch_distribution": {
                "cycles_0_uops": counters["dispatch_0"],
                "cycles_1_uop": counters["dispatch_1"],
                "cycles_2_uops": counters["dispatch_2"],
                "total_dispatched_uops": counters["dispatched_uops"],
            },
            "commit_distribution": {
                "cycles_0_uops": counters["commit_0"],
                "cycles_1_uop": counters["commit_1"],
                "cycles_2_uops": counters["commit_2"],
            },
            "stalls": {
                "dispatch_stall_cycles": counters["dispatch_stall_cycles"],
                "pipeline_stall_cycles": counters["pipeline_stall_cycles"],
            },
            "occupancy": {
                "mean_rob_occupancy": round(
                    self.rob_occupancy_sum / max(1, total_timed), 3
                ),
                "mean_sq_occupancy": round(
                    self.sq_occupancy_sum / max(1, total_timed), 3
                ),
            },
            "axi_totals": {
                "ar_requests": counters["axi_ar"],
                "aw_requests": counters["axi_aw"],
                "r_responses": counters["axi_r"],
                "b_responses": counters["axi_b"],
                "ar_backpressure_cycles": counters["axi_ar_backpressure_cycles"],
                "aw_backpressure_cycles": counters["axi_aw_backpressure_cycles"],
            },
        }
        if self.counters_path:
            counters_file = Path(self.counters_path)
            counters_file.parent.mkdir(parents=True, exist_ok=True)
            counters_file.write_text(
                json.dumps(pipeline_counters, indent=2) + "\n", encoding="utf-8"
            )
            cocotb.log.info(f"Wrote pipeline counters to {self.counters_path}")

        if not self.manifest_path:
            return
        manifest = self.manifest(uart_text, wall_time_s)
        manifest_file = Path(self.manifest_path)
        manifest_file.parent.mkdir(parents=True, exist_ok=True)
        manifest_file.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        cocotb.log.info(f"Wrote manifest to {self.manifest_path}")

    def manifest(self, uart_text: str, wall_time_s: float) -> dict[str, Any]:
        """Return the run's manifest; a field that the run cannot tell is left out."""
        total_timed = self.timed_cycle
        program = program_directory(self.app_name)
        file_hashes = {}
        environment = {}
        if program is not None:
            for name in ("sw.bin", "sw.elf", "sw.S", "sw.mem"):
                path = program / name
                if path.is_file():
                    file_hashes[f"{name}_sha256"] = hashlib.sha256(
                        path.read_bytes()
                    ).hexdigest()
            toolchain = elf_comment(program / "sw.elf")
            if toolchain:
                environment["toolchain"] = toolchain
        simulator = " ".join(
            str(part)
            for part in (
                getattr(cocotb, "SIM_NAME", None),
                getattr(cocotb, "SIM_VERSION", None),
            )
            if part
        )
        if simulator:
            environment["simulator"] = simulator
        environment["testbench"] = f"cocotb {cocotb.__version__}"
        ddr = ddr_model_settings(os.environ)
        memory: dict[str, Any] = {
            "tier": os.environ.get("FROST_COCOTB_MEM_CONFIG", "bram"),
            "ddr_model": "axi_behavioral_memory",
            "ddr_latency": ddr["DDR_MODEL_LATENCY"],
            "ddr_latency_jitter": ddr["DDR_MODEL_LATENCY_JITTER"],
            "ddr_reorder": bool(ddr["DDR_MODEL_REORDER"]),
        }
        seed = os.environ.get("FROST_DDR_MODEL_SEED", "").strip()
        if seed:
            memory["ddr_model_seed"] = seed
        seedcrc = re.search(r"seedcrc\s*:\s*(0x[0-9a-fA-F]+)", uart_text)
        crcfinal = re.search(r"\[0\]crcfinal\s*:\s*(0x[0-9a-fA-F]+)", uart_text)
        status = (
            "PASS"
            if "<<PASS>>" in uart_text or "Correct operation validated" in uart_text
            else "UNKNOWN"
        )
        return {
            "benchmark": self.app_name or "program",
            "run_number": self.run_number,
            "wall_time_seconds": round(wall_time_s, 3),
            "simulated_cycles_per_second": int(total_timed / max(1e-9, wall_time_s)),
            "git_commit": self.commit,
            "clock_frequency_hz": round(1e9 / self.clock_period_ns),
            "environment": environment,
            "memory_configuration": memory,
            "artifacts": file_hashes,
            "timed_region": {
                "start_pc": f"0x{self.start_pc:08x}" if self.start_pc else "0x00000000",
                "stop_pc": f"0x{self.stop_pc:08x}" if self.stop_pc else "0x00000000",
                "start_sim_cycle": self.start_sim_cycle,
                "stop_sim_cycle": self.stop_sim_cycle,
                "timed_cycles": total_timed,
            },
            "crc_validation": {
                "seedcrc": seedcrc.group(1) if seedcrc else "unknown",
                "crcfinal": crcfinal.group(1) if crcfinal else "unknown",
                "status": status,
            },
        }

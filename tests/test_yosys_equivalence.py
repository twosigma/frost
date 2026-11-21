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

"""Compare the portable Yosys frontend and yosys-slang on real RTL cuts."""

import json
import os
import re
import shlex
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from slang_frontend import UNROLL_LIMIT, top_cases
from test_run_yosys import YosysRunner


TOP = "platform_top"
RTL_OPTIONS = "-DSYNTHESIS"
CPU = "cpu/hart/cpu_inst"
BACKEND = f"{CPU}/u_tomasulo"
HOME_INSTANCE = "cpu/cluster_memory/gen_coherent_tier.home"

CASES = {
    "soc_top": "soc",
    "tage_history": f"{CPU}/u_tage_history",
    "dmmu": f"{BACKEND}/u_dmmu",
    "axi_mux": "soc/gen_cached_tier.dma_interconnect",
    "branch_predictor": (
        f"{CPU}/if_stage_inst/branch_prediction_controller_inst/branch_predictor_inst"
    ),
    "lq_coherence_port": f"{BACKEND}/u_coherence_port",
    "store_queue": f"{BACKEND}/u_sq",
    "coherence_home_completions": f"{HOME_INSTANCE}/completions",
    "cpu_ooo": CPU,
    "coherence_l1d": "cpu/hart/gen_coherent_tier.hart_cache/l1d",
    "load_queue": f"{BACKEND}/u_lq",
    "coherence_home": HOME_INSTANCE,
}

ELABORATION_SECONDS = 900
LOWERING_SECONDS = 180
PROOF_SECONDS = 420
# These children load simulation images through file tasks or hierarchical writes.
# Only their port declarations are needed at the proof boundary.
IMAGE_MODULES = ("axi_behavioral_memory", "imem_predecode", "tdp_bram_dc_byte_en")

Bit = int | str
Module = dict[str, Any]
FLOP_TYPES = {"$dff", "$adff", "$aldff"}


class UnsupportedModelError(ValueError):
    """The compared netlists fall outside the proof model."""


def run_yosys(
    directory: Path, name: str, commands: list[str], cwd: Path, timeout: int
) -> tuple[int, str]:
    """Save the exact script and full log and return the exit status and log tail."""
    script = directory / f"{name}.ys"
    log = directory / f"{name}.log"
    script.write_text("\n".join(commands) + "\n")
    started = time.monotonic()
    with log.open("wb") as handle:
        try:
            status = subprocess.run(
                ["yosys", "-s", str(script)],
                cwd=cwd,
                stdout=handle,
                stderr=subprocess.STDOUT,
                timeout=timeout,
                check=False,
            ).returncode
        except subprocess.TimeoutExpired:
            handle.write(f"\nProcess timed out after {timeout}s\n".encode())
            status = 124
        handle.write(
            f"\nExit {status}, elapsed {time.monotonic() - started:.2f}s\n".encode()
        )
    with log.open("rb") as handle:
        handle.seek(max(0, log.stat().st_size - 3600))
        return status, handle.read().decode(errors="replace")


def cut_commands(directory: Path, cases: list[str]) -> list[str]:
    """Follow instance paths in both elaborations and expose direct child ports."""
    copy = directory / "copy_cut.tcl"
    copy.write_text(
        "set file [lindex $argv 0]\n"
        "yosys tee -q -o $file select -list-mod @cut\n"
        "set handle [open $file]\n"
        "set module [string trim [read $handle]]\n"
        "close $handle\n"
        "yosys copy $module frost_equiv_cut\n"
    )
    commands = []
    for case in cases:
        commands.append(f"select -set cut {TOP}")
        for instance in CASES[case].split("/"):
            selection = f"*/c:{instance} @cut %i"
            commands.extend(
                [
                    f"select -assert-count 1 {selection}",
                    f"select -set cut {selection} %M",
                ]
            )
        commands.extend(
            [
                "select -assert-mod-count 1 @cut",
                f"dump -n -o {directory / (case + '.instance.il')} @cut",
                f"tcl {copy} {directory / (case + '.module')}",
                "proc -norom frost_equiv_cut",
                "expose -evert frost_equiv_cut/c:*",
                "select -assert-none frost_equiv_cut/t:$paramod* "
                "frost_equiv_cut/t:* frost_equiv_cut/t:$* %d",
                "select frost_equiv_cut",
                f"write_rtlil -selected {directory / (case + '.il')}",
                "select -clear",
                "delete frost_equiv_cut",
            ]
        )
    return commands


def slang_read(slang: Path, root: Path) -> str:
    """Write the generic slang read set with initialized state in the selected modules."""
    (source_unit,) = next(
        case.units
        for case in top_cases(root)
        if case.name == f"synthesis/generic/{TOP}"
    )
    options = (
        "--top",
        TOP,
        "--no-synthesis-define",
        "--no-proc",
        "--best-effort-hierarchy",
        *(f"--blackboxed-module={module}" for module in IMAGE_MODULES),
        f"--unroll-limit={UNROLL_LIMIT}",
        *source_unit.options,
        *source_unit.sources,
    )
    args = slang / "read_slang.f"
    args.write_text(shlex.join(options) + "\n")
    return f"read_slang -f {args}"


def elaborate(directory: Path, cases: list[str]) -> None:
    """Build both frontend views from the repository synthesis filelist."""
    runner = YosysRunner()
    native, slang = directory / "native", directory / "slang"
    for path in (native, slang):
        path.mkdir()

    sources = runner.parse_filelist(runner.filelist)
    defines = " ".join(
        (RTL_OPTIONS, *(f"-I{path}" for path in sorted(runner.include_dirs)))
    )
    sources = runner.convert_nic_sources(sources, native, defines, ELABORATION_SECONDS)
    native_read = [f"read_verilog -sv {defines} {path}" for path in sources]

    for path, commands in (
        (native, native_read),
        (slang, [slang_read(slang, runner.root_dir)]),
    ):
        status, tail = run_yosys(
            path,
            "elaborate",
            [*commands, f"hierarchy -check -top {TOP}", *cut_commands(path, cases)],
            runner.test_dir,
            ELABORATION_SECONDS,
        )
        if status:
            pytest.fail(f"{path.name} elaboration/cut exit {status} ({path}):\n{tail}")


@dataclass(frozen=True)
class FlopBit:
    """A bit of state and the signals/constants controlling its update."""

    data: Bit
    clock: Bit
    clock_polarity: int
    reset: Bit | None
    reset_polarity: int | None
    reset_value: Bit


def flop_bits(module: Module) -> dict[int, FlopBit]:
    """Treat asynchronous set/reset as an asynchronous load of a constant word."""
    state: dict[int, FlopBit] = {}
    for cell in module["cells"].values():
        if cell["type"] not in FLOP_TYPES:
            continue
        connections, params = cell["connections"], cell["parameters"]
        if cell["type"] == "$aldff":
            reset = connections["ALOAD"][0]
            polarity = int(params["ALOAD_POLARITY"], 2)
            values = connections["AD"]
        elif cell["type"] == "$adff":
            reset = connections["ARST"][0]
            polarity = int(params["ARST_POLARITY"], 2)
            values = list(reversed(params["ARST_VALUE"]))
        else:
            reset, polarity = None, None
            values = ["0"] * len(connections["Q"])
        for index, (q, d) in enumerate(
            zip(connections["Q"], connections["D"], strict=True)
        ):
            if not isinstance(q, int) or q in state:
                raise UnsupportedModelError(
                    f"invalid or multiply driven flop Q bit {q}"
                )
            state[q] = FlopBit(
                d,
                connections["CLK"][0],
                int(params["CLK_POLARITY"], 2),
                reset,
                polarity,
                values[index],
            )
    return state


def initial_bits(module: Module) -> dict[int, str]:
    """Record defined initialization by bit, including memory map's word state."""
    values: dict[int, str] = {}
    for net in module["netnames"].values():
        init = net["attributes"].get("init")
        if init is None:
            continue
        for bit, value in zip(net["bits"], reversed(init), strict=True):
            if value == "x":
                continue
            if not isinstance(bit, int) or values.setdefault(bit, value) != value:
                raise UnsupportedModelError(
                    f"invalid or conflicting initial value on bit {bit}"
                )
    return values


def match_state(
    gold: Module,
    gate: Module,
    gold_state: dict[int, FlopBit],
    gate_state: dict[int, FlopBit],
) -> dict[int, int]:
    """Pair state bits one-to-one by public net name and bit position."""
    pairs: dict[int, int] = {}
    inverse: dict[int, int] = {}
    for name, ref in gold["netnames"].items():
        impl = gate["netnames"].get(name)
        if ref["hide_name"] or impl is None or impl["hide_name"]:
            continue
        if (
            ref.get("offset", 0) != impl.get("offset", 0)
            or ref.get("upto", 0) != impl.get("upto", 0)
            or len(ref["bits"]) != len(impl["bits"])
        ):
            continue
        for lhs, rhs in zip(ref["bits"], impl["bits"], strict=True):
            if (
                lhs in gold_state
                and rhs in gate_state
                and (
                    pairs.setdefault(lhs, rhs) != rhs
                    or inverse.setdefault(rhs, lhs) != lhs
                )
            ):
                raise UnsupportedModelError(f"conflicting state aliases at {name}")
    return pairs


def add_port(module: Module, name: str, direction: str, bits: list[Bit]) -> None:
    """Expose the given bit IDs as a port in the JSON netlist."""
    if name in module["netnames"]:
        raise UnsupportedModelError(f"transition port already exists: {name}")
    module["netnames"][name] = {"hide_name": 0, "bits": bits, "attributes": {}}
    module["ports"][name] = {"direction": direction, "bits": bits}


def expose_transition(
    module: Module,
    state: dict[int, FlopBit],
    paired: list[int],
    free: list[int],
    peer_free_count: int,
    *,
    reference: bool,
) -> None:
    """Expose shared paired state and independent state for each design."""
    module["cells"] = {
        name: cell
        for name, cell in module["cells"].items()
        if cell["type"] not in FLOP_TYPES
    }
    for net in module["netnames"].values():
        net["attributes"].pop("init", None)
    # Pad the other design's free inputs with disconnected bits. The miter
    # can then share the interface without ever relating unpaired state.
    last_bit = max(
        (
            bit
            for net in module["netnames"].values()
            for bit in net["bits"]
            if isinstance(bit, int)
        ),
        default=1,
    )
    unused = list(range(last_bit + 1, last_bit + 1 + peer_free_count))
    inputs = paired + (free + unused if reference else unused + free)
    if inputs:
        add_port(module, "frost_state_q", "input", list(inputs))
    if not paired:
        return
    add_port(module, "frost_state_d", "output", [state[bit].data for bit in paired])
    add_port(module, "frost_state_clk", "output", [state[bit].clock for bit in paired])
    add_port(
        module,
        "frost_state_arst",
        "output",
        [reset if (reset := state[bit].reset) is not None else "0" for bit in paired],
    )
    add_port(
        module,
        "frost_state_arst_value",
        "output",
        [state[bit].reset_value for bit in paired],
    )


def paired_transition(gold: Module, gate: Module) -> tuple[int, int, int]:
    """Check paired initial state and turn both designs into combinational transitions."""
    gold_state, gate_state = flop_bits(gold), flop_bits(gate)
    pairs = match_state(gold, gate, gold_state, gate_state)
    gold_init, gate_init = initial_bits(gold), initial_bits(gate)
    if gold_init.keys() - gold_state.keys() or gate_init.keys() - gate_state.keys():
        raise UnsupportedModelError("initialization outside flop state")
    for lhs, rhs in pairs.items():
        ref, impl = gold_state[lhs], gate_state[rhs]
        if (
            ref.clock_polarity != impl.clock_polarity
            or ref.reset_polarity != impl.reset_polarity
        ):
            raise UnsupportedModelError(
                f"different flop controls on paired bits {lhs}, {rhs}"
            )
        if gold_init.get(lhs) != gate_init.get(rhs):
            raise UnsupportedModelError(
                f"different initialization on paired bits {lhs}, {rhs}"
            )
    gold_free = sorted(gold_state.keys() - pairs.keys())
    gate_free = sorted(gate_state.keys() - set(pairs.values()))
    expose_transition(
        gold, gold_state, list(pairs), gold_free, len(gate_free), reference=True
    )
    expose_transition(
        gate,
        gate_state,
        list(pairs.values()),
        gate_free,
        len(gold_free),
        reference=False,
    )
    return len(pairs), len(gold_free), len(gate_free)


def load_cut(directory: Path, work: Path, frontend: str, case: str) -> Module:
    """Lower the module's memories to explicit state and read the result."""
    source = directory / frontend / f"{case}.il"
    derived = source.with_suffix(".module").read_text().strip().lstrip("\\")
    if derived.startswith("$paramod"):
        _, _, derived = derived.partition("\\")
        module_name = derived.partition("\\")[0]
    else:
        module_name = derived.partition("$")[0]
    if module_name != case:
        raise UnsupportedModelError(
            f"{frontend} instance for {case} has type {module_name}"
        )
    model = work / f"{frontend}.json"
    status, tail = run_yosys(
        work,
        f"map_{frontend}",
        [
            f"read_rtlil {source}",
            "opt_clean",
            "check -assert",
            "memory_collect",
            "memory_map -keepdc",
            "dffunmap",
            # Memory mapping can leave undriven leaves for out-of-range read addresses.
            "opt_expr -keepdc -undriven",
            "opt_clean",
            "check -assert",
            f"write_json {model}",
        ],
        work,
        LOWERING_SECONDS,
    )
    if status:
        pytest.fail(f"{case} {frontend} memory/state lowering exit {status}:\n{tail}")
    cut = json.loads(model.read_text())
    return cut["modules"]["frost_equiv_cut"]


def check_interface(gold: Module, gate: Module) -> int:
    """Require identical ports and a separate source for each input bit."""
    signatures = []
    for module in (gold, gate):
        inputs = []
        signature = {}
        for name, port in module["ports"].items():
            direction, bits = port["direction"], port["bits"]
            if direction == "input":
                inputs.extend(bits)
            elif direction != "output":
                raise UnsupportedModelError(
                    f"{name} has unsupported direction {direction}"
                )
            signature[name] = (direction, len(bits))
        if any(not isinstance(bit, int) for bit in inputs) or len(inputs) != len(
            set(inputs)
        ):
            raise UnsupportedModelError("the cut ties together or drives input bits")
        signatures.append(signature)
    if signatures[0] != signatures[1]:
        raise UnsupportedModelError("cut port names, directions or widths differ")
    output_bits = sum(
        width for direction, width in signatures[0].values() if direction == "output"
    )
    if output_bits == 0:
        raise UnsupportedModelError("the cut has no outputs")
    return output_bits


def _logged_frontends(log: Path) -> set[str]:
    """Read the frontend execution headers from this Yosys invocation."""
    header = re.compile(r"^(?:\d+\.)+ Executing ([\w-]+) frontend[.:]")
    with log.open(errors="replace") as lines:
        return {match[1] for line in lines if (match := header.match(line))}


def prove(directory: Path, case: str) -> None:
    """Prove port and transition equality for every paired state and input."""
    routes = ("slang", "native")
    for route, expected in zip(routes, ("SLANG", "Verilog-2005"), strict=True):
        log = directory / route / "elaborate.log"
        observed = _logged_frontends(log)
        if observed != {expected}:
            readers = ", ".join(sorted(observed)) or "none"
            pytest.fail(
                f"Expected only the {expected} frontend in {log}. Observed {readers}."
            )

    work = directory / case
    work.mkdir()
    gold, gate = (load_cut(directory, work, route, case) for route in routes)
    output_bits = check_interface(gold, gate)
    state_bits, gold_free, gate_free = paired_transition(gold, gate)
    models = work / "transition.json"
    witness = work / "counterexample.json"
    models.write_text(json.dumps({"modules": {"gold": gold, "gate": gate}}))
    status, tail = run_yosys(
        work,
        "prove",
        [
            f"read_json {models}",
            "miter -equiv -flatten -make_assert -ignore_gold_x gold gate miter",
            "hierarchy -top miter",
            "check -assert",
            "select -assert-count 1 t:$assert",
            "select -assert-none t:$assume t:$check t:$any*",
            "select -assert-none t:$mem* t:$ff t:$*dff* t:$*latch* t:$sr",
            "opt_merge -keepdc",
            "opt_expr -keepdc",
            "opt_clean",
            # Encode the undefined-bit checks before reducing the Boolean miter.
            "xprop -required -formal -assume-def-inputs",
            "setattr -unset keep",
            "opt_expr -keepdc",
            "opt_merge -keepdc",
            "opt_clean -purge",
            "techmap",
            "opt -fast -keepdc -noff",
            "abc -g simple",
            "opt_clean",
            "check -assert",
            "select -assert-count 1 t:$assert",
            "sat -verify -prove-asserts -set-assumes "
            f"-show-inputs -show-outputs -dump_json {witness} miter",
        ],
        work,
        PROOF_SECONDS,
    )
    if status == 124:
        pytest.fail(
            f"{case}: transition proof inconclusive after {PROOF_SECONDS}s ({work})"
        )
    if witness.exists():
        pytest.fail(f"{case}: transition counterexample in {witness}\n{tail}")
    if status or "SAT proof finished - no model found: SUCCESS!" not in tail:
        pytest.fail(
            f"{case}: transition proof tool error (exit {status}, {work}):\n{tail}"
        )
    print(
        f"{case}: {output_bits} output bits, {state_bits} paired state bits, "
        f"{gold_free}/{gate_free} independent slang/native state bits"
    )


@pytest.fixture(scope="module")
def frontend_cuts(
    request: pytest.FixtureRequest, tmp_path_factory: pytest.TempPathFactory
) -> Path:
    """Share elaboration across the selected cases and keep full proof artifacts."""
    cases = [
        str(item.callspec.params["case"])
        for item in request.session.items
        if isinstance(item, pytest.Function)
        and item.module is request.module
        and item.originalname == "test_yosys_frontend_equivalence"
    ]
    evidence = os.environ.get("FROST_YOSYS_EQUIV_DIR")
    directory = (
        Path(evidence).resolve() if evidence else tmp_path_factory.mktemp("yosys-equiv")
    )
    directory.mkdir(parents=True, exist_ok=True)
    elaborate(directory, cases)
    return directory


@pytest.mark.synthesis
@pytest.mark.parametrize("case", CASES)
def test_yosys_frontend_equivalence(frontend_cuts: Path, case: str) -> None:
    """Prove that both frontends implement the same module transition."""
    prove(frontend_cuts, case)

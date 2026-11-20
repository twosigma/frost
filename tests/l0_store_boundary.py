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

"""Verify the registered SQ/LQ comparison and the models it actually used."""

import hashlib
import json
from pathlib import Path

import sby_config

PAIR = ("l0_store_boundary_twin", "boundary_twin")
REFERENCE_SHA256 = "34b18a80542394839a8821760251fdd9e405ed39b043fffed08577cc8067d01e"

# Digests of the ordered Yosys commands in the registered SBY. Changes to
# either preparation or the all-point proof require an explicit update.
SECTIONS = (
    (
        "gold",
        "design -stash gold",
        "bb7028b713b1669578fa32c8dba329c034433ed34ab492eca7e0d4582aa6a2f1",
    ),
    (
        "gate",
        "design -stash gate",
        "a522f1e7321122b1dd535112b1ade1f9307f6aab507f97f3373b9e737c1cf09d",
    ),
    (
        "point proof",
        "prep -top prim_twin_done",
        "43513fa58c4e8551ebf7092f60b9e87e27a661ff711064fabc770a2f508503e3",
    ),
)


def check_script(cfg: sby_config.TaskConfig, directory: Path) -> None:
    """Require the complete preparation and proof, including the clock and init checks."""
    reference = directory / cfg.files["l0_store_boundary.v"]
    if hashlib.sha256(reference.read_bytes()).hexdigest() != REFERENCE_SHA256:
        raise sby_config.ConfigError("the frozen SQ/LQ reference changed")
    commands = [
        " ".join(command.args)
        for command in cfg.parsed(directory, expand_opening=False)
    ]
    start = 0
    for name, last, digest in SECTIONS:
        if commands.count(last) != 1:
            raise sby_config.ConfigError(f"store boundary {name}: expected one {last}")
        stop = commands.index(last) + 1
        body = "\n".join(commands[start:stop]) + "\n"
        if hashlib.sha256(body.encode()).hexdigest() != digest:
            raise sby_config.ConfigError(
                f"store boundary {name}: command sequence changed"
            )
        start = stop
    if start != len(commands):
        raise sby_config.ConfigError(
            "unexpected commands after the store boundary proof"
        )


def check_model(path: Path) -> None:
    """Require identical ports and twelve state cuts on the free rising clock."""
    modules = json.loads(sby_config.read_checked_text(path))["modules"]
    interfaces = []
    for form in ("gold", "gate"):
        module = modules[form]
        ports = module["ports"]
        interfaces.append(
            [
                (
                    name,
                    p["direction"],
                    len(p["bits"]),
                    p.get("offset", 0),
                    p.get("upto", 0),
                    p.get("signed", 0),
                )
                for name, p in ports.items()
            ]
        )
        inputs = [
            bit
            for p in ports.values()
            if p["direction"] == "input"
            for bit in p["bits"]
        ]
        if any(type(bit) is not int for bit in inputs) or len(set(inputs)) != len(
            inputs
        ):
            raise ValueError(f"{form}: store boundary inputs must be independent")
        for name in ("i_clk", "i_rst_n", "i_flush_all"):
            if ports[name]["direction"] != "input" or len(ports[name]["bits"]) != 1:
                raise ValueError(f"{form}: expected a single free input for {name}")
        if any("init" in net["attributes"] for net in module["netnames"].values()):
            raise ValueError(f"{form}: store boundary has an initial value")

        cells = module["cells"].values()
        dffs = [cell for cell in cells if cell["type"] == "$dff"]
        if sorted(len(cell["connections"]["Q"]) for cell in dffs) != [
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            2,
            3,
            8,
            64,
            64,
        ]:
            raise ValueError(f"{form}: unexpected store boundary registers")
        for cell in dffs:
            if (
                cell["connections"]["CLK"] != ports["i_clk"]["bits"]
                or int(cell["parameters"]["CLK_POLARITY"], 2) != 1
            ):
                raise ValueError(
                    f"{form}: store boundary register does not use rising i_clk"
                )

        # The native reader retains unused function argument and result names.
        # None of their free values may feed a cell or leave the boundary.
        aliases = [
            cell["connections"]["Y"] for cell in cells if cell["type"] == "$anyseq"
        ]
        used = {
            bit
            for cell in cells
            for name, bits in cell["connections"].items()
            if cell["port_directions"][name] == "input"
            for bit in bits
        }
        used.update(bit for p in ports.values() for bit in p["bits"])
        if sorted(map(len, aliases)) != [1, 1, 1, 64, 64, 64] or any(
            used.intersection(bits) for bits in aliases
        ):
            raise ValueError(f"{form}: unexpected free input to the store comparison")
    if interfaces[0] != interfaces[1]:
        raise ValueError("the compiled store boundary ports differ")

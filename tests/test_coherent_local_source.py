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

"""Keep formal completion and retirement excerpts tied to production logic."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def tokens(text: str) -> str:
    """Discard comments and spacing while preserving SystemVerilog tokens."""
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
    return re.sub(r"\s+", "", text)


def test_local_completion_uses_production_excerpts() -> None:
    """Check the SC register, MEM priority, LQ handoff and adapter configuration."""
    source = (
        ROOT / "hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv"
    ).read_text()
    proof = tokens((ROOT / "formal/coherent_local_atomic_formal.sv").read_text())
    boundaries = (
        ("  function automatic logic is_younger(", "\n  endfunction"),
        ("  riscv_pkg::fu_complete_t sc_fu_complete_reg;", "\n`ifndef SYNTHESIS"),
        (
            '  (* dont_touch = "true" *)logic sc_valid_adapter_q;',
            "\n  // Fault-kind echo",
        ),
        ("  riscv_pkg::fu_complete_t mem_fu_to_adapter;", "\n  // LQ yields"),
        ("  assign lq_result_accepted =", "\n\n`ifndef SYNTHESIS"),
        (
            "  fu_cdb_adapter #(\n      .ALLOW_GRANT_REFILL(1'b0),\n      .ALWAYS_GRANTED(1'b1),\n      .INPUT_YOUNGER_PRECOMPUTED(1'b1)\n  ) u_mem_adapter",
            "\n\n  // ===",
        ),
    )
    for start, end in boundaries:
        begin = source.index(start)
        excerpt = source[begin : source.index(end, begin)]
        assert tokens(excerpt) in proof, start


def test_local_retirement_uses_production_gate() -> None:
    """Check protected-head retirement under a pending interrupt/debug drain."""
    source = (ROOT / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv").read_text()
    proof = tokens((ROOT / "formal/coherence_store_boundary_formal.sv").read_text())
    start = source.index(
        "  always_ff @(posedge i_clk) begin\n    if (i_rst || flush_all) trap_mret_commit_hold_q"
    )
    excerpt = source[start : source.index("\n\n", start)]
    assert tokens(excerpt) in proof
    begin = source.index("  assign coherent_head_protected =")
    assert tokens(source[begin : source.index(";", begin) + 1]) in proof
    begin = source.index("  assign coherent_retire_hold =")
    assert tokens(source[begin : source.index(";", begin) + 1]) in proof
    begin = source.index(".i_commit_hold(") + len(".i_commit_hold(")
    assert tokens(source[begin : source.index(")", begin)]) in proof


def test_local_reservation_uses_production_clear_and_discard() -> None:
    """Check successful SC retirement, installation and failed-SC disposal."""
    source = (
        ROOT / "hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv"
    ).read_text()
    proof = tokens((ROOT / "formal/coherent_local_atomic_formal.sv").read_text())
    for signal in (
        "sc_clear_reservation",
        "reservation_snoop_invalidate",
        "sc_discard",
    ):
        begin = source.index(f"  assign {signal} =")
        excerpt = source[begin : source.index(";", begin) + 1]
        assert tokens(excerpt) in proof

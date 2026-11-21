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

"""Project the live ROB store-completion assertion into a standalone cone."""

import argparse
import re
from pathlib import Path

CONFIG = {
    "MEM_RESPONSE_ERRORS": "bit",
    "CACHE_NORMAL_MEMORY": "bit",
    "CACHED_BASE": "longint unsigned",
    "CACHED_SIZE_BYTES": "longint unsigned",
}


def match_one(pattern: str, source: str) -> re.Match[str]:
    """Require one production anchor, including after an RTL refactor."""
    matches = list(re.finditer(pattern, source, re.MULTILINE | re.DOTALL))
    if len(matches) != 1:
        raise ValueError(f"expected one store-completion source match for {pattern!r}")
    return matches[0]


def _module(source: str, name: str) -> str:
    return match_one(rf"^module\s+{name}\b.*?^endmodule\b", source)[0]


def _assignment(source: str, name: str) -> str:
    return match_one(rf"\bassign\s+{name}\s*=[^;]+;", source)[0]


def _declaration(source: str, name: str) -> str:
    return match_one(rf"\blogic(?:\s*\[[^\]]+\])?\s+{name}\s*;", source)[0]


def _config_ports(source: str) -> str:
    for name, kind in CONFIG.items():
        match_one(rf"\bparameter\s+{kind}\s+{name}\s*=", source)
    return "".join(f"    input {kind} {name},\n" for name, kind in CONFIG.items())


def _replace_match(source: str, match: re.Match[str], text: str) -> str:
    return source[: match.start()] + text + source[match.end() :]


def project_helper(source: str) -> str:
    """Retain both generated bodies and select the elaboration with free bounds."""
    header = match_one(
        r"^module\s+coherent_store_pm_select\s*#\((.*?)\)\s*\((.*?)\);",
        source,
    )
    declared_params = re.findall(r"\bparameter\s+[^=]+?\b(\w+)\s*=", header[1])
    if set(declared_params) != CONFIG.keys() or len(declared_params) != len(CONFIG):
        raise ValueError("unexpected coherent_store_pm_select parameters")
    body = source[header.end() : source.rindex("endmodule")]
    pma = match_one(r"\bcoherent_store_pma\s+store_pma\s*\((.*?)\);", body)
    match_one(r"\.o_pma_ok\s*\(\s*o_pma_ok\s*\)", pma[1])
    body = _replace_match(body, pma, "assign o_pma_ok = cut_pma_ok;")
    for name, datatype in (
        ("CachedLimit", "[63:0] "),
        ("CompleteBits", "[31:0] "),
        ("CompleteSplit", ""),
    ):
        param = match_one(rf"\blocalparam\s+[^;=]+?\s+{name}\s*=([^;]+);", body)
        value = re.sub(r"\$clog2\s*\(", "symbolic_clog2(", param[1])
        body = _replace_match(body, param, f"wire {datatype}{name} ={value};")
    branches = match_one(
        r"\bif\s*\(\s*CompleteSplit\s*\)\s*begin\s*:\s*gen_complete_split\s*(.*?)"
        r"\bend\s+else\s+begin\s*:\s*gen_complete_full\s*(.*?)"
        r"\bend\s+(?=assign\s+o_complete\b)",
        body,
    )
    split, full = branches.groups()
    # A generated width is constant in each hardware instance. Instantiate
    # each legal split body and select it with the production width rule.
    body = _replace_match(
        body,
        branches,
        f"""\
  wire [31:0] selected_bits = CompleteBits;
  wire [XLEN-18:1] split_complete;
  wire full_complete;
  for (genvar width = 1; width <= XLEN - 18; width++) begin : gen_complete_split
    localparam int unsigned CompleteBits = width;
    logic complete_without_pma;
    {split}
    assign split_complete[width] = (selected_bits == width) && complete_without_pma;
  end
  if (1) begin : gen_complete_full
    logic complete_without_pma;
    {full}
    assign full_complete = complete_without_pma;
  end
  assign complete_without_pma = CompleteSplit ? (|split_complete) : full_complete;
  """,
    )
    return f"""module store_completion_pm_select_cone (
{_config_ports(header[1])}    input logic cut_pma_ok,{header[2]}
);
  function automatic int unsigned symbolic_clog2(input logic [63:0] value);
    logic [63:0] below;
    below = (value == 0) ? 64'd0 : value - 64'd1;
    symbolic_clog2 = 0;
    for (int bit_index = 0; bit_index < 64; bit_index++)
      if (below[bit_index]) symbolic_clog2 = bit_index + 1;
  endfunction
{body}
endmodule
"""


def project(raw: str) -> str:
    """Keep the cited source assignments, instance connections and assertion."""
    source = re.sub(
        r'"(?:[^"\\]|\\.)*"|/\*.*?\*/|//[^\n]*',
        lambda match: match[0] if match[0].startswith('"') else "",
        raw,
        flags=re.DOTALL,
    )
    wrapper = _module(source, "tomasulo_wrapper")
    connection = match_one(r"\.i_store_complete_valid\s*\((.*?)\)", wrapper)[1].strip()
    if connection != "store_complete_valid":
        raise ValueError("the wrapper's ROB completion input changed")
    instance = match_one(
        r"\bcoherent_store_pm_select\s*#\((.*?)\)\s*store_pm_select\s*\((.*?)\);",
        wrapper,
    )
    assertion = match_one(
        r"(?<=\n)`ifndef SYNTHESIS\s+always_comb\s+"
        r"(assert\s*\(\s*store_complete_valid\b[^;]+;)\s*`endif",
        wrapper,
    )[1]
    assigns = "\n  ".join(
        _assignment(wrapper, name)
        for name in (
            "mem_rs_issue_base",
            "store_page_offset_sum",
            "sq_effective_addr",
            "store_issue_fire",
            "store_complete_translated",
            "store_complete_valid",
        )
    )
    declarations = "\n  ".join(
        _declaration(wrapper, name)
        for name in (
            "mem_rs_issue_base",
            "sq_effective_addr",
            "store_page_offset_sum",
            "store_addr_pma_ok",
            "store_complete_untranslated",
            "store_complete_translated",
            "store_issue_fire",
        )
    )
    helper = project_helper(_module(source, "coherent_store_pm_select"))
    return f"""{helper}
module store_completion_cofactor (
{_config_ports(wrapper)}    input logic i_translation_active,
    input logic store_issue_translated,
    input logic store_issue_untranslated_without_pma,
    input logic cut_pma_ok,
    input logic dmmu_out_is_cmo,
    input logic mem_rs_issue_is_cmo,
    input logic mem_rs_issue_atomic_pma,
    input riscv_pkg::pm_mode_t i_mmu_pm_mode,
    input riscv_pkg::rs_issue_t o_mem_rs_issue,
    input logic [riscv_pkg::XLEN-1:0] dmmu_out_addr,
    output {_declaration(wrapper, "store_complete_valid").rstrip(";")}
);
  {declarations}
  store_completion_pm_select_cone store_pm_select (
      .cut_pma_ok(cut_pma_ok),{instance[1]},{instance[2]}
  );
  {assigns}
  always_comb p_store_completion_equivalent : {assertion}
endmodule
"""


def main() -> None:
    """Emit the cone header in the frontend's private source directory."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "wrapper", type=Path, nargs="?", default=Path("tomasulo_wrapper.sv")
    )
    wrapper = parser.parse_args().wrapper
    Path("store_completion_cofactor_cone.svh").write_text(project(wrapper.read_text()))


if __name__ == "__main__":
    main()

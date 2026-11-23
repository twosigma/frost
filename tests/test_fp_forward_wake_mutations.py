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

"""Check that FP forward-wake and engine-gate proofs reject planted RTL faults."""

import shutil
import subprocess
from collections import deque
from dataclasses import dataclass
from pathlib import Path

import pytest

from sby_config import stage_proof

ROOT = Path(__file__).resolve().parents[1]

# Concrete legal schedules that are subsets of fp_forward_wake_formal's
# witness and delivery inputs, keeping from-reset fault replay short.
_WITNESS_BASIC: tuple[tuple[str, str], ...] = (
    ("(* anyseq *)logic [1:0] delay_choice;", "wire [1:0] delay_choice = 0;"),
    ("(* anyseq *) logic [17:0] schedule_choice;", "wire [17:0] schedule_choice = 0;"),
    ("(* anyseq *) logic pick_vector;", "wire pick_vector = 0;"),
)
_WITNESS_LANE1: tuple[tuple[str, str], ...] = (
    ("(* anyseq *)logic [1:0] delay_choice;", "wire [1:0] delay_choice = 0;"),
    (
        "(* anyseq *) logic [17:0] schedule_choice;",
        "(* anyseq *) logic [4:0] rel_any; wire [17:0] schedule_choice = {5'd0, rel_any, 8'd0};",
    ),
    ("(* anyseq *) logic pick_vector;", "wire pick_vector = 0;"),
)
_WITNESS_FLUSH: tuple[tuple[str, str], ...] = (
    ("(* anyseq *)logic [1:0] delay_choice;", "wire [1:0] delay_choice = 0;"),
    (
        "(* anyseq *) logic [17:0] schedule_choice;",
        "wire [17:0] schedule_choice = 18'd110;",
    ),
    ("(* anyseq *) logic pick_vector;", "wire pick_vector = 0;"),
)
_DELIVERY_FRESH: tuple[tuple[str, str], ...] = (
    ("(* anyseq *)logic [1:0] delay_choice;", "wire [1:0] delay_choice = 0;"),
    (
        "(* anyseq *) logic send_engine, return_memory, release_external, partial, full, hold_commit;",
        "wire send_engine=0, return_memory=0, release_external=0, partial=0, full=0, hold_commit=1;",
    ),
    ("(* anyseq *) logic fp_ready;", "wire fp_ready = 1;"),
    (
        "(* anyseq *) logic [2:0] waits_for_producer;",
        "wire [2:0] waits_for_producer = 0;",
    ),
)
_DELIVERY_ALLOCATE: tuple[tuple[str, str], ...] = (
    ("(* anyseq *)logic [1:0] delay_choice;", "wire [1:0] delay_choice = 0;"),
    (
        "(* anyseq *) logic send_engine, return_memory, release_external, partial, full, hold_commit;",
        "wire send_engine=0, return_memory=0, release_external=0, partial=0, full=0, hold_commit=1;",
    ),
    ("(* anyseq *) logic fp_ready;", "wire fp_ready = cycle >= 10;"),
    (
        "(* anyseq *) logic [2:0] waits_for_producer;",
        "wire [2:0] waits_for_producer = 7;",
    ),
)
_DELIVERY_BUSY: tuple[tuple[str, str], ...] = (
    ("(* anyseq *)logic [1:0] delay_choice;", "wire [1:0] delay_choice = 0;"),
    (
        "(* anyseq *) logic send_engine, return_memory, release_external, partial, full, hold_commit;",
        "wire send_engine=1, return_memory=0, release_external=0, partial=0, full=0, hold_commit=1;",
    ),
    ("(* anyseq *) logic fp_ready;", "wire fp_ready = 1;"),
    (
        "(* anyseq *) logic [2:0] waits_for_producer;",
        "wire [2:0] waits_for_producer = 0;",
    ),
)


@dataclass(frozen=True)
class Mutation:
    """One planted RTL fault and the assertion required to catch it."""

    proof: str
    task: str
    source: str
    original: str
    changed: str
    assertion: str
    selector: str | None = None
    bmc_depth: int | None = None
    delivery_define: bool = False
    harness_edits: tuple[tuple[str, str], ...] = ()


MUTATIONS: dict[str, Mutation] = {
    "engine_op_rs_mismatch": Mutation(
        "fp_engine_op_class",
        "prove",
        "reservation_station.sv",
        "        riscv_pkg::FADD_S, riscv_pkg::FSUB_S, riscv_pkg::FMUL_S, riscv_pkg::FMADD_S,\n"
        "        riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S, riscv_pkg::FADD_D,",
        "        riscv_pkg::FSUB_S, riscv_pkg::FMUL_S, riscv_pkg::FMADD_S,\n"
        "        riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S, riscv_pkg::FADD_D,",
        "p_fp_engine_op_agree",
    ),
    "engine_op_shim_mismatch": Mutation(
        "fp_engine_op_class",
        "prove",
        "fp_shim.sv",
        "      riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D:\n      fp_op_pipelined = 1'b1;",
        "      riscv_pkg::FNMADD_D:\n      fp_op_pipelined = 1'b1;",
        "p_fp_engine_op_agree",
    ),
    "fifo_credit": Mutation(
        "fp_forward_wake",
        "fifo_prove",
        "fp_shim.sv",
        "pipe_busy_q <= !i_flush &&",
        "pipe_busy_q <= 1'b0 &&",
        "p_credit",
        selector="fifo",
        bmc_depth=23,
    ),
    "fifo_write_pointer": Mutation(
        "fp_forward_wake",
        "fifo_prove",
        "fp_shim.sv",
        "fifo_wr_ptr <= fifo_wr_ptr + 1'b1;",
        "fifo_wr_ptr <= fifo_wr_ptr;",
        "p_pointers",
        selector="fifo",
        bmc_depth=23,
    ),
    "fifo_wake_tail": Mutation(
        "fp_forward_wake",
        "fifo_prove",
        "fp_shim.sv",
        "o_fwd_wake_tag   = trk_tag[PipeDepth-2];",
        "o_fwd_wake_tag   = trk_tag[PipeDepth-2] ^ 5'd1;",
        "p_tail_progress",
        selector="fifo",
        bmc_depth=23,
    ),
    "fifo_slot_rank": Mutation(
        "fp_forward_wake",
        "fifo_prove",
        "fp_shim.sv",
        "if (fifo_pop) fifo_rd_ptr <= fifo_rd_ptr + 1'b1;",
        "if (fifo_pop) fifo_rd_ptr <= fifo_rd_ptr + 2'd2;",
        "p_fifo_position",
        selector="fifo",
        bmc_depth=23,
    ),
    "fifo_tag": Mutation(
        "fp_forward_wake",
        "fifo_prove",
        "fp_shim.sv",
        "fifo_tag[fifo_wr_ptr] <= trk_tag[PipeDepth-1];",
        "fifo_tag[fifo_wr_ptr] <= trk_tag[PipeDepth-1] ^ 5'd1;",
        "p_fifo_owned",
        selector="fifo",
        bmc_depth=23,
    ),
    "fifo_data": Mutation(
        "fp_forward_wake",
        "fifo_prove",
        "fp_shim.sv",
        ".i_write_data   ({pipe_flags, pipe_result}),",
        ".i_write_data   ({pipe_flags, pipe_result ^ 64'd1}),",
        "p_fifo_keeps_word",
        selector="fifo",
        bmc_depth=23,
    ),
    "fifo_head_word": Mutation(
        "fp_forward_wake",
        "fifo_prove",
        "fp_shim.sv",
        "o_pipe_complete.value    = fifo_rd_data[riscv_pkg::FLEN-1:0];",
        "o_pipe_complete.value    = fifo_rd_data[riscv_pkg::FLEN-1:0] ^ 64'd1;",
        "p_head_delivers_offer",
        selector="fifo",
        bmc_depth=23,
    ),
    "fifo_pop": Mutation(
        "fp_forward_wake",
        "fifo_prove",
        "fp_shim.sv",
        "assign fifo_pop = fifo_nonempty && (i_pipe_accepted || fifo_head_flushed);",
        "assign fifo_pop = fifo_nonempty && fifo_head_flushed;",
        "p_fifo_service",
        selector="fifo",
        bmc_depth=23,
    ),
    "route_adapter_credit": Mutation(
        "fp_forward_wake",
        "route_prove",
        "tomasulo_wrapper.sv",
        ".i_pipe_accepted (!fp_pipe_adapter_result_pending)",
        ".i_pipe_accepted (1'b0)",
        "p_fifo_accept",
        selector="route_prove",
        bmc_depth=5,
    ),
    "route_grant_word": Mutation(
        "fp_forward_wake",
        "route_prove",
        "tomasulo_wrapper.sv",
        "cdb_arb_in_6 = i_fu_complete_6.valid ? i_fu_complete_6 : fp_pipe_adapter_to_arbiter;",
        "cdb_arb_in_6 = i_fu_complete_6.valid ? i_fu_complete_6 : fp_pipe_adapter_to_arbiter;\n"
        "    cdb_arb_in_6.value[7] ^= 1'b1;",
        "p_grant_registers_offer",
        selector="route_prove",
        bmc_depth=5,
    ),
    "gate_class": Mutation(
        "rs_divide_gate",
        "fp_gate_prove",
        "reservation_station.sv",
        "      stage2_rob_tag <= primary_issue_tag;\n"
        "      stage2_is_divide <= primary_issue_divide;",
        "      stage2_rob_tag <= primary_issue_tag;\n"
        "      stage2_is_divide <= ~primary_issue_divide;",
        "p_fp_gate_payload",
        selector="fp_gate_prove",
        bmc_depth=12,
    ),
    "gate_bank": Mutation(
        "rs_divide_gate",
        "fp_gate_prove",
        "reservation_station.sv",
        "assign dispatch_is_divide   = DIVIDE_ISSUE_GATE && rs_is_divide_op(dispatch_op);",
        "assign dispatch_is_divide   = DIVIDE_ISSUE_GATE && !rs_is_divide_op(dispatch_op);",
        "p_row_opcode",
        selector="fp_gate_prove",
        bmc_depth=12,
    ),
    "gate_engine_busy": Mutation(
        "rs_divide_gate",
        "fp_gate_prove",
        "reservation_station.sv",
        "(i_divider_busy || (stage2_valid && stage2_is_divide))",
        "(stage2_valid && stage2_is_divide)",
        "p_fp_engine_issue_idle",
        selector="fp_gate_prove",
        bmc_depth=12,
    ),
    "wrapper_word_lane0": Mutation(
        "fp_forward_wake",
        "cover",
        "fp_shim.sv",
        "assign o_fwd_value      = pipe_result;",
        "assign o_fwd_value      = pipe_result ^ 64'd1;",
        "p_forward_word_lane0",
        selector="cover",
        bmc_depth=16,
        harness_edits=_WITNESS_BASIC,
    ),
    "wrapper_word_lane1": Mutation(
        "fp_forward_wake",
        "cover",
        "fp_shim.sv",
        "assign o_fwd_value      = pipe_result;",
        "assign o_fwd_value      = pipe_result ^ 64'd1;",
        "p_forward_word_lane1",
        selector="cover",
        bmc_depth=16,
        harness_edits=_WITNESS_LANE1,
    ),
    "wrapper_wake_lane0": Mutation(
        "fp_forward_wake",
        "cover",
        "tomasulo_wrapper.sv",
        "assign fp_rs_cdb_0 = EARLY_LOAD_WAKEUP ? fp_rs_wakeup_0 : cdb_bus_fp_qualified;",
        "always_comb begin\n"
        "    fp_rs_cdb_0 = EARLY_LOAD_WAKEUP ? fp_rs_wakeup_0 : cdb_bus_fp_qualified;\n"
        "    if (fp_fwd_wake_valid) begin\n"
        "      fp_rs_cdb_0.valid = 1'b1;\n"
        "      fp_rs_cdb_0.tag = fp_fwd_wake_tag;\n"
        "    end\n"
        "  end",
        "p_wake_excludes_lane0",
        selector="cover",
        bmc_depth=14,
        harness_edits=_WITNESS_BASIC,
    ),
    "wrapper_wake_lane1": Mutation(
        "fp_forward_wake",
        "cover",
        "tomasulo_wrapper.sv",
        "assign fp_rs_cdb_1 = EARLY_LOAD_WAKEUP ? fp_rs_wakeup_1 : cdb_bus_2_fp_qualified;",
        "logic planted_wake_q;\n"
        "  logic [riscv_pkg::ReorderBufferTagWidth-1:0] planted_tag_q;\n"
        "  always @(posedge i_clk) begin\n"
        "    planted_wake_q <= i_rst_n && fp_fwd_wake_valid;\n"
        "    planted_tag_q <= fp_fwd_wake_tag;\n"
        "  end\n"
        "  always_comb begin\n"
        "    fp_rs_cdb_1 = EARLY_LOAD_WAKEUP ? fp_rs_wakeup_1 : cdb_bus_2_fp_qualified;\n"
        "    if (planted_wake_q) begin\n"
        "      fp_rs_cdb_1.valid = 1'b1;\n"
        "      fp_rs_cdb_1.tag = planted_tag_q;\n"
        "    end\n"
        "  end",
        "p_wake_excludes_lane1",
        selector="cover",
        bmc_depth=14,
        harness_edits=_WITNESS_BASIC,
    ),
    "wrapper_source1": Mutation(
        "fp_forward_wake",
        "cover",
        "reservation_station.sv",
        "      src1_cdb_bypass[i] = issue_cdb_valid && !rs_src1_ready[i] && !src1_cdb_pend[i] &&\n"
        "          (ISSUE_CDB_TAG_SHADOW ? rs_src1_issue_tag[i] : rs_src1_tag[i]) == entry_cdb_tag[i];",
        "      src1_cdb_bypass[i] = issue_cdb_valid && !rs_src1_ready[i] && !src1_cdb_pend[i] &&\n"
        "          (ISSUE_CDB_TAG_SHADOW ? rs_src1_issue_tag[i] : rs_src1_tag[i]) == entry_cdb_tag[i]\n"
        "          || (FWD_WAKE && i_fwd_wake_valid && rs_valid[i] && !rs_src1_ready[i] &&\n"
        "              rs_src1_tag[i] == i_fwd_wake_tag);",
        "p_src1_exclusive",
        selector="cover",
        bmc_depth=14,
        harness_edits=_WITNESS_BASIC,
    ),
    "wrapper_source2": Mutation(
        "fp_forward_wake",
        "cover",
        "reservation_station.sv",
        "      src2_cdb_bypass[i] = issue_cdb_valid && !rs_src2_ready[i] && !src2_cdb_pend[i] &&\n"
        "          (ISSUE_CDB_TAG_SHADOW ? rs_src2_issue_tag[i] : rs_src2_tag[i]) == entry_cdb_tag[i];",
        "      src2_cdb_bypass[i] = issue_cdb_valid && !rs_src2_ready[i] && !src2_cdb_pend[i] &&\n"
        "          (ISSUE_CDB_TAG_SHADOW ? rs_src2_issue_tag[i] : rs_src2_tag[i]) == entry_cdb_tag[i]\n"
        "          || (FWD_WAKE && i_fwd_wake_valid && rs_valid[i] && !rs_src2_ready[i] &&\n"
        "              rs_src2_tag[i] == i_fwd_wake_tag);",
        "p_src2_exclusive",
        selector="cover",
        bmc_depth=14,
        harness_edits=_WITNESS_BASIC,
    ),
    "wrapper_source3": Mutation(
        "fp_forward_wake",
        "cover",
        "reservation_station.sv",
        "        src3_cdb_bypass[i] = issue_cdb_valid && !rs_src3_ready[i] && !src3_cdb_pend[i] &&\n"
        "            rs_src3_tag[i] == entry_cdb_tag[i];",
        "        src3_cdb_bypass[i] = issue_cdb_valid && !rs_src3_ready[i] && !src3_cdb_pend[i] &&\n"
        "            rs_src3_tag[i] == entry_cdb_tag[i]\n"
        "            || (FWD_WAKE && i_fwd_wake_valid && rs_valid[i] && !rs_src3_ready[i] &&\n"
        "                rs_src3_tag[i] == i_fwd_wake_tag);",
        "p_src3_exclusive",
        selector="cover",
        bmc_depth=14,
        harness_edits=_WITNESS_BASIC,
    ),
    "wrapper_consumer_flush": Mutation(
        "fp_forward_wake",
        "cover",
        "reservation_station.sv",
        "rs_rob_tag[free_idx] <= dispatch_rob_tag;",
        "rs_rob_tag[free_idx] <= (FWD_WAKE && dispatch_rob_tag == 3) ? '0 : dispatch_rob_tag;",
        "p_flush_covers_consumers",
        selector="cover",
        bmc_depth=15,
        harness_edits=_WITNESS_FLUSH,
    ),
    "wrapper_fresh_tag": Mutation(
        "fp_forward_wake",
        "cover",
        "fp_shim.sv",
        "trk_tag[0] <= i_rs_issue.rob_tag;",
        "trk_tag[0] <= (i_rs_issue.rob_tag == 1) ? 5'd3 : i_rs_issue.rob_tag;",
        "p_pipeline_fresh_tag",
        selector="cover",
        bmc_depth=10,
        delivery_define=True,
        harness_edits=_DELIVERY_FRESH,
    ),
    "wrapper_no_reallocation": Mutation(
        "fp_forward_wake",
        "cover",
        "reorder_buffer.sv",
        "o_alloc_resp.alloc_tag = tail_idx;",
        "o_alloc_resp.alloc_tag = (tail_idx >= 4) ? 5'd1 : tail_idx;",
        "p_no_reallocation",
        selector="cover",
        bmc_depth=20,
        delivery_define=True,
        harness_edits=_DELIVERY_ALLOCATE,
    ),
    "wrapper_drop_busy": Mutation(
        "fp_forward_wake",
        "cover",
        "tomasulo_wrapper.sv",
        ".i_divider_busy             (fp_engine_gate_busy),",
        ".i_divider_busy             (1'b0),",
        "p_engine_busy_transition",
        selector="cover",
        bmc_depth=12,
        delivery_define=True,
        harness_edits=_DELIVERY_BUSY,
    ),
    "wrapper_spurious_busy": Mutation(
        "fp_forward_wake",
        "cover",
        "tomasulo_wrapper.sv",
        ".i_divider_busy             (fp_engine_gate_busy),",
        ".i_divider_busy             (1'b1),",
        "p_engine_busy_transition",
        selector="cover",
        bmc_depth=6,
        delivery_define=True,
        harness_edits=_DELIVERY_BUSY,
    ),
}


def _replace_once(text: str, old: str, new: str) -> str:
    """Replace an exact single occurrence or fail immediately."""
    assert text.count(old) == 1, old
    return text.replace(old, new, 1)


def _prepare_sby(proof: Path, mutation: Mutation) -> None:
    """Adapt a staged .sby script to check a bounded counterexample for one property."""
    if mutation.selector is None:
        return
    script = proof.read_text(encoding="utf-8")
    tag = mutation.selector
    if tag == "cover":
        script = _replace_once(script, "\ncover: mode cover\n", "\ncover: mode bmc\n")
        script = _replace_once(
            script, "\ncover: depth 22\n", f"\ncover: depth {mutation.bmc_depth}\n"
        )
        script = _replace_once(
            script,
            "\ncover: smtbmc boolector\n",
            "\ncover: smtbmc --nopresat boolector\n",
        )
        script = _replace_once(script, "\ncover: vcd off\n", "\n")
        if mutation.delivery_define:
            script = _replace_once(
                script, "-DFP_FORWARD_WITNESS", "-DFP_FORWARD_DELIVERY"
            )
    else:
        script = _replace_once(script, f"\n{tag}: mode prove\n", f"\n{tag}: mode bmc\n")
        for old_depth in ("depth 3", "depth 4", "depth 8"):
            target = f"\n{tag}: {old_depth}\n"
            if target in script:
                script = _replace_once(
                    script, target, f"\n{tag}: depth {mutation.bmc_depth}\n"
                )
                break
        else:
            raise AssertionError(f"depth line not found for {tag}")
    end = script.index("[files]")
    prop = mutation.assertion
    isolate = (
        f"{tag}: select -assert-min 1 c:*{prop}* t:$check %i r:FLAVOR=assert %i\n"
        f"{tag}: chformal -remove -assert t:$check r:FLAVOR=assert %i c:*{prop}* %d\n"
    )
    if tag == "cover":
        isolate += f"{tag}: chformal -remove -cover\n{tag}: opt_clean -purge\n"
    proof.write_text(script[:end] + isolate + "\n" + script[end:], encoding="utf-8")


@pytest.mark.formal
@pytest.mark.parametrize("case", MUTATIONS)
def test_fp_forward_wake_rejects_fault(tmp_path: Path, case: str) -> None:
    """Each planted RTL fault must fail its target assertion with a saved trace."""
    if shutil.which("sby") is None:
        pytest.skip("SymbiYosys is unavailable")

    mutation = MUTATIONS[case]
    proof = stage_proof(ROOT / "formal" / f"{mutation.proof}.sby", ROOT, tmp_path)
    (candidate,) = (tmp_path / "hw").rglob(mutation.source)
    source = candidate.read_text(encoding="utf-8")
    assert source.count(mutation.original) == 1, (case, candidate)
    candidate.write_text(
        source.replace(mutation.original, mutation.changed), encoding="utf-8"
    )

    if mutation.harness_edits:
        harness = proof.parent / "fp_forward_wake_formal.sv"
        text = harness.read_text(encoding="utf-8")
        for old, new in mutation.harness_edits:
            assert text.count(old) == 1, (case, old)
            text = text.replace(old, new)
        harness.write_text(text, encoding="utf-8")

    _prepare_sby(proof, mutation)

    run = tmp_path / "counterexample"
    logfile = tmp_path / "sby.log"
    with logfile.open("w", encoding="utf-8") as log:
        result = subprocess.run(
            ["sby", "-f", "-d", str(run), proof.name, mutation.task],
            cwd=proof.parent,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=240,
            check=False,
        )
    with logfile.open(encoding="utf-8") as log:
        tail = "".join(deque(log, maxlen=60))
    assert result.returncode == 2 and "DONE (FAIL, rc=2)" in tail, tail
    failures = [line for line in tail.splitlines() if "failed assertion " in line]
    assert any(
        f".{mutation.assertion} at " in line or f".{mutation.assertion} " in line
        for line in failures
    ), tail
    assert (run / "engine_0/trace.yw").stat().st_size > 0

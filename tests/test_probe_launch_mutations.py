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

"""Prove that the probe-launch and C2b boundary proofs reject targeted mutations."""

import shutil
import subprocess
from collections import deque
from pathlib import Path

import pytest

from sby_config import stage_proof

ROOT = Path(__file__).resolve().parents[1]
LOAD_QUEUE = Path("hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv")
SQ_FORWARDING = Path(
    "hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/sq_forwarding_unit.sv"
)
LQ_PROOF = ROOT / "formal/load_queue.sby"
BOUNDARY_PROOF = ROOT / "formal/coherence_store_boundary.sby"


def _run_mutation(
    tmp_path: Path,
    proof_path: Path,
    task: str,
    rel_target: Path,
    original: str,
    mutated: str,
    timeout_s: int,
) -> str:
    if shutil.which("sby") is None:
        pytest.skip("SymbiYosys is unavailable")

    source = (ROOT / rel_target).read_text(encoding="utf-8")
    assert source.count(original) == 1, f"mutation target changed in {rel_target}"

    proof = stage_proof(proof_path, ROOT, tmp_path)
    (tmp_path / rel_target).write_text(
        source.replace(original, mutated), encoding="utf-8"
    )

    logfile = tmp_path / "sby.log"
    with logfile.open("w", encoding="utf-8") as log:
        result = subprocess.run(
            ["sby", "-f", proof.name, task],
            cwd=proof.parent,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=timeout_s,
            check=False,
        )
    assert result.returncode != 0, f"mutation escaped {proof_path.stem}:{task}"
    with logfile.open(encoding="utf-8") as log:
        output = "".join(deque(log, maxlen=60))
    assert "DONE (FAIL," in output, output
    return output


@pytest.mark.formal
def test_probe_zero_hold_removed_rejected(tmp_path: Path) -> None:
    """Removing !probe_zero_hold from probe_launch_permitted fails bmc_probe_launch."""
    output = _run_mutation(
        tmp_path,
        LQ_PROOF,
        "bmc_probe_launch",
        LOAD_QUEUE,
        "        !coh_launch_hold_q && !probe_zero_hold;",
        "        !coh_launch_hold_q;",
        timeout_s=300,
    )
    assert (
        "p_probe_block_inval_no_launch" in output
        or "p_probe_zero_twin_no_launch" in output
    ), output


@pytest.mark.formal
def test_probe_zero_hold_flush_clear_rejected(tmp_path: Path) -> None:
    """Clearing twin_wait_q on a flush fails bmc_probe_launch."""
    output = _run_mutation(
        tmp_path,
        LQ_PROOF,
        "bmc_probe_launch",
        LOAD_QUEUE,
        "      if (!i_rst_n) twin_wait_q <= 1'b0;\n"
        "      else if (zero_push) twin_wait_q <= 1'b1;\n"
        "      else if (twin_push) twin_wait_q <= 1'b0;",
        "      if (!i_rst_n) twin_wait_q <= 1'b0;\n"
        "      else if (zero_push) twin_wait_q <= 1'b1;\n"
        "      else if (twin_push || i_flush_en || i_flush_all) twin_wait_q <= 1'b0;",
        timeout_s=300,
    )
    assert "p_probe_zero_twin_no_launch" in output, output


@pytest.mark.formal
def test_probe_sampled_one_cycle_late_rejected(tmp_path: Path) -> None:
    """Delaying the SQ forwarding match by one cycle fails composed p_load_value."""
    output = _run_mutation(
        tmp_path,
        BOUNDARY_PROOF,
        "bmc_load_same_probe_launch",
        SQ_FORWARDING,
        "  always_ff @(posedge i_clk) begin\n"
        "    if (!i_rst_n) begin\n"
        "      o_sq_all_older_addrs_known <= 1'b0;\n"
        "      o_sq_forward.match         <= 1'b0;\n"
        "      o_sq_forward.can_forward   <= 1'b0;\n"
        "    end else begin\n"
        "      o_sq_all_older_addrs_known <= i_sq_check_capture_valid ? fwd_all_older_known : 1'b0;\n"
        "      o_sq_forward.match         <= i_sq_check_capture_valid ? fwd_found_match : 1'b0;\n"
        "      o_sq_forward.can_forward   <= i_sq_check_capture_valid ? fwd_can_fwd_ordered : 1'b0;\n"
        "    end\n"
        "  end",
        "  logic f_late_match_q;\n"
        "  always_ff @(posedge i_clk) begin\n"
        "    if (!i_rst_n) begin\n"
        "      o_sq_all_older_addrs_known <= 1'b0;\n"
        "      f_late_match_q             <= 1'b0;\n"
        "      o_sq_forward.match         <= 1'b0;\n"
        "      o_sq_forward.can_forward   <= 1'b0;\n"
        "    end else begin\n"
        "      o_sq_all_older_addrs_known <= i_sq_check_capture_valid ? fwd_all_older_known : 1'b0;\n"
        "      f_late_match_q             <= i_sq_check_capture_valid ? fwd_found_match : 1'b0;\n"
        "      o_sq_forward.match         <= f_late_match_q;\n"
        "      o_sq_forward.can_forward   <= i_sq_check_capture_valid ? fwd_can_fwd_ordered : 1'b0;\n"
        "    end\n"
        "  end",
        timeout_s=600,
    )
    assert "p_load_value" in output, output


@pytest.mark.formal
def test_c2b_sector_hold_push_prev_removed_rejected(tmp_path: Path) -> None:
    """Dropping the push_prev_q term from coherent_sector_hold fails C2b boundary BMC."""
    output = _run_mutation(
        tmp_path,
        BOUNDARY_PROOF,
        "bmc_probe_kept_same",
        LOAD_QUEUE,
        "             ((push_prev_q && !holder_valid_prev_q[holder]) ?\n"
        "              staged_push_match_q : staged_holder_match_q[holder]));",
        "             staged_holder_match_q[holder]);",
        timeout_s=600,
    )
    assert "p_sector_hold_exact" in output or "p_no_fatal" in output, output

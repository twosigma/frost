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

"""Check that predictor proofs report a counterexample when candidate RTL changes."""

import shutil
import subprocess
from collections import deque
from dataclasses import dataclass
from pathlib import Path

import pytest

from sby_config import stage_proof

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Mutation:
    """One edit to a proof input and the assertions that can observe it."""

    proof: str
    source: str
    original: str
    changed: str
    assertions: tuple[str, ...]


MUTATIONS = {
    "fetch_slot2_branch": Mutation(
        "predictor_fetch_contract",
        "if_stage.sv",
        "slot2_is_cond_branch_saved_q : slot2_is_cond_branch_live;",
        "slot2_is_cond_branch_saved_q : !slot2_is_cond_branch_live;",
        ("p_s2_branch",),
    ),
    "direction_index": Mutation(
        "tage_predictor_twin",
        "tage_predictor.sv",
        "? i_lookup_fold_index[t] :",
        "? (i_lookup_fold_index[t] ^ 1'b1) :",
        ("p_read_addresses",),
    ),
    "indirect_correct": Mutation(
        "ittage_predictor_twin",
        "ittage_predictor.sv",
        "if (correct_q[t]) begin",
        "if (!correct_q[t]) begin",
        ("p_write_data",),
    ),
    "backing_redirect": Mutation(
        "backing_btb_twin",
        "backing_btb.sv",
        "if (i_reset || sweep_active || i_redirect) begin",
        "if (i_reset || sweep_active) begin",
        ("p_held_select", "p_registers"),
    ),
    "direction_history": Mutation(
        "pd_history_twin",
        "tage_history.sv",
        "base_fold, dir_base_hist[HistLen-1], dir_event_bit, HistLen",
        "base_fold, dir_base_hist[HistLen-1], dir_event_bit ^ (t == 0), HistLen",
        ("p_lookup_dir_fold",),
    ),
    "pd_indirect_class": Mutation(
        "pd_history_twin",
        "pd_stage.sv",
        "pd_itt_eligible_raw_r <= pd_itt_eligible_raw_next;",
        "pd_itt_eligible_raw_r <= pd_itt_eligible_raw_next ^ 2'b01;",
        (
            "p_pd_redirect",
            "p_pd_redirect_slot2",
            "p_pd_redirect_taken",
            "p_pd_redirect_target",
            "p_write_data",
        ),
    ),
}


@pytest.mark.formal
@pytest.mark.parametrize("case", MUTATIONS)
def test_predictor_rejects_difference(tmp_path: Path, case: str) -> None:
    """The registered proof must produce a trace at an affected assertion."""
    if shutil.which("sby") is None:
        pytest.skip("SymbiYosys is unavailable")

    mutation = MUTATIONS[case]
    proof = stage_proof(ROOT / "formal" / f"{mutation.proof}.sby", ROOT, tmp_path)
    (candidate,) = (tmp_path / "hw").rglob(mutation.source)
    source = candidate.read_text(encoding="utf-8")
    assert source.count(mutation.original) == 1, candidate
    candidate.write_text(
        source.replace(mutation.original, mutation.changed), encoding="utf-8"
    )

    run = tmp_path / "counterexample"
    logfile = tmp_path / "sby.log"
    with logfile.open("w", encoding="utf-8") as log:
        result = subprocess.run(
            ["sby", "-f", "-d", str(run), proof.name, "bmc"],
            cwd=proof.parent,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=180,
            check=False,
        )
    with logfile.open(encoding="utf-8") as log:
        tail = "".join(deque(log, maxlen=60))
    assert result.returncode == 2 and "DONE (FAIL, rc=2)" in tail, tail
    failures = [line for line in tail.splitlines() if "failed assertion " in line]
    assert any(
        f".{assertion} at " in line
        for line in failures
        for assertion in mutation.assertions
    ), tail
    assert (run / "engine_0/trace.yw").stat().st_size > 0

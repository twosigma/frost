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

"""Check that the load-queue port-1 AMO exclusivity proof rejects broken fences."""

import shutil
import subprocess
from collections import deque
from dataclasses import dataclass
from pathlib import Path

import pytest

from sby_config import stage_proof

ROOT = Path(__file__).resolve().parents[1]
LOAD_QUEUE = Path("hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv")
LQ_PROOF = ROOT / "formal/load_queue.sby"


@dataclass(frozen=True)
class Mutation:
    """One planted RTL fault and the bounded check used to catch it."""

    original: str
    changed: str
    disable_sq_forward: bool = False
    bmc_depth: int = 12


MUTATIONS: dict[str, Mutation] = {
    "issue_block_amo_dropped_sq_forward": Mutation(
        "      issue_block_q <= older_amo_block_d | vec_hold_d;",
        "      issue_block_q <= vec_hold_d;",
    ),
    "issue_block_amo_dropped_l0_hit": Mutation(
        "      issue_block_q <= older_amo_block_d | vec_hold_d;",
        "      issue_block_q <= vec_hold_d;",
        disable_sq_forward=True,
    ),
    "alloc_amo_dep_dropped": Mutation(
        "          older_amo_dep_d[i][j] = dep_live_src[j] &&\n"
        "              is_older_than(lq_rob_tag[j], lq_rob_tag[i], dep_head_q);",
        "          older_amo_dep_d[i][j] = 1'b0;",
    ),
}


def _replace_once(text: str, old: str, new: str) -> str:
    """Replace an exact single occurrence or fail immediately."""
    assert text.count(old) == 1, old
    return text.replace(old, new, 1)


def _prepare_bmc_sby(proof: Path, mutation: Mutation) -> None:
    """Adapt prove_port1_amo to a from-reset BMC isolated to p_amo_port1_exclusive."""
    script = proof.read_text(encoding="utf-8")
    script = _replace_once(
        script,
        "\nprove_port1_amo: mode prove\n",
        "\nprove_port1_amo: mode bmc\n",
    )
    script = _replace_once(
        script,
        "\nprove_port1_amo: depth 1\n",
        f"\nprove_port1_amo: depth {mutation.bmc_depth}\n",
    )
    if mutation.disable_sq_forward:
        script = _replace_once(
            script,
            "port1_amo: chparam -set DEPTH 4 -set PROBE_LAUNCH 1 "
            "-set ENABLE_SQ_FORWARD_FAST_PATH 1 -set L0_CACHE_DEPTH 8 load_queue",
            "port1_amo: chparam -set DEPTH 4 -set PROBE_LAUNCH 1 "
            "-set ENABLE_SQ_FORWARD_FAST_PATH 0 -set L0_CACHE_DEPTH 8 load_queue",
        )
    end = script.index("[files]")
    isolate = (
        "prove_port1_amo: select -assert-min 1 "
        "c:*p_amo_port1_exclusive* t:$check %i r:FLAVOR=assert %i\n"
        "prove_port1_amo: chformal -remove -assert "
        "t:$check r:FLAVOR=assert %i c:*p_amo_port1_exclusive* %d\n"
    )
    proof.write_text(script[:end] + isolate + "\n" + script[end:], encoding="utf-8")


@pytest.mark.formal
@pytest.mark.parametrize("case", MUTATIONS)
def test_lq_port1_amo_exclusive_rejects_fault(tmp_path: Path, case: str) -> None:
    """Each broken older-AMO fence fails p_amo_port1_exclusive from reset."""
    if shutil.which("sby") is None:
        pytest.skip("SymbiYosys is unavailable")

    mutation = MUTATIONS[case]
    proof = stage_proof(LQ_PROOF, ROOT, tmp_path)
    target = tmp_path / LOAD_QUEUE
    source = target.read_text(encoding="utf-8")
    target.write_text(
        _replace_once(source, mutation.original, mutation.changed), encoding="utf-8"
    )
    _prepare_bmc_sby(proof, mutation)

    run = tmp_path / "counterexample"
    logfile = tmp_path / "sby.log"
    with logfile.open("w", encoding="utf-8") as log:
        result = subprocess.run(
            ["sby", "-f", "-d", str(run), proof.name, "prove_port1_amo"],
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
    assert any(".p_amo_port1_exclusive at " in line for line in failures), tail
    assert (run / "engine_0/trace.yw").stat().st_size > 0


@pytest.mark.formal
def test_lq_port1_amo_prove_rejects_dropped_fence(tmp_path: Path) -> None:
    """The registered prove_port1_amo task rejects dropping older_amo_block_d."""
    if shutil.which("sby") is None:
        pytest.skip("SymbiYosys is unavailable")

    mutation = MUTATIONS["issue_block_amo_dropped_sq_forward"]
    proof = stage_proof(LQ_PROOF, ROOT, tmp_path)
    target = tmp_path / LOAD_QUEUE
    source = target.read_text(encoding="utf-8")
    target.write_text(
        _replace_once(source, mutation.original, mutation.changed), encoding="utf-8"
    )

    run = tmp_path / "induction_fail"
    logfile = tmp_path / "sby.log"
    with logfile.open("w", encoding="utf-8") as log:
        result = subprocess.run(
            ["sby", "-f", "-d", str(run), proof.name, "prove_port1_amo"],
            cwd=proof.parent,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=180,
            check=False,
        )
    with logfile.open(encoding="utf-8") as log:
        tail = "".join(deque(log, maxlen=60))
    assert result.returncode != 0 and "DONE (PASS," not in tail, tail
    assert "failed assertion load_queue.p_amo_port1_" in tail, tail

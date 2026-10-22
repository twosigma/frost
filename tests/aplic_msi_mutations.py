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

"""Check that both MSI verification layers reject five isolated faults.

Run in the frost image: python3 tests/aplic_msi_mutations.py. Each case gets a
small private copy under sim_build/, leaving the working RTL and tests alone.
The cocotb cases run serially and always start with make clean. Logs and XML
reports remain in the printed output directory. This is an explicit diagnostic,
not part of normal pytest collection.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
RTL = Path("hw/rtl/peripherals/aplic/aplic.sv")
MUTATIONS = (
    (
        "supervisor_shift",
        "low_shift = dom ? smsiaddrcfgh_q[22:20] : mmsiaddrcfgh_q[22:20];",
        "low_shift = dom ? mmsiaddrcfgh_q[22:20] : mmsiaddrcfgh_q[22:20];",
    ),
    (
        "retire_at_accept",
        "msi_clear[s] = !msi_valid_q && msi_pick_valid && (msi_pick == MsiSlotBits'(s - 1));",
        "msi_clear[s] = msi_fire && (msi_slot_q == MsiSlotBits'(s - 1)) && msi_live_q;",
    ),
    (
        "unlocked_writes",
        "if (MSI_ENABLE && wr_hit && !wr_dom && !mmsiaddrcfgh_q[31]) begin",
        "if (MSI_ENABLE && wr_hit && !wr_dom) begin",
    ),
    (
        "generator_ie",
        "msi_req[NUM_SOURCES+d] = MSI_ENABLE && gen_busy_q[d];",
        "msi_req[NUM_SOURCES+d] = MSI_ENABLE && gen_busy_q[d] && dom_ie_q[d];",
    ),
    (
        "fixed_priority",
        "msi_rr_q <= (msi_slot_q == MsiSlotBits'(NumMsiSlots - 1)) ? '0 : msi_slot_q + 1'b1;",
        "msi_rr_q <= '0;",
    ),
)


# Restore the pending-episode tracking as well as the old acceptance clear.
# This keeps the mutant's behavior on reconfiguration identical to the old RTL.
RETIRE_AT_ACCEPT_STATE = """
  logic msi_live_q;
  logic [NUM_SOURCES:1] msi_invalidate;
  always_comb begin
    for (int s = 1; s <= NUM_SOURCES; s++)
      msi_invalidate[s] = cfg_clear[s] || (dom_dm_d[deleg_q[s]] != dom_dm_q[deleg_q[s]]) ||
          (latched[s] && wr_clr_ip[s] && wr_active[s]) ||
          (sm_q[s][2] && sm_q[s][1] && dom_dm_q[deleg_q[s]] && !rect[s]) ||
          (level_d[s] && dom_dm_d[deleg_d[s]] && !rect_d[s]);
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) msi_live_q <= 1'b0;
    else if (!msi_valid_q && msi_pick_valid) begin
      msi_live_q <= 1'b1;
      for (int s = 1; s <= NUM_SOURCES; s++)
        if ((msi_pick == MsiSlotBits'(s - 1)) && msi_invalidate[s]) msi_live_q <= 1'b0;
    end else begin
      for (int s = 1; s <= NUM_SOURCES; s++)
        if ((msi_slot_q == MsiSlotBits'(s - 1)) && msi_invalidate[s]) msi_live_q <= 1'b0;
    end
  end
"""


def _copy_case(destination: Path, source: str) -> None:
    files = (
        "tests/Makefile",
        "tests/test_run_cocotb.py",
        "tests/test_run_formal.py",
        "sw/apps/software_registry.py",
        "formal/aplic.sby",
    )
    for name in files:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    shutil.copytree(
        ROOT / "verif",
        destination / "verif",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    (destination / RTL).parent.mkdir(parents=True, exist_ok=True)
    (destination / RTL).write_text(source, encoding="utf-8")


def _run(command: list[str], case: Path, log: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    for key in (
        "SIM_BUILD",
        "COCOTB_RESULTS_FILE",
        "COCOTB_TEST_FILTER",
        "COCOTB_TESTCASE",
        "FROST_VERILATOR_EXTRA_ARGS",
    ):
        env.pop(key, None)
    env.setdefault("NUMBER_OF_CPU_CORES", "8")
    result = subprocess.run(
        command,
        cwd=case / "tests",
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=600,
        check=False,
    )
    (case / log).write_text(result.stdout, encoding="utf-8")
    return result


def _check_case(case: Path, *, mutant: bool) -> None:
    clean = _run(["make", "clean"], case, "clean.log")
    assert clean.returncode == 0, f"clean failed: {case}"
    bench = _run(
        [sys.executable, "test_run_cocotb.py", "aplic_msi"], case, "cocotb.log"
    )
    report_path = case / "tests/results.xml"
    assert report_path.is_file(), (
        f"bench failed without a test report: {case / 'cocotb.log'}"
    )
    report = ElementTree.parse(report_path)
    cases = report.findall(".//testcase")
    assert cases, f"no cocotb test cases: {case}"
    failures = [c for c in cases if c.find("failure") is not None]
    task = "msi_bmc" if mutant else "msi_prove"
    formal = _run(
        [
            sys.executable,
            "test_run_formal.py",
            "--target",
            "aplic",
            "--task",
            task,
            "--verbose",
        ],
        case,
        "formal.log",
    )
    if mutant:
        assert (
            bench.returncode != 0 and failures and "AssertionError" in bench.stdout
        ), f"mutant escaped the bench or failed before an assertion: {case}"
        assert (
            formal.returncode != 0
            and "Assert failed" in formal.stdout
            and "DONE (FAIL" in formal.stdout
        ), f"mutant escaped formal or failed before a counterexample: {case}"
    else:
        assert bench.returncode == 0 and not failures, f"baseline bench failed: {case}"
        assert formal.returncode == 0 and "DONE (PASS" in formal.stdout, (
            f"baseline formal failed: {case}"
        )
    print(
        f"{case.name}: bench {len(failures)}/{len(cases)} failures, formal {'FAIL' if mutant else 'PASS'}",
        flush=True,
    )


def main() -> None:
    """Run the baseline and each isolated mutant, requiring both detectors."""
    if not Path("/.dockerenv").exists():
        raise SystemExit("Run this diagnostic through the frost Docker wrapper.")
    output_root = ROOT / "sim_build"
    output_root.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="aplic_msi_mutations_", dir=output_root))
    print(f"Mutation reports: {output}", flush=True)
    source = (ROOT / RTL).read_text(encoding="utf-8")
    baseline = output / "baseline"
    _copy_case(baseline, source)
    _check_case(baseline, mutant=False)
    for name, original, changed in MUTATIONS:
        assert source.count(original) == 1, f"mutation anchor changed: {name}"
        case = output / name
        mutated = source.replace(original, changed, 1)
        if name == "retire_at_accept":
            anchor = "  function automatic logic [MSI_ADDR_WIDTH-1:0] msi_address"
            assert mutated.count(anchor) == 1
            mutated = mutated.replace(anchor, RETIRE_AT_ACCEPT_STATE + "\n" + anchor, 1)
        _copy_case(case, mutated)
        _check_case(case, mutant=True)
        if name == "retire_at_accept":
            # Check the spec's conservation property independently of the
            # complete transition equation, which also detects this fault.
            transition = (
                "if (f_past_valid && !f_rst_p) assert (ip_q[s] == f_pending[s]);"
            )
            assert mutated.count(transition) == 1
            (case / RTL).write_text(mutated.replace(transition, ""), encoding="utf-8")
            formal = _run(
                [
                    sys.executable,
                    "test_run_formal.py",
                    "--target",
                    "aplic",
                    "--task",
                    "msi_bmc",
                    "--verbose",
                ],
                case,
                "formal_conservation.log",
            )
            assert (
                formal.returncode != 0
                and "Assert failed" in formal.stdout
                and "DONE (FAIL" in formal.stdout
            )
            print(
                "retire_at_accept: spec conservation alone rejects the mutant",
                flush=True,
            )
    print("All five mutants rejected by both cocotb and formal.", flush=True)


if __name__ == "__main__":
    main()

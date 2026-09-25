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

"""Run SymbiYosys targets directly or through pytest.

Runs bounded checks, unbounded proofs and cover searches. Each .sby file in
formal/ is one target and defines its tasks; the properties and assumptions
live in the RTL (under `ifdef FORMAL` or a proof define) or in the harnesses
in formal/.
"""

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

# Path to the formal/ directory relative to the repository root
FORMAL_DIR = "formal"

# Per-task hang backstop in seconds; proof depth is set by each .sby file.
SBY_TASK_TIMEOUT_S = 2400


@dataclass(frozen=True)
class FormalTarget:
    """A formal verification target defined by an .sby file."""

    sby_file: str  # Filename of the .sby file (e.g., "trap_unit.sby")
    description: str  # Human-readable description
    tasks: tuple[str, ...] = ("bmc", "cover")  # Tasks this target supports

    @property
    def name(self) -> str:
        """Short name derived from the .sby filename."""
        return Path(self.sby_file).stem


# Registry of formal verification targets.
# Each entry maps to an .sby file in the formal/ directory.
FORMAL_TARGETS = [
    FormalTarget(
        "sq_live_count.sby",
        "SQ live-count next value equals the reference arithmetic for every allocation outcome",
        tasks=("bmc",),
    ),
    FormalTarget(
        "sq_committed_empty.sby",
        "SQ committed-empty next state equals the reference over reset, full flush and commits",
        tasks=("bmc",),
    ),
    FormalTarget(
        "pc_pending_capture.sby",
        "Pending-prediction valid next state equals the reference clear/set/hold priority",
        tasks=("bmc",),
    ),
    FormalTarget(
        "rs_issue_clear.sby",
        "RS second-port one-hot entry clear equals the reference indexed clear, including the INT station's parameters",
        tasks=("bmc", "bmc4", "bmc8", "bmc16", "bmc32"),
    ),
    FormalTarget(
        "rs_dispatch_defer.sby",
        "Dispatch's six CDB-deferral decisions equal the reference equations, with and without insertion-time repair",
        tasks=("bmc", "bmc_repair"),
    ),
    FormalTarget(
        "control_flow_holdoff.sby",
        "Redirect/reset holdoff next state with late prediction flags equals the reference, without assumptions",
        tasks=("bmc",),
    ),
    FormalTarget(
        "rob_retire_stall.sby",
        "ROB retirement strobes and every perf event equal a reference built from the full serializer stall",
        tasks=("bmc",),
    ),
    FormalTarget(
        "rob_control_next.sby",
        "ROB per-entry done/exception/replay next state matches the reference indexed-write priority",
        tasks=("bmc",),
    ),
    FormalTarget(
        "csr_commit_cofactor.sby",
        "Most CSR storage, both counters and the translation-invalidate request equal a "
        "reference transition model (in the integrated tasks, whenever no trap or xRET "
        "coincides with a CSR commit)",
        tasks=("prove", "prove_integrated", "prove_perf_off"),
    ),
    FormalTarget(
        "pc_increment_holdoff.sby",
        "Both sequential fetch PCs with late redirect/reset holdoff equal the reference for arbitrary selectors",
        tasks=("bmc", "bmc_xilinx"),
    ),
    FormalTarget(
        "rs_raw_pretag.sby",
        "Raw-wakeup pre-issue candidates match the real merged-lane reservation-station winner",
        tasks=("bmc",),
    ),
    FormalTarget(
        "fp_payload_read.sby",
        "FPU payload prefetch addresses match the reference post-pop increment for arbitrary state",
        tasks=("bmc",),
    ),
    FormalTarget(
        "lq_ram_payload.sby",
        "Load-result RAM write enables and every enabled address/data match the reference mux",
        tasks=("bmc", "bmc_forward", "bmc_forward_only", "cover"),
    ),
    FormalTarget(
        "cache_mshr_payload.sby",
        "Per-entry MSHR byte updates match the indexed fill/store merge for arbitrary state",
        tasks=("bmc",),
    ),
    FormalTarget(
        "lq_alloc_mask.sby",
        "Parallel cyclic allocation masks match the reference binary search and room checks",
        tasks=("bmc4", "bmc8", "bmc16"),
    ),
    FormalTarget(
        "lq_response_bypass.sby",
        "Load-response bypass equals full acceptance under its partial-flush guard",
        tasks=("bmc",),
    ),
    FormalTarget(
        "lq_capacity.sby",
        "Grouped free-entry capacity predicates equal the exact count comparisons",
        tasks=("bmc",),
    ),
    FormalTarget(
        "if_direction_payload.sby",
        "Dropping the NOP term from the direction payload select changes no live or replayed non-NOP packet",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "mispredict_capture.sby",
        "While recovery is pending, the captured payload equals a register loaded only on a mispredicted commit",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "line_arbiter_grant.sby",
        "Three-port generic and Xilinx grants match starvation-bounded priority",
        tasks=("bmc", "bmc_xilinx"),
    ),
    FormalTarget(
        "lq_cached_flags.sby",
        "Cached-slot invalidation and LR suppression match the reference next state",
        tasks=("bmc",),
    ),
    FormalTarget(
        "lq_prematch_cofactors.sby",
        "Registered candidate CAM results equal registering the selected-tag CAM",
        tasks=("bmc", "prove", "bmc_raw", "prove_raw"),
    ),
    FormalTarget(
        "lq_cached_hold.sby",
        "Cached-slot hold next state matches the full slot-mask reduction",
        tasks=("bmc",),
    ),
    FormalTarget(
        "prediction_metadata_output.sby",
        "Prediction taken bit equals the reference, and a saved or pending prediction never marks another packet",
        tasks=("bmc",),
    ),
    FormalTarget(
        "c_ext_buffer_next.sby",
        "Compressed buffer slot-2 next-state outcomes match the reference priority",
        tasks=("bmc",),
    ),
    FormalTarget(
        "sq_repair_mmio.sby",
        "Parallel store-repair MMIO classification matches full-width selected address addition",
        tasks=("bmc",),
    ),
    FormalTarget(
        "dmmu_mmio.sby",
        "DMMU parallel MMIO classification and captured next bit match the reference resolution/hold",
        tasks=("bmc",),
    ),
    FormalTarget(
        "rs_alloc_parallel.sby",
        "Parallel first/second free indices equal the serial search for arbitrary occupancy",
        tasks=("bmc4", "bmc8", "bmc16", "bmc32"),
    ),
    FormalTarget(
        "rs_pretag_cofactor.sby",
        "Pre-issue ROB tag computed ahead for each CDB-valid combination equals the reference priority select",
        tasks=("bmc", "bmc_tag_indexed"),
    ),
    FormalTarget(
        "fp_fma_align.sby",
        "FMA alignment shift amounts equal max-exponent subtraction at both precisions",
        tasks=("bmc", "bmc_xlen32"),
    ),
    FormalTarget(
        "lq_tag_order.sby",
        "LQ tag order and full-window boundary match extended arithmetic for arbitrary tags",
        tasks=("bmc",),
    ),
    FormalTarget(
        "ras_checkpoint.sby",
        "RAS next pointer and count equal the reference priority for arbitrary inputs and state",
        tasks=("bmc",),
    ),
    FormalTarget(
        "low_bram_presenter_tier.sby",
        "Low-BRAM fetch responses are the same with and without separate address retargeting",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "rvc_predecode.sby",
        "Full RV64C sideband expansion equals the reference decoder for every parcel",
        tasks=("bmc",),
    ),
    FormalTarget(
        "dispatch_admission.sby",
        "Dispatch admission factoring; queued variant assumes slot-2 valid follows the bundle bit",
        tasks=("bmc", "bmc_queued"),
    ),
    FormalTarget(
        "instr_operand_classifier.sby",
        "ID operand classes - direct fields match classification through the operation decode for all instructions and fault overrides",
        tasks=("bmc",),
    ),
    FormalTarget(
        "decoded_bundle_queue.sby",
        "Decoded bundles: FIFO order against a queue model, a held input consumed once, flush, bypass and wraparound",
        tasks=("prove", "prove_depth2", "cover"),
    ),
    FormalTarget(
        "int_muldiv_shim.sby",
        "Mixed-width MUL/DIV pipeline tracking, completion data alignment, and FIFO credits",
        tasks=(
            "prove",
            "prove_alignment",
            "prove_fallback",
            "prove_alignment_fallback",
            "cover",
        ),
    ),
    FormalTarget(
        "mem_wakeup_merge.sby",
        "Early load wakeup preserves both registered broadcasts and injects at most one exact value",
        tasks=("bmc",),
    ),
    FormalTarget(
        "trap_unit.sby",
        "Trap unit - exception and interrupt handling",
    ),
    FormalTarget(
        "csr_file.sby",
        "CSR file - control/status registers",
        tasks=("bmc", "cover", "bmc_perf_off"),
    ),
    FormalTarget(
        "tlb.sby",
        "TLB - lookup/insert/invalidate conservation in DTLB (16x3) and ITLB (8x2) shapes",
        tasks=("bmc", "cover", "bmc_itlb", "cover_itlb"),
    ),
    FormalTarget(
        "ptw.sby",
        "Page-table walker - walk FSM vs golden PTE classification",
    ),
    FormalTarget(
        "reorder_buffer.sby",
        "Reorder buffer - in-order commit with serialization",
    ),
    FormalTarget(
        "rob_start_cofactor.sby",
        "ROB CSR/xRET starts - no CSR/xRET entry is bypass-eligible, and starts equal the reference equations",
        tasks=("prove",),
    ),
    FormalTarget(
        "register_alias_table.sby",
        "Register alias table - rename mapping with checkpoints",
    ),
    FormalTarget(
        "rs_issue2_selector.sby",
        "Balanced INT-RS second-port selector - serial reference equivalence",
        tasks=("bmc",),
    ),
    FormalTarget(
        "alu_shift_hint.sby",
        "ALU - shift/rotate reference, and equivalence with the captured shift-amount hint",
        tasks=("bmc",),
    ),
    FormalTarget(
        "divider_prefix.sby",
        "Divider - each narrowed stage equals full-width restoring division and "
        "preserves the consumed-prefix bound, at 64 and 32 bits",
        tasks=("bmc", "bmc_xlen32"),
    ),
    FormalTarget(
        "reservation_station.sby",
        "Reservation station - dispatch, wakeup, issue, flush, at the module "
        "defaults and with INT features at eight-entry component capacity",
        tasks=("bmc", "cover", "bmc_tag_indexed", "cover_tag_indexed"),
    ),
    FormalTarget(
        "cdb_arbiter.sby",
        "CDB arbiter - priority arbitration, grant exclusivity, data forwarding",
    ),
    FormalTarget(
        "fu_cdb_adapter.sby",
        "FU CDB adapter - holding register, pass-through, back-pressure, flush",
    ),
    FormalTarget(
        "fu_cdb_adapter_payload_no_refill.sby",
        "FU CDB adapter - simplified payload-write-enable contract",
        tasks=("bmc",),
    ),
    FormalTarget(
        "mul_completion_tag.sby",
        "MUL completion tag - unqualified invalid tag preserves adapter state, "
        "valid results, and exact wrapper arbiter input",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "load_queue.sby",
        "Load queue - allocation/back-pressure, dependency cleanup, memory issue, "
        "router cancellation and owed responses, staged normal AMOs, CDB broadcast",
        tasks=(
            "bmc",
            "cover",
            "prove_pre_match",
            "bmc_no_prepare_busy",
            "cover_no_prepare_busy",
        ),
    ),
    FormalTarget(
        "load_queue_amo_compute.sby",
        "LQ normal-AMO capture/compute/write transitions, reference result, kill, coherence and stalled-write hold",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "data_mem_response_mux.sby",
        "Integrated response mux - arbitrary BRAM/MMIO/cached data and selectors, portable/Xilinx 32/64 bits",
        tasks=("generic32", "generic64", "xilinx32", "xilinx64"),
    ),
    FormalTarget(
        "sc_head_query.sby",
        "SC head coherence comparison - parallel per-entry line match equals selected-address comparison",
        tasks=("bmc",),
    ),
    FormalTarget(
        "coherence_replay_compare.sby",
        "Coherence replay - local line copies preserve phase timing and exact "
        "replay masks; full-width equality at 32, 64 and 66 bits",
        tasks=("prove", "prove_xlen32", "prove_xlen66", "cover"),
    ),
    FormalTarget(
        "coherence_observation.sby",
        "Coherence observation tracking through both commit lanes, flush and tag reuse, "
        "and the registered replay mask, under the load-to-commit timing contract",
        tasks=("prove", "prove_unrestricted", "cover"),
    ),
    FormalTarget(
        "data_mem_request_router.sby",
        "Data-memory router - mandatory device stage, flush cancel, drain/effect containment",
    ),
    FormalTarget(
        "line_port_axi_bridge.sby",
        "Line-port AXI bridge - AXI handshake legality across both resets, id conservation, "
        "stale-response drop",
    ),
    FormalTarget(
        "store_queue.sby",
        "Store queue - live count, write prerequisites, in-flight bounds, forwarding, "
        "committed stores surviving a partial flush",
    ),
    FormalTarget(
        "lq_l0_cache.sby",
        "L0 data cache - 128/256-entry dword cache, fill data and DMA invalidation",
        tasks=("bmc", "cover", "bmc_256", "cover_256"),
    ),
    FormalTarget(
        "branch_prediction_alias.sby",
        "IF branch prediction - base-PC slot alias output equals the generic base+2/base+4 computation",
        tasks=("bmc",),
    ),
    FormalTarget(
        "c_ext_state_cofactor.sby",
        "C-extension buffer state - next state with the handoff factored out equals the reference priority",
        tasks=("bmc",),
    ),
    FormalTarget(
        "immu_page_offset.sby",
        "IMMU translated PA page-offset preservation and visible-output equivalence",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "immu_bare.sby",
        "IMMU Bare bypass - exact PMA/output equivalence at local XLEN 64, 32, and 72",
        tasks=("bmc", "bmc_xlen32", "bmc_xlen72"),
    ),
    FormalTarget(
        "fetch_pc_mux.sby",
        "IF fetch PC - final prediction mux matches the reference one-hot and serial priority equations",
        tasks=("bmc", "bmc_integrated", "bmc_xilinx", "bmc_integrated_xilinx"),
    ),
    FormalTarget(
        "fetch_redirect.sby",
        "IF registered provider redirect - reference selector equation for arbitrary inputs/state",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "pc_register_mux.sby",
        "IF architectural PC - reference nested priority for arbitrary generic inputs",
        tasks=("bmc", "bmc_integrated", "bmc_xilinx", "bmc_integrated_xilinx"),
    ),
    FormalTarget(
        "pc_holdoff_cofactor.sby",
        "IF pending fetch holdoff - arbitrary-state effective-enable factoring matches the reference equations",
        tasks=("bmc",),
    ),
    FormalTarget(
        "pc_holdoff_tag.sby",
        "IF pending prediction holdoff - captured-tag producer induction and reference equations",
        tasks=("prove", "prove_xlen32", "prove_xlen72", "cover"),
    ),
    FormalTarget(
        "btb_tag_compare.sby",
        "BTB tag lookup - grouped equality matches full architectural tags, arbitrary RAM outputs",
        tasks=("bmc", "bmc_small_btb"),
    ),
    FormalTarget(
        "branch_prediction_disable.sby",
        "IF branch prediction - common guards, slot-1/slot-2 factoring, and staged/live disable exclusion",
        tasks=("bmc",),
    ),
    FormalTarget(
        "prediction_handoff.sby",
        "IF pending handoff - slot-2 veto equivalence and pending-state masking",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "prediction_release.sby",
        "IF pending prediction - pending-state masking and holdoff relations",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "prediction_metadata_tracker.sby",
        "IF prediction metadata - validity equivalence and payload provenance",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "fp_add_shim.sby",
        "FP add shim - FP add/compare/classify/sgnj/convert CDB pipeline",
    ),
    FormalTarget(
        "fp_mul_shim.sby",
        "FP mul shim - FP multiply/FMA CDB pipeline",
    ),
    FormalTarget(
        "fp_div_shim.sby",
        "FP div shim - FP divide/sqrt CDB pipeline",
    ),
    FormalTarget(
        "async_fifo.sby",
        "Asynchronous FIFO - occupancy bound, conservative credits, ready margin, "
        "no underflow, in-order delivery of a watched word under free-running "
        "unrelated clocks (multiclock)",
    ),
    FormalTarget(
        "tomasulo_wrapper.sby",
        "Tomasulo integration wrapper (ROB + RAT + RS + CDB arbiter) - commit propagation, "
        "flush composition, FMUL registered done repair",
        tasks=("bmc", "cover", "fmul_repair_bmc"),
    ),
]

# SymbiYosys task types (for CLI --task filter and pytest parametrize)
SBY_TASKS = [
    ("bmc_repair", "Bounded equivalence with insertion-time repair enabled"),
    ("prove_integrated", "Unbounded proof under the integrated interface contract"),
    ("prove_perf_off", "Unbounded proof with profiling counters absent"),
    ("bmc_raw", "Bounded equivalence with eight raw-wakeup candidates"),
    ("prove_raw", "Unbounded equivalence with eight raw-wakeup candidates"),
    ("bmc_forward", "Bounded equivalence with store forwarding enabled"),
    ("bmc_forward_only", "Bounded equivalence with store forwarding and no L0"),
    ("bmc_integrated_xilinx", "Bounded integrated equivalence with Xilinx primitives"),
    ("bmc4", "Bounded local equivalence at depth 4"),
    ("bmc8", "Bounded local equivalence at depth 8"),
    ("bmc16", "Bounded local equivalence at depth 16"),
    ("bmc32", "Bounded local equivalence at depth 32"),
    ("bmc_xilinx", "Bounded equivalence with the Xilinx primitive implementation"),
    ("bmc_queued", "Bounded check with decoded-queue admission contract"),
    ("bmc", "Bounded model checking (prove assertions hold for N cycles)"),
    ("cover", "Cover checking (prove interesting scenarios are reachable)"),
    ("prove", "Unbounded safety proof (ABC PDR or temporal induction)"),
    ("prove_depth2", "Unbounded proof of the two-entry decoded bundle queue"),
    (
        "bmc_no_prepare_busy",
        "Load queue component with busy-port preparation disabled",
    ),
    ("cover_no_prepare_busy", "Load queue reachability without busy-port preparation"),
    ("prove_alignment", "Unbounded mixed-width tracker and physical FU alignment"),
    ("prove_fallback", "Unbounded full-width fallback tracker and credits"),
    ("prove_alignment_fallback", "Unbounded full-width fallback FU alignment"),
    (
        "prove_pre_match",
        "Unrestricted equivalence of split LQ pre-issue match registers",
    ),
    (
        "prove_unrestricted",
        "Unbounded observation cleanup with only the initial-reset assumption",
    ),
    ("generic32", "Arbitrary-input portable response-mux equivalence at 32 bits"),
    ("generic64", "Arbitrary-input portable response-mux equivalence at 64 bits"),
    ("xilinx32", "Arbitrary-input LUT5 response-mux equivalence at 32 bits"),
    ("xilinx64", "Arbitrary-input LUT5 response-mux equivalence at 64 bits"),
    # Parameter-shape variants (chparam'd tops): the ITLB shape of the TLB.
    ("bmc_itlb", "Bounded model checking in the 8-entry 2-port ITLB shape"),
    ("cover_itlb", "Cover checking in the 8-entry 2-port ITLB shape"),
    ("bmc_xlen32", "Bounded checking with a local 32-bit datapath"),
    (
        "bmc_small_btb",
        "Bounded tag comparison with a 16-entry BTB and partial final group",
    ),
    ("bmc_xlen72", "Bounded Bare-output checking with local XLEN 72"),
    ("bmc_integrated", "Bounded checking with the integrated IF handoff parameter"),
    ("prove_xlen32", "Unbounded safety checking with a local 32-bit datapath"),
    (
        "prove_xlen66",
        "Unbounded replay comparison at XLEN 66, including a one-bit final group",
    ),
    ("prove_xlen72", "Unbounded captured-tag checking with local XLEN 72"),
    (
        "fmul_repair_bmc",
        "Bounded model checking with production FMUL dispatch done repair enabled",
    ),
    # INT reservation-station features at eight-entry component capacity;
    # the wrapper target checks the production sixteen-entry station.
    (
        "bmc_tag_indexed",
        "Bounded model checking of INT station features at eight-entry capacity",
    ),
    (
        "cover_tag_indexed",
        "Cover checking of INT station features at eight-entry capacity",
    ),
    ("bmc_perf_off", "Bounded model checking with the profiling counters left out"),
    ("bmc_256", "Bounded checking with a 256-entry L0 cache"),
    ("cover_256", "Cover checking with a 256-entry L0 cache"),
]


def test_formal_target_tasks_are_registered() -> None:
    """Every declared task must participate in CLI and pytest execution."""
    registered = {name for name, _ in SBY_TASKS}
    missing = {
        target.name: sorted(set(target.tasks) - registered)
        for target in FORMAL_TARGETS
        if set(target.tasks) - registered
    }
    assert not missing, f"Formal tasks would be silently skipped: {missing}"


class FormalRunner:
    """Run SymbiYosys tasks from the repository's formal/ directory."""

    def __init__(self) -> None:
        """Initialize runner with paths."""
        self.test_dir = Path(__file__).parent.resolve()
        self.root_dir = self.test_dir.parent
        self.formal_dir = self.root_dir / FORMAL_DIR

        if not self.formal_dir.exists():
            raise FileNotFoundError(f"Formal directory not found: {self.formal_dir}")

    def run_formal(
        self,
        target: FormalTarget,
        task: str,
        capture_output: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        """Run SymbiYosys on a target with a specific task.

        Args:
            target: The formal verification target to run.
            task: SymbiYosys task name (e.g., "bmc", "cover").
            capture_output: If True, capture stdout/stderr. If False, stream to console.

        Returns:
            CompletedProcess with results.
        """
        sby_path = self.formal_dir / target.sby_file
        if not sby_path.exists():
            raise FileNotFoundError(f"SBY file not found: {sby_path}")

        cmd = ["sby", "-t", "-f", str(sby_path), task]

        if capture_output:
            return subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=self.formal_dir,
                timeout=SBY_TASK_TIMEOUT_S,
            )
        else:
            return subprocess.run(
                cmd,
                cwd=self.formal_dir,
                timeout=SBY_TASK_TIMEOUT_S,
                text=True,
            )

    def check_for_errors(
        self, result: subprocess.CompletedProcess[str]
    ) -> tuple[bool, list[str]]:
        """Check formal verification output for errors.

        Returns:
            Tuple of (has_error, error_lines).
        """
        has_error = False
        error_lines = []

        output = (result.stdout or "") + (result.stderr or "")

        if "DONE (FAIL" in output:
            has_error = True
            for line in output.splitlines():
                if "Assert failed" in line or "FAIL" in line:
                    error_lines.append(line.strip())

        # A "DONE (ERROR" line means sby itself failed (syntax error, missing
        # file) rather than a property failing.
        if "DONE (ERROR" in output:
            has_error = True
            for line in output.splitlines():
                if "ERROR" in line:
                    error_lines.append(line.strip())

        if result.returncode != 0:
            has_error = True
            if not error_lines:
                error_lines.append(f"sby exited with code {result.returncode}")

        return has_error, error_lines

    def parse_results(self, result: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        """Parse SymbiYosys output for summary information.

        Returns:
            Dict with keys: passed, status, details, and elapsed (only when
            sby printed an elapsed-time line).
        """
        output = (result.stdout or "") + (result.stderr or "")
        info: dict[str, Any] = {
            "passed": result.returncode == 0,
            "status": "UNKNOWN",
            "details": [],
        }

        for line in output.splitlines():
            line = line.strip()
            if "DONE (PASS" in line:
                info["status"] = "PASS"
            elif "DONE (FAIL" in line:
                info["status"] = "FAIL"
            elif "DONE (ERROR" in line:
                info["status"] = "ERROR"
            elif "Assert failed" in line:
                info["details"].append(line)
            elif "reached cover statement" in line:
                info["details"].append(line)
            elif "Elapsed clock time" in line:
                info["elapsed"] = line

        return info


# ===========================================================================
# Pytest integration
# ===========================================================================


@pytest.mark.formal
class TestFormalVerification:
    """Formal verification tests using SymbiYosys."""

    def test_sby_installed(self) -> None:
        """Test that SymbiYosys is installed and available."""
        try:
            result = subprocess.run(
                ["sby", "--version"], capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                pytest.fail(
                    "sby (SymbiYosys) not found - required for formal verification tests"
                )
        except FileNotFoundError:
            pytest.fail("sby (SymbiYosys) not installed - required for formal tests")
        except subprocess.TimeoutExpired:
            pytest.fail("sby version check timed out")

    @pytest.mark.parametrize(
        "target,task_name,task_description",
        [
            (target, task_name, task_desc)
            for target in FORMAL_TARGETS
            for task_name, task_desc in SBY_TASKS
            if task_name in target.tasks
        ],
        ids=[
            f"{target.name}_{task_name}"
            for target in FORMAL_TARGETS
            for task_name, _ in SBY_TASKS
            if task_name in target.tasks
        ],
    )
    def test_formal(
        self,
        target: FormalTarget,
        task_name: str,
        task_description: str,
        capsys: Any,
    ) -> None:
        """Run formal verification for a specific target and task."""
        try:
            subprocess.run(["sby", "--version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            pytest.fail("sby (SymbiYosys) not installed - required for formal tests")

        runner = FormalRunner()

        with capsys.disabled():
            print(f"\nRunning formal {task_name}: {target.description}...")

        try:
            result = runner.run_formal(target, task_name, capture_output=True)
            has_error, error_lines = runner.check_for_errors(result)
            info = runner.parse_results(result)

            with capsys.disabled():
                if has_error:
                    print(f"\nFormal {task_name} for {target.name} FAILED:")
                    for line in error_lines:
                        print(f"  {line}")
                else:
                    elapsed = info.get("elapsed", "")
                    print(
                        f"\nFormal {task_name} for {target.name} PASSED"
                        f"{' (' + elapsed + ')' if elapsed else ''}"
                    )

            if has_error:
                error_msg = (
                    f"Formal {task_name} for {target.name} failed:\n"
                    + "\n".join(error_lines)
                )
                pytest.fail(error_msg)

        except subprocess.TimeoutExpired:
            pytest.fail(
                f"Formal {task_name} for {target.name} timed out after "
                f"{SBY_TASK_TIMEOUT_S // 60} minutes"
            )
        except Exception as e:
            pytest.fail(
                f"Unexpected error during formal {task_name} for {target.name}: {e}"
            )


# ===========================================================================
# Command-line interface for standalone execution
# ===========================================================================


def main() -> int:
    """Run formal verification from command line."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Run SymbiYosys formal verification for FROST",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                           # Run every target's declared tasks
  %(prog)s --target trap_unit        # Run specific target
  %(prog)s --task bmc                # Run only the bmc task
  %(prog)s --verbose                 # Show full sby output
  %(prog)s --list-targets            # List available targets/tasks and exit

This script can also be run via pytest:
  pytest test_run_formal.py                              # Run all formal tests
  pytest test_run_formal.py -k bmc                       # Run only BMC tests
  pytest test_run_formal.py -k cover                     # Run only cover tests
""",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Show full sby output"
    )
    parser.add_argument(
        "--list-targets",
        action="store_true",
        help="List available formal targets and supported tasks, then exit",
    )
    parser.add_argument(
        "--target",
        "-t",
        default=None,
        choices=[t.name for t in FORMAL_TARGETS],
        help="Run a specific target (default: all)",
    )
    parser.add_argument(
        "--task",
        default=None,
        choices=[t[0] for t in SBY_TASKS],
        help="Run a specific task type (default: all)",
    )

    args = parser.parse_args()

    if args.list_targets:
        print("Available formal targets (from FORMAL_TARGETS):")
        for target in FORMAL_TARGETS:
            print(
                f"  {target.name:20} tasks={','.join(target.tasks):15} - {target.description}"
            )
        print("\nSupported tasks:")
        for task_name, task_desc in SBY_TASKS:
            print(f"  {task_name:8} - {task_desc}")
        return 0

    try:
        result = subprocess.run(
            ["sby", "--version"], capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            print("Error: sby (SymbiYosys) not found or failed to run")
            return 1
        print(f"Found: {result.stdout.strip()}")
    except FileNotFoundError:
        print("Error: sby (SymbiYosys) is not installed or not in PATH")
        return 1

    runner = FormalRunner()

    targets = FORMAL_TARGETS
    if args.target:
        targets = [t for t in FORMAL_TARGETS if t.name == args.target]

    tasks = SBY_TASKS
    if args.task:
        tasks = [(n, d) for n, d in SBY_TASKS if n == args.task]

    failed = []
    passed = 0
    for target in targets:
        for task_name, task_desc in tasks:
            if task_name not in target.tasks:
                continue
            test_id = f"{target.name}:{task_name}"
            try:
                print(f"\n{'=' * 60}")
                print(f"Formal {task_name}: {target.description}")
                print(f"{'=' * 60}")

                result = runner.run_formal(
                    target, task_name, capture_output=not args.verbose
                )
                has_error, error_lines = runner.check_for_errors(result)

                if not args.verbose:
                    output = (result.stdout or "") + (result.stderr or "")
                    for line in output.splitlines():
                        if any(
                            kw in line
                            for kw in [
                                "DONE",
                                "Assert failed",
                                "reached cover",
                                "Status:",
                                "Elapsed",
                            ]
                        ):
                            print(f"  {line.strip()}")

                if has_error:
                    print(f"\n{test_id} FAILED")
                    for line in error_lines:
                        print(f"  {line}")
                    # Show full output on failure for debugging
                    if not args.verbose:
                        full_output = (result.stdout or "") + (result.stderr or "")
                        if full_output.strip():
                            print("\n  Full output:")
                            for line in full_output.strip().splitlines()[-20:]:
                                print(f"    {line}")
                    failed.append(test_id)
                else:
                    print(f"\n{test_id} PASSED")
                    passed += 1

            except subprocess.TimeoutExpired:
                print(f"\n{test_id} TIMEOUT ({SBY_TASK_TIMEOUT_S // 60} minutes)")
                failed.append(test_id)
            except Exception as e:
                print(f"\n{test_id} ERROR: {e}")
                failed.append(test_id)

    # Summary
    total = passed + len(failed)
    print(f"\n{'=' * 60}")
    print("FORMAL VERIFICATION SUMMARY")
    print(f"{'=' * 60}")
    print(f"Passed: {passed}/{total}")
    if failed:
        print(f"Failed: {', '.join(failed)}")
        return 1
    else:
        print("All formal verification targets passed!")
        return 0


if __name__ == "__main__":
    sys.exit(main())

# Front-end direction decision: parcel-queue replacement vs. incremental 2-wide

Status: **DECISION — stay on `improve_x3_timing`; shelve the parcel-queue front end.**
Date: 2026-07-05. Reviewers: Claude (Opus 4.8, the implementing session) and an
independent Codex GPT-5.5 (xhigh) review. Both converged on the same call.

This record exists because two divergent lines of front-end work were produced by
the same autonomous session, and it was not obvious which one to carry forward.
It is a standalone file: cherry-pick it onto whichever branch becomes canonical.

## 1. What diverged

Both branches share the common ancestor **`1da4747`** ("upgrade verilator
5.046→5.050", on `origin/main`).

- **Branch A — `improve_x3_timing`** (tip `678dd57`, 18 commits). Incremental
  perf/timing work on the **existing** front end + backend. Front end: `3f512a2`
  "form 2-wide bundles behind native 32-bit slot-1 instructions" adds 2-wide
  fetch to the existing `instruction_aligner`/`pc_reg` datapath. Backend:
  dual-issue INT reservation station (`ed41960`), symmetric lane-1 CDB wakeup
  (`3d1ff4f`), SQ→LQ store-to-load forwarding (`cf361d4`/`8a6060a`/`dfce253`),
  retire correctly-predicted branch at ROB head+1 (`c3f6513`), x3 post-opt timing
  (`055601e`). **This is the active mainline.**

- **Branch B — `worktree-parcel-queue-stage2-design`** (tip `a5cb9db`, 11
  commits). A **full front-end replacement**: `parcel_fill_engine` → FWFT
  `parcel_queue` → `parcel_consume_engine`, swapping `if_stage` → `if_stage_stage2`
  in `cpu_ooo`. Rationale in `PARCEL_QUEUE_DESIGN.md` — it removes the
  pending-prediction / `instruction_aligner` / `pc_reg` / `c_ext_state` /
  `prediction_metadata_tracker` machinery "by construction."

**The mechanical problem:** Branch B was branched from `1da4747` (main), **not**
from Branch A, even though A was already 18 commits ahead when B was created. So B
never contained A's backend/timing work, and the two never saw each other. Only
**3 files** overlap between the two diffs vs. the ancestor: `cpu_ooo.sv`,
`riscv_pkg.sv`, `tests/test_run_cocotb.py`. Everything else in B is new files.
Nothing was pushed; A is untouched.

## 2. Validation state at decision time

Branch B was brought up and is **coremark-CRC-validated** (crcfinal `0xe714`,
"Correct operation validated", both runs); also passes `hello_world`,
`c_ext_test`, `branch_pred_test`. Four integration bugs were found and fixed
during bring-up (see B's git log / the memory ledger): a 32-bit branch wrongly
leading a 2-wide bundle (both the e0 and e1 queue entries), the post-flush holdoff
squashing the real redirect target, and a RAS FWFT combinational loop.

Branch B has **one open regression: `call_stress` Test 3 (nested compressed
calls) deadlocks.** The old front end (A's base) passes it. See §4 — this turned
out to be the most useful thing B produced.

## 3. The decision and why

**Continue on `improve_x3_timing`. Shelve the parcel-queue branch as a
documented experiment and a hedge — do not finish it as a replacement now.**

Reasoning:

1. **The performance case for B is already captured by A, and it's small.** A's
   `3f512a2` ships the same 2-wide fetch B's design targets (native-control–
   excluded slot-1 leading, NEXT_LO/NEXT_HI slot-2 positions, slot-2 lookup at
   `pc_reg + slot-1 size`). A's own measurement: 2-wide IF deliveries 26%→46%,
   dispatch fire-2 26%→47%, but total CoreMark cycles only **309,643 → 308,365
   (−0.41%)**, and the commit says plainly: *"cycle time is still capped by the
   memory-load head-wait wall."* Fetch width is not the bottleneck.

2. **B's founding premise is too strong.** `PARCEL_QUEUE_DESIGN.md` §1 argues "no
   acceleration of pairing or advance can ship under the existing
   prediction-application machinery." A **literally disproves** that by shipping
   2-wide pairing on that machinery, CoreMark-clean. B is therefore **not a
   prerequisite** for the 2-wide win. It is a **hedge for the more ambitious
   direction** — the stage-1 fetch-capture-array (FCA) and metadata cleanup. The
   parked FCA branch (`5b4d35f`, parent = A's tip `678dd57`) *did* fail CoreMark
   CRC when it used captured words beyond the live window; that failure — not
   plain 2-wide — is what motivated the from-scratch queue. That ambition is real
   but not currently on the critical path.

3. **B's cost is high and its state is behind.** It is WIP with an open liveness
   deadlock; it lacks A's 18 backend/timing commits (dual-issue INT, CDB wakeup,
   SQ-forwarding — the *actual* IPC levers); it needs a rebase onto A (3-file
   conflict) and re-validation on A's newer backend; and it still owes the B3b
   straddle carry + B4 timing work. Its remaining unique value is **structural /
   maintainability** (deleting the fragile pending-prediction machinery), not
   performance.

## 4. The genuinely useful output of B: a latent Branch-A bug

The `call_stress` deadlock is **not just a B artifact — it is a latent liveness
bug on Branch A's backend that B's deeper speculation merely exposes.** Both
reviewers found it independently (Claude by debugging B; Codex by reading A's
RTL):

- The load queue's ROB-head anti-starvation override **excludes MMIO loads** —
  the `!lq_is_mmio[i]` guard in the head-priority scan
  (`load_queue/lq_issue_selector.sv`, the `head_mem_stored_phys` loop; ~L254–268
  on B, ~L274–283 on A).
- The single `sq_check` staging slot can be occupied by a **younger** load
  (`load_queue/load_queue.sv`, the `sq_check_pending` path; ~L944–949 on A).

So a ROB-head **MMIO** load with a known address can be starved indefinitely
behind a younger staged load — exactly the observed shape: head pinned at the
UART TX-ready poll `lw UART_TX_STATUS@0x1b0`, `rob_count=31`, `sq_count=8`, the
branch that would squash the wrong path waiting on that load's result → circular
deadlock. On A the incremental front end just never speculates deep enough to
trip it; that's luck, not a guarantee.

**Action:** turn `call_stress` into an A-side backend liveness test and fix the
LQ/SQ progress guarantee. Repro (on B):
`cd tests && make clean && FROST_WEDGE_MONITOR=1 FROST_WEDGE_DUMP_INTERVAL=40000 ./test_run_cocotb.py call_stress`
(head stuck at pc `0x1b0`). Fix sketch (Codex): fold head MMIO into the explicit
head-priority path; allow a ROB-head load to evict a younger staged load; assert
a ROB-head load with a known address issues within a bounded number of cycles
when the bus is free.

## 5. The real perf lever: the memory-load head-wait wall

Both A's own data and B's dead-end point here. Attack it on A using the existing
counters: `HEAD_LOAD_ADDR_PENDING`, `SQ_DISAMBIG`, `BUS_BLOCKED`, `CDB_WAIT`,
`POST_LQ`, and the SQ-check staging sub-buckets. Start with the bounded-progress
fix in §4 (it removes a pathological tail and hardens correctness), then work the
measured buckets: shorten the SQ-check launch/capture pipe and the post-LQ/CDB
path for head loads; keep tuning store-drain/forwarding only where counters show
it still blocks head loads.

## 6. What to salvage from B regardless

- **Keep** `PARCEL_QUEUE_DESIGN.md` and the stage-1 FCA postmortem — they are a
  correct analysis of the two-walker / pending-prediction bug class and remain the
  reference if the old front end ever becomes the blocker.
- **Keep** this decision record and the `call_stress` root cause (§4).
- The 4 B integration fixes are mostly B-local. The one cross-cutting rule —
  "a native BRANCH/JAL/JALR slot-1 cannot lead a 2-wide bundle" — is worth an
  audit on A, though A already encodes it (`riscv_pkg::imem_native_control` +
  `AllowsSlot2After`).

## 7. Git state (for whoever consolidates)

- Nothing pushed. A (`improve_x3_timing`) untouched at `678dd57`.
- B (`worktree-parcel-queue-stage2-design`) at `a5cb9db` (WIP-tagged commit).
- Common ancestor `1da4747`. To revisit B later: `git rebase --onto
  improve_x3_timing 1da4747 worktree-parcel-queue-stage2-design` (3-file
  conflict: `cpu_ooo.sv`, `riscv_pkg.sv`, `tests/test_run_cocotb.py`), then
  re-run the ladder to coremark and fix `call_stress`.
- **Recommended consolidation:** keep working on A; leave B's branch/worktree in
  place as the shelved experiment. No rebase/merge needed unless/until the parcel
  queue is revived.

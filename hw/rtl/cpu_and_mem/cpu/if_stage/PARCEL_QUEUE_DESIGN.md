# Parcel Queue — Stage 2 Design

Status: **DESIGN v2** (no RTL yet). v1 was adversarially reviewed by a
five-lens panel (bug-class replay, downstream contract, cycle accuracy,
timing/physical, completeness) with independent verification of HIGH-severity
findings; the confirmed findings are folded in below and recorded in §10.

Prerequisite reading: the fetch-capture-array (stage 1) forensic ledger and the
parked branch `fca-parcel-queue-stage1-wip` (commit 5b4d35f, do not merge).

This document specifies the stage-2 front-end redesign mandated by the stage-1
postmortem: **queue prediction metadata with the parcels and decouple the fetch
ask/serve stream from `pc_reg`**. Stage 1 proved the data-path value of holding
fetched words beyond the live window (every byte-check clean across ~7M
delivered packets) and proved that no acceleration of pairing or advance can
ship under the existing prediction-application machinery: any change to the
ask/serve lead arms stale-at-birth pending predictions whose land-on-branch
`pc_reg`-mux arm re-executes committed instructions (the coremark matrix-CRC
failure), and six containment shapes each broke a different load-bearing flow.

## 1. The root defect being removed

The current front end runs **two coupled walkers**:

- `o_pc` — the ask walker. Advances bundle-by-bundle using sizes decoded from
  the served window; steered immediately by BTB slot-1 hits (looked up at the
  ask address), slot-2 hits, RAS, PD redirect, and backend redirects
  (`pc_controller.sv:686-739`).
- `o_pc_reg` — the instruction walker. Nominally one step behind `o_pc`, it is
  the packet PC and the aligner's frame of reference.

Everything fragile in the front end is reconciliation between the two:

| Machinery | Purpose | Failure class it hosts |
|---|---|---|
| `sel_prediction_r` (1-registered-cycle application) | apply prediction to `pc_reg` a cycle after fetch redirected | the application-lag root cause |
| `pending_prediction_*` (~30 signals, `pc_controller.sv:332-681`) | `pc_reg` more than one step behind at prediction time | stale-at-birth arming; the unguarded land-on-branch yank (`pc_controller.sv:777-780`) |
| `pim` / `pim32` carve-outs + `carve_out_engaged_q` | stop the fetch-holdoff from squashing correct-path predecessors | the linux_boot instruction-skip (bug 5); residual +6/+8-lag hole is ledgered and STILL OPEN today |
| fetch-holdoff / `use_pending` handoff | squash wrong-path cycles between arm and application | transition-cycle double delivery (deterministic at 8028b5ac in linux_boot) |
| served-window guard + resteer | detect F drifting outside `{W, W±1}` | bug 2 (F=W+1-no-buffer), bug 4 (three consumers, different contracts) |
| aligner parity XOR `bank_sel_r ^ pc_reg[2]` | select which window half is `word(W)` | bug 1 (F=W−1 spanning corruption): a 1-bit code for a multi-valued offset |
| `c_ext_state` buffer + landing bookkeeping | the hand-rolled ±1-word tolerance | halfword-target catch-up holdoffs |
| stall `_sc` replay machinery (~25 saved registers) | re-present the pre-stall bundle after BRAM drifted | replay double-delivery (bug 3) |
| `prediction_metadata_tracker` | keep metadata glued to its instruction across stalls/handoffs | metadata-on-wrong-instruction; the cjpeg `redirect_kills_prediction_metadata` scope hack |

The structural fix: make the predicted-path instruction stream a **queue**.
The fill side owns fetch and binds prediction metadata to instructions at
enqueue; the consume side reads instructions in order. There is no second
walker, so there is nothing to reconcile, no application lag, and no arm/handoff
window in which state can go stale.

The panel review sharpened the claim: queue-resident metadata is immutable,
but **pre-enqueue in-flight state is not automatically safe** — every piece of
fill-side in-flight state (owed asks, the prediction-binding pipe, the
straddle carry of §2.6) must be epoch-governed, or the stale-at-birth class
reappears upstream of the queue (§10, finding 1). Epoch discipline is
therefore a first-class invariant of this design, not an implementation
detail.

## 2. Architecture

```
            +------------------------------------------------------------+
            |                        FILL ENGINE                         |
  BTB  <--->|  fill_pc walk (bundle-granular, sizes from sideband        |
  DIR  <--->|  predecode) . BTB slot-1 lookup at ask address,            |
            |  slot-2 lookup at walk time . epoch-tagged asks AND        |
            |  epoch-tagged in-flight prediction bindings                |
            +---------+--------------------------------------------------+
                      | enqueue <=2 instr entries/cycle
                      v         (pc, bytes, size, class, prediction metadata)
            +------------------+
            |   PARCEL QUEUE   |   8 entries, FIFO, 2W/2R,
            +---------+--------+   first-word-fall-through on empty
                      | dequeue <=2 entries/cycle (never on stall)
                      v
            +------------------------------------------------------------+
            |                      CONSUME ENGINE                        |
  RAS  <--->|  bundle former (slot rules from entry class bits)          |
            |  packet formation (from_if_to_pd / _2, fields from entries)|
            |  RAS detect on slot-1 dequeue-fire -> consume redirect     |
            +------------------------------------------------------------+
                      | redirects (RAS, PD heuristic, backend) flush the
                      | queue, resteer fill_pc, bump the epoch; the epoch
                      | kills ALL in-flight fill state (asks + bindings)
```

### 2.1 Fill engine

The fill engine is today's ask-side machinery relocated and stripped of every
`pc_reg` arm. It keeps, structurally unchanged:

- The bundle walk: `fill_pc` advances +2/+4 (1-wide) or +4/+6/+8 (2-wide)
  using per-halfword `IsCompressed` **sideband predecode** from the served
  window (`riscv_pkg.sv:102-113`, computed from the word bytes at 186-214, so
  provider-independent) — NOT the aligner's `pc_reg`-parity muxes. The fill
  frame is self-aligned: the window serves `{word(fill_pc), word(fill_pc)+1}`
  by construction, so "which half is the current word" is `fill_pc[2]`
  against the window's own served address — never a cross-walker parity. The
  F-vs-W disambiguation problem ceases to exist rather than being solved.
  (An assertion checks `i_served_addr` against the expected ask; the
  single-outstanding provider protocol makes this deterministic.)
- BTB slot-1 lookup at the **ask address** (as today, `bpc.i_pc = o_pc`):
  taken hits steer the next ask with the same redirect timing as today
  (zero-bubble in the ask stream; verified against today's cycle behavior by
  the panel's microarchitecture lens).
- BTB slot-2 lookup at walk time (`fill_pc + size(slot-1)`, as today's
  `slot2_pc_for_btb` but in the fill frame): a taken slot-2 hit redirects the
  next ask and epoch-kills the one already-issued wrong-path ask. The
  one-cycle fill gap this creates (today delivered downstream as a NOP via
  `o_slot2_redirect_q`) is absorbed by queue backlog when the consume side is
  behind, and only reaches PD as a bubble when the queue is empty.
- Direction-predictor lookups (slot-1 at ask, slot-2 at walk), captured into
  entry metadata — replacing `dir_taken_snapshot_r`'s alignment-by-timing with
  alignment-by-construction.
- The provider handshake: `i_instr_valid` low freezes the walk and holds the
  ask (today's `!fetch_progress` hold arms); redirects still land during the
  freeze. The seam itself changes (explicit redirect pulse, queue-full
  backpressure, tag-checked acceptance) — see §7.1.
- **Prediction gating**: the useful residue of `prediction_common`
  (`branch_prediction_controller.sv:360-377`). The serve-frame terms
  (`!use_instr_buffer`, `!spanning_*`) die with their machinery; the holdoff
  terms become "walk not frozen / no in-flight resteer this cycle"; the
  halfword gates (`!pc[1] || btb_compressed` for BTB, `|| is_compressed` for
  RAS-class entries) carry over unchanged in the fill frame;
  `i_disable_branch_prediction` (the verification-mode disable AND the
  dynamic CSR/serialization prediction fence from `ooo_pipeline_control.sv:
  226-228`) is **kept** as a fill lookup gate.

New in the fill engine:

- **Enqueue**: each walked instruction becomes one queue entry. Spanning
  32-bit instructions are assembled at enqueue from adjacent window halfwords
  (always available in the self-aligned frame except at the window top, where
  the walk ends the cycle's enqueue and continues next window — or consults
  the straddle carry, §2.6).
- **Epochs**: an epoch counter bumps on every resteer of `fill_pc` that can
  leave wrong-path state in flight (see the §2.5 matrix). Epoch-governed
  in-flight state:
  1. the owed ask — a served window whose epoch mismatches is dropped, not
     enqueued;
  2. **the prediction-binding pipe** (below);
  3. the straddle carry (§2.6).
  Sizing: the provider protocol is single-outstanding (one owed window at a
  time; `fetch_provider.sv` holds and re-serves the owed address), and
  redirects that bump the epoch are edge-triggered events (§2.4 makes the RAS
  redirect a dequeue-fire pulse, not a level), so at most one stale window
  and one stale binding can be in flight per resteer. A 2-bit epoch is
  therefore sufficient with margin; an SVA asserts no more than one
  outstanding ask per epoch. If a future provider pipelines multiple
  outstanding asks, the epoch must widen to cover
  max-outstanding + 1 — recorded as an assertion, not an assumption.
- **Prediction binding (pc-tagged, first-class invariant; see §2.1.1 — this
  supersedes the "epoch-tagged" wording below)**: the ask-time
  BTB/DIR lookup results ride an explicit **2-wide, epoch-tagged binding bus**
  aligned with the ask→serve latency — slot-1's ask-time result and slot-2's
  walk-time result each carry the epoch of the ask they belong to. At
  enqueue, entry `e0` binds the slot-1 stage and `e1` the slot-2 stage **only
  if the stage's epoch matches the arriving window's epoch; on mismatch the
  entry binds not-taken/zeroed metadata**. There is no free-running
  timing-aligned prediction register (today's `prediction_used_r` shape): a
  redirect landing between lookup and enqueue — including during an
  `!i_instr_valid` freeze — cannot leak a killed path's prediction onto the
  first post-redirect entry. This closes the panel's confirmed stale-at-birth
  analog (§10, finding 1) uniformly across every §2.5 row, including the
  no-flush slot-2 row. After a taken prediction the next enqueued entry IS
  the target instruction with `pc = target` written at fill; once enqueued,
  the binding is immutable.
- **Queue-full**: fill holds the ask via the seam's backpressure input
  (§7.1), asserting with ≥4-entry headroom for the in-flight window and the
  provider's registered-backpressure lag. Given consume drains ≥ as fast as
  fill fills in steady state, full mainly occurs during back-end stalls —
  where holding fetch is free. (Timing watch item: occupancy arithmetic sits
  on the ask-hold path; see §8.)

### 2.1.1 Ask-chain timing (derived from RTL — read before B-phase RTL)

This section pins the exact cycle relationship the fill-engine walk must
reproduce, derived from today's `if_stage` RTL (not from recollection). It
resolves the one question the stage-1/spec work left open: **does the
next-ask advance use the walked instruction's size sampled at ask time or at
serve time?**

**Today's dual-PC walk (confirmed in RTL):**

- `o_pc` is the *leading* fetch/ask address; `o_pc_reg` is the *decode*
  address and lags `o_pc` by exactly one cycle
  (`pc_increment_calculator.sv:295-296`; registers at `pc_controller.sv:787-791`).
- The BTB/DIR **slot-1 lookup is at the leading ask address**:
  `branch_prediction_controller_inst.i_pc(pc)` and `assign o_pc = pc`
  (`if_stage.sv:403, 557, 981`) — this is the "as today, `bpc.i_pc = o_pc`"
  the fill engine (§2.1) reproduces. The lookup result both steers the *next*
  `o_pc` combinationally (taken ⇒ zero-bubble redirect, `pc_controller.sv:702`
  `i_prediction_used_for_pc`) and is **registered one cycle forward**
  (`sel_prediction_r` / `i_predicted_target_r`) to align with the instruction
  when it reaches `o_pc_reg`. That timing-aligned register is exactly what the
  binding pipe replaces.
- The BTB **slot-2 lookup is at walk time**:
  `slot2_pc_for_btb = pc_reg + PcIncrementCompressed` (`if_stage.sv:383`) —
  the decode address plus slot-1's size (slot-1 is always compressed when
  slot-2 fires, hence `+2`). This is the `fill_pc + size(slot-1)` of §2.1.
- The **increment (size) is a serve-time quantity.** `o_is_compressed` /
  `is_compressed_fast` / the slot-2 metadata are all decoded from the
  *just-arrived* window and describe the instruction at `o_pc_reg`
  (`instruction_aligner.sv:146-152, 194-212`, gated by the
  `bank_sel_r ^ pc_reg[2]` word-parity). Both advance selects
  (`pc_fetch_advance_sel`, `pc_reg_advance_sel`, `if_stage.sv:1304-1326`) pick
  the increment `K` from that serve-time size, and `next_o_pc = o_pc + K`,
  `next_o_pc_reg = o_pc_reg + K` (same `K`). The ask's *own* bytes have not
  returned when the ask is presented, so its size cannot drive its own
  advance; the leading pointer advances by the *served* instruction's size.

**Answer to the open question:** the sequential next-ask advance uses the
walked instruction's size **at serve/walk time** (from the arriving window),
never at ask time. The only ask-time input to the next-ask mux is the BTB
taken/target, which overrides the sequential arm and needs no size.

**Mapping to the self-aligned fill engine** (single walker `fill_pc`; the
provider's `o_served_addr` replaces the recomputed `o_pc_reg`, so the
`bank_sel ^ pc_reg[2]` parity — and the whole F-vs-W disambiguation — is gone):

| Quantity | Today | Fill engine |
|---|---|---|
| ask / slot-1 lookup addr | `o_pc` (leading, registered) | `fill_pc` (`o_ask_pc`, `o_lookup_pc`) |
| decode / enqueue addr | `o_pc_reg` (recomputed, parity-reconciled) | `i_served_addr` (provider-supplied, self-aligned) |
| sequential advance | `o_pc + size(instr@o_pc_reg)` (serve time) | `served_addr + size(served)` (serve time) |
| taken redirect | ask-time BTB @ `o_pc` ⇒ next `o_pc` | ask-time BTB @ `fill_pc` ⇒ next `fill_pc` |
| slot-1 prediction align | `sel_prediction_r` reg (1 cy) | binding pipe `bind_q` (1 cy), pc-tagged |
| slot-2 prediction align | combinational @ walk | combinational @ walk (no carry) |

The ask→serve latency is one cycle: the slot-1 lookup at `fill_pc` (cycle N)
is registered into `bind_q` and bound to the entry when that address is served
(cycle N+1). Throughput is one instruction/cycle via provider pipelining; the
`window → sideband → size → next-ask` cone is the same depth as today's
`BRAM → aligner → o_pc` cone (§2.2/§8 — the timing win is deleting the
pending-prediction *control* cones, not this data cone).

**Binding is pc-tagged, not epoch-counted (supersedes the epoch-counter
realization in §2.1/§2.5).** The binding closure — "a redirect between lookup
and enqueue must not leak a killed path's prediction onto the first
post-redirect entry" — is realized by **tagging each binding stage with the
lookup address and binding iff `bind_q.pc == entry.pc`** (else zeroed
not-taken metadata). Because BTB/DIR metadata is a pure function of the lookup
address, an address match binds correct metadata unconditionally; this is
equivalent-or-stronger than an epoch match (a redirect *to the same address* —
tight self-loop — keeps the correct prediction and its zero bubble, where an
epoch bump would spuriously drop it). The consequences:

- The free-running epoch **counter is deleted.** The §2.5 matrix's "epoch++"
  columns are read as "the pc-tag no longer matches in-flight state," which the
  resteer produces for free (a resteer changes the address being enqueued).
- **Window acceptance is address-tag-checked** (§7.1): a window is
  accepted/enqueued only when `i_served_addr` matches the outstanding ask —
  the address-level counterpart that drops stale wrong-path windows.
- The **`i_core_redirect` pulse still exists** (§7.1) for the provider seam
  and, later, the straddle-carry kill (§2.6) — but no longer for a binding
  epoch. fence.i stays safe: it flushes + pulses + invalidates the provider
  buffer, and the re-fetched bytes carry their own (address-correct) metadata.

### 2.1.2 Slot-2 formation (2-wide, derived from RTL — B2)

The fill engine enqueues a second entry (`e1`) per served window when a
contiguous slot-2 exists, sustaining 2 instr/cycle. Slot-2 fires only behind a
**compressed** slot-1 (so slot-2 starts at `served_addr + 2`), giving exactly
two self-aligned positions — the buffer / fetch-swap cases of today's aligner
(`instruction_aligner.sv:301-314`) collapse away:

| `served_addr[1]` | position | parcel | 32-bit assembly | sideband source |
|---|---|---|---|---|
| 0 (slot-1 at word-lo) | CURRENT_HI | `low[31:16]` | `{high[15:0], low[31:16]}` (spans lo→hi) | `sb_lo` hi-halfword bits |
| 1 (slot-1 at word-hi) | NEXT_LO | `high[15:0]` | `high[31:0]` | `sb_hi` lo-halfword bits |

(`low`/`high` = the two window words; `sb_lo`/`sb_hi` their sidebands — the
high-word bits sunk as `_unused_b2` in B1.) NEXT_HI (slot-2 32-bit needing a
third word) is unreachable — it only arises behind a 32-bit slot-1, which never
carries a slot-2 — so **B2 needs no straddle**; every slot-2 fits the 64-bit
window (matches the aligner's CURRENT_HI/NEXT_LO-only candidates,
`instruction_aligner.sv:650-677`).

**Pairing** (fill-side, mirrors the consume former §2.3 so bundles match HEAD):
enqueue `e1` iff `e0.allows_slot2_after && e1.slot2_start_ok &&
!e0.predicted_taken`. Both sideband predicates already fold in HEAD's gates —
`allows_slot2_after = is_compressed && !compressed_control` (slot-1 compressed,
not a compressed branch) and `slot2_start_ok = is_compressed || !(serialize ||
fp)` (the CSR/FENCE/AMO/FP-compute slot-2 gates of
`instruction_aligner.sv:573-588`, folded into the predecode). HEAD's residual
branch/store gates were already dropped (aligner Sessions L/Q/R). The bundle
advance is `served_addr + 2 + size(slot-2)`.

**Slot-2 binding is walk-time** (combinational, this cycle): the slot-2 BTB/DIR
lookup is at `served_addr + 2` (today's `slot2_pc_for_btb = pc_reg + 2`,
`if_stage.sv:383`), off the registered served address, and binds `e1` the same
cycle it enqueues — no forward register (contrast slot-1's ask-time binding,
§2.1.1). Its pc-tag holds trivially; the asymmetry with slot-1 is why the
binding bus is 2-wide.

**Slot-2 taken is a registered redirect (the one bubble).** The slot-2 BTB
result is kept OFF the ask path (timing): when slot-2 is a taken branch the
engine still issues the sequential `served_addr + bundle` ask this cycle,
enqueues `e0`+`e1` (`e1` marked predicted_taken → target), and registers a
one-shot `slot2_redir_pending`. Next cycle it fires: ask ← slot-2 target,
`o_core_redirect` pulse (§7.1), **no queue flush** (`e0`/`e1` are valid,
in-order), and the in-flight wrong-path sequential window is rejected (accept
gated) — the one-cycle fill gap of §2.1/§2.5, absorbed by queue backlog. This
reproduces HEAD's `o_slot2_redirect_q` NOP (`pc_controller.sv:218-233`) exactly
while keeping the slot-2 BTB read off the ask critical path.

### 2.2 Parcel queue

An 8-entry circular FIFO of **instruction entries** (not raw halfwords — see
§6 Q1). Two write ports (fill enqueues a 2-wide bundle), two read ports
(consume reads head and head+1).

**First-word-fall-through (FWFT)**: when the queue is empty, the bundle
former sources combinationally from the incoming enqueue data, so the
redirect-target instruction reaches PD on the same cycle its window arrives —
matching today's refill latency exactly (backend redirect at N → target
packet at N+2). Without FWFT, a registered-only queue adds a deterministic +1
cycle to EVERY flushing redirect (backend mispredict, trap, MRET, FENCE.I,
PD, RAS), which the panel confirmed against provider RTL (§10, finding 2).
Consequence stated honestly: **the consume-side data cone is flop-sourced
only when the queue is non-empty; the FWFT arm re-imports a
window→assemble→packet combinational path of the same depth as today's
BRAM→aligner→packet cone.** The x3 timing win claimed by this design is the
deletion of the pending-prediction control cones, NOT flop-sourcing of the
data path (§8).

Entry format (~110 bits):

| Field | Bits | Source | Notes |
|---|---|---|---|
| `pc[31:1]` | 31 | fill walk | exact instruction PC; bit 0 always 0 |
| `bytes[31:0]` | 32 | window (spanning pre-assembled) | RVC: parcel in `[15:0]`, `[31:16]` don't-care |
| `is_compressed` | 1 | sideband predecode | authoritative |
| `allows_slot2_after` | 1 | sideband (`ImemSbAllowsSlot2After*`) | this entry may lead a 2-wide bundle |
| `slot2_start_ok` | 1 | sideband (`ImemSbSlot2StartValid*`) | this entry may occupy slot 2 |
| `btb_hit` | 1 | fill-time BTB lookup | |
| `predicted_taken` | 1 | fill-time (BTB counter / used) | entry marked taken ⇒ next entry is the target |
| `predicted_target[31:1]` | 31 | fill-time | |
| `dir_taken` | 1 | fill-time decoupled bimodal | slot-1 PD heuristic input |
| `dir_idx[9:0]` | 10 | fill-time | training index, carried to commit |

`ras_predicted` / `ras_predicted_target` / RAS checkpoints are **not** queue
fields — RAS is consume-side (§2.4), so those packet fields are generated at
emit exactly as today.

**Flush semantics** (two distinct operations, both single-cycle):

- **Full flush** (backend branch / trap / MRET / FENCE.I / PD redirect):
  head and tail pointers reset atomically and ALL valid bits clear. **Flush
  dominates enqueue**: an enqueue coincident with a full flush is suppressed
  entirely — no entry written, no tail movement — so no phantom pre-redirect
  entries can survive into the empty queue (§10, finding 4). Unit test: flush
  on the same cycle a 2-wide bundle enqueues; assert empty.
- **Partial flush** (RAS consume redirect): `tail ← head + 1` — the return
  entry at the head survives (it is being emitted this cycle); all younger
  entries die. Fires only as a dequeue-fire pulse (§2.4), so it cannot repeat
  or regress the tail under a stall.

No tags, no per-entry invalidation logic — entries are valid in FIFO order by
construction. This retires the stage-1 FCA's direct-mapped tag scheme
entirely; what re-lands from stage 1 is the *capability* (slot-2 and spanning
sourced from bytes beyond the live window — via the queue itself and the §2.6
straddle carry, which is the FCA's third-word reach reborn without tags) plus
its testbench assets, not the tagged array.

### 2.3 Consume engine

- **Bundle former**: slot-1 = head entry; slot-2 = head+1 iff
  `e0.allows_slot2_after && e1.slot2_start_ok && !e0.predicted_taken` and both
  entries are valid. (`!e0.predicted_taken` preserves downstream invariant
  "slot-2 PC = slot-1 PC + slot-1 size" — after a taken branch, head+1 is the
  target, discontiguous. Cross-boundary branch/target pairing is a stage-3
  upside, not attempted here.) A defensive assertion checks
  `e1.pc == e0.pc + size(e0)` whenever pairing fires.
- **Packet formation**: all `from_if_to_pd` / `_2` fields come from entry
  fields: `program_counter = e.pc`, `raw_parcel = e.bytes[15:0]`,
  `effective_instr` = `e.bytes` (native) / decompressed (slot-2 RVC — ONE
  consume-side `rvc_decompressor`, replacing the aligner's three; slot-1 RVC
  is decompressed in PD from `raw_parcel` as today), `sel_compressed =
  e.is_compressed`, `link_address = e.pc + size`, `btb_* / bp_dir_*` from
  entry metadata, `ras_*` from the consume-side RAS. `decomp_illegal` (slot-2)
  from the consume decompressor.
- **Queue empty** (and no FWFT data arriving) ⇒ `sel_nop = 1` (and
  `sel_nop_2 = 1`) with zeroed prediction metadata. This is the ONLY bubble
  source at consume, replacing the ~8-term `sel_nop_existing` OR
  (`if_stage.sv:808-826`). Bubbles from redirect latency, L1I misses, and
  fill-side prediction shuffles all manifest identically: nothing in the
  queue.
- **Stall**: dequeue is gated by `!stall`. The head entries do not move, so
  the identical bundle is re-presented on release *by construction* — the
  entire `_sc` stall-capture/replay apparatus and `replay_saved_if_outputs`
  are deleted, along with the bug-3 class (live vs saved signal skew on replay
  cycles). The provider-facing `o_fetch_replay_consume` contract is replaced
  per §7.
- **pc_reg**: dies as a walker. A `pc_reg`-equivalent debug tap can be
  exported as head-entry PC for the cpu_ooo `dbg_*` mirrors.

### 2.4 RAS — consume-side (stage 2.0)

Today's RAS is already content-based and serve-side: `ras_detector` reads the
*served* instruction, pushes/pops at serve time, and redirects the next ask.
Stage 2 keeps this shape at the consume engine:

- `ras_detector` runs on the slot-1 packet (head entry) as today.
- **All RAS side effects and the return redirect are edge-triggered on
  dequeue-fire** (`!stall && !sel_nop && !flush`): push, pop, checkpoint
  snapshot, and the consume redirect (partial flush + `fill_pc ← ras_target`
  + epoch++) fire exactly once, on the cycle the return entry actually
  retires from the queue. A return sitting at the head under a stall is
  inert — no redirect, no epoch bump, no flush — because the level condition
  is never sampled without dequeue-fire. (Panel finding: a level-sensitive
  formulation re-fires every stall cycle, thrashing fill and burning epochs;
  §10, finding 3.)
- Checkpoints snapshot pre-instruction state and ride the packet as today
  (downstream invariant 7 untouched).
- The RAS-from-buffer flow, `prediction_from_buffer_holdoff`,
  `use_buffer_after_prediction`, and the halfword-landing bookkeeping all die
  with the buffer machinery.

Latency: with FWFT (§2.2), a RAS redirect pays the same BRAM round trip as
today's holdoff-NOP'd stale cycles; any queue backlog at redirect time is
discarded (it was wrong-path anyway). Expected parity within ±0; measured, not
assumed (§8), with attribution per redirect type. The designed escape hatch if
return-heavy code measures worse: **stage 2.1** moves return detection to the
fill side (predecode `c.jr ra` / `jalr x0,0(ra)` on enqueued parcels —
tractable because the fill stream is in-order and adjacent) with a fill-side
speculative RAS restored from the consume-side architectural one on every
flush. Stage 2.1 is NOT required for correctness and is out of scope for the
initial land.

The PD backward-branch heuristic redirect is the same shape: consume-side
(downstream, in fact) redirect → full flush + resteer + epoch++. The
`redirect_kills_prediction_metadata` scope hack (the cjpeg bug's fix,
`branch_prediction_controller.sv:497-539`) dies naturally: metadata is
per-entry once enqueued, and the epoch-tagged binding bus (§2.1) provides the
equivalent kill for not-yet-enqueued lookups — so a younger redirect can
neither strip nor replay an older instruction's metadata, pre- or
post-enqueue.

### 2.5 Redirect matrix

One rule for everything: **flush per the table, resteer `fill_pc`, bump the
epoch — and the epoch bump kills ALL in-flight fill state (owed ask,
binding-bus stages, straddle carry).** (Per §2.1.1 the epoch is realized as
per-stage **pc-tags**, not a counter: a resteer changes the enqueued address,
so in-flight state stops matching for free; "epoch++" below reads as "in-flight
pc-tags no longer match.") Priority (same as today's next-PC mux):
reset > trap/MRET > FENCE.I > backend branch > PD redirect > RAS (consume) >
slot-2 BTB (fill) > slot-1 BTB (fill) > sequential.

| Event | Queue | fill_pc | Epoch | Notes |
|---|---|---|---|---|
| backend branch / trap / MRET / FENCE.I | full flush (dominates enqueue) | target | ++ | must land during stall and during `!i_instr_valid` freezes (as today, `pc_update_en` / hold-arm placement) |
| PD redirect | full flush (dominates enqueue) | target | ++ | |
| RAS return (consume, dequeue-fire pulse) | partial flush (`tail ← head+1`) | ras_target | ++ | head entry emits on the firing cycle |
| slot-2 BTB taken (fill) | no flush | target | ++ (kills 1 in-flight ask + its binding stage) | enqueue up to and incl. the slot-2 branch |
| slot-1 BTB taken (fill, ask-time) | no flush | target | — (no wrong-path ask issued) | zero-bubble in the ask stream, as today |
| queue full / `!i_instr_valid` | hold ask | hold | — | |

Backend-redirect-during-anything is uniform: the full flush is unconditional
and epoch filtering makes every in-flight return harmless — which is exactly
the property today's holdoff bookkeeping approximates with per-case timing
arguments.

### 2.6 Slot-2 behind a 32-bit slot-1 (B3)

B2 pairs only behind a **compressed** slot-1 (HEAD-parity). B3 reclaims the
width HEAD forfeited by letting a **32-bit slot-1** lead a bundle. It splits by
whether slot-2 fits the 64-bit window.

**B3a — in-window (self-alignment preserved; landed as the fill-engine unit
step).** Slot-2 sits at `served_addr + size(slot-1)` ∈ byte offset {2, 4, 6}
of the window. HEAD's aligner already computes these three positions
(`Slot2AtCurrentHi/NextLo/NextHi`, `instruction_aligner.sv:290-399`) but gates
NEXT_LO/NEXT_HI off — the width HEAD forfeited to the prediction race, now
structurally closed by the queue's per-entry binding. B3a enables them:

| slot-2 offset | position | parcel | 32-bit assembly | fits window? |
|---|---|---|---|---|
| 2 (RVC slot-1 @word-lo) | CURRENT_HI | `low[31:16]` | `{high[15:0], low[31:16]}` | yes |
| 4 (RVC@hw or 32b@word-lo) | NEXT_LO | `high[15:0]` | `high[31:0]` | yes |
| 6 (32b spanning slot-1 @hw) | NEXT_HI | `high[31:16]` | reaches word W+2 | RVC only |

The slot-1 gate generalizes: `allows_slot2_after = is_compressed ?
(!compressed_control) : (!serialize && !fp)` — the 32-bit arm equals the
`Slot2StartValid` predicate, so serialize/FP ops still cannot lead (matching the
ROB head-only gate). Not-taken branches may lead (`!predicted_taken` suppresses
the taken case; a mispredicted lead flushes the whole queue). The slot-2 lookup
address becomes `served_addr + size(slot-1)` (was fixed `+2`). A **NEXT_HI
32-bit slot-2 straddles** word W+2 and is suppressed (pairing declines, the op
replays as the next slot-1) — that shape is B3b. Every enabled slot-2 is fully
in the window, so self-alignment is untouched; B3a captures the bulk of the
reclaimed width (32b+RVC at any alignment, word-aligned 32b+32b).

**B3b — the straddle carry (NEXT_HI 32-bit; deferred to the integration
phase).** The one residual shape — 32-bit slot-1 spanning at offset 2 with a
32-bit slot-2 at offset 6 reaching word W+2 — needs three words of reach, which
the FCA supplied via `want_idx[2] = W+2` (§10, finding 5). The mechanism is a
**straddle carry register**: the trailing halfword (offset 6) + its predecode +
the slot-2 port's lookup at that pc, carried across the window advance. When the
walk is at the carried halfword the ask skips to the following word and the cycle
forms `{window_low[15:0], carry}` as slot-1 with its carried binding — a
controlled, fixed, single-halfword misalignment (always "the trailing halfword
of the previous window", so no tags/parity), killed by any redirect pulse. This
is the **one place stage 2 re-introduces a misalignment**, so — per the FCA
lesson that only CRC-checked compute (coremark) catches this width class's
races — B3b lands in the INTEGRATION phase behind the adjacent-dup + coremark-CRC
tripwires, NOT in the standalone unit. Without B3b, B1/B2/B3a still exceed HEAD
width (which pairs nothing behind a 32-bit slot-1); B3b only adds the misaligned
32+32 stretch.

## 3. What gets deleted / restructured

- `pc_controller.sv`: the whole pending-prediction block (~350 lines:
  `pending_prediction_*`, `sel_prediction_r`, `pim`/`pim32`/
  `carve_out_engaged_q`, `halfword_target_lead_catchup`,
  `redirect_kill_pending_q`, both `window_cannot_serve` mux arms, the
  `seq_next_pc_reg` machinery and the `_pc_mux` keep-duplicated cones — the
  worst x3 timing offenders in the front end). What remains becomes the fill
  walker's next-ask mux.
- `prediction_metadata_tracker.sv`: deleted (metadata rides in entries; the
  binding bus covers pre-enqueue).
- `c_ext_state.sv`: deleted (buffer, snapshots, landing bookkeeping).
- `instruction_aligner.sv`: deleted; replaced by the fill-side window slicer
  (self-aligned, no parity XOR) and the consume-side bundle former. Two of its
  three slot-2 decompressors go away.
- `branch_prediction_controller.sv`: **restructured, not deleted** — the BTB,
  direction predictor, RAS, and `ras_detector` instances survive; the gating
  wrapper is rebuilt as the fill lookup gate (§2.1) and the consume-side RAS
  trigger (§2.4). Dead gating terms: `use_instr_buffer`, `spanning_*`,
  `prediction_holdoff`/`btb_only_prediction_holdoff` (their c_ext consumers
  die), the registered metadata stage (`prediction_used_r`,
  `predicted_target_r`, `dir_taken_snapshot_r`) — replaced by the epoch-tagged
  binding bus. Kept: `i_disable_branch_prediction`, the halfword/compressed
  gates, the BTB/DIR update ports, the RAS restore port.
- `if_stage.sv`: the `_sc` stall-capture/replay apparatus (~25 saved
  registers + muxes), the served-window guard and resteer, the
  `fetch_word_swapped_*` nets, spanning assembly (moves to fill), the
  holdoff-driven `sel_nop` OR-tree.
- `control_flow_tracker.sv`: replaced by the epoch filter; `to_halfword`
  bookkeeping dies (halfword targets are just entry PCs).
- `pc_increment_calculator.sv`: the parallel-adder structure is reused by the
  fill walk's next-ask computation; the `pc_reg` product terms and
  `seq_next_pc_reg_neq_pc` die. `pc_reg_precompute.sv`: deleted.
- `i_instr_bank_sel_r`: no longer a consume-side parity input; the fill
  slicer uses `fill_pc[2]` with a served-address assertion (§2.1).
- The stage-1 FCA (`fetch_capture_array.sv`) is **not** re-landed: the queue
  plus the §2.6 straddle carry subsume it.

Kept unchanged: `branch_predictor` (BTB, incl. dual ports and update port),
`direction_predictor`, `return_address_stack` + `ras_detector`,
`rvc_decompressor`, the entire downstream (`from_if_to_pd_t` fields and
semantics, PD/ID/dispatch, recovery interfaces, `ex_comb_synthesizer`, BTB/DIR
training paths, RAS restore path).

## 4. Downstream contract compliance

Against the 12 invariants extracted from the consumer audit:

1. `sel_nop` sole bubble bit — single-source from queue-empty (FWFT-aware).
   (`frontend_validity_tracker`'s own `post_flush_holdoff_q` is a separate,
   downstream bubble source and is unaffected.) ✓
2. NOPs carry zeroed prediction metadata — empty-queue packet is all-zeros;
   epoch-mismatched bindings enqueue as zeros. ✓
3. PC-advance = delivery — the advance-select machinery is gone; delivery IS
   dequeue. The invariant becomes structural. ✓
4. `program_counter` exact, slot-2 = slot-1 + size — entry PCs written at
   fill; pairing rule + assertion enforce contiguity. ✓
5. `effective_instr` assembled / slot-2 pre-decompressed; `raw_parcel` raw —
   preserved (assembly at fill, one consume decompressor). ✓
6. slot-1 `sel_compressed` advisory, slot-2 authoritative — from entry
   predecode, bit-accurate. ✓
7. RAS checkpoints = pre-instruction state, slot-2 mirrors slot-1 — RAS ops at
   dequeue-fire, unchanged. ✓
8. `bp_dir_idx` exact predict-time index — captured at fill lookup, bound by
   epoch match. ✓
9. Stall ⇒ identical re-present — queue head immobile under stall; RAS/
   redirect side effects edge-triggered on dequeue-fire so nothing re-fires. ✓
10. Recovery priority and land-during-backpressure — redirect matrix §2.5;
    refill latency parity via FWFT (§2.2). ✓
11. Two-PC timing contract — packet PC is the entry PC; `o_pc` remains the
    ask. The "pc_reg lags pc by one cycle" contract dissolves; consumers were
    audited to depend only on packet PCs. ✓ (audit item: cpu_ooo `dbg_*` taps)
12. Flush ⇒ `sel_nop=1` bubbles — flush empties the queue and suppresses
    same-cycle enqueue. ✓

## 5. Why each stage-1 bug class is structurally closed

| Ledger class | Stage-2 disposition |
|---|---|
| Stale-at-birth pending arm + land-on-branch yank (coremark CRC) | No arm, no pending state, no `pc_reg` yank exists. Prediction binds at enqueue; consume order is queue order. |
| **Stale-at-birth analog upstream of enqueue** (found by the v1 panel, not by stage 1) | Closed by the epoch-tagged binding bus: a redirect between lookup and enqueue zeroes the binding rather than leaking it onto the first post-redirect entry (§2.1, §10 finding 1). |
| Transition-cycle double delivery (8028b5ac) | No fetch-holdoff/use_pending handoff; an entry dequeues exactly once; flush dominates enqueue so no phantom entries. The deterministic reproducer should VANISH — checked as a positive signal in verification. |
| pim/pim32 predecessor drops (+ open +6/+8 residual) | No fetch-holdoff squash to carve out of; older instructions are earlier entries and always emit. Closes the ledgered residual too. |
| Replay double-delivery (bug 3) | No saved/live signal pair to skew; stall = head doesn't move; all side effects edge-triggered on dequeue-fire. |
| F=W−1 spanning corruption (bug 1) | No cross-walker parity; spanning assembled in the self-aligned fill frame. |
| F=W+1-no-buffer guard gap (bug 2) | No served-window guard; availability is queue-valid bits, exact by construction. |
| `window_cannot_serve` multi-consumer contract (bug 4) | The signal and all three consumers cease to exist. |
| cjpeg metadata-strip scope hack | Per-entry metadata post-enqueue + epoch-tagged bindings pre-enqueue; redirects can't reach either. |

## 6. Design decisions (with recommendations)

1. **Queue granularity — instruction entries (recommended)** vs raw halfword
   parcels. Instruction entries kill the alignment problem at the consume
   boundary entirely (the ledger's lesson: every live-window consumer carried
   implicit F∈{W,W±1} assumptions); halfword parcels are denser but re-import
   an aligner at consume. Cost: ~110 bits × 8 entries ≈ 0.9k flops, offset by
   ~500 flops of deleted `_sc`/pending/buffer state (panel-audited as
   conservative).
2. **RAS placement — consume-side for 2.0 (recommended)**; fill-side predecode
   RAS as 2.1 if measurement shows a return-latency regression (§2.4).
3. **Queue depth — 8 entries (recommended)**; measure occupancy and
   full/empty duty cycles with the width-funnel counters before tuning.
4. **Landing order — 1-wide first (recommended)**: land the queue with slot-2
   formation disabled, validate the full ladder, then enable 2-wide
   (HEAD-parity width), then the straddle carry (§2.6) to exceed HEAD. Each
   step has the tripwires of §8.
5. **FCA fate — retire the tagged array (recommended)**; the queue + straddle
   carry subsume it. Cherry-pick from the parked branch only the
   view-formation patterns, the `test_instruction_aligner.py` extensions, and
   the probe/checker assets.
6. **FWFT bypass — yes (recommended)**: refill-latency parity on every
   flushing redirect is worth an empty-queue combinational arm whose depth
   matches today's always-on cone (§2.2). The alternative (accept +1 cycle on
   every mispredict recovery) fails the B2 "IPC parity" gate by construction.
7. **Provider seam — explicit redirect pulse (decided, §7.1)**: replace the
   acceptance-history retarget inference with `i_core_redirect`, re-point the
   seam's stall input at queue-full, delete `o_fetch_replay_consume`,
   tag-check window acceptance at fill. The inference alternative was audited
   and rejected: the `accepted_prev_q` shadow makes a consume-side redirect
   invisible, and in the L1I-miss case the provider commits a full wrong-path
   line fill before it can be corrected.

## 7. Interface & residual audits (work items before RTL)

- **Provider seam contract — RESOLVED (audited 2026-07-05, see §7.1)**: the
  inference-based retarget classifier is replaced by an explicit redirect
  pulse, the seam's stall input is re-pointed from the decode stall to
  queue-full backpressure, and `o_fetch_replay_consume` is deleted. Details
  and the failure derivation in §7.1.
### 7.1 The provider seam, stage-2 contract (audit result)

Today's contract (`fetch_provider.sv:31-42, 102-149`; fuzz mirror
`cpu_and_mem.sv:414-485`): the provider owns a 1-deep owed-ask register and
**infers** retargets from acceptance history —
`retarget_now = !accepted_prev_q && !i_fetch_replay_consume &&
(i_pc != pc_prev_q)` (`fetch_provider.sv:122`), resting on the invariant "the
core holds `o_pc` on every un-accepted cycle except backend redirects and the
registered stall-replay advance". Stage 2 breaks both legs:

1. **The `accepted_prev_q` shadow.** A consume-side redirect (RAS
   dequeue-fire, PD) can move `o_pc` on the cycle immediately after an
   accepted serve. `retarget_now` is suppressed that cycle
   (`accepted_prev_q = 1`), and on the next cycle the movement is invisible
   (`i_pc == pc_prev_q` already). The owed ask stays stale. If the stale
   window is resident the core can reject it by tag and the ask self-heals in
   one cycle (`ask_q <= i_pc` on the next valid cycle,
   `fetch_provider.sv:137,145`) — but if the stale ask **misses**, the miss
   engine (`fetch_provider.sv:250-267`, registered-ask-driven) launches a
   multi-cycle wrong-path DDR line fill and does not chase the redirect
   target until that fill completes and its window is presented and rejected.
   A return into an L1I-miss situation would eat the full wrong-line round
   trip. Inference cannot be patched around this; the movement information
   exists only in the core.
2. **Stall semantics invert.** The provider withholds publish-valid during
   the decode stall (`fetch_provider.sv:64-69, 209-210`) because the decode
   is the window consumer. In stage 2 the consumer is the fill engine, which
   must keep accepting windows during a backend stall — that is the queue's
   whole purpose. The decode stall must not reach the provider at all.

**The stage-2 seam** (changes to `fetch_provider`, its fuzz reference model,
and the seam wiring; the always-valid low-BRAM path is untouched):

- `i_core_redirect` (new): a pulse asserted by the core on EVERY `o_pc`
  resteer (backend branch / trap / MRET / FENCE.I / PD / RAS / slot-2 fill
  redirect — the §2.5 epoch-bump set plus slot-1-taken steering is not needed
  since slot-1 hits steer on accepted flow). Provider:
  `retarget_now = i_core_redirect` (the `pc != pc_prev` compare is demoted to
  an SVA that redirect pulses and movement agree). No inference remains.
- `i_fetch_backpressure` (replaces `i_pipeline_stall` at the seam): driven by
  queue-full, not the decode stall. Provider semantics unchanged (withhold
  publish-valid, park the owed window); only the meaning of the input moves.
  The registered lag (`pipeline_stall_q`, `fetch_provider.sv:200,218`)
  carries over, so **queue-full must assert with headroom**: ≥ 4 free entry
  slots (one in-flight window = up to 2 entries, plus one lag cycle's
  window).
- `o_fetch_replay_consume`: deleted (port and both consumers,
  `fetch_provider.sv:122`, `cpu_and_mem.sv:472`). The replay class does not
  exist — under a decode stall the queue simply stops dequeuing and the fill
  keeps running until backpressure.
- **Tag-checked acceptance in the fill engine** (promoted from assertion to
  functional gate): a window is accepted/enqueued only when `i_served_addr`'s
  word matches the fill walk's expected ask; a valid-but-mismatched window is
  treated as an unserved cycle. This makes the one-cycle stale-valid
  presentations around retargets harmless by construction and is the epoch
  filter's address-level counterpart.
- Fuzz coverage: inject RAS/PD redirect pulses during multi-cycle fetch gaps
  and in the accepted-shadow cycle; a directed test drives a consume redirect
  while the provider is mid-wrong-line fill and checks the fill is chased
  immediately on completion (no second wrong-line fill).

- Sideband coverage: `IsCompressed`/`Slot2StartValid`/`AllowsSlot2After` are
  computed from word bytes in `riscv_pkg` (provider-independent) — confirm
  every provider path routes them; fallback derivations exist at fill.
- BTB `requires_pc_reg_handoff` entry bit: consumer (`prediction_needs_pending`)
  dies; keep the BTB layout and ignore the bit initially, reclaim later.
- cpu_ooo `dbg_*` mirror taps that reference `pc_reg`.
- Perf counters: recompute width-funnel events and slot-2 kill causes at the
  bundle former (same event definitions, new sources).
- `i_pipeline_ctrl.flush` vs `i_frontend_state_flush` timing skew (the
  "allowed to lag by one cycle" c_ext flush) — map both onto queue-flush and
  verify no one-cycle window where a dead entry can dequeue.
- Trap/MRET during stall (`pc_update_en` bypasses stall today): fill redirect
  + flush must apply under stall; consume presents bubbles; downstream is
  flushed anyway. Enumerate in the unit tests.
- Formal: sweep `formal/` for if_stage harnesses bound to deleted nets.

## 8. Verification plan

Reuse the stage-1 arsenal (all probe/checker tooling exists on the parked
branch):

- **Unit — new**: `test_parcel_queue` cocotb suite: enqueue/dequeue/flush/
  epoch/full/empty/stall races; directed cases from the panel: (a) full flush
  coincident with a 2-wide enqueue → queue empty after; (b) redirect landing
  during an `!i_instr_valid` freeze with a taken prediction in the binding
  bus → post-redirect entry binds zeroed metadata; (c) taken slot-2 whose
  sequential shadow is epoch-killed, immediately followed by a target that is
  itself a predicted-taken branch; (d) RAS return at head across a multi-cycle
  stall → exactly one redirect/epoch bump on release; (e) FWFT refill cycle
  packet correctness.
- **Unit — migration** (dispositions, not "keep 13/13"; most existing
  if_stage tests assert on internal walker nets that vanish):
  `test_instruction_aligner.py` → port formation cases to the bundle former
  (incl. the stage-1 extensions from the parked branch);
  `test_c_ext_state.py`, `test_control_flow_tracker.py` → retire with their
  modules; `test_pc_controller.py` → rewrite (pending block gone);
  `test_pc_increment_calculator.py` → keep the adder cases the fill walk
  reuses, retire the `pc_reg` cases; `test_if_stage.py` → triage per test:
  bug-specific-to-deleted-machinery tests retire with a mapping to the §5
  structural closure that obsoletes each; generic contract tests rewrite
  against queue-visible state.
- **The packet-vs-objdump checker** (IF→PD packet trace diffed against
  per-address ground truth) after EVERY landing step — it is front-end-agnostic
  (checks emitted packets only) and was the decisive stage-1 probe.
- **Adjacent-duplicate commit scan** on commit-PC traces — the stale-at-birth
  and transition-double detector. Expected result on stage 2: the three
  benign HEAD doubles and the deterministic 8028b5ac double all VANISH
  (positive structural signal, not just non-regression).
- **Ladder**: fuzz ×4 (hello/c_ext/branch_pred/call_stress), spanning,
  directed ladder, isa ×2, csr/umode/traps, clint/irq, ddr/ddr_exec/
  smc_fencei, linux_boot, coremark (the CRC self-check is THE tripwire —
  stage 1's only catcher).
- **Performance**: width-funnel counters and IPC on coremark + linux_boot vs
  HEAD, with **attribution per redirect type** (backend mispredict refill,
  RAS return refill, PD redirect refill — the FWFT parity claim is verified
  here, not assumed), return-heavy code for the consume-side RAS decision
  (§6.2), and queue occupancy stats for depth (§6.3).
- **x3 timing**: validate at each landing step. The claimed win: the deleted
  pending `_pc_mux` keep-cones and the 24-level
  mispredict→flush→is_compressed→seq_next_pc_reg→CARRY8 path (panel-confirmed
  as genuinely deleted, not moved). Watch items (panel): the FWFT arm
  (window→assemble→packet — must not exceed today's BRAM→aligner→packet
  depth); the slot-2 walk cone's new enqueue-write endpoint; the RAS
  detector→fill next-ask mux cross-engine cone (compare today's
  i_instruction→ras_detector→RAS→next_pc); queue-occupancy arithmetic on the
  ask-hold path; spanning assembly + rotating write-port mux on the enqueue
  path.

## 9. Landing plan

- **A. Scaffolding** (no behavior change): extract packet formation behind a
  consume-module boundary; build `parcel_queue.sv` + fill-engine skeleton with
  unit tests, not yet instantiated.
- **B1. The swap, 1-wide**: queue in (FWFT from day one), slot-2 disabled.
  Full ladder + checkers. Fallback = revert the commit (ledger discipline: no
  parameter knob).
- **B2. 2-wide, HEAD-parity**: enable bundle former pairing. Ladder + width
  counters vs HEAD (IPC parity required, incl. per-redirect refill
  attribution).
- **B3. Width upside**: the straddle carry (§2.6) — misaligned 32+32 and
  slot-2 across window boundaries at sustained 2/cycle fill. Measure width
  gains via kill-cause counters — this is where stage 1's forfeited upside is
  finally collected (and it is a fill-local feature: no consume or prediction
  machinery is touched).
- **B4. x3 timing validation** and README updates (cpu README front-end
  section, this file moves from DESIGN to AS-BUILT), memory-ledger update.

Each B-step is one coherent commit with the §8 tripwires green before the
next.

## 10. v1 panel review record

Five adversarial lenses; every HIGH finding independently re-derived by a
verifier defaulting to refutation. Confirmed findings and their disposition:

1. **CONFIRMED (bug-replay): unflushed fill-side prediction register = the
   stale-at-birth analog upstream of enqueue.** A redirect during an
   `!i_instr_valid` freeze left v1's timing-aligned prediction register
   holding a killed path's (taken, target); the first post-redirect entry
   bound it. Fixed: epoch-tagged binding bus, bind-on-epoch-match only
   (§2.1); covers the no-flush slot-2 row that a flush-coupled clear would
   miss.
2. **CONFIRMED (uarch): registered-only queue adds +1 refill cycle to every
   flushing redirect** (verified against `pc_controller.sv`/`cpu_and_mem.sv`/
   `fetch_provider.sv` timing: target packet N+2 today vs N+3 through a
   flop-only queue). Fixed: FWFT bypass (§2.2), with the honest retraction of
   the "flop-only consume cone" timing claim.
3. **MEDIUM: level-sensitive RAS redirect re-fires under stall** (epoch
   storms, fill thrash, and an undefined partial-flush repeat). Fixed:
   dequeue-fire edge triggering + explicit partial-flush spec (§2.4, §2.2).
4. **MEDIUM: enqueue-vs-flush same-cycle priority unspecified** (phantom
   wrong-path entries after a flush). Fixed: flush dominates enqueue, atomic
   pointer reset, directed unit test (§2.2).
5. **MEDIUM: the B3 width upside was mis-attributed to queue adjacency** —
   the real enabler is 3-word reach, which the FCA had and the 64-bit window
   lacks. Fixed: straddle carry (§2.6); B2 re-scoped to HEAD-parity.
6. **MEDIUM: provider retarget classifier actively consumes
   `o_fetch_replay_consume` and infers redirects from acceptance history** —
   consume-side redirects violate its assumptions. Post-review audit
   (2026-07-05) confirmed and strengthened this: the `accepted_prev_q` shadow
   plus the registered-ask miss engine means an unchased redirect can commit
   a wrong-path DDR line fill. RESOLVED as design decision §6.7 / contract
   §7.1 (explicit `i_core_redirect`, queue-full backpressure,
   `o_fetch_replay_consume` deleted, tag-checked acceptance).
7. Also folded: epoch sizing derived from the single-outstanding provider
   protocol (§2.1); 2-wide binding-bus alignment for slot-1 ask-time vs
   slot-2 walk-time lookups (§2.1); `branch_prediction_controller`
   restructure and `i_disable_branch_prediction` retention (§2.1, §3);
   unit-test migration dispositions replacing "keep if_stage 13/13" (§8);
   timing watch items (§8).

Surfaces the panel attacked and could not break: the self-aligned fill frame
(bugs 1/2), the served-window-guard deletion (bug 4), stall re-present by
immobile head (bug 3), delivery-is-dequeue (invariant 3), slot-1 ask-time
zero-bubble reproduction, halfword-target BTB gating in the fill frame,
sel_nop_2 coupling, the cjpeg-hack dissolution, full `from_if_to_pd_t` field
coverage, and the epoch-filter timing cost.

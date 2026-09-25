# Tomasulo Wrapper

`tomasulo_wrapper.sv` assembles the out-of-order back-end. `cpu_ooo`
instantiates it once. It contains the reorder buffer (ROB), register alias
table (RAT), six reservation stations, the load and store queues (LQ, SQ), the
data MMU, the two-lane CDB arbiter, and the functional-unit shims and CDB
adapters, plus the logic that connects them: commit and CDB registration,
flush distribution, store-conditional resolution, dispatch buffers for the FP
stations, and the early store-address path. The
[back-end overview](../README.md) explains how the pieces fit together.

## What it instantiates

| Block | Count | Notes |
|-------|-------|-------|
| [`reorder_buffer`](../reorder_buffer/README.md) | 1 | |
| [`register_alias_table`](../register_alias_table/README.md) | 1 | |
| [`reservation_station`](../reservation_station/README.md) | 6 | INT, MUL, MEM, FP, FMUL, FDIV |
| [`load_queue`](../load_queue/README.md), [`store_queue`](../store_queue/README.md) | 1 each | |
| [`dmmu`](../../mmu/dmmu.sv) | 1 | Sv39 data translation between MEM_RS issue and the LQ/SQ address updates, bypassed while translation is off. The page-table walker lives in `cpu_ooo`, reached through the `*_walk_*` ports. |
| [`cdb_arbiter`](../cdb_arbiter/README.md) | 1 | Two lanes |
| [`fu_cdb_adapter`](../fu_cdb_adapter/README.md) | 8 | One per CDB slot |
| [FU shims](../fu_shims/README.md) | 6 | `int_alu_shim` ×2, `int_muldiv_shim` (feeds both the MUL and DIV slots), `fp_add_shim`, `fp_mul_shim`, `fp_div_shim` |

The MEM slot's adapter has no shim: its input is a mux of the registered store
fault, the registered SC result, and the LQ result. INT_RS's port-0 issue
packet also goes out on `o_rs_issue` to branch resolution in `cpu_ooo`, and
`o_rs_issue_branch_predicate_tag` is a separate register copy of its ROB tag
that branch resolution uses only for its checkpoint and age compares.

Glue that is large enough to stand alone lives in submodules:

| Submodule | Directory | Contents |
|-----------|-----------|----------|
| `commit_bus_pipeline` | `commit_bus/` | Registers of both ROB commit slots and their decoded fields |
| `dispatch_rs_router` | `dispatch_routing/` | Per-station dispatch valids for both slots, and the slot-1 intent signals |
| `sq_early_addr_pipeline` | `store_addr/` | Early store addresses for both dispatch slots, with persistent repair |
| `sc_pending_unit` | `atomics/` | Store-conditional table and fire decision |
| `lq_coherence_port` | `coherence/` | The core's side of the DMA coherence handshake: holds atomics off an admitted line, invalidates the LQ's copies, and marks loads that observed the line for replay (see the [cache library](../../../../lib/cache/README.md)) |
| `mem_wakeup_merge` | `wakeup/` | Early load wakeup for MEM_RS |
| `tomasulo_perf_counters` | `perf/` | The back-end profiling counters |

The rest stays in `tomasulo_wrapper.sv`: CDB registration, flush
distribution, the MEM-slot input mux, the FP-family dispatch buffers, and the
shim and adapter wiring.

## Parameters

| Parameter | Default | Effect |
|-----------|---------|--------|
| `SPLIT_RS_DISPATCH` | 0 | 1: per-station dispatch packets for both slots, as the CPU uses. 0: the single-slot `i_rs_dispatch` bus, decoded by `rs_type`, for wrapper benches |
| `ENABLE_DISPATCH_DONE_REPAIR` | 0 | Answers dispatch's done-repair queries from the ROB (see the [reservation station](../reservation_station/README.md#done-repair)) |
| `INT_RS_DEPTH` | 16 (`riscv_pkg::IntRsDepth`) | INT_RS entries: a power of two from 2 to 32, the ROB depth. It changes only INT_RS and the width of its occupancy count; port 1's window stays at eight entries, or the whole station if smaller |
| `EARLY_LOAD_WAKEUP` | 1 (`riscv_pkg::EarlyLoadWakeup`) | [Early dependent memory wakeup](#early-dependent-memory-wakeup) |
| `PREPARE_LOAD_WHILE_BUSY` | 1 (`riscv_pkg::PrepareLoadWhileBusy`) | LQ: start a load's store-queue check while the memory port is busy |
| `L0_CACHE_DEPTH` | 128 (`riscv_pkg::LqL0Depth`) | LQ L0 cache entries |
| `CACHED_BASE`, `CACHED_SIZE_BYTES` | `0x8000_0000`, `0x4000_0000` | Cached (DDR) region, for LQ and SQ tier tagging |
| `MMIO_ADDR`, `MMIO_SIZE_BYTES` | `0x4000_0000`, `0x2C` | Served MMIO window, for tagging AMO writes |
| `PERF_COUNTERS` | 1 | 0 leaves out `tomasulo_perf_counters`; `o_perf_counter_data` then reads zero |

`cpu_ooo` sets `SPLIT_RS_DISPATCH=1` and `ENABLE_DISPATCH_DONE_REPAIR=1` and
passes its own values for the rest. Its `PERF_COUNTERS` defaults to 0; FPGA
builds choose it with `build.py --perf-counters`.

## Dispatch routing

`dispatch_rs_router` turns the dispatch packets into a valid bit per station
and slot, and a slot-1 intent bit per station that each station uses to pick
slot 2's entry early. All of them are gated by `i_backend_recovery_hold`. Each
station reports full and full-for-2 status to dispatch; for the FP-family
stations the wrapper adds its one-entry dispatch buffer to that count. The LQ
and SQ allocate from the MEM_RS packets of both slots, slot 1 first.

## Flush coordination

The wrapper receives four flush inputs and distributes them, with the ROB head
tag for age comparisons, to every block.

| Input | Raised for | Effect |
|-------|------------|--------|
| `i_flush_en`, `i_flush_tag` | Branch misprediction recovery | Partial flush: removes work younger than `i_flush_tag` |
| `i_flush_all` | Trap, xRET, and FENCE-class recovery (FENCE.I, SFENCE.VMA, a translation CSR write) | Full flush of everything, including the ROB and RAT |
| `i_flush_after_head_commit` | Commit-time recovery, after the mispredicted instruction retired at the head | Everything left is younger, so the speculative blocks take it as a full flush |
| `i_early_recovery_flush` | Execute-time (early) branch recovery | The LQ's partial-flush input |

The speculative blocks (the stations, adapters, FU shims, data MMU, SC table,
FP-family buffers, coherence port, and the CDB arbiter's `i_kill`, which
suppresses both lanes on a full flush) use two derived terms:
`speculative_flush_all = i_flush_all || i_flush_after_head_commit` and
`speculative_flush_en = i_flush_en && !i_flush_after_head_commit`. The LQ takes
`speculative_flush_all` as its full flush and `i_early_recovery_flush` as its
partial flush. The ROB, the SQ, and the store early-address path take the raw
inputs; the ROB and SQ handle commit-time recovery themselves, and the SQ keeps
committed stores through it. The RAT takes `i_flush_all` only, because
misprediction recovery restores a RAT checkpoint through its own interface.

Since commit-time recovery becomes a full flush, every partial flush that
reaches the speculative blocks and the LQ comes from early recovery. The
wrapper asserts that `i_early_recovery_flush` equals `speculative_flush_en`
whenever `speculative_flush_all` is low. When they differ, the LQ's full-flush
input is also high and clears everything visible.

`i_backend_recovery_hold` is not a flush. While it is high, the wrapper blocks
dispatch into every station, blocks issue, and holds the FP-family buffers.

Some wide payload registers are written even when the write will be
discarded. The SQ writes a store's address and data payload even if the store
faults or a flush kills it, and the SC table writes a tag and address even
when a same-cycle flush vetoes the entry. A separate valid bit, which does see
the flush or fault, is the only thing that makes the payload observable. The
data MMU's pre-kill result pulses follow the same pattern: the SQ uses
`dmmu_out_sq_capture_valid` for payload only, and the LQ uses
`dmmu_out_lq_capture_valid` as its address-update valid because a flush clears
the targeted LQ entry on the same edge.

## Commit and CDB registration

The ROB's commit outputs are combinational. `commit_bus_pipeline` registers
both commit slots, and every internal consumer (RAT commit, SQ commit, SC
discard, the LR reservation clear, and the coherence port) uses the registered
view. The combinational buses are also exported (`o_commit_comb`,
`o_commit_comb_2`) for `cpu_ooo`'s same-cycle misprediction detection.

The registered commit valids are masked by the full flush (`i_flush_all`) in
the flush cycle itself. The valid register clears on the flush edge, but
without the mask its old value would stay visible for that cycle, and a
commit overlapping a trap, xRET, or FENCE-class flush could perform one more
architectural side effect. The SQ's forwarding scan uses the unmasked copies
(`*_valid_raw`); its result is discarded on a flush cycle anyway.

The SQ also receives the ROB's raw store-commit pulses for both slots
(`i_commit_valid_comb`, `i_commit_valid_comb_2`), a cycle before the registered
commit reaches it. They keep its committed-empty status from reading empty
while a just-committed store is still on its way, which a trap such as a timer
interrupt could otherwise act on and squash the store (see the
[store queue](../store_queue/README.md)).

`o_fence_class_flush_event`, `o_translation_csr_commit_shadow`, and
`o_fence_i_flush` come straight from the ROB; `o_fence_i_flush` is the
registered fence event. For FENCE.I and SFENCE.VMA it coincides with the
instruction in the registered commit bus, whose `is_fence_i` bit is set. For a
translation CSR write it arrives a cycle after the CSR has left that bus, with
`is_fence_i` clear. So a registered `is_fence_i` implies `o_fence_i_flush`, but
not the reverse. `cpu_ooo`'s early recovery relies on the forward direction,
which the wrapper formal target checks. `o_tlb_invalidate` is the ROB's
SFENCE.VMA window OR the CSR file's `i_csr_translation_flush_req`.

Both CDB lanes are registered once after the arbiter; the ROB and every station
wake from the registered lanes. The grants stay combinational, so an adapter
can clear its holding register in the cycle it is granted. The wrapper also
keeps same-edge copies of each lane next to particular consumers (per-station
tag copies, an INT_RS copy with its own issue-compare valid and tag, the ROB's
head-match tags, and a 64-bit copy for the store early-address path).
Simulation assertions check that the station and SQ copies always match the
main register.

A registered ALU result does not store a second copy of the ALU output. For
other sources the registered value comes from the arbiter's value tree. For a
live ALU or ALU2 result the wrapper registers only a select bit, and after the
edge takes the value from that ALU adapter's holding register, which captured
the same result on the same edge. This works because the adapter captures
every valid ALU result, which follows from the rule in the next section. The
[CDB arbiter](../cdb_arbiter/README.md) describes the live-value path.

## CDB adapters

| Slot | Adapter | `ALLOW_GRANT_REFILL` | `REGISTER_OUTPUT` | Other |
|------|---------|----------------------|-------------------|-------|
| 0, 7 | ALU, ALU2 | 1 (default) | 0 | `ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0` |
| 1 | MUL | 0 | 0 | |
| 2 | DIV | 0 | 1 | |
| 3 | MEM | 0 | 0 | |
| 4 | FP_ADD | 0 | 1 | |
| 5 | FP_MUL | 0 | 1 | Full flush held for one extra cycle |
| 6 | FP_DIV | 0 | 1 | Full flush held for one extra cycle |

With refill off, a granted adapter always returns to idle, which keeps the
grant out of the FU result FIFO and issue logic. `REGISTER_OUTPUT=1` removes
the same-cycle pass-through, adding a cycle to every DIV and FP result. The FP
multiply and divide shims act on a registered snapshot of the flush (pulse,
flush tag, and head tag), one cycle late, so their adapters treat the cycle
after a full flush as a flush too. The
[adapter README](../fu_cdb_adapter/README.md) describes each parameter.

A pending ALU adapter deasserts its INT_RS port's `fu_ready`, so no ALU result
arrives while it is pending; simulation asserts this for both ALUs. As a
result the ALU adapters never actually refill, their holding register can use
the result's valid bit alone as its write enable
(`ALLOW_GRANT_REFILL_PAYLOAD_WRITE=0`), and that register holds every valid ALU
result for the CDB value restore above.

Test inputs `i_fu_complete_0` to `i_fu_complete_7` feed the same slots in any
cycle the slot's adapter presents nothing. `cpu_ooo` ties them to zero.

## FP-family dispatch buffers

FP_RS, FMUL_RS, and FDIV_RS do not take dispatch packets directly. Each has a
one-entry buffer in the wrapper that captures the packet, applies done repair
to it, and then passes it to the station, so the stations tie their own repair
inputs to zero. Only slot 1 carries FP compute ops, so FP and FDIV use repair
channels 1 and 2, and FMUL, whose FMA takes three sources, uses channels 1
to 3.

Call the cycle after capture E1. The repair response for a newly captured
packet arrives in E1, marked by `*_pending_repair_capture_q`:

- If a source is unresolved and was queried, the buffer holds the packet
  through E1, merges the response, and passes it on in E2 at the earliest. A
  packet with nothing to repair can pass in E1.
- Both CDB lanes update a buffered packet in every cycle it waits. Lane 0 wins
  over lane 1, and both win over the repair response.
- Repair responses are accepted only in E1, so a packet held longer by
  recovery or a full station cannot take a later query's response for the
  same tag.
- FMUL decides at capture whether to hold in E1, from its unresolved-source
  bits alone. That relies on dispatch querying every unresolved source, which
  production dispatch does. FMUL can take a new packet in the cycle it passes
  one on, except during the repair window; FP and FDIV wait for the buffer to
  empty.
- A full flush empties the buffer, and so does a partial flush when the
  buffered packet is younger than the flush tag. No packet passes during a
  flush or `i_backend_recovery_hold`.

## Store address pipeline

A store's address can reach the SQ before MEM_RS issues the store. When a store
dispatches with its base register ready, `sq_early_addr_pipeline` registers the
base and immediate, adds them in the next cycle, and writes the address into
the store's SQ entry, matched by ROB tag. Each dispatch slot has its own
registers, adder, and SQ update port.

A store whose base is not ready becomes the slot's repair candidate. It waits
for its base tag on the done-repair channels or either CDB lane, then writes
its address. If a fresh store holds the slot's SQ port that cycle, the
candidate keeps the base and writes on the next free cycle. A candidate is
replaced by a newer unready store on the same slot (the old store then gets its
address at MEM_RS issue), cancelled when MEM_RS issues the store (the issue
delivers the address anyway), and cleared by any flush. Cancelling at issue
also keeps a stale candidate from writing into a later store that reuses the
ROB tag: a store cannot complete, and so its tag cannot be reused, before
MEM_RS issues it.

While a candidate waits, it writes its provisional address into the SQ entry's
payload without setting the address-valid bit; only the final update makes the
address visible. Under data translation the early address goes through the
data MMU's opportunistic lookup and is dropped unless that lookup hits and
passes every store check; MEM_RS issue translates every store anyway and
reports any fault.

## Store-conditional resolution

MEM_RS issues an SC like a store: its address and data go to the SQ. The SC
does not complete at issue. It waits in `sc_pending_unit`, and fires only when:

- its ROB entry is at the head,
- the SQ is committed-empty,
- its physical address is known (under data translation the data MMU supplies
  it after issue),
- and nothing else is using or about to use the MEM CDB slot: no LQ result, no
  pending MEM adapter, no registered store fault, and no earlier SC result
  still waiting.

The DMA coherence port can also hold SC fires around a DMA write.

The SC succeeds when the LR reservation, held in the LQ, is valid and covers
the SC's aligned doubleword, FROST's reservation granule. The reservation is
cleared when any SC commits, when the SQ launches a write to the same
doubleword, and when a DMA write invalidates the line. The SC's result (0 on
success, 1 on failure) is registered and presented to the MEM adapter in the
following cycle. When a failed SC commits, the wrapper sends `sc_discard` to
the SQ, which drops the entry without writing memory.

The pending table is keyed by ROB tag because MEM_RS issues SCs out of order:
a speculated LR/SC retry loop can issue several SCs before the oldest reaches
the head. Each waits in the table until it is at the head, so a younger SC can
never block the one that must complete first. The table has `SqDepth`
(eight) entries. That is enough because every waiting SC also holds an SQ
entry, so at most `SqDepth` can wait at once. An SC that found the table full
would never fire; a simulation assertion checks that every issuing SC finds a
free entry. A partial flush clears only entries younger than the flush tag,
since an older SC may still be waiting for the head; a full flush clears the
table.

The MEM adapter's input gives priority to the registered store fault, then the
registered SC result, then the LQ result. The fault register cannot wait,
because another store fault can arrive the next cycle, so a colliding SC
result waits behind it. An SC that faults completes through the fault path: the
registered fault strobe kills its table entry before it can fire. Each SC
result must reach the CDB exactly once, since a second broadcast could land on
a reused ROB tag; simulation assertions check this, and they are also part of
the wrapper formal target.

## Early dependent memory wakeup

With `EARLY_LOAD_WAKEUP=1` (the default), a load's result wakes its dependents
in MEM_RS one cycle before the registered CDB broadcast, so a load or store
whose address or store data comes from an earlier load can issue a cycle
sooner. The other stations, the ROB, and the SQ still see the load on the
registered CDB as usual.

`mem_wakeup_merge` places the LQ's staged, non-faulting result into an idle
registered CDB lane on MEM_RS's CDB inputs only. It never displaces a
registered broadcast; if both lanes are busy, the load wakes MEM_RS through
the registered copy a cycle later. The merge is enabled only when the LQ result
is the MEM adapter's input this cycle, with no store fault or SC result ahead
of it and the adapter idle. MEM_RS's look-ahead then exports eight candidate
tags so the LQ's pre-issue match can follow the merged lanes (see the
[reservation station](../reservation_station/README.md#pre-issue-look-ahead)).

Why it is safe:

- Outside recovery, the early token is a real broadcast, not a prediction: a
  presented MEM result always wins a CDB lane, since only MUL outranks MEM and
  the CDB is two lanes wide. The wrapper asserts that every injected packet is
  also broadcast in the same cycle.
- The token is built from registered LQ state and ignores recovery, which keeps
  the flush logic out of the MEM_RS wakeup path. That is still safe. During
  recovery MEM_RS accepts no dispatch and moves no new entry into stage 2, and
  a packet already in stage 2 captured its operands earlier, so a token in a
  recovery cycle can only mark sources ready in surviving resident entries. A
  surviving consumer is older than the recovery point, so its producer load is
  too; that load is delayed, not discarded, and its staged value is final. A
  consumer of a discarded load is younger than it and is discarded in the same
  cycle.
- The early packet never repeats the tag of a valid registered lane: an
  accepted load leaves the LQ's staging register before its registered
  broadcast, and in-flight tags are unique. When the registered broadcast
  arrives a cycle later, the source is already ready or about to receive the
  same value, so the duplicate has no effect.

## Performance counters

With `PERF_COUNTERS` nonzero, `perf/tomasulo_perf_counters.sv` keeps the
back-end counters: ROB head-wait and commit-blocked cycles and their
breakdowns, per-FU back-pressure, memory disambiguation, occupancy sums, L0
hits and fills, and two-wide commit opportunities and blockers. A snapshot is
captured one cycle after the `mperfctl` trigger, on the same cycle as the
top-level and cache counter blocks. See the
[counter reference](../../cpu_ooo/perf/README.md) for indices and definitions.

## Verification

- `tomasulo_wrapper` (cocotb) runs the integration tests with done repair
  enabled: FP-family buffer repair timing, CDB contention, SC flows and
  store-fault collisions, flushes, and stale-tag probes.
  `tomasulo_wrapper_no_early_load` runs the same suite with early load wakeup
  off. `tomasulo_wrapper_split_rs` tests per-station dispatch as the CPU uses
  it, including INT_RS's second-issue window and the local CDB copies.
  `tomasulo_load_wakeup` covers early wakeup across dispatch, CDB contention,
  and recovery, and `tomasulo_coherence` and `tomasulo_coherence_l0_256` cover
  DMA coherence races.
- The `tomasulo_wrapper` formal target checks commit propagation, flush
  composition, INT_RS's side-RAM tag rule against the real ROB, and the SC and
  CDB-copy assertions above, with translation off. Its `fmul_repair_bmc` task
  enables done repair and checks FMUL buffer repair timing and values for all
  three sources.
- In Verilator simulation, the wrapper logs CDB broadcasts that target a free
  ROB entry, naming the FU that produced each, to help track down results that
  escaped a flush.

See the [test runner](../../../../../../tests/README.md) for commands and the
[formal guide](../../../../../../formal/README.md) for proof scope and assumptions.

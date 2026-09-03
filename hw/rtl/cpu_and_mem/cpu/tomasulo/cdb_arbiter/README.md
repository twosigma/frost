# CDB Arbiter

A combinational fixed-priority arbiter selecting up to two of eight FU
completions per cycle for the two CDB lanes.

One balanced merge tree computes both winners together. The leaves are four
contiguous priority pairs:

```
[MUL, MEM]  [ALU, ALU2]  [DIV, FP_DIV]  [FP_MUL, FP_ADD]
```

Each node carries the highest two valid packets and their one-hot source IDs.
Each merge concatenates the higher-priority list before the lower and keeps its
first two valid packets. The pair, four-entry, and root merges bound both
selection cones to three stages. The previous design picked the lane-0 winner
first, masked it out, and ran a second encoder for lane 1, so the lane-1 cone
was serial with lane 0.

Live, non-pending results from the two single-cycle integer ALUs take a
different value path. Their valid, tag, exception metadata, and one-hot
identities go through the tree like every other packet, but their raw shim
values bypass it and are restored at each lane output, selected by the
valid-qualified raw grants. The stage2 -> ALU -> CDB live-value path is
timing-dominant, and this keeps it to one final three-arm value mux per lane.
Held adapter values and test-injected ALU values remain ordinary tree
payloads. Priority and packet contents are unchanged.

Each ALU slot therefore has three auxiliary inputs beside its effective
`i_fu_complete_N` packet: `value_is_live`, `live_value`, and
`tree_fallback_value`. The interface contract is
`value_is_live -> live_value == packet.value`; otherwise
`tree_fallback_value == packet.value`. A live flag is legal only for a valid
packet. For a held packet the wrapper sources `tree_fallback_value` from the
adapter's payload-register Q (`o_held_value`) rather than from the adapter's
pending/live output mux. The two are equal while the adapter is pending, but
taking Q directly keeps current live-shim data out of the tree's fallback
cone. The wrapper asserts this partition from its adapter and shim state. The
standalone arbiter formal harness assumes it instead. Each lane's restore mux
is a `cdb_live_value_restore` instance marked `keep_hierarchy` and
`dont_touch`, so synthesis cannot fold a second copy of the live value back
through the tree.

For registered consumers the arbiter also exports each lane's pre-restore tree
value (`o_lane0_tree_fallback_value`, `o_lane1_tree_fallback_value`) and the
four qualified live selects (`o_lane{0,1}_select_alu_live`,
`o_lane{0,1}_select_alu2_live`). They are aliases of the restore-mux inputs
and carry no second arbitration result. The wrapper registers them at the CDB
edge and repeats the restore after Q, taking the live values from the ALU
adapters' existing payload registers, so the registered CDB value D pins never
see the pre-Q restore mux.

The resulting `o_grant` vector can be 0-, 1-, or 2-hot. Priority, highest
first:

```
MUL  >  MEM  >  ALU  >  ALU2  >  DIV  >  FP_DIV  >  FP_MUL  >  FP_ADD
```

`ALU` and `ALU2` are the two single-cycle integer pipes fed by the
dual-issue INT reservation station; either can win either lane, so a
pure-ALU instruction stream can broadcast two results per cycle.

FUs not selected by either lane are held in their per-FU `fu_cdb_adapter` and
re-presented the next cycle. The deeply-pipelined units (MUL, DIV, FMUL, FDIV)
have additional internal result FIFOs to absorb multi-cycle contention.

## Full-flush kill

The arbiter has an `i_kill` input that suppresses both CDB broadcasts
(`o_cdb.valid` and `o_cdb_2.valid`) and the `o_grant` vector during
speculative full-flush recovery. The wrapper drives it from a local `cdb_kill`
copy of `speculative_flush_all`. The kill is applied here once rather than
inside every `fu_cdb_adapter` output cone, so the high-fanout flush signal
does not route through each adapter's critical path.

The arbiter also exports `o_grant_raw`, the same top-two grant before the kill
gate. It stays active during kill while `o_grant` is forced to zero. It was
added as a flush-independent "would be granted" signal for FU shims that pop
their result FIFOs under kill: popping is harmless because the shim's own
flush input clears the entries on the same edge, and using the raw grant keeps
`cdb_kill` out of the shim FIFO next-state cone. The wrapper leaves
`o_grant_raw` unconnected today. Shims pop when their adapter's registered
`result_pending` bit is clear (the wrapper's `*_result_accepted` signals) and
auto-drain flushed FIFO heads on their own. The kill-gated `o_grant` only
updates that flop, so it reaches the shim pop logic one cycle removed. The
port is driven but unused.

## Verification

Under `` `ifdef FORMAL `` the module carries an independent flat reference:
the previous topology's primary encoder, lane-0 subtraction, and secondary
encoder. Assertions prove the tree's metadata and fallback values, both
reconstructed output payloads, the one-hot identities, raw-grant payload
selection, and the kill-gated outputs equivalent to that reference
(`formal/cdb_arbiter.sby`). The cocotb test (`cdb_arbiter`) exhausts all 256
request-valid vectors with kill low and high, drives the inactive live and
fallback arms with different data so a wrong selection cannot hide behind
identical values, and adds directed live and fallback cases for both ALUs on
both lanes. The wrapper's formal target (`formal/tomasulo_wrapper.sby`) proves
the live/fallback interface contract itself, instantiating the arbiter with
`FORMAL_ASSUME_VALUE_SOURCE_CONTRACT = 0` so the standalone assumptions are
not inherited. Wrapper cocotb tests also cover both ALU effective packets in
the injection, live, and held source states.

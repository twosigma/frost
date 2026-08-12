# CDB Arbiter

A purely combinational fixed-priority arbiter that picks up to two
functional unit completions per cycle for broadcast on the Common
Data Bus. Eight inputs, a primary lane plus a secondary lane, no
internal state.

One balanced merge tree computes both winners together. The leaves are four
contiguous priority pairs:

```
[MUL, MEM]  [ALU, ALU2]  [DIV, FP_DIV]  [FP_MUL, FP_ADD]
```

Each node carries the highest two valid packets and their one-hot source IDs.
Merging a higher-priority list with a lower-priority list picks the higher
list's first packet when present; its second packet comes from the higher
list's second, the lower list's first, or the lower list's second depending on
whether the higher list contains two, one, or zero requests. Pair, four-entry,
and root merges therefore bound both lane-selection cones to three stages and
avoid a serial lane-0 encoder, lane-0 subtraction, and lane-1 encoder.

Live, non-pending results from the two single-cycle integer ALUs are a
value-path exception. Their valid, tag, exception metadata, and one-hot
identities traverse the same tree, but their raw shim values bypass it and are
restored at each lane output from valid-qualified raw grants. Held adapter and
test-injected ALU values remain ordinary tree payloads. Thus the exact priority
and complete combinational output packets are unchanged. Each `o_cdb` value
still crosses one protected final three-arm mux for grant-time observation,
instead of the wrapper's former effective-value mux plus the payload merges.

Each ALU slot therefore has three auxiliary inputs beside its effective
`i_fu_complete_N` packet: `value_is_live`, `live_value`, and
`tree_fallback_value`. The interface contract is
`value_is_live -> live_value == packet.value`; otherwise
`tree_fallback_value == packet.value`. A live flag is legal only for a valid
packet. For a held packet, the wrapper sources `tree_fallback_value` directly
from the adapter payload-register Q, not from the adapter's effective
pending/live output mux; the values are identical while pending, but the direct
Q source keeps current live-shim data out of the tree. The wrapper asserts this
partition from its adapter/shim state, while the standalone arbiter formal
harness assumes it. Two `keep_hierarchy` / `dont_touch` lane-local restore
instances prevent synthesis from recreating a second live-value copy through
the tree.

For registered consumers, the arbiter also exports each lane's tree fallback
value and the four prequalified `{lane, ALU-source}` live-select bits. These are
aliases of the exact inputs to the two combinational restore muxes, not a
second arbitration result. The wrapper captures them at its existing CDB edge
and repeats the same restore after Q from the ALU adapters' already-existing
payload registers. Consequently no registered CDB value D pin depends on the
pre-Q restore mux, while `o_cdb`, `o_cdb_2`, grants, priority, and broadcast
cycle remain unchanged.

The resulting `o_grant` vector can be 0-, 1-, or 2-hot. Priority remains:

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
copy of `speculative_flush_all`. Centralizing the kill here — rather than
replicating it inside every `fu_cdb_adapter` output cone — keeps the
broadly-fanned flush signal from routing through each adapter's critical path.

A raw pre-kill `o_grant_raw` is also exported: it mirrors the top-two
priority-encoder result even during kill, whereas `o_grant` is forced to zero.
It is intended as a flush-independent "would be granted" signal for FU shims
that pop their FIFOs under kill (the entries are being cleared by the shim's own
flush input on the same edge, so popping is harmless), keeping `cdb_kill` out of
the shim FIFO next-state cone. As wired today the wrapper leaves `o_grant_raw`
unconnected — shims instead pop when their adapter's registered
`result_pending` bit is clear (the kill-gated `o_grant` only updates that
flop, so it reaches the shim pop logic one cycle removed) and auto-drain
flushed FIFO heads on their own — so the port is currently driven but
unused.

## Verification

The whole module is small enough to formally verify exhaustively under
SymbiYosys. An independent flat primary/subtract/secondary reference implements
the previous topology under `` `ifdef FORMAL ``; assertions prove the tree's
metadata and fallback values, both reconstructed output payloads, one-hot
identities, raw-grant payload selection, and kill-gated outputs equivalent to
that reference. Cocotb exhausts all 256 request-valid vectors with kill both
low and high, drives divergent inactive live/fallback values, and includes
directed live and fallback cases for both ALUs on both lanes. Wrapper formal
discharges the live/fallback interface contracts without inheriting the
standalone arbiter assumptions; wrapper-level tests additionally cover both
ALU effective packets in injection, live, and held source states.

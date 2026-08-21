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
first two valid packets. Pair, four-entry, and root merges bound both selection
cones to three stages, avoiding serial lane-0 selection and lane-1 exclusion.

Live, non-pending results from the two single-cycle integer ALUs are a
value-path exception. Their valid, tag, exception metadata, and one-hot
identities traverse the same tree, but their raw shim values bypass it and are
restored at each lane output from valid-qualified raw grants. Held adapter and
test-injected ALU values remain ordinary tree payloads. Priority and packets
are unchanged; each `o_cdb` value crosses one protected final restore mux.

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

For registered consumers, the arbiter exports each lane's fallback value and
four prequalified `{lane, ALU-source}` live selects. These alias the restore-mux
inputs rather than forming another arbitration result. The wrapper captures
them at the CDB edge and repeats the restore after Q from existing adapter
payload registers, keeping registered CDB D pins independent of the pre-Q mux.

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

An independent flat primary/subtract/secondary formal reference implements
the previous topology under `` `ifdef FORMAL ``; assertions prove the tree's
metadata and fallback values, both reconstructed output payloads, one-hot
identities, raw-grant payload selection, and kill-gated outputs equivalent to
that reference. Cocotb exhausts all 256 request-valid vectors with kill both
low and high, drives divergent inactive live/fallback values, and includes
directed live and fallback cases for both ALUs on both lanes. Wrapper formal
discharges the live/fallback interface contracts without inheriting the
standalone arbiter assumptions. Wrapper tests also cover both
ALU effective packets in injection, live, and held source states.

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
the previous topology under `` `ifdef FORMAL ``; assertions prove both tree
lanes, their complete payloads, one-hot identities, raw grants, and kill-gated
outputs equivalent to that reference. Cocotb exhausts all 256 request-valid
vectors with kill both low and high, using distinct payload and metadata on
every FU, and includes directed ALU2 lane-0, lane-1, and ungranted cases.

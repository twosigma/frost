# Reservation Station

A generic, parameterized reservation station instantiated six times
with different depths for INT (16), MUL (4), MEM (8), FP (6),
FMUL (4), and FDIV (2) operations. Each instance tracks operand
readiness for its slice of the instruction stream and issues to a
functional unit when both sources (or all three, for FMA) are ready.

INT_RS is sized to absorb the bursty ALU arrivals that dominate
CoreMark — CoreMark profiling showed INT RS full ~7% of the time
with average occupancy ~4 at depth 8, so the queue was doubled
without changing any other RS structure. Everything else
(entry array, wakeup network, priority encoder) scales by parameter.

The wakeup mechanism is the standard Tomasulo CDB snoop: each entry
compares its source tags against the broadcast CDB tag every cycle,
and a match captures the value and marks the source ready. There's
also a same-cycle dispatch bypass — if the source's tag matches the
CDB broadcast on the same cycle the entry is dispatched, the entry
captures the value immediately without waiting a cycle.

Issue selection is a simple lowest-index priority encode over ready
entries. That's not strict FIFO order, but it's a close enough
approximation for the depths used here that the slightly older
entries usually go first anyway.

## Storage strategy

Hybrid FF + LUTRAM. Control and operand fields stay in flip-flops
because they need parallel CAM-style access for CDB tag comparison
across all entries. The read-once payload (operation, immediate,
rounding mode, branch target, prediction metadata, CSR address, …)
is written once at dispatch and read once at issue, so it lives in
distributed RAM with a single write port and a single read port.
This saves a substantial number of flip-flops compared to keeping
the whole entry in registers.

## Pre-issue look-ahead

Each RS emits `o_pre_issue_rob_tag` and `o_pre_issue_needs_lq` one
cycle before the real issue fires. Only the MEM_RS instance is
wired into a consumer: the LQ uses it to pre-register its
address-update CAM match against the incoming ROB tag, so the
LQ entry's `addr_valid` is observable the same cycle MEM_RS issues
(2 LUT levels at issue instead of 5–6). The port is free on the
other instances.

## INT_RS head-wait diagnostics

The INT_RS instance exposes a small query port (`i_head_query_tag`,
`o_head_query_in_rs`, `o_head_query_rs_ready`, `o_head_query_in_stage2`)
wired from the ROB head tag. The wrapper uses these to partition
`head_wait_int` into four mutually-exclusive sub-buckets
(`operand_wait`, `rs_ready_not_issued`, `stage2`, `post_rs`) so CoreMark
profiling can distinguish a head ALU stalled on a producer from one
stuck behind FU arbitration.

## Partial flush

The partial flush input invalidates entries whose ROB tag is younger
than the flush boundary, using the same age-based comparison as
elsewhere in the back-end. Older entries are preserved.

## Verification

Cocotb tests cover dispatch, CDB wakeup for each source slot,
same-cycle bypass, issue priority, FU ready gating, immediate
bypass, and partial/full flush. Inline formal properties prove
the dispatch / issue / wakeup / flush invariants.

# Reservation Station

A generic, parameterized reservation station instantiated six times
with different depths for INT, MUL, MEM, FP, FMUL, and FDIV
operations. Each instance tracks operand readiness for its slice of
the instruction stream and issues to a functional unit when both
sources (or all three, for FMA) are ready.

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

## Partial flush

The partial flush input invalidates entries whose ROB tag is younger
than the flush boundary, using the same age-based comparison as
elsewhere in the back-end. Older entries are preserved.

## Verification

Cocotb tests cover dispatch, CDB wakeup for each source slot,
same-cycle bypass, issue priority, FU ready gating, immediate
bypass, and partial/full flush. Inline formal properties prove
the dispatch / issue / wakeup / flush invariants.

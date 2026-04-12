# Load Queue

The LQ tracks every in-flight load from dispatch through memory access
to CDB broadcast. It also owns the L0 data cache, the LR/SC
reservation register, and the AMO read-modify-write path. Loads
allocate in program order at dispatch and free when their result is
broadcast on the CDB.

## What makes loads interesting

The hard part of an OOO load queue is figuring out *when* a load may
issue. The LQ uses conservative disambiguation: a load can't issue
to memory until every older store address is known. If a matching
older store turns up, the LQ pulls the data from the SQ via
store-to-load forwarding and skips memory entirely. Otherwise it
checks the L0 cache; on a hit, the result is available the same
cycle, and on a miss it issues to main memory.

MMIO loads are an additional case. Their reads can have side effects
(clear-on-read registers, status pulses), so they can't be issued
speculatively. The LQ pins MMIO loads to the ROB head — they only
fire when their entry is the oldest in flight.

FP64 loads (FLD) on the 32-bit memory bus need two sequential
accesses, so the entry has a phase bit and the data field is split
lo/hi in the LUTRAM so each phase writes only its half.

## L0 cache

The L0 is a 128-entry direct-mapped write-through cache, preserved
from the in-order core but moved inside the LQ. It's a hit-path
optimization: loads check it in parallel with SQ disambiguation, and
a hit returns the result the same cycle. Stores invalidate matching
lines on commit (the SQ pulses an invalidate back to the LQ), which
keeps the cache coherent without needing a write-through path of its
own.

## Atomics

The LR reservation register lives in the LQ. LR sets it on
completion; SC clears it; any SQ write to the reserved address
clears it via a snoop. SC succeeds if the reservation is still valid
when SC reaches the ROB head. AMO uses a separate memory write port
on the LQ for the write half of the read-modify-write — the AMO
fires from the ROB head with the SQ committed-empty so nothing else
can interleave.

## Storage strategy

Hybrid FF + LUTRAM. Control fields and the address need parallel
CAM-style scan (for tag match on address update, oldest-first issue
selection, partial flush invalidation), so they stay in flip-flops.
The 64-bit data payload lives in distributed RAM with two write
ports (one for the cache-hit / forward / memory-response path, one
for AMO completion) and is split lo/hi to support FLD's two-phase
fills.

## Verification

Cocotb tests cover allocation, address update, every load size,
SQ forwarding, MMIO ordering, FLD two-phase, FLW NaN-boxing, partial
and full flush, AMO read-modify-write, LR/SC reservation, and
constrained-random stress. Inline formal properties prove pointer
invariants, issue prerequisites, MMIO ordering, and flush behavior.

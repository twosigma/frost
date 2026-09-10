# FROST retirement trace and Spike differential checking

The OOO reorder buffer can emit an architectural retirement trace under
simulation. This is intentionally based on the commit payload, not internal
ROB state, so speculative work never enters the trace.

## Capture

The simulator writes `retire_trace.log` by default. Override the destination
with a simulator plusarg:

```text
+FROST_RETIRE_TRACE=/tmp/frost-retire.log
```

Each line contains one retired instruction:

```text
time=123 slot=0 pc=0000000080001000 rf=I rd=5 rd_valid=1 val=... store=0 branch=0 taken=0 exc=0 compressed=0
```

Both commit lanes are emitted. `slot` and `time` are diagnostic only and are
not part of the architectural comparison.

## Compare against Spike

Run Spike with its commit logger and compare the resulting stream:

```bash
spike --log-commits <spike-args> <program> 2> spike.log
python verif/retire_trace.py retire_trace.log spike.log
```

The checker compares retired PC ordering for every record. If a Spike-derived
logger includes register-write annotations (`xN=0x...` or `fN=0x...`), those are
also compared against FROST's committed destination and value.

Use `--max-records N` to bisect a long trace:

```bash
python verif/retire_trace.py retire_trace.log spike.log --max-records 10000
```

A mismatch reports the first divergent retirement index and both architectural
records, which makes it suitable as a guardrail while changing speculation,
forwarding, cache ordering, or commit logic.

## Scope

This first version deliberately does not compare simulator cycle counts or
ROB tags. It also does not infer store addresses/data from Spike's generic
commit log because Spike output formats differ between builds. Those are
microarchitectural/debug dimensions rather than the minimum architectural
retirement contract.

## Dynamic macro-op fusion profiling

The retirement trace and Spike commit log can be combined to measure the
*dynamic* frequency of the conservative macro-op fusion detector. This is
preferable to static disassembly counts because loops are weighted by actual
execution and dead code is excluded.

```bash
PYTHONPATH=. python tools/fusion_profile.py \
    retire_trace.log spike.log \
    --json build/fusion-profile.json
```

The profiler validates the FROST and Spike retirement PCs before counting
adjacent retired pairs. It reports the overall candidate rate plus the three
fusion classes currently recognized by the RTL detector.

The first implementation target is `LUI+ADDI`; the other classes remain
measured until workload data demonstrates enough dynamic opportunity to
justify fused execution/retirement semantics.

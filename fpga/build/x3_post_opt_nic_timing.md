# X3 NIC post-opt setup closure — 2026-09-10

The NIC-enabled X3 build closes post-opt setup at **WNS +0.035 ns,
TNS 0.000 ns, and 0 failing endpoints out of 559,462**. Native Vivado 2025.2
used the existing `AlternateRoutability` synthesis and `Explore` optimization
defaults for `xcux35-vsva1365-3-e`, with `hello_world` BRAM initialization.

| Scope | Clock period | Worst setup slack |
| --- | ---: | ---: |
| Whole optimized design | Existing clock groups | +0.035 ns |
| CPU clock domain | 3.333 ns | +0.035 ns |
| Fetch PC | 3.333 ns | +0.128 ns |
| Architectural PC | 3.333 ns | +0.373 ns |
| Registered fetch redirect | 3.333 ns | +0.286 ns |
| Loopback MAC clock domain | 24.997 ns | +1.654 ns |

Clock generation and executable constraints are unchanged. The XDC edit only
corrects the stale MAC-frequency comment to describe the existing 40 MHz
loopback clock. No timing exception or clock-period relaxation was added.
The worst remaining setup path runs from L2 MSHR state to a DMA coherence
sequencer state-register enable; its data delay is 3.056 ns.

The optimized netlist contains 217,949 LUTs, 147,267 CLB registers, zero
latches, 232.5 block-RAM tiles, 68 URAMs and 47 DSPs. These are post-opt
counts; the root README's earlier final-implementation resource table is a
separate measurement.

## Implementation

Fetch address computation completes sequential and non-sequential data before
late selection. Ordinary and catch-up request cores share a final slot-1 veto.
When their combined request is true, slot 1 is absent, so catch-up can choose
the plus-two address independently of that late veto. Three preserved scalar
winner bits select canonical slot 2, combined sequential data, or completed
non-sequential data. They preserve the original priorities for arbitrary
controls. Reset clears the three masks; preserved data words stay reset-free.
The original winner and arm observations remain available.

This arrangement reduces the actual slot-1-to-fetch suffix from four LUTs to
three. The canonical request uses two LUTs and retains +0.316 ns of full-design
margin; its target uses one LUT. Completed ordinary sequential data uses two
LUTs. These suffix counts exclude the matched driver cell and come from
through-pin queries on the complete checkpoint.
The calculator preserves its existing run/NOP data cofactors without changing
its equations. Architectural PC selection similarly completes non-sequential
choices before applying the exact sequential winner.

The other CPU cuts balance Bare instruction-PMA decoding, complete prediction
guards and compressed-instruction next-state cases before their late inputs,
and factor pending-prediction holdoffs using the captured predecessor-tag
relation. IF enables the slot-2 handoff simplification proved for its producer;
generic PC-controller instances retain the original veto. The registered
redirect helper, halfword history and frontend control-flow qualifier preserve
their sampled values and cycle timing. PTW request-valid uses an exact
registered copy of its previous expression. The cycle counter completes its
increment before selection, load-queue payloads prevent reset extraction, and
CSR/xRET ROB starts use the stored readiness justified by their allocation
classes; ordinary retirement and exceptions retain CDB bypass.

NIC byte packing uses a two-beat input queue with registered occupancy-based
ready. It adds an initial queue cycle and sustains one beat per cycle while
writes flow. Queued data participates in reset, start, flush, last-beat and
busy handling. DMA eligibility uses an exact registered expression and
completes its request-fire cases before late selection. Live stop/discard
behavior and out-of-range response-ID handling are retained.

## Verification and source binding

The regression matrix has **28 passing groups and 350 passing cocotb cases**.
The final CPU/IF units and CPU/NIC system programs were rerun on the frozen
candidate. Earlier unchanged module tests are retained with source/cone hash
comparisons and their original execution attribution. Current system coverage
includes three fetch-fuzz programs, DDR ITLB/VM/CSR programs, three historical
DDR fetch regressions, NIC loopback, echo and DMA torture. The NIC/VM/CSR
suite's nine program completion timestamps match the preceding candidate;
this supports unchanged progress for those tests. DDR ITLB case Z executes
17 variants six times each.

PC controller 20/20 and IF stage 42/42 tests pass, as do twelve current formal
tasks: four original fetch/architectural mux checks, arbitrary-state fetch
holdoff, captured-tag induction at 32/64/72 bits with default-64 covers, and
integrated handoff BMC, cover and unbounded PDR. The mux checks leave inputs
and PC state arbitrary and abstract calculator outputs; the actual calculator
is exercised by unit and system tests. The tag producer theorem assumes
initial pending-valid zero. These are local and integration proofs, with
their individual assumptions recorded in the formal documentation.

Three final-selection mutations have concrete assertion failures and retained
waveforms: missing slot-1 veto, overlapping canonical/sequential winners and
missing canonical reset. Other module equivalence and mutation evidence keeps
its original scope. The standard ROB cover run completed all twelve goals in
eleven traces, including translation-CSR drain.

All simulations, formal runs and checks used the repository `frost` image in
separate copied checkouts, with `make clean` before each cocotb target. The
pinned versions are Verilator 5.052, Yosys/SymbiYosys 0.68, Python 3.12 and
cocotb 2.1.0. Lint and 264 fast Python tests pass for the timing change.

The native launch manifest covers 1,131 files. CPU system snapshots bind
470 core/support files plus 552 software/runner files; NIC snapshots bind
957 inputs plus 21 additional shared support files. Those inputs stayed
unchanged during their runs. The final PC source differs from the native PC
snapshot only by two assignment line breaks required by lint. Exact diffs,
full-source whitespace identity and preprocessing under synthesis and formal
defines preserve this binding; the original native and test hashes remain
immutable. All 40 native outputs and 28 software initialization/build products
were independently hash-verified.

## Clock crossings and remaining implementation scope

All ten NIC skew groups cover their expected 88 Gray bits and meet the
3.000 ns bound. Reported pointer and counter skew are 0.403 ns and 0.397 ns.
The audit verifies 103 clock-launched first-stage synchronizer endpoints,
seven recognized nonclocked inputs, and all eight asynchronous PRE endpoints.
The two existing CDC-11 reset-fanout findings match the earlier checkpoints;
there are no CDC-10 findings or new NIC CDC critical rows.

This record covers setup in the optimized netlist. Existing DDR calibration
hold slack is -0.520 ns; eighteen DDR BITSLICE PLL/RIU max-skew checks account
for the -0.141 ns pulse-width result. Placement, routing and final timing
signoff remain outstanding. Existing constraint-coverage reports identify
153 no-clock pins, 330 unconstrained internal endpoints, one input without
an external delay and two outputs without external delays. The independent
audit names their DTM/BSCAN, UART and DDR-reset scopes; this change adds no
exceptions to hide those reports.

## Reproduction and retained artifacts

Run Vivado natively from a separate build checkout:

```bash
python3 fpga/build/build.py x3 --stop-after opt
```

`build.py` regenerates the README utilization table on probes. The qualified
checkpoint and initialization products are retained in `fpga/build/x3/work`.
Continue implementation from that checkpoint with:

```bash
python3 fpga/build/build.py x3 --start-at place
```

The qualified `post_opt.dcp` SHA-256 is
`d528aa746a6dcaf0e133f6f59d0acf42101953114ff271c3b93ac0b4f5c9032a`.
The prior canonical work directory is preserved separately when this result
is installed; its location and both artifact manifests are in the promotion
record. The following generated evidence directories are local, ignored by
Git, and should be kept with the checkpoint:

| Evidence | Local record |
| --- | --- |
| Native launch, metrics, source/output hashes and cosmetic source bridge | [probe 17](x3/work_nic_timing_20260909/probe17/) |
| Independent full-design clock, setup, utilization and constraint audit | [timing audit](x3/work_final_timing_audit/README.md) |
| NIC CDC, skew and exception coverage | [NIC audit](x3/work_nic_timing_20260909/nic_cdc_audit/SUMMARY.md) |
| Current and inherited regression scope | [system matrix](x3/work_system_verification/README.md) |
| PC/IF, formal, lint and source identities | [CPU checks](x3/work_candidate17_check/README.md) |
| Independent equation/model review | [review](x3/work_candidate17_review/README.md) |
| Selected fetch implementation and mutation witnesses | [slot-1 experiments](x3/work_nic_timing_20260909/slot1_experiments/README.md) |

The earlier [post-place timing record](x3_post_place_timing.md) describes its
own implementation snapshot.

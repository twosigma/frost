# Single-core performance experiments

The roadmap target remains **open**: 4 CoreMark/MHz at 322.265625 MHz,
routed timing met, with official-length performance and validation runs.
Unless noted, the measurements below are one-iteration cycle-exact diagnostics.
Their synthetic timer frequency does not make them official scores, even when the
upstream report prints ten seconds and valid CRCs. The rated README result
has not been replaced.

The integrated experimental profile achieves **3.9071 CoreMark/MHz** in a
17.47-second X3 run at **161.1328125 MHz** (629.57 CoreMark). Both seed sets
pass CRC validation, and Debian hardware regression passes on that measured
revision. A later fetch-mux optimization had an implicit-net wiring error
under Vivado. The corrected RTL now independently achieves **+0.002 ns
post-optimization WNS** at the target rate and passes all **45 hardware
regression stages at 161.1328125 MHz**. The sustained benchmark result above
remains specific to its measured revision and compiler configuration.

## Implementation

* The LQ response bypass now handles complete 64-bit LD, FLD and LR.D results.
  It retains the existing arbitration, held-result, flush, LR/SC and DMA
  qualification. AMOs still perform their separate write phase.
* MULW uses a dedicated three-cycle 32-bit multiplier; DIVW, DIVUW, REMW and
  REMUW use a seventeen-cycle 32-bit divider. Full-width latencies remain six
  and thirty-three cycles. Each pair shares four completion credits and a
  tracker; a word operation waits if its completion cycle is already reserved.
  `int_muldiv_shim.SHORT_WORD_OPS=0` retains the full-width fallback.
* `EARLY_LOAD_WAKEUP=1` lets the LQ's staged load wake a dependent memory
  operation through an idle registered CDB lane. Both occupied lanes are
  preserved and exceptions suppress injection. The token is formed from
  registered state only; recovery does not qualify it (MEM_RS cannot issue or
  dispatch during recovery), and the merge relies on an asserted tag-uniqueness
  contract instead of a lane-tag comparison. See the
  [wrapper README](../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/README.md).
  This option defaults to **0**.
* `DECODED_QUEUE_DEPTH=4` adds an optional fall-through queue of decoded
  two-instruction bundles. It decouples frontend replacement from dispatch,
  retains prediction metadata, re-reads operands/RAT state at dispatch, and
  preserves CSR/debug/recovery ownership. Dispatch reads a flop mirror of the
  head bundle, and a registered shadow of the instruction words and shallow
  routing flags, never the queue LUTRAM. The default is **0**. See the
  [frontend contract](../hw/rtl/cpu_and_mem/cpu/cpu_ooo/frontend_control/README.md).
* `PREPARE_LOAD_WHILE_BUSY=1` permits inert address staging while another
  client owns the shared port. SQ probes, L0 consumption and memory requests
  still obey the bus-busy gate. It defaults to **0**.
* `INT_RS_DEPTH` defaults to **8**. Sixteen entries help the queued frontend;
  thirty-two add negligible benefit. The parameter is bounded by the existing
  32-entry ROB and changes neither memory capacity nor retirement observation.
  The second INT issue port selects only among the lowest eight entries at any
  depth (`ISSUE2_WINDOW`), which keeps its selector and operand muxes at the
  eight-entry size. This costs 0.5% CoreMark cycles at depth sixteen (below).
* `L0_CACHE_DEPTH` is exposed from `frost` through the LQ. The default remains
  **128**: the measured benefit from 256 entries was negligible. Tested depths
  are 128 and 256. The unchanged coherence/admission bounds and retirement
  observation contract are documented in the [LQ README](../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/README.md).
* X3 builds accept `--cpu-base-clock-hz 322265625`, including the MMCM,
  software timebase, block-design clock metadata and timing-gate period check.
  The default remains 300 MHz. Experimental clocks cannot update the rated
  utilization table. `--single-core-performance` independently selects queue
  depth four, INT RS sixteen, busy-port preparation and early wakeup at synthesis.
  The experimental profile also cannot update the rated table.

No benchmark PCs, instruction sequences or data patterns are recognized by
these hardware changes. No fusion or retirement-count transformation is used.

## Measurement method

Baseline revision: `ffa4e83804989cb69266190a5e1c3928265df787`.
Simulation and formal checks use the repository's `frost` Docker image:
`sha256:85376b1d0d6c39f8896ebde77c3b262db9de393c73d17de13aedcc81d6e5b8d6`.
The image supplies Verilator 5.052, cocotb 2.1.0 and Bootlin GCC 15.3.0
(2026.08-1). Vivado 2025.2 runs natively.

Unless specified otherwise: BRAM code/data, L0 depth 128, INT RS depth 8,
profiling counters absent, C disabled, PGO disabled, stack workspace, default
CoreMark compiler tuning, and the first run after simulator startup.
Compare matching reset/run indices: several predictors and memories retain
state across the second reset. Throughput in these tables is `1,000,000/ticks`.

| Configuration | Timed cycles | Diagnostic CoreMark/MHz |
| --- | ---: | ---: |
| Original RV64 baseline | 295,639 | 3.3825 |
| 64-bit load response bypass | 291,512 | 3.4304 |
| Response bypass, L0 256 | 291,348 | 3.4323 |
| Response bypass and short word arithmetic (defaults) | 289,913 | 3.4493 |
| Response bypass and early memory wakeup | 286,788 | 3.4869 |
| Above plus short word arithmetic | 285,189 | 3.5064 |
| Above with INT RS increased to 16 | 287,239 | 3.4814 |
| Combined changes with opt-in PGO | 277,736 | 3.6005 |
| Combined changes, PGO, `-mtune=generic-ooo` | 275,302 | 3.6324 |

The combined hardware experiment improves throughput by 3.66% over the
original baseline; the defaults improve it by 1.98%. The combined experiment's
early-wakeup option is not the shipped default. PGO
uses the existing official training dataset and is a separate software
configuration; its gain is not attributed solely to RTL.

The generic-OOO compiler experiment also passes the validation seed set
(279,293 cycles). It is not the Makefile default. Increasing its inline limit
from 200 to 400 produces the same cycle counts. Disabling complete loop peeling
is slightly slower; full `-fprofile-use` is substantially slower. Combining the
PGO experiments with LTO triggers a GCC 15.3 internal compiler error during IPA
whole-program analysis. Those failed builds are retained as compiler failures,
not hardware results.

A ten-iteration run of the combined hardware with PGO and `generic-ooo`
tuning takes 2,749,211 cycles for the performance seed set (**3.6374**
diagnostic CoreMark/MHz) and 2,789,279 for validation. Both pass all required
CRCs. This confirms that the one-iteration result is close to the longer
run; ten iterations still fall far short of an official ten-second run.

| Configuration | BRAM performance | BRAM validation | DDR performance | DDR validation |
| --- | ---: | ---: | ---: | ---: |
| Hardware defaults | 289,913 | 291,583 | 401,343 | 402,394 |
| Combined hardware, opt-in PGO, default tuning | 277,736 | 282,982 | 349,294 | 353,808 |

These are first-reset timed cycles with identical required seed/CRC checks.
The DDR runner executes once per clean simulator invocation. The first sweep
attempt incorrectly expected two DDR reports; its successful simulation was
rejected by the archive validator. The corrected runner records the effective
one-run DDR contract, and both DDR seed sets were rerun successfully.

The baseline profile showed about 80.3% L0 hits, 16.2% frontend bubbles,
0.1% ROB-full stalls and 8% INT-RS-full stalls. Doubling L0 increased its hit
rate only slightly; doubling INT RS made this workload slower. MUL downstream
blocking was zero. These observations do not justify raising ROB/LQ capacity,
completion credits, or adding a third lane.

### Decoded queue and load preparation

These comparisons use the same opt-in official-dataset PGO and
`-mtune=generic-ooo` flags, C off, BRAM and L0 depth 128. All rows pass the
performance and validation CRC sets. The integrated four-option configuration
reproduces the inline prototype's first-reset counts exactly.

| Configuration | Performance cycles | Validation cycles | Diagnostic CoreMark/MHz (performance) |
| --- | ---: | ---: | ---: |
| Response bypass, short word paths, early wakeup | 275,302 | 279,293 | 3.6324 |
| Add four-bundle decoded queue | 265,487 | 269,356 | 3.7667 |
| Add inert preparation while the port is busy | 259,706 | 263,604 | 3.8505 |
| Add INT RS 16 (integrated experimental profile) | 256,353 | 260,413 | **3.9009** |
| Above with L0 256 | 256,218 | 260,195 | 3.9029 |
| INT RS 32, L0 128 | 256,330 | 260,385 | 3.9012 |

After the 322 MHz timing changes below, the integrated profile was re-measured
with the same flags. The early-wakeup and queue changes reproduce 256,353 and
260,413 cycles exactly. Adding the eight-entry issue-port-2 window gives
257,702 performance and 262,144 validation cycles (**3.8805** diagnostic
CoreMark/MHz). Both seed sets pass all CRCs. Other rows were not re-measured.

The integrated profile's second-reset counts are 256,457 performance and
260,318 validation. Its first DDR run takes 337,423 performance and 341,594
validation cycles. These remain short diagnostics, not an official result.
The best integrated result combines software and hardware changes; its gain
must not be attributed solely to RTL.

A depth-two queue gives 265,566/269,315 cycles before busy-port preparation;
depths eight and sixteen give no useful improvement over four. Registering
the empty path instead of falling through made the non-PGO workload slower
and was rejected. Four-byte-default instruction alignment also beat the
tested eight/sixteen-byte alignment overrides. Enlarging INT RS only became
useful after the frontend and load improvements: it was slower in the earlier
configuration. With the complete profile, INT-RS-full stalls fall from about
9.2% to 0.7%, average occupancy is 5.46, frontend bubbles are 11.2%, and the
L0 hit rate is 76.7%. ROB/LQ fullness remains too low to justify expansion.

A broader experiment also allowed SQ probes during port ownership. It was
slightly faster, but changed the held-SQ-capture contract. The integrated
option retains that contract and permits only side-effect-free load staging.
A separate concurrent L0-hit/store experiment added negligible benefit and
was not adopted. A later write-update probe retains matching valid cache lines
after partial committed stores and gives 253,606/257,216 cycles (3.9431
diagnostic CoreMark/MHz). It remains outside the integrated profile pending
coherence and timing qualification. Allocating partially known cache lines
adds almost nothing (253,600/257,237); that additional policy is not adopted.
A two-cycle MULW prototype saves only 61 performance and 50 validation cycles,
so the added datapath/timing risk is not justified.
A separate three-cycle low-half 64-bit multiplier leaves both integrated
CoreMark cycle counts unchanged and is also not adopted.
Disabling selective scheduling makes the integrated profile slower
(259,184/263,563 cycles); also disabling the first scheduling pass gives
261,233/265,132. Explicit register renaming or loop unrolling gives
256,354/260,372, effectively unchanged. These probes do not change defaults.

### Compressed-code ensemble

Four deterministic source orders, both official seed sets, all required CRCs
checked. These use the combined hardware experiment and the default compiler
tuning, with no PGO.

| Source order | C off, performance | C off, validation | C on, performance | C on, validation |
| --- | ---: | ---: | ---: | ---: |
| Natural | 285,189 | 286,621 | 302,189 | 302,662 |
| Permutation 1 | 285,222 | 286,665 | 307,129 | 308,127 |
| Permutation 2 | 285,222 | 286,665 | 307,129 | 308,127 |
| Permutation 3 | 285,222 | 286,665 | 307,129 | 308,127 |

C remains disabled by default. The three permuted orders produced identical
loadable binaries despite different ELF hashes. This is a two-layout ensemble
per C/seed configuration, not four independent hot-code placements.

With the integrated queue/preparation/INT16 profile, PGO and `generic-ooo`,
the two distinct compressed layouts give 264,617/266,646 and 264,959/267,095
performance/validation cycles. Their loadable binary hashes differ. Both
layouts pass all CRCs but remain slower than the 256,353/260,413 uncompressed
configuration, so C is still opt-in.

### Locked RV32 reference

The comparison locks the last dual-XLEN revision
`501f777b920f056471a6c65245ea007576c294ca` plus an archived software-only patch
applying the same CoreMark tuning and C/seed controls. Both architectures use
xPack GCC 15.2.0-1, hard-float D ABIs, no C, no PGO, BRAM and profiling counters.
The compiler was extracted from retained image
`sha256:7021bb5f7a15a50f3b04d94ae654d63d53f4b7f8aeb1a09f8594c170b00c8cf7`;
both simulations still run through the current `frost` image.

| Build | First reset | Second reset |
| --- | ---: | ---: |
| Locked RV32, matched tuning | 284,259 | 283,897 |
| Current RV64, combined hardware experiment | 285,626 | 285,000 |
| RV64, integrated queue/preparation/INT16 profile | **277,750** | **277,240** |

The earlier combined experiment missed parity by 0.48%/0.39% more cycles.
The integrated experimental profile **meets the cycle parity gate**, using
2.29%/2.34% fewer cycles than the locked RV32 reference at matching reset
indices. This comparison uses no PGO on either architecture. There is no
extrapolated cycle model. An independent simulator invocation reproduced
both reference RV32 counts exactly.

## Reproducing and retaining measurements

`scripts/coremark_sweep.py` runs every case through `scripts/frost.py`, cleans
the simulator first, validates seed/list/matrix/state CRCs, and saves the
command, settings, compiler/flags, source patch, benchmark sources, ELF,
loadable binaries, disassembly, PGO inputs and SHA-256 hashes. It rejects incomplete
reports and source changes during a sweep. Output must be outside the checkout.
`--runs` controls BRAM reset repetitions. DDR runs once, following the existing
test runner's reset/image-loading contract; the manifest records this explicitly.

```sh
python3 scripts/coremark_sweep.py --output /absolute/new/evidence-directory \
  --orders 4 --compressed 0 1 --memory bram ddr \
  --seeds performance validation --runs 2 \
  --verilator-arg=-GEARLY_LOAD_WAKEUP=1

# PGO is a separately disclosed configuration.
python3 scripts/coremark_sweep.py --output /absolute/new/pgo-directory \
  --orders 1 --compressed 0 --memory bram ddr --runs 2 --pgo 1 \
  --verilator-arg=-GEARLY_LOAD_WAKEUP=1

# Full experimental hardware profile; disclose PGO/compiler tuning separately.
python3 scripts/coremark_sweep.py --output /absolute/new/queued-directory \
  --orders 1 --compressed 0 --memory bram ddr --runs 2 --pgo 1 \
  --verilator-arg=-GEARLY_LOAD_WAKEUP=1 \
  --verilator-arg=-GPREPARE_LOAD_WHILE_BUSY=1 \
  --verilator-arg=-GDECODED_QUEUE_DEPTH=4 \
  --verilator-arg=-GINT_RS_DEPTH=16 \
  --tune-flags='--param max-inline-insns-auto=200 -fira-algorithm=CB -fstrict-aliasing -fselective-scheduling -fbranch-probabilities -fprofile-correction -Wno-missing-profile -mtune=generic-ooo'

# Native Vivado experiment; inspect the final routed report.
python3 fpga/build/build.py x3 --cpu-base-clock-hz 322265625 \
  --single-core-performance --build-dir /absolute/new/fpga-build --stop-after route
```

The local evidence archive for this session is
`../single-core-evidence-2026-09-22/` relative to the checkout. Its manifests
retain full hashes and flags; large binary and implementation artifacts are
kept outside Git. Each experiment retains its own source snapshot because
timing and simulation runs overlap in isolated worktrees.

## Verification and remaining gates

The new MUL/DIV formal target proves completion ownership and credits with
shallow SMT induction, and physical-pipeline alignment with PDR. Neither task
abstracts away the control being checked. Arithmetic is covered by the
existing FU checks and 43 shim tests, including mixed widths, signed overflow,
division by zero, stalls and recovery. The integer division reference model
uses exact integer arithmetic; converting a 64-bit quotient through Python
float was incorrect.

The L0 tests cover 128/256-entry capacity, aliases, overlapping fill/store/DMA
invalidation and randomized operations. All four L0 formal tasks pass. The
load queue's 87 tests pass, including 64-bit response, backpressure, flush,
out-of-order response and LR.D invalidation cases. The early-wakeup merge has
an exhaustive combinational formal check; wrapper tests cover dispatch
positions, occupied CDB lanes, full/partial recovery and dependent load/store
values. The 91 wrapper and six coherence integration tests pass.
The unit-log audit confirms simulator results for 94 configurations in the
initial matrix; the direct wakeup test also passes in a separate clean run.
The subsequently added full-width fallback passes all 43
arithmetic/latency/recovery tests, and the 256-entry L0 with early wakeup passes
all six wrapper coherence tests, including executed loads held before
retirement. Together these cover the 97 unit configurations registered before
the decoded-queue and busy-port preparation additions.
Splitting the LQ pre-issue
tag and valid registers preserves the exact CoreMark cycle count, passes the
existing LQ BMC/cover tasks, and has an unrestricted unbounded equivalence proof.
An audit found that parallel make could return success without rerunning
cocotb: its cleanup and regression targets were unordered siblings. The
result target now depends on cleanup, and the Python runner requires a fresh
XML report containing tests. A separate parallel OpenSBI build race is fixed
by grouping the image packer's output targets. Both fixes have regression
tests. All affected program cases were rerun after a clean and audited against actual
simulator reports: both hardware defaults and the early-wakeup configuration
pass all 83 BRAM cases and all 72 applicable DDR cases (11 expected skips).
`verification/program-matrix-coverage.json` maps each passing case to retained
logs. The original pytest totals alone are not regression evidence. Individually
cleaned benchmark and formal results are unaffected. An enabled-wakeup
Verilator lint run without suppressing combinational-loop warnings is clean.

The initial default/early-wakeup change passes all six Yosys portability
checks, including generic and Xilinx UltraScale+ synthesis of the CPU/NIC.
The subsequent queue integration passes 704 fast Python tests and explicit
lint of tracked and newly added files. Its standalone queue passes three
formal tasks and two 4,000-cycle randomized tests. The optional load-staging
configuration passes all 88 LQ tests and all five LQ formal tasks. The integrated
profile passes all six generic/Xilinx synthesis checks and ten focused full-CPU
checks, including CSR, VM/SATP, debug, FPU, RAS and variable-latency fetch.
Both the inline queue prototype and the extracted module with its additional
CPU assertions pass all 83 BRAM and 72 applicable DDR program cases, with
11 expected DDR skips. The extracted profile's per-case log references are in
`verification/integrated-program-matrix-coverage.json`. The two queue unit
configurations and busy-port LQ configuration complete coverage of all 100
currently registered unit configurations. The defaults also pass all 14
external ISA/benchmark/torture jobs
(1,044 passing cases and seven expected skips). The integrated profile also
passes all 1,044 external cases with the same seven skips, and all eighteen
CoreMark-PRO workload/memory pairs. Its final serial DDR architecture job was
stopped after 93 passes so the remaining 21 cases could run in eight isolated
Docker workers. Every unfinished case passes; the coverage audit matches their
union to the original 114-case group. The interrupted log and continuation
results are retained separately. `verification/integrated-external-matrix-coverage.json`
records the complete external coverage without counting any case twice.

A temporary-filesystem inode limit interrupted several extracted-profile
program cases. The isolated setup also omitted the OpenSBI submodule needed
by its smoke image. Those infrastructure failures are retained, and affected
cases pass after rerunning with the same RTL and pinned dependencies in
worktrees on disk.

### Routed timing

All reports below use the real CPU period and zero **added** setup uncertainty.
Vivado's derived clock uncertainty and other timing requirements remain active.
They are exploratory routes from retained checkpoints, not accepted timing
signoff. More physical optimization did not close these configurations.

| Configuration / checkpoint | CPU MHz | Routed WNS (ns) |
| --- | ---: | ---: |
| Hardware defaults, best placed checkpoint | 300 | -0.239 |
| Above, post-route physical optimization | 300 | -0.221 |
| Hardware defaults, post-placement physical optimization snapshot | 300 | -0.716 |
| Original revision, matched placement/direct-route control | 300 | -0.304 |
| Early wakeup, short word paths, LQ tag/valid retiming, best placed checkpoint | 322.265625 | -0.615 |
| Above, post-placement physical optimization snapshot | 322.265625 | -0.962 |
| Queued profile, inline prototype, best placed checkpoint | 322.265625 | -0.883 |

The 300 MHz direct route has positive hold slack (+0.009 ns); its worst
setup paths include architectural-PC-to-fetch-PC and instruction-memory
paths. The 322 MHz direct route has positive hold slack (+0.007 ns), but
LQ tag/valid and recovery-to-MEM-RS wakeup paths still miss setup. An earlier
-0.974 ns result was **placement** evidence only. The original revision's
matched 300 MHz control also misses timing (-0.304 ns, hold +0.009 ns), so
these checkpoints do not demonstrate a timing regression from the default
changes. They also do not establish 300 MHz closure for either revision.

The queued prototype's 322 MHz route has hold slack +0.008 ns and setup slack
-0.883 ns. Its worst path runs from the ROB value-head staging registers to
INT-RS operand capture; the report also contains a -0.058 ns DDR PHY minimum-skew
violation. Other setup paths within 0.004 ns of the worst involve ROB done
state, decoded-queue selection, early recovery and LQ address staging. Fixing
only the worst operand path therefore would not establish clock closure.
The control and queued physical-optimization sweeps were stopped
after two complete passes without closure; partial third passes are not results.
Their checkpoints, commands and reports are retained. A separate prototype
mirroring the decoded queue head in a register passes FIFO formal/unit checks
but makes best placement slack worse (-0.902 ns versus -0.827 ns). It is not
integrated, and placement is not routed signoff.

### Post-optimization timing at 322 MHz

Synthesis plus `opt_design` only (`build.py x3 --cpu-base-clock-hz 322265625
--single-core-performance --no-perf-counters --stop-after opt`), Vivado 2025.2, zero added
uncertainty. Post-opt delays are estimates, and unchanged paths move by up to
about 0.15 ns between netlists, so compare path families, not single runs.

| Configuration | WNS (ns) | TNS (ns) | Failing endpoints |
| --- | ---: | ---: | ---: |
| Hardware defaults, 300 MHz | +0.070 | 0 | 0 |
| Hardware defaults, 322 MHz | -0.173 | -88 | 1,021 |
| Integrated profile as first integrated | -1.395 | -1,301 | 7,238 |
| Registered-only early wakeup, queue head mirror | -0.569 | -609 | 4,446 |
| Plus registered instruction-word shadow | -0.444 | -130 | 1,503 |
| Plus INT port-2 pre-bypass/shift fields, no merge tag compare | -0.362 | -251 | 1,988 |
| Plus port-2 window, dispatch-flag shadow | -0.471 | -112 | 1,723 |
| Plus shared-path fixes below | -0.266 | -192 | 3,002 |
| Plus operand/predecode, fetch and queue/cache cofactors below (invalidated) | -0.187 | -148.277 | 2,773 |
| Plus fetch, retirement and queue-state cofactors below (invalidated) | -0.049 | -0.049 | 1 |
| Plus final DMMU MMIO capture cofactor (invalidated) | +0.002 | 0.000 | 0 |
| Corrected fetch-LUT control declaration | **+0.002** | **0.000** | **0** |

The three invalidated checkpoints had an undriven control input in the
generated fetch-PC LUTs. Vivado created local implicit nets because the
shared signal was declared after the generate block, then tied those inputs
to zero.
Verilator and Yosys resolved the intended module-level signal, so their
passing checks did not validate that FPGA netlist. The declaration now
precedes its uses, and native synthesis rejects `Synth 8-605` as an error.
Inspection of the corrected full synthesis netlist confirms that all 64
control inputs have the intended nonconstant driver. Fresh synthesis and
optimization reproduce +0.002 ns WNS with zero failing setup endpoints;
this remains a setup estimate with only 2 ps margin, not routed closure at
322.265625 MHz.

The corrected source preserves **257,702 performance / 262,144 validation
cycles** in the frozen-checkout PGO sweep, with all CRCs passing. The
20 PC-controller tests using Xilinx primitive models and all four fetch-mux
formal configurations pass. A diagnostic FPGA image made by reconnecting
only those 64 inputs in the original routed netlist passes all eleven
previously timing-out hardware stages, including DDR execution, ITLB,
interrupt stress, OpenSBI and the full Debian boot/userspace check.

A clean RTL rebuild at **161.1328125 MHz** also passes all **45 hardware
regression stages**, including the nine CoreMark-PRO workloads, Debian
boot/userspace/network checks and DDR ECC. The normal hardware-regression
benchmark configuration scores **587.13 CoreMark / 79.31 CoreMark-PRO**,
unchanged from the failing image's completed benchmark stages.

That rebuilt image has **+0.231 ns setup WNS, +0.010 ns hold slack**, and
zero failing pulse-width/skew checks. All 74 bus-skew constraints also pass.
Its first `RuntimeOptimized` route left one DDR PHY minimum-skew violation;
a fresh `Explore` route did not clear it. The tested image uses a targeted
delay-driven reroute of that DDR branch, with the existing constraints
unchanged. This implementation adjustment is specific to the tested
bitstream; the RTL fix alone does not guarantee routed timing for a new
build. The 322.265625 MHz result above remains post-opt setup timing only.

The -0.266 ns row added changes that also help the hardware defaults:

* The IMEM predecode sideband carries each halfword's RVC-expanded
  instruction bits [24:20] (28-bit sideband). IF selects them beside
  source-hot, so both slots' rs2 fields skip the fetched-parcel
  decompressor on the IMEM-to-PD path.
* `id_stage` exports its next-edge register value, generated from the
  register update, and the decoded queue's registered shadow covers every
  narrow control field (`riscv_pkg::id_dispatch_ctrl_t`), not just the
  instruction word and shallow flags.
* The divider's registered busy flag compares both possible issue outcomes
  and selects with the late MUL_RS issue valid.
* The shared cache's T stage loads its request fields whenever it is not
  holding a live entry, removing the accept decision from their enables.

Synthesis restructures unchanged logic when unrelated RTL changes: the same
IMEM-to-PD RTL mapped to 9 LUT levels in one netlist and 11 in another, and
the decoded-queue dispatch family ranged from -0.22 to -0.58 ns across builds
that did not touch it. Synthesis is deterministic for identical RTL, and
global retiming changed nothing. At that revision, the worst paths (about -0.27 ns)
were the IF next-PC and fetch-address loop (recovery and `satp` into the PC and
IMEM overlay address), ID decode into the queue shadow, and the unreplicated
full-flush register, which placement replicates by design.

The first profile's worst paths ran from full-flush recovery through the
early-wakeup qualifier, MEM_RS wakeup and issue selection into the LQ
pre-issue CAM, and from the queue's LUTRAM head through rename into every
reservation station. At that revision, the remaining worst paths were
mostly shared with the 322 MHz defaults: instruction memory to predecode,
full-flush kill to FU adapters and LQ SQ-check state, the IF prediction
holdoff, and L1-to-L2 requests. Queue-select paths into SQ/MUL_RS dispatch
state remained at about -0.2 ns. Post-opt closure is not routed signoff.

The -0.187 ns checkpoint preserves the profile's pipeline stages and issue
policy while shortening shared combinational paths. The same PGO sweep still
takes **257,702 performance / 262,144 validation cycles**. The pinned Docker
checks pass (704 fast tests), as do all seven synthesis tests and the focused
unit, program and equivalence checks for these changes. This was an intermediate
post-opt checkpoint with negative WNS; placement/routing did not run.
The principal changes are:

* Direct instruction-bit operand classification removes an operation-enum
  decode layer. An exhaustive proof retains the old classifier as reference.
* IMEM metadata grows to 78 bits per fetched word: fetch controls, both
  expanded source-register fields, and the remaining RV64C expansion/illegal
  bits for each parcel. Both instruction slots consume this metadata; the
  stored expansion is proved against the runtime decompressor for all parcels.
* INT RS port-2 allocation uses a one-hot free-entry selector. SQ occupancy
  and dispatch limits compute zero/one/two-allocation outcomes before the
  final valid selection. Queued slot-2 dispatch uses the bundle's existing
  validity contract. Ready RAT operands no longer mask unused producer tags.
* Early memory wakeup omits redundant reset qualification and carries four
  CDB-valid tag candidates into the LQ. Their CAM results and selector cross
  the existing pre-match register edge independently, without an added cycle.
* Recovery carries the flush tag independently of full-flush validity. LQ
  tag ordering uses equivalent unsigned comparisons; AMO response capture
  includes the eventual write-tier classification.
* Fetch keeps live page-offset bits, separates the low BRAM address repeat
  decision from translated-tier selection, and selects RAS checkpoint and
  prediction-validity outcomes after their late qualifiers.
* Cache skid/request admission is factored, the small acknowledgement ID
  queue uses registers, and packed tag UltraRAM banks use cascade height one.
  FMA alignment subtracts exponents directly before shift clamping.
* Binary RS allocation indices share the parallel free-entry masks. LQ
  allocation masks are computed for each cursor origin and selected by the
  registered cursor; its compact cursor and AMO indices keep the original
  search. LQ capacity predicates avoid a serial population-count path.
* Fetch prediction and sequential candidates feed an explicit final LUT6 per
  bit on Xilinx. A separate LUT completes redirect/resteer/hold data; late
  window and progress guards enter only the final requests. Both primitive
  and portable forms are proved against the original PC priority.
* Both BTB slots use grouped full-width tag comparisons. The compressed
  buffer computes both slot-2-valid next states before selecting the late
  validity bit. Recovery payload capture keeps its original valid lifetime,
  and NOP-only direction data remains masked by packet validity.
* DMMU and store-repair MMIO classification runs beside address selection,
  retaining permission and fault priority. LQ response bypass drops the age
  check already excluded by its partial-flush guard. Cached-slot flags keep
  explicit data feedback with reset as their only reset control.
* Each MSHR entry merges fills and store bytes locally, without feeding a
  selected complete line back through every entry's write mux.

The decoded-queue shadow uses `$bits(producer_ctrl)`, avoiding a Yosys parser
limitation on package-qualified type arguments. The Xilinx synthesis runner
loads primitive definitions before hierarchy elaboration so late LUT discovery
cannot reprocess a parent after its original child modules have been pruned.

The checkpoint that reported +0.002 ns adds the following intended
cycle-preserving transformations. Its synthesized fetch mux was incorrect,
as described above, so that margin cannot establish timing closure. The PGO
sweep of its RTL in the frozen main checkout took **257,702 performance /
262,144 validation cycles**, with all CRCs passing. Pinned Docker lint and
all 704 fast tests passed twice. All seven
Yosys synthesis tests, focused unit and CSR/fence/VM program tests, and the
local equivalence checks passed.

* The fetch mux omits unused sequential data from its non-sequential arms,
  completes window/progress choices and slot 1 before the final slot-2 mux,
  and brings sequential data directly into that final LUT6. Fetch holdoff
  follows size selection. Pending-fetch holdoffs compare exact-owner readiness
  and crossing separately. The architectural-PC mux uses a staged/sequential
  LUT5 followed by a reset/redirect/live-prediction LUT6. Pending validity
  selects completed outcomes of the bundle-size miss check, and redirect
  holdoffs complete non-prediction terms before the flags. Slot-2 prediction
  uses the direct staged/live validity expression.
* MEM_RS exports eight raw-CDB/early-load tag candidates, and the LQ registers
  their CAM results on the original edge. Load-result RAM payload selection
  removes redundant write qualification while retaining every write enable.
  FPU payload read pointers select their precomputed next value after the
  acceptance/flush decision.
* Integrated CSR instances use the existing exclusion between CSR commit and
  trap/xRET takes to shorten write and translation-invalidation logic. Generic
  instances retain full priority; port assertions check the integration
  contract, and unbounded local equivalence covers each affected state field.
* ROB done/exception bits compute per-entry allocation outcomes and use local
  tag/live completion checks. Completion still wins allocation, and stale
  completions remain filtered. Replay flags similarly finish allocation-clear
  outcomes before the accepted valids. All three next-state vectors are proved
  against the original indexed assignments from arbitrary state.
* Dispatch CDB deferral resolves tag/repair eligibility before the late RAT
  ready bit, preserving all six source decisions and the existing delivery cycle.
* SQ committed-empty detection completes registered-store status before the
  final combinational commit qualifiers, preserving reset and full-flush priority.
  Occupancy candidates complete allocation increments before the late removal
  subtraction; all three outcomes and the selected next count have local proofs.
* A retirement-only serializer stall omits guards already applied by ROB
  commit gates, while performance counters retain the canonical stall.
* INT RS port-2 issue clears validity directly from its existing accepted
  one-hot selector, preserving the original indexed-clear mask and priorities.
* DMMU MMIO-bit capture selects completed resolution/hold outcomes after the
  late TLB permission/tier classification, preserving its exact next state.

### Sustained hardware measurement

The integrated profile passes both 11,000-iteration seed runs on the X3 at
**161.1328125 MHz**. This is half the target clock, used for functional
validation. Code/data are in BRAM, workspace on the stack, L0 128, INT RS 16,
queue depth four, early wakeup and busy-port preparation enabled, and profiling
counters absent. C is off; official-dataset PGO and the `generic-ooo` flags above
are enabled. Bootlin GCC 15.3.0 (2026.08-1) compiled both images.

| Seed set | Timed cycles | Reported seconds | CoreMark/MHz | CoreMark |
| --- | ---: | ---: | ---: | ---: |
| Performance | 2,815,357,118 | 17.472276 | 3.9071 | 629.57 |
| Validation | 2,860,166,720 | 17.750367 | 3.8459 | 619.71 |

* Performance ELF SHA-256: `bbba451ba46d7271e33c6c5a08e375aaf27bed9ad8581b7046faf9cf17de305e`.
* Validation ELF SHA-256: `85637fe777e1ea9eb66bc3e820c4146aa6888be6398f86e393233c37b4ce2b5c`.

All four required CRCs match for each seed set. The archive's
`hardware-161/coremark-{performance,validation}.json` records the complete
compiler flags, command and measurements; `hardware-coremark-161/` retains
the binaries and build inputs. The software timebase rounds the half-hertz
fraction down to 161,132,812 Hz; the table's normalized score uses timed cycles.
The measured image has routed WNS +0.149 ns and hold slack +0.010 ns, zero
routing errors, and all 74 bus-skew constraints met (minimum slack +2.395 ns).
Its bitstream hash and source snapshot are retained with the programming log.
Hello-world, CSR, VM and FPU hardware checks pass. Debian 13 with the pinned
6.12.107 kernel also passes NFS-root boot, systemd readiness, userspace stress,
cycle/retirement counters, NIC loopback, and root-filesystem recovery. The
end-of-run DDR ECC check reports no errors. The lab board remains programmed
with this 161.13 MHz experimental image.
These official-length runs validate the lower-clock configuration and do not
establish either a 322 MHz timing pass or a score at that frequency.

### General workload comparison

The integrated queue/staging/INT16/early-wakeup profile passes all nine
CoreMark-PRO validation workloads in both memory tiers. The baseline and
candidate use identical
loadable binaries. These are **total program completion cycles**, including
startup and UART output, from fast validation runs; they are not official
CoreMark-PRO scores or isolated benchmark timings. The table compares the first
run after simulator startup; the archive also retains the second BRAM run.

| Workload | BRAM baseline / candidate | DDR baseline / candidate |
| --- | ---: | ---: |
| core | 6,570,548 / 6,193,399 | 8,159,324 / 7,821,524 |
| cjpeg | 326,690 / 319,086 | 446,761 / 444,117 |
| linear algebra | 956,477 / 936,155 | 1,152,639 / 1,148,298 |
| loops | 6,830,812 / 6,712,985 | 7,285,274 / 7,127,813 |
| neural net | 4,789,951 / 4,762,917 | 4,976,277 / 4,987,747 |
| parser | 222,410 / 217,823 | 329,991 / 325,850 |
| radix2 | 1,935,075 / 1,835,127 | 2,431,692 / 2,345,783 |
| SHA | 140,850 / 139,546 | 217,563 / 216,260 |
| zip | 259,663 / 256,626 | 352,464 / 351,835 |

Seventeen of eighteen comparisons improve. Neural net in DDR takes 0.23%
more cycles; this small regression is retained rather than hidden in an
aggregate score. `integrated-coremark-pro-comparison.json` retains per-pair
hashes, source/command references and cycle counts. The earlier nonqueue
configuration improved all eighteen comparisons and remains archived in
`coremark-pro-comparison.json`. That earlier candidate's core BRAM artifact was
reproduced after a later workload overwrote the working binary; that original
mismatched capture is retained separately and is not used for the comparison.

Still required before closing the roadmap target:

* Reach 250,000 cycles per CoreMark iteration at the target configuration,
  then validate an actual run of at least ten seconds at 322.265625 MHz.
  Use at least 14,000 iterations at the target throughput and check elapsed
  time; the rated 300 MHz default remains 11,000 iterations.
* Meet routed timing with the profile that passes equally tuned RV32 parity.
* Complete general-workload regression and hardware Linux checks for the
  candidate that meets timing.
* Complete physical qualification of the decoded queue and evaluate wider fetch delivery.
  The current no-C CoreMark image fits the 64 KiB overlay, so simply enlarging
  that overlay cannot remove this benchmark's remaining frontend bubbles.
  The fixed 64-bit fetch window and its compressed-code penalties remain.
  An isolated experiment advancing native fetches by eight bytes broke
  control-flow handling and was rejected. Fetch requests, buffered parcels,
  prediction ownership and architectural PC advance must be changed together.

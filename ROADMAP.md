# FROST Roadmap

FROST is evolving from its original RV32GCB M/U-mode design into an RV64GCB
core with S-mode and Sv39 that boots mainline MMU Linux, followed by a stock
riscv64 distribution, a multi-hart SMP system, and explicit RV64 performance
parity with the best the former RV32 design could have reached. Phases are
sequential; each one keeps every existing suite green (riscv-arch-test,
riscv-tests, torture, formal, the cocotb program suites in both memory tiers,
the Linux boot jobs), re-closes X3 timing at 300 MHz post-route before it is
called done, keeps the core RTL vendor-primitive-free, and updates the
documentation it makes stale.

## Phase 0: Harden the Linux substrate (done)

Retire the post-link kernel mutation the no-MMU boot relied on, prove the
unpatched kernel boots in simulation and on hardware, add a userspace stress
payload to the boot jobs, document the boot ABI, and expose Zicntr to
userspace through `mcounteren`.

## Phase 1: RV64GCB (done)

Widen the core to XLEN=64 (still M/U, still no-MMU) before changing the
privilege architecture, so the MMU is built once for Sv39: a native 64-bit
data tier, RV64 I/M/A/F/D/C, 64-bit CSRs and traps, the rv64 test matrices
and an rv64 no-MMU Linux image in CI. Exit met 2026-08-12 with X3 timing
closed at 300 MHz; rv32 support was retired once the RV64 design and X3
hardware flow were established.

## Phase 2: Memory-level parallelism (done)

Tagged line transactions with several in flight through the adapter,
arbiter and AXI bridge; a non-blocking cache at every level; four cached
loads in flight at the load queue; two line fills in flight at the fetch
provider behind a victim store; ids composed per port so a walker or a
second hart is one more port. Exit met 2026-08-23: overlapped demand misses
measured by the new counters, CoreMark-PRO improved on X3, and the
page-table-walk account in hw/rtl/lib/cache/README.md.

## Phase 3: S-mode, Sv39, and MMU Linux (in progress)

S-mode CSRs and delegation, Sv39 with ITLB/DTLB and a hardware page-table
walker, PIPT translation ahead of the cached tier, PLIC, OpenSBI as the
M-mode firmware, and a RISC-V debug module early in the phase. Verification
adds the privilege/VM suites, torture with paging, and directed TLB tests.
Exit: mainline rv64 MMU Linux (Buildroot userspace) boots unpatched in CI and
on hardware, with working `perf` basics.

Immediate priority (2026-09-05): recover the Phase 3 hardware performance
regression before further feature work. The latest functionally passing X3
CoreMark-PRO sweep scored 137.65 against the existing 146.65 baseline (-6.14%).
The unchanged tuned default-BRAM CoreMark binary took 354,091 / 353,755 cycles
before recovery. Expanding the low-BRAM scalar predecode overlay from 16 to
64 KiB recovers 305,059 / 304,727 cycles with identical executable bytes;
frontend bubbles roughly halve, while transient width kills barely change.
Matched tiny CoreMark-PRO probes with verification disabled (`-v0 -i1`)
reduce the scored MITH workload timer from 66,978 to 56,520 cycles for parser
(-15.61%) and 139,695 to 129,059 for JPEG (-7.61%). Each RTL pair uses
identical executable bytes, compiler settings, and datasets. A private,
post-PASS read-only observer reconstructs exact cycles from the benchmark's
retained timestamps; it adds no simulated cycles or benchmark instructions.
These timed intervals exclude final reporting, unlike the larger end-to-end
test gains, but still use tiny inputs, not the official hardware workload.
Separate default verified tests pass for all nine workloads, as do the
capacity/boundary, frontend, branch/ITLB, interrupt/return-hazard, debug, and
programming-reload regressions. All nine official binaries' executable
sections fit below 64 KiB; cached-DDR datasets do not consume that coverage.
Fresh native post-opt is +0.055 ns WNS / zero TNS, versus +0.052 ns before,
with a 0.98% post-opt LUT increase and unchanged BRAM/URAM/DSP counts.
The official hardware sweep is still required to establish recovery of the
full -6.14%; do not infer the aggregate score from tiny-input simulations.
Keep benchmark sources, compiler settings, workloads, and baselines fixed;
require functional regression coverage and fresh native synthesis/post-opt
timing no worse than the pre-recovery +0.052 ns WNS / zero setup failures at
300 MHz. Candidate runs must not overwrite the active implementation flow.
This recovery is part of Phase 3 now; the broader RV32-counterfactual parity,
fusion, capacity, and width work remains in Phase 6.

## Phase 4: System I/O and distribution

SD storage, Ethernet, and a stock riscv64 Debian from persistent storage.
Exit: log into Debian over SSH on hardware, install a package with apt, and
survive a multi-day soak.

## Phase 5: SMP

Two harts on the X3 sharing an L2 as the point of coherence, IPIs, per-hart
PLIC contexts, and litmus-test coverage of RVWMO across harts. Exit: 2-hart
SMP Debian with measurable scaling, timing held, and a multi-day soak.

## Phase 6: RV64 performance parity

Make RV64 match or exceed the score that an equally tuned RV32 build could
have reached, rather than comparing tuned RV64 with the retired untuned RV32
binary. The compiler retune recovers XLEN-independent headroom: under matched
settings with C retained in both ABI lanes, Spike still measures 251,089
timed-region instructions for lp64d against 221,578 for ilp32d, a 13.3%
architectural instruction penalty. The former RV32 hardware also had 8-byte
CoreMark list heads where lp64d has 16-byte heads. RTL cannot make those ABI
facts disappear, but it can prevent them from costing cycles. The initial
planning bar is approximately 1,100 CoreMark at 300 MHz; that is a
counterfactual estimate from instruction counts, not a measured result, and
must be replaced by a reproducible reference before it becomes an exit
criterion. Immediate regression recovery has moved to Phase 3. With the former
16 KiB low-memory predecode overlay, a matched two-run build A/B averaged
361,535 stock versus 353,923 tuned cycles: tuning removed 11.7% of retired
instructions but only 2.11% of cycles as IPC fell from about 0.78 to 0.71.
The tuned build had no 64-bit-window slot-2 kills; 55.6% of its width kills
were aligner/BRAM transients, versus 21.0% stock. The 64 KiB overlay recovers
304,893 mean cycles on the identical tuned binary by roughly halving frontend
bubbles, not by removing the remaining transient width kills. Keep those two
limitations distinct when planning further width work.

Work in measured order:

- Lock the reference first. Preserve matched rv32/rv64 compiler inputs, add
  dynamic instruction-class and stall attribution, and establish the tuned
  RV32 counterfactual from the last dual-XLEN RTL or an equivalently calibrated
  trace model. Keep the official 2,000-byte workload, both required seed sets,
  CRCs, exact compiler and flags, memory/cache ratios, ELF hash, and a
  minimum-ten-second X3 run with every published result. Use link-order
  ensembles whenever C is enabled so placement luck is not mistaken for RTL
  improvement.
- Build on the Phase 3 front-end recovery. Out-of-overlay low-BRAM instruction
  windows repeat once for registered predecode metadata, making a larger tuned
  binary pay a penalty that the old RTL and smaller stock binary largely avoid.
  The 64 KiB scalar overlay has recovered the initial simulation checkpoint:
  304,893 mean cycles versus roughly 354k before, close to the 305,064-cycle
  result on the tuning branch's base RTL. For code beyond that capacity, compare
  further capacity with a small tagged predecode-window cache or stream buffer,
  and let a decoded-instruction queue absorb any unavoidable response repeat.
  Select by transient-kill and front-end-bubble counters, FPGA cost, and
  post-route timing rather than by CoreMark placement. Preserve the
  variable-latency fetch contract and the 300 MHz target.
- Remove the fetch-layout ceiling. Replace the fixed 64-bit-window limitation
  with a sliding parcel buffer or a 96/128-bit fetch queue that can deliver any
  two consecutive legal instructions, including an odd-halfword 32b+32b pair
  crossing the old window. Re-enable C only when an ensemble shows stable
  throughput. This is a general front-end correction, not parity credit by
  itself unless the differential measurements show that RV64 benefits more.
- Make 32-bit semantics cheap inside RV64. Use the rv32/rv64 dynamic trace to
  identify the actual excess `sext.w`, `zext.h`, and related producer/consumer
  pairs. Add only general, formally proved macro-op fusion or rename-time
  elimination for safe pairs; fused instructions must still count correctly in
  `minstret`, preserve precise state, and be disabled or exposed correctly for
  debug single-step. Track known sign-/zero-extended results so redundant high
  halves need not consume full-width CDB, reservation-station, and ROB routing.
  Give `MULW` a real 32x32 path and `DIVW`/`REMW` a 32-bit divider path: today
  the W-form divide shares the 64-bit, 33-cycle pipeline, versus 17 cycles in
  the former RV32 configuration. Reconstruct the architectural 64-bit result
  only at the boundary.
- Restore pointer-chase capacity and latency. The current LQ L0 is 128
  direct-mapped 8-byte entries, so an RV64 16-byte list head consumes two lines
  where the RV32 8-byte head consumed one. Evaluate at least a 256-entry L0,
  then associativity or skewed indexing if conflict counters justify it, so the
  effective node capacity is no worse at lp64. Add a CDB-to-memory wakeup/AGU
  bypass so a dependent next-pointer load can begin its L0 lookup on the next
  cycle; consider a generic load-PC-trained dependent-load prefetcher only if
  capacity and bypass work leave measured pointer stalls.
- Spend wider state only where counters demand it. A small decoded-instruction
  queue can absorb fetch and prediction bubbles before changing global width.
  If extension fusion and the memory path do not close the remaining gap,
  increase the 32-entry ROB, 8-entry integer/memory stations, and 8-entry LQ in
  isolation, then consider a third dispatch/commit/integer lane. Width-aware
  storage should first reclaim the FPGA area and timing lost to mechanically
  doubling every RV32 payload, so none of these changes buys score by lowering
  the 300 MHz clock target.

No mechanism may recognize CoreMark functions, PCs, data patterns, or the
benchmark binary. Each step must improve a generic microarchitectural event,
survive the full verification matrix, re-close X3 timing at 300 MHz, and show
no material regression in CoreMark-PRO or Linux workloads. Exit requires the
best rule-compliant RV64 build to meet or beat the locked tuned-RV32 reference
in cycle-exact simulation and in an official-length X3 run, with both CoreMark
seed sets validated and the complete reporting metadata retained.

## Deferred

A general 3-wide redesign beyond the measured Phase 6 fallback, an ASIC
tape-out, the V/H/crypto extensions, and Sv32 are out of scope until the phases
above are complete and there is demand for them.

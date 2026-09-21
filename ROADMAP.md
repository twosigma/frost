# FROST Roadmap

What is left to build. Work that is finished is described by the thing itself
and recorded in the git history; it is not repeated here.

FROST today is an RV64GCB out-of-order core with S-mode and Sv39 on an Alveo
X3522PV, booting a stock Debian 13 riscv64 from an NFS root over its own
10GbE NIC, closing routed timing at 300 MHz and scoring 1015 CoreMark on the
board. Phases are sequential; each one keeps every existing suite green
(riscv-arch-test, riscv-tests, torture, formal, the cocotb program suites in
both memory tiers, the Linux build and QEMU boot jobs, and the hardware
regression's Linux stage), re-closes X3 timing post-route before it is called
done, keeps the core RTL vendor-primitive-free, and updates the documentation
it makes stale.

## Phase 5: RV64 performance parity

Make RV64 match or exceed the score that an equally tuned RV32 build could
have reached, rather than comparing tuned RV64 with the retired untuned RV32
binary. The compiler retune recovers XLEN-independent headroom: under matched
settings with C retained in both ABI lanes, Spike still measures 251,089
timed-region instructions for lp64d against 221,578 for ilp32d, a 13.3%
architectural instruction penalty. The former RV32 hardware also had 8-byte
CoreMark list heads where lp64d has 16-byte heads. RTL cannot make those ABI
facts disappear, but it can prevent them from costing cycles. The target is
4 CoreMark/MHz at 322.265625 MHz, so 1289 CoreMark, single core, measured on
the board. That clock is this design's original target, reached by the MMCM
recipe kept as a comment in `boards/x3/x3_frost.sv`: a 10GbE line-rate
frequency, exactly twice the MAC's 161.1328125 MHz fabric word clock, though
still a separate domain from it. The 300 MHz in place today is a retreat taken
to make closure easier. Against what the design delivers today, 1015 CoreMark
at 300 MHz measured on the board, 3.38 CoreMark/MHz, the target is a 1.27x
step: 7.4% from the clock and 18.2% from work per cycle. It replaces an
earlier planning bar of approximately 1,100 CoreMark, which was a
counterfactual from instruction counts rather than a measurement. For outside reference, the highest soft-core CoreMark measured on FPGA fabric
that a survey of vendor, academic and EEMBC sources could identify is 452 at
100 MHz, and no soft-core CoreMark has been published above 200 MHz; per-MHz
figures up to 4.5 exist at those clocks, which is why the bar here is work per
second at a clock the design closes, with CoreMark/MHz recorded beside it as a
diagnostic.
The immediate regression this replaced has already been recovered, by
expanding the low-BRAM scalar predecode overlay from 16 to 64 KiB. With the
former
16 KiB low-memory predecode overlay, a matched two-run build A/B averaged
361,535 stock versus 353,923 tuned cycles: tuning removed 11.7% of retired
instructions but only 2.11% of cycles as IPC fell from about 0.78 to 0.71.
The tuned build had no 64-bit-window slot-2 kills; 55.6% of its width kills
were aligner/BRAM transients, versus 21.0% stock. The 64 KiB overlay recovers
304,893 mean cycles on the identical tuned binary by roughly halving frontend
bubbles, not by removing the remaining transient width kills. Keep those two
limitations distinct when planning further width work.

Sequencing: this phase runs before SMP by choice -- single-hart performance is
wanted sooner than a second hart -- so its structural changes are chosen against
one hart's envelope, which already carries the NIC's DMA traffic, not
against the two-hart resource, timing, and memory-latency envelope Phase 6 adds
(a shared L2 as the point of coherence, and coherence traffic between harts).
That is a known cost of the order, not a reason the integrated envelope stops
mattering: a widened hart that just closes 300 MHz alone can lose its return
once duplicated, so every capacity and lane size chosen here is revalidated when
the second hart lands, and some of it may have to be given back to hold timing
and coherence then. The DMA coherence contract -- a coherence sequencer walks
every DMA request through the L1D and the load queue before the shared level
orders it -- is not deferred along with the inter-hart one: anything that alters transaction semantics, tracking
coverage, or resource dependencies is a renewed coherence review against it,
not a free capacity tweak; record with it the parameter bounds and the
admission and service dependencies the change relies on, so Phase 6 can
establish the inter-hart contract over a structure it can enumerate. Measure
single-hart parity and SMP scaling separately: parity is a single-hart result
against the locked RV32 reference (a measurement with one active hart in the
SMP design also counts), reported apart from the two-hart throughput and
interference Phase 6 adds.

Work in measured order:

- Lock the reference: preserve it now, finalize it before Phase 5 evaluation.
  Archive the selected dual-XLEN revision with its matching environment (image
  identity and bytes, compiler, Vivado version), benchmark inputs, ELF, run
  commands, and existing results and X3 timing evidence -- git keeps sources, not
  the environment or which configuration actually worked -- and verify one short
  RV32 reproduction so the archive is known usable. Define the reference and
  comparison rules now: a named frozen RV32 microarchitecture, or a specific
  validated model ("best the former design could have reached" is otherwise
  unbounded). Preserving does not require finishing the RV32 retune, the dynamic
  instruction-class and stall attribution, or a trace model now; any modeled
  reference must be validated against retained RV32 timing evidence, with its
  uncertainty and pass criterion stated (an approximate reference is not made
  exact by running the RV64 candidate in cycle-exact simulation). Keep the
  official 2,000-byte workload, both required seed sets, CRCs, exact compiler and
  flags, memory/cache ratios, ELF hash, and a minimum-ten-second X3 run with
  every published result. Use link-order ensembles whenever C is enabled so
  placement luck is not mistaken for RTL improvement.
- Build on that front-end recovery. Out-of-overlay low-BRAM instruction
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
  the clock target.

No mechanism may recognize CoreMark functions, PCs, data patterns, or the
benchmark binary. Each step must improve a generic microarchitectural event,
survive the full verification matrix, re-close X3 timing at the target clock,
and show no material regression in CoreMark-PRO or Linux workloads. Exit
requires 1289 CoreMark, single core, from an official-length X3 run at
322.265625 MHz with routed timing met there, and the best rule-compliant RV64
build meeting or beating the locked tuned-RV32 reference in cycle-exact
simulation, with both CoreMark seed sets validated and the complete reporting
metadata retained.

## Phase 6: SMP

Two harts on the X3 sharing an L2 as the point of coherence, IPIs, per-hart
PLIC contexts, and litmus-test coverage of RVWMO across harts. Before the second
hart, establish the coherence contract -- including the DMA model above --
over resident LQ L0 data, outstanding fills, executed-but-unretired loads (the
LQ frees an entry at CDB capture, before retirement, so a snoop of live entries
does not cover them), AMOs, and LR/SC reservations, and validate a baseline
whose admission and service rules keep coherence traffic making progress at
saturation -- probe data and acknowledgements must be able to escape, not merely
enter a queue. This phase inherits the capacity and lane sizing Phase 5 chose
for single-hart performance instead of setting them: the safety and progress
obligations have to be re-established over that structure as it stands, and
holding them may mean giving some of it back. Freeze those obligations and the
parameter bounds they require. Exit: 2-hart SMP Debian with measurable
scaling, timing held, and a soak sized the way the networking one was: hours
under sustained load, long enough to exercise each recovery path repeatedly.

## Unscheduled

Memory errors reach nobody. The DDR4 is ECC-checked, but the controller's
interrupt is unconnected, `ECC_EN_IRQ` is clear, and the AXI bridge ignores the
error responses it is given (`line_port_axi_bridge.sv` checks them only in
simulation), so an uncorrectable error is consumed as data. Nothing scrubs, so
correctable errors sit until they become uncorrectable, which matters most
across the long soaks. `CE_CNT` saturates at 255 and means nothing unless it is
read and cleared; the regression's `ddr_ecc` stage reads it once a run, which
catches gross breakage but is not reporting.

## Deferred

A general 3-wide redesign beyond the measured Phase 5 fallback, an ASIC
tape-out, the V/H/crypto extensions, and Sv32 are out of scope until the phases
above are complete and there is demand for them.

Two storage paths are optional and unscheduled: iSCSI with ext4 if a workload
needs local-disk filesystem semantics, and a host-backed PCIe/virtio block
device as a deployment capability. Neither replaces the NFS root.

# FROST Roadmap

## Single-core performance

The goal is 4 CoreMark/MHz at 322.265625 MHz, or 1,289 CoreMark on one hart,
up from 3.91 CoreMark/MHz. That rate was measured on the board at 161 MHz, on
a build whose second integer issue port scanned all 16 reservation-station
entries; the default scans eight, which in simulation takes about 0.5% more
cycles. A score counts only from a run of at least ten seconds that passes
the CRC checks for both official seed sets, with the compiler flags, the
`sw.bin` hash, and memory and cache settings recorded. RTL changes must also
keep routed timing at the target clock.

The RV64 core must also match or beat FROST's earlier RV32 configuration,
tuned the same way, in cycle-exact simulation. The
[performance guide](docs/single_core_performance.md#comparing-changes)
describes the reference and the comparison method.

Priorities, guided by the performance counters and timing reports:

1. Fewer front-end bubbles. Beyond the four-bundle decoded queue and the
   64 KiB predecoded region of BRAM, compare a larger predecoded region with a
   tagged predecode cache or a stream buffer. Fetch must keep working with
   variable-latency memory.
2. Pairing across fetch windows. The front end pairs two instructions only
   when both fit in one 64-bit fetch window. Removing that limit lets any two
   consecutive instructions pair. Then measure compressed code across
   different code layouts: CoreMark runs without compressed instructions for
   now, and should use them again once throughput is stable across link
   orders.
3. Cheaper 32-bit operations on RV64. `MULW` takes three cycles and word
   division or remainder seventeen. Use instruction traces to evaluate fusion
   or elimination at rename. Any such transformation must keep precise
   exceptions, retirement counts, and debug single-step behavior, and be
   formally verified.
4. Lower pointer-chasing latency. Response bypass, early wakeup of
   dependent loads, and load preparation while the memory port is busy are in
   place. Next, try associativity in the load queue's L0 cache if its conflict
   counters justify it, then prefetching for dependent loads. A 256-entry L0
   added little over the default 128 entries.
5. Queue capacity where counters show pressure. Sixteen INT
   reservation-station entries capture the measured benefit; larger INT RS,
   ROB, and load-queue sizes currently show little gain. A third lane is worth
   considering only if front-end and memory work leave issue width as the
   limit.

Performance changes must improve general workloads, never by recognizing
benchmark code, PCs, or data patterns. They must pass the full regression in
both memory tiers, keep DMA coherent and the core RTL portable, meet the
target clock, and not materially slow CoreMark-PRO or Linux. Changes to the
load queue, its L0 cache, or queue capacities must also update the DMA
coherence argument: the parameter bounds, and why DMA admission and service
still make progress, including for loads that have not yet retired.

## SMP

Two X3 harts sharing the L2 as their coherence point, with inter-processor
interrupts, per-hart PLIC contexts, and RVWMO litmus tests. The single-hart
queue sizes and lane choices will need revisiting against the timing and
memory-traffic cost of the second hart.

Before implementation, the coherence design has to cover everything a hart
can hold: L0 data, outstanding fills, executed but unretired loads, AMOs,
LR/SC reservations, and DMA. Snooping live load-queue entries is not enough,
because an entry is freed as soon as its result is staged for the common data
bus, before the load retires. The DMA observation table, which tracks loads
until they retire, is the starting point. Probe data and acknowledgements must
keep making progress when every queue is full.

Done means Debian running on both harts, multi-hart scaling reported
separately from single-hart performance, routed timing met, and hours of
sustained-load testing that repeatedly exercise the recovery paths.

## Memory error handling

The DDR controller counts ECC errors, but nothing reports them to software:
its interrupt is unconnected and `ECC_EN_IRQ` is clear. The cache hierarchy's
AXI bridge checks error responses only in simulation. The plan is to connect
ECC reporting, propagate AXI errors to software, and add scrubbing and
periodic reporting (`CE_CNT` saturates at 255, so it must be read and
cleared). The hardware
regression checks ECC once at the end of a run, which catches errors but is
not continuous monitoring.

## Deferred

These wait for demand: a general three-wide redesign, an ASIC
implementation, the V and H extensions, the full crypto extensions, and Sv32.
Storage beyond the NFS root, such as iSCSI with ext4 or host-backed
PCIe/virtio block devices, is possible; NFS remains the supported root
filesystem.

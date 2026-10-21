# FROST Roadmap

[Prof. John Goodacre](https://github.com/goodacre-manchester) is helping to
set the direction of this roadmap. The sections are in priority order.

## Memory system

The L1D, L1I, and L2 are 4-way set-associative with tree pseudo-LRU
replacement, one design for every target. The L1D inserts lines bimodally: a
fill becomes its set's most recently used only one time in 32, so a working
set somewhat larger than the L1D keeps part of itself resident instead of
evicting each line just before its next use. The L1s read every way's data at
the tag decision, so their hits take as long as the direct-mapped caches'
did. The L2 reads its data after the tag compare picks the way, one cycle
more than a parallel read.

The L2 uses 64-byte lines, following John Goodacre's design. An adapter maps
each 32-byte request from the L1 caches, the page-table walker, and the DMA
port onto its half of a line. The L2 writes back only whole lines, each as a
single 512-bit AXI transfer that the X3's ECC DDR4 controller takes without
a read-modify-write, and a 32-byte write that misses fetches its line and
merges into it. Two costs of the design remain to measure on hardware, with
programs running from DDR, such as CoreMark-PRO and Linux, and with NIC
receive traffic: a 32-byte write to a line the L2 lacks reads the line from
DDR first, and a write to the other half of a line with a read in flight
waits for that read and holds up the L2.

Software sees memory errors through the memory error unit. On the X3 a
reader polls the DDR controller's ECC registers about once a millisecond and
passes on corrected and uncorrectable errors with their physical addresses,
the cache hierarchy's AXI bridge passes on every error response, and Linux
logs both and shows the counts in sysfs (`linux/frost-memerr`). What remains
is scrubbing, which rewrites corrected data so that single-bit errors do not
build up into uncorrectable ones.

## VCU118 board support

Add the AMD VCU118 (Virtex UltraScale+ VU9P, -2L speed grade) as a second
board. The port needs board files and build support but no core RTL
changes: constraints, clocking, the DDR4 controller, and the UART and
Ethernet connections. The VCU118 gets its own clock target; the X3 stays at
322.265625 MHz and remains the reference for performance and timing.
Contributors with the board run its hardware tests. Done means the full
hardware regression, including Debian, passes on a VCU118.

## Verification

FROST is tested with formal proofs of individual modules, unit benches, full
programs, the RISC-V architecture tests and riscv-tests, riscv-torture
programs against Spike, TestRIG against the Sail model in four parallel CI
jobs, and Debian on the X3. Every CI job that simulates the whole SoC draws
its own DDR model latency, jitter, and completion order from a seed that a
failing test's output names. CI merges the line coverage of those
simulations, the toggle coverage of the unit benches, and the counts of
cover points for microarchitectural corner cases, such as a DMA write to a
line that an executed, unretired load has read, into one
[report](tests/README.md#coverage) of what the tests reach.

Next is to reach what that report shows no test reaching, with directed
tests for the corner cases whose cover points no whole-SoC run hits, and to
add cover points where the design documents call a case hard to reach. Toggle coverage
of the whole-SoC runs also remains: Verilator's slows them about sixfold, so
they need a cheaper form first.

## ASIC-ready RTL

The RTL is portable: Xilinx primitives sit behind `FROST_XILINX_PRIMS`, and
builds without it use portable versions. CI checks the portable build two
ways: Yosys's generic synthesis through its coarse stage, which stops before
memories and logic are mapped to gates, and the [ASIC flow](asic/README.md),
which maps it to standard cells and SRAM macros and routes it. To be ready
for an ASIC, the RTL also needs:

1. Reset. An FPGA loads declared initial values into registers at
   configuration; ASIC synthesis ignores them. Every register that relies on
   one needs a reset or a documented reason its starting value does not
   matter, checked by simulations that start registers and memories at
   random values, across several seeds.
2. Memory wrappers. The CPU's memories use the wrappers in `hw/rtl/lib/ram`,
   except the instruction memory, which infers its block RAMs in
   `imem_predecode.sv`. Move those behind the wrappers and list the
   instances that an ASIC flow replaces with SRAM macros.
3. The remaining memories in the ASIC flow. The [ASIC flow](asic/README.md)
   synthesizes, places, and routes the design with OpenROAD's flow scripts
   on FreePDK45 (their Nangate45 platform), from synthesis to GDS in CI on
   every pull request and merge, and reports its area and timing. The RAM
   wrappers' memories are dual-port SRAM macros that OpenRAM generates, since
   FROST's block RAMs have two ports and bsg_fakeram models only single-port
   memories. Its L2 holds 256 KiB, an eighth of the X3's, so that the flow
   fits CI's runners. The flow still mocks the other memories larger than
   4,096 bits as a single row of flip-flops: the instruction memory, which
   gets macros once item 2 moves it behind the wrappers; the NIC's frame and
   packet buffers; and the arrays read without a clock, such as the BTB tags
   and the TAGE tables, which need flip-flop or latch arrays rather than SRAM
   macros.
   The final GDS leaves the macros' cells empty, since their layouts are not
   in the repository. At the X3's clock, the macros' read paths fail by up
   to 0.41 ns, the worst from the data memory to the load queue. That path
   has half a clock cycle from launch to capture, giving an estimated core
   fmax of 254.8 MHz
   ([results](asic/README.md#results-with-the-sram-macros)).
   FreePDK45 is not a manufacturable process, so the flow shows that the RTL
   maps onto standard cells and SRAM macros and estimates its area and
   timing; it does not replace a foundry flow.

## SMP

Two X3 harts with inter-processor interrupts, per-hart PLIC contexts, and
RVWMO litmus tests. The single-hart queue sizes and lane choices will need
revisiting against the timing and memory-traffic cost of the second hart.

There are two candidate coherence points. One is the L2, the ordering point
for all traffic below the L1s; a sequencer in front of it already probes the
L1D for every DMA request. The other is a coherence unit at the L1 level,
between the L1D caches and the L2. It keeps a copy of each L1D's tags, so a
request probes only the caches that hold the line; it runs MESI with
cache-to-cache transfer, and the DMA port connects to it as another
requester.

Either way, the coherence design has to cover everything a hart can hold: L0
data, outstanding fills, executed but unretired loads, AMOs, LR/SC
reservations, and DMA. Snooping live load-queue entries is not enough,
because an entry is freed as soon as its result is staged for the common data
bus, before the load retires. The DMA observation table, which tracks loads
until they retire, is the starting point. A tag copy that filters probes must
also cover data the load queue still holds after the L1D evicts a line. Probe
data and acknowledgements must keep making progress when every queue is
full.

Done means Debian running on both harts, multi-hart scaling reported
separately from single-hart performance, routed timing met, and hours of
sustained-load testing that repeatedly exercise the recovery paths.

## Single-core performance

Before the CPU/SoC separation, FROST measured 4.27 CoreMark/MHz,
1,375 CoreMark at 322.265625 MHz,
past the goal of 4 CoreMark/MHz. The next goal is 5 CoreMark/MHz at the same
clock, or 1,611 CoreMark on one hart. A score counts only from a run of at
least ten seconds that passes the CRC checks for both official seed sets, with
the compiler flags, the `sw.bin` hash, and memory and cache settings recorded.
RTL changes must also keep routed timing at the target clock.

The AXI CPU boundary's Normal read-cache and write-through implementation
meets the original 1% aggregate CoreMark and CoreMark-PRO tolerance at
161.132812 MHz and passes all 48 X3 hardware stages. Individual workloads
vary; see the [current measurements](docs/single_core_performance.md).
The trace-model estimates below use the earlier local-BRAM baseline, not the
refactored memory path.

A CoreMark iteration is about 234,000 instructions, so 5 CoreMark/MHz, or
200,000 cycles per iteration, needs 1.17 instructions per cycle, up from 1.00.
A model driven by the CoreMark instruction trace gives these estimates for
each change on its own:

| Change | Estimated CoreMark/MHz |
| --- | --- |
| None | 4.27 |
| Perfect branch prediction, every direction and target | 4.73 |
| Load-to-use latency one cycle shorter | 4.58 |
| Ideal fetch: two instructions per cycle up to a taken branch, no bubbles | 4.58 |
| Dependent integer operations issued back to back | 4.50 |
| Half the remaining mispredictions | 4.48 |
| Two-instruction fetch in straight-line code | 4.47 |
| No bubble after a taken slot-2 prediction | 4.34 |
| A second memory port | 4.34 |
| Word multiplies two cycles faster | 4.29 |
| A 64-entry ROB, 16 checkpoints, and 16-entry load and store queues | 4.28 |

No single change reaches 5. Perfect prediction alone stops near 4.7, and the
back end as built stops near 5.1 even with perfect prediction and ideal fetch.
Reaching 5 takes about three changes together: two-instruction straight-line
fetch, a cycle off load-to-use latency, and half the remaining mispredictions
give about 5.1, as does the same set with back-to-back integer issue in place
of the load-latency cut.

Priorities, guided by the performance counters and timing reports:

1. Branch prediction. About 2,100 mispredictions per iteration remain. PD,
   the pre-decode stage, overrides only slot-1 directions, so slot-2 branches
   keep the BTB's direction, and long loops mispredict their exits.
2. Pairing across fetch windows. The front end pairs two instructions only
   when both fit in one 64-bit fetch window, and after a redirect the fetch
   address advances four and eight bytes in turn, so straight-line code
   alternates two-instruction and one-instruction packets. The instruction in
   such a one-instruction packet is the window's second word, which no BTB
   lookup covers, so calls and returns there recover at commit. Removing the
   limit lets any two consecutive instructions pair. Then measure compressed
   code across different code layouts: CoreMark runs without compressed
   instructions, and should use them once throughput is stable across link
   orders.
3. Lower pointer-chasing latency. Response bypass, early wakeup of dependent
   loads, and load preparation while the memory port is busy are in place.
   Next, take a cycle out of load-to-use latency, try associativity in the
   load queue's L0 cache if its conflict counters justify it, then
   prefetching for dependent loads. The earlier local-BRAM measurements
   found little benefit from 256 entries over 128. The AXI Normal read-cache
   profile now uses 256 entries to reduce its more expensive misses.
4. Back-to-back integer issue. Dependent integer operations issue two cycles
   apart because the stations wake from the registered CDB, so serial chains,
   such as the table-driven CRC code GCC generates for CoreMark, run at half
   rate. Issuing them back to back needs wakeup at selection, with the ALU
   result forwarded to the dependent operation.
5. Fewer front-end bubbles. Beyond the four-bundle decoded queue and the
   Normal instruction cache, compare a tagged predecode cache with a stream
   buffer. In the earlier local-BRAM front-end measurements, a
   taken slot-2 prediction costs one bubble and a PD redirect two. Fetch must
   keep working with variable-latency memory.
6. Cheaper 32-bit operations on RV64. `MULW` takes three cycles and word
   division or remainder thirty-three, though CoreMark gains little from a
   faster `MULW`. Use instruction traces to evaluate fusion or elimination at
   rename. Any such transformation must keep precise exceptions, retirement
   counts, and debug single-step behavior, and be formally verified.
7. Queue capacity where counters show pressure. Sixteen INT
   reservation-station entries capture the measured benefit; larger INT RS,
   ROB, and load-queue sizes currently show little gain, and a second memory
   port would add little. A third lane is worth considering only if front-end
   and memory work leave issue width as the limit.

Performance changes must improve general workloads, never by recognizing
benchmark code, PCs, or data patterns. They must pass the full regression in
both memory tiers, keep DMA coherent and the core RTL portable, meet the
target clock, and not materially slow CoreMark-PRO or Linux. Changes to the
load queue, its L0 cache, or queue capacities must also update the DMA
coherence argument: the parameter bounds, and why DMA admission and service
still make progress, including for loads that have not yet retired.

## Core area

A second hart duplicates the core and its L1 caches and shares the L2, the
DDR controller, the NIC, and the DMA engine. In the X3 baseline before the
CPU/SoC separation, the core, its L1 caches, and its fetch logic used about
107,000 of the design's 164,500 LUTs, suggesting about 26% of the device's
LUTs for two harts. Some single-hart placements already showed routing
congestion, and that build met timing only with its better placements.
Each LUT cut from the core is saved once per hart. The largest blocks are the
fetch stage and its predictors, the integer reservation station, the ROB, and
the two ALUs.

## Timing margin

The X3 baseline before the CPU/SoC separation met 322.265625 MHz only with
its better placements: the flow places several candidates and keeps one
that qualifies (see [X3 placement](fpga/README.md#x3-placement)). The CPU/SoC
boundary currently passes post-opt setup at 322 MHz; full implementation
validation remains pending. The goal is enough slack that a single default
placement meets timing.

## Possible future work

- A general three-wide redesign
- The V and H extensions
- The full crypto extensions
- Storage beyond the NFS root, such as iSCSI with ext4 or host-backed
  PCIe/virtio block devices; NFS is the supported root filesystem

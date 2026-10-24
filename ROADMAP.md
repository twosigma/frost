# FROST Roadmap

[Prof. John Goodacre](https://github.com/goodacre-manchester) is helping to
set the direction of this roadmap. The sections are in priority order.

## SMP

Two harts on the X3, sharing one L2, with RVWMO litmus tests and Debian
running on both. `cpu_top` holds one hart with its L0, L1D, L1I, and L2, and
its outgoing AXI4 master is not coherent, so two `cpu_top` instances on
shared memory do not form an SMP system. Its coherent ingress gives DMA and
the NIC access to one tile's caches; it is not a protocol between tiles (see
the [CPU boundary](hw/rtl/cpu_top/README.md)). Inside `cpu_top`, the
per-hart block `frost_hart` holds the core with its MMUs and its L0 and L1
caches, and `frost_cluster_memory` holds the shared L2, the DMA coherence
sequencer, and the memory master, which stays plain AXI4. The single-hart
`cpu_top` keeps its integration interface by composing one of each. The link
between them carries the single-hart protocol: the L1s' line ports and the
DMA sequencer's probes into the one L1D. The coherent interface inside the
cluster, which a second hart needs, comes first. An L2 in every hart instead
would need its own coherence design between the private L2s.

Coherence is ordered at the shared L2, the ordering point for all traffic
below the L1s. A sequencer in front of it takes the requests for each line in
turn and probes both harts' L1Ds, as the existing sequencer probes the L1D for
every DMA request. The L1Ds hold lines in MESI states, and dirty data passes
through the L2 rather than directly between the L1Ds. A coherence unit at the
L1 level can follow if measurements show that the probes or the trip through
the L2 limit performance: it would keep a copy of each L1D's tags, so that a
request probes only the caches that hold the line, and move lines directly
between the L1Ds.

The coherence design has to cover everything a hart can hold: L0 data,
outstanding fills, executed but unretired loads, AMOs, LR/SC reservations,
and DMA. Snooping live load-queue entries is not enough, because an entry is
freed as soon as its result is staged for the common data bus, before the
load retires. The DMA observation table, which tracks loads until they
retire, is the starting point. Stores need write permission: today the L1D
writes a line it hits without checking for other copies, and completes a
write miss before its fill arrives. Probe data and acknowledgements must keep
making progress when every queue is full. The single-hart queue sizes and
lane choices will need revisiting against the timing and memory-traffic cost
of the second hart.

Writable BRAM stays private to one hart. Its read caches are outside the
coherent ingress, and its instruction and data copies are separate, so a
store to it does not reach another hart's cached copies, and an AMO on it is
not atomic between harts. Data the harts share lives in DDR.

The SoC has an AIA 1.0 APLIC with machine and supervisor domains, five
wired interrupt sources, and direct and MSI delivery. Each CPU contains
machine and supervisor IMSIC files with 63 identities and Smaia/Ssaia
CSRs. The SoC decodes a 2 MiB device window into registered per-hart MSI
inputs. Files reset to direct APLIC delivery for existing programs.

The generated device tree advertises both IMSIC levels and links the APLIC
domains with `msi-parent`. OpenSBI uses the machine IMSIC for IPIs and
delegates the wired sources to the supervisor APLIC. Linux uses supervisor
IMSIC delivery for IPIs and wired interrupts. The build connects one hart;
the decoder and APLIC retain their hart-count parameters.

Done means Debian running on both harts, multi-hart scaling reported
separately from single-hart performance, and hours of sustained-load testing
that repeatedly exercise the recovery paths.

## Memory system

The L1D, L1I, and L2 are 4-way set-associative with tree pseudo-LRU
replacement, one design for every target. The L1D inserts lines bimodally: a
fill becomes its set's most recently used only one time in 32, so a working
set somewhat larger than the L1D keeps part of itself resident instead of
evicting each line just before its next use. The L1s read every way's data at
the tag decision, which keeps their hit latency at that of a direct-mapped
cache. The L2 reads its data after the tag compare picks the way, one cycle
more than a parallel read.

The L2 uses 64-byte lines, following John Goodacre's design. An adapter maps
each 32-byte request from the L1 caches, the page-table walker, and the DMA
port onto its half of a line. The L2 writes back only whole lines, each as a
single 512-bit AXI transfer that the X3's ECC DDR4 controller takes without
a read-modify-write, and a 32-byte write that misses fetches its line and
merges into it.

The physical address width follows the configured DDR aperture, from 1 GiB,
the default and the X3's, to 128 GiB, through the fetch and data paths, the
MMUs and page-table walker, the caches, the DMA engine, and the NIC. The DMA
engine and the NIC keep their original descriptor formats and add
full-width ones. Accesses outside the aperture fault or are rejected rather
than alias lower addresses. Simulation, formal checks, and a Linux boot in
QEMU cover addresses above 4 GiB; on hardware, the X3 build uses a 1 GiB
aperture.

Software sees memory errors through the memory error unit. On the X3 a
reader polls the DDR controller's ECC registers about once a millisecond and
passes on corrected and uncorrectable errors with their physical addresses,
the cache hierarchy's AXI bridge passes on every error response, and Linux
logs both and shows the counts in sysfs (`linux/frost-memerr`). The driver
also scrubs: it rewrites each line with a reported corrected error, so the L2
writes the corrected data back to DDR with fresh ECC, and a background patrol
reads all of memory, once a day by default, to find errors in data that
nothing else reads.

Profiling counters measure the L2's two write costs on the X3. A 32-byte
write to a line the L2 lacks reads the line from DDR first, and a write to
the other half of a line with a read in flight waits for that read and holds
up the L2. Writes held behind reads are rare: at most three in any run
measured. Write fills are negligible for programs running from DDR: none in
`ddr_bench`, at most 0.02% of the L2's misses in any CoreMark-PRO workload,
and about 0.3% under Linux. NIC receive raises them to about 6% of the L2's
misses and of the cycles its miss slots are held in a 512 MiB NFS read, and
to about 4.5% in a UDP stream. The counters leave out maintenance traffic,
so the Linux figures do not include write fills from the L1D writebacks that
`sfence.vma` triggers.

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

Next is to add cover points where the design documents call a case hard to
reach, and directed tests for those that no whole-SoC run hits. Toggle
coverage of the whole-SoC runs also remains: Verilator's slows them about
sixfold, so they need a cheaper form first.

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
   the instruction memory's block RAMs and PC-metadata overlays included,
   and the ASIC flow
   [lists the instances](asic/README.md#instances-built-from-sram-macros)
   that it builds from SRAM macros. The wrappers' arrays read without a
   clock, such as the PC-metadata overlays and the BTB tags, have no macro
   form (item 3).
3. The remaining memories in the ASIC flow. The [ASIC flow](asic/README.md)
   synthesizes, places, and routes the design with OpenROAD's flow scripts
   on FreePDK45 (their Nangate45 platform), from synthesis to GDS in CI on
   every pull request and merge, and reports its area and timing. The RAM
   wrappers' memories are dual-port SRAM macros that OpenRAM generates, since
   FROST's block RAMs have two ports and bsg_fakeram models only single-port
   memories. Its L2 holds 256 KiB, an eighth of the X3's, so that the flow
   fits CI's runners. The flow still mocks the other memories larger than
   4,096 bits as a single row of flip-flops: the NIC's frame and packet
   buffers, and the arrays read without a clock, such as the BTB tags, the
   TAGE tables, and the instruction memory's PC-metadata overlays, which
   need flip-flop or latch arrays rather than SRAM macros.
   The final GDS leaves the macros' cells empty, since their layouts are not
   in the repository. At the X3's clock, the macros' read paths fail by up
   to 0.47 ns, the worst from the data memory to `soc_top`'s local response
   register. That path has half a clock cycle from launch to capture, giving
   an estimated core fmax of 247.6 MHz
   ([results](asic/README.md#results-with-the-sram-macros)).
   FreePDK45 is not a manufacturable process, so the flow shows that the RTL
   maps onto standard cells and SRAM macros and estimates its area and
   timing; it does not replace a foundry flow.

## Single-core performance

FROST runs CoreMark at 4.23 CoreMark/MHz, past the goal of 4 CoreMark/MHz.
The next goal is 5 CoreMark/MHz. A score counts only from a run of at least
ten seconds that passes the CRC checks for both official seed sets, with the
compiler flags, the `sw.bin` hash, and memory and cache settings recorded.
The [performance measurements](docs/single_core_performance.md) give each
CoreMark-PRO workload and how it is measured.

A CoreMark iteration is about 234,000 instructions, so 5 CoreMark/MHz, or
200,000 cycles per iteration, needs 1.17 instructions per cycle, up from 0.99.
A model driven by the CoreMark instruction trace gives these estimates for
each change on its own. It treats the BRAM as attached directly to the core,
without the instruction and data read caches in front of it, so its baseline
is 4.27:

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
   prefetching for dependent loads. The L0 holds 256 entries because its
   misses to BRAM cross the AXI boundary. CoreMark-PRO's sha workload takes
   29% longer with the read caches in front of BRAM than with BRAM attached
   directly, so it is the first workload to profile.
4. Back-to-back integer issue. Dependent integer operations issue two cycles
   apart because the stations wake from the registered CDB, so serial chains,
   such as the table-driven CRC code GCC generates for CoreMark, run at half
   rate. Issuing them back to back needs wakeup at selection, with the ALU
   result forwarded to the dependent operation.
5. Fewer front-end bubbles. Beyond the four-bundle decoded queue and the
   instruction read cache in front of BRAM, compare a tagged predecode cache
   with a stream buffer. A taken slot-2 prediction costs one bubble and a PD
   redirect two. Fetch must keep working with variable-latency memory.
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

A second hart duplicates the core and its L0 and L1 caches and shares the
L2, the DDR controller, the NIC, and the DMA engine, so each LUT cut from the
core is saved once per hart. The largest blocks are the fetch stage and its
predictors, the integer reservation station, the ROB, and the two ALUs.

## Possible future work

- Support for the AMD VCU118 (Virtex UltraScale+ VU9P, -2L speed grade) as a
  second board: constraints, clocking, the DDR4 controller, and the UART and
  Ethernet connections, with its own clock target and no core RTL changes.
  Contributors with the board would run its hardware tests.
- A PCIe Gen3 x4 root complex between the 64-bit AXI interconnect and PIPE,
  the PHY interface that ASIC PCIe PHYs also use, with a small wrapper for
  the FPGA's transceivers, so that Linux finds NVMe drives and other devices
  with its standard drivers. The X3's PCIe lanes go to its host connector,
  where FROST is the device rather than the root, so hardware tests of the
  root complex need a board with a downstream slot or connector.
- Storage beyond the NFS root: NVMe drives through the root complex, a block
  device that the host serves through the X3's PCIe Gen4 x8 host interface
  with FROST as the endpoint, or iSCSI with ext4. NFS is the supported root
  filesystem.
- A frame buffer with HDMI output for a local display, in dual-ported on-chip
  memory such as UltraRAM so that refresh traffic stays off DDR, with a
  clock-domain crossing from the SoC clock to the pixel clock. It needs a
  board or bridge board with an HDMI output.
- Enough timing margin at 322.265625 MHz that a single default placement
  meets timing
- A general three-wide redesign
- The V and H extensions
- The full crypto extensions

# FROST Roadmap

[Prof. John Goodacre](https://github.com/goodacre-manchester) is helping to
set the direction of this roadmap. The sections are in priority order.

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
programs against Spike, TestRIG against the Sail model, and Debian on the X3.
Next:

1. Coverage. Merge Verilator line and toggle coverage across the CI runs and
   add cover points for microarchitectural corner cases, such as a DMA write
   to a line that an unretired load has read, to show what no test reaches.
2. Longer random runs. Run TestRIG nightly with thousands of tests per
   template, and run the cached-DDR program tests with random DDR latency.
   Add the A extension to the TestRIG comparison, which needs a way to
   reconcile the reservation rules of FROST and Sail: both are legal, but an
   SC can succeed under one and fail under the other.

## Memory system

The L2 uses 32-byte lines, but the X3's DDR4 controller transfers 64 bytes
at a time: one burst on the 64-bit bus, 512 bits at its AXI port. With ECC
on and no data mask, every 32-byte writeback makes the controller read the
64 bytes, merge, and write them back, and every 32-byte fill reads 64 bytes
and keeps half. The plan is 64-byte L2 lines in two 32-byte sectors, so the
L1 caches, the DMA port, and coherence probes keep 32-byte lines, and a
32-byte write still allocates without a fill. A line can move as two
256-bit beats. Measure the change with programs running from DDR, such as
CoreMark-PRO and Linux.

The DDR controller counts ECC errors, but nothing reports them to software:
its interrupt is unconnected and `ECC_EN_IRQ` is clear. The cache hierarchy's
AXI bridge checks error responses only in simulation. The plan is to connect
ECC reporting, propagate AXI errors to software, and add scrubbing and
periodic reporting (`CE_CNT` saturates at 255, so it must be read and
cleared). The hardware regression checks ECC once at the end of a run, which
catches errors but is not continuous monitoring.

## ASIC-ready RTL

The RTL is portable: Xilinx primitives sit behind `FROST_XILINX_PRIMS`,
builds without it use portable versions, and CI synthesizes the design with
Yosys. An ASIC flow also needs:

1. Reset. An FPGA loads declared initial values into registers at
   configuration; ASIC synthesis ignores them. Every register that relies on
   one needs a reset or a documented reason its starting value does not
   matter, checked by simulations that start registers and memories at
   random values, across several seeds.
2. Memory wrappers. The CPU's memories use the wrappers in `hw/rtl/lib/ram`,
   except the instruction memory, which infers its block RAMs in
   `imem_predecode.sv`. Move those behind the wrappers and list the
   instances that an ASIC flow replaces with SRAM macros.

## SMP

Two X3 harts with inter-processor interrupts, per-hart PLIC contexts, and
RVWMO litmus tests. The single-hart queue sizes and lane choices will need
revisiting against the timing and memory-traffic cost of the second hart.

There are two candidate coherence points. One is the L2, which already
orders DMA against the L1D, probing the L1D on every coherent request. The
other is a snoop control unit between the L1D caches and the L2, as in the
ARM11 MPCore and Cortex-A9. It keeps a copy of each L1D's tags, so a request
probes only the caches that hold the line; it runs MESI with cache-to-cache
transfer, and the DMA port connects to it like the Cortex-A9's accelerator
coherency port.

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

FROST runs CoreMark at 4.27 CoreMark/MHz, 1,375 CoreMark at 322.265625 MHz,
past the goal of 4 CoreMark/MHz. The next goal is 5 CoreMark/MHz at the same
clock, or 1,611 CoreMark on one hart. A score counts only from a run of at
least ten seconds that passes the CRC checks for both official seed sets, with
the compiler flags, the `sw.bin` hash, and memory and cache settings recorded.
RTL changes must also keep routed timing at the target clock.

The RV64 core must also match or beat FROST's earlier RV32 configuration,
tuned the same way, in cycle-exact simulation. The
[performance guide](docs/single_core_performance.md#comparing-changes)
describes the reference and the comparison method.

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
   prefetching for dependent loads. A 256-entry L0 added little over the
   default 128 entries.
4. Back-to-back integer issue. Dependent integer operations issue two cycles
   apart because the stations wake from the registered CDB, so serial chains,
   such as the table-driven CRC code GCC generates for CoreMark, run at half
   rate. Issuing them back to back needs wakeup at selection, with the ALU
   result forwarded to the dependent operation.
5. Fewer front-end bubbles. Beyond the four-bundle decoded queue and the
   single-cycle fetch region (the first 64 KiB of BRAM), compare a larger
   single-cycle region with a tagged predecode cache or a stream buffer. A
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
DDR controller, the NIC, and the DMA engine. In the X3 build, the core, its
L1 caches, and its fetch logic use about 107,000 of the design's 164,500
LUTs, so two harts would use about 26% of the device's LUTs. The limit is
placement, not capacity: some single-hart placements already show routing
congestion, and the build meets timing only with its better placements.
Each LUT cut from the core is saved once per hart. The largest blocks are the
fetch stage and its predictors, the integer reservation station, the ROB, and
the two ALUs.

## Timing margin

The X3 build meets 322.265625 MHz only with its better placements: the flow
places several candidates and keeps one that qualifies (see
[X3 placement](fpga/README.md#x3-placement)). The goal is enough slack that a
single default placement meets timing.

## Deferred

These wait for demand: a general three-wide redesign, an ASIC
implementation, the V and H extensions, the full crypto extensions, and Sv32.
Storage beyond the NFS root, such as iSCSI with ext4 or host-backed
PCIe/virtio block devices, is possible; NFS remains the supported root
filesystem.

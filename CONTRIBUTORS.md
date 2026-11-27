# Contributors

## Two Sigma Employees

### Adam Bagley ([@adambagley](https://github.com/adambagley))

- Original author and maintainer

### Dr. Jordan Slott ([@jslott2sigma](https://github.com/jslott2sigma))

- Implemented C standard library string functions (`strcmp`, `strncpy`, `strstr`, `strchr`)
- Implemented character classification functions (`isdigit`, `isalpha`, `toupper`)
- Implemented number parsing functions (`strtol`, `atoi`)
- Created the stdlib validation application

### Dr. Thomas Detwiler ([@tdetwile](https://github.com/tdetwile))

- Optimized ALU by sharing a single subtractor across SLT/SUB operations
- Unified immediate/register operand paths in ALU
- Halved divider pipeline depth by folding two radix-2 iterations per stage
- Added register stages on memory write path to improve timing closure

### Charles Saternos ([@clsater](https://github.com/clsater))

- Implemented heap memory system with arena allocator (`arena_push`, `arena_push_zero`, `arena_push_align`)
- Implemented freelist-based `malloc`/`free`
- Modified linker script to carve out 8KB heap region
- Wrote original packet parser software app

### Erez Strauss ([@erez-strauss](https://github.com/erez-strauss))

- Implemented the portable `sprintf`/`snprintf` library (`%d`, `%f`, `%e`, `%g`, `%x`, flags, width, precision, length modifiers)
- Created the initial ~260-case integer, floating-point, string, and truncation test suite (since expanded to 344 checks)

## External

### Dr. Nicholas Beser ([@ndbeser](https://github.com/ndbeser))

- Johns Hopkins University Applied Physics Laboratory
- Advisor for architecting and developing the Tomasulo out-of-order back-end, the cache hierarchy, and the superscalar pipeline

### Prof. John Goodacre ([@goodacre-manchester](https://github.com/goodacre-manchester))

- Professor at the University of Manchester, contributing in a personal capacity
- Helps set the direction of the [roadmap](ROADMAP.md)
- Found four RISC-V conformance bugs by differential testing against the Sail model
- Suggested the RVFI-DII port and the TestRIG comparison against Sail that runs in CI
- Co-authored the fixes that make the unimplemented machine HPM counters
  read-only zero and that page-fault on a non-leaf PTE with D, A, or U set
- Designed the 64-byte L2 and its 512-bit DDR port
- Implemented configurable physical addressing for DDR apertures up to 128 GiB
  across the CPU, MMUs, caches, AXI, DMA, NIC, and firmware, including full-width
  NIC descriptors and Linux driver support, with its formal checks, the
  physical-address test matrix in CI, and a QEMU Linux boot above 4 GiB
- Proposed the reusable `cpu_top` integration boundary and
  `platform_top = cpu_top + soc_top` separation, with a unified AXI4 master,
  configurable PMA, and explicit interrupt, debug, boot, and reset interfaces
- Implemented the VCU118 board port, including clocking, DDR4, pin constraints,
  and build and software-loading integration
- Implemented VCU118 RJ-45 and QSFP1 Ethernet, the GMII MAC path, SPI flash
  boot stages, and U-Boot console and network support
- Proposed the open ASIC flow on FreePDK45
- Proposed an L1-level coherence unit for SMP
- Built the architectural performance model in `perf-modeling/`, a
  cycle-approximate model of `cpu_top` and `soc_top` correlated against
  traces that the program bench captures from the RTL
- Measured Linux on FROST with sysbench, `perf` and microbenchmarks, which set
  the roadmap's Linux performance items
- Implemented the radix-4 divider with leading-zero early termination, and
  the FP fast paths for compares, moves, sign injection and conversions
- Doubled the ITLB to 16 entries and removed the Sv39 sequential-fetch
  bubble with intra-page virtual tagging
- Added the data MMU's last-page translation bypass, which saved a cycle
  on translated accesses to the most recently used page, and which the
  resident-hit bypass later generalized
- Added streaming coherent DMA, which keeps DMA fills marked non-allocating
  in one L2 way so that network traffic does not evict the CPU's lines from
  the others
- Added the standard HPM counters 3 to 8 for branches, mispredictions, TLB
  walks, L1D misses and store-queue stalls, with their OpenSBI PMU mapping
- Added the coherent prefetch agent, which trains a stream predictor on the
  hart's data requests and reads the lines ahead of ascending streams into
  the L2 with Prefetch requests to the home
- Added a self-modifying-code torture test and a next-PC check at retirement,
  and fixed the two front-end bugs they found: stale fast-BTB predictions
  after code or translation changes, and a compressed-instruction buffer that
  could take a word from the wrong fetch window
- Extended the performance model to the coherent L1D, the store drain and the
  home's prefetcher, with a VCU118 board data set and its calibration tool
- Moved signal declarations ahead of their first use across the RTL, as the
  SystemVerilog standard requires, and added a yosys-slang front-end check to CI
- Implemented the Ethernet NIC offload engine (checksums, segmentation and scatter-gather), configurable ingress buffering, 802.3x flow control, telemetry and the matching Linux driver support
- Added mixed-tier store serialization coverage, the VCU118 4 MiB L2 configuration and a dependent-load cache-capacity measurement application
- Preserved TLB entries across SUM/MXR changes, added Svvptc and translation events, and cached upper-level page-table pointers
- Implemented Sscofpmf counter overflow, privilege filtering, delegated local interrupts, and programmable cycle and instruction counters
- Implemented 64-byte Zicboz block zeroing, its coherent cache protocol and grant handling, and the matching tests and firmware integration
- Made the Vivado build steps finish when the launcher outlives Vivado, and explain a Vivado process that dies without an error line
- Moved the VCU118 flash boot partition to 0x04000000 behind one shared constant, with a consistency test and a programmer check that the FPGA image fits below it
- Made the architecture-test runner report Zifencei as SKIP in the BRAM tier, where self-modifying code cannot run, so a full BRAM run ends with a clean summary
- Added a same-address load-order test for the L1D hit path across an invalidating probe, and a cbo.zero check that an owed twin keeps the L1D's acquisition endpoint
- Implemented Sstvala, writing the faulting instruction's bits to mtval and stval on illegal-instruction exceptions from every source, with a directed test across privilege modes and delegation
- Implemented Zicbom, decoding cbo.clean, cbo.flush and cbo.inval with their CBCFE and CBIE gates, load-permission translation with store faults, and ordered completion in the store queue, with a directed test, bench cases, formal checks and a TestRIG trace
- Advertised Zicbop, Zawrs, Zihpm, Zicbom and the RVA22 profile properties in the device tree and boot image, with prefetch hints as no-ops, the Zawrs wait instructions and their `mstatus.TW` rule, and directed tests for each
- Split attributed net declarations that carried an initialiser into a declaration and a separate `assign`, so front ends that reject an attribute on an initialised net accept them
- Fixed interrupt starvation by closely spaced device accesses, holding the next device access while an interrupt take is armed, with a program that measures interrupt-take latency across device, atomic, fence and memory-bound loops
- Added page-pool RX fragments, tunable copying of short frames, and conditional DMA synchronization to the Linux NIC driver
- Implemented registered receive packet lengths, compact transmit FIFOs with per-frame metadata, mailbox transfers for NIC configuration and pause events, and a bare-metal NIC throughput benchmark.
- Added nine-bit ASIDs with global pages, the four selective forms of SFENCE.VMA, and a 512-entry second-level TLB in block RAM with a 32-entry superpage side array, with a directed test, a unit bench and formal checks
- Implemented Zfhmin and Zfa floating-point extensions, with architecture-test references, FP engine checks and TestRIG differential coverage
- Limited the fanout of the L1D's phase and selection registers, registered the L2's zero-fill image clear, and matched DMA ingress grants and releases by queue identity
- Implemented Zcb, Zcmop, Zimop, and Zihintntl, with decoder, formal, architecture-test and TestRIG coverage and ISA advertisement.
- Implemented grant responses for attached L1D loads and same-sector load merging beside the read-hit pipeline, with formal checks and directed tests
- Kept L1D stream prefetches off sectors held by pending store records and waiting `cbo.zero` twins, closing a stale-line install that lost the upper half of a zeroed block, with a cluster reproduction test and an invariant check
- Configured the VCU118 32 KiB L1I cache and added a directed set, eviction, `fence.i` and Sv39 `PA[12]`-crossing test across 16 KiB and 32 KiB geometries
- Gave the store queue separate early-address and MMIO copies and the ROB link-value read comparators separate staged allocation addresses, with formal equivalence checks.
- Simplified L2 home payload captures, registered fill update phase flags and replicated writeback reply selects while preserving qualified request and response behavior
- Limited the fanout of the L1I's miss-slot selection registers, formed the fetch-hold polarity directly in the IMMU's copy LUTs, and applied the ID stage's illegal-instruction and fetch-fault kill after operand classification, with formal equivalence checks
- Implemented one-cycle L1I invalidation with valid bits in flip-flops and added a JIT-style fence.i and refetch benchmark
- Added L1I refill and L2 demand and prefetch miss events to the HPM counters, with Linux PMU mappings and directed verification.
- Registered the VCU118 DDR initializer's AXI valid signals, applied its SLR floorplan and updated its external I/O constraints.
- Switched out-of-context IP synthesis to project-mode runs, clocked the BSCAN debug transport at its primitives, adapted Vivado exit detection to child IP logs, and extended the L1D zero-cover budget
- Implemented Svpbmt with PBMTE and PTE validation, PBMT in both TLB levels, coherent uncached DDR aliases, uncached memory access and PMA overrides, with directed programs, benches, formal checks and a TestRIG trace
- Shortened the L2 home's hit path with banked UltraRAM parallel way reads, final-tag-cycle way selection, quick result offers, and dispatch-cycle lookup offers, with formal checks and home bench coverage
- Loaded reservation-station stage-2 issue payloads on functional-unit readiness while keeping validity on the flush-qualified issue path, with a two-copy wrapper payload-twin formal check
- Added the SYSRESET register and OpenSBI syscon-reboot support for SBI system reset, with register and device-tree tests
- Added GMII receive-loss diagnostics, PHY error polling, and larger default receive buffering in the NIC driver
- Implemented Ssnpm pointer masking for U-mode with PMLEN 7 and 16, including CSR controls, memory-address handling, formal checks, directed programs, and comparison with Sail.
- Implemented Svnapot 64 KiB NAPOT leaves in the page-table walker, with reserved-encoding checks, Svpbmt alias composition, a directed program, bench cases, formal checks and a TestRIG trace
- Advertised Ssu64xl in the device tree and boot image, with a TestRIG trace that checks the read-only UXL and SXL fields against Sail
- Gave each quarter of the integer reservation station's entries its own register copy of the CDB issue tags, with a simulation check, an induction proof that each copy equals its tag and an equivalence proof that the copies leave the station's behavior unchanged from reset
- Installed fully written 64-byte store blocks without fill through paired `GetMZero` acquisitions and data twins, and overlapped cached plain writes in the store queue with gathering and same-sector combining hints, with their formal checks, benchmarks, and directed tests
- Implemented pipelined DSP multiplication and radix-4 division for single- and double-precision floating-point operations and added a regression for the latency of arithmetic operations
- Implemented pipelined scalar floating-point arithmetic, radix-16 division and early wakeup of dependent operations.
- Implemented Zicbom clean, flush and invalidate through the coherent cache hierarchy.
- Extended the backing branch target buffer, added tagged indirect target prediction (ITTAGE), and switched TAGE to global direction history.
- Added front-end redirect checks and a seeded control-flow test suite.
- Added early recovery of mispredicted indirect jumps and a misprediction cost probe.
- Isolated each IP synthesis run in its own Tcl Store user area and bounded the VCU118 NIC pause-event mailbox payload.
- Added slab-like node reuse benches (`coherence_stale_line` and `node_reuse_test`) beside full-line stores, `cbo.zero` and DMA, added `FROST_BP_COUNT` branch-misprediction logging to real-program simulation, and stopped the performance model crediting L1D stream look-ahead hints by default
- Added `--vlen` selection (`128`, `256`, or `512`) to the opt-in VCU118 vector build and software loader, naming matching `Zvl*b` extensions in the generated Linux device tree.

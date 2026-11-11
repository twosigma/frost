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
- Created the ~260-case integer, floating-point, string, and truncation test suite

## External

### Dr. Nicholas Beser ([@ndbeser](https://github.com/ndbeser))

- Johns Hopkins University Applied Physics Laboratory
- Advisor for architecting and developing the Tomasulo out-of-order back-end, the cache hierarchy, and the superscalar pipeline

### Prof. John Goodacre ([@goodacre-manchester](https://github.com/goodacre-manchester))

- Professor at the University of Manchester, contributing in a personal capacity
- Helps set the direction of the [roadmap](ROADMAP.md)
- Found four RISC-V conformance bugs by differential testing against the Sail model
- Suggested the RVFI-DII port and the TestRIG comparison against Sail that now runs in CI
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
- Added the data MMU's last-page translation bypass, which saves a cycle
  on translated accesses to the most recently used page
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
- Implemented the Ethernet NIC offload engine (checksums, segmentation and scatter-gather), scalable ingress buffering, 802.3x flow control, telemetry and the matching Linux driver support
- Added mixed-tier store serialization coverage, the VCU118 4 MiB L2 configuration and a dependent-load cache-capacity measurement application
- Preserved TLB entries across SUM/MXR changes, added Svvptc and translation events, and cached upper-level page-table pointers
- Implemented Sscofpmf counter overflow, privilege filtering, delegated local interrupts, and programmable cycle and instruction counters

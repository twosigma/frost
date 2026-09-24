# Cache library file list: the line cache, the line-port arbiter, the two
# coherence sequencers, the hierarchy, the AXI bridge, the simulation-only DDR
# model, and the cocotb unit-bench harnesses.

# Per-cache performance event types (must precede the cache modules).
$(ROOT)/hw/rtl/lib/cache/cache_perf_pkg.sv

# Write-back direct-mapped line cache (one module for every level)
$(ROOT)/hw/rtl/lib/cache/frost_cache.sv

# N:1 tagged line-port arbiter. Listed before the hierarchy, which
# instantiates a tree of them, so Yosys never meets a parameterized
# instantiation of a module it has not parsed yet; that saves hierarchy
# deferral rounds. tests/test_run_yosys.py avoids the Yosys assertion that
# reprocessing the parameterized hierarchy can trigger.
$(ROOT)/hw/rtl/lib/cache/line_port_arbiter.sv

# DMA coherence sequencer: probes the L1D, and for a write runs the load-queue
# handshake, before a DMA request reaches the shared level.
$(ROOT)/hw/rtl/lib/cache/dma_coherence_sequencer.sv

# Walker coherence sequencer: probes the L1D before a page-table walk read
# reaches the shared level.
$(ROOT)/hw/rtl/lib/cache/walker_coherence_sequencer.sv

# Configurable cache hierarchy wrapper (L1s + walker + DMA ports, optional URAM L2)
$(ROOT)/hw/rtl/lib/cache/frost_cache_hierarchy.sv

# Tagged line-port -> AXI4 master bridge, multiple outstanding (bottom of the hierarchy)
$(ROOT)/hw/rtl/lib/cache/line_port_axi_bridge.sv

# Simulation-only AXI main-memory model (stands in for DDR)
$(ROOT)/hw/rtl/lib/cache/axi_behavioral_memory.sv

# Cocotb unit-bench harness (hierarchy + bridge + behavioral memory)
$(ROOT)/hw/rtl/lib/cache/frost_cache_test_harness.sv

# Cocotb unit-bench harness (arbiter + bridge + behavioral memory)
$(ROOT)/hw/rtl/lib/cache/line_port_arbiter_test_harness.sv

# Cache hierarchy library file list
# Recursive line-port cache + the bottom-of-hierarchy AXI bridge and the
# simulation-only behavioral main memory.

# Packed cache performance-observer types (must precede the cache modules).
$(ROOT)/hw/rtl/lib/cache/cache_perf_pkg.sv

# Write-back direct-mapped line cache (one module for L1 and L2)
$(ROOT)/hw/rtl/lib/cache/frost_cache.sv

# N:1 tagged line-port arbiter — listed before the hierarchy that
# instantiates a tree of them, so parameterized instantiations never
# forward-reference an unparsed module (fewer yosys hierarchy deferral
# rounds; the reprocess-a-chparam'd-top assert those can trigger is also
# defused at the flow level, see tests/test_run_yosys.py).
$(ROOT)/hw/rtl/lib/cache/line_port_arbiter.sv

# Per-board cache hierarchy wrapper (L1s + walker port, optional URAM L2)
$(ROOT)/hw/rtl/lib/cache/frost_cache_hierarchy.sv

# Tagged line-port -> AXI4 master bridge, multiple outstanding (bottom of the hierarchy)
$(ROOT)/hw/rtl/lib/cache/line_port_axi_bridge.sv

# Simulation-only AXI main-memory model (stands in for DDR)
$(ROOT)/hw/rtl/lib/cache/axi_behavioral_memory.sv

# Cocotb unit-bench harness (stack + bridge + behavioral memory)
$(ROOT)/hw/rtl/lib/cache/frost_cache_test_harness.sv

# Cocotb unit-bench harness (arbiter + bridge + behavioral memory)
$(ROOT)/hw/rtl/lib/cache/line_port_arbiter_test_harness.sv

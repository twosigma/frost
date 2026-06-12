# Cache hierarchy library file list
# Recursive line-port cache + the bottom-of-hierarchy AXI bridge and the
# simulation-only behavioral main memory.

# Write-back direct-mapped line cache (one module for L1 and L2)
$(ROOT)/hw/rtl/lib/cache/frost_cache.sv

# Per-board cache hierarchy wrapper (L1, optional URAM L2)
$(ROOT)/hw/rtl/lib/cache/frost_cache_hierarchy.sv

# Line-port -> AXI4 master bridge (bottom of the hierarchy)
$(ROOT)/hw/rtl/lib/cache/line_port_axi_bridge.sv

# Simulation-only AXI main-memory model (stands in for DDR)
$(ROOT)/hw/rtl/lib/cache/axi_behavioral_memory.sv

# Cocotb unit-bench harness (stack + bridge + behavioral memory)
$(ROOT)/hw/rtl/lib/cache/frost_cache_test_harness.sv

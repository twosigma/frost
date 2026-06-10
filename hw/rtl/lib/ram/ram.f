# RAM primitives library file list
# Generic FPGA memory primitives for use across the design

# Simple dual-port distributed RAM (async read, sync write)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv

# Two-read-port variant of sdp_dist_ram (shared backing array, two async reads)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram_2r.sv

# Multi-write-port distributed RAM using Live Value Table (async read, sync write)
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv

# Two-read-port variant of mwp_dist_ram (shared LVT + banks, two async reads)
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram_2r.sv

# Simple dual-port block RAM (sync read, sync write)
$(ROOT)/hw/rtl/lib/ram/sdp_block_ram.sv

# Dual-clock simple dual-port block RAM (for clock domain crossing)
$(ROOT)/hw/rtl/lib/ram/sdp_block_ram_dc.sv

# True dual-port block RAM with dual clocks and byte enables
$(ROOT)/hw/rtl/lib/ram/tdp_bram_dc_byte_en.sv

# True dual-port block RAM with dual clocks (simple, no byte enables or write-first)
$(ROOT)/hw/rtl/lib/ram/tdp_bram_dc.sv

# Simple dual-port UltraRAM scratchpad (single clock, byte enables, configurable
# read latency) -- backs the high-address URAM memory tier
$(ROOT)/hw/rtl/lib/ram/sdp_uram_byte_en.sv

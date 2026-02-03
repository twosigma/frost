# RAM primitives library file list
# Generic FPGA memory primitives for use across the design

# Simple dual-port distributed RAM (async read, sync write)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv

# Simple dual-port block RAM (sync read, sync write)
$(ROOT)/hw/rtl/lib/ram/sdp_block_ram.sv

# Dual-clock simple dual-port block RAM (for clock domain crossing)
$(ROOT)/hw/rtl/lib/ram/sdp_block_ram_dc.sv

# True dual-port block RAM with dual clocks and byte enables
$(ROOT)/hw/rtl/lib/ram/tdp_bram_dc_byte_en.sv

# True dual-port block RAM with dual clocks (simple, no byte enables or write-first)
$(ROOT)/hw/rtl/lib/ram/tdp_bram_dc.sv

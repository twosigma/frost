# Reorder Buffer unit test file list
# Contains reorder_buffer.sv and its package dependencies

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (distributed RAM used for multi-bit ROB fields)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv

# Reorder Buffer module
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv

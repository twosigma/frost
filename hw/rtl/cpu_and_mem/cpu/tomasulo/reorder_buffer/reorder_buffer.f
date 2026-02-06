# Reorder Buffer unit test file list
# Contains reorder_buffer.sv and its package dependencies

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (distributed RAM used for multi-bit ROB fields)
-f $(ROOT)/hw/rtl/lib/ram/ram.f

# Reorder Buffer module
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv

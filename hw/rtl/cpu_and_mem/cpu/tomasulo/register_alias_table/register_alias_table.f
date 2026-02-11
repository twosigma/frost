# Register Alias Table unit test file list
# Contains register_alias_table.sv and its package dependencies

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (distributed RAM used for checkpoint storage)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv

# Register Alias Table module
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv

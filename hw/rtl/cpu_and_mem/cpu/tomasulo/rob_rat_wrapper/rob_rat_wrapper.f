# ROB-RAT integration wrapper file list
# Contains both submodules and the wrapper

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (used by both ROB and RAT)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv

# Submodules
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv

# Wrapper
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/rob_rat_wrapper/rob_rat_wrapper.sv

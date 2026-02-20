# Tomasulo out-of-order execution engine file list
# Contains all Tomasulo submodules (types are in riscv_pkg Section 12)

# Shared package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# Shared RAM primitives
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv

# Reorder Buffer
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv

# Register Alias Table
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv

# Reservation Station
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv

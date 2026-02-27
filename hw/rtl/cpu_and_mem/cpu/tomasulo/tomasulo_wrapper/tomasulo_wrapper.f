# Tomasulo integration wrapper file list
# Contains ROB, RAT, RS, and the wrapper

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (used by ROB and RAT)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv

# Submodules
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/cdb_arbiter/cdb_arbiter.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_cdb_adapter/fu_cdb_adapter.sv

# FU shims (includes ALU sources)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fu_shims.f

# Load queue (includes load_unit and L0 cache)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ma_stage/load_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv

# Wrapper
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv

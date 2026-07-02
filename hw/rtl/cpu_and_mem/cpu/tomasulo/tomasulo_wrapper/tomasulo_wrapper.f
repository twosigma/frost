# Tomasulo integration wrapper file list
# Contains ROB, RAT, RS, and the wrapper

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (used by ROB and RAT)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram_2r.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram_2r.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram_ohread.sv

# Submodules
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/rob_serializer.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/cdb_arbiter/cdb_arbiter.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_cdb_adapter/fu_cdb_adapter.sv

# FU shims (includes ALU sources)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fu_shims.f

# Load queue (includes load_unit and L0 cache)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_issue_selector.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv

# Store queue (+ extracted store-to-load forwarding submodule)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/sq_forwarding_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv

# Wrapper glue submodules (extracted from tomasulo_wrapper top-level)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/store_addr/sq_early_addr_pipeline.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/commit_bus/commit_bus_pipeline.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/dispatch_routing/dispatch_rs_router.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/atomics/sc_pending_unit.sv

# Wrapper
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv

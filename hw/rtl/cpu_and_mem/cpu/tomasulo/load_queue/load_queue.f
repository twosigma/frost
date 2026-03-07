# Load Queue file list
# Circular buffer tracking in-flight load instructions (hybrid FF + LUTRAM)

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (lq_data LUTRAM)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv

# Load unit (byte/halfword extraction and sign extension)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ma_stage/load_unit.sv

# L0 data cache (OoO-compatible, used internally by load_queue)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv

# Module
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv

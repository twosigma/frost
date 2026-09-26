# Load Queue file list
# Tracks loads, LRs and AMOs from dispatch to the CDB (flip-flops + LUTRAM)

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (LQ data and address LUTRAMs, L0 arrays)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv

# Load unit (byte/halfword/word extraction and sign/zero extension)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_unit.sv

# L0 data cache (instantiated by load_queue)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv

# Issue selector and the load queue itself
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_issue_selector.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv

# Store Queue file list
# Commit-ordered store buffer with store-to-load forwarding (hybrid FF + LUTRAM)

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (sq_data LUTRAM)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv

# Module
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv

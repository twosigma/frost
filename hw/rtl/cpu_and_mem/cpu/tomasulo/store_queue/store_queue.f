# Store Queue file list
# Commit-ordered store buffer with store-to-load forwarding (hybrid FF + LUTRAM)

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (sq_data LUTRAM)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv

# Module (+ extracted store-to-load forwarding submodule)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/sq_forwarding_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv

# Reservation Station file list
# Hybrid FF + LUTRAM storage

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# RAM primitives (payload LUTRAM)
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv
$(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv

# Module
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv

# Register file list: the generic register file behind both the integer and
# FP architectural register files
# Dependencies: sdp_dist_ram and mwp_dist_ram (from lib/ram)

# Generic register file, parameterized by width, read ports, write ports, and
# hardwired zero
$(ROOT)/hw/rtl/cpu_and_mem/cpu/wb_stage/generic_regfile.sv

# Instruction Fetch (IF) stage file list

# RVC reference decompressor (instantiated by pd_stage in simulation)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv

# Branch prediction
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction.f

# Decoupled F0 fetch PC controller
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/fetch_pc_decoupled.sv

# Decoupled parcel queue with zero-cycle empty and partial bypass
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/fetch_parcel_queue.sv

# Instruction MMU - Bare-mode pass-through and Sv39 translation of the fetch PC;
# its TLB module (mmu/dtlb.sv) is listed in tomasulo_wrapper.f
$(ROOT)/hw/rtl/cpu_and_mem/cpu/mmu/immu.sv

# IF integration
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv

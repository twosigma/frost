# Instruction Fetch (IF) stage file list

# RVC alignment and state
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/c_extension.f

# Branch prediction
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction.f

# Holdoffs for stale instruction cycles
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/control_flow_tracker.sv

# PC adders with a preserved synthesis boundary
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_reg_precompute.sv

# Sequential PC calculation
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv

# Fetch and emitted-packet PCs
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_controller.sv

# Served-window coverage
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/served_window_coverage.sv

# Low-BRAM request retargeting
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/fetch_redirect.sv

# Low target sums carried to PD
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pd_target_candidate.sv

# Instruction MMU - Bare-mode pass-through and Sv39 translation of the fetch PC;
# its TLB module (mmu/dtlb.sv) is listed in tomasulo_wrapper.f
$(ROOT)/hw/rtl/cpu_and_mem/cpu/mmu/immu.sv

# IF integration
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv

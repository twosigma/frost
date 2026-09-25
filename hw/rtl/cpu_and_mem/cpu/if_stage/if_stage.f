# Instruction Fetch (IF) stage file list
# Manages program counter and instruction memory interface

# C-Extension support (RVC) - alignment, buffer state, and the reference
# decompressor used in simulation
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/c_extension.f

# Branch prediction - BTB, bimodal direction predictor, return address stack
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction.f

# Control flow tracker - holdoff signal generation for stale instruction cycles
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/control_flow_tracker.sv

# PC register pre-computation - adder submodule with dont_touch boundary
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_reg_precompute.sv

# PC increment calculator - sequential PC computation with parallel adders
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv

# PC controller - program counter management with C-ext and branch prediction support
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_controller.sv

# Served-window check - whether a provider's window covers pc_reg's packet
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/served_window_coverage.sv

# Fetch redirect - registered retarget pulse for the low-BRAM fetch presenter
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/fetch_redirect.sv

# Instruction MMU - Bare-mode pass-through and Sv39 translation of the fetch PC;
# its TLB module (mmu/dtlb.sv) is listed in tomasulo_wrapper.f
$(ROOT)/hw/rtl/cpu_and_mem/cpu/mmu/immu.sv

# IF stage top-level - instantiates and connects submodules
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv

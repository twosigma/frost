# Instruction Fetch (IF) stage file list
# Manages program counter and instruction memory interface

# C-Extension support (RVC) - decompression, alignment, state tracking
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/c_extension.f

# Branch prediction - BTB-based prediction to reduce control flow penalties
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction.f

# Control flow tracker - holdoff signal generation for stale instruction cycles
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/control_flow_tracker.sv

# PC register pre-computation - adder submodule with dont_touch boundary
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_reg_precompute.sv

# PC increment calculator - sequential PC computation with parallel adders
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv

# PC controller - program counter management with C-ext and branch prediction support
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_controller.sv

# IF stage top-level - instantiates and connects submodules
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.sv

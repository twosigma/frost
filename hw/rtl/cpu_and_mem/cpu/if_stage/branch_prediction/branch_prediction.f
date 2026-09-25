# Branch Prediction file list
# BTB, bimodal direction predictor, return address stack, and their control logic

# Branch Target Buffer (BTB) - stores predicted targets
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv

# Direction predictor (bimodal) - conditional-branch direction without a taken BTB prediction
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/direction_predictor.sv

# Return Address Stack (RAS) - predicts function return addresses
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/return_address_stack.sv

# Branch prediction controller - gating logic and registration
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv

# Prediction metadata tracker - aligns prediction metadata with the IF output across
# stalls, bubbles, and the pending-prediction handoff
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/prediction_metadata_tracker.sv

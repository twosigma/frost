# Branch Prediction file list
# BTB-based branch prediction for reducing control flow penalties

# Branch Target Buffer (BTB) - stores predicted targets
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv

# Return Address Stack (RAS) - predicts function return addresses
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/ras_detector.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/return_address_stack.sv

# Branch prediction controller - gating logic and registration
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv

# Prediction metadata tracker - manages prediction info through stalls/spanning
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/prediction_metadata_tracker.sv

# Branch Prediction file list

# Target lookup
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv

# Conditional direction for PD redirects
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/direction_predictor.sv

# Return targets
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/return_address_stack.sv

# Prediction gating and registration
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv

# Metadata alignment across stalls, bubbles, and pending handoffs
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/prediction_metadata_tracker.sv

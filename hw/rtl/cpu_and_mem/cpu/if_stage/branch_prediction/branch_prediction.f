# Branch Prediction file list

# Two-bank direct-mapped F0 fast BTB
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/fetch_btb_2w.sv

# Four-bank bimodal direction predictor
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/fetch_dir_4b.sv

# Tagged, history-based conditional direction for PD redirects
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/tage_predictor.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/ittage_predictor.sv

# Second-level targets for PD redirects
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/backing_btb.sv

# Return targets
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/return_address_stack.sv

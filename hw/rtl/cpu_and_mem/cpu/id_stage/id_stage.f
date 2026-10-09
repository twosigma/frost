# Instruction Decode (ID) stage file list

# Operation decode
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv

# Dispatch operand classes - parallel to operation decode
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/instr_operand_classifier.sv

# I/S/B/U/J immediates
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/immediate_decoder.sv

# Parallel instruction-class decode
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/instruction_type_decoder.sv

# Branch targets and prediction checks
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/branch_target_precompute.sv

# Dispatch packets for up to two instructions
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.sv

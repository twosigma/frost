# Instruction Decode (ID) stage file list
# Decodes RISC-V instructions and extracts immediate values

# Instruction decoder - determines operation type from opcode/funct fields
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv

# Immediate value decoder - extracts I/S/B/U/J type immediates
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/immediate_decoder.sv

# Instruction type decoder - direct type detection for timing optimization
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/instruction_type_decoder.sv

# Branch target pre-computation - targets and prediction verification
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/branch_target_precompute.sv

# ID stage integration - registers the dispatch packets for up to two instructions
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.sv

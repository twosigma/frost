# C-Extension (RVC) support file list
# Handles 16-bit compressed instruction alignment, state tracking, and decompression

# RVC decompressor - expands 16-bit compressed instructions to 32-bit
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv

# C-extension state - instruction buffer, stall-saved fetch word, registered size
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/c_ext_state.sv

# Instruction aligner - parcel selection based on PC alignment and C-ext state
$(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/instruction_aligner.sv

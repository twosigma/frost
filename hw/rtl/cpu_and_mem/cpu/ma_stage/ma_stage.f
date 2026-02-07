# Memory Access (MA) stage file list
# Completes load operations with proper byte extraction and sign extension

# Load unit - extracts bytes/halfwords/words and sign/zero-extends
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ma_stage/load_unit.sv

# AMO unit - handles atomic read-modify-write operations (A extension)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ma_stage/amo_unit.sv

# FP64 load/store sequencer - handles double-precision memory access sequencing
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ma_stage/fp64_sequencer.sv

# MA stage integration - selects between ALU result and load data for writeback
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ma_stage/ma_stage.sv

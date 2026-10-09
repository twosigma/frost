# FU shim modules file list
# Shims translate rs_issue_t into FU-specific ports, instantiate the FU,
# and pack the result into fu_complete_t.

# DSP-tiled multiplier core (used by the integer multiplier)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/dsp_tiled_multiplier_unsigned.sv

# RAM primitive used by the integer MUL/DIV shim's multiply result FIFO
$(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv

# ALU, plus the multiplier and divider sources int_muldiv_shim needs
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.f

# Integer ALU shim (INT_RS -> ALU -> fu_complete_t)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_alu_shim.sv

# Integer MUL/DIV shim (MUL_RS -> multiplier/divider -> fu_complete_t)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv

# FP engine (every F and D compute instruction)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu.f

# FP shim (FP_RS -> fp_engine -> fu_complete_t)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_shim.sv

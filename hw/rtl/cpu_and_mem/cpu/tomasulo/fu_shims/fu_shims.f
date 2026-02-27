# FU shim modules file list
# Shims translate rs_issue_t into FU-specific ports, instantiate the FU,
# and pack the result into fu_complete_t.

# DSP tiled multiplier (shared by ALU multiplier and FPU multiplier)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/dsp_tiled_multiplier_unsigned.sv

# ALU (includes multiplier and divider sources needed by alu.sv)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.f

# Integer ALU shim (INT_RS -> ALU -> fu_complete_t)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_alu_shim.sv

# Integer MUL/DIV shim (MUL_RS -> multiplier/divider -> fu_complete_t)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv

# FPU subunits (shared by all FP shims)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu.f

# FP add/compare/classify/sgnj/convert shim (FP_RS -> subunits -> fu_complete_t)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_add_shim.sv

# FP multiply/FMA shim (FMUL_RS -> fpu_mult_unit/fpu_fma_unit -> fu_complete_t)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_mul_shim.sv

# FP divide/sqrt shim (FDIV_RS -> fpu_div_sqrt_unit -> fu_complete_t)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_div_shim.sv

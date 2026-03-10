# RISC-V OOO CPU core file list (Tomasulo out-of-order execution)
# RV32IMACBFD + Zicsr, with IF/PD/ID front-end and Tomasulo back-end

# Package with all type definitions and pipeline interconnect structures
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# Pipeline Stage 1: Instruction Fetch (IF)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.f

# Pipeline Stage 2: Pre-Decode (PD)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/pd_stage/pd_stage.f

# Pipeline Stage 3: Instruction Decode (ID)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.f

# Register file (integer + FP, shared with in-order)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/wb_stage/regfile.f

# Tomasulo wrapper (ROB, RAT, RS, CDB, FU shims, LQ, SQ)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.f

# Dispatch unit
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.sv

# Branch/jump resolution (combinational, reused from EX stage)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/branch_jump_unit.sv

# CSR file (Zicsr + Zicntr extensions)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/csr/csr.f

# Trap unit (exception/interrupt handling)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv

# OOO CPU top-level integration
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo.sv

/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * FROST CPU Core - 6-stage pipelined RISC-V processor (RV32IMACBF)
 *
 * This is the top-level CPU module containing the complete 6-stage pipeline
 * and all supporting units (forwarding, hazards, traps, CSRs, cache, atomics, FPU).
 *
 * ISA Support:
 * ============
 *   RV32I   - Base integer (37 instructions)
 *   M       - Multiply/divide (8 instructions)
 *   A       - Atomics: LR/SC, AMO (11 instructions)
 *   F       - Single-precision floating-point (26 instructions)
 *   C       - Compressed 16-bit (27 instruction forms)
 *   B       - Bit manipulation: Zba + Zbb + Zbs (43 instructions)
 *   Zicsr   - CSR access (6 instructions)
 *   Zicntr  - Performance counters (cycle, time, instret)
 *   Zicond  - Conditional zero (2 instructions)
 *   Zbkb    - Crypto bit manipulation (5 instructions)
 *   Machine mode - Full M-mode trap handling
 *
 * Pipeline Stages:
 * ================
 *   +----+   +----+   +----+   +----+   +----+   +----+
 *   | IF | > | PD | > | ID | > | EX | > | MA | > | WB |
 *   +----+   +----+   +----+   +----+   +----+   +----+
 *     |         |        |        |        |        |
 *     |         |        |        +--------+--------+
 *     |         |        |        |  Forwarding paths
 *     |         |        |        |
 *     |         |        v        v
 *     |         |    +------------------+
 *     |         |    |  Forwarding Unit |
 *     |         |    +------------------+
 *     |         |              |
 *     |         v              |
 *     |    +---------+         |
 *     |    | Regfile | <-------+ (WB writes)
 *     |    +---------+
 *     |
 *     v
 *   +-------------------------------------+
 *   |        Hazard Resolution Unit       |
 *   |   (stall/flush, load-use, mul/div)  |
 *   +-------------------------------------+
 *
 * Module Hierarchy:
 * =================
 *   cpu
 *   ├── if_stage          Instruction fetch, PC control, C-extension handling
 *   │   ├── pc_controller     PC update logic, branch targeting
 *   │   ├── branch_prediction/    Branch prediction subsystem
 *   │   │   ├── branch_predictor       32-entry BTB
 *   │   │   ├── branch_prediction_controller  Prediction gating
 *   │   │   └── prediction_metadata_tracker   Stall/spanning handling
 *   │   └── c_extension/          Compressed instruction support
 *   │       ├── c_ext_state           State machines (spanning, buffer)
 *   │       ├── instruction_aligner   Parcel selection
 *   │       └── rvc_decompressor      16-bit → 32-bit expansion
 *   ├── pd_stage          Pre-decode, early source register extraction
 *   ├── id_stage          Instruction decode, immediate extraction
 *   │   └── instr_decoder     Opcode/funct field decoding
 *   ├── ex_stage          Execute: ALU, branches, memory address, FPU
 *   │   ├── alu               Arithmetic/logic operations
 *   │   │   ├── multiplier    2-cycle pipelined multiply
 *   │   │   └── divider       16-stage pipelined divide
 *   │   ├── fpu               Floating-point unit (F extension)
 *   │   │   ├── fp_adder      3-cycle pipelined add/sub
 *   │   │   ├── fp_multiplier 3-cycle pipelined multiply
 *   │   │   ├── fp_divider    ~15-cycle sequential divide
 *   │   │   ├── fp_sqrt       ~15-cycle sequential sqrt
 *   │   │   ├── fp_fma        4-cycle pipelined FMA
 *   │   │   └── ...           Compare, convert, classify, sign inject
 *   │   ├── branch_jump_unit  Branch condition evaluation
 *   │   ├── store_unit        Store address/data preparation
 *   │   └── exception_detector  ECALL, EBREAK, misaligned access
 *   ├── ma_stage          Memory access, load completion
 *   │   ├── load_unit         Load data extraction/sign-extension
 *   │   └── amo_unit          Atomic memory operations FSM
 *   ├── regfile           32x32 integer register file (2R/1W)
 *   ├── fp_regfile        32x32 FP register file (3R/1W for FMA)
 *   ├── l0_cache          Direct-mapped data cache (128 entries)
 *   ├── csr_file          Control/Status registers (M-mode + counters)
 *   ├── forwarding_unit   Integer RAW hazard resolution via bypass
 *   ├── fp_forwarding_unit FP RAW hazard resolution via bypass
 *   ├── hazard_resolution_unit  Stall/flush control
 *   ├── trap_unit         Exception/interrupt handling
 *   └── lr_sc_reservation LR/SC address reservation for atomics
 *
 * Key Features:
 * =============
 *   - Full data forwarding (0-cycle penalty for most RAW hazards)
 *   - L0 cache eliminates load-use stall when data is cached
 *   - 2-cycle multiply, 17-cycle divide (fully pipelined)
 *   - 3-cycle branch penalty (all branches resolved in EX)
 *   - Full M-mode trap handling (interrupts + exceptions)
 *   - CLINT-compatible timer (mtime/mtimecmp)
 *
 * Memory Interface:
 * =================
 *   Instruction: o_pc → i_instr (1-cycle latency, word-aligned)
 *   Data:        o_data_mem_addr → i_data_mem_rd_data (1-cycle latency)
 *                o_data_mem_wr_data, o_data_mem_per_byte_wr_en (byte enables)
 *
 * See Also:
 *   - README.md: Architecture overview and diagrams
 *   - riscv_pkg.sv: Type definitions and inter-stage structures
 *   - cpu_and_mem.sv: Integration with memory subsystem
 */
module cpu #(
    /*
      XLEN is RISC-V term for processor data width. 64 would be another possible value,
      but not yet supported by FROST.
    */
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h28
) (
    input logic i_clk,
    input logic i_rst,
    // interface with instruction memory
    output logic [XLEN-1:0] o_pc,
    input logic [31:0] i_instr,  // Raw 32-bit fetch (C extension handles decompression in IF stage)
    // interface with data memory
    input logic [XLEN-1:0] i_data_mem_rd_data,
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [3:0] o_data_mem_per_byte_wr_en,
    output logic o_data_mem_read_enable,
    output logic o_mmio_read_pulse,
    output logic [XLEN-1:0] o_mmio_load_addr,
    output logic o_mmio_load_valid,
    // reset sequence (due to cache LUTRAM clear) finished
    output logic o_rst_done,
    // these indicate output is valid. useful for testbench
    output logic o_vld,
    output logic o_pc_vld,
    // Interrupt inputs (active-high)
    input riscv_pkg::interrupt_t i_interrupts,
    // Timer interface (from memory-mapped mtime register)
    input logic [63:0] i_mtime,
    // Branch prediction disable (for verification - prevents BTB predictions)
    input logic i_disable_branch_prediction
);

  // 6-stage pipeline: IF -> PD -> ID -> EX -> MA -> WB
  localparam int unsigned NumPipelineStages = 6;
  // Interconnect structs between stages/submodules
  riscv_pkg::from_if_to_pd_t from_if_to_pd;
  riscv_pkg::from_pd_to_id_t from_pd_to_id;
  riscv_pkg::from_id_to_ex_t from_id_to_ex;
  riscv_pkg::from_ex_comb_t from_ex_comb;
  riscv_pkg::from_ex_to_ma_t from_ex_to_ma;
  riscv_pkg::from_ma_comb_t from_ma_comb;
  riscv_pkg::from_ma_to_wb_t from_ma_to_wb;
  riscv_pkg::from_cache_t from_cache;
  riscv_pkg::fwd_to_ex_t fwd_to_ex;
  riscv_pkg::rf_to_fwd_t rf_to_fwd;
  riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
  // F extension: FP forwarding and regfile signals
  riscv_pkg::fp_fwd_to_ex_t fp_fwd_to_ex;
  riscv_pkg::fp_rf_to_fwd_t fp_rf_to_fwd;
  logic [2:0] frm_csr;  // Rounding mode from frm CSR
  // CSR file signals (Zicsr/Zicntr extensions)
  logic [XLEN-1:0] csr_read_data;
  logic [XLEN-1:0] csr_mstatus, csr_mie, csr_mtvec, csr_mepc;
  logic csr_mstatus_mie_direct;  // Direct MIE bit output to avoid Icarus issues with bit extraction
  // Trap unit signals
  logic trap_taken, mret_taken;
  logic [XLEN-1:0] trap_target, trap_pc, trap_cause, trap_value;
  logic stall_for_wfi;
  riscv_pkg::trap_ctrl_t trap_ctrl;
  assign trap_ctrl.trap_taken  = trap_taken;
  assign trap_ctrl.mret_taken  = mret_taken;
  assign trap_ctrl.trap_target = trap_target;
  // A extension: LR/SC reservation register
  riscv_pkg::reservation_t reservation;
  // A extension: AMO unit signals
  logic amo_stall_for_amo;
  riscv_pkg::amo_interface_t amo;  // AMO write interface (enable, data, address)
  logic amo_write_enable_delayed;  // Delayed by 1 cycle, for regfile bypass
  logic [XLEN-1:0] amo_result;
  logic amo_read_phase;
  // Stall signal excluding AMO comes from hazard_resolution_unit as a separate output.
  // This breaks the combinational loop: stall → AMO check → stall_for_amo → stall
  // The hazard unit computes it as: stall_for_mul_div | stall_for_load_use | stall_for_wfi
  // (excludes i_stall_for_amo to prevent the loop)
  // NOTE: This is a separate wire (not through packed struct) to avoid false loop detection.
  logic stall_excluding_amo;

  // Stall signal for FPU input - excludes FPU in-flight hazard so FPU can continue computing
  // to resolve the hazard. Similar to how integer multiply continues during multiply stall.
  logic stall_for_fpu_input;

  // Hazard resolution unit - manages stalls, flushes
  hazard_resolution_unit #(
      .XLEN(XLEN),
      .NUM_PIPELINE_STAGES(NumPipelineStages),
      .MMIO_ADDR(MMIO_ADDR),
      .MMIO_SIZE_BYTES(MMIO_SIZE_BYTES)
  ) hazard_resolution_unit_inst (
      .i_clk,
      .i_rst,
      .i_from_pd_to_id(from_pd_to_id),
      .i_from_id_to_ex(from_id_to_ex),
      .i_from_ex_to_ma(from_ex_to_ma),
      .i_from_ex_comb(from_ex_comb),
      .i_from_cache(from_cache),
      .i_stall_for_amo(amo_stall_for_amo),
      .i_amo_write_enable_delayed(amo_write_enable_delayed),
      // F extension: FPU stall for multi-cycle operations
      .i_stall_for_fpu(from_ex_comb.stall_for_fpu),
      // Trap handling
      .i_trap_taken(trap_taken),
      .i_mret_taken(mret_taken),
      .i_stall_for_wfi(stall_for_wfi),
      .o_pipeline_ctrl(pipeline_ctrl),
      .o_stall_excluding_amo(stall_excluding_amo),
      .o_stall_for_fpu_input(stall_for_fpu_input),
      .o_mmio_read_pulse(o_mmio_read_pulse),
      .o_rst_done,
      .o_vld,
      .o_pc_vld
  );

  /*
    Stage 1: Instruction Fetch (IF)
    Manages program counter, branch target calculation, and instruction memory interface.
    Handles C extension: decompresses 16-bit instructions and manages variable-length fetch.
    All branches and jumps (JAL, JALR, conditional) are resolved in EX stage.
  */
  if_stage #(
      .XLEN(XLEN)
  ) if_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_instr,
      .i_from_ex_comb(from_ex_comb),
      // Trap handling: PC redirection on trap entry/exit
      .i_trap_ctrl(trap_ctrl),
      // Branch prediction control (for verification)
      .i_disable_branch_prediction,
      .o_pc,
      .o_from_if_to_pd(from_if_to_pd)
  );

  /*
    Stage 2: Pre-Decode (PD)
    Pipeline register between IF and ID for timing closure and future pre-decode logic.
  */
  pd_stage #(
      .XLEN(XLEN)
  ) pd_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_if_to_pd(from_if_to_pd),
      .o_from_pd_to_id(from_pd_to_id)
  );

  /*
    Stage 3: Instruction Decode (ID)
    Decodes instructions, generates immediate values, and detects instruction types.
    Also registers regfile read data for the EX stage, with WB bypass for same-cycle writes.
  */
  id_stage #(
      .XLEN(XLEN)
  ) id_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),
      .i_rf_to_id(rf_to_fwd),  // Regfile read data (read in ID stage, registered here)
      .i_fp_rf_to_id(fp_rf_to_fwd),  // F extension: FP regfile read data
      .i_from_ma_to_wb(from_ma_to_wb),  // For WB bypass (WB writes same cycle as ID reads)
      .o_from_id_to_ex(from_id_to_ex)
  );

  /*
    Stage 4: Execute (EX)
    Performs ALU operations, branch resolution, memory address generation
  */
  ex_stage #(
      .XLEN(XLEN)
  ) ex_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_id_to_ex(from_id_to_ex),
      .i_fwd_to_ex(fwd_to_ex),
      // F extension: FP operand forwarding
      .i_fp_fwd_to_ex(fp_fwd_to_ex),
      .i_csr_read_data(csr_read_data),
      // F extension: Rounding mode from frm CSR
      .i_frm_csr(frm_csr),
      // F extension: Stall for FPU (excludes FPU RAW hazard so FPU can continue computing)
      .i_stall_for_fpu(stall_for_fpu_input),
      .i_reservation(reservation),
      .o_from_ex_comb(from_ex_comb),
      .o_from_ex_to_ma(from_ex_to_ma)
  );

  // Data memory interface outputs
  // During AMO stall, use from_ex_to_ma (current AMO address for read)
  // During AMO write, use captured address (stable even if from_ex_to_ma changes)
  // Otherwise use EX stage combinational signals for normal loads/stores
  assign o_data_mem_addr = amo.write_enable ? amo.write_address :
                           amo_stall_for_amo ? from_ex_to_ma.data_memory_address :
                           from_ex_comb.data_memory_address;
  assign o_data_mem_wr_data = amo.write_enable ? amo.write_data :
                                                  from_ex_comb.data_memory_write_data;
  // TIMING OPTIMIZATION: Use stall_for_trap_check instead of stall.
  // The regular stall signal depends on ~trap_taken (traps override stall), creating
  // a critical path: forwarding → trap_detection → stall → memory_write_enable.
  // stall_for_trap_check = stall_sources (no trap/mret gating) breaks this path.
  // Functionally safe: non-store instructions have byte_write_enable = 0 anyway,
  // and using stall_sources is more conservative (blocks writes during any stall).
  assign o_data_mem_per_byte_wr_en = amo.write_enable ? 4'b1111 :
                                     (from_ex_comb.data_memory_byte_write_enable &
                                      {4{~pipeline_ctrl.stall_for_trap_check}});
  assign o_data_mem_read_enable = (from_ex_to_ma.is_load_instruction | from_ex_to_ma.is_lr) &
                                  ~pipeline_ctrl.stall;
  assign o_mmio_load_addr = from_ex_to_ma.data_memory_address;
  assign o_mmio_load_valid = from_ex_to_ma.is_load_instruction |
                             from_ex_to_ma.is_lr |
                             from_ex_to_ma.is_fp_load;

  /*
    Stage 5: Memory Access (MA)
    Completes load operations and prepares data for writeback
  */
  ma_stage #(
      .XLEN(XLEN),
      .MMIO_ADDR(MMIO_ADDR),
      .MMIO_SIZE_BYTES(MMIO_SIZE_BYTES)
  ) ma_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_ex_to_ma(from_ex_to_ma),
      .i_data_mem_rd_data,
      .i_amo_result(amo_result),
      .i_amo_write_enable(amo.write_enable),
      .o_from_ma_comb(from_ma_comb),
      .o_from_ma_to_wb(from_ma_to_wb),
      .o_amo_write_enable_delayed(amo_write_enable_delayed)
  );

  /*
    A extension: Atomic Memory Operation Unit
    Handles read-modify-write operations for AMO instructions.
    Stalls pipeline during atomic operation and drives memory write.
  */
  // Early AMO detection: true when a regular AMO (not LR/SC) is in EX stage.
  // This allows the AMO unit to capture forwarded rs2 before entering MA.
  logic amo_in_ex;
  assign amo_in_ex = from_id_to_ex.is_amo_instruction &&
                     !from_id_to_ex.is_lr && !from_id_to_ex.is_sc;

  amo_unit #(
      .XLEN(XLEN)
  ) amo_unit_inst (
      .i_clk,
      .i_rst,
      .i_stall(stall_excluding_amo),  // Use external stalls only to avoid combinational loop
      // Early detection and RS2 capture for correct forwarding timing
      .i_amo_in_ex(amo_in_ex),
      .i_rs2_fwd(fwd_to_ex.source_reg_2_value),
      // From EX→MA pipeline register
      .i_is_amo_instruction(from_ex_to_ma.is_amo_instruction),
      .i_is_lr(from_ex_to_ma.is_lr),
      .i_is_sc(from_ex_to_ma.is_sc),
      .i_instruction_operation(from_ex_to_ma.instruction_operation),
      .i_data_memory_address(from_ex_to_ma.data_memory_address),
      .i_data_memory_read_data(from_ma_comb.data_memory_read_data),
      .o_stall_for_amo(amo_stall_for_amo),
      .o_amo_write_enable(amo.write_enable),
      .o_amo_write_data(amo.write_data),
      .o_amo_write_addr(amo.write_address),
      .o_amo_result(amo_result),
      .o_amo_read_phase(amo_read_phase)
  );

  /*
    Register File (reads in ID stage, writes in WB stage)
    Read addresses come from PD stage (early source registers) so reads occur in ID stage.
    Read data is registered at ID→EX boundary, removing regfile from EX critical path.
    Note: x0 (register 0) is hardwired to zero, so writes to it are blocked.
  */
  regfile #(
      .DATA_WIDTH(XLEN)
  ) regfile_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),  // Read address from PD stage (early source regs)
      .i_from_ma_to_wb(from_ma_to_wb),
      .o_rf_to_fwd(rf_to_fwd)
  );

  /*
    F extension: Floating-Point Register File
    32x32 FP registers (f0-f31), with 3 read ports (for FMA) and 1 write port.
    Unlike integer regfile, there is no hardwired zero register.
  */
  fp_regfile #(
      .DATA_WIDTH(XLEN)
  ) fp_regfile_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),  // Read addresses from PD stage
      .i_from_ma_to_wb(from_ma_to_wb),  // Write data from WB stage
      .o_fp_rf_to_fwd (fp_rf_to_fwd)
  );

  // L0 data cache - reduces memory latency for frequently accessed data
  l0_cache #(
      .CACHE_DEPTH(128),
      .XLEN(XLEN),
      .MEM_BYTE_ADDR_WIDTH(MEM_BYTE_ADDR_WIDTH),
      .MMIO_ADDR(MMIO_ADDR)
  ) l0_cache_inst (
      .i_clk,
      .i_rst,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_id_to_ex(from_id_to_ex),
      .i_from_ex_comb(from_ex_comb),
      .i_from_ex_to_ma(from_ex_to_ma),
      .i_from_ma_comb(from_ma_comb),
      // A extension: AMO write interface for cache coherence
      .i_amo(amo),
      .o_from_cache(from_cache)
  );

  // Forwarding unit - resolves data hazards by forwarding results from later stages
  // Uses registered regfile data from from_id_to_ex (read in ID stage, not EX stage)
  forwarding_unit #(
      .XLEN(XLEN),
      .MMIO_ADDR(MMIO_ADDR),
      .MMIO_SIZE_BYTES(MMIO_SIZE_BYTES)
  ) forwarding_unit_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),
      .i_from_id_to_ex(from_id_to_ex),
      .i_from_ex_comb(from_ex_comb),
      .i_from_ex_to_ma(from_ex_to_ma),
      .i_from_ma_comb(from_ma_comb),
      .i_from_ma_to_wb(from_ma_to_wb),
      .i_from_cache(from_cache),
      // A extension: AMO result forwarding
      .i_amo_write_enable(amo.write_enable),
      .i_amo_result(amo_result),
      .i_amo_read_phase(amo_read_phase),
      .o_fwd_to_ex(fwd_to_ex)
  );

  // F extension: FP forwarding unit - resolves FP RAW hazards
  // Three source operand forwarding for FMA instructions (fs1, fs2, fs3)
  fp_forwarding_unit #(
      .XLEN(XLEN)
  ) fp_forwarding_unit_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),
      .i_from_id_to_ex(from_id_to_ex),
      .i_from_ex_comb (from_ex_comb),
      .i_from_ex_to_ma(from_ex_to_ma),
      .i_from_ma_comb (from_ma_comb),
      .i_from_ma_to_wb(from_ma_to_wb),
      .o_fp_fwd_to_ex (fp_fwd_to_ex)
  );

  /*
    CSR File (Zicsr + Zicntr + Machine-mode + F extensions)
    Implements Control and Status Registers including:
    - F extension: fflags, frm, fcsr (FP exception flags and rounding mode)
    - Performance counters: cycle, time, instret
    - Machine-mode CSRs: mstatus, mie, mtvec, mscratch, mepc, mcause, mtval, mip
  */
  // CSR write enable: write when instruction commits and not stalled.
  // Ignore CSR read stall so CSR writes (e.g., MIE enable) aren't delayed an extra cycle.
  logic csr_write_enable;
  assign csr_write_enable = ~pipeline_ctrl.stall_for_trap_check && ~trap_taken;

  // CSR write data: rs1 value for register-based ops, zero-extended immediate for immediate ops
  logic [XLEN-1:0] csr_write_data;
  assign csr_write_data = (from_id_to_ex.instruction_operation == riscv_pkg::CSRRWI ||
                           from_id_to_ex.instruction_operation == riscv_pkg::CSRRSI ||
                           from_id_to_ex.instruction_operation == riscv_pkg::CSRRCI) ?
                          {27'b0, from_id_to_ex.csr_imm} : fwd_to_ex.source_reg_1_value;

  // Extract funct3 from instruction for CSR operations
  // Note: We use explicit bit select from the 32-bit representation because
  // Icarus Verilog has issues with packed struct field access in port connections
  logic [2:0] csr_op_funct3;
  assign csr_op_funct3 = 3'(32'(from_id_to_ex.instruction) >> 12);

  csr_file #(
      .XLEN(XLEN)
  ) csr_file_inst (
      .i_clk,
      .i_rst,
      // CSR access interface
      .i_csr_read_enable(from_id_to_ex.is_csr_instruction),
      .i_csr_address(from_id_to_ex.csr_address),
      .i_csr_op(csr_op_funct3),  // funct3 for CSR operation
      .i_csr_write_data(csr_write_data),
      .i_csr_write_enable(csr_write_enable),
      .o_csr_read_data(csr_read_data),
      // Instruction retire
      .i_instruction_retired(o_vld && ~trap_taken),
      // Interrupt inputs
      .i_interrupts(i_interrupts),
      // Timer input
      .i_mtime(i_mtime),
      // Trap entry signals
      .i_trap_taken(trap_taken),
      .i_trap_pc(trap_pc),
      .i_trap_cause(trap_cause),
      .i_trap_value(trap_value),
      // MRET signal
      .i_mret_taken(mret_taken),
      // CSR outputs for trap unit
      .o_mstatus(csr_mstatus),
      .o_mie(csr_mie),
      .o_mtvec(csr_mtvec),
      .o_mepc(csr_mepc),
      .o_mstatus_mie_direct(csr_mstatus_mie_direct),
      // F extension: FP exception flags accumulation
      .i_fp_flags(from_ma_to_wb.fp_flags),
      .i_fp_flags_valid(from_ma_to_wb.fp_regfile_write_enable && o_vld && ~trap_taken),
      // F extension: FP flags from MA stage (for CSR read hazard forwarding)
      .i_fp_flags_ma(from_ex_to_ma.fp_flags),
      .i_fp_flags_ma_valid(from_ex_to_ma.is_fp_instruction &&
                           (from_ex_to_ma.fp_regfile_write_enable || from_ex_to_ma.is_fp_to_int)),
      // F extension: Rounding mode output for FPU
      .o_frm(frm_csr)
  );

  /*
    Trap Unit
    Handles exception detection, interrupt arbitration, and trap entry/exit logic.
    Coordinates with CSR file and pipeline control for trap handling.
  */
  trap_unit #(
      .XLEN(XLEN)
  ) trap_unit_inst (
      .i_clk,
      .i_rst,
      // Pipeline control - use stall_for_trap_check to break combinatorial loop
      // (trap_taken affects stall, but stall_for_trap_check doesn't depend on trap_taken)
      .i_pipeline_stall(pipeline_ctrl.stall_for_trap_check),
      // CSR values
      .i_mstatus(csr_mstatus),
      .i_mie(csr_mie),
      .i_mtvec(csr_mtvec),
      .i_mepc(csr_mepc),
      .i_mstatus_mie_direct(csr_mstatus_mie_direct),
      // Interrupt inputs
      .i_interrupts(i_interrupts),
      // Exception inputs from EX stage
      .i_exception_valid(from_ex_comb.exception_valid),
      .i_exception_cause(from_ex_comb.exception_cause),
      .i_exception_tval(from_ex_comb.exception_tval),
      .i_exception_pc(from_id_to_ex.program_counter),
      // MRET instruction in EX stage
      .i_mret_in_ex(from_id_to_ex.is_mret),
      // WFI instruction in EX stage
      .i_wfi_in_ex(from_id_to_ex.is_wfi),
      // Trap control outputs
      .o_trap_taken(trap_taken),
      .o_mret_taken(mret_taken),
      .o_trap_target(trap_target),
      // To CSR file
      .o_trap_pc(trap_pc),
      .o_trap_cause(trap_cause),
      .o_trap_value(trap_value),
      // WFI stall
      .o_stall_for_wfi(stall_for_wfi)
  );

  /*
    A extension: LR/SC Reservation Register
    Tracks load-reserved address for store-conditional synchronization.
  */
  lr_sc_reservation #(
      .XLEN(XLEN)
  ) lr_sc_reservation_inst (
      .i_clk,
      .i_rst,
      .i_stall(pipeline_ctrl.stall),
      .i_is_lr_in_ma(from_ex_to_ma.is_lr),
      .i_lr_address(from_ex_to_ma.data_memory_address),
      .i_is_sc_in_ex(from_id_to_ex.is_sc),
      .o_reservation(reservation)
  );

endmodule : cpu

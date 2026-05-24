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
 * OOO Register Files (integer + FP) with widen-commit write-back bypass.
 *
 * Encapsulates the two architectural register files (read in ID, written from
 * ROB commit) together with the same-cycle write-back bypass that resolves a
 * source register being committed on the same edge it is read.
 *
 * Both files use a 2-write-port topology for widen (2-wide) commit: port 0 =
 * slot 1 (rob_commit), port 1 = slot 2 (rob_commit_2). The mwp_dist_ram LVT
 * steers same-address reads to the higher-numbered port (slot 2), matching
 * program order (slot 2 tag T+1 > slot 1 tag T). The bypass mirrors that
 * priority (port 1 > port 0) for the read ports that feed ID and dispatch.
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Register Files" section, with the parent's write-port / inter-stage
 * signals presented as ports and aliased back to their original names.
 */

module ooo_register_files #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,

    // ROB-commit write ports (port 0 = slot 1, port 1 = slot 2).
    input logic                          i_port0_int_we,
    input logic [                   4:0] i_port0_int_addr,
    input logic [              XLEN-1:0] i_port0_int_data,
    input logic                          i_port1_int_we,
    input logic [                   4:0] i_port1_int_addr,
    input logic [              XLEN-1:0] i_port1_int_data,
    input logic                          i_port0_fp_we,
    input logic [                   4:0] i_port0_fp_addr,
    input logic [riscv_pkg::FpWidth-1:0] i_port0_fp_data,
    input logic                          i_port1_fp_we,
    input logic [                   4:0] i_port1_fp_addr,
    input logic [riscv_pkg::FpWidth-1:0] i_port1_fp_data,

    // Read source addresses (slot 1 / slot 2, ID-early and dispatch).
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id,
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id_2,
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex_2,

    // Resolved (post-bypass) read results.
    output riscv_pkg::rf_to_fwd_t                             o_rf_to_fwd,
    output riscv_pkg::rf_to_fwd_t                             o_rf_to_fwd_2,
    output logic                     [              XLEN-1:0] o_int_rf_dispatch_rs1_data,
    output logic                     [              XLEN-1:0] o_int_rf_dispatch_rs2_data,
    output logic                     [              XLEN-1:0] o_int_rf_dispatch_rs1_data_2,
    output logic                     [              XLEN-1:0] o_int_rf_dispatch_rs2_data_2,
    output riscv_pkg::fp_rf_to_fwd_t                          o_fp_rf_to_fwd,
    output riscv_pkg::fp_rf_to_fwd_t                          o_fp_rf_to_fwd_2,
    output logic                     [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs1_data,
    output logic                     [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs2_data,
    output logic                     [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs3_data,
    output logic                     [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs1_data_2,
    output logic                     [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs2_data_2,
    output logic                     [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs3_data_2
);

  // FP data width (declared first: the port aliases below size FP signals).
  localparam int unsigned FpW = riscv_pkg::FpWidth;

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  logic            port0_int_we;
  logic [     4:0] port0_int_addr;
  logic [XLEN-1:0] port0_int_data;
  logic            port1_int_we;
  logic [     4:0] port1_int_addr;
  logic [XLEN-1:0] port1_int_data;
  logic            port0_fp_we;
  logic [     4:0] port0_fp_addr;
  logic [ FpW-1:0] port0_fp_data;
  logic            port1_fp_we;
  logic [     4:0] port1_fp_addr;
  logic [ FpW-1:0] port1_fp_data;
  assign port0_int_we   = i_port0_int_we;
  assign port0_int_addr = i_port0_int_addr;
  assign port0_int_data = i_port0_int_data;
  assign port1_int_we   = i_port1_int_we;
  assign port1_int_addr = i_port1_int_addr;
  assign port1_int_data = i_port1_int_data;
  assign port0_fp_we    = i_port0_fp_we;
  assign port0_fp_addr  = i_port0_fp_addr;
  assign port0_fp_data  = i_port0_fp_data;
  assign port1_fp_we    = i_port1_fp_we;
  assign port1_fp_addr  = i_port1_fp_addr;
  assign port1_fp_data  = i_port1_fp_data;

  riscv_pkg::from_pd_to_id_t from_pd_to_id, from_pd_to_id_2;
  riscv_pkg::from_id_to_ex_t from_id_to_ex, from_id_to_ex_2;
  assign from_pd_to_id   = i_from_pd_to_id;
  assign from_pd_to_id_2 = i_from_pd_to_id_2;
  assign from_id_to_ex   = i_from_id_to_ex;
  assign from_id_to_ex_2 = i_from_id_to_ex_2;

  // ===========================================================================
  // Register Files (read in ID, write from ROB commit)
  // ===========================================================================

  // Integer register file.  Widen-commit drives the regfile with 2
  // independent write ports: port 0 = slot 1 (rob_commit), port 1 =
  // slot 2 (rob_commit_2).  The mwp_dist_ram LVT steers reads to the
  // highest-numbered port (slot 2) when both ports write the same
  // address — matching program order since slot 2 has tag T+1 > slot 1
  // has tag T.
  localparam int unsigned IntRfWrPorts = 2;
  // 8 INT read ports: slot-1 ID rs1/rs2, slot-1 dispatch rs1/rs2, slot-2 ID
  // rs1/rs2, slot-2 dispatch rs1/rs2.  Session G wires slot-2 dispatch reads
  // through to the RAT's i_int_regfile_data*_2 inputs.
  logic                  [           8*XLEN-1:0] int_rf_read_data;
  logic                  [     IntRfWrPorts-1:0] int_rf_write_enable;
  logic                  [   IntRfWrPorts*5-1:0] int_rf_write_addr;
  logic                  [IntRfWrPorts*XLEN-1:0] int_rf_write_data;
  logic                                          int_rf_wb_bypass_id_rs1;
  logic                                          int_rf_wb_bypass_id_rs2;
  logic                                          int_rf_wb_bypass_dispatch_rs1;
  logic                                          int_rf_wb_bypass_dispatch_rs2;
  logic                                          int_rf_wb_bypass_id_rs1_2;
  logic                                          int_rf_wb_bypass_id_rs2_2;
  logic                                          int_rf_wb_bypass_dispatch_rs1_2;
  logic                                          int_rf_wb_bypass_dispatch_rs2_2;
  logic                  [             XLEN-1:0] int_rf_dispatch_rs1_data;
  logic                  [             XLEN-1:0] int_rf_dispatch_rs2_data;
  logic                  [             XLEN-1:0] int_rf_dispatch_rs1_data_2;
  logic                  [             XLEN-1:0] int_rf_dispatch_rs2_data_2;

  riscv_pkg::rf_to_fwd_t                         rf_to_fwd;
  riscv_pkg::rf_to_fwd_t                         rf_to_fwd_2;

  // Write-port assembly (port 0 = slot 1, port 1 = slot 2).
  assign int_rf_write_enable = {port1_int_we, port0_int_we};
  assign int_rf_write_addr   = {port1_int_addr, port0_int_addr};
  assign int_rf_write_data   = {port1_int_data, port0_int_data};

  generic_regfile #(
      .DATA_WIDTH(XLEN),
      .NUM_READ_PORTS(8),
      .NUM_WRITE_PORTS(IntRfWrPorts),
      .HARDWIRE_ZERO(1)
  ) regfile_inst (
      .i_clk,
      .i_write_enable(int_rf_write_enable),
      .i_write_addr(int_rf_write_addr),
      .i_write_data(int_rf_write_data),
      .i_stall(1'b0),  // OOO: commit writes must not be blocked by front-end stall
      .i_read_addr({
        from_id_to_ex_2.instruction.source_reg_2,
        from_id_to_ex_2.instruction.source_reg_1,
        from_pd_to_id_2.source_reg_2_early,
        from_pd_to_id_2.source_reg_1_early,
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1,
        from_pd_to_id.source_reg_2_early,
        from_pd_to_id.source_reg_1_early
      }),
      .o_read_data(int_rf_read_data)
  );

  // Widen-commit bypass: check both write ports (slot 1 = port 0,
  // slot 2 = port 1).  Priority: port 1 > port 0 (newer tag wins on
  // same-address conflict, matching the regfile LVT priority).
  //
  // Both ports write the regfile at the same edge, so the bypass is a
  // straightforward same-cycle compare and no cross-cycle tracking is
  // needed.
  logic int_hit_id_rs1_p1, int_hit_id_rs1_p0;
  logic int_hit_id_rs2_p1, int_hit_id_rs2_p0;
  logic int_hit_dp_rs1_p1, int_hit_dp_rs1_p0;
  logic int_hit_dp_rs2_p1, int_hit_dp_rs2_p0;

  assign int_hit_id_rs1_p1 = port1_int_we && |port1_int_addr &&
                             (port1_int_addr == from_pd_to_id.source_reg_1_early);
  assign int_hit_id_rs1_p0 = port0_int_we && |port0_int_addr &&
                             (port0_int_addr == from_pd_to_id.source_reg_1_early);

  assign int_hit_id_rs2_p1 = port1_int_we && |port1_int_addr &&
                             (port1_int_addr == from_pd_to_id.source_reg_2_early);
  assign int_hit_id_rs2_p0 = port0_int_we && |port0_int_addr &&
                             (port0_int_addr == from_pd_to_id.source_reg_2_early);

  assign int_hit_dp_rs1_p1 = port1_int_we && |port1_int_addr &&
                             (port1_int_addr == from_id_to_ex.instruction.source_reg_1);
  assign int_hit_dp_rs1_p0 = port0_int_we && |port0_int_addr &&
                             (port0_int_addr == from_id_to_ex.instruction.source_reg_1);

  assign int_hit_dp_rs2_p1 = port1_int_we && |port1_int_addr &&
                             (port1_int_addr == from_id_to_ex.instruction.source_reg_2);
  assign int_hit_dp_rs2_p0 = port0_int_we && |port0_int_addr &&
                             (port0_int_addr == from_id_to_ex.instruction.source_reg_2);

  assign int_rf_wb_bypass_id_rs1 = int_hit_id_rs1_p1 || int_hit_id_rs1_p0;
  assign int_rf_wb_bypass_id_rs2 = int_hit_id_rs2_p1 || int_hit_id_rs2_p0;
  assign int_rf_wb_bypass_dispatch_rs1 = int_hit_dp_rs1_p1 || int_hit_dp_rs1_p0;
  assign int_rf_wb_bypass_dispatch_rs2 = int_hit_dp_rs2_p1 || int_hit_dp_rs2_p0;

  logic [XLEN-1:0] int_bypass_data_id_rs1;
  logic [XLEN-1:0] int_bypass_data_id_rs2;
  logic [XLEN-1:0] int_bypass_data_dp_rs1;
  logic [XLEN-1:0] int_bypass_data_dp_rs2;

  assign int_bypass_data_id_rs1 = int_hit_id_rs1_p1 ? port1_int_data : port0_int_data;
  assign int_bypass_data_id_rs2 = int_hit_id_rs2_p1 ? port1_int_data : port0_int_data;
  assign int_bypass_data_dp_rs1 = int_hit_dp_rs1_p1 ? port1_int_data : port0_int_data;
  assign int_bypass_data_dp_rs2 = int_hit_dp_rs2_p1 ? port1_int_data : port0_int_data;

  assign rf_to_fwd.source_reg_1_data = int_rf_wb_bypass_id_rs1 ? int_bypass_data_id_rs1 :
                                       int_rf_read_data[XLEN-1:0];
  assign rf_to_fwd.source_reg_2_data = int_rf_wb_bypass_id_rs2 ? int_bypass_data_id_rs2 :
                                       int_rf_read_data[2*XLEN-1:XLEN];
  assign int_rf_dispatch_rs1_data    = int_rf_wb_bypass_dispatch_rs1 ? int_bypass_data_dp_rs1 :
                                       int_rf_read_data[3*XLEN-1:2*XLEN];
  assign int_rf_dispatch_rs2_data    = int_rf_wb_bypass_dispatch_rs2 ? int_bypass_data_dp_rs2 :
                                       int_rf_read_data[4*XLEN-1:3*XLEN];

  // Slot-2 ID-stage widen-commit bypass — same structure as slot-1 above.
  logic int_hit_id_rs1_2_p1, int_hit_id_rs1_2_p0;
  logic int_hit_id_rs2_2_p1, int_hit_id_rs2_2_p0;
  logic int_hit_dp_rs1_2_p1, int_hit_dp_rs1_2_p0;
  logic int_hit_dp_rs2_2_p1, int_hit_dp_rs2_2_p0;

  assign int_hit_id_rs1_2_p1 = port1_int_we && |port1_int_addr &&
                               (port1_int_addr == from_pd_to_id_2.source_reg_1_early);
  assign int_hit_id_rs1_2_p0 = port0_int_we && |port0_int_addr &&
                               (port0_int_addr == from_pd_to_id_2.source_reg_1_early);
  assign int_hit_id_rs2_2_p1 = port1_int_we && |port1_int_addr &&
                               (port1_int_addr == from_pd_to_id_2.source_reg_2_early);
  assign int_hit_id_rs2_2_p0 = port0_int_we && |port0_int_addr &&
                               (port0_int_addr == from_pd_to_id_2.source_reg_2_early);

  assign int_hit_dp_rs1_2_p1 = port1_int_we && |port1_int_addr &&
                               (port1_int_addr == from_id_to_ex_2.instruction.source_reg_1);
  assign int_hit_dp_rs1_2_p0 = port0_int_we && |port0_int_addr &&
                               (port0_int_addr == from_id_to_ex_2.instruction.source_reg_1);
  assign int_hit_dp_rs2_2_p1 = port1_int_we && |port1_int_addr &&
                               (port1_int_addr == from_id_to_ex_2.instruction.source_reg_2);
  assign int_hit_dp_rs2_2_p0 = port0_int_we && |port0_int_addr &&
                               (port0_int_addr == from_id_to_ex_2.instruction.source_reg_2);

  assign int_rf_wb_bypass_id_rs1_2 = int_hit_id_rs1_2_p1 || int_hit_id_rs1_2_p0;
  assign int_rf_wb_bypass_id_rs2_2 = int_hit_id_rs2_2_p1 || int_hit_id_rs2_2_p0;
  assign int_rf_wb_bypass_dispatch_rs1_2 = int_hit_dp_rs1_2_p1 || int_hit_dp_rs1_2_p0;
  assign int_rf_wb_bypass_dispatch_rs2_2 = int_hit_dp_rs2_2_p1 || int_hit_dp_rs2_2_p0;

  logic [XLEN-1:0] int_bypass_data_id_rs1_2;
  logic [XLEN-1:0] int_bypass_data_id_rs2_2;
  logic [XLEN-1:0] int_bypass_data_dp_rs1_2;
  logic [XLEN-1:0] int_bypass_data_dp_rs2_2;
  assign int_bypass_data_id_rs1_2 = int_hit_id_rs1_2_p1 ? port1_int_data : port0_int_data;
  assign int_bypass_data_id_rs2_2 = int_hit_id_rs2_2_p1 ? port1_int_data : port0_int_data;
  assign int_bypass_data_dp_rs1_2 = int_hit_dp_rs1_2_p1 ? port1_int_data : port0_int_data;
  assign int_bypass_data_dp_rs2_2 = int_hit_dp_rs2_2_p1 ? port1_int_data : port0_int_data;

  assign rf_to_fwd_2.source_reg_1_data = int_rf_wb_bypass_id_rs1_2 ? int_bypass_data_id_rs1_2 :
                                         int_rf_read_data[5*XLEN-1:4*XLEN];
  assign rf_to_fwd_2.source_reg_2_data = int_rf_wb_bypass_id_rs2_2 ? int_bypass_data_id_rs2_2 :
                                         int_rf_read_data[6*XLEN-1:5*XLEN];
  assign int_rf_dispatch_rs1_data_2 = int_rf_wb_bypass_dispatch_rs1_2 ? int_bypass_data_dp_rs1_2 :
                                      int_rf_read_data[7*XLEN-1:6*XLEN];
  assign int_rf_dispatch_rs2_data_2 = int_rf_wb_bypass_dispatch_rs2_2 ? int_bypass_data_dp_rs2_2 :
                                      int_rf_read_data[8*XLEN-1:7*XLEN];

  // FP register file.  Same 2-write-port topology as the INT regfile for
  // widen-commit.  FpW is declared up near the INT regfile for forward-
  // reference reasons (INT port0_fp_data uses it for sizing).
  localparam int unsigned FpRfWrPorts = 2;
  // 12 FP read ports: slot-1 ID rs1/rs2/rs3, slot-1 dispatch rs1/rs2/rs3,
  // slot-2 ID rs1/rs2/rs3, slot-2 dispatch rs1/rs2/rs3.  Session G wires
  // slot-2 dispatch reads through to the RAT's i_fp_regfile_data*_2.
  logic                     [         12*FpW-1:0] fp_rf_read_data;
  logic                     [    FpRfWrPorts-1:0] fp_rf_write_enable;
  logic                     [  FpRfWrPorts*5-1:0] fp_rf_write_addr;
  logic                     [FpRfWrPorts*FpW-1:0] fp_rf_write_data;
  logic                                           fp_rf_wb_bypass_id_rs1;
  logic                                           fp_rf_wb_bypass_id_rs2;
  logic                                           fp_rf_wb_bypass_id_rs3;
  logic                                           fp_rf_wb_bypass_dispatch_rs1;
  logic                                           fp_rf_wb_bypass_dispatch_rs2;
  logic                                           fp_rf_wb_bypass_dispatch_rs3;
  logic                                           fp_rf_wb_bypass_id_rs1_2;
  logic                                           fp_rf_wb_bypass_id_rs2_2;
  logic                                           fp_rf_wb_bypass_id_rs3_2;
  logic                                           fp_rf_wb_bypass_dispatch_rs1_2;
  logic                                           fp_rf_wb_bypass_dispatch_rs2_2;
  logic                                           fp_rf_wb_bypass_dispatch_rs3_2;
  logic                     [            FpW-1:0] fp_rf_dispatch_rs1_data;
  logic                     [            FpW-1:0] fp_rf_dispatch_rs2_data;
  logic                     [            FpW-1:0] fp_rf_dispatch_rs3_data;
  logic                     [            FpW-1:0] fp_rf_dispatch_rs1_data_2;
  logic                     [            FpW-1:0] fp_rf_dispatch_rs2_data_2;
  logic                     [            FpW-1:0] fp_rf_dispatch_rs3_data_2;

  riscv_pkg::fp_rf_to_fwd_t                       fp_rf_to_fwd;
  riscv_pkg::fp_rf_to_fwd_t                       fp_rf_to_fwd_2;

  assign fp_rf_write_enable = {port1_fp_we, port0_fp_we};
  assign fp_rf_write_addr   = {port1_fp_addr, port0_fp_addr};
  assign fp_rf_write_data   = {port1_fp_data, port0_fp_data};

  generic_regfile #(
      .DATA_WIDTH(FpW),
      .NUM_READ_PORTS(12),
      .NUM_WRITE_PORTS(FpRfWrPorts),
      .HARDWIRE_ZERO(0)
  ) fp_regfile_inst (
      .i_clk,
      .i_write_enable(fp_rf_write_enable),
      .i_write_addr(fp_rf_write_addr),
      .i_write_data(fp_rf_write_data),
      .i_stall(1'b0),  // OOO: commit writes must not be blocked by front-end stall
      .i_read_addr({
        from_id_to_ex_2.instruction.funct7[6:2],
        from_id_to_ex_2.instruction.source_reg_2,
        from_id_to_ex_2.instruction.source_reg_1,
        from_pd_to_id_2.fp_source_reg_3_early,
        from_pd_to_id_2.source_reg_2_early,
        from_pd_to_id_2.source_reg_1_early,
        from_id_to_ex.instruction.funct7[6:2],
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1,
        from_pd_to_id.fp_source_reg_3_early,
        from_pd_to_id.source_reg_2_early,
        from_pd_to_id.source_reg_1_early
      }),
      .o_read_data(fp_rf_read_data)
  );

  // FP widen-commit bypass: parallel 2-port structure to the INT bypass.
  logic fp_hit_id_rs1_p1, fp_hit_id_rs1_p0;
  logic fp_hit_id_rs2_p1, fp_hit_id_rs2_p0;
  logic fp_hit_id_rs3_p1, fp_hit_id_rs3_p0;
  logic fp_hit_dp_rs1_p1, fp_hit_dp_rs1_p0;
  logic fp_hit_dp_rs2_p1, fp_hit_dp_rs2_p0;
  logic fp_hit_dp_rs3_p1, fp_hit_dp_rs3_p0;

  assign fp_hit_id_rs1_p1 = port1_fp_we && (port1_fp_addr == from_pd_to_id.source_reg_1_early);
  assign fp_hit_id_rs1_p0 = port0_fp_we && (port0_fp_addr == from_pd_to_id.source_reg_1_early);
  assign fp_hit_id_rs2_p1 = port1_fp_we && (port1_fp_addr == from_pd_to_id.source_reg_2_early);
  assign fp_hit_id_rs2_p0 = port0_fp_we && (port0_fp_addr == from_pd_to_id.source_reg_2_early);
  assign fp_hit_id_rs3_p1 = port1_fp_we && (port1_fp_addr == from_pd_to_id.fp_source_reg_3_early);
  assign fp_hit_id_rs3_p0 = port0_fp_we && (port0_fp_addr == from_pd_to_id.fp_source_reg_3_early);

  assign fp_hit_dp_rs1_p1 = port1_fp_we && (port1_fp_addr==from_id_to_ex.instruction.source_reg_1);
  assign fp_hit_dp_rs1_p0 = port0_fp_we && (port0_fp_addr==from_id_to_ex.instruction.source_reg_1);
  assign fp_hit_dp_rs2_p1 = port1_fp_we && (port1_fp_addr==from_id_to_ex.instruction.source_reg_2);
  assign fp_hit_dp_rs2_p0 = port0_fp_we && (port0_fp_addr==from_id_to_ex.instruction.source_reg_2);
  assign fp_hit_dp_rs3_p1 = port1_fp_we && (port1_fp_addr == from_id_to_ex.instruction.funct7[6:2]);
  assign fp_hit_dp_rs3_p0 = port0_fp_we && (port0_fp_addr == from_id_to_ex.instruction.funct7[6:2]);

  assign fp_rf_wb_bypass_id_rs1 = fp_hit_id_rs1_p1 || fp_hit_id_rs1_p0;
  assign fp_rf_wb_bypass_id_rs2 = fp_hit_id_rs2_p1 || fp_hit_id_rs2_p0;
  assign fp_rf_wb_bypass_id_rs3 = fp_hit_id_rs3_p1 || fp_hit_id_rs3_p0;
  assign fp_rf_wb_bypass_dispatch_rs1 = fp_hit_dp_rs1_p1 || fp_hit_dp_rs1_p0;
  assign fp_rf_wb_bypass_dispatch_rs2 = fp_hit_dp_rs2_p1 || fp_hit_dp_rs2_p0;
  assign fp_rf_wb_bypass_dispatch_rs3 = fp_hit_dp_rs3_p1 || fp_hit_dp_rs3_p0;

  logic [FpW-1:0] fp_bypass_data_id_rs1, fp_bypass_data_id_rs2, fp_bypass_data_id_rs3;
  logic [FpW-1:0] fp_bypass_data_dp_rs1, fp_bypass_data_dp_rs2, fp_bypass_data_dp_rs3;

  assign fp_bypass_data_id_rs1 = fp_hit_id_rs1_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_id_rs2 = fp_hit_id_rs2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_id_rs3 = fp_hit_id_rs3_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs1 = fp_hit_dp_rs1_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs2 = fp_hit_dp_rs2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs3 = fp_hit_dp_rs3_p1 ? port1_fp_data : port0_fp_data;

  assign fp_rf_to_fwd.fp_source_reg_1_data = fp_rf_wb_bypass_id_rs1 ? fp_bypass_data_id_rs1 :
                                             fp_rf_read_data[FpW-1:0];
  assign fp_rf_to_fwd.fp_source_reg_2_data = fp_rf_wb_bypass_id_rs2 ? fp_bypass_data_id_rs2 :
                                             fp_rf_read_data[2*FpW-1:FpW];
  assign fp_rf_to_fwd.fp_source_reg_3_data = fp_rf_wb_bypass_id_rs3 ? fp_bypass_data_id_rs3 :
                                             fp_rf_read_data[3*FpW-1:2*FpW];
  assign fp_rf_dispatch_rs1_data = fp_rf_wb_bypass_dispatch_rs1 ? fp_bypass_data_dp_rs1 :
                                   fp_rf_read_data[4*FpW-1:3*FpW];
  assign fp_rf_dispatch_rs2_data = fp_rf_wb_bypass_dispatch_rs2 ? fp_bypass_data_dp_rs2 :
                                   fp_rf_read_data[5*FpW-1:4*FpW];
  assign fp_rf_dispatch_rs3_data = fp_rf_wb_bypass_dispatch_rs3 ? fp_bypass_data_dp_rs3 :
                                   fp_rf_read_data[6*FpW-1:5*FpW];

  // Slot-2 ID-stage FP widen-commit bypass — same structure as slot-1 above.
  logic fp_hit_id_rs1_2_p1, fp_hit_id_rs1_2_p0;
  logic fp_hit_id_rs2_2_p1, fp_hit_id_rs2_2_p0;
  logic fp_hit_id_rs3_2_p1, fp_hit_id_rs3_2_p0;
  logic fp_hit_dp_rs1_2_p1, fp_hit_dp_rs1_2_p0;
  logic fp_hit_dp_rs2_2_p1, fp_hit_dp_rs2_2_p0;
  logic fp_hit_dp_rs3_2_p1, fp_hit_dp_rs3_2_p0;

  assign fp_hit_id_rs1_2_p1 = port1_fp_we && (port1_fp_addr == from_pd_to_id_2.source_reg_1_early);
  assign fp_hit_id_rs1_2_p0 = port0_fp_we && (port0_fp_addr == from_pd_to_id_2.source_reg_1_early);
  assign fp_hit_id_rs2_2_p1 = port1_fp_we && (port1_fp_addr == from_pd_to_id_2.source_reg_2_early);
  assign fp_hit_id_rs2_2_p0 = port0_fp_we && (port0_fp_addr == from_pd_to_id_2.source_reg_2_early);
  assign fp_hit_id_rs3_2_p1 = port1_fp_we &&
                              (port1_fp_addr == from_pd_to_id_2.fp_source_reg_3_early);
  assign fp_hit_id_rs3_2_p0 = port0_fp_we &&
                              (port0_fp_addr == from_pd_to_id_2.fp_source_reg_3_early);

  assign fp_hit_dp_rs1_2_p1 = port1_fp_we &&
                              (port1_fp_addr == from_id_to_ex_2.instruction.source_reg_1);
  assign fp_hit_dp_rs1_2_p0 = port0_fp_we &&
                              (port0_fp_addr == from_id_to_ex_2.instruction.source_reg_1);
  assign fp_hit_dp_rs2_2_p1 = port1_fp_we &&
                              (port1_fp_addr == from_id_to_ex_2.instruction.source_reg_2);
  assign fp_hit_dp_rs2_2_p0 = port0_fp_we &&
                              (port0_fp_addr == from_id_to_ex_2.instruction.source_reg_2);
  assign fp_hit_dp_rs3_2_p1 = port1_fp_we &&
                              (port1_fp_addr == from_id_to_ex_2.instruction.funct7[6:2]);
  assign fp_hit_dp_rs3_2_p0 = port0_fp_we &&
                              (port0_fp_addr == from_id_to_ex_2.instruction.funct7[6:2]);

  assign fp_rf_wb_bypass_id_rs1_2 = fp_hit_id_rs1_2_p1 || fp_hit_id_rs1_2_p0;
  assign fp_rf_wb_bypass_id_rs2_2 = fp_hit_id_rs2_2_p1 || fp_hit_id_rs2_2_p0;
  assign fp_rf_wb_bypass_id_rs3_2 = fp_hit_id_rs3_2_p1 || fp_hit_id_rs3_2_p0;
  assign fp_rf_wb_bypass_dispatch_rs1_2 = fp_hit_dp_rs1_2_p1 || fp_hit_dp_rs1_2_p0;
  assign fp_rf_wb_bypass_dispatch_rs2_2 = fp_hit_dp_rs2_2_p1 || fp_hit_dp_rs2_2_p0;
  assign fp_rf_wb_bypass_dispatch_rs3_2 = fp_hit_dp_rs3_2_p1 || fp_hit_dp_rs3_2_p0;

  logic [FpW-1:0] fp_bypass_data_id_rs1_2, fp_bypass_data_id_rs2_2, fp_bypass_data_id_rs3_2;
  logic [FpW-1:0] fp_bypass_data_dp_rs1_2, fp_bypass_data_dp_rs2_2, fp_bypass_data_dp_rs3_2;
  assign fp_bypass_data_id_rs1_2 = fp_hit_id_rs1_2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_id_rs2_2 = fp_hit_id_rs2_2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_id_rs3_2 = fp_hit_id_rs3_2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs1_2 = fp_hit_dp_rs1_2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs2_2 = fp_hit_dp_rs2_2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs3_2 = fp_hit_dp_rs3_2_p1 ? port1_fp_data : port0_fp_data;

  assign fp_rf_to_fwd_2.fp_source_reg_1_data = fp_rf_wb_bypass_id_rs1_2 ?
                                               fp_bypass_data_id_rs1_2 :
                                               fp_rf_read_data[7*FpW-1:6*FpW];
  assign fp_rf_to_fwd_2.fp_source_reg_2_data = fp_rf_wb_bypass_id_rs2_2 ?
                                               fp_bypass_data_id_rs2_2 :
                                               fp_rf_read_data[8*FpW-1:7*FpW];
  assign fp_rf_to_fwd_2.fp_source_reg_3_data = fp_rf_wb_bypass_id_rs3_2 ?
                                               fp_bypass_data_id_rs3_2 :
                                               fp_rf_read_data[9*FpW-1:8*FpW];
  assign fp_rf_dispatch_rs1_data_2 = fp_rf_wb_bypass_dispatch_rs1_2 ? fp_bypass_data_dp_rs1_2 :
                                     fp_rf_read_data[10*FpW-1:9*FpW];
  assign fp_rf_dispatch_rs2_data_2 = fp_rf_wb_bypass_dispatch_rs2_2 ? fp_bypass_data_dp_rs2_2 :
                                     fp_rf_read_data[11*FpW-1:10*FpW];
  assign fp_rf_dispatch_rs3_data_2 = fp_rf_wb_bypass_dispatch_rs3_2 ? fp_bypass_data_dp_rs3_2 :
                                     fp_rf_read_data[12*FpW-1:11*FpW];

  // --- Output wiring.
  assign o_rf_to_fwd = rf_to_fwd;
  assign o_rf_to_fwd_2 = rf_to_fwd_2;
  assign o_int_rf_dispatch_rs1_data = int_rf_dispatch_rs1_data;
  assign o_int_rf_dispatch_rs2_data = int_rf_dispatch_rs2_data;
  assign o_int_rf_dispatch_rs1_data_2 = int_rf_dispatch_rs1_data_2;
  assign o_int_rf_dispatch_rs2_data_2 = int_rf_dispatch_rs2_data_2;
  assign o_fp_rf_to_fwd = fp_rf_to_fwd;
  assign o_fp_rf_to_fwd_2 = fp_rf_to_fwd_2;
  assign o_fp_rf_dispatch_rs1_data = fp_rf_dispatch_rs1_data;
  assign o_fp_rf_dispatch_rs2_data = fp_rf_dispatch_rs2_data;
  assign o_fp_rf_dispatch_rs3_data = fp_rf_dispatch_rs3_data;
  assign o_fp_rf_dispatch_rs1_data_2 = fp_rf_dispatch_rs1_data_2;
  assign o_fp_rf_dispatch_rs2_data_2 = fp_rf_dispatch_rs2_data_2;
  assign o_fp_rf_dispatch_rs3_data_2 = fp_rf_dispatch_rs3_data_2;

endmodule : ooo_register_files

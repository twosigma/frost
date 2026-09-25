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
 * Integer and FP architectural register files, read for dispatch and written
 * at ROB commit, plus the same-cycle bypass that forwards a register being
 * committed on the edge it is read.
 *
 * Both files have two write ports for two-wide commit: port 0 is slot 1
 * (rob_commit), port 1 is slot 2 (rob_commit_2). When both ports write the
 * same address the mwp_dist_ram LVT steers reads to the higher-numbered port.
 * That matches program order, because slot 2 carries tag T+1 and slot 1 tag T.
 * The bypass applies the same priority, port 1 over port 0, on the read
 * ports. Its hit compares start at registered qualifiers rather than at the
 * write ports.
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

    // Pre-registered bypass qualifiers for the write-back bypass network.
    // Each is a single FF computed one cycle early from the ROB's
    // combinational commit, plus the delayed-CSR writeback on port 0, so the
    // wide hit-compare fanout starts at a register instead of riding the
    // commit-valid/flush-mask LUT cone. Relative to the write ports above:
    //   i_bypass_pN_int_we == i_portN_int_we && |i_portN_int_addr
    //   i_bypass_pN_fp_we  == i_portN_fp_we
    //   i_bypass_pN_addr   == the active portN write address
    // Those hold in every cycle but a full flush, where a qualifier may stay
    // asserted for a commit whose architectural write was masked off. That
    // phantom hit only mis-selects operand data for a dispatch that the same
    // full flush squashes, so it is never consumed.
    input logic       i_bypass_p0_int_we,
    input logic       i_bypass_p1_int_we,
    input logic       i_bypass_p0_fp_we,
    input logic       i_bypass_p1_fp_we,
    input logic [4:0] i_bypass_p0_addr,
    input logic [4:0] i_bypass_p1_addr,

    // Read source addresses (slot 1 / slot 2 at dispatch).
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex_2,

    // Resolved (post-bypass) read results.
    output logic [              XLEN-1:0] o_int_rf_dispatch_rs1_data,
    output logic [              XLEN-1:0] o_int_rf_dispatch_rs2_data,
    output logic [              XLEN-1:0] o_int_rf_dispatch_rs1_data_2,
    output logic [              XLEN-1:0] o_int_rf_dispatch_rs2_data_2,
    output logic [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs1_data,
    output logic [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs2_data,
    output logic [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs3_data,
    output logic [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs1_data_2,
    output logic [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs2_data_2,
    output logic [riscv_pkg::FpWidth-1:0] o_fp_rf_dispatch_rs3_data_2
);

  // FP data width (declared first: the port aliases below size FP signals).
  localparam int unsigned FpW = riscv_pkg::FpWidth;

  // --- Port aliases.
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
  logic            bypass_p0_int_we;
  logic            bypass_p1_int_we;
  logic            bypass_p0_fp_we;
  logic            bypass_p1_fp_we;
  logic [     4:0] bypass_p0_addr;
  logic [     4:0] bypass_p1_addr;
  assign bypass_p0_int_we = i_bypass_p0_int_we;
  assign bypass_p1_int_we = i_bypass_p1_int_we;
  assign bypass_p0_fp_we  = i_bypass_p0_fp_we;
  assign bypass_p1_fp_we  = i_bypass_p1_fp_we;
  assign bypass_p0_addr   = i_bypass_p0_addr;
  assign bypass_p1_addr   = i_bypass_p1_addr;
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

  riscv_pkg::from_id_to_ex_t from_id_to_ex, from_id_to_ex_2;
  assign from_id_to_ex   = i_from_id_to_ex;
  assign from_id_to_ex_2 = i_from_id_to_ex_2;

  // ===========================================================================
  // Register Files (read for dispatch, written at ROB commit)
  // ===========================================================================

  // Integer register file; the header covers its two write ports.
  localparam int unsigned IntRfWrPorts = 2;
  // 4 INT read ports: slot-1 dispatch rs1/rs2, slot-2 dispatch rs1/rs2.
  // Slot-2 dispatch reads are wired through to the RAT's
  // i_int_regfile_data*_2 inputs.
  logic [           4*XLEN-1:0] int_rf_read_data;
  logic [     IntRfWrPorts-1:0] int_rf_write_enable;
  logic [   IntRfWrPorts*5-1:0] int_rf_write_addr;
  logic [IntRfWrPorts*XLEN-1:0] int_rf_write_data;
  logic                         int_rf_wb_bypass_dispatch_rs1;
  logic                         int_rf_wb_bypass_dispatch_rs2;
  logic                         int_rf_wb_bypass_dispatch_rs1_2;
  logic                         int_rf_wb_bypass_dispatch_rs2_2;
  logic [             XLEN-1:0] int_rf_dispatch_rs1_data;
  logic [             XLEN-1:0] int_rf_dispatch_rs2_data;
  logic [             XLEN-1:0] int_rf_dispatch_rs1_data_2;
  logic [             XLEN-1:0] int_rf_dispatch_rs2_data_2;

  // Write-port assembly (port 0 = slot 1, port 1 = slot 2).
  assign int_rf_write_enable = {port1_int_we, port0_int_we};
  assign int_rf_write_addr   = {port1_int_addr, port0_int_addr};
  assign int_rf_write_data   = {port1_int_data, port0_int_data};

  generic_regfile #(
      .DATA_WIDTH(XLEN),
      .NUM_READ_PORTS(4),
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
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1
      }),
      .o_read_data(int_rf_read_data)
  );

  // Commit bypass for the slot-1 reads: port 1 wins a same-address hit, as
  // in the register file. Both ports write the register file at the same
  // edge, so this is a same-cycle compare with no cross-cycle tracking.
  logic int_hit_dp_rs1_p1, int_hit_dp_rs1_p0;
  logic int_hit_dp_rs2_p1, int_hit_dp_rs2_p0;

  // Each hit is one 5-bit compare against the registered bypass qualifiers
  // (see the port list), not against the commit-valid logic.
  assign int_hit_dp_rs1_p1 = bypass_p1_int_we &&
                             (bypass_p1_addr == from_id_to_ex.instruction.source_reg_1);
  assign int_hit_dp_rs1_p0 = bypass_p0_int_we &&
                             (bypass_p0_addr == from_id_to_ex.instruction.source_reg_1);

  assign int_hit_dp_rs2_p1 = bypass_p1_int_we &&
                             (bypass_p1_addr == from_id_to_ex.instruction.source_reg_2);
  assign int_hit_dp_rs2_p0 = bypass_p0_int_we &&
                             (bypass_p0_addr == from_id_to_ex.instruction.source_reg_2);

  assign int_rf_wb_bypass_dispatch_rs1 = int_hit_dp_rs1_p1 || int_hit_dp_rs1_p0;
  assign int_rf_wb_bypass_dispatch_rs2 = int_hit_dp_rs2_p1 || int_hit_dp_rs2_p0;

  logic [XLEN-1:0] int_bypass_data_dp_rs1;
  logic [XLEN-1:0] int_bypass_data_dp_rs2;

  assign int_bypass_data_dp_rs1 = int_hit_dp_rs1_p1 ? port1_int_data : port0_int_data;
  assign int_bypass_data_dp_rs2 = int_hit_dp_rs2_p1 ? port1_int_data : port0_int_data;

  assign int_rf_dispatch_rs1_data = int_rf_wb_bypass_dispatch_rs1 ? int_bypass_data_dp_rs1 :
                                    int_rf_read_data[XLEN-1:0];
  assign int_rf_dispatch_rs2_data = int_rf_wb_bypass_dispatch_rs2 ? int_bypass_data_dp_rs2 :
                                    int_rf_read_data[2*XLEN-1:XLEN];

  // Commit bypass for the slot-2 reads: same as slot 1.
  logic int_hit_dp_rs1_2_p1, int_hit_dp_rs1_2_p0;
  logic int_hit_dp_rs2_2_p1, int_hit_dp_rs2_2_p0;

  assign int_hit_dp_rs1_2_p1 = bypass_p1_int_we &&
                               (bypass_p1_addr == from_id_to_ex_2.instruction.source_reg_1);
  assign int_hit_dp_rs1_2_p0 = bypass_p0_int_we &&
                               (bypass_p0_addr == from_id_to_ex_2.instruction.source_reg_1);
  assign int_hit_dp_rs2_2_p1 = bypass_p1_int_we &&
                               (bypass_p1_addr == from_id_to_ex_2.instruction.source_reg_2);
  assign int_hit_dp_rs2_2_p0 = bypass_p0_int_we &&
                               (bypass_p0_addr == from_id_to_ex_2.instruction.source_reg_2);

  assign int_rf_wb_bypass_dispatch_rs1_2 = int_hit_dp_rs1_2_p1 || int_hit_dp_rs1_2_p0;
  assign int_rf_wb_bypass_dispatch_rs2_2 = int_hit_dp_rs2_2_p1 || int_hit_dp_rs2_2_p0;

  logic [XLEN-1:0] int_bypass_data_dp_rs1_2;
  logic [XLEN-1:0] int_bypass_data_dp_rs2_2;
  assign int_bypass_data_dp_rs1_2 = int_hit_dp_rs1_2_p1 ? port1_int_data : port0_int_data;
  assign int_bypass_data_dp_rs2_2 = int_hit_dp_rs2_2_p1 ? port1_int_data : port0_int_data;

  assign int_rf_dispatch_rs1_data_2 = int_rf_wb_bypass_dispatch_rs1_2 ? int_bypass_data_dp_rs1_2 :
                                      int_rf_read_data[3*XLEN-1:2*XLEN];
  assign int_rf_dispatch_rs2_data_2 = int_rf_wb_bypass_dispatch_rs2_2 ? int_bypass_data_dp_rs2_2 :
                                      int_rf_read_data[4*XLEN-1:3*XLEN];

  // FP register file, with the same two write ports as the integer file.
  localparam int unsigned FpRfWrPorts = 2;
  // 6 FP read ports: slot-1 dispatch rs1/rs2/rs3, slot-2 dispatch
  // rs1/rs2/rs3. Slot-2 dispatch reads are wired through to the RAT's
  // i_fp_regfile_data*_2.
  logic [          6*FpW-1:0] fp_rf_read_data;
  logic [    FpRfWrPorts-1:0] fp_rf_write_enable;
  logic [  FpRfWrPorts*5-1:0] fp_rf_write_addr;
  logic [FpRfWrPorts*FpW-1:0] fp_rf_write_data;
  logic                       fp_rf_wb_bypass_dispatch_rs1;
  logic                       fp_rf_wb_bypass_dispatch_rs2;
  logic                       fp_rf_wb_bypass_dispatch_rs3;
  logic                       fp_rf_wb_bypass_dispatch_rs1_2;
  logic                       fp_rf_wb_bypass_dispatch_rs2_2;
  logic                       fp_rf_wb_bypass_dispatch_rs3_2;
  logic [            FpW-1:0] fp_rf_dispatch_rs1_data;
  logic [            FpW-1:0] fp_rf_dispatch_rs2_data;
  logic [            FpW-1:0] fp_rf_dispatch_rs3_data;
  logic [            FpW-1:0] fp_rf_dispatch_rs1_data_2;
  logic [            FpW-1:0] fp_rf_dispatch_rs2_data_2;
  logic [            FpW-1:0] fp_rf_dispatch_rs3_data_2;

  assign fp_rf_write_enable = {port1_fp_we, port0_fp_we};
  assign fp_rf_write_addr   = {port1_fp_addr, port0_fp_addr};
  assign fp_rf_write_data   = {port1_fp_data, port0_fp_data};

  generic_regfile #(
      .DATA_WIDTH(FpW),
      .NUM_READ_PORTS(6),
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
        from_id_to_ex.instruction.funct7[6:2],
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1
      }),
      .o_read_data(fp_rf_read_data)
  );

  // FP commit bypass for the slot-1 reads: same structure as the integer one.
  logic fp_hit_dp_rs1_p1, fp_hit_dp_rs1_p0;
  logic fp_hit_dp_rs2_p1, fp_hit_dp_rs2_p0;
  logic fp_hit_dp_rs3_p1, fp_hit_dp_rs3_p0;

  assign fp_hit_dp_rs1_p1 = bypass_p1_fp_we &&
                            (bypass_p1_addr == from_id_to_ex.instruction.source_reg_1);
  assign fp_hit_dp_rs1_p0 = bypass_p0_fp_we &&
                            (bypass_p0_addr == from_id_to_ex.instruction.source_reg_1);
  assign fp_hit_dp_rs2_p1 = bypass_p1_fp_we &&
                            (bypass_p1_addr == from_id_to_ex.instruction.source_reg_2);
  assign fp_hit_dp_rs2_p0 = bypass_p0_fp_we &&
                            (bypass_p0_addr == from_id_to_ex.instruction.source_reg_2);
  assign fp_hit_dp_rs3_p1 = bypass_p1_fp_we &&
                            (bypass_p1_addr == from_id_to_ex.instruction.funct7[6:2]);
  assign fp_hit_dp_rs3_p0 = bypass_p0_fp_we &&
                            (bypass_p0_addr == from_id_to_ex.instruction.funct7[6:2]);

  assign fp_rf_wb_bypass_dispatch_rs1 = fp_hit_dp_rs1_p1 || fp_hit_dp_rs1_p0;
  assign fp_rf_wb_bypass_dispatch_rs2 = fp_hit_dp_rs2_p1 || fp_hit_dp_rs2_p0;
  assign fp_rf_wb_bypass_dispatch_rs3 = fp_hit_dp_rs3_p1 || fp_hit_dp_rs3_p0;

  logic [FpW-1:0] fp_bypass_data_dp_rs1, fp_bypass_data_dp_rs2, fp_bypass_data_dp_rs3;

  assign fp_bypass_data_dp_rs1 = fp_hit_dp_rs1_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs2 = fp_hit_dp_rs2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs3 = fp_hit_dp_rs3_p1 ? port1_fp_data : port0_fp_data;

  assign fp_rf_dispatch_rs1_data = fp_rf_wb_bypass_dispatch_rs1 ? fp_bypass_data_dp_rs1 :
                                   fp_rf_read_data[FpW-1:0];
  assign fp_rf_dispatch_rs2_data = fp_rf_wb_bypass_dispatch_rs2 ? fp_bypass_data_dp_rs2 :
                                   fp_rf_read_data[2*FpW-1:FpW];
  assign fp_rf_dispatch_rs3_data = fp_rf_wb_bypass_dispatch_rs3 ? fp_bypass_data_dp_rs3 :
                                   fp_rf_read_data[3*FpW-1:2*FpW];

  // FP commit bypass for the slot-2 reads: same as slot 1.
  logic fp_hit_dp_rs1_2_p1, fp_hit_dp_rs1_2_p0;
  logic fp_hit_dp_rs2_2_p1, fp_hit_dp_rs2_2_p0;
  logic fp_hit_dp_rs3_2_p1, fp_hit_dp_rs3_2_p0;

  assign fp_hit_dp_rs1_2_p1 = bypass_p1_fp_we &&
                              (bypass_p1_addr == from_id_to_ex_2.instruction.source_reg_1);
  assign fp_hit_dp_rs1_2_p0 = bypass_p0_fp_we &&
                              (bypass_p0_addr == from_id_to_ex_2.instruction.source_reg_1);
  assign fp_hit_dp_rs2_2_p1 = bypass_p1_fp_we &&
                              (bypass_p1_addr == from_id_to_ex_2.instruction.source_reg_2);
  assign fp_hit_dp_rs2_2_p0 = bypass_p0_fp_we &&
                              (bypass_p0_addr == from_id_to_ex_2.instruction.source_reg_2);
  assign fp_hit_dp_rs3_2_p1 = bypass_p1_fp_we &&
                              (bypass_p1_addr == from_id_to_ex_2.instruction.funct7[6:2]);
  assign fp_hit_dp_rs3_2_p0 = bypass_p0_fp_we &&
                              (bypass_p0_addr == from_id_to_ex_2.instruction.funct7[6:2]);

  assign fp_rf_wb_bypass_dispatch_rs1_2 = fp_hit_dp_rs1_2_p1 || fp_hit_dp_rs1_2_p0;
  assign fp_rf_wb_bypass_dispatch_rs2_2 = fp_hit_dp_rs2_2_p1 || fp_hit_dp_rs2_2_p0;
  assign fp_rf_wb_bypass_dispatch_rs3_2 = fp_hit_dp_rs3_2_p1 || fp_hit_dp_rs3_2_p0;

  logic [FpW-1:0] fp_bypass_data_dp_rs1_2, fp_bypass_data_dp_rs2_2, fp_bypass_data_dp_rs3_2;
  assign fp_bypass_data_dp_rs1_2 = fp_hit_dp_rs1_2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs2_2 = fp_hit_dp_rs2_2_p1 ? port1_fp_data : port0_fp_data;
  assign fp_bypass_data_dp_rs3_2 = fp_hit_dp_rs3_2_p1 ? port1_fp_data : port0_fp_data;

  assign fp_rf_dispatch_rs1_data_2 = fp_rf_wb_bypass_dispatch_rs1_2 ? fp_bypass_data_dp_rs1_2 :
                                     fp_rf_read_data[4*FpW-1:3*FpW];
  assign fp_rf_dispatch_rs2_data_2 = fp_rf_wb_bypass_dispatch_rs2_2 ? fp_bypass_data_dp_rs2_2 :
                                     fp_rf_read_data[5*FpW-1:4*FpW];
  assign fp_rf_dispatch_rs3_data_2 = fp_rf_wb_bypass_dispatch_rs3_2 ? fp_bypass_data_dp_rs3_2 :
                                     fp_rf_read_data[6*FpW-1:5*FpW];

  // --- Output wiring.
  assign o_int_rf_dispatch_rs1_data = int_rf_dispatch_rs1_data;
  assign o_int_rf_dispatch_rs2_data = int_rf_dispatch_rs2_data;
  assign o_int_rf_dispatch_rs1_data_2 = int_rf_dispatch_rs1_data_2;
  assign o_int_rf_dispatch_rs2_data_2 = int_rf_dispatch_rs2_data_2;
  assign o_fp_rf_dispatch_rs1_data = fp_rf_dispatch_rs1_data;
  assign o_fp_rf_dispatch_rs2_data = fp_rf_dispatch_rs2_data;
  assign o_fp_rf_dispatch_rs3_data = fp_rf_dispatch_rs3_data;
  assign o_fp_rf_dispatch_rs1_data_2 = fp_rf_dispatch_rs1_data_2;
  assign o_fp_rf_dispatch_rs2_data_2 = fp_rf_dispatch_rs2_data_2;
  assign o_fp_rf_dispatch_rs3_data_2 = fp_rf_dispatch_rs3_data_2;

endmodule : ooo_register_files

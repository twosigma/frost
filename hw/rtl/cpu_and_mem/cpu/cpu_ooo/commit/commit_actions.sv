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
 * Commit-time actions.
 *
 * Turns ROB commit into the architectural side effects:
 *   - widen-commit regfile writes on two ports (port 0 = slot 1 = rob_commit,
 *     port 1 = slot 2 = rob_commit_2), routed to the INT or FP file by dest_rf;
 *   - the delayed CSR writeback (csr_read_data, one cycle after the CSR commits)
 *     which takes priority on port 0 and keeps the commit CSR address off the
 *     same-cycle regfile-forwarding path;
 *   - the csr_commit_fire / csr_wb_pending serialization handshakes;
 *   - the retire valid (o_vld / o_pc_vld) and the 1-or-2 instret increment.
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Commit-Time Actions" section, with the parent's signals presented as
 * ports and aliased back to their original names.
 */

module commit_actions #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input logic i_rst,

    input riscv_pkg::reorder_buffer_commit_t            i_rob_commit,
    input riscv_pkg::reorder_buffer_commit_t            i_rob_commit_2,
    input logic                                         i_rob_commit_valid,
    input logic                              [XLEN-1:0] i_csr_read_data,
    input logic                                         i_trap_taken,

    // Regfile write ports (port 0 = slot 1 + delayed CSR, port 1 = slot 2).
    output logic                          o_port0_int_we,
    output logic [                   4:0] o_port0_int_addr,
    output logic [              XLEN-1:0] o_port0_int_data,
    output logic                          o_port0_fp_we,
    output logic [                   4:0] o_port0_fp_addr,
    output logic [riscv_pkg::FpWidth-1:0] o_port0_fp_data,
    output logic                          o_port1_int_we,
    output logic [                   4:0] o_port1_int_addr,
    output logic [              XLEN-1:0] o_port1_int_data,
    output logic                          o_port1_fp_we,
    output logic [                   4:0] o_port1_fp_addr,
    output logic [riscv_pkg::FpWidth-1:0] o_port1_fp_data,

    // CSR serialization handshakes + retire status.
    output logic       o_csr_commit_fire,
    output logic       o_csr_wb_pending,
    output logic       o_vld,
    output logic       o_pc_vld,
    output logic [1:0] o_instruction_retired_count
);

  localparam int unsigned FpW = riscv_pkg::FpWidth;

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  riscv_pkg::reorder_buffer_commit_t            rob_commit;
  riscv_pkg::reorder_buffer_commit_t            rob_commit_2;
  logic                                         rob_commit_valid;
  logic                              [XLEN-1:0] csr_read_data;
  logic                                         trap_taken;
  assign rob_commit       = i_rob_commit;
  assign rob_commit_2     = i_rob_commit_2;
  assign rob_commit_valid = i_rob_commit_valid;
  assign csr_read_data    = i_csr_read_data;
  assign trap_taken       = i_trap_taken;

  logic            csr_commit_fire;
  logic            csr_wb_pending;
  logic [     4:0] csr_wb_dest_reg;

  // --- Regfile writes from ROB commit ---
  // Widen-commit drives two independent write ports per regfile:
  //   port 0 = rob_commit (slot 1)
  //   port 1 = rob_commit_2 (slot 2)
  // Both retire in the same cycle when commit_2_fire fired.  The
  // mwp_dist_ram LVT steers reads to port 1 when both ports write the
  // same address — matching program order since slot 2 has the newer tag.
  //
  // CSR instructions use a delayed writeback from csr_read_data, the CSR
  // file's registered read result.  That removes the commit CSR address
  // from the same-cycle regfile-forwarding/dispatch source-value path.
  logic            port0_int_we;
  logic [     4:0] port0_int_addr;
  logic [XLEN-1:0] port0_int_data;
  logic            port0_fp_we;
  logic [     4:0] port0_fp_addr;
  logic [ FpW-1:0] port0_fp_data;
  logic            port1_int_we;
  logic [     4:0] port1_int_addr;
  logic [XLEN-1:0] port1_int_data;
  logic            port1_fp_we;
  logic [     4:0] port1_fp_addr;
  logic [ FpW-1:0] port1_fp_data;

  assign csr_commit_fire = rob_commit.valid && rob_commit.is_csr && !rob_commit.exception;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      csr_wb_pending  <= 1'b0;
      csr_wb_dest_reg <= '0;
    end else begin
      csr_wb_pending <= csr_commit_fire && rob_commit.dest_valid;
      if (csr_commit_fire && rob_commit.dest_valid) begin
        csr_wb_dest_reg <= rob_commit.dest_reg;
      end
    end
  end

  always_comb begin
    port0_int_we   = 1'b0;
    port0_int_addr = '0;
    port0_int_data = '0;
    port0_fp_we    = 1'b0;
    port0_fp_addr  = '0;
    port0_fp_data  = '0;

    if (csr_wb_pending) begin
      port0_int_we   = 1'b1;
      port0_int_addr = csr_wb_dest_reg;
      port0_int_data = csr_read_data;
    end else if (rob_commit_valid && rob_commit.dest_valid && !rob_commit.exception &&
                 !rob_commit.is_csr) begin
      if (rob_commit.dest_rf == 1'b0) begin
        port0_int_we   = 1'b1;
        port0_int_addr = rob_commit.dest_reg;
        port0_int_data = rob_commit.value[XLEN-1:0];
      end else begin
        port0_fp_we   = 1'b1;
        port0_fp_addr = rob_commit.dest_reg;
        port0_fp_data = rob_commit.value;
      end
    end
  end

  always_comb begin
    port1_int_we   = 1'b0;
    port1_int_addr = '0;
    port1_int_data = '0;
    port1_fp_we    = 1'b0;
    port1_fp_addr  = '0;
    port1_fp_data  = '0;

    // Slot 2 can never take an exception, be a CSR, or be serial (all
    // excluded by the ROB hazard gate).  Only the INT/FP dest case applies.
    if (rob_commit_2.valid && rob_commit_2.dest_valid) begin
      if (rob_commit_2.dest_rf == 1'b0) begin
        port1_int_we   = 1'b1;
        port1_int_addr = rob_commit_2.dest_reg;
        port1_int_data = rob_commit_2.value[XLEN-1:0];
      end else begin
        port1_fp_we   = 1'b1;
        port1_fp_addr = rob_commit_2.dest_reg;
        port1_fp_data = rob_commit_2.value;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst && csr_wb_pending) begin
      assert (!rob_commit.valid && !rob_commit_2.valid)
      else $error("CSR delayed writeback overlapped a commit write port");
    end
  end
`endif

  // --- Instruction retire signal ---
  assign o_vld = rob_commit_valid && !rob_commit.exception;

  // Instret increments 1 or 2 per cycle based on widen-commit retirement.
  // Slot 2 can never take an exception (the 2-wide gate excludes them),
  // so its retire condition is simply "slot 2 valid".
  logic [1:0] instruction_retired_count;
  always_comb begin
    instruction_retired_count = 2'd0;
    if (rob_commit_valid && !rob_commit.exception && !trap_taken) begin
      instruction_retired_count = 2'd1;
      if (rob_commit_2.valid) begin
        instruction_retired_count = 2'd2;
      end
    end
  end

  // --- PC validity ---
  assign o_pc_vld = o_vld;

  // --- Output wiring.
  assign o_port0_int_we = port0_int_we;
  assign o_port0_int_addr = port0_int_addr;
  assign o_port0_int_data = port0_int_data;
  assign o_port0_fp_we = port0_fp_we;
  assign o_port0_fp_addr = port0_fp_addr;
  assign o_port0_fp_data = port0_fp_data;
  assign o_port1_int_we = port1_int_we;
  assign o_port1_int_addr = port1_int_addr;
  assign o_port1_int_data = port1_int_data;
  assign o_port1_fp_we = port1_fp_we;
  assign o_port1_fp_addr = port1_fp_addr;
  assign o_port1_fp_data = port1_fp_data;
  assign o_csr_commit_fire = csr_commit_fire;
  assign o_csr_wb_pending = csr_wb_pending;
  assign o_instruction_retired_count = instruction_retired_count;

endmodule : commit_actions

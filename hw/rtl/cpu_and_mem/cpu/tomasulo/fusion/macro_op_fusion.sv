/*
 * Conservative macro-op fusion candidate detector.
 *
 * This module intentionally does NOT alter architectural execution yet. It
 * recognizes only generic RV64 pairs whose data-flow relationship is explicit
 * and whose fusion can later be implemented without benchmark-specific rules.
 * Keeping detection separate from execution gives verification a stable
 * candidate contract before changing ROB/minstret/precise-trap semantics.
 *
 * Recognized pairs:
 *   LUI   rd, imm20       + ADDI  rd, rd, imm12
 *   AUIPC rd, imm20       + JALR  rd2, rd, imm12
 *   LUI   rd, imm20       + JALR  rd2, rd, imm12
 *
 * The JALR forms are marked only when the second instruction consumes the
 * first result. The LUI+ADDI form is marked only when both instructions write
 * the same integer register. x0 is excluded because it creates no useful
 * architectural producer.
 */
module macro_op_fusion #(
    parameter bit ENABLE = 1'b0
) (
    input  logic                  i_valid_1,
    input  logic                  i_valid_2,
    input  riscv_pkg::instr_op_e  i_op_1,
    input  riscv_pkg::instr_op_e  i_op_2,
    input  logic [4:0]            i_rd_1,
    input  logic [4:0]            i_rs1_2,
    input  logic [4:0]            i_rd_2,
    output logic                  o_candidate,
    output logic [1:0]            o_kind
);

  localparam logic [1:0] FUSE_NONE     = 2'd0;
  localparam logic [1:0] FUSE_LUI_ADDI = 2'd1;
  localparam logic [1:0] FUSE_AUIPC_JALR = 2'd2;
  localparam logic [1:0] FUSE_LUI_JALR = 2'd3;

  always_comb begin
    o_candidate = 1'b0;
    o_kind      = FUSE_NONE;

    if (ENABLE && i_valid_1 && i_valid_2 && (i_rd_1 != 5'd0)) begin
      if ((i_op_1 == riscv_pkg::LUI) &&
          (i_op_2 == riscv_pkg::ADDI) &&
          (i_rs1_2 == i_rd_1) && (i_rd_2 == i_rd_1)) begin
        o_candidate = 1'b1;
        o_kind      = FUSE_LUI_ADDI;
      end else if ((i_op_2 == riscv_pkg::JALR) &&
                   (i_rs1_2 == i_rd_1) &&
                   ((i_op_1 == riscv_pkg::AUIPC) ||
                    (i_op_1 == riscv_pkg::LUI))) begin
        o_candidate = 1'b1;
        o_kind      = (i_op_1 == riscv_pkg::AUIPC) ?
                      FUSE_AUIPC_JALR : FUSE_LUI_JALR;
      end
    end
  end

`ifndef SYNTHESIS
  // Candidate classification must never claim a pair without the explicit
  // producer/consumer dependency. These assertions are deliberately local so
  // the detector can be formally proven independently of the OOO backend.
  always_comb begin
    if (o_candidate) begin
      assert (i_valid_1 && i_valid_2);
      assert (i_rd_1 != 5'd0);
      assert (i_rs1_2 == i_rd_1);
      assert ((o_kind == FUSE_LUI_ADDI) ||
              (o_kind == FUSE_AUIPC_JALR) ||
              (o_kind == FUSE_LUI_JALR));
    end
  end
`endif
endmodule

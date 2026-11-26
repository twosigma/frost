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

// Serial committed floating-point execution. Read addresses, element
// extraction, arithmetic and writes are registered. Setting VRF_REG_DATA=1
// accommodates an extra VRF output register stage in vec_engine. Unordered sum
// reductions use the permitted ordered evaluation; inactive elements
// contribute no exception flags. The flags of an instruction's active elements
// leave in one registered pulse after its last element, sent only if one is
// set, and o_idle stays low until that pulse has left.
module vec_fp_exec #(
    parameter int unsigned VLEN = 256,
    parameter bit VRF_REG_DATA = 1'b0,
    localparam int unsigned Bytes = VLEN / 8,
    localparam int unsigned ByteBits = $clog2(Bytes),
    localparam int unsigned MaskBits = $clog2(VLEN)
) (
    input logic i_clk,
    i_rst,
    i_valid,
    input logic [31:0] i_insn,
    input logic [1:0] i_sew,
    input logic [15:0] i_vl,
    i_vstart,
    input logic [63:0] i_scalar,
    input logic [2:0] i_frm,
    output logic o_idle,
    output logic o_flags_valid,
    output logic [4:0] o_flags,
    output logic [3:0][4:0] o_raddr,
    input logic [3:0][VLEN-1:0] i_rdata,
    output logic o_we,
    output logic [4:0] o_waddr,
    output logic [VLEN-1:0] o_wdata,
    output logic [Bytes-1:0] o_wbe
);
  typedef enum logic [3:0] {
    IDLE,
    PRE,
    PRE2,
    SNAP,
    ADDRESS,
    READ,
    READ2,
    CAPTURE,
    EXTRACT,
    OPERANDS,
    LAUNCH,
    WAIT_RESULT,
    FORMAT,
    WRITE,
    ADVANCE
  } state_e;
  state_e state;
  logic [31:0] insn_q;
  logic [1:0] sew_q;
  logic [2:0] rm_q;
  logic [15:0] vl_q, idx_q, limit_q, source_idx_q;
  logic [63:0] scalar_q, a_q, b_q, c_q, acc_q, result_q;
  logic [VLEN-1:0] mask_q;
  logic [2:0][VLEN-1:0] regs_q;
  logic [3:0][4:0] raddr_q;
  logic active_q, write_q;
  logic [4:0] flags_q, acc_flags_q;
  logic [5:0] f6;
  logic [4:0] vd, vs1, vs2;
  logic scalar_form, reduce_op, wide, conversion, narrowing, mask_dest;
  logic scalar_move, merge_op, slide_op;
  logic [1:0] aw, bw, dw;
  logic [15:0] next_source_idx, abyte, abyte_addr, bbyte, dbyte;
  assign f6 = insn_q[31:26];
  assign vd = insn_q[11:7];
  assign vs1 = insn_q[19:15];
  assign vs2 = insn_q[24:20];
  assign scalar_form = insn_q[14:12] == 5;
  assign reduce_op = !scalar_form &&
      (f6 == 1 || f6 == 3 || f6 == 5 || f6 == 7 || f6 == 6'h31 || f6 == 6'h33);
  assign conversion = f6 == 6'h12;
  assign wide = f6 >= 6'h30 || (conversion && vs1[4:3] == 1);
  assign narrowing = conversion && vs1[4:3] == 2;
  assign mask_dest = f6 >= 6'h18 && f6 <= 6'h1f;
  assign scalar_move = f6 == 6'h10;
  assign merge_op = f6 == 6'h17;
  assign slide_op = f6 == 6'h0e || f6 == 6'h0f;
  assign aw = sew_q + 2'(narrowing || f6 == 6'h34 || f6 == 6'h36);
  assign dw = sew_q + 2'(wide);
  assign bw = reduce_op ? dw : sew_q;
  assign next_source_idx = slide_op ? (f6[0] ? idx_q + 16'd1 : idx_q - 16'd1) : idx_q;
  assign abyte = source_idx_q << aw;
  assign abyte_addr = next_source_idx << aw;
  assign bbyte = (reduce_op ? 16'd0 : idx_q) << bw;
  assign dbyte = (reduce_op ? 16'd0 : idx_q) << dw;
  assign o_raddr = raddr_q;

  function automatic logic [63:0] cut(input logic [63:0] x, input logic [1:0] w);
    case (w)
      0: cut = 64'(x[7:0]);
      1: cut = 64'(x[15:0]);
      2: cut = 64'(x[31:0]);
      default: cut = x;
    endcase
  endfunction
  function automatic logic [63:0] unbox(input logic [63:0] x, input logic [1:0] w);
    case (w)
      1: unbox = x[63:16] == '1 ? 64'(x[15:0]) : 64'h7e00;
      2: unbox = x[63:32] == '1 ? 64'(x[31:0]) : 64'h7fc00000;
      default: unbox = x;
    endcase
  endfunction

  logic [2:0] lane_kind, lane_rm;
  logic [3:0] lane_op;
  logic [1:0] lane_aw, lane_bw;
  logic lane_signed, lane_neg_prod, lane_neg_add;
  logic [63:0] lane_a, lane_b, lane_c;
  logic lane_valid;
  logic [63:0] lane_result;
  logic [4:0] lane_flags;
  always_comb begin
    lane_kind = 0;
    lane_op = 0;
    lane_rm = rm_q;
    lane_aw = aw;
    lane_bw = bw;
    lane_signed = vs1[0];
    lane_neg_prod = 1'b0;
    lane_neg_add = 1'b0;
    lane_a = a_q;
    lane_b = reduce_op ? acc_q : b_q;
    lane_c = c_q;
    if (conversion) begin
      lane_kind = vs1[2] && !vs1[1] ? 3'd5 : vs1[1] && !vs1[2] ? 3'd4 : 3'd3;
      if (vs1[2:1] == 3) lane_rm = 1;
      if (vs1 == 21) lane_rm = 5;
    end else if (f6 == 6'h13) begin
      if (vs1 == 0) begin
        lane_kind = 2;
        lane_op   = 1;
      end else if (vs1 == 16) begin
        lane_kind = 1;
        lane_op   = 8;
      end else begin
        lane_kind = 6;
        lane_op   = vs1 == 4 ? 4'd1 : 4'd0;
      end
    end else if (mask_dest) begin
      lane_kind = 1;
      case (f6)
        6'h18, 6'h1c: lane_op = 0;
        6'h1b, 6'h1d: lane_op = 1;
        default: lane_op = 2;
      endcase
      if (f6 == 6'h1d || f6 == 6'h1f) begin
        lane_a = b_q;
        lane_b = a_q;
      end
    end else if (f6 == 4 || f6 == 5 || f6 == 6 || f6 == 7) begin
      lane_kind = 1;
      lane_op   = f6[1] ? 4'd4 : 4'd3;
    end else if (f6 == 8 || f6 == 9 || f6 == 10) begin
      lane_kind = 1;
      lane_op   = 4'd5 + {2'b0, f6[1:0]};
    end else if (f6 == 6'h20 || f6 == 6'h21) begin
      lane_kind = 2;
      if (f6[0]) begin
        lane_a = b_q;
        lane_b = a_q;
      end
    end else if ((f6 >= 6'h28 && f6 <= 6'h2f) || f6 >= 6'h3c) begin
      lane_neg_prod = f6[0];
      lane_neg_add  = f6[0] ^ f6[1];
      if (!f6[2]) begin
        lane_a = c_q;
        lane_c = a_q;
      end
    end else if (f6 == 6'h24 || f6 == 6'h38) lane_op = 1;
    else begin
      lane_op = 2;
      lane_neg_add = f6 == 2 || f6 == 6'h27 || f6 == 6'h32 || f6 == 6'h36;
      if (f6 == 6'h27) begin
        lane_a = b_q;
        lane_b = a_q;
      end
    end
  end
  vec_fp_lane u_lane (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && !scalar_move && !merge_op && !slide_op),
      .i_kind(lane_kind),
      .i_op(lane_op),
      .i_aw(lane_aw),
      .i_bw(lane_bw),
      .i_dw(dw),
      .i_rm(lane_rm),
      .i_signed(lane_signed),
      .i_neg_prod(lane_neg_prod),
      .i_neg_add(lane_neg_add),
      .i_a(lane_a),
      .i_b(lane_b),
      .i_c(lane_c),
      .o_ready(),
      .o_valid(lane_valid),
      .o_result(lane_result),
      .o_flags(lane_flags)
  );
  assign o_idle = (state == IDLE) && !o_flags_valid;
  assign o_we   = state == WRITE && write_q;

  // Control state machine (reset-bearing flops only).
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      o_flags_valid <= 1'b0;
    end else begin
      o_flags_valid <= 1'b0;
      case (state)
        IDLE: if (i_valid) state <= PRE;
        PRE: state <= VRF_REG_DATA ? PRE2 : SNAP;
        PRE2: state <= SNAP;
        SNAP: state <= ADDRESS;
        ADDRESS: begin
          if (idx_q >= limit_q) begin
            o_flags_valid <= |acc_flags_q;
            state <= IDLE;
          end else state <= READ;
        end
        READ: state <= VRF_REG_DATA ? READ2 : CAPTURE;
        READ2: state <= CAPTURE;
        CAPTURE: state <= EXTRACT;
        EXTRACT: state <= OPERANDS;
        OPERANDS: state <= LAUNCH;
        LAUNCH: state <= (scalar_move || merge_op || slide_op) ? FORMAT : WAIT_RESULT;
        WAIT_RESULT: if (lane_valid) state <= FORMAT;
        FORMAT: state <= WRITE;
        WRITE: state <= ADVANCE;
        ADVANCE: state <= ADDRESS;
        default: state <= IDLE;
      endcase
    end
  end

  // Reset-free datapath registers (no i_rst fanout on wide datapath flops).
  always_ff @(posedge i_clk) begin
    case (state)
      IDLE:
      if (i_valid) begin
        insn_q <= i_insn;
        sew_q <= i_sew;
        rm_q <= i_frm;
        vl_q <= i_vl;
        idx_q <= i_vstart;
        limit_q <= i_vl;
        scalar_q <= i_scalar;
        acc_flags_q <= '0;
        raddr_q[0] <= i_insn[24:20];
        raddr_q[1] <= i_insn[19:15];
        raddr_q[2] <= i_insn[11:7];
        raddr_q[3] <= 5'd0;
      end
      SNAP: begin
        mask_q <= i_rdata[3];
        if (scalar_move) begin
          limit_q <= idx_q < vl_q ? 16'd1 : 16'd0;
          idx_q   <= 0;
        end
      end
      ADDRESS: begin
        source_idx_q <= next_source_idx;
        raddr_q[0]   <= vs2 + 5'(abyte_addr >> ByteBits);
        raddr_q[1]   <= vs1 + 5'(bbyte >> ByteBits);
        raddr_q[2]   <= mask_dest ? vd : (vd + 5'(dbyte >> ByteBits));
        raddr_q[3]   <= 5'd0;
        if (idx_q >= limit_q) o_flags <= acc_flags_q;
      end
      CAPTURE: regs_q <= i_rdata[2:0];
      EXTRACT: begin
        a_q <= cut(64'(regs_q[0] >> (8 * int'(abyte[ByteBits-1:0]))), aw);
        b_q <= scalar_form ? unbox(
            scalar_q, sew_q
        ) : cut(
            64'(regs_q[1] >> (8 * int'(bbyte[ByteBits-1:0]))), bw
        );
        c_q <= cut(64'(regs_q[2] >> (8 * int'(dbyte[ByteBits-1:0]))), dw);
        if (reduce_op && idx_q == 0) acc_q <= cut(64'(regs_q[1]), dw);
        active_q <= scalar_move || merge_op || insn_q[25] || mask_q[MaskBits'(idx_q)];
        flags_q <= '0;
      end
      OPERANDS: write_q <= reduce_op ? idx_q + 1 == limit_q : active_q;
      LAUNCH: begin
        if (scalar_move || merge_op || slide_op) begin
          result_q <= a_q;
          if (scalar_move || (merge_op && (insn_q[25] || mask_q[MaskBits'(idx_q)])) ||
              (slide_op && ((!f6[0] && idx_q == 0) || (f6[0] && idx_q+1 == vl_q))))
            result_q <= b_q;
        end
      end
      WAIT_RESULT:
      if (lane_valid) begin
        result_q <= reduce_op && !active_q ? acc_q : lane_result;
        if (mask_dest && f6 == 6'h1c) result_q <= lane_result ^ 64'd1;
        if (reduce_op && active_q) acc_q <= lane_result;
        flags_q <= active_q ? lane_flags : 5'b0;
      end
      FORMAT: begin
        o_waddr <= vd + 5'(dbyte >> ByteBits);
        o_wdata <= VLEN'(result_q) << (8 * int'(dbyte[ByteBits-1:0]));
        o_wbe   <= ((Bytes'(1) << (4'd1 << dw)) - Bytes'(1)) << int'(dbyte[ByteBits-1:0]);
        if (mask_dest) begin
          o_waddr <= vd;
          o_wdata <= (regs_q[2] & ~(VLEN'(1) << idx_q)) | (VLEN'(result_q[0]) << idx_q);
          o_wbe   <= Bytes'(1) << (idx_q >> 3);
        end
        acc_flags_q <= acc_flags_q | flags_q;
      end
      ADVANCE: idx_q <= idx_q + 1;
      default: ;
    endcase
  end
endmodule

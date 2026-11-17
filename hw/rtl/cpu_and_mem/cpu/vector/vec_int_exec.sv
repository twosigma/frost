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

// Committed integer operations with mixed element widths or cross-element
// dependencies. One element is read, executed and written at a time. The
// register file and every lane see registered data; inactive bytes are held.
module vec_int_exec #(
    parameter int unsigned VLEN = 256,
    localparam int unsigned Bytes = VLEN / 8,
    localparam int unsigned ByteBits = $clog2(Bytes),
    localparam int unsigned MaskBits = $clog2(VLEN)
) (
    input logic i_clk,
    i_rst,
    i_valid,
    input logic [31:0] i_insn,
    input logic [1:0] i_sew,
    input logic [2:0] i_lmul,
    input logic [15:0] i_vl,
    i_vstart,
    input logic [63:0] i_scalar,
    input logic [1:0] i_vxrm,
    output logic o_idle,
    o_sat,
    output logic [3:0][4:0] o_raddr,
    input logic [3:0][VLEN-1:0] i_rdata,
    output logic o_we,
    output logic [4:0] o_waddr,
    output logic [VLEN-1:0] o_wdata,
    output logic [Bytes-1:0] o_wbe
);
  typedef enum logic [4:0] {
    IDLE,
    PRE,
    SNAP,
    ADDRESS,
    READ,
    CAPTURE,
    EXTRACT,
    INDEX,
    GREAD,
    GCAP,
    GEXTRACT,
    LAUNCH,
    WAIT_RESULT,
    PRODUCT,
    ROUND_START,
    ROUND_WAIT,
    FORMAT,
    WRITE,
    ADVANCE
  } state_e;
  state_e state;
  logic [31:0] insn_q;
  logic [1:0] sew_q, rm_q;
  logic [15:0] vl_q, idx_q, out_idx_q, limit_q, vlmax_q;
  logic [63:0] scalar_q;
  logic [VLEN-1:0] mask0_q, mask1_q, mask2_q;
  logic [2:0][VLEN-1:0] regs_q;
  logic [63:0] a_q, b_q, c_q, result_q;
  logic [127:0] product_q;
  logic active_q, sat_q, source_valid_q, insert_q, write_element_q;
  logic [15:0] source_idx_q;
  logic [1:0] aw, bw, dw;
  logic [15:0] abyte, bbyte, dbyte;
  logic [5:0] f6;
  logic [2:0] f3;
  logic [4:0] vd, vs1, vs2;
  logic iv, mv, whole, scalar_move, mask_logic, mask_scan, iota, id_op;
  logic reduce_op, wide_reduce, widen, narrow, extend_op, mask_dest;
  logic multiply_op, wide_mul, wide_mac, fractional, divide_op, permute, compress;
  logic carry_op, use_scalar, wide_source;
  assign f6 = insn_q[31:26];
  assign f3 = insn_q[14:12];
  assign vd = insn_q[11:7];
  assign vs1 = insn_q[19:15];
  assign vs2 = insn_q[24:20];
  assign iv = (f3 == 0) || (f3 == 3) || (f3 == 4);
  assign mv = (f3 == 2) || (f3 == 6);
  assign whole = (f3 == 3) && (f6 == 6'h27);
  assign scalar_move = (f3 == 6) && (f6 == 6'h10);
  assign mask_logic = (f3 == 2) && (f6[5:3] == 3'b011);
  assign mask_scan = (f3 == 2) && (f6 == 6'h14) && (vs1 < 16);
  assign iota = (f3 == 2) && (f6 == 6'h14) && (vs1 == 16);
  assign id_op = (f3 == 2) && (f6 == 6'h14) && (vs1 == 17);
  assign wide_reduce = (f3 == 0) && ((f6 == 6'h30) || (f6 == 6'h31));
  assign reduce_op = ((f3 == 2) && (f6 < 8)) || wide_reduce;
  assign widen = (mv && (f6 >= 6'h30)) || (iv && (f6 == 6'h35));
  assign wide_source = mv && (f6 >= 6'h34) && (f6 <= 6'h37);
  assign narrow = iv && (f6 >= 6'h2c) && (f6 <= 6'h2f);
  assign extend_op = (f3 == 2) && (f6 == 6'h12);
  assign carry_op = iv && (f6 >= 6'h10) && (f6 <= 6'h13);
  assign mask_dest = mask_logic || mask_scan || (carry_op && f6[0]);
  assign fractional = iv && (f6 == 6'h27) && !whole;
  assign wide_mul = mv && (f6 >= 6'h38);
  assign wide_mac = mv && (f6 >= 6'h3c);
  assign multiply_op = fractional || wide_mul ||
      (mv && ((f6 >= 6'h24 && f6 <= 6'h27) || f6 == 6'h29 ||
               f6 == 6'h2b || f6 == 6'h2d || f6 == 6'h2f));
  assign divide_op = mv && (f6 >= 6'h20) && (f6 <= 6'h23);
  assign permute = (iv && (f6 == 6'h0c || f6 == 6'h0e || f6 == 6'h0f)) ||
      (f3 == 6 && (f6 == 6'h0e || f6 == 6'h0f));
  assign compress = (f3 == 2) && (f6 == 6'h17);
  assign use_scalar = (f3 == 3) || (f3 == 4) || (f3 == 6);

  function automatic logic [63:0] cut(input logic [63:0] x, input logic [1:0] w);
    case (w)
      0: cut = 64'(x[7:0]);
      1: cut = 64'(x[15:0]);
      2: cut = 64'(x[31:0]);
      default: cut = x;
    endcase
  endfunction
  function automatic logic [63:0] sext(input logic [63:0] x, input logic [1:0] w);
    case (w)
      0: sext = 64'($signed(x[7:0]));
      1: sext = 64'($signed(x[15:0]));
      2: sext = 64'($signed(x[31:0]));
      default: sext = x;
    endcase
  endfunction
  always_comb begin
    aw = sew_q + 2'(narrow || wide_source);
    if (extend_op) aw = sew_q - (2'd0 - vs1[2:1]);
    bw = (f3 == 0 && f6 == 6'h0e) ? 2'd1 : sew_q;
    dw = sew_q + 2'(widen || wide_reduce);
    if (reduce_op) bw = dw;
    abyte = source_idx_q << aw;
    bbyte = (reduce_op ? 16'd0 : idx_q) << bw;
    dbyte = (reduce_op ? 16'd0 : (compress ? out_idx_q : idx_q)) << dw;
    o_raddr[0] = vs2 + 5'(abyte >> ByteBits);
    o_raddr[1] = vs1 + 5'(bbyte >> ByteBits);
    o_raddr[2] = vd + 5'(dbyte >> ByteBits);
    o_raddr[3] = 0;
    if (state == PRE || state == SNAP) begin
      o_raddr[0] = vs2;
      o_raddr[1] = vs1;
      o_raddr[2] = vd;
    end
    if (mask_dest) o_raddr[2] = vd;
  end

  vec_pkg::mul_op_e   mul_op;
  vec_pkg::mask_op_e  mask_op;
  vec_pkg::red_op_e   red_op;
  vec_pkg::extra_op_e fixed_op;
  logic [63:0] mul_x, mul_y, mul_z, mask_a, mask_b, mask_act;
  logic [7:0] red_act;
  logic mul_valid, mask_valid, red_valid, fixed_valid, div_valid;
  logic [63:0] mul_result, mask_result, mask_scalar, red_result, fixed_result, div_result;
  logic [127:0] mul_product;
  logic fixed_sat;
  always_comb begin
    mul_op = vec_pkg::VM_MUL;
    mul_x  = a_q;
    mul_y  = b_q;
    mul_z  = c_q;
    if (fractional) mul_op = vec_pkg::VM_MULH;
    else if (wide_mul) begin
      case (f6)
        6'h38, 6'h3c: mul_op = vec_pkg::VM_MULHU;
        6'h3a: mul_op = vec_pkg::VM_MULHSU;
        6'h3b, 6'h3d: mul_op = vec_pkg::VM_MULH;
        6'h3e: mul_op = vec_pkg::VM_MULHSU;
        default: begin
          mul_op = vec_pkg::VM_MULHSU;
          mul_x  = b_q;
          mul_y  = a_q;
        end
      endcase
    end else begin
      case (f6)
        6'h24:   mul_op = vec_pkg::VM_MULHU;
        6'h26:   mul_op = vec_pkg::VM_MULHSU;
        6'h27:   mul_op = vec_pkg::VM_MULH;
        6'h29, 6'h2b: begin
          mul_op = f6[1] ? vec_pkg::VM_NMSAC : vec_pkg::VM_MACC;
          mul_x  = c_q;
          mul_z  = a_q;
        end
        6'h2d:   mul_op = vec_pkg::VM_MACC;
        6'h2f:   mul_op = vec_pkg::VM_NMSAC;
        default: ;
      endcase
    end
    case (f6[2:0])
      0: mask_op = vec_pkg::VK_ANDN;
      1: mask_op = vec_pkg::VK_AND;
      2: mask_op = vec_pkg::VK_OR;
      3: mask_op = vec_pkg::VK_XOR;
      4: mask_op = vec_pkg::VK_ORN;
      5: mask_op = vec_pkg::VK_NAND;
      6: mask_op = vec_pkg::VK_NOR;
      default: mask_op = vec_pkg::VK_XNOR;
    endcase
    if (mask_scan || iota || id_op) begin
      case (vs1)
        1: mask_op = vec_pkg::VK_SBF;
        2: mask_op = vec_pkg::VK_SOF;
        3: mask_op = vec_pkg::VK_SIF;
        16: mask_op = vec_pkg::VK_IOTA;
        default: mask_op = vec_pkg::VK_ID;
      endcase
    end
    mask_a   = 64'(mask2_q[MaskBits'(idx_q)]);
    mask_b   = 64'(mask1_q[MaskBits'(idx_q)]);
    mask_act = 64'(active_q);
    red_act  = 8'(active_q);
    red_op   = vec_pkg::red_op_e'({1'b0, f6[2:0]});
    if (wide_reduce) red_op = f6[0] ? vec_pkg::VR_WSUM : vec_pkg::VR_WSUMU;
    fixed_op = vec_pkg::VX_ZEXT;
    if (carry_op) begin
      case (f6[1:0])
        0: fixed_op = vec_pkg::VX_ADC;
        1: fixed_op = vec_pkg::VX_MADC;
        2: fixed_op = vec_pkg::VX_SBC;
        default: fixed_op = vec_pkg::VX_MSBC;
      endcase
    end else if (extend_op) fixed_op = vs1[0] ? vec_pkg::VX_SEXT : vec_pkg::VX_ZEXT;
    else if (fractional) fixed_op = vec_pkg::VX_SMUL;
    else if (iv) begin
      case (f6)
        6'h20:   fixed_op = vec_pkg::VX_ADDU;
        6'h21:   fixed_op = vec_pkg::VX_ADD;
        6'h22:   fixed_op = vec_pkg::VX_SUBU;
        6'h23:   fixed_op = vec_pkg::VX_SUB;
        6'h2a:   fixed_op = vec_pkg::VX_SSRL;
        6'h2b:   fixed_op = vec_pkg::VX_SSRA;
        6'h2c:   fixed_op = vec_pkg::VX_NSRL;
        6'h2d:   fixed_op = vec_pkg::VX_NSRA;
        6'h2e:   fixed_op = vec_pkg::VX_CLIPU;
        6'h2f:   fixed_op = vec_pkg::VX_CLIP;
        6'h35:   fixed_op = vec_pkg::VX_WSLL;
        default: ;
      endcase
    end else begin
      case (f6)
        6'h08: fixed_op = vec_pkg::VX_AADDU;
        6'h09: fixed_op = vec_pkg::VX_AADD;
        6'h0a: fixed_op = vec_pkg::VX_ASUBU;
        6'h0b: fixed_op = vec_pkg::VX_ASUB;
        6'h30, 6'h34: fixed_op = vec_pkg::VX_WADDU;
        6'h31, 6'h35: fixed_op = vec_pkg::VX_WADD;
        6'h32, 6'h36: fixed_op = vec_pkg::VX_WSUBU;
        6'h33, 6'h37: fixed_op = vec_pkg::VX_WSUB;
        default: ;
      endcase
    end
  end
  logic simple_op, mask_op_sel, fixed_start;
  assign simple_op = whole || scalar_move || compress || permute;
  assign mask_op_sel = mask_logic || mask_scan || iota || id_op;
  assign fixed_start = (state == ROUND_START) ||
      ((state == LAUNCH) && !simple_op && !mask_op_sel && !reduce_op &&
       !multiply_op && !divide_op);
  vec_mul_lane u_mul (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && multiply_op),
      .i_op(mul_op),
      .i_sew(vec_pkg::sew_e'(sew_q)),
      .i_x(mul_x),
      .i_y(mul_y),
      .i_z(mul_z),
      .o_valid(mul_valid),
      .o_result(mul_result),
      .o_wide(mul_product)
  );
  vec_mask_unit #(
      .MAX_BITS(VLEN)
  ) u_mask (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && mask_op_sel),
      .i_first(idx_q == 0),
      .i_op(mask_op),
      .i_sew(vec_pkg::SEW64),
      .i_a(mask_a),
      .i_b(mask_b),
      .i_act(mask_act),
      .o_valid(mask_valid),
      .o_result(mask_result),
      .o_scalar(mask_scalar)
  );
  vec_red_unit u_red (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && reduce_op),
      .i_first(idx_q == 0),
      .i_op(red_op),
      .i_sew(vec_pkg::sew_e'(sew_q)),
      .i_word(a_q),
      .i_act(red_act),
      .i_init(b_q),
      .o_valid(red_valid),
      .o_acc(red_result)
  );
  vec_fixed_lane u_fixed (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(fixed_start),
      .i_op(fixed_op),
      .i_sew(sew_q),
      .i_aw(aw),
      .i_vxrm(rm_q),
      .i_a(a_q),
      .i_b(b_q),
      .i_product(product_q),
      .i_carry(!insn_q[25] && mask0_q[MaskBits'(idx_q)]),
      .o_valid(fixed_valid),
      .o_result(fixed_result),
      .o_sat(fixed_sat)
  );
  vec_div_lane u_div (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && divide_op),
      .i_signed(f6[0]),
      .i_rem(f6[1]),
      .i_a(f6[0] ? sext(a_q, sew_q) : a_q),
      .i_b(f6[0] ? sext(b_q, sew_q) : b_q),
      .o_valid(div_valid),
      .o_result(div_result)
  );

  logic [63:0] source_index_d;
  logic source_valid_d, insert_d, write_d;
  always_comb begin
    source_index_d = 64'(idx_q);
    source_valid_d = 1'b1;
    insert_d = 1'b0;
    write_d = 1'b1;
    if (permute) begin
      if (f6 == 6'h0c || (f6 == 6'h0e && f3 == 0)) begin
        source_index_d = use_scalar ? scalar_q : b_q;
      end else if (f6 == 6'h0e) begin
        source_index_d = 64'(idx_q) - ((f3 == 6) ? 64'd1 : scalar_q);
        if (f3 == 6 && idx_q == 0) insert_d = 1'b1;
        else write_d = 64'(idx_q) >= scalar_q || f3 == 6;
      end else begin
        source_index_d = 64'(idx_q) + ((f3 == 6) ? 64'd1 : scalar_q);
        if (f3 == 6 && idx_q + 1 == vl_q) insert_d = 1'b1;
        if (source_index_d < 64'(idx_q)) source_valid_d = 1'b0;
      end
      source_valid_d = source_valid_d && (source_index_d < 64'(vlmax_q));
    end
    if (compress) write_d = mask1_q[MaskBits'(idx_q)];
  end
  assign o_idle = state == IDLE;
  assign o_we   = state == WRITE && write_element_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      o_sat <= 1'b0;
    end else begin
      o_sat <= 1'b0;
      case (state)
        IDLE:
        if (i_valid) begin
          insn_q <= i_insn;
          sew_q <= i_sew;
          rm_q <= i_vxrm;
          scalar_q <= i_scalar;
          if (i_insn[14:12] == 3) begin
            if (i_insn[31:26] == 6'h10 || i_insn[31:26] == 6'h11 ||
                i_insn[31:26] == 6'h20 || i_insn[31:26] == 6'h21)
              scalar_q <= 64'($signed(i_insn[19:15]));
            else scalar_q <= 64'(i_insn[19:15]);
          end
          vl_q <= i_vl;
          idx_q <= i_vstart;
          out_idx_q <= 0;
          limit_q <= i_vl;
          vlmax_q <= i_lmul[2] ? (16'(Bytes) >> (4'(i_sew) + (4'd8 - {1'b0,i_lmul}))) :
              ((16'(Bytes) << i_lmul) >> i_sew);
          state <= PRE;
        end
        PRE: state <= SNAP;
        SNAP: begin
          mask2_q <= i_rdata[0];
          mask1_q <= i_rdata[1];
          mask0_q <= i_rdata[3];
          if (whole) limit_q <= (16'(Bytes) * (16'(vs1) + 1)) >> sew_q;
          else if (scalar_move) begin
            limit_q <= (idx_q < vl_q) ? 16'd1 : 16'd0;
            idx_q   <= 0;
          end
          state <= ADDRESS;
        end
        ADDRESS: begin
          source_idx_q <= idx_q;
          if (idx_q >= limit_q) state <= IDLE;
          else state <= READ;
        end
        READ: state <= CAPTURE;
        CAPTURE: begin
          regs_q <= i_rdata[2:0];
          state  <= EXTRACT;
        end
        EXTRACT: begin
          a_q <= cut(64'(regs_q[0] >> (8 * int'(abyte[ByteBits-1:0]))), aw);
          b_q <= cut(use_scalar ? scalar_q : 64'(regs_q[1] >> (8 * int'(bbyte[ByteBits-1:0]))), bw);
          c_q <= cut(64'(regs_q[2] >> (8 * int'(dbyte[ByteBits-1:0]))), dw);
          active_q <= whole || scalar_move || carry_op || insn_q[25] || mask0_q[MaskBits'(idx_q)];
          sat_q <= 1'b0;
          state <= INDEX;
        end
        INDEX: begin
          source_idx_q <= source_index_d[15:0];
          source_valid_q <= source_valid_d;
          insert_q <= insert_d;
          write_element_q <= (active_q && write_d) || (reduce_op && idx_q + 1 == limit_q);
          if (reduce_op && idx_q + 1 != limit_q) write_element_q <= 1'b0;
          state <= permute ? GREAD : LAUNCH;
        end
        GREAD: state <= GCAP;
        GCAP: begin
          regs_q[0] <= i_rdata[0];
          state <= GEXTRACT;
        end
        GEXTRACT: begin
          a_q <= insert_q ? cut(
              scalar_q, sew_q
          ) : (source_valid_q ? cut(
              64'(regs_q[0] >> (8 * int'(abyte[ByteBits-1:0]))), aw
          ) : 64'd0);
          state <= LAUNCH;
        end
        LAUNCH: begin
          if (simple_op) begin
            result_q <= scalar_move ? cut(scalar_q, sew_q) : a_q;
            state <= FORMAT;
          end else state <= WAIT_RESULT;
        end
        WAIT_RESULT: begin
          if (mul_valid) begin
            result_q <= mul_result;
            product_q <= mul_product;
            state <= (wide_mul || fractional) ? PRODUCT : FORMAT;
          end else if (mask_valid) begin
            result_q <= mask_result;
            state <= FORMAT;
          end else if (red_valid) begin
            result_q <= red_result;
            state <= FORMAT;
          end else if (fixed_valid) begin
            result_q <= fixed_result;
            sat_q <= fixed_sat && active_q;
            state <= FORMAT;
          end else if (div_valid) begin
            result_q <= div_result;
            state <= FORMAT;
          end
        end
        PRODUCT: begin
          if (fractional) begin
            case (sew_q)
              0: product_q <= 128'($signed(product_q[15:0]));
              1: product_q <= 128'($signed(product_q[31:0]));
              2: product_q <= 128'($signed(product_q[63:0]));
              default: ;
            endcase
            state <= ROUND_START;
          end else begin
            result_q <= product_q[63:0] + (wide_mac ? c_q : 64'd0);
            state <= FORMAT;
          end
        end
        ROUND_START: state <= ROUND_WAIT;
        ROUND_WAIT:
        if (fixed_valid) begin
          result_q <= fixed_result;
          sat_q <= fixed_sat && active_q;
          state <= FORMAT;
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
          o_sat <= sat_q;
          state <= WRITE;
        end
        WRITE: state <= ADVANCE;
        ADVANCE: begin
          if (compress && mask1_q[MaskBits'(idx_q)]) out_idx_q <= out_idx_q + 1;
          idx_q <= idx_q + 1;
          state <= ADDRESS;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule

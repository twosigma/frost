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

// Committed integer operations outside the single-width ALU path.
// Single-width and widening integer multiply/multiply-accumulate execute
// a full register group in parallel across VLEN/64 multiply lanes, skipping
// groups outside vstart..vl. Integer and widening-sum reductions stream one
// 64-bit lane per cycle through the pipelined reduction tree. Fixed-point,
// carry/borrow, widening/narrowing add/shift, divide, mask and permutation
// instructions execute one element at a time. Register-file read addresses
// and write outputs are registered; inactive bytes are held.
module vec_int_exec #(
    parameter int unsigned VLEN = 256,
    localparam int unsigned Lanes = VLEN / 64,
    localparam int unsigned LaneBits = $clog2(Lanes),
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
    ADVANCE,
    GM_RD,
    GM_LAUNCH,
    GM_WAIT,
    GM_WR_LO,
    GM_WR_HI,
    GR_FEED,
    GR_WAIT
  } state_e;
  state_e state;
  logic [31:0] insn_q;
  logic [1:0] sew_q, rm_q;
  logic [2:0] lmul_q;
  logic [15:0] vl_q, vstart_q, idx_q, out_idx_q, limit_q, vlmax_q;
  logic [63:0] scalar_q, scalar_rep_q;
  logic [VLEN-1:0] mask0_q, mask1_q, mask2_q;
  logic [2:0][VLEN-1:0] regs_q;
  logic [63:0] a_q, b_q, c_q, result_q;
  logic [127:0] product_q;
  logic active_q, sat_q, source_valid_q, insert_q, write_element_q;
  logic [15:0] source_idx_q;
  logic [3:0][4:0] raddr_q;
  logic we_q;
  logic [4:0] waddr_q;
  logic [VLEN-1:0] wdata_q;
  logic [Bytes-1:0] wbe_q;

  // Group-wide multiply/MAC state
  logic [3:0] g_q, last_g_q;
  logic [4:0] gm_waddr_lo_q;
  logic [2:0] gm_wait_cnt_q;
  logic gm_v0_captured_q, gm_has_hi_q;
  logic [15:0] gbase_q;
  logic [Bytes-1:0] gm_act_d, gm_act_q, wbe_lo_d, wbe_hi_d, wbe_lo_q, wbe_hi_q;
  logic [VLEN-1:0] old_vd_lo_q, old_vd_hi_q, wide_hi_q;

  // Pipelined group-wide reduction state
  logic [6:0] red_lane_q, red_last_lane_q;
  logic [5:0] red_last_sr_q;
  logic [Bytes-1:0] red_wbe_q;

  logic [1:0] aw, bw, dw;
  logic [15:0] abyte, bbyte, dbyte;
  logic [15:0] abyte_addr, bbyte_addr, dbyte_addr;
  logic [5:0] f6;
  logic [2:0] f3;
  logic [4:0] vd, vs1, vs2;
  logic iv, mv, whole, scalar_move, mask_logic, mask_scan, iota, id_op;
  logic reduce_op, wide_reduce, widen, narrow, extend_op, mask_dest;
  logic multiply_op, wide_mul, wide_mac, fractional, grp_mul_op, divide_op, permute, compress;
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
  assign grp_mul_op = multiply_op && !fractional;
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
  function automatic logic [63:0] replicate64(input logic [63:0] x, input logic [1:0] w);
    unique case (w)
      2'd0: replicate64 = {8{x[7:0]}};
      2'd1: replicate64 = {4{x[15:0]}};
      2'd2: replicate64 = {2{x[31:0]}};
      default: replicate64 = x;
    endcase
  endfunction
  // Segmented 2*SEW addition for widening multiply-accumulate (SEW 8/16/32 -> 16/32/64).
  function automatic logic [63:0] wide_add64(input logic [63:0] x, input logic [63:0] y,
                                             input logic [1:0] sew);
    logic [7:0] tops;
    logic [71:0] ex, ey, es;
    unique case (sew)
      2'd0: tops = 8'b1010_1010;
      2'd1: tops = 8'b1000_1000;
      default: tops = 8'b1000_0000;
    endcase
    for (int i = 0; i < 8; i++) begin
      ex[9*i+:8] = x[8*i+:8];
      ey[9*i+:8] = y[8*i+:8];
      ex[9*i+8]  = tops[i] ? 1'b0 : 1'b1;
      ey[9*i+8]  = 1'b0;
    end
    es = ex + ey;
    for (int i = 0; i < 8; i++) wide_add64[8*i+:8] = es[9*i+:8];
  endfunction

  always_comb begin
    aw = sew_q + 2'(narrow || wide_source);
    if (extend_op) aw = sew_q - (2'd0 - vs1[2:1]);
    bw = (f3 == 0 && f6 == 6'h0e) ? 2'd1 : sew_q;
    dw = sew_q + 2'(widen || wide_reduce);
    if (reduce_op) bw = dw;
    abyte = source_idx_q << aw;
    bbyte = idx_q << bw;
    dbyte = (compress ? out_idx_q : idx_q) << dw;
    abyte_addr = idx_q << aw;
    bbyte_addr = idx_q << bw;
    dbyte_addr = (compress ? out_idx_q : idx_q) << dw;
  end
  assign o_raddr = raddr_q;

  // Group bounds computed from registered state in PRE.
  logic [2:0] epr_shift, epl_shift;
  logic [3:0] max_g, eff_last_g;
  logic [15:0] first_g_raw, last_g_raw;
  logic no_body;
  assign epr_shift = 3'(ByteBits) - {1'b0, sew_q};
  assign epl_shift = 3'd3 - {1'b0, sew_q};
  assign max_g = lmul_q[2] ? 4'd0 : ((4'd1 << lmul_q[1:0]) - 4'd1);
  assign first_g_raw = vstart_q >> epr_shift;
  assign last_g_raw = (vl_q - 16'd1) >> epr_shift;
  assign no_body = (vstart_q >= vl_q) || (first_g_raw > {12'd0, max_g});
  assign eff_last_g = (last_g_raw > {12'd0, max_g}) ? max_g : last_g_raw[3:0];

  vec_pkg::mul_op_e   mul_op;
  vec_pkg::mask_op_e  mask_op;
  vec_pkg::red_op_e   red_op;
  vec_pkg::extra_op_e fixed_op;
  logic [63:0] mul_x, mul_y, mul_z, mask_a, mask_b, mask_act;
  logic [Lanes-1:0] mul_lane_valid, mul_lane_ovalid;
  logic [Lanes-1:0][63:0] mul_lane_x, mul_lane_y, mul_lane_z, mul_lane_result;
  logic [Lanes-1:0][127:0] mul_lane_wide;
  logic [VLEN-1:0] mul_res_vec, wide_lo_vec, wide_hi_vec, wide_acc_vec;
  logic [63:0] red_word_in, red_init_in;
  logic [7:0] red_act_in;
  logic mask_valid, red_valid, fixed_valid, div_valid;
  logic [63:0] mask_result, mask_scalar, red_result, fixed_result, div_result;
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

    for (int l = 0; l < Lanes; l++) begin
      logic [63:0] la, lb, lc;
      la = i_rdata[0][64*l+:64];
      lb = use_scalar ? scalar_rep_q : i_rdata[1][64*l+:64];
      lc = i_rdata[2][64*l+:64];
      mul_lane_valid[l] = (state == GM_LAUNCH) || ((l == 0) && (state == LAUNCH) && fractional);
      if ((l == 0) && (state == LAUNCH) && fractional) begin
        mul_lane_x[l] = mul_x;
        mul_lane_y[l] = mul_y;
        mul_lane_z[l] = mul_z;
      end else if (wide_mul && f6 == 6'h3f) begin
        mul_lane_x[l] = lb;
        mul_lane_y[l] = la;
        mul_lane_z[l] = 64'd0;
      end else if (!wide_mul && (f6 == 6'h29 || f6 == 6'h2b)) begin
        mul_lane_x[l] = lc;
        mul_lane_y[l] = lb;
        mul_lane_z[l] = la;
      end else begin
        mul_lane_x[l] = la;
        mul_lane_y[l] = lb;
        mul_lane_z[l] = lc;
      end
    end

    for (int l = 0; l < Lanes; l++) mul_res_vec[64*l+:64] = mul_lane_result[l];
    for (int l = 0; l < Lanes / 2; l++) begin
      wide_lo_vec[128*l+:128] = mul_lane_wide[l];
      wide_hi_vec[128*l+:128] = mul_lane_wide[Lanes/2+l];
    end
    for (int l = 0; l < Lanes; l++) begin
      logic [63:0] wa, wb;
      wa = (state == GM_WR_LO) ? wide_hi_q[64*l+:64] : wide_lo_vec[64*l+:64];
      wb = (state == GM_WR_LO) ? old_vd_hi_q[64*l+:64] : old_vd_lo_q[64*l+:64];
      wide_acc_vec[64*l+:64] = wide_add64(wa, wb, sew_q);
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

    // Pipelined 64-bit lane inputs for integer reductions
    begin
      logic [VLEN-1:0] cur_mask;
      logic [LaneBits-1:0] sub_lane;
      logic [3:0] epl;
      sub_lane = red_lane_q[LaneBits-1:0];
      cur_mask = (red_lane_q == 7'd0) ? i_rdata[3] : mask0_q;
      red_word_in = (red_lane_q == 7'd0) ? i_rdata[0][63:0] : regs_q[0][64*int'(sub_lane)+:64];
      red_init_in = cut(i_rdata[1][63:0], dw);
      epl = 4'd8 >> sew_q;
      for (int k = 0; k < 8; k++) begin
        logic [15:0] e;
        e = ({9'd0, red_lane_q} << epl_shift) + 16'(k);
        red_act_in[k] = (k < int'(epl)) && (e < vl_q) && (e >= vstart_q) &&
            (insn_q[25] || cur_mask[MaskBits'(e)]);
      end
    end
    red_op = vec_pkg::red_op_e'({1'b0, f6[2:0]});
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

  for (genvar l = 0; l < Lanes; l++) begin : gen_mul
    vec_mul_lane u_mul (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_valid(mul_lane_valid[l]),
        .i_op(mul_op),
        .i_sew(vec_pkg::sew_e'(sew_q)),
        .i_x(mul_lane_x[l]),
        .i_y(mul_lane_y[l]),
        .i_z(mul_lane_z[l]),
        .o_valid(mul_lane_ovalid[l]),
        .o_result(mul_lane_result[l]),
        .o_wide(mul_lane_wide[l])
    );
  end
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
      .i_valid(state == GR_FEED),
      .i_first(red_lane_q == 7'd0),
      .i_op(red_op),
      .i_sew(vec_pkg::sew_e'(sew_q)),
      .i_word(red_word_in),
      .i_act(red_act_in),
      .i_init(red_init_in),
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
  always_comb begin
    logic [2:0] wsh;
    wsh = {1'b0, sew_q} + 3'd1;
    for (int k = 0; k < Bytes; k++) begin
      logic [15:0] e;
      e = gbase_q + 16'(k);
      gm_act_d[k] = (16'(k) < (16'(Bytes) >> sew_q)) && (e < vl_q) && (e >= vstart_q) &&
          (insn_q[25] || mask0_q[MaskBits'(e)]);
    end
    for (int b = 0; b < Bytes; b++) begin
      if (wide_mul) begin
        wbe_lo_d[b] = gm_act_q[ByteBits'(b>>wsh)];
        wbe_hi_d[b] = gm_act_q[ByteBits'((Bytes+b)>>wsh)];
      end else begin
        wbe_lo_d[b] = gm_act_q[ByteBits'(b>>sew_q)];
        wbe_hi_d[b] = 1'b0;
      end
    end
  end

  assign o_idle = (state == IDLE) && !we_q;
  assign o_we = we_q;
  assign o_waddr = waddr_q;
  assign o_wdata = wdata_q;
  assign o_wbe = wbe_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      we_q <= 1'b0;
      o_sat <= 1'b0;
      red_last_sr_q <= 6'd0;
    end else begin
      we_q <= 1'b0;
      o_sat <= 1'b0;
      red_last_sr_q <= {red_last_sr_q[4:0], (state == GR_FEED) && (red_lane_q == red_last_lane_q)};
      case (state)
        IDLE:
        if (i_valid && !we_q) begin
          insn_q <= i_insn;
          sew_q <= i_sew;
          lmul_q <= i_lmul;
          rm_q <= i_vxrm;
          scalar_q <= i_scalar;
          if (i_insn[14:12] == 3) begin
            if (i_insn[31:26] == 6'h10 || i_insn[31:26] == 6'h11 ||
                i_insn[31:26] == 6'h20 || i_insn[31:26] == 6'h21)
              scalar_q <= 64'($signed(i_insn[19:15]));
            else scalar_q <= 64'(i_insn[19:15]);
          end
          vl_q <= i_vl;
          vstart_q <= i_vstart;
          idx_q <= i_vstart;
          out_idx_q <= 0;
          limit_q <= i_vl;
          vlmax_q <= i_lmul[2] ? (16'(Bytes) >> (4'(i_sew) + (4'd8 - {1'b0,i_lmul}))) :
              ((16'(Bytes) << i_lmul) >> i_sew);
          raddr_q[0] <= i_insn[24:20];
          raddr_q[1] <= i_insn[19:15];
          raddr_q[2] <= i_insn[11:7];
          raddr_q[3] <= 5'd0;
          state <= PRE;
        end
        PRE: begin
          if (grp_mul_op) begin
            if (no_body) begin
              state <= IDLE;
            end else begin
              g_q <= first_g_raw[3:0];
              last_g_q <= eff_last_g;
              scalar_rep_q <= replicate64(scalar_q, sew_q);
              gm_v0_captured_q <= 1'b0;
              if (first_g_raw == 16'd0) begin
                if (wide_mac) raddr_q[2] <= vd + 5'd1;
                state <= GM_LAUNCH;
              end else begin
                raddr_q[0] <= vs2 + 5'(first_g_raw[3:0]);
                raddr_q[1] <= vs1 + 5'(first_g_raw[3:0]);
                raddr_q[2] <= vd + (wide_mul ? {first_g_raw[3:0], 1'b0} : 5'(first_g_raw[3:0]));
                state <= GM_RD;
              end
            end
          end else if (reduce_op) begin
            if (vstart_q >= vl_q) begin
              state <= IDLE;
            end else begin
              red_lane_q <= 7'd0;
              red_last_lane_q <= 7'((vl_q - 16'd1) >> epl_shift);
              red_wbe_q <= (Bytes'(1) << (4'd1 << dw)) - Bytes'(1);
              raddr_q[0] <= vs2 + 5'd1;
              state <= GR_FEED;
            end
          end else begin
            state <= SNAP;
          end
        end
        // ------------------------------------------------------------------
        // Group-wide multiply and multiply-accumulate (single-width & wide)
        // ------------------------------------------------------------------
        GM_RD: begin
          if (!gm_v0_captured_q) begin
            mask0_q <= i_rdata[3];
            gm_v0_captured_q <= 1'b1;
          end
          if (wide_mac) raddr_q[2] <= vd + {g_q[3:0], 1'b1};
          state <= GM_LAUNCH;
        end
        GM_LAUNCH: begin
          if (!gm_v0_captured_q) begin
            mask0_q <= i_rdata[3];
            gm_v0_captured_q <= 1'b1;
          end
          old_vd_lo_q <= i_rdata[2];
          gm_wait_cnt_q <= 3'd0;
          state <= GM_WAIT;
        end
        GM_WAIT: begin
          gm_wait_cnt_q <= gm_wait_cnt_q + 3'd1;
          if (gm_wait_cnt_q == 3'd0) begin
            old_vd_hi_q <= i_rdata[2];
            gbase_q <= {12'd0, g_q} << epr_shift;
            gm_has_hi_q <= wide_mul &&
                ((({12'd0, g_q} << epr_shift) + (16'(Bytes >> 1) >> sew_q)) < vl_q);
            gm_waddr_lo_q <= vd + (wide_mul ? {g_q[3:0], 1'b0} : 5'(g_q));
          end else if (gm_wait_cnt_q == 3'd1) begin
            gm_act_q <= gm_act_d;
          end else if (gm_wait_cnt_q == 3'd2) begin
            wbe_lo_q <= wbe_lo_d;
            wbe_hi_q <= wbe_hi_d;
          end
          if (mul_lane_ovalid[0]) begin
            we_q <= 1'b1;
            waddr_q <= gm_waddr_lo_q;
            wbe_q <= wbe_lo_q;
            wdata_q <= wide_mac ? wide_acc_vec : (wide_mul ? wide_lo_vec : mul_res_vec);
            wide_hi_q <= wide_hi_vec;
            if (!gm_has_hi_q && (g_q < last_g_q)) begin
              raddr_q[0] <= vs2 + 5'(g_q + 4'd1);
              raddr_q[1] <= vs1 + 5'(g_q + 4'd1);
              raddr_q[2] <= vd + (wide_mul ? {g_q[3:0] + 4'd1, 1'b0} : 5'(g_q + 4'd1));
            end
            state <= GM_WR_LO;
          end
        end
        GM_WR_LO: begin
          if (gm_has_hi_q) begin
            we_q    <= 1'b1;
            waddr_q <= vd + {g_q[3:0], 1'b1};
            wbe_q   <= wbe_hi_q;
            wdata_q <= wide_mac ? wide_acc_vec : wide_hi_q;
            if (g_q < last_g_q) begin
              raddr_q[0] <= vs2 + 5'(g_q + 4'd1);
              raddr_q[1] <= vs1 + 5'(g_q + 4'd1);
              raddr_q[2] <= vd + {g_q[3:0] + 4'd1, 1'b0};
            end
            state <= GM_WR_HI;
          end else if (g_q < last_g_q) begin
            g_q <= g_q + 4'd1;
            if (wide_mac) raddr_q[2] <= vd + {g_q[3:0] + 4'd1, 1'b1};
            state <= GM_LAUNCH;
          end else begin
            state <= IDLE;
          end
        end
        GM_WR_HI: begin
          if (g_q < last_g_q) begin
            g_q <= g_q + 4'd1;
            if (wide_mac) raddr_q[2] <= vd + {g_q[3:0] + 4'd1, 1'b1};
            state <= GM_LAUNCH;
          end else begin
            state <= IDLE;
          end
        end
        // ------------------------------------------------------------------
        // Pipelined 64-bit lane-by-lane integer reductions
        // ------------------------------------------------------------------
        GR_FEED: begin
          if (red_lane_q == 7'd0) begin
            mask0_q   <= i_rdata[3];
            regs_q[0] <= i_rdata[0];
          end
          if (red_lane_q[LaneBits-1:0] == LaneBits'(Lanes - 1)) begin
            regs_q[0]  <= i_rdata[0];
            raddr_q[0] <= vs2 + 5'(red_lane_q >> LaneBits) + 5'd2;
          end
          if (red_lane_q == red_last_lane_q) begin
            state <= GR_WAIT;
          end else begin
            red_lane_q <= red_lane_q + 7'd1;
          end
        end
        GR_WAIT: begin
          if (red_last_sr_q[5]) begin
            we_q    <= 1'b1;
            waddr_q <= vd;
            wbe_q   <= red_wbe_q;
            wdata_q <= VLEN'(red_result);
            state   <= IDLE;
          end
        end
        // ------------------------------------------------------------------
        // Element-by-element sequencer for remaining operations
        // ------------------------------------------------------------------
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
          raddr_q[0]   <= vs2 + 5'(abyte_addr >> ByteBits);
          raddr_q[1]   <= vs1 + 5'(bbyte_addr >> ByteBits);
          raddr_q[2]   <= mask_dest ? vd : (vd + 5'(dbyte_addr >> ByteBits));
          raddr_q[3]   <= 5'd0;
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
          write_element_q <= active_q && write_d;
          if (permute) raddr_q[0] <= vs2 + 5'((source_index_d[15:0] << aw) >> ByteBits);
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
          if (mul_lane_ovalid[0]) begin
            result_q <= mul_lane_result[0];
            product_q <= mul_lane_wide[0];
            state <= PRODUCT;
          end else if (mask_valid) begin
            result_q <= mask_result;
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
          case (sew_q)
            0: product_q <= 128'($signed(product_q[15:0]));
            1: product_q <= 128'($signed(product_q[31:0]));
            2: product_q <= 128'($signed(product_q[63:0]));
            default: ;
          endcase
          state <= ROUND_START;
        end
        ROUND_START: state <= ROUND_WAIT;
        ROUND_WAIT:
        if (fixed_valid) begin
          result_q <= fixed_result;
          sat_q <= fixed_sat && active_q;
          state <= FORMAT;
        end
        FORMAT: begin
          we_q    <= write_element_q;
          waddr_q <= vd + 5'(dbyte >> ByteBits);
          wdata_q <= VLEN'(result_q) << (8 * int'(dbyte[ByteBits-1:0]));
          wbe_q   <= ((Bytes'(1) << (4'd1 << dw)) - Bytes'(1)) << int'(dbyte[ByteBits-1:0]);
          if (mask_dest) begin
            waddr_q <= vd;
            wdata_q <= (regs_q[2] & ~(VLEN'(1) << idx_q)) | (VLEN'(result_q[0]) << idx_q);
            wbe_q   <= Bytes'(1) << (idx_q >> 3);
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

`ifndef SYNTHESIS
`ifndef FORMAL
  logic ie_reset_seen_q = 1'b0;
  always @(posedge i_clk) begin
    if (i_rst) ie_reset_seen_q <= 1'b1;
    if (ie_reset_seen_q && !i_rst) begin
      assert (!red_last_sr_q[5] || red_valid)
      else $error("vec_int_exec: reduction final strobe misaligned with u_red.o_valid");
    end
  end
`endif
`endif
endmodule

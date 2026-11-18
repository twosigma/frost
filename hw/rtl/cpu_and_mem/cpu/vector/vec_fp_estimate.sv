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

// V's reciprocal and reciprocal-square-root estimates. The lookup values
// are the ratified V 1.0 tables. A fixed FRAC normalization steps precede the
// lookup, exponent calculation and packing; operand values never affect latency.
module vec_fp_estimate #(
    parameter int unsigned EXP = 8,
    parameter int unsigned FRAC = 23,
    localparam int unsigned W = 1 + EXP + FRAC
) (
    input logic i_clk,
    i_rst,
    i_valid,
    input logic i_rsqrt,
    input logic [2:0] i_rm,
    input logic [W-1:0] i_a,
    output logic o_ready,
    o_valid,
    output logic [W-1:0] o_result,
    output logic [4:0] o_flags
);
  localparam int EW = EXP + 3;
  localparam int CW = $clog2(FRAC + 1);
  localparam int Bias = (1 << (EXP - 1)) - 1;
  localparam logic [W-1:0] Nan = {1'b0, {EXP{1'b1}}, 1'b1, {(FRAC - 1) {1'b0}}};
  typedef enum logic [2:0] {
    IDLE,
    NORMALIZE,
    LOOKUP,
    PACK,
    OUTPUT
  } state_e;
  state_e state;
  logic [CW-1:0] count_q;
  logic [FRAC:0] sig_q;
  logic signed [EW-1:0] exp_q, out_exp_q;
  logic sign_q, sqrt_q, nan_q, snan_q, inf_q, zero_q;
  logic [2:0] rm_q;
  logic [6:0] estimate_q;
  function automatic logic [6:0] vfrec7_table(input logic [6:0] index);
    case (index)
      7'd0: vfrec7_table = 7'd127;
      7'd1: vfrec7_table = 7'd125;
      7'd2: vfrec7_table = 7'd123;
      7'd3: vfrec7_table = 7'd121;
      7'd4: vfrec7_table = 7'd119;
      7'd5: vfrec7_table = 7'd117;
      7'd6: vfrec7_table = 7'd116;
      7'd7: vfrec7_table = 7'd114;
      7'd8: vfrec7_table = 7'd112;
      7'd9: vfrec7_table = 7'd110;
      7'd10: vfrec7_table = 7'd109;
      7'd11: vfrec7_table = 7'd107;
      7'd12: vfrec7_table = 7'd105;
      7'd13: vfrec7_table = 7'd104;
      7'd14: vfrec7_table = 7'd102;
      7'd15: vfrec7_table = 7'd100;
      7'd16: vfrec7_table = 7'd99;
      7'd17: vfrec7_table = 7'd97;
      7'd18: vfrec7_table = 7'd96;
      7'd19: vfrec7_table = 7'd94;
      7'd20: vfrec7_table = 7'd93;
      7'd21: vfrec7_table = 7'd91;
      7'd22: vfrec7_table = 7'd90;
      7'd23: vfrec7_table = 7'd88;
      7'd24: vfrec7_table = 7'd87;
      7'd25: vfrec7_table = 7'd85;
      7'd26: vfrec7_table = 7'd84;
      7'd27: vfrec7_table = 7'd83;
      7'd28: vfrec7_table = 7'd81;
      7'd29: vfrec7_table = 7'd80;
      7'd30: vfrec7_table = 7'd79;
      7'd31: vfrec7_table = 7'd77;
      7'd32: vfrec7_table = 7'd76;
      7'd33: vfrec7_table = 7'd75;
      7'd34: vfrec7_table = 7'd74;
      7'd35: vfrec7_table = 7'd72;
      7'd36: vfrec7_table = 7'd71;
      7'd37: vfrec7_table = 7'd70;
      7'd38: vfrec7_table = 7'd69;
      7'd39: vfrec7_table = 7'd68;
      7'd40: vfrec7_table = 7'd66;
      7'd41: vfrec7_table = 7'd65;
      7'd42: vfrec7_table = 7'd64;
      7'd43: vfrec7_table = 7'd63;
      7'd44: vfrec7_table = 7'd62;
      7'd45: vfrec7_table = 7'd61;
      7'd46: vfrec7_table = 7'd60;
      7'd47: vfrec7_table = 7'd59;
      7'd48: vfrec7_table = 7'd58;
      7'd49: vfrec7_table = 7'd57;
      7'd50: vfrec7_table = 7'd56;
      7'd51: vfrec7_table = 7'd55;
      7'd52: vfrec7_table = 7'd54;
      7'd53: vfrec7_table = 7'd53;
      7'd54: vfrec7_table = 7'd52;
      7'd55: vfrec7_table = 7'd51;
      7'd56: vfrec7_table = 7'd50;
      7'd57: vfrec7_table = 7'd49;
      7'd58: vfrec7_table = 7'd48;
      7'd59: vfrec7_table = 7'd47;
      7'd60: vfrec7_table = 7'd46;
      7'd61: vfrec7_table = 7'd45;
      7'd62: vfrec7_table = 7'd44;
      7'd63: vfrec7_table = 7'd43;
      7'd64: vfrec7_table = 7'd42;
      7'd65: vfrec7_table = 7'd41;
      7'd66: vfrec7_table = 7'd40;
      7'd67: vfrec7_table = 7'd40;
      7'd68: vfrec7_table = 7'd39;
      7'd69: vfrec7_table = 7'd38;
      7'd70: vfrec7_table = 7'd37;
      7'd71: vfrec7_table = 7'd36;
      7'd72: vfrec7_table = 7'd35;
      7'd73: vfrec7_table = 7'd35;
      7'd74: vfrec7_table = 7'd34;
      7'd75: vfrec7_table = 7'd33;
      7'd76: vfrec7_table = 7'd32;
      7'd77: vfrec7_table = 7'd31;
      7'd78: vfrec7_table = 7'd31;
      7'd79: vfrec7_table = 7'd30;
      7'd80: vfrec7_table = 7'd29;
      7'd81: vfrec7_table = 7'd28;
      7'd82: vfrec7_table = 7'd28;
      7'd83: vfrec7_table = 7'd27;
      7'd84: vfrec7_table = 7'd26;
      7'd85: vfrec7_table = 7'd25;
      7'd86: vfrec7_table = 7'd25;
      7'd87: vfrec7_table = 7'd24;
      7'd88: vfrec7_table = 7'd23;
      7'd89: vfrec7_table = 7'd23;
      7'd90: vfrec7_table = 7'd22;
      7'd91: vfrec7_table = 7'd21;
      7'd92: vfrec7_table = 7'd21;
      7'd93: vfrec7_table = 7'd20;
      7'd94: vfrec7_table = 7'd19;
      7'd95: vfrec7_table = 7'd19;
      7'd96: vfrec7_table = 7'd18;
      7'd97: vfrec7_table = 7'd17;
      7'd98: vfrec7_table = 7'd17;
      7'd99: vfrec7_table = 7'd16;
      7'd100: vfrec7_table = 7'd15;
      7'd101: vfrec7_table = 7'd15;
      7'd102: vfrec7_table = 7'd14;
      7'd103: vfrec7_table = 7'd14;
      7'd104: vfrec7_table = 7'd13;
      7'd105: vfrec7_table = 7'd12;
      7'd106: vfrec7_table = 7'd12;
      7'd107: vfrec7_table = 7'd11;
      7'd108: vfrec7_table = 7'd11;
      7'd109: vfrec7_table = 7'd10;
      7'd110: vfrec7_table = 7'd9;
      7'd111: vfrec7_table = 7'd9;
      7'd112: vfrec7_table = 7'd8;
      7'd113: vfrec7_table = 7'd8;
      7'd114: vfrec7_table = 7'd7;
      7'd115: vfrec7_table = 7'd7;
      7'd116: vfrec7_table = 7'd6;
      7'd117: vfrec7_table = 7'd5;
      7'd118: vfrec7_table = 7'd5;
      7'd119: vfrec7_table = 7'd4;
      7'd120: vfrec7_table = 7'd4;
      7'd121: vfrec7_table = 7'd3;
      7'd122: vfrec7_table = 7'd3;
      7'd123: vfrec7_table = 7'd2;
      7'd124: vfrec7_table = 7'd2;
      7'd125: vfrec7_table = 7'd1;
      7'd126: vfrec7_table = 7'd1;
      7'd127: vfrec7_table = 7'd0;
      default: vfrec7_table = '0;
    endcase
  endfunction

  function automatic logic [6:0] vfrsqrt7_table(input logic [6:0] index);
    case (index)
      7'd0: vfrsqrt7_table = 7'd52;
      7'd1: vfrsqrt7_table = 7'd51;
      7'd2: vfrsqrt7_table = 7'd50;
      7'd3: vfrsqrt7_table = 7'd48;
      7'd4: vfrsqrt7_table = 7'd47;
      7'd5: vfrsqrt7_table = 7'd46;
      7'd6: vfrsqrt7_table = 7'd44;
      7'd7: vfrsqrt7_table = 7'd43;
      7'd8: vfrsqrt7_table = 7'd42;
      7'd9: vfrsqrt7_table = 7'd41;
      7'd10: vfrsqrt7_table = 7'd40;
      7'd11: vfrsqrt7_table = 7'd39;
      7'd12: vfrsqrt7_table = 7'd38;
      7'd13: vfrsqrt7_table = 7'd36;
      7'd14: vfrsqrt7_table = 7'd35;
      7'd15: vfrsqrt7_table = 7'd34;
      7'd16: vfrsqrt7_table = 7'd33;
      7'd17: vfrsqrt7_table = 7'd32;
      7'd18: vfrsqrt7_table = 7'd31;
      7'd19: vfrsqrt7_table = 7'd30;
      7'd20: vfrsqrt7_table = 7'd30;
      7'd21: vfrsqrt7_table = 7'd29;
      7'd22: vfrsqrt7_table = 7'd28;
      7'd23: vfrsqrt7_table = 7'd27;
      7'd24: vfrsqrt7_table = 7'd26;
      7'd25: vfrsqrt7_table = 7'd25;
      7'd26: vfrsqrt7_table = 7'd24;
      7'd27: vfrsqrt7_table = 7'd23;
      7'd28: vfrsqrt7_table = 7'd23;
      7'd29: vfrsqrt7_table = 7'd22;
      7'd30: vfrsqrt7_table = 7'd21;
      7'd31: vfrsqrt7_table = 7'd20;
      7'd32: vfrsqrt7_table = 7'd19;
      7'd33: vfrsqrt7_table = 7'd19;
      7'd34: vfrsqrt7_table = 7'd18;
      7'd35: vfrsqrt7_table = 7'd17;
      7'd36: vfrsqrt7_table = 7'd16;
      7'd37: vfrsqrt7_table = 7'd16;
      7'd38: vfrsqrt7_table = 7'd15;
      7'd39: vfrsqrt7_table = 7'd14;
      7'd40: vfrsqrt7_table = 7'd14;
      7'd41: vfrsqrt7_table = 7'd13;
      7'd42: vfrsqrt7_table = 7'd12;
      7'd43: vfrsqrt7_table = 7'd12;
      7'd44: vfrsqrt7_table = 7'd11;
      7'd45: vfrsqrt7_table = 7'd10;
      7'd46: vfrsqrt7_table = 7'd10;
      7'd47: vfrsqrt7_table = 7'd9;
      7'd48: vfrsqrt7_table = 7'd9;
      7'd49: vfrsqrt7_table = 7'd8;
      7'd50: vfrsqrt7_table = 7'd7;
      7'd51: vfrsqrt7_table = 7'd7;
      7'd52: vfrsqrt7_table = 7'd6;
      7'd53: vfrsqrt7_table = 7'd6;
      7'd54: vfrsqrt7_table = 7'd5;
      7'd55: vfrsqrt7_table = 7'd4;
      7'd56: vfrsqrt7_table = 7'd4;
      7'd57: vfrsqrt7_table = 7'd3;
      7'd58: vfrsqrt7_table = 7'd3;
      7'd59: vfrsqrt7_table = 7'd2;
      7'd60: vfrsqrt7_table = 7'd2;
      7'd61: vfrsqrt7_table = 7'd1;
      7'd62: vfrsqrt7_table = 7'd1;
      7'd63: vfrsqrt7_table = 7'd0;
      7'd64: vfrsqrt7_table = 7'd127;
      7'd65: vfrsqrt7_table = 7'd125;
      7'd66: vfrsqrt7_table = 7'd123;
      7'd67: vfrsqrt7_table = 7'd121;
      7'd68: vfrsqrt7_table = 7'd119;
      7'd69: vfrsqrt7_table = 7'd118;
      7'd70: vfrsqrt7_table = 7'd116;
      7'd71: vfrsqrt7_table = 7'd114;
      7'd72: vfrsqrt7_table = 7'd113;
      7'd73: vfrsqrt7_table = 7'd111;
      7'd74: vfrsqrt7_table = 7'd109;
      7'd75: vfrsqrt7_table = 7'd108;
      7'd76: vfrsqrt7_table = 7'd106;
      7'd77: vfrsqrt7_table = 7'd105;
      7'd78: vfrsqrt7_table = 7'd103;
      7'd79: vfrsqrt7_table = 7'd102;
      7'd80: vfrsqrt7_table = 7'd100;
      7'd81: vfrsqrt7_table = 7'd99;
      7'd82: vfrsqrt7_table = 7'd97;
      7'd83: vfrsqrt7_table = 7'd96;
      7'd84: vfrsqrt7_table = 7'd95;
      7'd85: vfrsqrt7_table = 7'd93;
      7'd86: vfrsqrt7_table = 7'd92;
      7'd87: vfrsqrt7_table = 7'd91;
      7'd88: vfrsqrt7_table = 7'd90;
      7'd89: vfrsqrt7_table = 7'd88;
      7'd90: vfrsqrt7_table = 7'd87;
      7'd91: vfrsqrt7_table = 7'd86;
      7'd92: vfrsqrt7_table = 7'd85;
      7'd93: vfrsqrt7_table = 7'd84;
      7'd94: vfrsqrt7_table = 7'd83;
      7'd95: vfrsqrt7_table = 7'd82;
      7'd96: vfrsqrt7_table = 7'd80;
      7'd97: vfrsqrt7_table = 7'd79;
      7'd98: vfrsqrt7_table = 7'd78;
      7'd99: vfrsqrt7_table = 7'd77;
      7'd100: vfrsqrt7_table = 7'd76;
      7'd101: vfrsqrt7_table = 7'd75;
      7'd102: vfrsqrt7_table = 7'd74;
      7'd103: vfrsqrt7_table = 7'd73;
      7'd104: vfrsqrt7_table = 7'd72;
      7'd105: vfrsqrt7_table = 7'd71;
      7'd106: vfrsqrt7_table = 7'd70;
      7'd107: vfrsqrt7_table = 7'd70;
      7'd108: vfrsqrt7_table = 7'd69;
      7'd109: vfrsqrt7_table = 7'd68;
      7'd110: vfrsqrt7_table = 7'd67;
      7'd111: vfrsqrt7_table = 7'd66;
      7'd112: vfrsqrt7_table = 7'd65;
      7'd113: vfrsqrt7_table = 7'd64;
      7'd114: vfrsqrt7_table = 7'd63;
      7'd115: vfrsqrt7_table = 7'd63;
      7'd116: vfrsqrt7_table = 7'd62;
      7'd117: vfrsqrt7_table = 7'd61;
      7'd118: vfrsqrt7_table = 7'd60;
      7'd119: vfrsqrt7_table = 7'd59;
      7'd120: vfrsqrt7_table = 7'd59;
      7'd121: vfrsqrt7_table = 7'd58;
      7'd122: vfrsqrt7_table = 7'd57;
      7'd123: vfrsqrt7_table = 7'd56;
      7'd124: vfrsqrt7_table = 7'd56;
      7'd125: vfrsqrt7_table = 7'd55;
      7'd126: vfrsqrt7_table = 7'd54;
      7'd127: vfrsqrt7_table = 7'd53;
      default: vfrsqrt7_table = '0;
    endcase
  endfunction

  logic [FRAC:0] significand;
  logic [W-1:0] result_d;
  logic [4:0] flags_d;
  logic finite_overflow;
  always_comb begin
    significand = {1'b1, estimate_q, {(FRAC - 7) {1'b0}}};
    result_d = {sign_q, EXP'(out_exp_q), significand[FRAC-1:0]};
    flags_d = '0;
    finite_overflow = rm_q == 1 || (rm_q == 2 && !sign_q) || (rm_q == 3 && sign_q);
    if (out_exp_q <= 0) begin
      significand = significand >> (1 - out_exp_q);
      result_d = {sign_q, {EXP{1'b0}}, significand[FRAC-1:0]};
    end
    if (out_exp_q > EW'(2 * Bias)) begin
      flags_d = 5'b00101;
      result_d = finite_overflow ?
          {sign_q, EXP'(2 * Bias), {FRAC{1'b1}}} : {sign_q, {EXP{1'b1}}, {FRAC{1'b0}}};
    end
    if (inf_q) begin
      result_d = {sign_q, {(W - 1) {1'b0}}};
      flags_d  = '0;
    end
    if (zero_q) begin
      result_d = {sign_q, {EXP{1'b1}}, {FRAC{1'b0}}};
      flags_d  = 5'b01000;
    end
    if (nan_q || (sqrt_q && sign_q && !zero_q)) begin
      result_d = Nan;
      flags_d  = {snan_q || (sqrt_q && sign_q && !zero_q && !nan_q), 4'b0};
    end
  end
  assign o_ready = state == IDLE;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state   <= IDLE;
      o_valid <= 1'b0;
    end else begin
      o_valid <= 1'b0;
      case (state)
        IDLE:
        if (i_valid) begin
          sign_q <= i_a[W-1];
          sqrt_q <= i_rsqrt;
          rm_q <= i_rm;
          nan_q <= i_a[W-2-:EXP] == '1 && i_a[FRAC-1:0] != '0;
          snan_q <= i_a[W-2-:EXP] == '1 && i_a[FRAC-1:0] != '0 && !i_a[FRAC-1];
          inf_q <= i_a[W-2-:EXP] == '1 && i_a[FRAC-1:0] == '0;
          zero_q <= i_a[W-2:0] == '0;
          exp_q <= i_a[W-2-:EXP] == '0 ? EW'(1) : EW'(i_a[W-2-:EXP]);
          sig_q <= {i_a[W-2-:EXP] != '0, i_a[FRAC-1:0]};
          count_q <= '0;
          state <= NORMALIZE;
        end
        NORMALIZE: begin
          if (!sig_q[FRAC]) begin
            sig_q <= sig_q << 1;
            exp_q <= exp_q - 1;
          end
          count_q <= count_q + 1'b1;
          if (count_q == CW'(FRAC - 1)) state <= LOOKUP;
        end
        LOOKUP: begin
          estimate_q <= sqrt_q ? vfrsqrt7_table(
              {exp_q[0], sig_q[FRAC-1-:6]}
          ) : vfrec7_table(
              sig_q[FRAC-1-:7]
          );
          out_exp_q <= sqrt_q ? ((EW'(3 * Bias - 1) - exp_q) >>> 1) : (EW'(2 * Bias - 1) - exp_q);
          state <= PACK;
        end
        PACK: begin
          o_result <= result_d;
          o_flags <= flags_d;
          state <= OUTPUT;
        end
        OUTPUT: begin
          o_valid <= 1'b1;
          state   <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule

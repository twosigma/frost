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
  The AES block of the vector unit (Zvkned) for one 128-bit element group:
  vaesef, vaesem, vaesdf, vaesdm and vaesz on state i_state (vd) with round key
  i_key (vs2), and the key-schedule steps vaeskf1 (AES-128: next round key from
  i_key and round i_rnd) and vaeskf2 (AES-256: next round key from i_state, the
  key two rounds back, and i_key, the previous one). Byte j of the group is
  AES state byte j (column j/4, row j%4); key words are 32-bit little-endian.
  Round numbers outside 1..10 (vaeskf1) or 2..14 (vaeskf2) are replaced by the
  number with bit 3 inverted, as the specification requires.

  S-box lookups take the first cycle; ShiftRows, the key-schedule words and
  the round-key addition the second; MixColumns (followed by the round key,
  as vaesem orders them) or InvMixColumns (after the round key, as vaesdm
  orders them) the third. The
  result appears a fixed three cycles after the cycle that takes the input, for
  every operation and value, so the timing is independent of the data
  (Zvkt).
*/
module vec_aes_group
  import vec_pkg::*;
(
    input  logic            i_clk,
    input  logic            i_rst,
    input  logic            i_valid,
    input  aes_op_e         i_op,
    input  logic    [  3:0] i_rnd,
    input  logic    [127:0] i_state,
    input  logic    [127:0] i_key,
    output logic            o_valid,
    output logic    [127:0] o_result
);

  localparam logic [7:0] Sbox[256] = '{
      8'h63,
      8'h7c,
      8'h77,
      8'h7b,
      8'hf2,
      8'h6b,
      8'h6f,
      8'hc5,
      8'h30,
      8'h01,
      8'h67,
      8'h2b,
      8'hfe,
      8'hd7,
      8'hab,
      8'h76,
      8'hca,
      8'h82,
      8'hc9,
      8'h7d,
      8'hfa,
      8'h59,
      8'h47,
      8'hf0,
      8'had,
      8'hd4,
      8'ha2,
      8'haf,
      8'h9c,
      8'ha4,
      8'h72,
      8'hc0,
      8'hb7,
      8'hfd,
      8'h93,
      8'h26,
      8'h36,
      8'h3f,
      8'hf7,
      8'hcc,
      8'h34,
      8'ha5,
      8'he5,
      8'hf1,
      8'h71,
      8'hd8,
      8'h31,
      8'h15,
      8'h04,
      8'hc7,
      8'h23,
      8'hc3,
      8'h18,
      8'h96,
      8'h05,
      8'h9a,
      8'h07,
      8'h12,
      8'h80,
      8'he2,
      8'heb,
      8'h27,
      8'hb2,
      8'h75,
      8'h09,
      8'h83,
      8'h2c,
      8'h1a,
      8'h1b,
      8'h6e,
      8'h5a,
      8'ha0,
      8'h52,
      8'h3b,
      8'hd6,
      8'hb3,
      8'h29,
      8'he3,
      8'h2f,
      8'h84,
      8'h53,
      8'hd1,
      8'h00,
      8'hed,
      8'h20,
      8'hfc,
      8'hb1,
      8'h5b,
      8'h6a,
      8'hcb,
      8'hbe,
      8'h39,
      8'h4a,
      8'h4c,
      8'h58,
      8'hcf,
      8'hd0,
      8'hef,
      8'haa,
      8'hfb,
      8'h43,
      8'h4d,
      8'h33,
      8'h85,
      8'h45,
      8'hf9,
      8'h02,
      8'h7f,
      8'h50,
      8'h3c,
      8'h9f,
      8'ha8,
      8'h51,
      8'ha3,
      8'h40,
      8'h8f,
      8'h92,
      8'h9d,
      8'h38,
      8'hf5,
      8'hbc,
      8'hb6,
      8'hda,
      8'h21,
      8'h10,
      8'hff,
      8'hf3,
      8'hd2,
      8'hcd,
      8'h0c,
      8'h13,
      8'hec,
      8'h5f,
      8'h97,
      8'h44,
      8'h17,
      8'hc4,
      8'ha7,
      8'h7e,
      8'h3d,
      8'h64,
      8'h5d,
      8'h19,
      8'h73,
      8'h60,
      8'h81,
      8'h4f,
      8'hdc,
      8'h22,
      8'h2a,
      8'h90,
      8'h88,
      8'h46,
      8'hee,
      8'hb8,
      8'h14,
      8'hde,
      8'h5e,
      8'h0b,
      8'hdb,
      8'he0,
      8'h32,
      8'h3a,
      8'h0a,
      8'h49,
      8'h06,
      8'h24,
      8'h5c,
      8'hc2,
      8'hd3,
      8'hac,
      8'h62,
      8'h91,
      8'h95,
      8'he4,
      8'h79,
      8'he7,
      8'hc8,
      8'h37,
      8'h6d,
      8'h8d,
      8'hd5,
      8'h4e,
      8'ha9,
      8'h6c,
      8'h56,
      8'hf4,
      8'hea,
      8'h65,
      8'h7a,
      8'hae,
      8'h08,
      8'hba,
      8'h78,
      8'h25,
      8'h2e,
      8'h1c,
      8'ha6,
      8'hb4,
      8'hc6,
      8'he8,
      8'hdd,
      8'h74,
      8'h1f,
      8'h4b,
      8'hbd,
      8'h8b,
      8'h8a,
      8'h70,
      8'h3e,
      8'hb5,
      8'h66,
      8'h48,
      8'h03,
      8'hf6,
      8'h0e,
      8'h61,
      8'h35,
      8'h57,
      8'hb9,
      8'h86,
      8'hc1,
      8'h1d,
      8'h9e,
      8'he1,
      8'hf8,
      8'h98,
      8'h11,
      8'h69,
      8'hd9,
      8'h8e,
      8'h94,
      8'h9b,
      8'h1e,
      8'h87,
      8'he9,
      8'hce,
      8'h55,
      8'h28,
      8'hdf,
      8'h8c,
      8'ha1,
      8'h89,
      8'h0d,
      8'hbf,
      8'he6,
      8'h42,
      8'h68,
      8'h41,
      8'h99,
      8'h2d,
      8'h0f,
      8'hb0,
      8'h54,
      8'hbb,
      8'h16
  };

  localparam logic [7:0] InvSbox[256] = '{
      8'h52,
      8'h09,
      8'h6a,
      8'hd5,
      8'h30,
      8'h36,
      8'ha5,
      8'h38,
      8'hbf,
      8'h40,
      8'ha3,
      8'h9e,
      8'h81,
      8'hf3,
      8'hd7,
      8'hfb,
      8'h7c,
      8'he3,
      8'h39,
      8'h82,
      8'h9b,
      8'h2f,
      8'hff,
      8'h87,
      8'h34,
      8'h8e,
      8'h43,
      8'h44,
      8'hc4,
      8'hde,
      8'he9,
      8'hcb,
      8'h54,
      8'h7b,
      8'h94,
      8'h32,
      8'ha6,
      8'hc2,
      8'h23,
      8'h3d,
      8'hee,
      8'h4c,
      8'h95,
      8'h0b,
      8'h42,
      8'hfa,
      8'hc3,
      8'h4e,
      8'h08,
      8'h2e,
      8'ha1,
      8'h66,
      8'h28,
      8'hd9,
      8'h24,
      8'hb2,
      8'h76,
      8'h5b,
      8'ha2,
      8'h49,
      8'h6d,
      8'h8b,
      8'hd1,
      8'h25,
      8'h72,
      8'hf8,
      8'hf6,
      8'h64,
      8'h86,
      8'h68,
      8'h98,
      8'h16,
      8'hd4,
      8'ha4,
      8'h5c,
      8'hcc,
      8'h5d,
      8'h65,
      8'hb6,
      8'h92,
      8'h6c,
      8'h70,
      8'h48,
      8'h50,
      8'hfd,
      8'hed,
      8'hb9,
      8'hda,
      8'h5e,
      8'h15,
      8'h46,
      8'h57,
      8'ha7,
      8'h8d,
      8'h9d,
      8'h84,
      8'h90,
      8'hd8,
      8'hab,
      8'h00,
      8'h8c,
      8'hbc,
      8'hd3,
      8'h0a,
      8'hf7,
      8'he4,
      8'h58,
      8'h05,
      8'hb8,
      8'hb3,
      8'h45,
      8'h06,
      8'hd0,
      8'h2c,
      8'h1e,
      8'h8f,
      8'hca,
      8'h3f,
      8'h0f,
      8'h02,
      8'hc1,
      8'haf,
      8'hbd,
      8'h03,
      8'h01,
      8'h13,
      8'h8a,
      8'h6b,
      8'h3a,
      8'h91,
      8'h11,
      8'h41,
      8'h4f,
      8'h67,
      8'hdc,
      8'hea,
      8'h97,
      8'hf2,
      8'hcf,
      8'hce,
      8'hf0,
      8'hb4,
      8'he6,
      8'h73,
      8'h96,
      8'hac,
      8'h74,
      8'h22,
      8'he7,
      8'had,
      8'h35,
      8'h85,
      8'he2,
      8'hf9,
      8'h37,
      8'he8,
      8'h1c,
      8'h75,
      8'hdf,
      8'h6e,
      8'h47,
      8'hf1,
      8'h1a,
      8'h71,
      8'h1d,
      8'h29,
      8'hc5,
      8'h89,
      8'h6f,
      8'hb7,
      8'h62,
      8'h0e,
      8'haa,
      8'h18,
      8'hbe,
      8'h1b,
      8'hfc,
      8'h56,
      8'h3e,
      8'h4b,
      8'hc6,
      8'hd2,
      8'h79,
      8'h20,
      8'h9a,
      8'hdb,
      8'hc0,
      8'hfe,
      8'h78,
      8'hcd,
      8'h5a,
      8'hf4,
      8'h1f,
      8'hdd,
      8'ha8,
      8'h33,
      8'h88,
      8'h07,
      8'hc7,
      8'h31,
      8'hb1,
      8'h12,
      8'h10,
      8'h59,
      8'h27,
      8'h80,
      8'hec,
      8'h5f,
      8'h60,
      8'h51,
      8'h7f,
      8'ha9,
      8'h19,
      8'hb5,
      8'h4a,
      8'h0d,
      8'h2d,
      8'he5,
      8'h7a,
      8'h9f,
      8'h93,
      8'hc9,
      8'h9c,
      8'hef,
      8'ha0,
      8'he0,
      8'h3b,
      8'h4d,
      8'hae,
      8'h2a,
      8'hf5,
      8'hb0,
      8'hc8,
      8'heb,
      8'hbb,
      8'h3c,
      8'h83,
      8'h53,
      8'h99,
      8'h61,
      8'h17,
      8'h2b,
      8'h04,
      8'h7e,
      8'hba,
      8'h77,
      8'hd6,
      8'h26,
      8'he1,
      8'h69,
      8'h14,
      8'h63,
      8'h55,
      8'h21,
      8'h0c,
      8'h7d
  };

  function automatic logic [7:0] xtime(input logic [7:0] x);
    xtime = {x[6:0], 1'b0} ^ (x[7] ? 8'h1b : 8'h00);
  endfunction

  function automatic logic [7:0] rcon(input logic [3:0] i);
    unique case (i)
      4'd0: rcon = 8'h01;
      4'd1: rcon = 8'h02;
      4'd2: rcon = 8'h04;
      4'd3: rcon = 8'h08;
      4'd4: rcon = 8'h10;
      4'd5: rcon = 8'h20;
      4'd6: rcon = 8'h40;
      4'd7: rcon = 8'h80;
      4'd8: rcon = 8'h1b;
      4'd9: rcon = 8'h36;
      default: rcon = 8'h00;
    endcase
  endfunction

  // Stage 0: input registers.
  logic s0_valid;
  aes_op_e s0_op;
  logic [3:0] s0_rnd;
  logic [127:0] s0_state, s0_key;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_op <= i_op;
    s0_state <= i_state;
    s0_key <= i_key;
    // Out-of-range round numbers have bit 3 inverted.
    if (i_op == VA_KF1) s0_rnd <= (i_rnd == 4'd0 || i_rnd > 4'd10) ? (i_rnd ^ 4'd8) : i_rnd;
    else s0_rnd <= (i_rnd < 4'd2 || i_rnd > 4'd14) ? (i_rnd ^ 4'd8) : i_rnd;
  end

  // Stage 1: forward and inverse S-boxes of the state, and of key word 3.
  logic [127:0] sub_fwd, sub_inv;
  logic [31:0] key_sub;
  always_comb begin
    for (int j = 0; j < 16; j++) begin
      sub_fwd[8*j+:8] = Sbox[s0_state[8*j+:8]];
      sub_inv[8*j+:8] = InvSbox[s0_state[8*j+:8]];
    end
    for (int j = 0; j < 4; j++) key_sub[8*j+:8] = Sbox[s0_key[96+8*j+:8]];
  end

  logic s1_valid;
  aes_op_e s1_op;
  logic [3:0] s1_rnd;
  logic [127:0] s1_state, s1_key, s1_fwd, s1_inv;
  logic [31:0] s1_key_sub;
  always_ff @(posedge i_clk) begin
    if (i_rst) s1_valid <= 1'b0;
    else s1_valid <= s0_valid;
    s1_op <= s0_op;
    s1_rnd <= s0_rnd;
    s1_state <= s0_state;
    s1_key <= s0_key;
    s1_fwd <= sub_fwd;
    s1_inv <= sub_inv;
    s1_key_sub <= key_sub;
  end

  // Stage 2: ShiftRows (row r moves left by r for encryption, right for
  // decryption), the key schedule, and the round-key addition.
  logic [127:0] shifted, added, sched;
  always_comb begin
    for (int c = 0; c < 4; c++)
    for (int r = 0; r < 4; r++) begin
      if (s1_op == VA_DF || s1_op == VA_DM) shifted[8*(4*c+r)+:8] = s1_inv[8*(4*((c+4-r)%4)+r)+:8];
      else shifted[8*(4*c+r)+:8] = s1_fwd[8*(4*((c+r)%4)+r)+:8];
    end
    added = ((s1_op == VA_Z) ? s1_state : shifted) ^ s1_key;
  end
  always_comb begin
    logic [31:0] t, w0, w1, w2, w3;
    logic [127:0] prev;
    logic [ 31:0] rot;
    // RotWord on a little-endian word moves byte 1 to byte 0.
    rot = {s1_key_sub[7:0], s1_key_sub[31:8]};
    // vaeskf1 builds on the current key; vaeskf2 on the key two rounds back
    // (vd). Even vaeskf2 rounds rotate and add Rcon, odd ones only
    // substitute.
    if (s1_op == VA_KF1) begin
      t = rot ^ {24'b0, rcon(s1_rnd - 4'd1)};
      prev = s1_key;
    end else begin
      t = s1_rnd[0] ? s1_key_sub : (rot ^ {24'b0, rcon((s1_rnd >> 1) - 4'd1)});
      prev = s1_state;
    end
    w0 = prev[31:0] ^ t;
    w1 = prev[63:32] ^ w0;
    w2 = prev[95:64] ^ w1;
    w3 = prev[127:96] ^ w2;
    sched = {w3, w2, w1, w0};
  end

  logic s2_valid;
  aes_op_e s2_op;
  logic [127:0] s2_shifted, s2_key, s2_added, s2_sched;
  always_ff @(posedge i_clk) begin
    if (i_rst) s2_valid <= 1'b0;
    else s2_valid <= s1_valid;
    s2_op <= s1_op;
    s2_shifted <= shifted;
    s2_key <= s1_key;
    s2_added <= added;
    s2_sched <= sched;
  end

  // Stage 3: MixColumns of the shifted state, then the round key, for
  // vaesem; InvMixColumns of the key-added state for vaesdm.
  logic [127:0] mixed, inv_mixed;
  always_comb begin
    for (int c = 0; c < 4; c++) begin
      logic [7:0] e0, e1, e2, e3, f0, f1, f2, f3;
      e0 = s2_shifted[32*c+:8];
      e1 = s2_shifted[32*c+8+:8];
      e2 = s2_shifted[32*c+16+:8];
      e3 = s2_shifted[32*c+24+:8];
      f0 = xtime(e0);
      f1 = xtime(e1);
      f2 = xtime(e2);
      f3 = xtime(e3);
      mixed[32*c+:8] = f0 ^ f1 ^ e1 ^ e2 ^ e3 ^ s2_key[32*c+:8];
      mixed[32*c+8+:8] = e0 ^ f1 ^ f2 ^ e2 ^ e3 ^ s2_key[32*c+8+:8];
      mixed[32*c+16+:8] = e0 ^ e1 ^ f2 ^ f3 ^ e3 ^ s2_key[32*c+16+:8];
      mixed[32*c+24+:8] = f0 ^ e0 ^ e1 ^ e2 ^ f3 ^ s2_key[32*c+24+:8];
    end
    for (int c = 0; c < 4; c++) begin
      logic [7:0] a0, a1, a2, a3;
      logic [7:0] x0, x1, x2, x3, y0, y1, y2, y3, z0, z1, z2, z3;
      a0 = s2_added[32*c+:8];
      a1 = s2_added[32*c+8+:8];
      a2 = s2_added[32*c+16+:8];
      a3 = s2_added[32*c+24+:8];
      x0 = xtime(a0);
      x1 = xtime(a1);
      x2 = xtime(a2);
      x3 = xtime(a3);
      // Multiples 4a and 8a for the inverse coefficients 9, 11, 13, 14.
      y0 = xtime(x0);
      y1 = xtime(x1);
      y2 = xtime(x2);
      y3 = xtime(x3);
      z0 = xtime(y0);
      z1 = xtime(y1);
      z2 = xtime(y2);
      z3 = xtime(y3);
      // 14 = 8+4+2, 11 = 8+2+1, 13 = 8+4+1, 9 = 8+1
      inv_mixed[32*c+:8] = (z0 ^ y0 ^ x0) ^ (z1 ^ x1 ^ a1) ^ (z2 ^ y2 ^ a2) ^ (z3 ^ a3);
      inv_mixed[32*c+8+:8] = (z0 ^ a0) ^ (z1 ^ y1 ^ x1) ^ (z2 ^ x2 ^ a2) ^ (z3 ^ y3 ^ a3);
      inv_mixed[32*c+16+:8] = (z0 ^ y0 ^ a0) ^ (z1 ^ a1) ^ (z2 ^ y2 ^ x2) ^ (z3 ^ x3 ^ a3);
      inv_mixed[32*c+24+:8] = (z0 ^ x0 ^ a0) ^ (z1 ^ y1 ^ a1) ^ (z2 ^ a2) ^ (z3 ^ y3 ^ x3);
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s2_valid;
    unique case (s2_op)
      VA_EM: o_result <= mixed;
      VA_DM: o_result <= inv_mixed;
      VA_KF1, VA_KF2: o_result <= s2_sched;
      default: o_result <= s2_added;  // VA_EF, VA_DF, VA_Z
    endcase
  end

endmodule

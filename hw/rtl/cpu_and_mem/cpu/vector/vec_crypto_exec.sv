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

// Committed Zvbc and AES/SHA2/GHASH execution. Four element transfers gather
// a complete crypto group before any write, including SHA-512 across two
// registers at VLEN128. Setting VRF_REG_DATA=1 accommodates an extra VRF
// output register stage in vec_engine. Every operation has data-independent
// execution time.
module vec_crypto_exec #(
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
    output logic o_idle,
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
    NEXT_WORD,
    LAUNCH,
    WAIT_RESULT,
    FORMAT,
    WRITE,
    ADVANCE
  } state_e;
  state_e state;
  logic [31:0] insn_q;
  logic [1:0] sew_q, word_q;
  logic [15:0] vl_q, idx_q;
  logic [63:0] scalar_q;
  logic [VLEN-1:0] mask_q;
  logic [2:0][VLEN-1:0] regs_q;
  logic [3:0][4:0] raddr_q;
  logic [255:0] a_q, b_q, d_q, result_q;
  logic clmul, scalar_key, sha, ghash, active;
  // An LMUL group spans at most eight registers. OP-VE starts on a
  // four-element boundary, so its word index supplies the low two bits.
  localparam int unsigned AddrBits = ByteBits + 3;
  logic [AddrBits-1:0] byte_index;
  logic [AddrBits-3:0] element;
  logic [ByteBits-3:0] key_word;
  logic [63:0] write_word;
  logic [5:0] f6;
  logic [4:0] vd, vs1, vs2;
  assign f6 = insn_q[31:26];
  assign vd = insn_q[11:7];
  assign vs1 = insn_q[19:15];
  assign vs2 = insn_q[24:20];
  assign clmul = insn_q[6:0] == 7'h57;
  assign scalar_key = !clmul && f6 == 6'h29;
  assign sha = !clmul && f6 >= 6'h2d;
  assign ghash = !clmul && (f6 == 6'h2c || (f6 == 6'h28 && vs1 == 17));
  assign element = clmul ? idx_q[AddrBits-3:0] : {idx_q[AddrBits-3:2], word_q};
  assign byte_index = (sew_q == 3) ? {element[AddrBits-4:0], 3'b0} : {element, 2'b0};
  assign key_word = scalar_key ? (ByteBits - 2)'(word_q) : byte_index[ByteBits-1:2];
  assign write_word = (sew_q == 3) ? result_q[64*word_q+:64] : 64'(result_q[32*word_q+:32]);
  assign active = !clmul || insn_q[25] || mask_q[MaskBits'(idx_q)];
  assign o_raddr = raddr_q;
  vec_pkg::aes_op_e aes_op;
  vec_pkg::sha_op_e sha_op;
  always_comb begin
    aes_op = vec_pkg::VA_DM;
    if (f6 == 6'h22) aes_op = vec_pkg::VA_KF1;
    else if (f6 == 6'h2a) aes_op = vec_pkg::VA_KF2;
    else
      case (vs1)
        1: aes_op = vec_pkg::VA_DF;
        2: aes_op = vec_pkg::VA_EM;
        3: aes_op = vec_pkg::VA_EF;
        7: aes_op = vec_pkg::VA_Z;
        default: ;
      endcase
    sha_op = f6 == 6'h2d ? vec_pkg::VS_MS : f6 == 6'h2e ? vec_pkg::VS_CH : vec_pkg::VS_CL;
  end
  logic av, sv, gv, cv;
  logic [127:0] ar, gr;
  logic [255:0] sr;
  logic [ 63:0] cr;
  vec_aes_group u_aes (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && !clmul && !sha && !ghash),
      .i_op(aes_op),
      .i_rnd(vs1[3:0]),
      .i_state(d_q[127:0]),
      .i_key(a_q[127:0]),
      .o_valid(av),
      .o_result(ar)
  );
  vec_sha2_group u_sha (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && sha),
      .i_op(sha_op),
      .i_sew64(sew_q == 3),
      .i_vd(d_q),
      .i_vs2(a_q),
      .i_vs1(b_q),
      .o_valid(sv),
      .o_result(sr)
  );
  vec_ghash_group u_ghash (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && ghash),
      .i_gmul(f6 == 6'h28),
      .i_vd(d_q[127:0]),
      .i_vs2(a_q[127:0]),
      .i_vs1(b_q[127:0]),
      .o_valid(gv),
      .o_result(gr)
  );
  vec_clmul_lane u_clmul (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(state == LAUNCH && clmul),
      .i_high(f6[0]),
      .i_a(a_q[63:0]),
      .i_b(insn_q[14:12] == 6 ? scalar_q : b_q[63:0]),
      .o_valid(cv),
      .o_result(cr),
      .o_product()
  );
  assign o_idle = state == IDLE;
  assign o_we   = state == WRITE && active;

  // Control state machine (reset-bearing flop only).
  always_ff @(posedge i_clk) begin
    if (i_rst) state <= IDLE;
    else
      case (state)
        IDLE: if (i_valid) state <= PRE;
        PRE: state <= VRF_REG_DATA ? PRE2 : SNAP;
        PRE2: state <= SNAP;
        SNAP: state <= ADDRESS;
        ADDRESS: state <= idx_q >= vl_q ? IDLE : READ;
        READ: state <= VRF_REG_DATA ? READ2 : CAPTURE;
        READ2: state <= CAPTURE;
        CAPTURE: state <= EXTRACT;
        EXTRACT: state <= NEXT_WORD;
        NEXT_WORD: state <= (clmul || word_q == 3) ? LAUNCH : ADDRESS;
        LAUNCH: state <= WAIT_RESULT;
        WAIT_RESULT: if (av || sv || gv || cv) state <= FORMAT;
        FORMAT: state <= WRITE;
        WRITE: state <= (clmul || word_q == 3) ? ADVANCE : FORMAT;
        ADVANCE: state <= ADDRESS;
        default: state <= IDLE;
      endcase
  end

  // Reset-free datapath registers (no i_rst fanout on wide datapath flops).
  always_ff @(posedge i_clk) begin
    case (state)
      IDLE:
      if (i_valid) begin
        insn_q <= i_insn;
        sew_q <= i_sew;
        vl_q <= i_vl;
        idx_q <= i_vstart;
        scalar_q <= i_scalar;
        word_q <= 0;
        raddr_q[0] <= i_insn[24:20];
        raddr_q[1] <= i_insn[19:15];
        raddr_q[2] <= i_insn[11:7];
        raddr_q[3] <= 5'd0;
      end
      SNAP: mask_q <= i_rdata[3];
      ADDRESS: begin
        raddr_q[0] <= scalar_key ? vs2 : (vs2 + 5'(byte_index >> ByteBits));
        raddr_q[1] <= vs1 + 5'(byte_index >> ByteBits);
        raddr_q[2] <= vd + 5'(byte_index >> ByteBits);
        raddr_q[3] <= 5'd0;
      end
      CAPTURE: regs_q <= i_rdata[2:0];
      EXTRACT: begin
        if (sew_q == 3) begin
          a_q[64*word_q+:64] <= regs_q[0][64*byte_index[ByteBits-1:3]+:64];
          b_q[64*word_q+:64] <= regs_q[1][64*byte_index[ByteBits-1:3]+:64];
          d_q[64*word_q+:64] <= regs_q[2][64*byte_index[ByteBits-1:3]+:64];
        end else begin
          a_q[32*word_q+:32] <= regs_q[0][32*key_word+:32];
          b_q[32*word_q+:32] <= regs_q[1][32*byte_index[ByteBits-1:2]+:32];
          d_q[32*word_q+:32] <= regs_q[2][32*byte_index[ByteBits-1:2]+:32];
        end
      end
      NEXT_WORD: word_q <= (clmul || word_q == 3) ? 2'd0 : (word_q + 2'd1);
      WAIT_RESULT:
      if (av || sv || gv || cv) begin
        result_q <= cv ? 256'(cr) : gv ? 256'(gr) : av ? 256'(ar) : sr;
      end
      FORMAT: begin
        o_waddr <= vd + 5'(byte_index >> ByteBits);
        // Replicate the word across the port. Only the addressed 32- or
        // 64-bit slice has its byte enables set.
        for (int k = 0; k < VLEN / 32; k++) begin
          o_wdata[32*k+:32] <= (sew_q == 3 && k % 2 == 1) ? write_word[63:32] : write_word[31:0];
          o_wbe[4*k+:4] <= {4{(sew_q == 3) ? (int'(byte_index[ByteBits-1:3]) == k/2) :
              (int'(byte_index[ByteBits-1:2]) == k)}};
        end
      end
      WRITE: word_q <= word_q + 2'd1;
      ADVANCE: begin
        word_q <= 0;
        idx_q  <= idx_q + (clmul ? 16'd1 : 16'd4);
      end
      default: ;
    endcase
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // The element index above takes its low two bits from the word counter, so
  // an OP-VE accepted with vl or vstart off a four-element boundary would write
  // a whole group across the boundary. The ROB head traps that case; these
  // checks catch an operand that reaches the engine without passing it.
  logic crypto_reset_seen_q = 1'b0;
  logic [15:0] vstart_chk_q, write_element;
  logic [5:0] f6_in;
  assign f6_in = i_insn[31:26];
  assign write_element = clmul ? idx_q : {idx_q[15:2], word_q};
  always @(posedge i_clk) begin
    if (i_rst) crypto_reset_seen_q <= 1'b1;
    if (state == IDLE && i_valid) vstart_chk_q <= i_vstart;
    if (crypto_reset_seen_q && !i_rst) begin
      if (state == IDLE && i_valid) begin
        if (i_insn[6:0] == 7'h57) begin
          assert (i_sew == 2'd3)
          else $error("vec_crypto_exec: carry-less multiply accepted at SEW %0d", 8 << i_sew);
        end else begin
          assert (i_vl[1:0] == 2'b00 && i_vstart[1:0] == 2'b00)
          else
            $error(
                "vec_crypto_exec: element group accepted with vl %0d, vstart %0d", i_vl, i_vstart
            );
          assert ((f6_in >= 6'h2d) ? (i_sew >= 2'd2) : (i_sew == 2'd2))
          else $error("vec_crypto_exec: funct6 %0h accepted at SEW %0d", f6_in, 8 << i_sew);
        end
      end
      if (o_we) begin
        assert (write_element >= vstart_chk_q && write_element < vl_q)
        else
          $error(
              "vec_crypto_exec: element %0d written outside vstart %0d to vl %0d",
              write_element,
              vstart_chk_q,
              vl_q
          );
        // Dispatch rejects a .vs or vaesz.vs destination group that holds the
        // key register; each group reads the key again.
        assert (!scalar_key || o_waddr != vs2)
        else $error("vec_crypto_exec: write to key register v%0d", vs2);
      end
    end
  end
`endif
`endif
endmodule

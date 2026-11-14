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
  The vector engine's first form: it executes committed vector instructions
  one at a time, element group by element group (DLEN = VLEN, so a group is
  one vector register), with no overlap between instructions. Correctness
  comes first; chaining and overlap come later.

  It takes an instruction with the vl, vtype and vstart it executes under and
  its scalar operand (rs1's value), and raises o_idle when it has finished.
  Supported so far: the single-width integer arithmetic, logical, minimum and
  maximum, shift and Zvbb rotate operations (.vv, .vx, .vi), the integer
  compares into a mask register, vmerge and vmv.v.*, vandn, and the Zvbb
  unary operations (vbrev8, vrev8, vbrev, vclz, vctz, vcpop.v). o_unsupported
  pulses for anything else, which the front end never sends.

  Masking and the tail use the register file's byte enables: only active body
  elements (vstart <= i < vl, and v0[i] set when masked) are written, so tail
  and inactive elements stay undisturbed, which both policies allow. Compares
  build their mask in a register from the old destination, set one bit per
  active body element, and write it once at the end.

  Two ports serve the memory side (and a bench): a read of one register
  (registered, one cycle) and a byte-enabled write of one register.
*/
module vec_engine #(
    parameter  int unsigned VLEN  = 256,
    localparam int unsigned Lanes = VLEN / 64,
    localparam int unsigned Bytes = VLEN / 8
) (
    input  logic             i_clk,
    input  logic             i_rst,
    input  logic             i_valid,
    output logic             o_idle,
    input  logic [     31:0] i_insn,
    input  logic [      2:0] i_vsew,
    input  logic [      2:0] i_vlmul,
    input  logic [     15:0] i_vl,
    input  logic [     15:0] i_vstart,
    input  logic [     63:0] i_rs1,
    output logic             o_unsupported,
    // Memory-side ports
    input  logic [      4:0] i_xr_addr,
    output logic [ VLEN-1:0] o_xr_data,
    input  logic             i_xw_en,
    input  logic [      4:0] i_xw_addr,
    input  logic [ VLEN-1:0] i_xw_data,
    input  logic [Bytes-1:0] i_xw_be
);

  // --------------------------------------------------------------------------
  // Register file: reads 0 vs2, 1 vs1, 2 old vd, 3 v0, 4 memory side;
  // writes 0 engine, 1 memory side.
  // --------------------------------------------------------------------------
  logic [1:0] rf_we;
  logic [1:0][4:0] rf_waddr;
  logic [1:0][VLEN-1:0] rf_wdata;
  logic [1:0][Bytes-1:0] rf_wbe;
  logic [4:0][4:0] rf_raddr;
  logic [4:0][VLEN-1:0] rf_rdata;
  vec_vrf #(
      .DEPTH(32),
      .WIDTH(VLEN),
      .NR(5),
      .NW(2)
  ) u_vrf (
      .i_clk  (i_clk),
      .i_we   (rf_we),
      .i_waddr(rf_waddr),
      .i_wdata(rf_wdata),
      .i_wbe  (rf_wbe),
      .i_raddr(rf_raddr),
      .o_rdata(rf_rdata)
  );
  assign rf_raddr[4] = i_xr_addr;
  assign o_xr_data   = rf_rdata[4];
  assign rf_we[1]    = i_xw_en;
  assign rf_waddr[1] = i_xw_addr;
  assign rf_wdata[1] = i_xw_data;
  assign rf_wbe[1]   = i_xw_be;

  // --------------------------------------------------------------------------
  // Decode
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_PRE,   // read v0 and the old destination
    S_PRE2,  // capture them
    S_RD,    // read group g's sources
    S_EX,    // lanes running; their result is captured when they finish
    S_WR,    // write group g from registers
    S_MWR    // write a compare's mask
  } state_e;
  state_e state;

  logic [31:0] insn_q;
  logic [1:0] sew_q;
  logic [3:0] groups_q;  // registers in the group
  logic [15:0] vl_q, vstart_q;
  logic [63:0] scalar_q;  // replicated per element at SEW
  vec_pkg::int_op_e op_q;
  logic mask_dest_q, use_scalar_q, masked_q, merge_q, unary_q;
  logic [3:0] g_q;
  logic [2:0] ex_cnt_q;

  wire [5:0] funct6 = i_insn[31:26];
  wire [2:0] funct3 = i_insn[14:12];
  wire vm_bit = i_insn[25];
  wire [4:0] f_vs1 = i_insn[19:15];

  // Decode an instruction: {supported, op, mask_dest, unary, uimm}.
  logic d_ok, d_mask_dest, d_unary, d_uimm, d_imm6;
  vec_pkg::int_op_e d_op;
  always_comb begin
    d_ok = 1'b0;
    d_op = vec_pkg::VI_ADD;
    d_mask_dest = 1'b0;
    d_unary = 1'b0;
    d_uimm = 1'b0;
    d_imm6 = 1'b0;
    if (i_insn[6:0] == 7'b1010111) begin
      if (funct3 == 3'b000 || funct3 == 3'b100 || funct3 == 3'b011) begin
        d_ok = 1'b1;
        unique casez (funct6)
          6'b000000: d_op = vec_pkg::VI_ADD;
          6'b000001: d_op = vec_pkg::VI_ANDN;
          6'b000010: d_op = vec_pkg::VI_SUB;
          6'b000011: d_op = vec_pkg::VI_RSUB;
          6'b000100: d_op = vec_pkg::VI_MINU;
          6'b000101: d_op = vec_pkg::VI_MIN;
          6'b000110: d_op = vec_pkg::VI_MAXU;
          6'b000111: d_op = vec_pkg::VI_MAX;
          6'b001001: d_op = vec_pkg::VI_AND;
          6'b001010: d_op = vec_pkg::VI_OR;
          6'b001011: d_op = vec_pkg::VI_XOR;
          6'b010100: begin
            d_op   = vec_pkg::VI_ROR;
            d_uimm = 1'b1;
          end
          6'b010101: begin
            // vrol.vv/.vx; with .vi it is vror.vi with imm[5] set
            d_op   = (funct3 == 3'b011) ? vec_pkg::VI_ROR : vec_pkg::VI_ROL;
            d_uimm = 1'b1;
            d_imm6 = (funct3 == 3'b011);
          end
          6'b010111: d_op = vm_bit ? vec_pkg::VI_MV : vec_pkg::VI_MERGE;
          6'b011000: d_op = vec_pkg::VI_MSEQ;
          6'b011001: d_op = vec_pkg::VI_MSNE;
          6'b011010: d_op = vec_pkg::VI_MSLTU;
          6'b011011: d_op = vec_pkg::VI_MSLT;
          6'b011100: d_op = vec_pkg::VI_MSLEU;
          6'b011101: d_op = vec_pkg::VI_MSLE;
          6'b011110: d_op = vec_pkg::VI_MSGTU;
          6'b011111: d_op = vec_pkg::VI_MSGT;
          6'b100101: begin
            d_op   = vec_pkg::VI_SLL;
            d_uimm = 1'b1;
          end
          6'b101000: begin
            d_op   = vec_pkg::VI_SRL;
            d_uimm = 1'b1;
          end
          6'b101001: begin
            d_op   = vec_pkg::VI_SRA;
            d_uimm = 1'b1;
          end
          default:   d_ok = 1'b0;
        endcase
        d_mask_dest = (funct6[5:3] == 3'b011);
        if (funct6 == 6'b010100 && funct3 == 3'b011) d_imm6 = 1'b0;
      end else if (funct3 == 3'b010 && funct6 == 6'b010010) begin
        d_unary = 1'b1;
        d_ok = 1'b1;
        unique case (f_vs1)
          5'b01000: d_op = vec_pkg::VI_BREV8;
          5'b01001: d_op = vec_pkg::VI_REV8;
          5'b01010: d_op = vec_pkg::VI_BREV;
          5'b01100: d_op = vec_pkg::VI_CLZ;
          5'b01101: d_op = vec_pkg::VI_CTZ;
          5'b01110: d_op = vec_pkg::VI_CPOP;
          default:  d_ok = 1'b0;
        endcase
      end
    end
  end

  // The scalar operand at SEW, replicated across a 64-bit lane.
  function automatic logic [63:0] replicate(input logic [63:0] x, input logic [1:0] sew);
    unique case (sew)
      2'd0: replicate = {8{x[7:0]}};
      2'd1: replicate = {4{x[15:0]}};
      2'd2: replicate = {2{x[31:0]}};
      default: replicate = x;
    endcase
  endfunction

  logic [63:0] d_scalar;
  always_comb begin
    if (funct3 == 3'b011) begin
      if (d_uimm) d_scalar = 64'({d_imm6 ? i_insn[26] : 1'b0, i_insn[19:15]});
      else d_scalar = {{59{i_insn[19]}}, i_insn[19:15]};
    end else begin
      d_scalar = i_rs1;
    end
  end

  // --------------------------------------------------------------------------
  // Per-instruction state
  // --------------------------------------------------------------------------
  logic [VLEN-1:0] v0_q, mres_q;
  logic [4:0] vd_q, vs1_q, vs2_q;
  localparam int unsigned VlBits = 16;

  // Elements per register at each SEW.
  function automatic logic [15:0] epr(input logic [1:0] sew);
    epr = 16'(VLEN / 8) >> sew;
  endfunction

  // Lane inputs and outputs
  logic lane_valid;
  logic [Lanes-1:0] lane_ovalid;
  logic [Lanes-1:0][63:0] lane_a, lane_b, lane_res;
  logic [Lanes-1:0][7:0] lane_min, lane_mout;
  for (genvar l = 0; l < Lanes; l++) begin : gen_lanes
    vec_int_lane u_lane (
        .i_clk   (i_clk),
        .i_rst   (i_rst),
        .i_valid (lane_valid),
        .i_op    (op_q),
        .i_sew   (vec_pkg::sew_e'(sew_q)),
        .i_a     (lane_a[l]),
        .i_b     (lane_b[l]),
        .i_mask  (lane_min[l]),
        .o_valid (lane_ovalid[l]),
        .o_result(lane_res[l]),
        .o_mask  (lane_mout[l])
    );
  end

  // Group g's first element index and v0 bits (element k of the register at
  // bit k), registered when the group's sources are read.
  logic [VLEN-1:0] gmask;
  logic [15:0] gbase;
  always_ff @(posedge i_clk) begin
    if (state == S_RD) begin
      gbase <= 16'(g_q) * epr(sew_q);
      gmask <= v0_q >> (16'(g_q) * epr(sew_q));
    end
  end

  // Lane l holds elements l*(64/SEW) .. ; its v0 bits.
  always_comb begin
    for (int l = 0; l < Lanes; l++) begin
      lane_a[l] = rf_rdata[0][64*l+:64];
      lane_b[l] = use_scalar_q ? scalar_q : rf_rdata[1][64*l+:64];
      unique case (sew_q)
        2'd0: lane_min[l] = gmask[8*l+:8];
        2'd1: lane_min[l] = 8'(gmask[4*l+:4]);
        2'd2: lane_min[l] = 8'(gmask[2*l+:2]);
        default: lane_min[l] = 8'(gmask[l]);
      endcase
    end
  end

  // Active body elements of group g, per element (bit k: element gbase + k)
  // and per byte, registered while the lanes run; and the same bits at their
  // place in a mask register.
  logic [VLEN-1:0] act_d, act_q, act_sh_q;
  logic [Bytes-1:0] wbe_q;
  always_comb begin
    for (int k = 0; k < VLEN; k++) begin
      logic [15:0] e;
      e = gbase + 16'(k);
      act_d[k] = (16'(k) < epr(sew_q)) && (e < vl_q) && (e >= vstart_q) && (!masked_q || gmask[k]);
    end
  end
  always_ff @(posedge i_clk) begin
    if (state == S_EX) begin
      act_q <= act_d;
      act_sh_q <= act_q << gbase;
      for (int b = 0; b < Bytes; b++) wbe_q[b] <= act_q[b>>sew_q];
    end
  end

  // Compare results of group g, element k at bit k.
  logic [VLEN-1:0] gcmp;
  always_comb begin
    gcmp = '0;
    for (int l = 0; l < Lanes; l++) begin
      unique case (sew_q)
        2'd0: gcmp[8*l+:8] = lane_mout[l];
        2'd1: gcmp[4*l+:4] = lane_mout[l][3:0];
        2'd2: gcmp[2*l+:2] = lane_mout[l][1:0];
        default: gcmp[l] = lane_mout[l][0];
      endcase
    end
  end

  always_ff @(posedge i_clk) begin
    lane_valid <= 1'b0;
    o_unsupported <= 1'b0;
    if (i_rst) begin
      state <= S_IDLE;
    end else begin
      unique case (state)
        S_IDLE:
        if (i_valid) begin
          insn_q <= i_insn;
          sew_q <= i_vsew[1:0];
          groups_q <= i_vlmul[2] ? 4'd1 : (4'd1 << i_vlmul[1:0]);
          vl_q <= i_vl;
          vstart_q <= i_vstart;
          scalar_q <= replicate(d_scalar, i_vsew[1:0]);
          use_scalar_q <= (funct3 == 3'b100) || (funct3 == 3'b011);
          op_q <= d_op;
          mask_dest_q <= d_mask_dest;
          unary_q <= d_unary;
          // vmerge reads v0 as its select and writes every body element.
          masked_q <= !vm_bit && !(d_op == vec_pkg::VI_MERGE);
          merge_q <= (d_op == vec_pkg::VI_MERGE);
          vd_q <= i_insn[11:7];
          vs1_q <= i_insn[19:15];
          vs2_q <= i_insn[24:20];
          g_q <= '0;
          if (!d_ok) o_unsupported <= 1'b1;
          else state <= S_PRE;
        end
        S_PRE: state <= S_PRE2;
        S_PRE2: begin
          v0_q   <= rf_rdata[3];
          mres_q <= rf_rdata[2];
          state  <= S_RD;
        end
        S_RD: state <= S_EX;
        S_EX: begin
          if (ex_cnt_q == 3'd0) lane_valid <= 1'b1;
          if (lane_ovalid[0]) state <= S_WR;
        end
        S_WR: begin
          if (mask_dest_q) mres_q <= (mres_q & ~act_sh_q) | ((gcmp_q << gbase) & act_sh_q);
          if (g_q + 4'd1 == groups_q) state <= mask_dest_q ? S_MWR : S_IDLE;
          else begin
            g_q   <= g_q + 4'd1;
            state <= S_RD;
          end
        end
        S_MWR: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

  // The lanes' results, captured in the cycle they appear.
  logic [VLEN-1:0] res_q, gcmp_q;
  always_ff @(posedge i_clk) begin
    if (state == S_EX && lane_ovalid[0]) begin
      for (int l = 0; l < Lanes; l++) res_q[64*l+:64] <= lane_res[l];
      gcmp_q <= gcmp;
    end
  end

  // Lane start: one pulse at the first S_EX cycle.
  always_ff @(posedge i_clk) begin
    if (state == S_RD) ex_cnt_q <= 3'd0;
    else if (state == S_EX) ex_cnt_q <= ex_cnt_q + 3'd1;
  end

  // Read addresses: v0 and old vd in S_PRE, sources in S_RD (the data is
  // there in S_EX's first cycle, when the lanes take it).
  assign rf_raddr[0] = vs2_q + 5'(g_q);
  assign rf_raddr[1] = unary_q ? vs2_q : vs1_q + 5'(g_q);
  assign rf_raddr[2] = vd_q;
  assign rf_raddr[3] = 5'd0;

  // Writes, from registers: a group's result in S_WR (not for compares), the
  // mask in S_MWR.
  always_comb begin
    rf_we[0] = 1'b0;
    rf_waddr[0] = vd_q + 5'(g_q);
    rf_wdata[0] = '0;
    rf_wbe[0] = '0;
    rf_wdata[0] = res_q;
    if (state == S_WR && !mask_dest_q) begin
      rf_we[0]  = 1'b1;
      rf_wbe[0] = wbe_q;
    end else if (state == S_MWR) begin
      rf_we[0] = 1'b1;
      rf_waddr[0] = vd_q;
      rf_wdata[0] = mres_q;
      rf_wbe[0] = '1;
    end
  end

  assign o_idle = (state == S_IDLE);

endmodule

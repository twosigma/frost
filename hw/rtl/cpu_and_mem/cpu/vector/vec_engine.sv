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
  The vector engine executes committed vector instructions over DLEN = VLEN
  register groups.

  The single-width integer ALU, compare, merge, move and Zvbb unary path is
  pipelined at one register group per cycle across the VRF read stage, the
  three-stage vec_int_lane pipeline, and writeback. Groups before vstart and
  past vl are skipped. Consecutive group-ALU instructions overlap and chain at
  register-group granularity, stalling only when a source register (or v0 / old
  vd when used) is still pending write in the pipeline.

  vec_int_exec executes integer multiply/MAC (group-wide), reductions
  (pipelined 64-bit lane per cycle), and mixed-width/fixed-point/divide/mask/
  permutation operations. vec_fp_exec sequences FP16/32/64 arithmetic,
  conversions and reductions. vec_crypto_exec gathers registered element
  groups for AES, SHA-2 and GHASH, and handles Zvbc carry-less multiplication.
  These auxiliary executors take exclusive ownership of engine VRF ports while
  busy. o_unsupported pulses for unrecognized encodings.

  Masking and the tail use the register file's byte enables: only active body
  elements (vstart <= i < vl, and v0[i] set when masked) are written, so tail
  and inactive elements stay undisturbed, which both policies allow. Compares
  build their mask in a register from the old destination, set one bit per
  active body element, and write it once at the end.

  Two ports serve the memory side (and a bench): a read of one register
  (registered, one cycle) and a byte-enabled write of one register.
*/
module vec_engine #(
    parameter  int unsigned VLEN        = 256,
    parameter  bit          SPLIT_ISSUE = 1'b0,
    localparam int unsigned Lanes       = VLEN / 64,
    localparam int unsigned Bytes       = VLEN / 8,
    localparam int unsigned ByteBits    = $clog2(Bytes)
) (
    input  logic             i_clk,
    input  logic             i_rst,
    input  logic             i_valid,
    input  logic             i_aux_valid = 1'b0,
    output logic             o_idle,
    output logic             o_grp_ready,
    output logic [     31:0] o_wr_mask,
    input  logic [     31:0] i_insn,
    input  logic [      2:0] i_vsew,
    input  logic [      2:0] i_vlmul,
    input  logic [     15:0] i_vl,
    input  logic [     15:0] i_vstart,
    input  logic [     63:0] i_rs1,
    output logic             o_unsupported,
    input  logic [      1:0] i_vxrm = 2'b00,
    output logic             o_sat,
    input  logic [      2:0] i_frm = 3'b000,
    output logic             o_flags_valid,
    output logic [      4:0] o_flags,
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

  logic aux_valid_in;
  assign aux_valid_in = SPLIT_ISSUE ? i_aux_valid : i_valid;

  logic aux_idle, aux_we;
  logic [3:0][4:0] aux_raddr, int_raddr;
  logic [4:0] aux_waddr, int_waddr;
  logic [VLEN-1:0] aux_wdata, int_wdata;
  logic [Bytes-1:0] aux_wbe, int_wbe;
  logic int_we, d_extra;
  assign d_extra = riscv_pkg::vector_int_extra_ok(i_insn);
  vec_int_exec #(
      .VLEN(VLEN)
  ) u_int_exec (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(aux_valid_in && o_idle && d_extra),
      .i_insn(i_insn),
      .i_sew(i_vsew[1:0]),
      .i_lmul(i_vlmul),
      .i_vl(i_vl),
      .i_vstart(i_vstart),
      .i_scalar(i_rs1),
      .i_vxrm(i_vxrm),
      .o_idle(aux_idle),
      .o_sat(o_sat),
      .o_raddr(aux_raddr),
      .i_rdata(rf_rdata[3:0]),
      .o_we(aux_we),
      .o_waddr(aux_waddr),
      .o_wdata(aux_wdata),
      .o_wbe(aux_wbe)
  );
  logic fp_idle, fp_we, d_fp;
  logic [3:0][4:0] fp_raddr;
  logic [4:0] fp_waddr;
  logic [VLEN-1:0] fp_wdata;
  logic [Bytes-1:0] fp_wbe;
  assign d_fp = riscv_pkg::vector_fp_ok(i_insn) && !(i_insn[14:12] == 1 && i_insn[31:26] == 6'h10);
  vec_fp_exec #(
      .VLEN(VLEN)
  ) u_fp_exec (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(aux_valid_in && o_idle && d_fp),
      .i_insn(i_insn),
      .i_sew(i_vsew[1:0]),
      .i_vl(i_vl),
      .i_vstart(i_vstart),
      .i_scalar(i_rs1),
      .i_frm(i_frm),
      .o_idle(fp_idle),
      .o_flags_valid(o_flags_valid),
      .o_flags(o_flags),
      .o_raddr(fp_raddr),
      .i_rdata(rf_rdata[3:0]),
      .o_we(fp_we),
      .o_waddr(fp_waddr),
      .o_wdata(fp_wdata),
      .o_wbe(fp_wbe)
  );
  logic crypto_idle, crypto_we, d_crypto;
  logic [3:0][4:0] crypto_raddr;
  logic [4:0] crypto_waddr;
  logic [VLEN-1:0] crypto_wdata;
  logic [Bytes-1:0] crypto_wbe;
  assign d_crypto = riscv_pkg::vector_crypto_ok(i_insn);
  vec_crypto_exec #(
      .VLEN(VLEN)
  ) u_crypto_exec (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(aux_valid_in && o_idle && d_crypto),
      .i_insn(i_insn),
      .i_sew(i_vsew[1:0]),
      .i_vl(i_vl),
      .i_vstart(i_vstart),
      .i_scalar(i_rs1),
      .o_idle(crypto_idle),
      .o_raddr(crypto_raddr),
      .i_rdata(rf_rdata[3:0]),
      .o_we(crypto_we),
      .o_waddr(crypto_waddr),
      .o_wdata(crypto_wdata),
      .o_wbe(crypto_wbe)
  );
  assign rf_raddr[3:0] = !crypto_idle ? crypto_raddr :
      !fp_idle ? fp_raddr : aux_idle ? int_raddr : aux_raddr;
  assign rf_we[0] = !crypto_idle ? crypto_we : !fp_idle ? fp_we : aux_idle ? int_we : aux_we;
  assign rf_waddr[0] = !crypto_idle ? crypto_waddr :
      !fp_idle ? fp_waddr : aux_idle ? int_waddr : aux_waddr;
  assign rf_wdata[0] = !crypto_idle ? crypto_wdata :
      !fp_idle ? fp_wdata : aux_idle ? int_wdata : aux_wdata;
  assign rf_wbe[0] = !crypto_idle ? crypto_wbe : !fp_idle ? fp_wbe : aux_idle ? int_wbe : aux_wbe;

  // --------------------------------------------------------------------------
  // Pipelined group-ALU sequencer (Stage R): pre-decoded on seq_accept
  // --------------------------------------------------------------------------
  logic seq_valid_q, seq_started_q;
  logic seq_ok_q, seq_no_body_q, seq_mask_dest_q, seq_unary_q;
  logic seq_use_scalar_q, seq_masked_q, seq_need_vs2_q, seq_need_vs1_q, seq_need_v0_q;
  vec_pkg::int_op_e seq_op_q;
  logic [4:0] seq_vd_q, seq_vs2_q, seq_vs1_q;
  logic [1:0] seq_sew_q;
  logic [2:0] seq_epr_shift_q;
  logic [3:0] seq_g_q, seq_last_g_q;
  logic [15:0] seq_vl_q, seq_vstart_q;
  logic [63:0] seq_scalar_q;
  logic [31:0] seq_wr_mask_q;

  // Pipeline stages aligned with vec_int_lane:
  //   R  -> VRF read address presented (seq_*_q)
  //   E0 -> VRF data ready, presented to vec_int_lane
  //   E1 -> vec_int_lane stage 0 (s0)
  //   E2 -> vec_int_lane stage 1 (s1)
  //   W  -> vec_int_lane output valid (o_result / o_mask), writes VRF
  logic e0_valid_q, e0_mask_dest_q, e0_masked_q, e0_use_scalar_q, e0_first_q, e0_last_q;
  vec_pkg::int_op_e e0_op_q;
  logic [1:0] e0_sew_q;
  logic [4:0] e0_vd_reg_q;
  logic [15:0] e0_gbase_q, e0_vl_q, e0_vstart_q;
  logic [63:0] e0_scalar_q;

  logic e1_valid_q, e1_mask_dest_q, e1_masked_q, e1_last_q;
  logic [1:0] e1_sew_q;
  logic [4:0] e1_vd_reg_q;
  logic [15:0] e1_gbase_q, e1_vl_q, e1_vstart_q;
  logic [Bytes-1:0] e1_gmask_q;

  logic e2_valid_q, e2_mask_dest_q, e2_last_q;
  logic [1:0] e2_sew_q;
  logic [4:0] e2_vd_reg_q;
  logic [15:0] e2_gbase_q;
  logic [Bytes-1:0] e2_act_q;

  logic w_valid_q, w_mask_dest_q, w_last_q;
  logic [1:0] w_sew_q;
  logic [4:0] w_vd_reg_q;
  logic [15:0] w_gbase_q;
  logic [Bytes-1:0] w_wbe_q;
  logic [VLEN-1:0] w_act_sh_q;

  logic mwr_pending_q;
  logic [4:0] mwr_vd_q;
  logic [VLEN-1:0] mres_q;

  // Pre-decode incoming group-ALU instruction (latched on seq_accept).
  wire [5:0] d_funct6 = i_insn[31:26];
  wire [2:0] d_funct3 = i_insn[14:12];
  wire d_vm_bit = i_insn[25];
  wire [4:0] d_vs2 = i_insn[24:20];
  wire [4:0] d_vs1 = i_insn[19:15];
  wire [4:0] d_vd = i_insn[11:7];

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
      if (d_funct3 == 3'b000 || d_funct3 == 3'b100 || d_funct3 == 3'b011) begin
        d_ok = 1'b1;
        unique casez (d_funct6)
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
            d_op   = (d_funct3 == 3'b011) ? vec_pkg::VI_ROR : vec_pkg::VI_ROL;
            d_uimm = 1'b1;
            d_imm6 = (d_funct3 == 3'b011);
          end
          6'b010111: d_op = d_vm_bit ? vec_pkg::VI_MV : vec_pkg::VI_MERGE;
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
        d_mask_dest = (d_funct6[5:3] == 3'b011);
        if (d_funct6 == 6'b010100 && d_funct3 == 3'b011) d_imm6 = 1'b0;
      end else if (d_funct3 == 3'b010 && d_funct6 == 6'b010010) begin
        d_unary = 1'b1;
        d_ok = 1'b1;
        unique case (d_vs1)
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

  logic d_use_scalar, d_masked, d_merge;
  assign d_use_scalar = (d_funct3 == 3'b100) || (d_funct3 == 3'b011);
  // vmerge reads v0 as its select and writes every body element.
  assign d_masked     = !d_vm_bit && !(d_op == vec_pkg::VI_MERGE);
  assign d_merge      = (d_op == vec_pkg::VI_MERGE);

  function automatic logic [63:0] replicate(input logic [63:0] x, input logic [1:0] sew);
    unique case (sew)
      2'd0: replicate = {8{x[7:0]}};
      2'd1: replicate = {4{x[15:0]}};
      2'd2: replicate = {2{x[31:0]}};
      default: replicate = x;
    endcase
  endfunction

  logic [63:0] d_scalar_raw, d_scalar_rep;
  always_comb begin
    if (d_funct3 == 3'b011) begin
      if (d_uimm) d_scalar_raw = 64'({d_imm6 ? i_insn[26] : 1'b0, i_insn[19:15]});
      else d_scalar_raw = {{59{i_insn[19]}}, i_insn[19:15]};
    end else begin
      d_scalar_raw = i_rs1;
    end
    d_scalar_rep = replicate(d_scalar_raw, i_vsew[1:0]);
  end

  // Active register-group range for [i_vstart, i_vl), precomputed for seq_accept.
  logic [3:0] d_groups, d_eff_last_g;
  logic [2:0] d_epr_shift;
  logic [15:0] d_first_g_raw, d_last_g_raw;
  logic d_no_body;
  assign d_groups = i_vlmul[2] ? 4'd1 : (4'd1 << i_vlmul[1:0]);
  assign d_epr_shift = 3'(ByteBits) - {1'b0, i_vsew[1:0]};
  assign d_first_g_raw = i_vstart >> d_epr_shift;
  assign d_last_g_raw = (i_vl - 16'd1) >> d_epr_shift;
  assign d_no_body = (i_vl == 16'd0) || (i_vstart >= i_vl) || (d_first_g_raw >= {12'd0, d_groups});
  assign d_eff_last_g = (d_last_g_raw >= {12'd0, d_groups}) ? (d_groups - 4'd1) : d_last_g_raw[3:0];

  // In-flight register write mask across stages E0, E1, E2, W and compare MWR.
  // Because vec_vrf reads return pre-edge data, a register stays hazardous
  // through stage W (until the edge that commits its write completes).
  logic [31:0] pipe_wr_mask;
  always_comb begin
    pipe_wr_mask = 32'd0;
    if (e0_valid_q && !e0_mask_dest_q) pipe_wr_mask[e0_vd_reg_q] = 1'b1;
    if (e1_valid_q && !e1_mask_dest_q) pipe_wr_mask[e1_vd_reg_q] = 1'b1;
    if (e2_valid_q && !e2_mask_dest_q) pipe_wr_mask[e2_vd_reg_q] = 1'b1;
    if (w_valid_q && !w_mask_dest_q) pipe_wr_mask[w_vd_reg_q] = 1'b1;
    if (mwr_pending_q) pipe_wr_mask[mwr_vd_q] = 1'b1;
  end

  // Exported write mask includes in-flight compares (whose stages are excluded
  // from internal pipe_wr_mask) and registers written by seq_*_q (precomputed
  // and registered on seq_accept).
  logic [31:0] cmp_wr_mask, d_wr_mask;
  always_comb begin
    cmp_wr_mask = 32'd0;
    if (e0_valid_q && e0_mask_dest_q) cmp_wr_mask[e0_vd_reg_q] = 1'b1;
    if (e1_valid_q && e1_mask_dest_q) cmp_wr_mask[e1_vd_reg_q] = 1'b1;
    if (e2_valid_q && e2_mask_dest_q) cmp_wr_mask[e2_vd_reg_q] = 1'b1;
    if (w_valid_q && w_mask_dest_q) cmp_wr_mask[w_vd_reg_q] = 1'b1;
  end
  always_comb begin
    d_wr_mask = 32'd0;
    if (d_ok && !d_no_body) begin
      if (d_mask_dest) begin
        d_wr_mask[d_vd] = 1'b1;
      end else begin
        for (int i = 0; i < 8; i++) begin
          if (4'(i) >= d_first_g_raw[3:0] && 4'(i) <= d_eff_last_g)
            d_wr_mask[5'(d_vd+5'(i))] = 1'b1;
        end
      end
    end
  end
  assign o_wr_mask = pipe_wr_mask | cmp_wr_mask | (seq_valid_q ? seq_wr_mask_q : 32'd0);

  // Source read addresses for the current sequencer group (pure flops + 5-bit add).
  logic [4:0] r_vs2_addr, r_vs1_addr;
  assign r_vs2_addr   = seq_vs2_q + 5'(seq_g_q);
  assign r_vs1_addr   = seq_unary_q ? seq_vs2_q : (seq_vs1_q + 5'(seq_g_q));
  assign int_raddr[0] = r_vs2_addr;
  assign int_raddr[1] = r_vs1_addr;
  assign int_raddr[2] = seq_vd_q;
  assign int_raddr[3] = 5'd0;

  // RAW hazard check for the current sequencer group (pure flops -> 3 LUTs).
  logic raw_hazard;
  assign raw_hazard = (seq_need_vs2_q && pipe_wr_mask[r_vs2_addr]) ||
      (seq_need_vs1_q && pipe_wr_mask[r_vs1_addr]) || (seq_need_v0_q && pipe_wr_mask[0]) ||
      (seq_mask_dest_q && pipe_wr_mask[seq_vd_q]);

  logic grp_pipe_busy, cmp_in_flight, seq_issue_fire, seq_finishing, seq_accept;
  assign grp_pipe_busy = e0_valid_q || e1_valid_q || e2_valid_q || w_valid_q || mwr_pending_q;
  assign cmp_in_flight = (seq_valid_q && seq_mask_dest_q) || (e0_valid_q && e0_mask_dest_q) ||
      (e1_valid_q && e1_mask_dest_q) || (e2_valid_q && e2_mask_dest_q) ||
      (w_valid_q && w_mask_dest_q) || mwr_pending_q;
  logic seq_last_fire;
  assign seq_issue_fire = seq_valid_q && seq_ok_q && !seq_no_body_q && !raw_hazard;
  assign seq_last_fire = seq_issue_fire && !seq_mask_dest_q && (seq_g_q == seq_last_g_q);
  assign seq_finishing = seq_valid_q && (!seq_ok_q || seq_no_body_q || seq_last_fire);

  assign o_idle = !seq_valid_q && !grp_pipe_busy && aux_idle && fp_idle && crypto_idle;
  assign o_grp_ready = aux_idle && fp_idle && crypto_idle && !cmp_in_flight &&
      (!seq_valid_q || seq_finishing);
  assign seq_accept = SPLIT_ISSUE ? (i_valid && o_grp_ready) :
      (i_valid && o_grp_ready && !d_extra && !d_fp && !d_crypto);

  // --------------------------------------------------------------------------
  // Stage E0 -> vec_int_lane instances -> Stage W
  // --------------------------------------------------------------------------
  logic [Lanes-1:0] lane_ovalid;
  logic [Lanes-1:0][63:0] lane_a, lane_b, lane_res;
  logic [Lanes-1:0][7:0] lane_min, lane_mout;
  logic [VLEN-1:0] e0_gmask_full;
  assign e0_gmask_full = rf_rdata[3] >> e0_gbase_q;

  always_comb begin
    for (int l = 0; l < Lanes; l++) begin
      lane_a[l] = rf_rdata[0][64*l+:64];
      lane_b[l] = e0_use_scalar_q ? e0_scalar_q : rf_rdata[1][64*l+:64];
      unique case (e0_sew_q)
        2'd0: lane_min[l] = e0_gmask_full[8*l+:8];
        2'd1: lane_min[l] = 8'(e0_gmask_full[4*l+:4]);
        2'd2: lane_min[l] = 8'(e0_gmask_full[2*l+:2]);
        default: lane_min[l] = 8'(e0_gmask_full[l]);
      endcase
    end
  end

  for (genvar l = 0; l < Lanes; l++) begin : gen_lanes
    vec_int_lane u_lane (
        .i_clk   (i_clk),
        .i_rst   (i_rst),
        .i_valid (e0_valid_q),
        .i_op    (e0_op_q),
        .i_sew   (vec_pkg::sew_e'(e0_sew_q)),
        .i_a     (lane_a[l]),
        .i_b     (lane_b[l]),
        .i_mask  (lane_min[l]),
        .o_valid (lane_ovalid[l]),
        .o_result(lane_res[l]),
        .o_mask  (lane_mout[l])
    );
  end

  // Active body elements computed in E1 -> registered into E2.
  logic [Bytes-1:0] e2_act_d;
  always_comb begin
    for (int k = 0; k < Bytes; k++) begin
      logic [15:0] e;
      e = e1_gbase_q + 16'(k);
      e2_act_d[k] = (16'(k) < (16'(Bytes) >> e1_sew_q)) && (e < e1_vl_q) && (e >= e1_vstart_q) &&
          (!e1_masked_q || e1_gmask_q[k]);
    end
  end

  // Per-byte write enables and shifted compare mask computed in E2 -> W.
  logic [Bytes-1:0] w_wbe_d;
  logic [ VLEN-1:0] w_act_sh_d;
  always_comb begin
    for (int b = 0; b < Bytes; b++) w_wbe_d[b] = e2_act_q[ByteBits'(b>>e2_sew_q)];
    w_act_sh_d = VLEN'(e2_act_q) << e2_gbase_q;
  end

  // Compare results of group g in Stage W, element k at bit k.
  logic [VLEN-1:0] gcmp, lane_res_vec;
  always_comb begin
    gcmp = '0;
    for (int l = 0; l < Lanes; l++) begin
      lane_res_vec[64*l+:64] = lane_res[l];
      unique case (w_sew_q)
        2'd0: gcmp[8*l+:8] = lane_mout[l];
        2'd1: gcmp[4*l+:4] = lane_mout[l][3:0];
        2'd2: gcmp[2*l+:2] = lane_mout[l][1:0];
        default: gcmp[l] = lane_mout[l][0];
      endcase
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      seq_valid_q   <= 1'b0;
      seq_started_q <= 1'b0;
      e0_valid_q    <= 1'b0;
      e1_valid_q    <= 1'b0;
      e2_valid_q    <= 1'b0;
      w_valid_q     <= 1'b0;
      mwr_pending_q <= 1'b0;
      o_unsupported <= 1'b0;
    end else begin
      o_unsupported <= seq_valid_q && !seq_ok_q;

      // Sequencer (Stage R)
      if (seq_accept) begin
        seq_valid_q      <= 1'b1;
        seq_started_q    <= 1'b0;
        seq_ok_q         <= d_ok;
        seq_no_body_q    <= d_no_body;
        seq_mask_dest_q  <= d_mask_dest;
        seq_unary_q      <= d_unary;
        seq_use_scalar_q <= d_use_scalar;
        seq_masked_q     <= d_masked;
        seq_need_vs2_q   <= (d_op != vec_pkg::VI_MV);
        seq_need_vs1_q   <= !d_use_scalar && !d_unary;
        seq_need_v0_q    <= d_masked || d_merge;
        seq_op_q         <= d_op;
        seq_vd_q         <= d_vd;
        seq_vs2_q        <= d_vs2;
        seq_vs1_q        <= d_vs1;
        seq_sew_q        <= i_vsew[1:0];
        seq_epr_shift_q  <= d_epr_shift;
        seq_g_q          <= d_first_g_raw[3:0];
        seq_last_g_q     <= d_eff_last_g;
        seq_vl_q         <= i_vl;
        seq_vstart_q     <= i_vstart;
        seq_scalar_q     <= d_scalar_rep;
        seq_wr_mask_q    <= d_wr_mask;
      end else if (seq_valid_q) begin
        if (!seq_ok_q || seq_no_body_q) begin
          seq_valid_q   <= 1'b0;
          seq_started_q <= 1'b0;
        end else if (seq_issue_fire) begin
          if (seq_g_q == seq_last_g_q) begin
            seq_valid_q   <= 1'b0;
            seq_started_q <= 1'b0;
          end else begin
            seq_g_q       <= seq_g_q + 4'd1;
            seq_started_q <= 1'b1;
          end
        end
      end

      // Stage R -> E0
      e0_valid_q <= seq_issue_fire;
      if (seq_issue_fire) begin
        e0_op_q         <= seq_op_q;
        e0_sew_q        <= seq_sew_q;
        e0_mask_dest_q  <= seq_mask_dest_q;
        e0_masked_q     <= seq_masked_q;
        e0_use_scalar_q <= seq_use_scalar_q;
        e0_first_q      <= !seq_started_q;
        e0_last_q       <= (seq_g_q == seq_last_g_q);
        e0_vd_reg_q     <= seq_mask_dest_q ? seq_vd_q : (seq_vd_q + 5'(seq_g_q));
        e0_gbase_q      <= {12'd0, seq_g_q} << seq_epr_shift_q;
        e0_vl_q         <= seq_vl_q;
        e0_vstart_q     <= seq_vstart_q;
        e0_scalar_q     <= seq_scalar_q;
      end

      // Stage E0 -> E1 (aligned with vec_int_lane s0)
      e1_valid_q <= e0_valid_q;
      if (e0_valid_q) begin
        e1_sew_q       <= e0_sew_q;
        e1_mask_dest_q <= e0_mask_dest_q;
        e1_masked_q    <= e0_masked_q;
        e1_last_q      <= e0_last_q;
        e1_vd_reg_q    <= e0_vd_reg_q;
        e1_gbase_q     <= e0_gbase_q;
        e1_vl_q        <= e0_vl_q;
        e1_vstart_q    <= e0_vstart_q;
        e1_gmask_q     <= e0_gmask_full[Bytes-1:0];
        if (e0_mask_dest_q && e0_first_q) mres_q <= rf_rdata[2];
      end

      // Stage E1 -> E2 (aligned with vec_int_lane s1)
      e2_valid_q <= e1_valid_q;
      if (e1_valid_q) begin
        e2_sew_q       <= e1_sew_q;
        e2_mask_dest_q <= e1_mask_dest_q;
        e2_last_q      <= e1_last_q;
        e2_vd_reg_q    <= e1_vd_reg_q;
        e2_gbase_q     <= e1_gbase_q;
        e2_act_q       <= e2_act_d;
      end

      // Stage E2 -> W (aligned with vec_int_lane o_valid)
      w_valid_q <= e2_valid_q;
      if (e2_valid_q) begin
        w_sew_q       <= e2_sew_q;
        w_mask_dest_q <= e2_mask_dest_q;
        w_last_q      <= e2_last_q;
        w_vd_reg_q    <= e2_vd_reg_q;
        w_gbase_q     <= e2_gbase_q;
        w_wbe_q       <= w_wbe_d;
        w_act_sh_q    <= w_act_sh_d;
      end

      // Stage W -> compare mask accumulate and MWR
      if (mwr_pending_q) mwr_pending_q <= 1'b0;
      if (w_valid_q && w_mask_dest_q) begin
        mres_q <= (mres_q & ~w_act_sh_q) | ((gcmp << w_gbase_q) & w_act_sh_q);
        if (w_last_q) begin
          mwr_pending_q <= 1'b1;
          mwr_vd_q      <= w_vd_reg_q;
        end
      end
    end
  end

  // Group-ALU VRF writes, driven directly from registered lane/mask outputs.
  always_comb begin
    int_we = 1'b0;
    int_waddr = w_vd_reg_q;
    int_wdata = lane_res_vec;
    int_wbe = w_wbe_q;
    if (mwr_pending_q) begin
      int_we    = 1'b1;
      int_waddr = mwr_vd_q;
      int_wdata = mres_q;
      int_wbe   = '1;
    end else if (w_valid_q && !w_mask_dest_q) begin
      int_we = 1'b1;
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // Register file port 0 and the read ports belong to whichever executor is
  // busy, so at most one may be.
  logic eng_reset_seen_q = 1'b0;
  always @(posedge i_clk) begin
    if (i_rst) eng_reset_seen_q <= 1'b1;
    if (eng_reset_seen_q && !i_rst) begin
      assert ($onehot0({seq_valid_q || grp_pipe_busy, !aux_idle, !fp_idle, !crypto_idle}))
      else
        $error(
            "vec_engine: executors busy at once: group %0b, integer %0b, FP %0b, crypto %0b",
            seq_valid_q || grp_pipe_busy,
            !aux_idle,
            !fp_idle,
            !crypto_idle
        );
      assert (w_valid_q == lane_ovalid[0])
      else $error("vec_engine: stage W valid %0b != lane o_valid %0b", w_valid_q, lane_ovalid[0]);
      assert (!(mwr_pending_q && w_valid_q))
      else $error("vec_engine: compare MWR collided with Stage W");
    end
  end
`endif
`endif

endmodule

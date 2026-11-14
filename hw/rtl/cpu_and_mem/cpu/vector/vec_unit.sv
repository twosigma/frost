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
  The vector unit as the core sees it so far: the instruction word of every
  vector arithmetic ROB entry (written at allocation), an 8-entry queue (VIQ)
  filled when such an entry retires, with the scalar operand INT_RS left in
  its ROB value and the vl, vtype and vstart it executes under, and the engine,
  which takes one queued instruction at a time.

  vmv.x.s, vcpop.m and vfirst.m (VTOX) execute at the ROB head: once such an
  entry is the head, the head is not speculative, and the queue and engine
  are idle, the unit waits two cycles (a vector-config update reaches the CSR
  file that late, and the last older instruction's queue push one cycle after
  it retires) and checks idleness again, reads vs2 (and v0 when masked) through the engine's read
  port, computes the result in two stages and presents it on CDB slot 6 until
  it is granted; a full flush drops it. Each entry completes once. o_commit_hold asks the ROB to
  stop retiring while the queue is nearly full (registered); o_idle is high
  when the queue is empty and the engine idle.
*/
module vec_unit #(
    parameter  int unsigned VLEN = 256,
    localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth
) (
    input  logic                               i_clk,
    input  logic                               i_rst,
    // Slot-1 allocation
    input  logic                               i_alloc,
    input  logic                    [TagW-1:0] i_alloc_tag,
    input  logic                               i_alloc_is_varith,
    input  logic                    [    31:0] i_alloc_insn,
    // Slot-2 allocation (never a vector instruction): it clears the flags of
    // its tag, which a squashed vector instruction may have left set
    input  logic                               i_alloc_2,
    input  logic                    [TagW-1:0] i_alloc_tag_2,
    // Registered commit bus (slot 1; vector arithmetic never retires as slot 2)
    input  logic                               i_commit_valid,
    input  logic                    [TagW-1:0] i_commit_tag,
    input  logic                               i_commit_exception,
    input  logic                    [    63:0] i_commit_value,
    // Architectural vl, vtype ({vill, vtype[7:0]}) and vstart
    input  logic                    [    15:0] i_vl,
    input  logic                    [     8:0] i_vtype,
    input  logic                    [    15:0] i_vstart,
    // Head execution of vector-to-scalar ops
    input  logic                               i_alloc_is_vtox,
    input  logic                    [TagW-1:0] i_head_tag,
    input  logic                               i_rob_empty,
    input  logic                               i_head_safe,
    input  logic                               i_flush_all,
    input  logic                               i_grant,
    output riscv_pkg::fu_complete_t            o_vtox_complete,
    output logic                               o_varith_commit,
    output logic                               o_commit_hold,
    output logic                               o_idle
);

  localparam int unsigned Depth = 8;

  logic [31:0] insn_q[riscv_pkg::ReorderBufferDepth];
  logic [riscv_pkg::ReorderBufferDepth-1:0] is_varith_q, is_vtox_q;
  logic vtox_done;
  logic [TagW-1:0] vtox_tag_q;
  always_ff @(posedge i_clk) begin
    if (i_alloc) insn_q[i_alloc_tag] <= i_alloc_insn;
    // Every allocation of a tag rewrites its flags, so a flag left by a
    // squashed vector instruction never describes a later one.
    if (i_rst) begin
      is_vtox_q   <= '0;
      is_varith_q <= '0;
    end else begin
      if (vtox_done) is_vtox_q[vtox_tag_q] <= 1'b0;
      if (i_alloc) begin
        is_vtox_q[i_alloc_tag]   <= i_alloc_is_vtox;
        is_varith_q[i_alloc_tag] <= i_alloc_is_varith;
      end
      if (i_alloc_2) begin
        is_vtox_q[i_alloc_tag_2]   <= 1'b0;
        is_varith_q[i_alloc_tag_2] <= 1'b0;
      end
    end
  end
  assign o_varith_commit = i_commit_valid && is_varith_q[i_commit_tag] && !i_commit_exception;

  // The engine's register read port, used by the vector-to-scalar logic.
  logic [4:0] xr_addr;
  logic [VLEN-1:0] xr_data;

  // VIQ: {insn, scalar, vl, vtype, vstart}
  localparam int unsigned EntryW = 32 + 64 + 16 + 9 + 16;
  logic [EntryW-1:0] viq_q[Depth];
  logic [$clog2(Depth)-1:0] head_q, tail_q;
  logic [$clog2(Depth):0] count_q;
  logic push, pop, issued_q;
  logic eng_idle;
  assign push = o_varith_commit;
  assign pop  = eng_idle && !issued_q && (count_q != '0);
  always_ff @(posedge i_clk) begin
    if (push) viq_q[tail_q] <= {insn_q[i_commit_tag], i_commit_value, i_vl, i_vtype, i_vstart};
    if (i_rst) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      issued_q <= 1'b0;
      o_commit_hold <= 1'b0;
    end else begin
      if (push) tail_q <= tail_q + 1'b1;
      if (pop) head_q <= head_q + 1'b1;
      count_q <= count_q + ($clog2(Depth) + 1)'(push) - ($clog2(Depth) + 1)'(pop);
      issued_q <= pop;
      // Two spare entries cover the commit bus's registered delay.
      o_commit_hold <= (count_q + ($clog2(Depth) + 1)'(push)) >= ($clog2(Depth) + 1)'(Depth - 2);
    end
  end

  logic [31:0] e_insn;
  logic [63:0] e_scalar;
  logic [15:0] e_vl, e_vstart;
  logic [8:0] e_vtype;
  assign {e_insn, e_scalar, e_vl, e_vtype, e_vstart} = viq_q[head_q];

  vec_engine #(
      .VLEN(VLEN)
  ) u_engine (
      .i_clk        (i_clk),
      .i_rst        (i_rst),
      .i_valid      (pop),
      .o_idle       (eng_idle),
      .i_insn       (e_insn),
      .i_vsew       (e_vtype[5:3]),
      .i_vlmul      (e_vtype[2:0]),
      .i_vl         (e_vl),
      .i_vstart     (e_vstart),
      .i_rs1        (e_scalar),
      .o_unsupported(),
      .i_xr_addr    (xr_addr),
      .o_xr_data    (xr_data),
      .i_xw_en      (1'b0),
      .i_xw_addr    ('0),
      .i_xw_data    ('0),
      .i_xw_be      ('0)
  );

  assign o_idle = eng_idle && (count_q == '0) && !issued_q;

  // --------------------------------------------------------------------------
  // Vector-to-scalar at the head
  // --------------------------------------------------------------------------
  localparam int unsigned Blocks = VLEN / 64;
  typedef enum logic [2:0] {
    X_IDLE,
    X_WAIT,
    X_RD2,   // vs2 read presented
    X_RD0,   // v0 read presented
    X_ST1,   // per-64-bit counts and first indices
    X_ST2,   // combine
    X_OUT    // presented until granted
  } xstate_e;
  xstate_e xs;
  logic [31:0] xi;
  logic [1:0] xwait_q;
  logic [VLEN-1:0] xs2_q, xactive_q;
  logic [15:0] xvl_q;
  logic [8:0] xvt_q;
  logic [Blocks-1:0][6:0] blk_cnt_q;
  logic [Blocks-1:0][5:0] blk_first_q;
  logic [Blocks-1:0] blk_any_q;
  logic [63:0] xres_q;
  wire x_masked = !xi[25];
  wire x_is_mv = (xi[19:15] == 5'b00000);
  wire x_is_first = (xi[19:15] == 5'b10001);
  assign xi = insn_q[vtox_tag_q];
  assign xr_addr = (xs == X_RD0) ? 5'd0 : xi[24:20];
  assign vtox_done = (xs == X_OUT) && i_grant;

  // Per-64-bit counts and first set bits of the active mask.
  logic [Blocks-1:0][6:0] blk_cnt;
  logic [Blocks-1:0][5:0] blk_first;
  logic [Blocks-1:0] blk_any;
  always_comb begin
    for (int b = 0; b < Blocks; b++) begin
      blk_first[b] = 6'd63;
      for (int j = 63; j >= 0; j--) if (xactive_q[64*b+j]) blk_first[b] = 6'(j);
      blk_cnt[b] = 7'($countones(xactive_q[64*b+:64]));
      blk_any[b] = |xactive_q[64*b+:64];
    end
  end

  // Body bits below vl.
  logic [VLEN-1:0] body;
  always_comb for (int k = 0; k < VLEN; k++) body[k] = 16'(k) < xvl_q;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_all) begin
      xs <= X_IDLE;
    end else begin
      unique case (xs)
        X_IDLE:
        if (!i_rob_empty && is_vtox_q[i_head_tag] && i_head_safe && o_idle) begin
          vtox_tag_q <= i_head_tag;
          xwait_q <= '0;
          xs <= X_WAIT;
        end
        X_WAIT: begin
          xwait_q <= xwait_q + 2'd1;
          // The last older instruction's queue push lands a cycle after it
          // retires, so idleness is checked again before the read.
          if (xwait_q == 2'd1) begin
            xvl_q <= i_vl;
            xvt_q <= i_vtype;
            xs <= o_idle ? X_RD2 : X_IDLE;
          end
        end
        X_RD2:   xs <= X_RD0;
        X_RD0: begin
          xs2_q <= xr_data;  // vs2, read last cycle
          xs <= X_ST1;
        end
        X_ST1: begin
          // v0 arrives now; active bits for vcpop/vfirst
          xactive_q <= xs2_q & body & (x_masked ? xr_data : '1);
          xs <= X_ST2;
        end
        X_ST2: begin
          blk_cnt_q <= blk_cnt;
          blk_first_q <= blk_first;
          blk_any_q <= blk_any;
          xs <= X_OUT;
        end
        X_OUT:   if (i_grant) xs <= X_IDLE;
        default: xs <= X_IDLE;
      endcase
    end
  end

  // Result, formed from the block values while presented.
  always_comb begin
    logic [15:0] cnt;
    logic [63:0] first;
    logic found;
    cnt   = '0;
    first = '1;
    found = 1'b0;
    for (int b = 0; b < Blocks; b++) begin
      cnt = cnt + 16'(blk_cnt_q[b]);
      if (!found && blk_any_q[b]) begin
        first = 64'(64 * b) + 64'(blk_first_q[b]);
        found = 1'b1;
      end
    end
    if (x_is_mv) begin
      unique case (xvt_q[4:3])
        2'd0: xres_q = {{56{xs2_q[7]}}, xs2_q[7:0]};
        2'd1: xres_q = {{48{xs2_q[15]}}, xs2_q[15:0]};
        2'd2: xres_q = {{32{xs2_q[31]}}, xs2_q[31:0]};
        default: xres_q = xs2_q[63:0];
      endcase
    end else if (x_is_first) xres_q = first;
    else xres_q = 64'(cnt);
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // A vector-to-scalar result is presented only while its entry is the head.
  logic x_reset_seen_q = 1'b0;
  always @(posedge i_clk) begin
    if (i_rst) x_reset_seen_q <= 1'b1;
    if (x_reset_seen_q && !i_rst && xs == X_OUT && (i_rob_empty || i_head_tag != vtox_tag_q))
      $error(
          "vec_unit: vector-to-scalar result presented for tag %0d, head %0d, empty %0b",
          vtox_tag_q,
          i_head_tag,
          i_rob_empty
      );
  end
`endif
`endif

  always_comb begin
    o_vtox_complete = '0;
    o_vtox_complete.valid = (xs == X_OUT);
    o_vtox_complete.tag = vtox_tag_q;
    o_vtox_complete.value = riscv_pkg::FLEN'(xres_q);
  end

endmodule

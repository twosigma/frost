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

// Per-channel unbounded k-induction checker for one async_fifo inside axi_cdc.
module axi_cdc_chan_check #(
    parameter int unsigned WIDTH = 8,
    parameter int unsigned DEPTH = 4
) (
    input logic gclk,
    input logic f_init_done,
    input logic domain_active,
    input logic wclk,
    input logic wrst,
    input logic w_cleared_phase,
    input logic wvalid,
    input logic wready,
    input logic [WIDTH-1:0] wdata,
    input logic sample_push,
    input logic rclk,
    input logic rclk_rose,
    input logic rrst,
    input logic prev_rrst,
    input logic r_cleared_phase,
    input logic rvalid,
    input logic rready,
    input logic [WIDTH-1:0] rdata,
    // Hierarchical FIFO state taps for inductive invariants.
    input logic [$clog2(DEPTH):0] fifo_wptr_bin,
    input logic [$clog2(DEPTH):0] fifo_wptr_gray,
    input logic [$clog2(DEPTH):0] fifo_rptr_sync0,
    input logic [$clog2(DEPTH):0] fifo_rptr_sync1,
    input logic [$clog2(DEPTH):0] fifo_rptr_bin_w,
    input logic [$clog2(DEPTH):0] fifo_rptr_bin,
    input logic [$clog2(DEPTH):0] fifo_rptr_gray,
    input logic [$clog2(DEPTH):0] fifo_wptr_sync0,
    input logic [$clog2(DEPTH):0] fifo_wptr_sync1,
    input logic fifo_rd_issued,
    input logic [1:0] fifo_skid_valid,
    input logic [WIDTH-1:0] fifo_skid_data0,
    input logic [WIDTH-1:0] fifo_skid_data1,
    input logic [WIDTH-1:0] fifo_ram_rdata,
    input logic [WIDTH-1:0] fifo_ram0,
    input logic [WIDTH-1:0] fifo_ram1,
    input logic [WIDTH-1:0] fifo_ram2,
    input logic [WIDTH-1:0] fifo_ram3
);
  localparam int unsigned AddrBits = $clog2(DEPTH);
  localparam int unsigned PtrBits  = AddrBits + 1;

  function automatic logic [PtrBits-1:0] bin2gray(input logic [PtrBits-1:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function automatic logic [PtrBits-1:0] gray2bin(input logic [PtrBits-1:0] g);
    logic [PtrBits-1:0] b;
    b[PtrBits-1] = g[PtrBits-1];
    for (int i = int'(PtrBits) - 2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    gray2bin = b;
  endfunction

  logic [PtrBits-1:0] f_wr_ptr = '0;
  logic [PtrBits-1:0] f_rd_ptr = '0;
  logic               f_watch_gen = 1'b0;
  logic               f_watch_ack = 1'b0;
  logic [PtrBits-1:0] f_watch_slot = '0;
  logic [  WIDTH-1:0] f_watch_data = '0;

  wire                f_watching = (f_watch_gen != f_watch_ack);

  always_ff @(posedge wclk) begin
    if (wrst) begin
      f_wr_ptr     <= '0;
      f_watch_gen  <= 1'b0;
      f_watch_slot <= '0;
      f_watch_data <= '0;
    end else if (wvalid && wready) begin
      f_wr_ptr <= f_wr_ptr + PtrBits'(1);
      if (!f_watching && sample_push) begin
        f_watch_gen  <= ~f_watch_gen;
        f_watch_slot <= f_wr_ptr;
        f_watch_data <= wdata;
      end
    end
  end

  always_ff @(posedge rclk) begin
    if (rrst) begin
      f_rd_ptr    <= '0;
      f_watch_ack <= 1'b0;
    end else if (rvalid && rready) begin
      f_rd_ptr <= f_rd_ptr + PtrBits'(1);
      if (f_watching && (f_rd_ptr == f_watch_slot)) begin
        f_watch_ack <= f_watch_gen;
      end
    end
  end

  logic             prev_domain_active = 1'b0;
  logic             prev_rvalid = 1'b0;
  logic             prev_rready = 1'b0;
  logic [WIDTH-1:0] prev_rdata = '0;
  logic             prev_watching = 1'b0;
  logic             prev_match_head = 1'b0;
  logic [WIDTH-1:0] prev_watch_data = '0;

  always_ff @(posedge gclk) begin
    prev_domain_active <= domain_active;
    prev_rvalid        <= rvalid;
    prev_rready        <= rready;
    prev_rdata         <= rdata;
    prev_watching      <= f_watching;
    prev_match_head    <= (f_rd_ptr == f_watch_slot);
    prev_watch_data    <= f_watch_data;
  end

  wire [PtrBits-1:0] f_inflight = f_wr_ptr - f_rd_ptr;

  always_comb begin
    if (f_init_done) begin
      // Interface restatements documenting the output reset-gate assigns in
      // axi_cdc.sv (lines 122, 167, 188, 209, 254) and async_fifo.sv (line 129):
      // a domain in reset asserts neither READY nor VALID, even before its clock
      // has produced an edge to clear uninitialized skid or FIFO registers.
      if (wrst) p_wrst_gates_ready : assert (!wready);
      if (rrst) p_rrst_gates_valid : assert (!rvalid);

      // AXI4 VALID and payload hold steady across non-edge ticks and unready edges.
      if (!prev_rrst && !rrst && prev_rvalid && !(rclk_rose && prev_rready)) begin
        p_hold_until_ready : assert (rvalid && (rdata == prev_rdata));
      end

      // Every popped beat consumed on a ready read-clock edge emerges in FIFO
      // order with intact payload.
      if (prev_domain_active && !rrst && rclk_rose && prev_rvalid && prev_rready &&
          prev_watching && prev_match_head) begin
        p_pop_order_and_data : assert (prev_rdata == prev_watch_data);
      end
    end

    if (domain_active) begin
      // Total unconsumed beats never exceed RAM + 2-skid capacity, and pops never lead pushes.
      p_inflight_bounded : assert (f_inflight <= PtrBits'(DEPTH + 2));

      if (rvalid) begin
        p_valid_implies_inflight : assert (f_inflight != '0);
        if (f_watching && (f_rd_ptr == f_watch_slot)) begin
          p_valid_head_data_exact : assert (rdata == f_watch_data);
        end
      end
    end
  end

  // Inductive invariants tying the reference counters and watched word to async_fifo state.
  wire  [PtrBits-1:0] w_bin_s0 = gray2bin(fifo_wptr_sync0);
  wire  [PtrBits-1:0] w_bin_s1 = gray2bin(fifo_wptr_sync1);
  wire  [PtrBits-1:0] r_bin_s0 = gray2bin(fifo_rptr_sync0);
  wire  [PtrBits-1:0] r_bin_s1 = gray2bin(fifo_rptr_sync1);
  wire  [        1:0] skid_cnt = {1'b0, fifo_skid_valid[0]} + {1'b0, fifo_skid_valid[1]};
  wire  [        1:0] pipe_cnt = skid_cnt + {1'b0, fifo_rd_issued};

  wire  [PtrBits-1:0] age_w1 = fifo_wptr_bin - w_bin_s0;
  wire  [PtrBits-1:0] age_w2 = fifo_wptr_bin - w_bin_s1;
  wire  [PtrBits-1:0] age_r0 = fifo_wptr_bin - fifo_rptr_bin;
  wire  [PtrBits-1:0] age_r1 = fifo_wptr_bin - r_bin_s0;
  wire  [PtrBits-1:0] age_r2 = fifo_wptr_bin - r_bin_s1;
  wire  [PtrBits-1:0] age_rw = fifo_wptr_bin - fifo_rptr_bin_w;
  wire  [PtrBits-1:0] age_rd = fifo_wptr_bin - f_rd_ptr;
  wire  [PtrBits-1:0] age_ws = fifo_wptr_bin - f_watch_slot;

  logic [  WIDTH-1:0] ram_at_watch;
  always_comb begin
    unique case (f_watch_slot[AddrBits-1:0])
      2'd0:    ram_at_watch = fifo_ram0;
      2'd1:    ram_at_watch = fifo_ram1;
      2'd2:    ram_at_watch = fifo_ram2;
      default: ram_at_watch = fifo_ram3;
    endcase
  end

  always_comb begin
    if (f_init_done) begin
      if (w_cleared_phase) begin
        p_inv_w_cleared :
        assert ((fifo_wptr_bin == '0) && (fifo_wptr_gray == '0) &&
                (fifo_rptr_sync0 == '0) && (fifo_rptr_sync1 == '0) &&
                (fifo_rptr_bin_w == '0) && (f_wr_ptr == '0) && !f_watch_gen);
      end
      if (r_cleared_phase) begin
        p_inv_r_cleared :
        assert ((fifo_rptr_bin == '0) && (fifo_rptr_gray == '0) &&
                (fifo_wptr_sync0 == '0) && (fifo_wptr_sync1 == '0) &&
                !fifo_rd_issued && (fifo_skid_valid == '0) &&
                (f_rd_ptr == '0) && !f_watch_ack);
      end

      if (domain_active) begin
        if (wrst) begin
          p_inv_w_rst_holds_r_idle :
          assert ((fifo_rptr_bin == '0) && (fifo_rptr_gray == '0) &&
                  (fifo_wptr_sync0 == '0) && (fifo_wptr_sync1 == '0) &&
                  !fifo_rd_issued && (fifo_skid_valid == '0) &&
                  (f_rd_ptr == '0) && !f_watch_ack);
        end
        p_inv_wgray : assert (fifo_wptr_gray == bin2gray(fifo_wptr_bin));
        p_inv_rgray : assert (fifo_rptr_gray == bin2gray(fifo_rptr_bin));
        p_inv_skid_shape : assert (!(fifo_skid_valid[1] && !fifo_skid_valid[0]));
        p_inv_pipe_bound : assert (({1'b0, skid_cnt} + {2'b0, fifo_rd_issued}) <= 3'd2);
        p_inv_wr_ptr_eq : assert (fifo_wptr_bin == f_wr_ptr);
        p_inv_rd_ptr_eq : assert (fifo_rptr_bin == (f_rd_ptr + PtrBits'(pipe_cnt)));
        p_inv_ptr_chain :
        assert ((age_w1 <= age_w2) && (age_w2 <= age_r0) && (age_r0 <= age_r1) &&
                (age_r1 <= age_r2) && (age_r2 <= age_rw) && (age_rw <= PtrBits'(DEPTH)));
        p_inv_rd_age_eq : assert (age_rd == (age_r0 + PtrBits'(pipe_cnt)));

        if (f_watching) begin
          p_inv_watch_in_range : assert ((age_ws != '0) && (age_ws <= age_rd));
          if (age_ws <= age_r0) begin
            p_inv_watch_in_ram : assert (ram_at_watch == f_watch_data);
          end else if (f_watch_slot == f_rd_ptr) begin
            if (fifo_skid_valid[0]) begin
              p_inv_watch_in_skid0 : assert (fifo_skid_data0 == f_watch_data);
            end else begin
              p_inv_watch_in_rdata_head : assert (fifo_ram_rdata == f_watch_data);
            end
          end else begin
            if (fifo_skid_valid[1]) begin
              p_inv_watch_in_skid1 : assert (fifo_skid_data1 == f_watch_data);
            end else begin
              p_inv_watch_in_rdata_tail : assert (fifo_ram_rdata == f_watch_data);
            end
          end
        end
      end
    end
  end
endmodule

// Multiclock formal harness for axi_cdc coupled to cdc_reset_pair and
// soc_top's 1-source-clock-skewed dma_cdc reset tree.
// In safety proofs (COVER_MODE=0), proves all five asynchronous AXI4 channels
// (AW, W, B, AR, R) unbounded by k-induction at READY_MARGIN=0 with zero AXI
// input assumptions under genuinely free clocks (arbitrary phase, ratio, and
// stopped clocks during reset), staggered reset release, runtime reset
// re-assertion after traffic, and unbounded RAM-entry reuse.
module axi_cdc_formal #(
    parameter int unsigned ADDR_WIDTH = 2,
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ID_WIDTH   = 1,
    parameter int unsigned USER_WIDTH = 1,
    parameter int unsigned DEPTH      = 4,
    // Bitmask of active channels: 0=AW, 1=W, 2=B, 3=AR, 4=R (31 = all five).
    parameter int unsigned CHECK_MASK = 31,
    parameter bit          COVER_MODE = 1'b0
) (
    (* gclk *) input logic gclk,
    input logic i_arst,
    input logic i_use_dma_src_skew,
    input logic i_free_src_clk,
    input logic i_free_dst_clk,
    input logic i_sample_push,
    input logic i_use_div_clks,
    input logic [1:0] i_clk_ratio,
    input logic [1:0] i_init_phase,
    input logic i_src_awvalid,
    input logic [ID_WIDTH-1:0] i_src_awid,
    input logic [ADDR_WIDTH-1:0] i_src_awaddr,
    input logic [7:0] i_src_awlen,
    input logic [2:0] i_src_awsize,
    input logic [1:0] i_src_awburst,
    input logic i_src_awlock,
    input logic [3:0] i_src_awcache,
    input logic [2:0] i_src_awprot,
    input logic [3:0] i_src_awqos,
    input logic [3:0] i_src_awregion,
    input logic [USER_WIDTH-1:0] i_src_awuser,
    input logic i_src_wvalid,
    input logic [DATA_WIDTH-1:0] i_src_wdata,
    input logic [DATA_WIDTH/8-1:0] i_src_wstrb,
    input logic i_src_wlast,
    input logic [USER_WIDTH-1:0] i_src_wuser,
    input logic i_src_bready,
    input logic i_src_arvalid,
    input logic [ID_WIDTH-1:0] i_src_arid,
    input logic [ADDR_WIDTH-1:0] i_src_araddr,
    input logic [7:0] i_src_arlen,
    input logic [2:0] i_src_arsize,
    input logic [1:0] i_src_arburst,
    input logic i_src_arlock,
    input logic [3:0] i_src_arcache,
    input logic [2:0] i_src_arprot,
    input logic [3:0] i_src_arqos,
    input logic [3:0] i_src_arregion,
    input logic [USER_WIDTH-1:0] i_src_aruser,
    input logic i_src_rready,
    input logic i_dst_awready,
    input logic i_dst_wready,
    input logic i_dst_bvalid,
    input logic [ID_WIDTH-1:0] i_dst_bid,
    input logic [1:0] i_dst_bresp,
    input logic [USER_WIDTH-1:0] i_dst_buser,
    input logic i_dst_arready,
    input logic i_dst_rvalid,
    input logic [ID_WIDTH-1:0] i_dst_rid,
    input logic [DATA_WIDTH-1:0] i_dst_rdata,
    input logic [1:0] i_dst_rresp,
    input logic i_dst_rlast,
    input logic [USER_WIDTH-1:0] i_dst_ruser
);

  localparam bit CheckAw = ((CHECK_MASK & 1) != 0);
  localparam bit CheckW = ((CHECK_MASK & 2) != 0);
  localparam bit CheckB = ((CHECK_MASK & 4) != 0);
  localparam bit CheckAr = ((CHECK_MASK & 8) != 0);
  localparam bit CheckR = ((CHECK_MASK & 16) != 0);

  localparam int unsigned CountBits = $clog2(DEPTH) + 2;
  localparam int unsigned AwWidth = ID_WIDTH + ADDR_WIDTH + 8 + 3 + 2 + 1 + 4 + 3 + 4 + 4 +
      USER_WIDTH;
  localparam int unsigned WWidth = DATA_WIDTH + (DATA_WIDTH / 8) + 1 + USER_WIDTH;
  localparam int unsigned BWidth = ID_WIDTH + 2 + USER_WIDTH;
  localparam int unsigned RWidth = ID_WIDTH + DATA_WIDTH + 2 + 1 + USER_WIDTH;

  // Symbolic-constant selector covering both direct cdc_reset_pair outputs and
  // soc_top's dma_cdc reset wiring (soc_top.sv:297-325, 1882-1892), where
  // i_dst_rst comes directly from cdc_reset_pair while i_src_rst is registered
  // one i_src_clk edge later in rst_core.
  wire use_dma_src_skew = i_use_dma_src_skew;

  logic f_init_done = 1'b0;
  logic use_dma_src_skew_q = 1'b0;
  logic [1:0] div_phase = '0;
  logic use_div_clks_q = 1'b0;
  logic [1:0] clk_ratio_q = '0;
  logic [1:0] init_phase_q = '0;

  always_ff @(posedge gclk) begin
    f_init_done        <= 1'b1;
    use_dma_src_skew_q <= i_use_dma_src_skew;
    use_div_clks_q     <= i_use_div_clks;
    clk_ratio_q        <= i_clk_ratio;
    init_phase_q       <= i_init_phase;
    if (!f_init_done) begin
      div_phase <= i_init_phase + 2'd1;
    end else begin
      div_phase <= div_phase + 2'd1;
    end
  end

  wire [1:0] cur_phase = f_init_done ? div_phase : i_init_phase;
  wire clk_div1 = ~cur_phase[0];
  wire clk_div2 = ~cur_phase[1];

  logic div_src_clk;
  logic div_dst_clk;
  always_comb begin
    unique case (i_clk_ratio)
      2'd0: begin
        div_src_clk = clk_div1;
        div_dst_clk = clk_div1;
      end
      2'd1: begin
        div_src_clk = clk_div1;
        div_dst_clk = clk_div2;
      end
      default: begin
        div_src_clk = clk_div2;
        div_dst_clk = clk_div1;
      end
    endcase
  end

  wire  use_div = COVER_MODE && i_use_div_clks;
  wire  i_src_clk = use_div ? div_src_clk : i_free_src_clk;
  wire  i_dst_clk = use_div ? div_dst_clk : i_free_dst_clk;

  logic prev_src_clk = 1'b0;
  logic prev_dst_clk = 1'b0;
  always_ff @(posedge gclk) begin
    prev_src_clk <= i_src_clk;
    prev_dst_clk <= i_dst_clk;
  end

  wire src_clk_rose = !prev_src_clk && i_src_clk;
  wire dst_clk_rose = !prev_dst_clk && i_dst_clk;

  // In safety proofs (COVER_MODE=0), i_use_dma_src_skew is a symbolic constant
  // and the ONLY environment assumption is reset on tick 0: clocks, AXI inputs,
  // and runtime reset re-assertions after tick 0 are completely unconstrained.
  always_comb begin
    if (!f_init_done) begin
      assume (i_arst);
    end else begin
      assume (i_use_dma_src_skew == use_dma_src_skew_q);
    end
    if (COVER_MODE) begin
      assume (i_clk_ratio <= 2'd2);
      if (f_init_done) begin
        assume (i_use_div_clks == use_div_clks_q);
        assume (i_clk_ratio == clk_ratio_q);
        assume (i_init_phase == init_phase_q);
        if (use_div) assume (!i_arst && i_src_awvalid && i_dst_awready);
      end
    end
  end

  logic pair_a_rst;
  logic pair_b_rst;
  cdc_reset_pair u_reset_pair (
      .i_arst (i_arst),
      .i_a_clk(i_src_clk),
      .i_b_clk(i_dst_clk),
      .o_a_rst(pair_a_rst),
      .o_b_rst(pair_b_rst)
  );

  logic rst_core_q = 1'b1;
  always_ff @(posedge i_src_clk) begin
    rst_core_q <= pair_a_rst;
  end

  wire  src_rst = use_dma_src_skew ? rst_core_q : pair_a_rst;
  wire  dst_rst = pair_b_rst;

  logic prev_src_rst = 1'b1;
  logic prev_dst_rst = 1'b1;
  always_ff @(posedge gclk) begin
    prev_src_rst <= src_rst;
    prev_dst_rst <= dst_rst;
  end

  wire domain_active = f_init_done && (!pair_a_rst || !pair_b_rst);
  wire src_cleared_phase = (use_dma_src_skew ? !u_reset_pair.a_reset :
                            !u_reset_pair.reset_a.chain_q[0]) && src_rst;
  wire dst_cleared_phase = !u_reset_pair.reset_b.chain_q[0] && dst_rst;

  logic o_src_awready;
  logic o_src_wready;
  logic o_src_bvalid;
  logic [ID_WIDTH-1:0] o_src_bid;
  logic [1:0] o_src_bresp;
  logic [USER_WIDTH-1:0] o_src_buser;
  logic o_src_arready;
  logic o_src_rvalid;
  logic [ID_WIDTH-1:0] o_src_rid;
  logic [DATA_WIDTH-1:0] o_src_rdata;
  logic [1:0] o_src_rresp;
  logic o_src_rlast;
  logic [USER_WIDTH-1:0] o_src_ruser;

  logic o_dst_awvalid;
  logic [ID_WIDTH-1:0] o_dst_awid;
  logic [ADDR_WIDTH-1:0] o_dst_awaddr;
  logic [7:0] o_dst_awlen;
  logic [2:0] o_dst_awsize;
  logic [1:0] o_dst_awburst;
  logic o_dst_awlock;
  logic [3:0] o_dst_awcache;
  logic [2:0] o_dst_awprot;
  logic [3:0] o_dst_awqos;
  logic [3:0] o_dst_awregion;
  logic [USER_WIDTH-1:0] o_dst_awuser;
  logic o_dst_wvalid;
  logic [DATA_WIDTH-1:0] o_dst_wdata;
  logic [DATA_WIDTH/8-1:0] o_dst_wstrb;
  logic o_dst_wlast;
  logic [USER_WIDTH-1:0] o_dst_wuser;
  logic o_dst_bready;
  logic o_dst_arvalid;
  logic [ID_WIDTH-1:0] o_dst_arid;
  logic [ADDR_WIDTH-1:0] o_dst_araddr;
  logic [7:0] o_dst_arlen;
  logic [2:0] o_dst_arsize;
  logic [1:0] o_dst_arburst;
  logic o_dst_arlock;
  logic [3:0] o_dst_arcache;
  logic [2:0] o_dst_arprot;
  logic [3:0] o_dst_arqos;
  logic [3:0] o_dst_arregion;
  logic [USER_WIDTH-1:0] o_dst_aruser;
  logic o_dst_rready;

  axi_cdc #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH),
      .ID_WIDTH  (ID_WIDTH),
      .USER_WIDTH(USER_WIDTH),
      .DEPTH     (DEPTH)
  ) dut (
      .i_src_clk     (i_src_clk),
      .i_src_rst     (src_rst),
      .i_dst_clk     (i_dst_clk),
      .i_dst_rst     (dst_rst),
      .i_src_awvalid (i_src_awvalid),
      .o_src_awready (o_src_awready),
      .i_src_awid    (i_src_awid),
      .i_src_awaddr  (i_src_awaddr),
      .i_src_awlen   (i_src_awlen),
      .i_src_awsize  (i_src_awsize),
      .i_src_awburst (i_src_awburst),
      .i_src_awlock  (i_src_awlock),
      .i_src_awcache (i_src_awcache),
      .i_src_awprot  (i_src_awprot),
      .i_src_awqos   (i_src_awqos),
      .i_src_awregion(i_src_awregion),
      .i_src_awuser  (i_src_awuser),
      .i_src_wvalid  (i_src_wvalid),
      .o_src_wready  (o_src_wready),
      .i_src_wdata   (i_src_wdata),
      .i_src_wstrb   (i_src_wstrb),
      .i_src_wlast   (i_src_wlast),
      .i_src_wuser   (i_src_wuser),
      .o_src_bvalid  (o_src_bvalid),
      .i_src_bready  (i_src_bready),
      .o_src_bid     (o_src_bid),
      .o_src_bresp   (o_src_bresp),
      .o_src_buser   (o_src_buser),
      .i_src_arvalid (i_src_arvalid),
      .o_src_arready (o_src_arready),
      .i_src_arid    (i_src_arid),
      .i_src_araddr  (i_src_araddr),
      .i_src_arlen   (i_src_arlen),
      .i_src_arsize  (i_src_arsize),
      .i_src_arburst (i_src_arburst),
      .i_src_arlock  (i_src_arlock),
      .i_src_arcache (i_src_arcache),
      .i_src_arprot  (i_src_arprot),
      .i_src_arqos   (i_src_arqos),
      .i_src_arregion(i_src_arregion),
      .i_src_aruser  (i_src_aruser),
      .o_src_rvalid  (o_src_rvalid),
      .i_src_rready  (i_src_rready),
      .o_src_rid     (o_src_rid),
      .o_src_rdata   (o_src_rdata),
      .o_src_rresp   (o_src_rresp),
      .o_src_rlast   (o_src_rlast),
      .o_src_ruser   (o_src_ruser),
      .o_dst_awvalid (o_dst_awvalid),
      .i_dst_awready (i_dst_awready),
      .o_dst_awid    (o_dst_awid),
      .o_dst_awaddr  (o_dst_awaddr),
      .o_dst_awlen   (o_dst_awlen),
      .o_dst_awsize  (o_dst_awsize),
      .o_dst_awburst (o_dst_awburst),
      .o_dst_awlock  (o_dst_awlock),
      .o_dst_awcache (o_dst_awcache),
      .o_dst_awprot  (o_dst_awprot),
      .o_dst_awqos   (o_dst_awqos),
      .o_dst_awregion(o_dst_awregion),
      .o_dst_awuser  (o_dst_awuser),
      .o_dst_wvalid  (o_dst_wvalid),
      .i_dst_wready  (i_dst_wready),
      .o_dst_wdata   (o_dst_wdata),
      .o_dst_wstrb   (o_dst_wstrb),
      .o_dst_wlast   (o_dst_wlast),
      .o_dst_wuser   (o_dst_wuser),
      .i_dst_bvalid  (i_dst_bvalid),
      .o_dst_bready  (o_dst_bready),
      .i_dst_bid     (i_dst_bid),
      .i_dst_bresp   (i_dst_bresp),
      .i_dst_buser   (i_dst_buser),
      .o_dst_arvalid (o_dst_arvalid),
      .i_dst_arready (i_dst_arready),
      .o_dst_arid    (o_dst_arid),
      .o_dst_araddr  (o_dst_araddr),
      .o_dst_arlen   (o_dst_arlen),
      .o_dst_arsize  (o_dst_arsize),
      .o_dst_arburst (o_dst_arburst),
      .o_dst_arlock  (o_dst_arlock),
      .o_dst_arcache (o_dst_arcache),
      .o_dst_arprot  (o_dst_arprot),
      .o_dst_arqos   (o_dst_arqos),
      .o_dst_arregion(o_dst_arregion),
      .o_dst_aruser  (o_dst_aruser),
      .i_dst_rvalid  (i_dst_rvalid),
      .o_dst_rready  (o_dst_rready),
      .i_dst_rid     (i_dst_rid),
      .i_dst_rdata   (i_dst_rdata),
      .i_dst_rresp   (i_dst_rresp),
      .i_dst_rlast   (i_dst_rlast),
      .i_dst_ruser   (i_dst_ruser)
  );

  wire [AwWidth-1:0] src_aw_pack = {
    i_src_awid,
    i_src_awaddr,
    i_src_awlen,
    i_src_awsize,
    i_src_awburst,
    i_src_awlock,
    i_src_awcache,
    i_src_awprot,
    i_src_awqos,
    i_src_awregion,
    i_src_awuser
  };
  wire [AwWidth-1:0] dst_aw_pack = {
    o_dst_awid,
    o_dst_awaddr,
    o_dst_awlen,
    o_dst_awsize,
    o_dst_awburst,
    o_dst_awlock,
    o_dst_awcache,
    o_dst_awprot,
    o_dst_awqos,
    o_dst_awregion,
    o_dst_awuser
  };
  wire [WWidth-1:0] src_w_pack = {i_src_wdata, i_src_wstrb, i_src_wlast, i_src_wuser};
  wire [WWidth-1:0] dst_w_pack = {o_dst_wdata, o_dst_wstrb, o_dst_wlast, o_dst_wuser};
  wire [BWidth-1:0] dst_b_pack = {i_dst_bid, i_dst_bresp, i_dst_buser};
  wire [BWidth-1:0] src_b_pack = {o_src_bid, o_src_bresp, o_src_buser};
  wire [AwWidth-1:0] src_ar_pack = {
    i_src_arid,
    i_src_araddr,
    i_src_arlen,
    i_src_arsize,
    i_src_arburst,
    i_src_arlock,
    i_src_arcache,
    i_src_arprot,
    i_src_arqos,
    i_src_arregion,
    i_src_aruser
  };
  wire [AwWidth-1:0] dst_ar_pack = {
    o_dst_arid,
    o_dst_araddr,
    o_dst_arlen,
    o_dst_arsize,
    o_dst_arburst,
    o_dst_arlock,
    o_dst_arcache,
    o_dst_arprot,
    o_dst_arqos,
    o_dst_arregion,
    o_dst_aruser
  };
  wire [RWidth-1:0] dst_r_pack = {i_dst_rid, i_dst_rdata, i_dst_rresp, i_dst_rlast, i_dst_ruser};
  wire [RWidth-1:0] src_r_pack = {o_src_rid, o_src_rdata, o_src_rresp, o_src_rlast, o_src_ruser};

  generate
    if (!COVER_MODE) begin : g_safety
      always_comb begin
        if (f_init_done) begin
          if (i_arst) begin
            p_reset_pair_async_assert : assert (pair_a_rst && pair_b_rst);
          end
          p_inv_rst_a_shift :
          assert (!u_reset_pair.reset_a.chain_q[0] || u_reset_pair.reset_a.chain_q[1]);
          p_inv_rst_b_shift :
          assert (!u_reset_pair.reset_b.chain_q[0] || u_reset_pair.reset_b.chain_q[1]);
          p_inv_peer_a_shift :
          assert (!u_reset_pair.peer_a.chain_q[0] || u_reset_pair.peer_a.chain_q[1]);
          p_inv_peer_b_shift :
          assert (!u_reset_pair.peer_b.chain_q[0] || u_reset_pair.peer_b.chain_q[1]);

          if (i_arst) begin
            p_inv_arst_chains :
            assert ((u_reset_pair.reset_a.chain_q == 2'b11) &&
                    (u_reset_pair.reset_b.chain_q == 2'b11));
          end
          if (u_reset_pair.a_reset) begin
            p_inv_a_holds_peer_a : assert (u_reset_pair.peer_a.chain_q == 2'b11);
          end
          if (u_reset_pair.b_reset) begin
            p_inv_b_holds_peer_b : assert (u_reset_pair.peer_b.chain_q == 2'b11);
          end
          if (!u_reset_pair.reset_a.chain_q[0] && pair_a_rst) begin
            p_inv_dma_skew_caught_up : assert (rst_core_q);
          end
        end
      end

      if (CheckAw) begin : g_aw
        axi_cdc_chan_check #(
            .WIDTH(AwWidth),
            .DEPTH(DEPTH)
        ) u_chk (
            .gclk           (gclk),
            .f_init_done    (f_init_done),
            .domain_active  (domain_active),
            .wclk           (i_src_clk),
            .wrst           (src_rst),
            .w_cleared_phase(src_cleared_phase),
            .wvalid         (i_src_awvalid),
            .wready         (o_src_awready),
            .wdata          (src_aw_pack),
            .sample_push    (i_sample_push),
            .rclk           (i_dst_clk),
            .rclk_rose      (dst_clk_rose),
            .rrst           (dst_rst),
            .prev_rrst      (prev_dst_rst),
            .r_cleared_phase(dst_cleared_phase),
            .rvalid         (o_dst_awvalid),
            .rready         (i_dst_awready),
            .rdata          (dst_aw_pack),
            .fifo_wptr_bin  (dut.aw_fifo.wptr_bin_q),
            .fifo_wptr_gray (dut.aw_fifo.wptr_gray_q),
            .fifo_rptr_sync0(dut.aw_fifo.sync_rptr.stage_q[0]),
            .fifo_rptr_sync1(dut.aw_fifo.sync_rptr.stage_q[1]),
            .fifo_rptr_bin_w(dut.aw_fifo.rptr_bin_w),
            .fifo_rptr_bin  (dut.aw_fifo.rptr_bin_q),
            .fifo_rptr_gray (dut.aw_fifo.rptr_gray_q),
            .fifo_wptr_sync0(dut.aw_fifo.sync_wptr.stage_q[0]),
            .fifo_wptr_sync1(dut.aw_fifo.sync_wptr.stage_q[1]),
            .fifo_rd_issued (dut.aw_fifo.rd_issued_q),
            .fifo_skid_valid(dut.aw_fifo.skid_valid_q),
            .fifo_skid_data0(dut.aw_fifo.skid_data_q[0]),
            .fifo_skid_data1(dut.aw_fifo.skid_data_q[1]),
            .fifo_ram_rdata (dut.aw_fifo.ram_rdata),
            .fifo_ram0      (dut.aw_fifo.storage.ram[0]),
            .fifo_ram1      (dut.aw_fifo.storage.ram[1]),
            .fifo_ram2      (dut.aw_fifo.storage.ram[2]),
            .fifo_ram3      (dut.aw_fifo.storage.ram[3])
        );
      end

      if (CheckW) begin : g_w
        axi_cdc_chan_check #(
            .WIDTH(WWidth),
            .DEPTH(DEPTH)
        ) u_chk (
            .gclk           (gclk),
            .f_init_done    (f_init_done),
            .domain_active  (domain_active),
            .wclk           (i_src_clk),
            .wrst           (src_rst),
            .w_cleared_phase(src_cleared_phase),
            .wvalid         (i_src_wvalid),
            .wready         (o_src_wready),
            .wdata          (src_w_pack),
            .sample_push    (i_sample_push),
            .rclk           (i_dst_clk),
            .rclk_rose      (dst_clk_rose),
            .rrst           (dst_rst),
            .prev_rrst      (prev_dst_rst),
            .r_cleared_phase(dst_cleared_phase),
            .rvalid         (o_dst_wvalid),
            .rready         (i_dst_wready),
            .rdata          (dst_w_pack),
            .fifo_wptr_bin  (dut.w_fifo.wptr_bin_q),
            .fifo_wptr_gray (dut.w_fifo.wptr_gray_q),
            .fifo_rptr_sync0(dut.w_fifo.sync_rptr.stage_q[0]),
            .fifo_rptr_sync1(dut.w_fifo.sync_rptr.stage_q[1]),
            .fifo_rptr_bin_w(dut.w_fifo.rptr_bin_w),
            .fifo_rptr_bin  (dut.w_fifo.rptr_bin_q),
            .fifo_rptr_gray (dut.w_fifo.rptr_gray_q),
            .fifo_wptr_sync0(dut.w_fifo.sync_wptr.stage_q[0]),
            .fifo_wptr_sync1(dut.w_fifo.sync_wptr.stage_q[1]),
            .fifo_rd_issued (dut.w_fifo.rd_issued_q),
            .fifo_skid_valid(dut.w_fifo.skid_valid_q),
            .fifo_skid_data0(dut.w_fifo.skid_data_q[0]),
            .fifo_skid_data1(dut.w_fifo.skid_data_q[1]),
            .fifo_ram_rdata (dut.w_fifo.ram_rdata),
            .fifo_ram0      (dut.w_fifo.storage.ram[0]),
            .fifo_ram1      (dut.w_fifo.storage.ram[1]),
            .fifo_ram2      (dut.w_fifo.storage.ram[2]),
            .fifo_ram3      (dut.w_fifo.storage.ram[3])
        );
      end

      if (CheckB) begin : g_b
        axi_cdc_chan_check #(
            .WIDTH(BWidth),
            .DEPTH(DEPTH)
        ) u_chk (
            .gclk           (gclk),
            .f_init_done    (f_init_done),
            .domain_active  (domain_active),
            .wclk           (i_dst_clk),
            .wrst           (dst_rst),
            .w_cleared_phase(dst_cleared_phase),
            .wvalid         (i_dst_bvalid),
            .wready         (o_dst_bready),
            .wdata          (dst_b_pack),
            .sample_push    (i_sample_push),
            .rclk           (i_src_clk),
            .rclk_rose      (src_clk_rose),
            .rrst           (src_rst),
            .prev_rrst      (prev_src_rst),
            .r_cleared_phase(src_cleared_phase),
            .rvalid         (o_src_bvalid),
            .rready         (i_src_bready),
            .rdata          (src_b_pack),
            .fifo_wptr_bin  (dut.b_fifo.wptr_bin_q),
            .fifo_wptr_gray (dut.b_fifo.wptr_gray_q),
            .fifo_rptr_sync0(dut.b_fifo.sync_rptr.stage_q[0]),
            .fifo_rptr_sync1(dut.b_fifo.sync_rptr.stage_q[1]),
            .fifo_rptr_bin_w(dut.b_fifo.rptr_bin_w),
            .fifo_rptr_bin  (dut.b_fifo.rptr_bin_q),
            .fifo_rptr_gray (dut.b_fifo.rptr_gray_q),
            .fifo_wptr_sync0(dut.b_fifo.sync_wptr.stage_q[0]),
            .fifo_wptr_sync1(dut.b_fifo.sync_wptr.stage_q[1]),
            .fifo_rd_issued (dut.b_fifo.rd_issued_q),
            .fifo_skid_valid(dut.b_fifo.skid_valid_q),
            .fifo_skid_data0(dut.b_fifo.skid_data_q[0]),
            .fifo_skid_data1(dut.b_fifo.skid_data_q[1]),
            .fifo_ram_rdata (dut.b_fifo.ram_rdata),
            .fifo_ram0      (dut.b_fifo.storage.ram[0]),
            .fifo_ram1      (dut.b_fifo.storage.ram[1]),
            .fifo_ram2      (dut.b_fifo.storage.ram[2]),
            .fifo_ram3      (dut.b_fifo.storage.ram[3])
        );
      end

      if (CheckAr) begin : g_ar
        axi_cdc_chan_check #(
            .WIDTH(AwWidth),
            .DEPTH(DEPTH)
        ) u_chk (
            .gclk           (gclk),
            .f_init_done    (f_init_done),
            .domain_active  (domain_active),
            .wclk           (i_src_clk),
            .wrst           (src_rst),
            .w_cleared_phase(src_cleared_phase),
            .wvalid         (i_src_arvalid),
            .wready         (o_src_arready),
            .wdata          (src_ar_pack),
            .sample_push    (i_sample_push),
            .rclk           (i_dst_clk),
            .rclk_rose      (dst_clk_rose),
            .rrst           (dst_rst),
            .prev_rrst      (prev_dst_rst),
            .r_cleared_phase(dst_cleared_phase),
            .rvalid         (o_dst_arvalid),
            .rready         (i_dst_arready),
            .rdata          (dst_ar_pack),
            .fifo_wptr_bin  (dut.ar_fifo.wptr_bin_q),
            .fifo_wptr_gray (dut.ar_fifo.wptr_gray_q),
            .fifo_rptr_sync0(dut.ar_fifo.sync_rptr.stage_q[0]),
            .fifo_rptr_sync1(dut.ar_fifo.sync_rptr.stage_q[1]),
            .fifo_rptr_bin_w(dut.ar_fifo.rptr_bin_w),
            .fifo_rptr_bin  (dut.ar_fifo.rptr_bin_q),
            .fifo_rptr_gray (dut.ar_fifo.rptr_gray_q),
            .fifo_wptr_sync0(dut.ar_fifo.sync_wptr.stage_q[0]),
            .fifo_wptr_sync1(dut.ar_fifo.sync_wptr.stage_q[1]),
            .fifo_rd_issued (dut.ar_fifo.rd_issued_q),
            .fifo_skid_valid(dut.ar_fifo.skid_valid_q),
            .fifo_skid_data0(dut.ar_fifo.skid_data_q[0]),
            .fifo_skid_data1(dut.ar_fifo.skid_data_q[1]),
            .fifo_ram_rdata (dut.ar_fifo.ram_rdata),
            .fifo_ram0      (dut.ar_fifo.storage.ram[0]),
            .fifo_ram1      (dut.ar_fifo.storage.ram[1]),
            .fifo_ram2      (dut.ar_fifo.storage.ram[2]),
            .fifo_ram3      (dut.ar_fifo.storage.ram[3])
        );
      end

      if (CheckR) begin : g_r
        axi_cdc_chan_check #(
            .WIDTH(RWidth),
            .DEPTH(DEPTH)
        ) u_chk (
            .gclk           (gclk),
            .f_init_done    (f_init_done),
            .domain_active  (domain_active),
            .wclk           (i_dst_clk),
            .wrst           (dst_rst),
            .w_cleared_phase(dst_cleared_phase),
            .wvalid         (i_dst_rvalid),
            .wready         (o_dst_rready),
            .wdata          (dst_r_pack),
            .sample_push    (i_sample_push),
            .rclk           (i_src_clk),
            .rclk_rose      (src_clk_rose),
            .rrst           (src_rst),
            .prev_rrst      (prev_src_rst),
            .r_cleared_phase(src_cleared_phase),
            .rvalid         (o_src_rvalid),
            .rready         (i_src_rready),
            .rdata          (src_r_pack),
            .fifo_wptr_bin  (dut.r_fifo.wptr_bin_q),
            .fifo_wptr_gray (dut.r_fifo.wptr_gray_q),
            .fifo_rptr_sync0(dut.r_fifo.sync_rptr.stage_q[0]),
            .fifo_rptr_sync1(dut.r_fifo.sync_rptr.stage_q[1]),
            .fifo_rptr_bin_w(dut.r_fifo.rptr_bin_w),
            .fifo_rptr_bin  (dut.r_fifo.rptr_bin_q),
            .fifo_rptr_gray (dut.r_fifo.rptr_gray_q),
            .fifo_wptr_sync0(dut.r_fifo.sync_wptr.stage_q[0]),
            .fifo_wptr_sync1(dut.r_fifo.sync_wptr.stage_q[1]),
            .fifo_rd_issued (dut.r_fifo.rd_issued_q),
            .fifo_skid_valid(dut.r_fifo.skid_valid_q),
            .fifo_skid_data0(dut.r_fifo.skid_data_q[0]),
            .fifo_skid_data1(dut.r_fifo.skid_data_q[1]),
            .fifo_ram_rdata (dut.r_fifo.ram_rdata),
            .fifo_ram0      (dut.r_fifo.storage.ram[0]),
            .fifo_ram1      (dut.r_fifo.storage.ram[1]),
            .fifo_ram2      (dut.r_fifo.storage.ram[2]),
            .fifo_ram3      (dut.r_fifo.storage.ram[3])
        );
      end
    end
  endgenerate

  generate
    if (COVER_MODE) begin : g_covers
      logic [CountBits-1:0] sat_aw_pushes = '0;
      logic [CountBits-1:0] sat_aw_pops = '0;
      logic [CountBits-1:0] sat_r_pops = '0;
      logic aw_delivered = 1'b0, w_delivered = 1'b0, b_delivered = 1'b0;
      logic ar_delivered = 1'b0, r_delivered = 1'b0;
      logic prev_dst_awvalid = 1'b0;
      logic saw_dma_skew_midflight_rst = 1'b0;
      logic saw_stopped_clock_in_rst = 1'b0;
      logic [2:0] dst_stopped_in_rst_ticks = '0;

      always_ff @(posedge i_src_clk) begin
        if (src_rst) begin
          sat_aw_pushes <= '0;
          sat_r_pops    <= '0;
          b_delivered   <= 1'b0;
          r_delivered   <= 1'b0;
        end else begin
          if (i_src_awvalid && o_src_awready && (sat_aw_pushes != {CountBits{1'b1}})) begin
            sat_aw_pushes <= sat_aw_pushes + CountBits'(1);
          end
          if (o_src_bvalid && i_src_bready) b_delivered <= 1'b1;
          if (o_src_rvalid && i_src_rready) begin
            r_delivered <= 1'b1;
            if (sat_r_pops != {CountBits{1'b1}}) sat_r_pops <= sat_r_pops + CountBits'(1);
          end
        end
      end

      always_ff @(posedge i_dst_clk) begin
        if (dst_rst) begin
          sat_aw_pops  <= '0;
          aw_delivered <= 1'b0;
          w_delivered  <= 1'b0;
          ar_delivered <= 1'b0;
        end else begin
          if (o_dst_awvalid && i_dst_awready) begin
            aw_delivered <= 1'b1;
            if (sat_aw_pops != {CountBits{1'b1}}) sat_aw_pops <= sat_aw_pops + CountBits'(1);
          end
          if (o_dst_wvalid && i_dst_wready) w_delivered <= 1'b1;
          if (o_dst_arvalid && i_dst_arready) ar_delivered <= 1'b1;
        end
      end

      always_ff @(posedge gclk) begin
        prev_dst_awvalid <= o_dst_awvalid;
        if (f_init_done) begin
          if (use_dma_src_skew && prev_dst_awvalid && i_arst && !src_rst && dst_rst) begin
            saw_dma_skew_midflight_rst <= 1'b1;
          end
          if (dst_stopped_in_rst_ticks == 3'd6) begin
            saw_stopped_clock_in_rst <= 1'b1;
          end
          if (dst_rst && !dst_clk_rose) begin
            if (dst_stopped_in_rst_ticks != 3'd7) begin
              dst_stopped_in_rst_ticks <= dst_stopped_in_rst_ticks + 3'd1;
            end
          end else begin
            dst_stopped_in_rst_ticks <= '0;
          end
        end
      end

      always_comb begin
        if (f_init_done) begin
          // Reach simultaneous bidirectional delivery across all five AXI channels.
          c_all_five_channels_delivered :
          cover (!use_div && aw_delivered && w_delivered && b_delivered && ar_delivered &&
                 r_delivered);

          // Reach full four-entry backpressure on AW at READY_MARGIN=0.
          c_aw_full_backpressure :
          cover (!use_div && !src_rst && !o_src_awready &&
                 ((sat_aw_pushes - sat_aw_pops) >= CountBits'(DEPTH)));

          // Reach RAM-entry reuse (>= DEPTH + 1 pushes and pops) on AW across 1:1, 2:1,
          // and 1:2 divided-clock ratios (excluding phase 3), plus R-channel reuse.
          c_aw_ram_reuse_1to1 :
          cover (use_div && (i_clk_ratio == 2'd0) && (sat_aw_pops >= CountBits'(DEPTH + 1)));
          c_aw_ram_reuse_2to1 :
          cover (use_div && (i_clk_ratio == 2'd1) && (i_init_phase != 2'd3) &&
                 (sat_aw_pops >= CountBits'(DEPTH + 1)));
          c_aw_ram_reuse_1to2 :
          cover (use_div && (i_clk_ratio == 2'd2) && (i_init_phase != 2'd3) &&
                 (sat_aw_pops >= CountBits'(DEPTH + 1)));
          c_r_ram_reuse : cover (!use_div && (sat_r_pops >= CountBits'(DEPTH + 1)));

          // Reach staggered reset release where source pushes before destination reset clears.
          c_staggered_reset_crossing :
          cover (!use_div && !src_rst && dst_rst && (sat_aw_pushes != '0));

          // Reach mid-traffic runtime reset with dma_cdc 1-cycle skew followed by post-reset delivery.
          c_post_traffic_dma_skew_reset_recovery :
          cover (!use_div && saw_dma_skew_midflight_rst && !src_rst && !dst_rst && aw_delivered);

          // Reach stopped destination clock held safely in reset across >= 6 ticks before release.
          c_stopped_clock_reset_hold :
          cover (!use_div && saw_stopped_clock_in_rst && !src_rst && !dst_rst && aw_delivered);
        end
      end
    end
  endgenerate

endmodule

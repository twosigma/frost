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
 * axi_mux: NUM_PORTS AXI4 slave ports onto one AXI4 master port.
 *
 * The downstream id is {port index, upstream id}, so B and R return to the
 * port named by their id's top bits, with that port's READY; their data is
 * broadcast. AW and AR are each granted round-robin, a burst at a time, and
 * a grant is held while the downstream VALID waits for READY. AW is granted
 * only to a port that also presents WVALID, so a master whose write data is
 * not ready cannot take the W channel ahead of the others; AXI4 lets a slave
 * wait for WVALID before AWREADY and forbids a master to wait for AWREADY
 * before WVALID. Each downstream AW handshake records {port, AWLEN} in a
 * W_DEPTH-entry FIFO, and W beats come from the port at its head, AWLEN + 1
 * of them per entry. A downstream AW is presented only while the FIFO has
 * room, so the downstream handshake, the port's handshake and the record are
 * one event.
 *
 * The mux holds no beat: VALID and payload pass down and READY up through
 * combinational paths, which AXI4 does not allow between the inputs and
 * outputs of one component. Connect it only between interfaces that drive
 * their outputs from registers and take their inputs into registers, as
 * soc_top does, and put an AXI register slice on any port that leaves the SoC.
 * Every port is synchronous to i_clk.
 */
module axi_mux #(
    parameter int unsigned NUM_PORTS = 2,
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 256,
    parameter int unsigned UP_ID_WIDTH = 4,
    parameter int unsigned W_DEPTH = 4,
    localparam int unsigned PortBits = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1,
    localparam int unsigned DownIdWidth = UP_ID_WIDTH + PortBits
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream AXI4 slave ports, packed per port.
    input  logic [NUM_PORTS-1:0]                   i_up_awvalid,
    output logic [NUM_PORTS-1:0]                   o_up_awready,
    input  logic [NUM_PORTS-1:0][ UP_ID_WIDTH-1:0] i_up_awid,
    input  logic [NUM_PORTS-1:0][  ADDR_WIDTH-1:0] i_up_awaddr,
    input  logic [NUM_PORTS-1:0][             7:0] i_up_awlen,
    input  logic [NUM_PORTS-1:0][             2:0] i_up_awsize,
    input  logic [NUM_PORTS-1:0][             1:0] i_up_awburst,
    input  logic [NUM_PORTS-1:0]                   i_up_awlock,
    input  logic [NUM_PORTS-1:0][             3:0] i_up_awcache,
    input  logic [NUM_PORTS-1:0][             2:0] i_up_awprot,
    input  logic [NUM_PORTS-1:0][             3:0] i_up_awqos,
    input  logic [NUM_PORTS-1:0]                   i_up_wvalid,
    output logic [NUM_PORTS-1:0]                   o_up_wready,
    input  logic [NUM_PORTS-1:0][  DATA_WIDTH-1:0] i_up_wdata,
    input  logic [NUM_PORTS-1:0][DATA_WIDTH/8-1:0] i_up_wstrb,
    input  logic [NUM_PORTS-1:0]                   i_up_wlast,
    output logic [NUM_PORTS-1:0]                   o_up_bvalid,
    input  logic [NUM_PORTS-1:0]                   i_up_bready,
    output logic [NUM_PORTS-1:0][ UP_ID_WIDTH-1:0] o_up_bid,
    output logic [NUM_PORTS-1:0][             1:0] o_up_bresp,
    input  logic [NUM_PORTS-1:0]                   i_up_arvalid,
    output logic [NUM_PORTS-1:0]                   o_up_arready,
    input  logic [NUM_PORTS-1:0][ UP_ID_WIDTH-1:0] i_up_arid,
    input  logic [NUM_PORTS-1:0][  ADDR_WIDTH-1:0] i_up_araddr,
    input  logic [NUM_PORTS-1:0][             7:0] i_up_arlen,
    input  logic [NUM_PORTS-1:0][             2:0] i_up_arsize,
    input  logic [NUM_PORTS-1:0][             1:0] i_up_arburst,
    input  logic [NUM_PORTS-1:0]                   i_up_arlock,
    input  logic [NUM_PORTS-1:0][             3:0] i_up_arcache,
    input  logic [NUM_PORTS-1:0][             2:0] i_up_arprot,
    input  logic [NUM_PORTS-1:0][             3:0] i_up_arqos,
    output logic [NUM_PORTS-1:0]                   o_up_rvalid,
    input  logic [NUM_PORTS-1:0]                   i_up_rready,
    output logic [NUM_PORTS-1:0][ UP_ID_WIDTH-1:0] o_up_rid,
    output logic [NUM_PORTS-1:0][  DATA_WIDTH-1:0] o_up_rdata,
    output logic [NUM_PORTS-1:0][             1:0] o_up_rresp,
    output logic [NUM_PORTS-1:0]                   o_up_rlast,

    // Downstream AXI4 master.
    output logic                    o_dn_awvalid,
    input  logic                    i_dn_awready,
    output logic [ DownIdWidth-1:0] o_dn_awid,
    output logic [  ADDR_WIDTH-1:0] o_dn_awaddr,
    output logic [             7:0] o_dn_awlen,
    output logic [             2:0] o_dn_awsize,
    output logic [             1:0] o_dn_awburst,
    output logic                    o_dn_awlock,
    output logic [             3:0] o_dn_awcache,
    output logic [             2:0] o_dn_awprot,
    output logic [             3:0] o_dn_awqos,
    output logic                    o_dn_wvalid,
    input  logic                    i_dn_wready,
    output logic [  DATA_WIDTH-1:0] o_dn_wdata,
    output logic [DATA_WIDTH/8-1:0] o_dn_wstrb,
    output logic                    o_dn_wlast,
    input  logic                    i_dn_bvalid,
    output logic                    o_dn_bready,
    input  logic [ DownIdWidth-1:0] i_dn_bid,
    input  logic [             1:0] i_dn_bresp,
    output logic                    o_dn_arvalid,
    input  logic                    i_dn_arready,
    output logic [ DownIdWidth-1:0] o_dn_arid,
    output logic [  ADDR_WIDTH-1:0] o_dn_araddr,
    output logic [             7:0] o_dn_arlen,
    output logic [             2:0] o_dn_arsize,
    output logic [             1:0] o_dn_arburst,
    output logic                    o_dn_arlock,
    output logic [             3:0] o_dn_arcache,
    output logic [             2:0] o_dn_arprot,
    output logic [             3:0] o_dn_arqos,
    input  logic                    i_dn_rvalid,
    output logic                    o_dn_rready,
    input  logic [ DownIdWidth-1:0] i_dn_rid,
    input  logic [  DATA_WIDTH-1:0] i_dn_rdata,
    input  logic [             1:0] i_dn_rresp,
    input  logic                    i_dn_rlast
);
  localparam int unsigned WBits = $clog2(W_DEPTH);
  localparam int unsigned WCountBits = $clog2(W_DEPTH + 1);

  initial begin
    if (NUM_PORTS < 1) $fatal(1, "axi_mux: NUM_PORTS must be >= 1");
    if (W_DEPTH < 2 || (W_DEPTH & (W_DEPTH - 1)) != 0)
      $fatal(1, "axi_mux: W_DEPTH must be a power of two, at least 2");
  end

  // The first requesting port at or after a round-robin pointer.
  function automatic logic [PortBits-1:0] rr_pick(input logic [NUM_PORTS-1:0] req,
                                                  input logic [PortBits-1:0] start);
    logic found;
    rr_pick = start;
    found   = 1'b0;
    for (int k = 0; k < int'(NUM_PORTS); k++) begin
      logic [PortBits-1:0] p;
      p = PortBits'((32'(start) + 32'(k)) % NUM_PORTS);
      if (!found && req[p]) begin
        rr_pick = p;
        found   = 1'b1;
      end
    end
  endfunction

  function automatic logic [PortBits-1:0] rr_next(input logic [PortBits-1:0] port);
    rr_next = (32'(port) + 1 == NUM_PORTS) ? '0 : port + 1'b1;
  endfunction

  // ---- AW -------------------------------------------------------------------------------
  logic [WCountBits-1:0] wq_count_q;
  logic [WBits-1:0] wq_head_q, wq_tail_q;
  logic [PortBits-1:0] wq_port_q[W_DEPTH];
  logic [7:0] wq_len_q[W_DEPTH];
  logic wq_room;
  assign wq_room = 32'(wq_count_q) < W_DEPTH;

  logic aw_hold_q;
  logic [PortBits-1:0] aw_sel_q, aw_rr_q, aw_sel;
  logic [NUM_PORTS-1:0] aw_cand;
  logic aw_any;
  assign aw_cand = i_up_awvalid & i_up_wvalid;
  assign aw_sel = aw_hold_q ? aw_sel_q : rr_pick(aw_cand, aw_rr_q);
  assign aw_any = aw_hold_q || (|aw_cand);

  assign o_dn_awvalid = !i_rst && aw_any && wq_room;
  assign o_dn_awid = {aw_sel, i_up_awid[aw_sel]};
  assign o_dn_awaddr = i_up_awaddr[aw_sel];
  assign o_dn_awlen = i_up_awlen[aw_sel];
  assign o_dn_awsize = i_up_awsize[aw_sel];
  assign o_dn_awburst = i_up_awburst[aw_sel];
  assign o_dn_awlock = i_up_awlock[aw_sel];
  assign o_dn_awcache = i_up_awcache[aw_sel];
  assign o_dn_awprot = i_up_awprot[aw_sel];
  assign o_dn_awqos = i_up_awqos[aw_sel];
  logic aw_fire;
  assign aw_fire = o_dn_awvalid && i_dn_awready;
  always_comb begin
    for (int p = 0; p < int'(NUM_PORTS); p++) o_up_awready[p] = aw_fire && (aw_sel == PortBits'(p));
  end

  // ---- W --------------------------------------------------------------------------------
  logic [7:0] w_beat_q;
  logic wq_any;
  logic [PortBits-1:0] w_port;
  assign wq_any = wq_count_q != '0;
  assign w_port = wq_port_q[wq_head_q];

  assign o_dn_wvalid = !i_rst && wq_any && i_up_wvalid[w_port];
  assign o_dn_wdata = i_up_wdata[w_port];
  assign o_dn_wstrb = i_up_wstrb[w_port];
  assign o_dn_wlast = i_up_wlast[w_port];
  logic w_fire, w_pop;
  assign w_fire = o_dn_wvalid && i_dn_wready;
  assign w_pop  = w_fire && (w_beat_q == wq_len_q[wq_head_q]);
  always_comb begin
    for (int p = 0; p < int'(NUM_PORTS); p++) o_up_wready[p] = w_fire && (w_port == PortBits'(p));
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      aw_hold_q  <= 1'b0;
      aw_rr_q    <= '0;
      wq_count_q <= '0;
      wq_head_q  <= '0;
      wq_tail_q  <= '0;
      w_beat_q   <= '0;
    end else begin
      aw_hold_q <= o_dn_awvalid && !i_dn_awready;
      aw_sel_q  <= aw_sel;
      if (aw_fire) begin
        aw_rr_q              <= rr_next(aw_sel);
        wq_port_q[wq_tail_q] <= aw_sel;
        wq_len_q[wq_tail_q]  <= i_up_awlen[aw_sel];
        wq_tail_q            <= wq_tail_q + 1'b1;
      end
      wq_count_q <= wq_count_q + WCountBits'(aw_fire) - WCountBits'(w_pop);
      if (w_pop) begin
        wq_head_q <= wq_head_q + 1'b1;
        w_beat_q  <= '0;
      end else if (w_fire) begin
        w_beat_q <= w_beat_q + 8'd1;
      end
    end
  end

  // ---- AR -------------------------------------------------------------------------------
  logic ar_hold_q;
  logic [PortBits-1:0] ar_sel_q, ar_rr_q, ar_sel;
  logic ar_any;
  assign ar_sel = ar_hold_q ? ar_sel_q : rr_pick(i_up_arvalid, ar_rr_q);
  assign ar_any = ar_hold_q || (|i_up_arvalid);

  assign o_dn_arvalid = !i_rst && ar_any;
  assign o_dn_arid = {ar_sel, i_up_arid[ar_sel]};
  assign o_dn_araddr = i_up_araddr[ar_sel];
  assign o_dn_arlen = i_up_arlen[ar_sel];
  assign o_dn_arsize = i_up_arsize[ar_sel];
  assign o_dn_arburst = i_up_arburst[ar_sel];
  assign o_dn_arlock = i_up_arlock[ar_sel];
  assign o_dn_arcache = i_up_arcache[ar_sel];
  assign o_dn_arprot = i_up_arprot[ar_sel];
  assign o_dn_arqos = i_up_arqos[ar_sel];
  logic ar_fire;
  assign ar_fire = o_dn_arvalid && i_dn_arready;
  always_comb begin
    for (int p = 0; p < int'(NUM_PORTS); p++) o_up_arready[p] = ar_fire && (ar_sel == PortBits'(p));
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ar_hold_q <= 1'b0;
      ar_rr_q   <= '0;
    end else begin
      ar_hold_q <= o_dn_arvalid && !i_dn_arready;
      ar_sel_q  <= ar_sel;
      if (ar_fire) ar_rr_q <= rr_next(ar_sel);
    end
  end

  // ---- B and R: steered by the id's port bits ---------------------------------------------
  logic [PortBits-1:0] b_port, r_port;
  assign b_port = i_dn_bid[DownIdWidth-1-:PortBits];
  assign r_port = i_dn_rid[DownIdWidth-1-:PortBits];
  assign o_dn_bready = i_up_bready[b_port];
  assign o_dn_rready = i_up_rready[r_port];
  always_comb begin
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      o_up_bvalid[p] = i_dn_bvalid && (b_port == PortBits'(p));
      o_up_bid[p]    = i_dn_bid[UP_ID_WIDTH-1:0];
      o_up_bresp[p]  = i_dn_bresp;
      o_up_rvalid[p] = i_dn_rvalid && (r_port == PortBits'(p));
      o_up_rid[p]    = i_dn_rid[UP_ID_WIDTH-1:0];
      o_up_rdata[p]  = i_dn_rdata;
      o_up_rresp[p]  = i_dn_rresp;
      o_up_rlast[p]  = i_dn_rlast;
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      if (i_dn_bvalid && (32'(b_port) >= NUM_PORTS))
        $error("axi_mux: B for nonexistent port %0d", b_port);
      if (i_dn_rvalid && (32'(r_port) >= NUM_PORTS))
        $error("axi_mux: R for nonexistent port %0d", r_port);
      if (w_fire && (o_dn_wlast != w_pop))
        $error(
            "axi_mux: WLAST %0d from port %0d on beat %0d of %0d",
            o_dn_wlast,
            w_port,
            w_beat_q,
            32'(wq_len_q[wq_head_q]) + 1
        );
    end
  end
`endif
`endif

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Formal environment and properties (formal/axi_mux.sby): AXI4 masters
  // upstream, an AXI4 slave downstream that answers only what it accepted,
  // and a reference FIFO of AW grants that every W beat must follow.
  // ---------------------------------------------------------------------------
  initial assume (i_rst);
  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  localparam int unsigned FDepth = 2 * W_DEPTH;  // a power of two above the FIFO's depth
  localparam int unsigned FBits = $clog2(FDepth + 1);

  // The masters hold VALID and payload until READY and are quiet in reset.
  always @(posedge i_clk) begin
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      if (i_rst) begin
        assume (!i_up_awvalid[p] && !i_up_wvalid[p] && !i_up_arvalid[p]);
      end else if (f_past_valid && !$past(i_rst)) begin
        if ($past(i_up_awvalid[p] && !o_up_awready[p]))
          assume (i_up_awvalid[p] && $stable(
              {i_up_awid[p], i_up_awaddr[p], i_up_awlen[p], i_up_awsize[p], i_up_awburst[p]}
          ));
        if ($past(i_up_wvalid[p] && !o_up_wready[p]))
          assume (i_up_wvalid[p] && $stable({i_up_wdata[p], i_up_wstrb[p], i_up_wlast[p]}));
        if ($past(i_up_arvalid[p] && !o_up_arready[p]))
          assume (i_up_arvalid[p] && $stable(
              {i_up_arid[p], i_up_araddr[p], i_up_arlen[p], i_up_arsize[p], i_up_arburst[p]}
          ));
      end
    end
  end

  // The slave answers only the bursts it accepted, per port, and holds its
  // responses until READY.
  logic [NUM_PORTS-1:0][FBits-1:0] f_b_owed, f_r_owed;
  always @(posedge i_clk) begin
    if (i_rst) begin
      f_b_owed <= '0;
      f_r_owed <= '0;
    end else begin
      for (int p = 0; p < int'(NUM_PORTS); p++) begin
        f_b_owed[p] <= f_b_owed[p] + FBits'(aw_fire && (aw_sel == PortBits'(p))) -
            FBits'(i_dn_bvalid && o_dn_bready && (b_port == PortBits'(p)));
        f_r_owed[p] <= f_r_owed[p] + FBits'(ar_fire && (ar_sel == PortBits'(p))) -
            FBits'(i_dn_rvalid && o_dn_rready && i_dn_rlast && (r_port == PortBits'(p)));
      end
    end
  end
  always_comb begin
    if (i_rst || !f_past_valid) assume (!i_dn_bvalid && !i_dn_rvalid);
    if (i_dn_bvalid) assume ((32'(b_port) < NUM_PORTS) && (f_b_owed[b_port] != '0));
    if (i_dn_rvalid) assume ((32'(r_port) < NUM_PORTS) && (f_r_owed[r_port] != '0));
    // The slave's bounded acceptance keeps the reference counters in range.
    for (int p = 0; p < int'(NUM_PORTS); p++) begin
      if (f_b_owed[p] == FBits'(FDepth)) assume (!(aw_fire && (aw_sel == PortBits'(p))));
      if (f_r_owed[p] == FBits'(FDepth)) assume (!(ar_fire && (ar_sel == PortBits'(p))));
    end
  end
  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(i_dn_bvalid && !o_dn_bready))
        assume (i_dn_bvalid && $stable({i_dn_bid, i_dn_bresp}));
      if ($past(i_dn_rvalid && !o_dn_rready))
        assume (i_dn_rvalid && $stable({i_dn_rid, i_dn_rdata, i_dn_rresp, i_dn_rlast}));
    end
  end

  // Reference: AW grants in order, with their beat counts. Indexes are sized
  // variables, so every sum wraps at its width.
  localparam int unsigned FIdxBits = $clog2(FDepth);
  logic [PortBits-1:0] f_wq_port[FDepth];
  logic [7:0] f_wq_len[FDepth];
  logic [FIdxBits-1:0] f_wq_head, f_wq_tail, f_wq_next;
  logic [FBits-1:0] f_wq_count;
  logic [7:0] f_w_beat;
  assign f_wq_tail = f_wq_head + FIdxBits'(f_wq_count);
  assign f_wq_next = f_wq_head + 1'b1;
  always @(posedge i_clk) begin
    if (i_rst) begin
      f_wq_head  <= '0;
      f_wq_count <= '0;
      f_w_beat   <= '0;
    end else begin
      if (aw_fire) begin
        f_wq_port[f_wq_tail] <= o_dn_awid[DownIdWidth-1-:PortBits];
        f_wq_len[f_wq_tail]  <= o_dn_awlen;
      end
      f_wq_count <= f_wq_count + FBits'(aw_fire) -
          FBits'(w_fire && (f_w_beat == f_wq_len[f_wq_head]));
      if (w_fire) begin
        if (f_w_beat == f_wq_len[f_wq_head]) begin
          f_w_beat  <= '0;
          f_wq_head <= f_wq_next;
        end else begin
          f_w_beat <= f_w_beat + 8'd1;
        end
      end
    end
  end

  // The reference mapped onto the mux's FIFO and grant state.
  logic [WBits-1:0] f_rtl_idx[W_DEPTH], f_rtl_tail;
  logic [FIdxBits-1:0] f_ref_idx[W_DEPTH];
  always_comb begin
    for (int j = 0; j < int'(W_DEPTH); j++) begin
      f_rtl_idx[j] = wq_head_q + WBits'(j);
      f_ref_idx[j] = f_wq_head + FIdxBits'(j);
    end
    f_rtl_tail = wq_head_q + WBits'(wq_count_q);
  end
  always_comb begin
    if (!i_rst && f_past_valid) begin
      h_wq :
      assert ((32'(f_wq_count) == 32'(wq_count_q)) && (f_w_beat == w_beat_q) &&
              (wq_tail_q == f_rtl_tail));
      for (int j = 0; j < int'(W_DEPTH); j++) begin
        // h_wq_entry
        if (32'(j) < 32'(wq_count_q))
          assert ((wq_port_q[f_rtl_idx[j]] == f_wq_port[f_ref_idx[j]]) &&
                  (wq_len_q[f_rtl_idx[j]] == f_wq_len[f_ref_idx[j]]) &&
                  (32'(wq_port_q[f_rtl_idx[j]]) < NUM_PORTS));
      end
      h_w_beat : assert ((wq_count_q != '0) ? (w_beat_q <= wq_len_q[wq_head_q]) : (w_beat_q == '0));
      h_sel_ports :
      assert ((!aw_hold_q || (32'(aw_sel_q) < NUM_PORTS)) &&
              (!ar_hold_q || (32'(ar_sel_q) < NUM_PORTS)) &&
              (32'(aw_rr_q) < NUM_PORTS) && (32'(ar_rr_q) < NUM_PORTS));
      // A held grant's master still presents its request, as the AXI rules
      // assumed above require.
      if (aw_hold_q) h_aw_hold_valid : assert (i_up_awvalid[aw_sel_q]);
      if (ar_hold_q) h_ar_hold_valid : assert (i_up_arvalid[ar_sel_q]);
    end
  end

  always_comb begin
    if (i_rst) begin
      p_quiet_in_reset :
      assert (!o_dn_awvalid && !o_dn_wvalid && !o_dn_arvalid && !(|o_up_awready) &&
                                 !(|o_up_wready) && !(|o_up_arready));
    end
    if (!i_rst && f_past_valid) begin
      p_wq_bounded : assert (32'(f_wq_count) <= W_DEPTH);
      // A downstream AW is one upstream AW, of the port its id names.
      if (aw_fire) begin
        p_aw_one_port :
        assert (o_up_awready == (NUM_PORTS'(1) << o_dn_awid[DownIdWidth-1-:PortBits]));
        p_aw_payload :
        assert ((o_dn_awid[UP_ID_WIDTH-1:0] == i_up_awid[aw_sel]) &&
                               (o_dn_awaddr == i_up_awaddr[aw_sel]) &&
                               (o_dn_awlen == i_up_awlen[aw_sel]) && i_up_awvalid[aw_sel]);
      end else begin
        p_aw_none : assert (o_up_awready == '0);
      end
      if (ar_fire) begin
        p_ar_one_port :
        assert (o_up_arready == (NUM_PORTS'(1) << o_dn_arid[DownIdWidth-1-:PortBits]));
        p_ar_payload :
        assert ((o_dn_arid[UP_ID_WIDTH-1:0] == i_up_arid[ar_sel]) &&
                               (o_dn_araddr == i_up_araddr[ar_sel]) && i_up_arvalid[ar_sel]);
      end else begin
        p_ar_none : assert (o_up_arready == '0);
      end
      // W follows the AW grants: from the oldest granted burst's port only.
      if (o_dn_wvalid) begin
        p_w_after_aw : assert (f_wq_count != '0);
        p_w_from_head :
        assert ((w_port == f_wq_port[f_wq_head]) &&
                                (o_dn_wdata == i_up_wdata[f_wq_port[f_wq_head]]) &&
                                (o_dn_wstrb == i_up_wstrb[f_wq_port[f_wq_head]]));
      end
      if (w_fire)
        p_w_one_port :
        assert (o_up_wready == (NUM_PORTS'(1) << f_wq_port[f_wq_head]));
        else p_w_none : assert (o_up_wready == '0);
      // B and R reach the port their id names, with that port's READY.
      for (int p = 0; p < int'(NUM_PORTS); p++) begin
        assert (o_up_bvalid[p] == (i_dn_bvalid && (b_port == PortBits'(p))));
        assert (o_up_rvalid[p] == (i_dn_rvalid && (r_port == PortBits'(p))));
        if (o_up_bvalid[p]) assert (o_up_bid[p] == i_dn_bid[UP_ID_WIDTH-1:0]);
        if (o_up_rvalid[p])
          assert ((o_up_rid[p] == i_dn_rid[UP_ID_WIDTH-1:0]) && (o_up_rdata[p] == i_dn_rdata));
      end
      if (i_dn_bvalid) p_b_ready_routed : assert (o_dn_bready == i_up_bready[b_port]);
      if (i_dn_rvalid) p_r_ready_routed : assert (o_dn_rready == i_up_rready[r_port]);
    end
  end

  // As a master the mux holds its downstream VALIDs and payloads.
  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_dn_awvalid && !i_dn_awready))
        p_dn_aw_held : assert (o_dn_awvalid && $stable({o_dn_awid, o_dn_awaddr, o_dn_awlen}));
      if ($past(o_dn_arvalid && !i_dn_arready))
        p_dn_ar_held : assert (o_dn_arvalid && $stable({o_dn_arid, o_dn_araddr, o_dn_arlen}));
      if ($past(o_dn_wvalid && !i_dn_wready))
        p_dn_w_held : assert (o_dn_wvalid && $stable({o_dn_wdata, o_dn_wstrb, o_dn_wlast}));
    end
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      c_two_ports_queued :
      cover ((f_wq_count >= FBits'(2)) && (f_wq_port[f_wq_head] != f_wq_port[f_wq_next]));
      c_aw_held_then_taken : cover ($past(aw_hold_q) && aw_fire);
      c_multi_beat_w : cover (w_fire && (f_w_beat != '0));
      c_b_and_r_to_ports : cover (i_dn_bvalid && i_dn_rvalid && (b_port != r_port));
    end
  end
`endif

endmodule : axi_mux

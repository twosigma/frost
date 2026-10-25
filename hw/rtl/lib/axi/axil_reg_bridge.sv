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
 * AXI4-Lite slave for 32-bit register writes and aligned 64-bit read pairs.
 * AW and W are buffered independently. One read or write, including its
 * response, occupies the bridge at a time. AxPROT is accepted and ignored.
 * WIDE_OFFSETS lists complete 64-bit registers, least-significant entry
 * first. Partial writes to their dwords have no effect and return OKAY.
 */
module axil_reg_bridge #(
    parameter int unsigned ADDR_BITS = 12,
    parameter int unsigned WIDE_COUNT = 2,
    parameter logic [WIDE_COUNT*ADDR_BITS-1:0] WIDE_OFFSETS = {ADDR_BITS'('h078), ADDR_BITS'('h070)}
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_axil_awvalid,
    output logic o_axil_awready,
    input logic [ADDR_BITS-1:0] i_axil_awaddr,
    input logic [2:0] i_axil_awprot,
    input logic i_axil_wvalid,
    output logic o_axil_wready,
    input logic [63:0] i_axil_wdata,
    input logic [7:0] i_axil_wstrb,
    output logic o_axil_bvalid,
    input logic i_axil_bready,
    output logic [1:0] o_axil_bresp,
    input logic i_axil_arvalid,
    output logic o_axil_arready,
    input logic [ADDR_BITS-1:0] i_axil_araddr,
    input logic [2:0] i_axil_arprot,
    output logic o_axil_rvalid,
    input logic i_axil_rready,
    output logic [63:0] o_axil_rdata,
    output logic [1:0] o_axil_rresp,
    output logic o_wr_en,
    output logic [ADDR_BITS-1:0] o_wr_offset,
    output logic [31:0] o_wr_data,
    output logic o_wr64_en,
    output logic [63:0] o_wr64_data,
    output logic [ADDR_BITS-1:0] o_rd_offset,
    input logic [63:0] i_rd_pair
);
  typedef enum logic [2:0] {
    Idle,
    Write,
    WriteResp,
    Read,
    ReadData,
    ReadResp
  } state_t;
  state_t state_q;
  logic aw_pending_q, w_pending_q;
  logic [ADDR_BITS-1:0] awaddr_q, araddr_q;
  logic [63:0] wdata_q;
  logic [ 7:0] wstrb_q;
  logic write_apply, wide_dword, wide_address, wr_hi;

  initial begin
    if (ADDR_BITS < 4) $fatal(1, "axil_reg_bridge: ADDR_BITS must be at least 4");
    for (int k = 0; k < WIDE_COUNT; k++) begin
      if (WIDE_OFFSETS[k*ADDR_BITS+:3] != 0)
        $fatal(1, "axil_reg_bridge: wide offsets must be dword aligned");
    end
  end

  // Readiness depends only on the selected transaction and its buffers.
  assign o_axil_awready = !i_rst && state_q == Write && !aw_pending_q;
  assign o_axil_wready = !i_rst && state_q == Write && !w_pending_q;
  assign o_axil_arready = !i_rst && state_q == Read;
  assign o_axil_bvalid = !i_rst && state_q == WriteResp;
  assign o_axil_rvalid = !i_rst && state_q == ReadResp;
  assign o_axil_bresp = 2'b00;
  assign o_axil_rresp = 2'b00;
  assign write_apply = !i_rst && state_q == Write && aw_pending_q && w_pending_q;
  always_comb begin
    wide_dword   = 1'b0;
    wide_address = 1'b0;
    for (int k = 0; k < WIDE_COUNT; k++) begin
      wide_dword |= awaddr_q[ADDR_BITS-1:3] == WIDE_OFFSETS[k*ADDR_BITS+3+:ADDR_BITS-3];
      wide_address |= awaddr_q == WIDE_OFFSETS[k*ADDR_BITS+:ADDR_BITS];
    end
  end
  assign wr_hi = |wstrb_q[7:4];
  assign o_wr64_en = write_apply && &wstrb_q && wide_address;
  assign o_wr_en = write_apply && |wstrb_q && !wide_dword;
  assign o_wr_offset = o_wr64_en ? awaddr_q : {awaddr_q[ADDR_BITS-1:3], wr_hi, 2'b00};
  assign o_wr_data = wr_hi ? wdata_q[63:32] : wdata_q[31:0];
  assign o_wr64_data = wdata_q;
  assign o_rd_offset = {araddr_q[ADDR_BITS-1:3], 3'b000};

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q <= Idle;
      aw_pending_q <= 1'b0;
      w_pending_q <= 1'b0;
    end else begin
      case (state_q)
        Idle: begin
          if (i_axil_awvalid || i_axil_wvalid) state_q <= Write;
          else if (i_axil_arvalid) state_q <= Read;
        end
        Write: begin
          if (i_axil_awvalid && o_axil_awready) begin
            aw_pending_q <= 1'b1;
            awaddr_q <= i_axil_awaddr;
          end
          if (i_axil_wvalid && o_axil_wready) begin
            w_pending_q <= 1'b1;
            wdata_q <= i_axil_wdata;
            wstrb_q <= i_axil_wstrb;
          end
          if (write_apply) begin
            aw_pending_q <= 1'b0;
            w_pending_q <= 1'b0;
            state_q <= WriteResp;
          end
        end
        WriteResp: if (i_axil_bready) state_q <= Idle;
        Read:
        if (i_axil_arvalid) begin
          araddr_q <= i_axil_araddr;
          state_q  <= ReadData;
        end
        ReadData: begin
          o_axil_rdata <= i_rd_pair;
          state_q <= ReadResp;
        end
        ReadResp:  if (i_axil_rready) state_q <= Idle;
        default:   state_q <= Idle;
      endcase
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire [5:0] unused_prot = {i_axil_awprot, i_axil_arprot};
  /* verilator lint_on UNUSEDSIGNAL */

  axil_checker #(
      .ADDR_BITS(ADDR_BITS)
  ) checker_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_awvalid(i_axil_awvalid),
      .i_awready(o_axil_awready),
      .i_awaddr(i_axil_awaddr),
      .i_awprot(i_axil_awprot),
      .i_wvalid(i_axil_wvalid),
      .i_wready(o_axil_wready),
      .i_wdata(i_axil_wdata),
      .i_wstrb(i_axil_wstrb),
      .i_bvalid(o_axil_bvalid),
      .i_bready(i_axil_bready),
      .i_bresp(o_axil_bresp),
      .i_arvalid(i_axil_arvalid),
      .i_arready(o_axil_arready),
      .i_araddr(i_axil_araddr),
      .i_arprot(i_axil_arprot),
      .i_rvalid(o_axil_rvalid),
      .i_rready(i_axil_rready),
      .i_rdata(o_axil_rdata),
      .i_rresp(o_axil_rresp)
  );

`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic f_aw, f_w, f_ar, f_applied;
  logic [ADDR_BITS-1:0] f_awaddr, f_araddr;
  logic [63:0] f_wdata, f_read_data;
  logic [7:0] f_wstrb;
  logic f_wide, f_wide_dword;
  always_comb begin
    f_wide = 1'b0;
    f_wide_dword = 1'b0;
    for (int k = 0; k < WIDE_COUNT; k++) begin
      f_wide |= f_awaddr == WIDE_OFFSETS[k*ADDR_BITS+:ADDR_BITS];
      f_wide_dword |= (f_awaddr >> 3) == (WIDE_OFFSETS[k*ADDR_BITS+:ADDR_BITS] >> 3);
    end
  end
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !$past(i_rst) && !i_rst) begin
      if ($past(i_axil_awvalid && !o_axil_awready)) begin
        assume (i_axil_awvalid);
        assume ($stable({i_axil_awaddr, i_axil_awprot}));
      end
      if ($past(i_axil_wvalid && !o_axil_wready)) begin
        assume (i_axil_wvalid);
        assume ($stable({i_axil_wdata, i_axil_wstrb}));
      end
      if ($past(i_axil_arvalid && !o_axil_arready)) begin
        assume (i_axil_arvalid);
        assume ($stable({i_axil_araddr, i_axil_arprot}));
      end
      if ($past(o_axil_bvalid && !i_axil_bready)) begin
        assert (o_axil_bvalid);
        assert ($stable(o_axil_bresp));
      end
      if ($past(o_axil_rvalid && !i_axil_rready)) begin
        assert (o_axil_rvalid);
        assert ($stable({o_axil_rdata, o_axil_rresp}));
      end
    end
    if (i_rst) begin
      f_aw <= 1'b0;
      f_w <= 1'b0;
      f_ar <= 1'b0;
      f_applied <= 1'b0;
      assert (!o_axil_awready && !o_axil_wready && !o_axil_arready);
      assert (!o_axil_bvalid && !o_axil_rvalid && !o_wr_en && !o_wr64_en);
    end else if (f_past_valid) begin
      assert (state_q <= ReadResp);
      assert (!(aw_pending_q || w_pending_q) || state_q == Write);
      assert (f_aw == (aw_pending_q || state_q == WriteResp));
      assert (f_w == (w_pending_q || state_q == WriteResp));
      assert (f_ar == (state_q == ReadData || state_q == ReadResp));
      assert (f_applied == (state_q == WriteResp));
      if (aw_pending_q) assert (awaddr_q == f_awaddr);
      if (w_pending_q) assert ({wdata_q, wstrb_q} == {f_wdata, f_wstrb});
      if (f_ar) assert (o_rd_offset == {f_araddr[ADDR_BITS-1:3], 3'b000});
      assert (!(f_ar && (f_aw || f_w)));
      assert (o_axil_bresp == 0 && o_axil_rresp == 0);
      if (i_axil_awvalid && o_axil_awready) begin
        assert (!f_aw);
        f_aw <= 1'b1;
        f_awaddr <= i_axil_awaddr;
      end
      if (i_axil_wvalid && o_axil_wready) begin
        assert (!f_w);
        f_w <= 1'b1;
        f_wdata <= i_axil_wdata;
        f_wstrb <= i_axil_wstrb;
      end
      if (i_axil_arvalid && o_axil_arready) begin
        assert (!f_ar);
        f_ar <= 1'b1;
        f_araddr <= i_axil_araddr;
      end
      // Reference expressions for the SoC's register-bus mapping. All
      // address bits, strobes and data bits are unconstrained.
      assert (write_apply == (f_aw && f_w && !f_applied));
      assert (o_wr64_en == (write_apply && f_wstrb == 8'hff && f_wide));
      assert (o_wr_en == (write_apply && f_wstrb != 0 && !f_wide_dword));
      if (o_wr_en || o_wr64_en) begin
        assert(o_wr_offset == (o_wr64_en ? f_awaddr :
            {f_awaddr[ADDR_BITS-1:3], (|f_wstrb[7:4]), 2'b00}));
        assert (o_wr_data == ((|f_wstrb[7:4]) ? f_wdata[63:32] : f_wdata[31:0]));
        assert (o_wr64_data == f_wdata);
      end
      if (write_apply) f_applied <= 1'b1;
      if (o_axil_bvalid) assert (f_aw && f_w && f_applied);
      if (o_axil_bvalid && i_axil_bready) begin
        f_aw <= 1'b0;
        f_w <= 1'b0;
        f_applied <= 1'b0;
      end
      if (state_q == ReadData) f_read_data <= i_rd_pair;
      if (o_axil_rvalid) begin
        assert (f_ar);
        assert (o_axil_rdata == f_read_data);
      end
      if (o_axil_rvalid && i_axil_rready) f_ar <= 1'b0;
      cover (f_aw && !f_w);
      cover (f_w && !f_aw);
      cover (o_wr64_en);
      cover (write_apply && f_wide_dword && !o_wr64_en);
      cover (o_wr_en && |f_wstrb[7:4]);
      cover (o_axil_bvalid && !i_axil_bready);
      cover (o_axil_rvalid && !i_axil_rready);
    end
    if (f_past_valid) cover (i_rst && $past(o_axil_bvalid || o_axil_rvalid));
  end
`endif
endmodule

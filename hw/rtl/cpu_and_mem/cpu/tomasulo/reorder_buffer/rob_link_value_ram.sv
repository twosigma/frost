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
 * ROB value RAM with one shared allocation link bank.
 *
 * With reorder_buffer's SharedLinkBank set, both allocation ports share one
 * LINK_WIDTH bank. Non-branch allocations select a constant zero. The CDB
 * lanes each have a DATA_WIDTH bank.
 *
 * LVT codes (2 bits, the same width as the 4-port LVT):
 *   CodeZero = 0  allocation without a link (reads 0)
 *   CodeLink = 1  allocation with a link (reads zext(link bank))
 *   CodeCdb0 = 2  CDB lane 0 bank (port 2 of the 4-port RAM)
 *   CodeCdb1 = 3  CDB lane 1 bank (port 3 of the 4-port RAM)
 *
 * Allocation slot s writes code (i_alloc_branch[s] ? CodeLink : CodeZero) at
 * i_alloc_address[s] through the same one-cycle LVT staging, drain order and
 * staged override as mwp_dist_ram. The link bank writes in the allocation
 * cycle when either slot is an enabled branch; slot 2's enabled branch takes
 * the bank's single port.
 *
 * Two enabled branch allocations must target the same address; otherwise
 * slot 1's link is lost. cpu_ooo's dispatch allows at most one: slot 2 never
 * fires behind a slot-1 branch. With this restriction, reads match the
 * 4-port RAM cycle for cycle, including stale, duplicate-tag and drain-cycle
 * CDB writes.
 *
 * ONEHOT_READ = 1 is the head-port variant (mwp_dist_ram_ohread's AND-OR LVT
 * read); i_read_onehot must equal 1 << i_read_address when the read is used.
 * Unlike mwp_dist_ram_ohread, an all-zero i_read_onehot reads 0 rather than
 * slot 1's bank. ONEHOT_READ = 0 is the binary-read variant (mwp_dist_ram's
 * staged read path); it ignores i_read_onehot.
 */
module rob_link_value_ram #(
    parameter int unsigned ADDR_WIDTH  = 5,
    parameter int unsigned DATA_WIDTH  = 64,
    parameter int unsigned LINK_WIDTH  = DATA_WIDTH,
    parameter bit          ONEHOT_READ = 1'b0
) (
    input logic i_clk,

    // Allocation ports [0] = slot 1, [1] = slot 2 (staged LVT update).
    input logic [1:0]                 i_alloc_enable,
    input logic [1:0][ADDR_WIDTH-1:0] i_alloc_address,
    input logic [1:0]                 i_alloc_branch,
    input logic [1:0][LINK_WIDTH-1:0] i_alloc_link,

    // CDB ports [0] = lane 0, [1] = lane 1 (live LVT update).
    input logic [1:0]                 i_cdb_enable,
    input logic [1:0][ADDR_WIDTH-1:0] i_cdb_address,
    input logic [1:0][DATA_WIDTH-1:0] i_cdb_data,

    // Asynchronous read; i_read_onehot is used only with ONEHOT_READ = 1.
    input  logic [   ADDR_WIDTH-1:0] i_read_address,
    input  logic [2**ADDR_WIDTH-1:0] i_read_onehot,
    output logic [   DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  localparam logic [1:0] CodeZero = 2'd0;
  localparam logic [1:0] CodeLink = 2'd1;
  localparam logic [1:0] CodeCdb0 = 2'd2;
  localparam logic [1:0] CodeCdb1 = 2'd3;

  // ---------------------------------------------------------------------------
  // Banks: one shared link bank and one bank per CDB lane.
  // ---------------------------------------------------------------------------
  logic                  link_write_enable;
  logic                  link_write_slot2;
  logic [ADDR_WIDTH-1:0] link_write_address;
  logic [LINK_WIDTH-1:0] link_write_data;
  logic [LINK_WIDTH-1:0] link_read_data;

  assign link_write_slot2 = i_alloc_enable[1] && i_alloc_branch[1];
  assign link_write_enable = link_write_slot2 || (i_alloc_enable[0] && i_alloc_branch[0]);
  assign link_write_address = link_write_slot2 ? i_alloc_address[1] : i_alloc_address[0];
  assign link_write_data = link_write_slot2 ? i_alloc_link[1] : i_alloc_link[0];

  sdp_dist_ram #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(LINK_WIDTH)
  ) u_link_bank (
      .i_clk,
      .i_write_enable (link_write_enable),
      .i_write_address(link_write_address),
      .i_read_address (i_read_address),
      .i_write_data   (link_write_data),
      .o_read_data    (link_read_data)
  );

  logic [1:0][DATA_WIDTH-1:0] cdb_read_data;

  for (genvar lane = 0; lane < 2; lane++) begin : g_cdb_banks
    sdp_dist_ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_bank (
        .i_clk,
        .i_write_enable (i_cdb_enable[lane]),
        .i_write_address(i_cdb_address[lane]),
        .i_read_address (i_read_address),
        .i_write_data   (i_cdb_data[lane]),
        .o_read_data    (cdb_read_data[lane])
    );
  end : g_cdb_banks

  // ---------------------------------------------------------------------------
  // Live Value Table: stage each allocation's branch flag as its bank code.
  // ---------------------------------------------------------------------------
  logic [1:0] lvt[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) lvt[i] = CodeZero;

  logic [1:0] staged_lvt_we_q = '0;
  logic [1:0] staged_lvt_link_q;
  // Limit address fanout to the read-port compares.
  (* max_fanout = 48 *) logic [1:0][ADDR_WIDTH-1:0] staged_lvt_addr_q;

  always_ff @(posedge i_clk) begin
    staged_lvt_we_q   <= i_alloc_enable;
    staged_lvt_addr_q <= i_alloc_address;
    staged_lvt_link_q <= i_alloc_branch;
  end

  always_ff @(posedge i_clk) begin
    // Staged drains first, slot 2 last; a live same-address write overrides.
    for (int s = 0; s < 2; s++) begin
      if (staged_lvt_we_q[s]) lvt[staged_lvt_addr_q[s]] <= {1'b0, staged_lvt_link_q[s]};
    end
    if (i_cdb_enable[0]) lvt[i_cdb_address[0]] <= CodeCdb0;
    if (i_cdb_enable[1]) lvt[i_cdb_address[1]] <= CodeCdb1;
  end

  // ---------------------------------------------------------------------------
  // Read: bank select, then a 3-bank + zero data mux.
  // ---------------------------------------------------------------------------
  logic [1:0] lvt_read_code;

  if (ONEHOT_READ) begin : g_read_onehot
    // Apply staged overrides per entry before the one-hot LVT read.
    logic [1:0] lvt_eff[RamDepth];

    always_comb begin
      for (int i = 0; i < RamDepth; i++) begin
        lvt_eff[i] = lvt[i];
        for (int s = 0; s < 2; s++) begin
          if (staged_lvt_we_q[s] && (staged_lvt_addr_q[s] == ADDR_WIDTH'(i))) begin
            lvt_eff[i] = {1'b0, staged_lvt_link_q[s]};
          end
        end
      end
    end

    always_comb begin
      lvt_read_code = '0;
      for (int i = 0; i < RamDepth; i++) begin
        if (i_read_onehot[i]) lvt_read_code |= lvt_eff[i];
      end
    end
  end else begin : g_read_binary
    // Split the LVT read at the address MSB, then apply staged overrides.
    (* keep = "true" *)logic [1:0] lvt_read_lo;
    (* keep = "true" *)logic [1:0] lvt_read_hi;
    (* keep = "true" *)logic [1:0] staged_read_hit;
    (* keep = "true" *)logic [1:0] lvt_read_sel;

    if (ADDR_WIDTH > 1) begin : g_split
      assign lvt_read_lo = lvt[{1'b0, i_read_address[ADDR_WIDTH-2:0]}];
      assign lvt_read_hi = lvt[{1'b1, i_read_address[ADDR_WIDTH-2:0]}];
    end else begin : g_no_split
      assign lvt_read_lo = lvt[0];
      assign lvt_read_hi = lvt[RamDepth-1];
    end

    always_comb begin
      for (int s = 0; s < 2; s++) begin
        staged_read_hit[s] = staged_lvt_we_q[s] && (staged_lvt_addr_q[s] == i_read_address);
      end
    end

    always_comb begin
      lvt_read_sel = i_read_address[ADDR_WIDTH-1] ? lvt_read_hi : lvt_read_lo;
      for (int s = 0; s < 2; s++) begin
        if (staged_read_hit[s]) lvt_read_sel = {1'b0, staged_lvt_link_q[s]};
      end
    end

    assign lvt_read_code = lvt_read_sel;
  end

  (* keep = "true" *) logic [DATA_WIDTH-1:0] selected_value;
  always_comb begin
    case (lvt_read_code)
      CodeLink: selected_value = DATA_WIDTH'(link_read_data);
      CodeCdb0: selected_value = cdb_read_data[0];
      CodeCdb1: selected_value = cdb_read_data[1];
      default:  selected_value = '0;
    endcase
  end

  assign o_read_data = selected_value;

`ifndef SYNTHESIS
`ifndef FORMAL
  initial begin
    if (LINK_WIDTH > DATA_WIDTH) begin
      $fatal(1, "rob_link_value_ram: LINK_WIDTH (%0d) > DATA_WIDTH (%0d)", LINK_WIDTH, DATA_WIDTH);
    end
  end

  // The shared link bank cannot write two distinct addresses in one cycle.
  always @(posedge i_clk) begin
    if (!$isunknown(
            {i_alloc_enable, i_alloc_branch}
        ) && (&(i_alloc_enable & i_alloc_branch)) &&
            (i_alloc_address[0] != i_alloc_address[1])) begin
      $error("rob_link_value_ram: two branch allocations at different addresses");
    end
  end
`endif
`endif

endmodule : rob_link_value_ram

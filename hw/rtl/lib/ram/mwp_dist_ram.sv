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
 * Multi-write-port distributed RAM using a live-value table (LVT). Each write
 * port has its own RAM bank; the per-address LVT selects the newest bank for
 * the asynchronous read. Among ordinary same-cycle writes, the highest-numbered
 * port wins. Duplicate the module with shared writes for additional reads.
 *
 * Ports [NUM_STAGED_LVT_PORTS-1:0] write their banks immediately and update
 * the LVT one cycle later. A read override covers the delay.
 *
 * Ports [NUM_NARROW_WRITE_PORTS-1:0] store only NARROW_DATA_WIDTH low bits;
 * reads reconstruct zero upper bits. The ROB uses narrow allocation ports
 * for zero-extended XLEN link addresses when SharedLinkBank=0. With
 * FLEN == XLEN, these banks are full width and need no upper-bit check.
 *
 * Staged ports must have the lowest indices. Their collision rules differ:
 *   - A same-cycle staged/live collision is legal and the staged write wins.
 *     The ROB relies on allocation beating a stale CDB completion.
 *   - A live write in the following drain cycle wins and therefore must be
 *     architecturally newer. The ROB guarantees no completion one cycle after
 *     allocation; other users must provide the equivalent invariant.
 */
module mwp_dist_ram #(
    parameter int unsigned ADDR_WIDTH             = 5,          // Address width in bits
    parameter int unsigned DATA_WIDTH             = 32,         // Data width in bits
    parameter int unsigned NUM_WRITE_PORTS        = 2,          // Number of write ports (>= 2)
    // Low-index ports with delayed LVT updates; see the collision rules above.
    parameter int unsigned NUM_STAGED_LVT_PORTS   = 0,
    // Low-index ports whose data must be zero above NARROW_DATA_WIDTH.
    parameter int unsigned NUM_NARROW_WRITE_PORTS = 0,
    parameter int unsigned NARROW_DATA_WIDTH      = DATA_WIDTH
) (
    input logic i_clk,

    // Write ports (active-high enables, independent addresses and data)
    input logic [NUM_WRITE_PORTS-1:0]                 i_write_enable,
    input logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] i_write_address,
    input logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] i_write_data,

    // Read port (asynchronous / combinational)
    input  logic [ADDR_WIDTH-1:0] i_read_address,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned SelWidth = $clog2(NUM_WRITE_PORTS);
  // Signed loop bound avoids unsigned comparison warnings when the count is zero.
  localparam int StagedLvtPorts = int'(NUM_STAGED_LVT_PORTS);

  // ---------------------------------------------------------------------------
  // RAM bank per write port. Narrow reads are zero-extended to DATA_WIDTH.
  // ---------------------------------------------------------------------------
  logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] bank_read_data;

  for (genvar wp = 0; wp < NUM_WRITE_PORTS; wp++) begin : g_banks
    localparam int unsigned BankWidth =
        (wp < int'(NUM_NARROW_WRITE_PORTS)) ? NARROW_DATA_WIDTH : DATA_WIDTH;
    logic [BankWidth-1:0] bank_read_data_raw;
    sdp_dist_ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(BankWidth)
    ) u_bank (
        .i_clk,
        .i_write_enable (i_write_enable[wp]),
        .i_write_address(i_write_address[wp]),
        .i_read_address (i_read_address),
        .i_write_data   (i_write_data[wp][BankWidth-1:0]),
        .o_read_data    (bank_read_data_raw)
    );
    assign bank_read_data[wp] = DATA_WIDTH'(bank_read_data_raw);
  end : g_banks

  // ---------------------------------------------------------------------------
  // Live Value Table (register-based)
  //
  // Selects the newest bank per address, with the collision priority above.
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) lvt[i] = '0;

  // Holds staged writes for one cycle; unused bits stay zero.
  // Declaration initialization is allowed for always_ff state by IEEE 1800
  // 9.2.2.4; a separate initial process would be another writer.
  logic [NUM_WRITE_PORTS-1:0] staged_lvt_we_q = '0;
  // Limit address fanout to the read-port compares.
  (* max_fanout = 48 *) logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] staged_lvt_addr_q;

  always_ff @(posedge i_clk) begin
    for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
      if (wp < StagedLvtPorts) begin
        staged_lvt_we_q[wp]   <= i_write_enable[wp];
        staged_lvt_addr_q[wp] <= i_write_address[wp];
      end else begin
        staged_lvt_we_q[wp]   <= 1'b0;
        staged_lvt_addr_q[wp] <= '0;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    // Staged drains first: a live same-address write below overrides.
    for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
      if (staged_lvt_we_q[wp]) lvt[staged_lvt_addr_q[wp]] <= SelWidth'(wp);
    end
    for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
      if (wp >= StagedLvtPorts) begin
        if (i_write_enable[wp]) lvt[i_write_address[wp]] <= SelWidth'(wp);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read mux: select the bank indicated by the effective LVT
  //
  // Override stale LVT entries during the one-cycle drain gap. The bank
  // already holds the staged write, so the override selects the new data.
  // Except for same-cycle staged/live collisions, reads match the unstaged
  // module cycle for cycle. Without staged ports, lvt_eff equals lvt.
  //
  // g_read_staged computes the same selection only for i_read_address. The
  // highest matching staged port wins. The LVT mux splits at the address
  // MSB for timing.
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt_eff[RamDepth];

  always_comb begin
    for (int i = 0; i < RamDepth; i++) begin
      lvt_eff[i] = lvt[i];
      for (int wp = 0; wp < NUM_WRITE_PORTS; wp++) begin
        if ((wp < StagedLvtPorts) && staged_lvt_we_q[wp] &&
            (staged_lvt_addr_q[wp] == ADDR_WIDTH'(i))) begin
          lvt_eff[i] = SelWidth'(wp);
        end
      end
    end
  end

  if (StagedLvtPorts == 0) begin : g_read_live
    assign o_read_data = bank_read_data[lvt_eff[i_read_address]];
  end else begin : g_read_staged
    // The kept nets fix the split described above; without them synthesis
    // folds the override back into the full-depth mux.
    (* keep = "true" *) logic [SelWidth-1:0] lvt_read_lo;
    (* keep = "true" *) logic [SelWidth-1:0] lvt_read_hi;
    (* keep = "true" *) logic [StagedLvtPorts-1:0] staged_read_hit;
    (* keep = "true" *) logic [SelWidth-1:0] lvt_read_sel;

    if (ADDR_WIDTH > 1) begin : g_split
      assign lvt_read_lo = lvt[{1'b0, i_read_address[ADDR_WIDTH-2:0]}];
      assign lvt_read_hi = lvt[{1'b1, i_read_address[ADDR_WIDTH-2:0]}];
    end else begin : g_no_split
      assign lvt_read_lo = lvt[0];
      assign lvt_read_hi = lvt[RamDepth-1];
    end

    always_comb begin
      for (int wp = 0; wp < StagedLvtPorts; wp++) begin
        staged_read_hit[wp] = staged_lvt_we_q[wp] && (staged_lvt_addr_q[wp] == i_read_address);
      end
    end

    always_comb begin
      lvt_read_sel = i_read_address[ADDR_WIDTH-1] ? lvt_read_hi : lvt_read_lo;
      for (int wp = 0; wp < StagedLvtPorts; wp++) begin
        if (staged_read_hit[wp]) lvt_read_sel = SelWidth'(wp);
      end
    end

    assign o_read_data = bank_read_data[lvt_read_sel];
  end : g_read_staged

`ifndef SYNTHESIS
`ifndef FORMAL
  // Staged ports must be the lowest indices: the drain-cycle override rule
  // (live beats staged) matches "highest port wins" only in that layout.
  initial begin
    if (NUM_STAGED_LVT_PORTS > NUM_WRITE_PORTS) begin
      $fatal(1, "mwp_dist_ram: NUM_STAGED_LVT_PORTS (%0d) > NUM_WRITE_PORTS (%0d)",
             NUM_STAGED_LVT_PORTS, NUM_WRITE_PORTS);
    end
    if (NUM_NARROW_WRITE_PORTS > NUM_WRITE_PORTS) begin
      $fatal(1, "mwp_dist_ram: NUM_NARROW_WRITE_PORTS (%0d) > NUM_WRITE_PORTS (%0d)",
             NUM_NARROW_WRITE_PORTS, NUM_WRITE_PORTS);
    end
    if (NARROW_DATA_WIDTH > DATA_WIDTH) begin
      $fatal(1, "mwp_dist_ram: NARROW_DATA_WIDTH (%0d) > DATA_WIDTH (%0d)", NARROW_DATA_WIDTH,
             DATA_WIDTH);
    end
  end

  // Reject nonzero upper bits that a narrow bank would discard.
  if (NUM_NARROW_WRITE_PORTS > 0 && NARROW_DATA_WIDTH < DATA_WIDTH) begin : g_narrow_write_check
    localparam int NarrowPorts = int'(NUM_NARROW_WRITE_PORTS);
    always @(posedge i_clk) begin
      for (int wp = 0; wp < NarrowPorts; wp++) begin
        if (!$isunknown(
                i_write_enable[wp]
            ) && i_write_enable[wp] && !$isunknown(
                i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH]
            ) && (i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH] != '0)) begin
          $error("mwp_dist_ram: narrow write port %0d carries nonzero upper bits (0x%0h)", wp,
                 i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH]);
        end
      end
    end
  end : g_narrow_write_check

  // The ROB checks for stale completions in the cycle after allocation,
  // where a live write would override the staged LVT update.
`endif
`endif

endmodule : mwp_dist_ram

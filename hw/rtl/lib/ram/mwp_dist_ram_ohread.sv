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
 * mwp_dist_ram with a one-hot read select for the Live Value Table.
 *
 * Storage and write rules match mwp_dist_ram, including staged and narrow
 * ports. i_read_address drives the RAM banks; i_read_onehot selects the LVT
 * entry with an AND-OR reduction:
 *
 *   lvt_read_sel = OR_i (i_read_onehot[i] ? lvt_eff[i] : '0)
 *
 * The caller must hold i_read_onehot == (1 << i_read_address) in every cycle
 * where o_read_data is consumed; o_read_data then equals the base module's.
 * An all-zero i_read_onehot reads bank 0. A simulation-only check below
 * fires on any other mismatch.
 *
 * The ROB supplies registered head masks; reservation stations supply their
 * second-issue winner mask.
 */
module mwp_dist_ram_ohread #(
    parameter int unsigned ADDR_WIDTH             = 5,          // Address width in bits
    parameter int unsigned DATA_WIDTH             = 32,         // Data width in bits
    parameter int unsigned NUM_WRITE_PORTS        = 2,          // Number of write ports (>= 2)
    // Low-index ports with delayed LVT updates; see mwp_dist_ram.
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

    // Asynchronous read; binary and one-hot addresses must agree when used.
    input  logic [   ADDR_WIDTH-1:0] i_read_address,
    input  logic [2**ADDR_WIDTH-1:0] i_read_onehot,
    output logic [   DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned SelWidth = $clog2(NUM_WRITE_PORTS);
  // Signed loop bound avoids unsigned comparison warnings when the count is zero.
  localparam int StagedLvtPorts = int'(NUM_STAGED_LVT_PORTS);

  // ---------------------------------------------------------------------------
  // RAM bank per write port (identical to mwp_dist_ram, including the
  // narrow-port zero-extension).
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
  // Live Value Table (register-based, identical write behavior).
  // Staged ports (indices < NUM_STAGED_LVT_PORTS) update one cycle late from
  // staging registers; staged drains apply first so a live same-address write
  // in the drain cycle wins. See mwp_dist_ram for the collision rules.
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) lvt[i] = '0;

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

  // Override stale LVT entries during the one-cycle drain gap.
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

  // ---------------------------------------------------------------------------
  // Read mux: LVT selected by the one-hot AND-OR instead of a binary mux
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt_read_sel;
  always_comb begin
    lvt_read_sel = '0;
    for (int i = 0; i < RamDepth; i++) begin
      if (i_read_onehot[i]) lvt_read_sel |= lvt_eff[i];
    end
  end

  assign o_read_data = bank_read_data[lvt_read_sel];

`ifndef SYNTHESIS
`ifndef FORMAL
  initial begin
    if (NUM_STAGED_LVT_PORTS > NUM_WRITE_PORTS) begin
      $fatal(1, "mwp_dist_ram_ohread: NUM_STAGED_LVT_PORTS (%0d) > NUM_WRITE_PORTS (%0d)",
             NUM_STAGED_LVT_PORTS, NUM_WRITE_PORTS);
    end
    if (NUM_NARROW_WRITE_PORTS > NUM_WRITE_PORTS) begin
      $fatal(1, "mwp_dist_ram_ohread: NUM_NARROW_WRITE_PORTS (%0d) > NUM_WRITE_PORTS (%0d)",
             NUM_NARROW_WRITE_PORTS, NUM_WRITE_PORTS);
    end
    if (NARROW_DATA_WIDTH > DATA_WIDTH) begin
      $fatal(1, "mwp_dist_ram_ohread: NARROW_DATA_WIDTH (%0d) > DATA_WIDTH (%0d)",
             NARROW_DATA_WIDTH, DATA_WIDTH);
    end
  end

  // Narrow write ports must be given zero-extended data (see mwp_dist_ram).
  if (NUM_NARROW_WRITE_PORTS > 0 && NARROW_DATA_WIDTH < DATA_WIDTH) begin : g_narrow_write_check
    localparam int NarrowPorts = int'(NUM_NARROW_WRITE_PORTS);
    always @(posedge i_clk) begin
      for (int wp = 0; wp < NarrowPorts; wp++) begin
        if (!$isunknown(
                i_write_enable[wp]
            ) && i_write_enable[wp] && !$isunknown(
                i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH]
            ) && (i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH] != '0)) begin
          $error("mwp_dist_ram_ohread: narrow write port %0d carries nonzero upper bits (0x%0h)",
                 wp, i_write_data[wp][DATA_WIDTH-1:NARROW_DATA_WIDTH]);
        end
      end
    end
  end : g_narrow_write_check

  // A nonzero one-hot select must match the binary address or the read may
  // return the wrong bank. Zero selects bank 0 and is allowed for unused
  // reads, including uninitialized ROB head masks and an idle second issue
  // port. FORMAL excludes this check because Yosys cannot elaborate a clocked
  // $error.
  always @(posedge i_clk) begin
    if (!$isunknown(
            i_read_address
        ) && !$isunknown(
            i_read_onehot
        ) && (i_read_onehot != '0) && (i_read_onehot != (RamDepth'(1) << i_read_address))) begin
      $error("mwp_dist_ram_ohread: i_read_onehot (0x%0h) != 1 << i_read_address (%0d)",
             i_read_onehot, i_read_address);
    end
  end

  // The ROB checks for stale completions in the cycle after allocation,
  // where a live write would override the staged LVT update.
`endif
`endif

endmodule : mwp_dist_ram_ohread

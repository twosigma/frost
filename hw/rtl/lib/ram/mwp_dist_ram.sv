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
 * Multi-write-port distributed RAM using the Live Value Table (LVT) technique.
 *
 * Provides NUM_WRITE_PORTS independent write ports and a single asynchronous
 * read port backed by distributed (LUT) RAM. Internally, one sdp_dist_ram
 * instance is allocated per write port, each exclusively written by its
 * corresponding port. A small register-based Live Value Table tracks which
 * RAM copy holds the most recent value for every address, steering the read
 * mux accordingly.
 *
 * Write-port priority: when multiple ports write the same address in the same
 * cycle, the highest-numbered port wins (index NUM_WRITE_PORTS-1 has the
 * highest priority).
 *
 * For multiple read ports, instantiate multiple copies of this module with
 * identical write connections; each copy may use a different i_read_address.
 *
 * Resource cost (approximate, for DEPTH entries):
 *   - NUM_WRITE_PORTS x sdp_dist_ram instances (DATA_WIDTH-wide each)
 *   - DEPTH x $clog2(NUM_WRITE_PORTS) flip-flops for the LVT
 *   - One NUM_WRITE_PORTS-to-1 DATA_WIDTH-wide read mux
 *
 * Scales well up to ~4 write ports; beyond that the read mux depth and LVT
 * size start to matter for timing.
 *
 * NUM_STAGED_LVT_PORTS (timing option, default 0 = classic behavior):
 * write ports [NUM_STAGED_LVT_PORTS-1:0] get a REGISTER-STAGED LVT update.
 * Their bank write still happens in the enable cycle; only the LVT update is
 * executed one cycle later from internal {we, address} staging registers, so
 * a late-arriving write enable never reaches the per-entry LVT decode (DEPTH x
 * SelWidth flop CE/D cones — the dominant fanout of this module).  Reads stay
 * cycle-exact: a per-entry effective-LVT view overrides the staged entry's
 * stale LVT bits during the one-cycle gap, computed purely from the staging
 * registers on the EARLY side of the read mux (the late read address sees the
 * same DEPTH-to-1 select depth as the unstaged module).  Semantics are
 * bit-identical to the unstaged module for every read, PROVIDED a staged
 * port's write address is never written again (by any port) in the very next
 * cycle with a requirement that the STAGED port's value win — the drain
 * applies staged updates first, so a live port writing the same address in
 * the drain cycle wins, exactly like the same-cycle "highest port wins" rule
 * (staged ports must therefore be the LOWEST indices, enforced below).
 */
module mwp_dist_ram #(
    parameter int unsigned ADDR_WIDTH           = 5,   // Address width in bits
    parameter int unsigned DATA_WIDTH           = 32,  // Data width in bits
    parameter int unsigned NUM_WRITE_PORTS      = 2,   // Number of write ports (>= 2)
    // Ports [NUM_STAGED_LVT_PORTS-1:0] update the LVT one cycle late from
    // staging registers (banks still write same-cycle).  See header.
    parameter int unsigned NUM_STAGED_LVT_PORTS = 0
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
  // Signed mirror for loop-bound comparisons (loop vars are signed int;
  // comparing against the unsigned parameter is a constant-comparison
  // lint warning when NUM_STAGED_LVT_PORTS=0).
  localparam int StagedLvtPorts = int'(NUM_STAGED_LVT_PORTS);

  // ---------------------------------------------------------------------------
  // RAM bank per write port
  // ---------------------------------------------------------------------------
  logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] bank_read_data;

  for (genvar wp = 0; wp < NUM_WRITE_PORTS; wp++) begin : g_banks
    sdp_dist_ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_bank (
        .i_clk,
        .i_write_enable (i_write_enable[wp]),
        .i_write_address(i_write_address[wp]),
        .i_read_address (i_read_address),
        .i_write_data   (i_write_data[wp]),
        .o_read_data    (bank_read_data[wp])
    );
  end : g_banks

  // ---------------------------------------------------------------------------
  // Live Value Table (register-based)
  //
  // Tracks which bank holds the most recent write for each address.
  // Highest-indexed write port wins on simultaneous same-address writes.
  //
  // Staged ports (indices < NUM_STAGED_LVT_PORTS): the LVT update runs one
  // cycle late from the staging registers below, so the port's (late) enable
  // only loads the staging flops' D pins instead of every per-entry LVT
  // CE/D cone.  Staged drains apply FIRST so a live port writing the same
  // address in the drain cycle wins (it is the architecturally newer write).
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) lvt[i] = '0;

  // Staged-LVT state: bit wp mirrors write port wp, held one cycle.  Bits at
  // or above NUM_STAGED_LVT_PORTS are tied 0 and synthesize away (the classic
  // all-live configuration when NUM_STAGED_LVT_PORTS=0).
  logic [NUM_WRITE_PORTS-1:0]                 staged_lvt_we_q;
  logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] staged_lvt_addr_q;

  initial staged_lvt_we_q = '0;

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
  // Read mux — select the bank indicated by the effective LVT
  //
  // lvt_eff overrides the staged entries' still-stale LVT bits during the
  // one-cycle drain gap.  The override terms are pure functions of staging
  // REGISTERS, so they fold into the early side of the select cone; the late
  // read address sees the same RamDepth-to-1 depth as the unstaged module.
  // The staged port's bank was written in the enable cycle, so the corrected
  // select returns the new data — reads are cycle-exact vs. the unstaged
  // module.
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

  assign o_read_data = bank_read_data[lvt_eff[i_read_address]];

`ifndef SYNTHESIS
`ifndef FORMAL
  // Staged ports must be the lowest indices: the drain-cycle override rule
  // (live beats staged) matches "highest port wins" only in that layout.
  initial begin
    if (NUM_STAGED_LVT_PORTS > NUM_WRITE_PORTS) begin
      $fatal(1, "mwp_dist_ram: NUM_STAGED_LVT_PORTS (%0d) > NUM_WRITE_PORTS (%0d)",
             NUM_STAGED_LVT_PORTS, NUM_WRITE_PORTS);
    end
  end

  // Caller invariant required by the staging: a staged port's write address
  // must not also be written by a LIVE port in the SAME cycle.  (The read
  // correction would pick the staged bank during the gap cycle, while the
  // classic same-cycle rule gives the live port the win.)  In the reorder
  // buffer's use this cannot happen — an entry being allocated (staged ports)
  // cannot receive a CDB result (live ports) in its allocation cycle.
  always @(posedge i_clk) begin
    for (int k = 0; k < StagedLvtPorts; k++) begin
      for (int wp = StagedLvtPorts; wp < NUM_WRITE_PORTS; wp++) begin
        if (!$isunknown(
                {i_write_enable[k], i_write_enable[wp]}
            ) && i_write_enable[k] && i_write_enable[wp] &&
                (i_write_address[k] == i_write_address[wp])) begin
          $error("mwp_dist_ram: staged port %0d and live port %0d wrote 0x%0h same-cycle", k, wp,
                 i_write_address[k]);
        end
      end
    end
  end
`endif
`endif

endmodule : mwp_dist_ram

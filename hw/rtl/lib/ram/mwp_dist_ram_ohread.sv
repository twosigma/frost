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
 * mwp_dist_ram with a ONE-HOT read select for the Live Value Table.
 *
 * Identical storage/write semantics to mwp_dist_ram (one sdp_dist_ram bank per
 * write port + register LVT, highest-numbered port wins on same-address
 * writes).  The difference is purely a TIMING restructure of the read path:
 * the caller supplies BOTH the binary read address (still used for the banks'
 * LUTRAM address pins, which require binary) AND a registered one-hot image of
 * the same address (i_read_onehot).  The LVT bank-select lookup — a 32:1 mux
 * of registered LVT bits behind a high-fanout binary select in the base
 * module — becomes an AND-OR reduction over per-entry one-hot bits:
 *
 *   lvt_read_sel = OR_i (i_read_onehot[i] ? lvt[i] : '0)
 *
 * CONTRACT (caller invariant): i_read_onehot == (1 << i_read_address) in
 * every cycle where o_read_data is consumed.  Under that invariant the
 * reduction equals lvt[i_read_address] exactly, so o_read_data is
 * bit-identical to the base module's.  A simulation-only check below fires if
 * the invariant is ever violated.
 *
 * Intended use: the reorder buffer head / head+1 read ports, whose one-hot
 * images (head_clear_mask / head_next_clear_mask) are already maintained as
 * registers that move in lockstep with head_ptr.
 *
 * NUM_STAGED_LVT_PORTS: same register-staged LVT-update option as
 * mwp_dist_ram (see that header for the full contract).  Ports
 * [NUM_STAGED_LVT_PORTS-1:0] write their bank same-cycle but update the LVT
 * one cycle later from staging registers; reads stay cycle-exact via a
 * per-entry effective-LVT override computed from the staging registers.
 */
module mwp_dist_ram_ohread #(
    parameter int unsigned ADDR_WIDTH           = 5,   // Address width in bits
    parameter int unsigned DATA_WIDTH           = 32,  // Data width in bits
    parameter int unsigned NUM_WRITE_PORTS      = 2,   // Number of write ports (>= 2)
    // Ports [NUM_STAGED_LVT_PORTS-1:0] update the LVT one cycle late from
    // staging registers (banks still write same-cycle).  See mwp_dist_ram.
    parameter int unsigned NUM_STAGED_LVT_PORTS = 0
) (
    input logic i_clk,

    // Write ports (active-high enables, independent addresses and data)
    input logic [NUM_WRITE_PORTS-1:0]                 i_write_enable,
    input logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] i_write_address,
    input logic [NUM_WRITE_PORTS-1:0][DATA_WIDTH-1:0] i_write_data,

    // Read port (asynchronous / combinational).
    // i_read_address feeds the LUTRAM banks (binary); i_read_onehot must be a
    // registered one-hot image of the SAME address and steers the LVT select.
    input  logic [   ADDR_WIDTH-1:0] i_read_address,
    input  logic [2**ADDR_WIDTH-1:0] i_read_onehot,
    output logic [   DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned RamDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned SelWidth = $clog2(NUM_WRITE_PORTS);
  // Signed mirror for loop-bound comparisons (loop vars are signed int;
  // comparing against the unsigned parameter is a constant-comparison
  // lint warning when NUM_STAGED_LVT_PORTS=0).
  localparam int StagedLvtPorts = int'(NUM_STAGED_LVT_PORTS);

  // ---------------------------------------------------------------------------
  // RAM bank per write port (identical to mwp_dist_ram)
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
  // Live Value Table (register-based, identical write behavior).
  // Staged ports (indices < NUM_STAGED_LVT_PORTS) update one cycle late from
  // staging registers; staged drains apply first so a live same-address write
  // in the drain cycle wins.  See mwp_dist_ram for the full contract.
  // ---------------------------------------------------------------------------
  logic [SelWidth-1:0] lvt[RamDepth];

  initial for (int i = 0; i < RamDepth; ++i) lvt[i] = '0;

  // Initialized at declaration (not via an initial block): IEEE 1800
  // 9.2.2.4 forbids an always_ff variable being written by another process,
  // but explicitly permits declaration initialization (Verilator >=5.050
  // enforces this; yosys formal needs the pinned init value either way).
  logic [NUM_WRITE_PORTS-1:0] staged_lvt_we_q = '0;
  logic [NUM_WRITE_PORTS-1:0][ADDR_WIDTH-1:0] staged_lvt_addr_q;

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

  // Per-entry effective-LVT view: overrides the staged entries' still-stale
  // LVT bits during the one-cycle drain gap, purely from staging registers
  // (early side of the reduction — the one-hot mask sees unchanged depth).
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
  // Read mux — LVT selected via the one-hot AND-OR instead of a binary mux
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
  end

  // Simulation-only contract check: the one-hot select must mirror the binary
  // read address whenever both are known.  A mismatch would silently return
  // the wrong bank's data, so treat it as an error.  The all-zero case is
  // tolerated: it only occurs before the caller's reset has loaded the mask
  // register (2-state sims read uninitialized FFs as 0), where it selects
  // bank 0 exactly like the base module's initial lvt='0 read would.
  // (FORMAL builds exclude this block — yosys cannot elaborate $error in a
  // clocked process; the equivalent invariant is proven as
  // p_head_mask_onehot / p_head_next_mask_onehot in the reorder_buffer's
  // FORMAL section instead.)
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

  // Same-cycle staged+live writes to one address are legal and resolve
  // staged-wins (see mwp_dist_ram's header for the full staged-port
  // collision contract) — no check here.  The dangerous arrival is a live
  // write in the staged address's DRAIN cycle; the reorder buffer (the only
  // staged-port user) excludes and checks that window at the ROB level.
`endif
`endif

endmodule : mwp_dist_ram_ohread
